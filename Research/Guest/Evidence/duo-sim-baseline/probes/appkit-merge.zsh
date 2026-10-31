#!/bin/zsh
# appkit-merge.zsh <udid|name> [out.json]
# Merge raw/appkit/<app>/<scenario>/records.jsonl (written by probes/appkit-run.zsh) into
# appkit.json in the README's record format. Extra per-record fields: scenario,
# device_orientation_requested (the -deviceOrientation passed to posture.zsh), transcript.
set -euo pipefail
here=${0:a:h}
root=${here:h}
jq=/opt/homebrew/bin/jq
udid=$($root/tools/sim.zsh udid ${1:?udid})
out=${2:-$root/appkit.json}
work=$(mktemp -d -t appkitmerge); trap 'rm -rf "$work"' EXIT

files=()
for app in Preferences MobileSafari VPAppKitProbe; do
  for scenario in launch-closed launch-open launch-settled orientations; do
    f=$root/raw/appkit/$app/$scenario/records.jsonl
    [[ -s $f ]] && files+=($f)
  done
done
cat $files > $work/records.jsonl
postures=( $root/raw/appkit/*/*/[0-9][0-9]-*.posture.json(N) )
for p in $postures; do
  [[ -s $p ]] || continue
  $jq -c --arg f "${p#$root/}" '. + {file: $f}' $p
done > $work/postures.jsonl

runtime=$(xcrun simctl list runtimes -j | $jq -c '.runtimes[] | select(.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-1") | {identifier, version, buildversion}')
device=$(xcrun simctl list devices -j | $jq -c --arg u $udid '.devices[] | .[] | select(.udid == $u) | {name, udid, deviceTypeIdentifier}')
xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')

$jq -n --argjson runtime "$runtime" --argjson device "$device" --arg xcode "$xcode" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)" \
  --slurpfile recs $work/records.jsonl --slurpfile post $work/postures.jsonl '
  {
    meta: {
      domain: "appkit", runtime: $runtime, device: $device, xcode: $xcode, host: $host, date: $date,
      posture_mechanism: "SBDisplayToolServiceCoordinator performDisplaySwapWithSettings: (tools/posture.zsh); -deviceOrientation= sets the device orientation that SpringBoard and the app see",
      apps: {
        Preferences: "com.apple.Preferences",
        MobileSafari: "com.apple.mobilesafari",
        VPAppKitProbe: "com.vphone.duobaseline.appkitprobe: minimal ObjC UIKit app, all 4 orientations in Info.plist, one window scene, UIDeviceFamily 1; source src/appkit/probe-app (build.zsh); logs every scene/geometry/trait/screen/hinge callback to Documents/events.jsonl"
      },
      scenarios: {
        "launch-closed": "closed (portrait) -> launch app -> book (anchored at closed) -> open (from book) -> closed",
        "launch-open": "open (portrait) -> launch app -> book (from open, no anchor) -> closed -> open",
        "launch-settled": "closed -> launch, probe 15 s later; open -> launch, probe 15 s later. The launch-closed and launch-open launch snapshots are taken 6 s after simctl launch: Preferences and MobileSafari open(launched-open) were still foregroundInactive there (activationState 1, deactivationReasons 32, view bounds 0x0); use the settled15s snapshots as the steady state",
        "orientations": "open portrait -> launch -> open landscapeLeft, landscapeRight -> book landscapeLeft (anchored at closed) -> book landscapeRight (no anchor) -> closed landscapeLeft, landscapeRight -> closed portrait"
      },
      record_fields: "README record format plus: scenario, device_orientation_requested (posture.zsh -deviceOrientation), transcript (probe transcript). orientation = the app window scene effectiveGeometry.interfaceOrientation. posture = posture plus the path that led there, e.g. book(after-closed); open(launched-open) = the app was launched in that posture",
      enums: {
        UIInterfaceOrientation: "1 portrait, 2 portraitUpsideDown, 3 landscapeLeft, 4 landscapeRight",
        UIDeviceOrientation: "1 portrait, 2 portraitUpsideDown, 3 landscapeLeft, 4 landscapeRight, 5 faceUp, 6 faceDown",
        UIInterfaceOrientationMask: "2 portrait, 4 upsideDown, 8 landscapeRight, 16 landscapeLeft; 26 = all but upside down, 30 = all",
        UIUserInterfaceSizeClass: "1 compact, 2 regular",
        UISceneActivationState: "-1 unattached, 0 foregroundActive, 1 foregroundInactive, 2 background",
        UIHingeStatus: "0 unknown, 1 closed, 2 partiallyOpen, 3 fullyOpen; UIHinge.angle is in radians"
      },
      postures: $post
    },
    records: [ $recs[] | {api, kind, process, posture, orientation, call, value, error, scenario, device_orientation_requested, transcript} ]
  }' > $out
print -- "appkit-merge.zsh: $($jq '.records | length' $out) records, $($jq '.meta.postures | length' $out) posture runs -> $out"
