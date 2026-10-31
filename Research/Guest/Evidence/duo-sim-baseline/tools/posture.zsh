#!/bin/zsh
# posture.zsh <udid|name> closed|book|open [swap options]
# posture.zsh <udid|name> angle <degrees> [swap options]
# posture.zsh <udid|name> status
# posture.zsh <udid|name> unlock
#
# Drives the iPhone Duo simulator's fold through SpringBoard's own display tool — the
# path Apple's internal `suiatool` swap command takes — then verifies it:
#
#   1. In SpringBoard (over lldb), SBFDisplayToolSwapSettingsFromArguments() parses
#      "-position=<closed|book|open|0.0-1.0>" plus any swap options given here, and
#      -[SBDisplayToolServiceCoordinator performDisplaySwapWithSettings:completion:] runs
#      the synthetic hinge sweep. The sweep is pushed through SBFDevicePoseProvider, so
#      SBDisplayContentModeCoordinator / SBFDisplayContentModeResolver resolve the displays
#      exactly as for a real fold. (The XPC front door, SBSDisplayToolService, needs the
#      com.apple.springboard.sbdisplay.service entitlement, which no simulator binary has.)
#   2. After the sweep settles: one SpringBoard readback (the resolver description: hinge
#      state, angle, prevailing policy, per-display applied/target content mode) and
#      screenshots of display 1 (cover) and display 3 (inner), each classified lit/dark.
#
# Swap options are passed to SBFDisplayToolSwapSettingsFromArguments verbatim:
#   -duration=<s> (0 = instant "yoinking" swap)  -deviceOrientation=<portrait|...>
#   -fade | -continuous   (-wait is accepted but irrelevant: this script polls)
# positions: closed = 0.0 (0°), book = 0.5556 (100°), open = 1.0 (180°), angle = deg/180.
#
# The hinge regions have hysteresis: where a sweep stops moves the closed/partiallyOpen
# boundary (at rest at 0° it is 0.47 ≈ 85°; after stopping at 60° it is 0.63 ≈ 113°, so a
# later "book" sweep from 60° does not reach it and stays on the cover). So `book` first
# anchors at closed with an instant swap and then sweeps open to 100° — the "book from
# closed swaps cover to inner" case of the tool's own help. POSTURE_ANCHOR overrides this:
#   POSTURE_ANCHOR=closed|open   instant swap there first (any posture)
#   POSTURE_ANCHOR=none          sweep from wherever the hinge is now
# Defaults: book → closed; closed, open, angle → none.
#
# Output: one JSON object on stdout; artifacts in $POSTURE_OUT (default ../raw/posture):
#   <stamp>-<label>-swap.txt, -readback.txt (+ .raw.txt), -d1.png, -d3.png, .json
# Exit status: 0 when the lit panel matches the posture (closed → cover, book/open →
# inner; angle and status are not judged), 3 on a mismatch, 1 on errors.
set -euo pipefail
here=${0:a:h}
jq=/opt/homebrew/bin/jq

(( $# >= 2 )) || { sed -n '2,38p' ${0:a} | sed 's/^# \{0,1\}//'; exit 2 }
udid=$($here/sim.zsh udid $1); shift
verb=$1; shift
out=${POSTURE_OUT:-${here:h}/raw/posture}
mkdir -p $out
stamp=$(date +%Y%m%d-%H%M%S)

case $verb in
  closed|book|open) position=$verb label=$verb ;;
  angle)
    deg=${1:?angle needs degrees}; shift
    position=$(awk -v d=$deg 'BEGIN { p = d / 180; if (p < 0) p = 0; if (p > 1) p = 1; printf "%.6f", p }')
    label="angle${deg}" ;;
  status|unlock) position="" label=$verb ;;
  *) print -u2 "posture.zsh: unknown posture '$verb'"; exit 2 ;;
esac
extra=("$@")
base=$out/$stamp-$label

# Shared lldb fragments. Locals carry a vp prefix: short names collide with symbols in the
# shared cache ("names", "m", ...), and lldb persistent $variables are unreliable here.
coord='NSObject *vpSvc = [[UIApplication sharedApplication] valueForKey:@"_displayToolService"]; NSObject *vpCoord = [vpSvc valueForKey:@"_swapCoordinator"];'

if [[ $verb == unlock ]]; then
  $here/probe.zsh $udid SpringBoard - $base-unlock.txt <<EOF
expr -l objc -O -- $coord ((void(*)(id,SEL))objc_msgSend)(vpCoord, @selector(unlockForTesting)); @"unlocked"
EOF
  cat $base-unlock.txt; exit 0
fi

anchor=${POSTURE_ANCHOR:-$( [[ $verb == book ]] && print closed || print none )}
if [[ -n $position && $anchor != none ]]; then
  [[ $anchor == closed || $anchor == open ]] || { print -u2 "posture.zsh: bad POSTURE_ANCHOR=$anchor"; exit 2 }
  POSTURE_ANCHOR=none POSTURE_OUT=$out/anchor $0 $udid $anchor -duration=0 > /dev/null || true
fi

if [[ -n $position ]]; then
  objc_args="@\"-position=$position\""
  for a in "${extra[@]}"; do objc_args+=", @\"$a\""; done
  started=0
  for attempt in 1 2 3; do
    $here/probe.zsh $udid SpringBoard - $base-swap.txt <<EOF
