#!/bin/zsh
# appkit-run.zsh <udid|name> <app> [scenario ...]
#
# appkit domain driver: what a foreground app sees (UIKit geometry, scene migration).
#   app:       Preferences | MobileSafari | VPAppKitProbe
#   scenarios: launch-closed  launch closed (cover), unfold book, open, fold closed
#              launch-open    launch open (inner), fold to book (no anchor), closed, unfold open
#              launch-settled closed and open launches probed 15 s after launch (the others: 6 s)
#              orientations   landscapeLeft/Right in open, book and closed, then portrait closed
# Each state: tools/posture.zsh, then probes/appkit-scenes.lldb in the app, screenshots of both
# panels, and (VPAppKitProbe only) the app's own callback log since the posture change started.
# Output: raw/appkit/<app>/<scenario>/NN-<label>.{txt,json,...} and one tagged record file
# raw/appkit/<app>/<scenario>/records.jsonl (merged into appkit.json by probes/appkit-merge.zsh).
set -euo pipefail
here=${0:a:h}
root=${here:h}
tools=$root/tools
jq=/opt/homebrew/bin/jq
udid=$($tools/sim.zsh udid ${1:?udid})
app=${2:?app}; shift 2
case $app in
  Preferences) bundle=com.apple.Preferences ;;
  MobileSafari) bundle=com.apple.mobilesafari ;;
  VPAppKitProbe) bundle=com.vphone.duobaseline.appkitprobe ;;
  *) print -u2 "unknown app $app"; exit 2 ;;
