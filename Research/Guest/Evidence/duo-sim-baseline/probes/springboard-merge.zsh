#!/bin/zsh
# springboard-merge.zsh [out.json]
#
# Merge the steps recorded by springboard-run.zsh (raw/springboard/steps) into
# springboard.json in the README record format. The step list below fixes the order, the
# "posture" label of each step (posture + how it was reached + device orientation / app),
# and is copied into meta.steps together with each step's posture.zsh JSON.
#
# Normalisation: Objective-C object addresses (0x followed by 6+ hex digits) in string
# values are replaced by "0x*" so that values can be compared with vphone-duo; the raw
# transcripts in raw/springboard/steps keep them.
set -euo pipefail
here=${0:a:h}
root=${here:h}
jq=/opt/homebrew/bin/jq
out=${1:-$root/springboard.json}
steps=$root/raw/springboard/steps
sim=048B820B-86E8-43F9-9DF1-F76802AD6DB8

# step-label | posture label | note
table=(
  "closed-boot|closed(boot)|first readback after boot; never unfolded; home screen"
  "book-after-closed|book(after-closed)|posture.zsh book: instant anchor at closed, sweep 0->100 deg"
  "open-after-book|open(after-book)|sweep 100->180 deg"
  "closed-after-open|closed(after-open)|fold: sweep 180->0 deg"
  "open-after-closed|open(after-closed)|unfold: sweep 0->180 deg"
  "book-after-open|book(after-open)|POSTURE_ANCHOR=none: sweep 180->100 deg"
  "closed-after-book|closed(after-book)|fold: sweep 100->0 deg"
  "closed-landscapeLeft|closed[device:landscapeLeft]|-deviceOrientation=landscapeLeft, home screen"
  "closed-landscapeRight|closed[device:landscapeRight]|-deviceOrientation=landscapeRight, home screen"
  "closed-portraitUpsideDown|closed[device:portraitUpsideDown]|-deviceOrientation=portraitUpsideDown, home screen"
  "closed-portrait|closed[device:portrait]|back to portrait, home screen"
  "open-landscapeLeft|open[device:landscapeLeft]|unfold from closed with -deviceOrientation=landscapeLeft, home screen; SpringBoard crashed ~50 s later during the next step (raw/springboard/crash)"
  "open-portraitUpsideDown|open[device:portraitUpsideDown](after SpringBoard relaunch)|first step on the relaunched SpringBoard (pid changed); home screen"
  "open-portrait|open[device:portrait](after SpringBoard relaunch)|home screen"
  "open-landscapeLeft-r2|open[device:landscapeLeft](after SpringBoard relaunch)|home screen, POSTURE_SETTLE=25"
  "open-landscapeRight|open[device:landscapeRight](after SpringBoard relaunch)|home screen, POSTURE_SETTLE=25"
  "book-landscapeLeft|book[device:landscapeLeft](after SpringBoard relaunch)|anchor closed, sweep to 100 deg in landscapeLeft"
  "book-landscapeRight|book[device:landscapeRight](after SpringBoard relaunch)|anchor closed, sweep to 100 deg"
  "book-portraitUpsideDown|book[device:portraitUpsideDown](after SpringBoard relaunch)|anchor closed, sweep to 100 deg"
  "book-portrait|book[device:portrait](after SpringBoard relaunch)|anchor closed, sweep to 100 deg"
  "closed-after-book-r2|closed(after-book)(after SpringBoard relaunch)|fold, portrait, home screen"
  "closed-safari-landscapeLeft|closed[device:landscapeLeft,app:MobileSafari]|cover rotation with a landscape-capable app"
  "closed-safari-landscapeRight|closed[device:landscapeRight,app:MobileSafari]|"
  "closed-safari-portrait|closed[device:portrait,app:MobileSafari](after landscapeRight)|"
  "open-safari-landscapeLeft|open[device:landscapeLeft,app:MobileSafari]|"
  "open-safari-landscapeRight|open[device:landscapeRight,app:MobileSafari]|"
  "open-safari-portraitUpsideDown|open[device:portraitUpsideDown,app:MobileSafari]|"
  "open-safari-portrait|open[device:portrait,app:MobileSafari](after portraitUpsideDown)|"
  "closed-safari-portrait-initial|closed[device:portrait,app:MobileSafari](just launched)|re-captured after the lock tests (the first capture was overwritten): simctl launch com.apple.mobilesafari on the cover"
  "open-safari-portrait-unfold|open[device:portrait,app:MobileSafari](after-closed)|re-captured after the lock tests: unfold with Safari"
  "open-before-autolock|open(home screen, before auto-lock)|Safari terminated; status only"
  "open-autolocked|open(auto-locked)|idle-timer disable assertion invalidated, waited 80 s"
  "closed-after-autolock-open|closed(after auto-lock in open)|fold while auto-locked"
  "closed-after-autolock-open-wake|closed(after auto-lock in open, after simulated home press)|-[SpringBoard _simulateHomeButtonPressWithCompletion:nil]: no effect (still AOD, locked)"
  "closed-after-autolock-open-lockwake|closed(after auto-lock in open, woken by lock button)|-[SpringBoard _simulateLockButtonPress] wakes the cover to the lock screen"
  "book-before-autolock|book(home screen, before auto-lock)|"
  "book-autolocked|book(auto-locked)|"
  "closed-after-autolock-book|closed(after auto-lock in book)|fold while auto-locked"
  "open-before-lockbutton|open(unlocked, before lock button)|auto-lock disabled again, unlocked with attemptUnlockWithPasscode:nil"
  "open-lockbutton|open(locked by lock button)|-[SpringBoard _simulateLockButtonPress]"
  "closed-after-lockbutton-open|closed(after lock button in open)|fold while locked by the lock button"
  "closed-boot2|closed(boot, second boot)|after shutdown/boot"
  "open-boot2|open(after-closed, second boot)|first unfold of the second boot, portrait"
  "open-boot2-landscapeLeft|open[device:landscapeLeft](second boot)|"
  "open-boot2-portrait|open[device:portrait](second boot, after a rotation)|"
)

