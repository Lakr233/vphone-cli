#!/bin/zsh
# merge.zsh: build ../../display.json from states/manifest.jsonl and the per-state probe transcripts.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
jq=/opt/homebrew/bin/jq
U=28D2B766-8C33-40F0-99D3-56571D6FF08A
work=$(mktemp -d -t dispmerge); trap 'rm -rf "$work"' EXIT
runtime=$(xcrun simctl list runtimes -j | $jq -c '.runtimes[] | select(.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-1") | {identifier, version, buildversion}')
device=$(xcrun simctl list devices -j | $jq -c --arg u $U '.devices[] | .[] | select(.udid == $u) | {name, udid, deviceTypeIdentifier}')
xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')
: > $work/records.jsonl; : > $work/postures.jsonl
while IFS= read -r line; do
  seq=$(print -r -- $line | $jq -r .seq); posture=$(print -r -- $line | $jq -r .posture); orient=$(print -r -- $line | $jq -r .requested_orientation)
  $jq -c --arg seq $seq --argjson m "$line" '{seq: $seq, capture: $m, posture_driver: .}' $here/states/$seq-posture.json >> $work/postures.jsonl
  for p in backboardd springboard safari; do
    f=$here/states/$seq-$p.txt
    [[ -e $f ]] || continue
    proc=$p; [[ $p == springboard ]] && proc=SpringBoard; [[ $p == safari ]] && proc=MobileSafari
    grep '^{"' $f | $jq -c --arg proc $proc --arg posture $posture --arg orient $orient --arg seq $seq '
      def pubscreen: ["bounds","nativeBounds","scale","nativeScale","coordinateSpace","fixedCoordinateSpace","traitCollection","maximumFramesPerSecond","currentMode","preferredMode","availableModes","mirroredScreen","brightness","wantsSoftwareDimming","overscanCompensation","overscanCompensationInsets","applicationFrame","isCaptured","calibratedLatency","currentEDRHeadroom","potentialEDRHeadroom","referenceDisplayModeStatus","description","class","displayIdentity_never"];
      .records[] | . as $r | ($r.api | split(".")) as $parts |
      {api, kind: (if ($parts[0] == "UIScreen" and ($parts | length) == 2 and (pubscreen | index($parts[1]))) then "public"
                   elif ($parts[0] == "UITraitCollection" and ($parts[1] | startswith("_") | not)) then "public"
                   else .kind end),
       process: $proc, posture: $posture, orientation: $orient, call, value, error, capture: $seq}' >> $work/records.jsonl
  done
done < $here/states/manifest.jsonl
$jq -n \
  --argjson runtime "$runtime" --argjson device "$device" --arg xcode "$xcode" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)" \
  --slurpfile pos $work/postures.jsonl --slurpfile recs $work/records.jsonl '
  {
    meta: {
      domain: "display", runtime: $runtime, device: $device, xcode: $xcode, host: $host, date: $date,
      posture_mechanism: "SBDisplayToolServiceCoordinator performDisplaySwapWithSettings: (tools/posture.zsh)",
      capture_order: [$pos[] | .seq],
      notes: [
        "posture: the posture.zsh posture plus the path that led to it, e.g. open(after-closed). closed(boot) is the state right after boot, before any swap. +safari: MobileSafari was the foreground app (captures 08-10, 12, 13); captures 01-07 and 11 are on the home screen. 11-reboot is a second boot of the same simulator (shutdown + boot after capture 10-open-P); display UUIDs change on every boot.",
        "orientation: for captures 01-07 the device was never rotated (portrait; SpringBoard scenes are portrait-only). For 08-10, 12 and 13 it is the -deviceOrientation option passed to the swap tool; the swap tool option landscapeLeft produced UIDeviceOrientation 4 and interface orientation 4 (UIInterfaceOrientationLandscapeLeft) in MobileSafari, landscapeRight produced 3/3 on the cover; on the inner display the app scene is rotated a quarter turn from that: portrait gives interface 4, landscapeLeft 1, landscapeRight 2 (see the MobileSafari and SpringBoard UIApplication.connectedScenes.summary records). MobileSafari records (process MobileSafari) show what the app saw. SpringBoard primary scenes on the cover stay interfaceOrientation 1; the inner primary scene follows the app (1, 2 or 4) - with device portrait it reported 1 right after an unfold from closed (09-book-P, 12-open-P) and 4 when the swap started on the inner (10-open-P, 13-book-P).",
        "capture: extra field, the raw/display/states/<capture>-<process>.txt transcript the record came from.",
        "BKOrientationManager raw device orientation: 0 in captures 01-07; later captures follow BKSHIDServicesSetDeviceOrientationForAutomation calls made while finding a working rotation method (last call: 1). The swap tool -deviceOrientation does not change it. After the reboot (11-13) it is 0 again.",
        "Volatile values (differ between any two reads): CAWindowServerDisplay nextWakeupTime/previousVBL/vblDelta, contextIdAtPosition, pointer addresses inside description strings, BKDigitizerTouchStreamClient creationTime, BKDisplayBrightnessController freeze times."
      ],
      postures: [$pos[]]
    },
    records: $recs
  }' > $root/display.json
print -- "merge: $($jq '.records | length' $root/display.json) records -> $root/display.json"
