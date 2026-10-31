#!/bin/zsh
# smoke.zsh <udid|name> [out.json]
#
# End-to-end check of sim.zsh / probe.zsh / posture.zsh: for closed, book and open, drive
# the posture, then run probes/smoke-springboard.lldb in SpringBoard ([UIScreen screens]
# and SBDisplayContentModeCoordinator state) and collect everything into one JSON file in
# the README's record format (default ../smoke.json). Transcripts go to ../raw/smoke/.
set -euo pipefail
here=${0:a:h}
root=${here:h}
jq=/opt/homebrew/bin/jq

udid=$($here/sim.zsh udid ${1:?udid or name})
out=${2:-$root/smoke.json}
rawdir=$root/raw/smoke
mkdir -p $rawdir
work=$(mktemp -d -t smoke); trap 'rm -rf "$work"' EXIT

runtime=$(xcrun simctl list runtimes -j | $jq -c '.runtimes[] | select(.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-1") | {identifier, version, buildversion}')
device=$(xcrun simctl list devices -j | $jq -c --arg u $udid '.devices[] | .[] | select(.udid == $u) | {name, udid, deviceTypeIdentifier}')
xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')

for posture in closed book open; do
  POSTURE_OUT=$rawdir $here/posture.zsh $udid $posture > $work/$posture-posture.json || {
    print -u2 "smoke.zsh: posture $posture did not verify"; cat $work/$posture-posture.json >&2 }
  $here/probe.zsh $udid SpringBoard $root/probes/smoke-springboard.lldb $rawdir/$posture-springboard.txt
  grep -E '^\{"(records|orientation)"' $rawdir/$posture-springboard.txt > $work/$posture-records.json || {
    print -u2 "smoke.zsh: no JSON in $rawdir/$posture-springboard.txt"; exit 1 }
done

$jq -n \
  --argjson runtime "$runtime" --argjson device "$device" --arg xcode "$xcode" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)" \
  --slurpfile pc $work/closed-posture.json --slurpfile pb $work/book-posture.json --slurpfile po $work/open-posture.json \
  --slurpfile rc $work/closed-records.json --slurpfile rb $work/book-records.json --slurpfile ro $work/open-records.json '
  def orient: {"1": "portrait", "2": "portraitUpsideDown", "3": "landscapeLeft", "4": "landscapeRight"}[tostring] // "unknown";
  def tag($posture; $r): $r.records | map({api, kind, process: "SpringBoard", posture: $posture,
      orientation: ($r.orientation | orient), call, value, error});
  {
    meta: {
      domain: "smoke", runtime: $runtime, device: $device, xcode: $xcode, host: $host, date: $date,
      posture_mechanism: "SBDisplayToolServiceCoordinator performDisplaySwapWithSettings: (tools/posture.zsh)",
      postures: [$pc[0], $pb[0], $po[0]]
    },
    records: (tag("closed"; $rc[0]) + tag("book"; $rb[0]) + tag("open"; $ro[0]))
  }' > $out
print -- "smoke.zsh: $($jq '.records | length' $out) records -> $out"
$jq -r '.meta.postures[] | "\(.posture): lit=\(.screenshots.lit_panel) expected=\(.expected_lit_panel) ok=\(.ok) hinge=\(.springboard.hinge_state) \(.springboard.position) policy=\(.springboard.prevailing_policy) primary=\(.springboard.primary_on)"' $out