esac
scenarios=("$@"); (( ${#scenarios} )) || scenarios=(launch-closed launch-open orientations)
events() { print -- "$(xcrun simctl get_app_container $udid $bundle data)/Documents/events.jsonl" }

# drive <label> <posture args...>: posture.zsh with one retry after the 10 s testing lock.
drive() {
  local label=$1; shift
  local rc=0
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  POSTURE_ANCHOR=${anchor:-} POSTURE_OUT=$dir/posture $tools/posture.zsh $udid "$@" > $dir/$n-$label.posture.json 2> $dir/$n-$label.posture.err || rc=$?
  if (( rc == 3 )); then
    print -u2 "appkit-run: $label did not verify; status, wait out the lock, retry"
    POSTURE_OUT=$dir/posture $tools/posture.zsh $udid status > $dir/$n-$label.status-before-retry.json 2>/dev/null || true
    sleep 11; rc=0
    POSTURE_ANCHOR=${anchor:-} POSTURE_OUT=$dir/posture $tools/posture.zsh $udid "$@" > $dir/$n-$label.posture.json 2>> $dir/$n-$label.posture.err || rc=$?
  fi
  print -u2 "appkit-run: [$app/$scenario] $n $label posture rc=$rc $($jq -c '{ok, hinge: .springboard.hinge_state, lit: .screenshots.lit_panel}' $dir/$n-$label.posture.json 2>/dev/null)"
  last_post=$dir/$n-$label.posture.json; anchor=""
  sleep 2
}

# snap <posture-label> <device-orientation-requested>
snap() {
  local plabel=$1 devo=$2 base=$dir/$n-${1//[()]/_}
  sleep 1
  $tools/probe.zsh $udid $app $here/appkit-scenes.lldb $base.txt 2>> $dir/probe.err || print -u2 "appkit-run: probe rc=$?"
  local shots; shots=$($tools/sim.zsh shot $udid $dir/shots $n-${1//[()]/_})
  local line; line=$(grep -E '^\{"(records|orientation)"' $base.txt || true)
  [[ -n $line ]] || { print -u2 "appkit-run: no JSON in $base.txt"; line='{"orientation":0,"records":[{"api":"harness.probe","kind":"private","call":"probes/appkit-scenes.lldb","value":null,"error":"probe produced no JSON; see transcript"}]}' }
  print -r -- "$line" > $base.json
  local evjson='[]'
  if [[ $app == VPAppKitProbe && -n ${t0:-} ]]; then
    evjson=$($jq -c --argjson t0 $t0 -s '[ .[] | select(.t + 978307200 >= $t0) |
      {t_rel: ((.t + 978307200 - $t0) * 1000 | round / 1000), event, detail,
       sceneBounds: .snapshot.sceneBounds, geometryBounds: .snapshot.geometryBounds, interfaceOrientation: .snapshot.interfaceOrientation,
       hsc: .snapshot.hsc, vsc: .snapshot.vsc, screen: .snapshot.screen, screenIsMain: .snapshot.screenIsMain, screens: (.snapshot.screens | length),
       screenBounds: .snapshot.screenBounds, windowSafeArea: .snapshot.windowSafeArea, deviceOrientation: .snapshot.deviceOrientation,
       activationState: .snapshot.activationState} ]' "$(events)")
  fi
  $jq -c -n --argjson p "$(cat $base.json)" --arg process $app --arg posture "$plabel" --arg devo "$devo" --arg scenario $scenario \
    --arg shots "$shots" --argjson post "$( [[ -n ${last_post:-} && -s $last_post ]] && cat $last_post || print null)" --arg t0 "${t0:-}" --argjson ev "$evjson" \
    --arg transcript "${base#$root/}.txt" --arg rootp "$root/" '
    def orient: {"1": "portrait", "2": "portraitUpsideDown", "3": "landscapeLeft", "4": "landscapeRight"}[tostring] // "unknown";
    def tag: . + {process: $process, posture: $posture, orientation: ($p.orientation | orient),
                  device_orientation_requested: $devo, scenario: $scenario, transcript: $transcript};
    ($p.records[] | {api, kind, process: null, posture: null, orientation: null, call, value, error} | tag),
    ({api: "harness.postureDriver", kind: "private", call: "tools/posture.zsh JSON for the posture change before this probe (null: no posture change, e.g. after a relaunch)", value: $post, error: null} | tag),
    ({api: "harness.screenshots", kind: "private", call: "tools/sim.zsh shot (display 1 = cover, display 3 = inner)",
      value: ($shots | split("\n") | map(split(" ") | {path: (.[0] | sub($rootp; "")), state: .[1]})), error: null} | tag),
    (if $app_is_probe then
      {api: "VPAppKitProbe.callbackSequence", kind: "public",
       call: "UIWindowSceneDelegate / UISceneDelegate / UIViewController / UIHingeInteraction / NSNotification callbacks logged by src/appkit/probe-app since the posture change started (t_rel seconds after posture.zsh was invoked; the swap itself begins after its lldb detach, ~3-4 s later)",
       value: $ev, error: (if ($ev | length) == 0 then "no callbacks since the posture change started" else null end)} | tag
     else empty end)
  ' --argjson app_is_probe $([[ $app == VPAppKitProbe ]] && print true || print false) >> $dir/records.jsonl
  print -u2 "appkit-run: [$app/$scenario] $n snap $plabel ($devo): $($jq -c '[.orientation, (.records|length)]' $base.json) $(print -- $shots | awk '{printf "%s ", $2}')"
  t0=""; last_post=""
  n=$(printf %02d $((10#$n + 1)))
}

relaunch() {
  xcrun simctl terminate $udid $bundle >/dev/null 2>&1 || true
  sleep 1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  xcrun simctl launch $udid $bundle > /dev/null
  sleep ${1:-5}
}

for scenario in $scenarios; do
  dir=$root/raw/appkit/$app/$scenario
  rm -rf $dir; mkdir -p $dir
  n=01; t0=""
  case $scenario in
    launch-closed)
      drive closed closed -deviceOrientation=portrait
      relaunch;                                    snap "closed(launched-closed)" portrait
      drive book book;                             snap "book(after-closed)" portrait
      anchor=none drive open open;         snap "open(after-book)" portrait
      drive closed closed;                         snap "closed(after-open)" portrait ;;
    launch-open)
      drive open open -deviceOrientation=portrait
      relaunch;                                    snap "open(launched-open)" portrait
      anchor=none drive book book;         snap "book(after-open)" portrait
      drive closed closed;                         snap "closed(after-book)" portrait
      drive open open;                             snap "open(after-closed)" portrait ;;
    orientations)
      drive open open -deviceOrientation=portrait
      relaunch;                                    snap "open(launched-open)" portrait
      for o in landscapeLeft landscapeRight; do
        drive open open -deviceOrientation=$o;     snap "open" $o
      done
      drive book book -deviceOrientation=landscapeLeft;                        snap "book(after-closed)" landscapeLeft
      anchor=none drive book book -deviceOrientation=landscapeRight;   snap "book" landscapeRight
      drive closed closed -deviceOrientation=landscapeLeft;                    snap "closed(after-book)" landscapeLeft
      drive closed closed -deviceOrientation=landscapeRight;                   snap "closed" landscapeRight
      drive closed closed -deviceOrientation=portrait;                         snap "closed" portrait ;;
    launch-settled)
      drive closed closed -deviceOrientation=portrait
      relaunch 15;                                 snap "closed(launched-closed,settled15s)" portrait
      drive open open
      relaunch 15;                                 snap "open(launched-open,settled15s)" portrait ;;
    *) print -u2 "unknown scenario $scenario"; exit 2 ;;
  esac
  [[ $app == VPAppKitProbe ]] && cp "$(events)" $dir/events.jsonl
done