runtime=$(xcrun simctl list runtimes -j | $jq -c '.runtimes[] | select(.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-1") | {identifier, version, buildversion}')
device=$(xcrun simctl list devices -j | $jq -c --arg u $sim '.devices[] | .[] | select(.udid == $u) | {name, udid, deviceTypeIdentifier}')
xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')

work=$(mktemp -d -t sbmerge); trap 'rm -rf "$work"' EXIT
print -n '[' > $work/records.json
print -n '[' > $work/meta.json
first=1
for row in $table; do
  step=${row%%|*}; rest=${row#*|}; label=${rest%%|*}; note=${rest#*|}
  [[ -e $steps/$step.records.json ]] || { print -u2 "springboard-merge: skipping missing step $step"; continue }
  (( first )) || { print -n ',' >> $work/records.json; print -n ',' >> $work/meta.json }
  first=0
  $jq -c --arg posture "$label" '
    def orient: {"0": "unknown", "1": "portrait", "2": "portraitUpsideDown", "3": "landscapeLeft", "4": "landscapeRight"}[tostring] // "unknown";
    def norm: if type == "string" then gsub("0x[0-9a-f]{6,}"; "0x*")
              elif type == "array" then map(norm)
              elif type == "object" then with_entries(.value |= norm) else . end;
    (.orientation | orient) as $o
    | [.records[] | {api, kind, process: "SpringBoard", posture: $posture, orientation: $o, call, value: (.value | norm), error}]
    | .[]' $steps/$step.records.json | $jq -s -c '.' | sed -e 's/^\[//' -e 's/\]$//' >> $work/records.json
  pj=null
  [[ -e $steps/$step.posture.json ]] && pj=$(cat $steps/$step.posture.json)
  $jq -n -c --arg step $step --arg posture "$label" --arg note "$note" --argjson pj "$pj" \
    --slurpfile r $steps/$step.records.json \
    '{step: $step, posture: $posture, note: $note, primary_scene_interfaceOrientation: $r[0].orientation, record_count: ($r[0].records | length), posture_tool: $pj}' >> $work/meta.json
done
print ']' >> $work/records.json
print ']' >> $work/meta.json

$jq -n \
  --argjson runtime "$runtime" --argjson device "$device" --arg xcode "$xcode" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)" \
  --slurpfile recs $work/records.json --slurpfile meta $work/meta.json '
  {
    meta: {
      domain: "springboard", runtime: $runtime, device: $device, xcode: $xcode, host: $host, date: $date,
      posture_mechanism: "SBDisplayToolServiceCoordinator performDisplaySwapWithSettings: (tools/posture.zsh), -deviceOrientation= for device orientation",
      probe: "probes/springboard-state.lldb (one expression; records every listed getter of the objects reached from -[SpringBoard _displayToolService])",
      orientation_field: "UIWindowScene.interfaceOrientation of SBDisplayContentModeCoordinator.primaryWindowScene (as in smoke.json); the requested device orientation is in the posture label",
      api_naming: "SBWindowScene[cover] = surfaceType 1 (SB-main, display Main), SBWindowScene[inner] = surfaceType 2 (com.apple.springboard.bringup, Unknown.main[3]); SBFDisplayProxy[cover|inner] likewise",
      normalisation: "0x[0-9a-f]{6,} replaced by 0x* in string values; raw values in raw/springboard/steps/*-state.raw.txt",
      notes: "see springboard.md",
      postures: [$meta[0][] | .posture_tool | select(. != null)],
      steps: [$meta[0][] | del(.posture_tool)]
    },
    records: $recs[0]
  }' > $out
print -- "springboard-merge: $($jq '.records | length' $out) records from $($jq '.meta.steps | length' $out) steps -> $out"
