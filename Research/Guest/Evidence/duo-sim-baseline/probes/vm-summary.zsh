#!/bin/zsh
# vm-summary.zsh <records.jsonl | domain.json posture-label>
# The posture-table values from springboard-state / display-springboard records: prevailing
# policy, hinge state, primary scene, content modes, backlight states, scene and screen
# orientation/bounds, transition style. Works on a VM step's records.jsonl or on one posture
# of a simulator domain file.
set -euo pipefail
jq=/opt/homebrew/bin/jq
if [[ $1 == *.jsonl ]]; then src=($jq -s -c . $1); else src=($jq -c --arg l "$2" '[.records[] | select(.posture == $l)]' $1); fi
"${src[@]}" | $jq -r '
  def v($a): [.[] | select(.api == $a) | .value] | first;
  def vc($a; $c): [.[] | select(.api == $a and (.call | test($c))) | .value] | first;
  (v("SBFDisplayContentModeResolver.description") // "" | tostring) as $res
  | {
    policy: v("SBFResolvedDisplayContentMode.prevailingPolicy"),
    hinge: ($res | capture("SBFHingeState: (?<s>\\.[A-Za-z]+)\\n\\s+Position: (?<p>[0-9.]+ \\([0-9.]+°\\))")? // null),
    transitionStyle: v("SBFDisplayContentModeResolver._preferredTransitionStyle"),
    primary: (v("SBDisplayContentModeCoordinator.primaryWindowScene") | if type == "object" then .persistentIdentifier // . else . end),
    contentModes: ([.[] | select(.api == "SBDisplayContentModeCoordinator.displayContentModeForWindowScene") | .value | select(type == "object") | {(.scene | tostring): .value}] | add),
    backlight_cover: v("SBWindowScene[cover].backlightController.backlightState"),
    backlight_inner: v("SBWindowScene[inner].backlightController.backlightState"),
    screenIsOn: [v("SBWindowScene[cover].backlightController.screenIsOn"), v("SBWindowScene[inner].backlightController.screenIsOn")],
    io_cover: v("SBWindowScene[cover].interfaceOrientation"),
    io_inner: v("SBWindowScene[inner].interfaceOrientation"),
    screen_cover: v("SBWindowScene[cover].screen.bounds"),
    screen_inner: v("SBWindowScene[inner].screen.bounds"),
    uiLocked: v("SBLockScreenManager.sharedInstance.isUILocked")
  }'