expr -l objc -O -- struct VPSwapSettings { long long state; double duration; long long deviceOrientation; long long profileOverride; BOOL waitForCompletion; long long targetMode; double targetHingePosition; double lockedForTestingUntil; }; $coord struct VPSwapSettings vpS; memset(&vpS, 0, sizeof(vpS)); NSError *vpErr = nil; BOOL vpParsed = ((BOOL(*)(id, struct VPSwapSettings *, NSError **))dlsym(RTLD_DEFAULT, "SBFDisplayToolSwapSettingsFromArguments"))(@[$objc_args], &vpS, &vpErr); BOOL vpStarted = vpParsed ? ((BOOL(*)(id, SEL, struct VPSwapSettings, id))objc_msgSend)(vpCoord, @selector(performDisplaySwapWithSettings:completion:), vpS, nil) : NO; [NSString stringWithFormat:@"parsed=%d started=%d targetMode=%lld targetHingePosition=%.6f duration=%.3f profileOverride=%lld deviceOrientation=%lld error=%@", vpParsed, vpStarted, vpS.targetMode, vpS.targetHingePosition, vpS.duration, vpS.profileOverride, vpS.deviceOrientation, vpErr]
EOF
    if grep -q 'started=1' $base-swap.txt; then started=1; break; fi
    grep -q 'parsed=0' $base-swap.txt && { cat $base-swap.txt >&2; exit 1 }
    sleep 3   # "a display swap is already in flight"
  done
  (( started )) || { print -u2 "posture.zsh: swap did not start"; cat $base-swap.txt >&2; exit 1 }
  sleep ${POSTURE_SETTLE:-3}
fi

# Readback; repeat while the coordinator is still sweeping (state != 0).
for attempt in 1 2 3 4 5 6; do
  $here/probe.zsh $udid SpringBoard - $base-readback.txt <<EOF
expr -l objc -O -- $coord Ivar vpIv = class_getInstanceVariable([vpCoord class], "_currentSettings"); long long *vpP = (long long *)((char *)(__bridge void *)vpCoord + ivar_getOffset(vpIv)); [NSString stringWithFormat:@"coordinator state=%lld instantSwapIsRunning=%@ replayIsRunning=%@", vpP[0], [vpCoord valueForKey:@"_instantSwapIsRunning"], [vpCoord valueForKey:@"_replayIsRunning"]]
expr -l objc -O -- [[[[UIApplication sharedApplication] valueForKey:@"_displayToolService"] valueForKey:@"_displayContentModeCoordinator"] valueForKey:@"_resolver"]
EOF
  grep -q 'coordinator state=0 instantSwapIsRunning=0 replayIsRunning=0' $base-readback.txt && break
  sleep 2
done

shots=$($here/sim.zsh shot $udid $out $stamp-$label)
d1=$(print -- $shots | awk 'NR == 1 { print $2 }')
d3=$(print -- $shots | awk 'NR == 2 { print $2 }')

rb=$base-readback.txt
field() { awk -v pat="$1" 'index($0, pat) { sub(".*" pat, ""); print; exit }' $rb }
hinge=$(field 'SBFHingeState: .')
pos_line=$(awk '/^ +Position: / { sub(/^ +Position: /, ""); print; exit }' $rb)
policy=$(field 'Prevailing Policy: ' | tr -d ';')
primary=$(awk '/prevailing, primary on/ { sub(".*primary on \\.", ""); sub(";.*", ""); print; exit }' $rb)
displays=$(awk '
  /<SBFDisplayProxy:/ { id = $0; sub(".*identifier: ", "", id); sub(">.*", "", id) }
  /surfaceType: \./ { s = $2; sub("^\\.", "", s); sub(";", "", s) }
  /applied: \./ { a = $2; sub("^\\.", "", a); sub(";", "", a) }
  /target: \./ { t = $2; sub("^\\.", "", t); sub(";", "", t); printf "%s %s %s %s\n", id, s, a, t }
' $rb)
settled=$(grep -q 'coordinator state=0 instantSwapIsRunning=0 replayIsRunning=0' $rb && print true || print false)

expect=""
case $verb in closed) expect=cover ;; book|open) expect=inner ;; esac
lit_panel=none
[[ $d1 == lit && $d3 != lit ]] && lit_panel=cover
[[ $d3 == lit && $d1 != lit ]] && lit_panel=inner
[[ $d1 == lit && $d3 == lit ]] && lit_panel=both

$jq -n \
  --arg udid $udid --arg posture $verb --arg label $label --arg position "$position" \
  --arg extra "${extra[*]}" --arg hinge "$hinge" --arg pos "$pos_line" --arg policy "$policy" \
  --arg primary "$primary" --arg displays "$displays" --arg d1 $d1 --arg d3 $d3 \
  --arg lit $lit_panel --arg expect "$expect" --argjson settled $settled \
  --arg swap "$( [[ -e $base-swap.txt ]] && grep -E '^parsed=' $base-swap.txt || true )" \
  --arg base "$base" --arg anchor "$( [[ -n $position ]] && print $anchor || print none )" '
  {
    udid: $udid, posture: $posture, label: $label, anchor: $anchor,
    requested_position: (if $position == "" then null else $position end),
    swap_options: $extra, swap_result: (if $swap == "" then null else $swap end),
    settled: $settled,
    springboard: {
      hinge_state: $hinge, position: $pos, prevailing_policy: $policy, primary_on: $primary,
      displays: ($displays | split("\n") | map(select(length > 0) | split(" ") |
                 {identifier: .[0], surface: .[1], applied: .[2], target: .[3]}))
    },
    screenshots: {display1_cover: $d1, display3_inner: $d3, lit_panel: $lit},
    expected_lit_panel: (if $expect == "" then null else $expect end),
    ok: (if $expect == "" then null else ($expect == $lit) end),
    artifacts: $base
  }' | tee $base.json

if [[ -n $expect && $expect != $lit_panel ]]; then exit 3; fi
