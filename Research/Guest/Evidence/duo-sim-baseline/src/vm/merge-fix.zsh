#!/bin/zsh
# merge-fix.zsh: append the fix re-measurement (raw/vm/steps/fx-*, listed in
# raw/vm/steps/ORDER.fix-9064efca) to vm-<domain>.json. Existing records are kept as they
# are (bundle 2.14.0-local.21dc0c06, meta.vm.bundle); every appended record carries
# "bundle": "2.14.0-local.9064efca" and "step": "fx-<label>", and each fx step's rpc.json goes
# to meta.steps with its bundle. meta.fix describes the second pass. Re-running replaces the
# fx records and steps instead of duplicating them. Addresses are normalised as in vm-merge.zsh.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
jq=/opt/homebrew/bin/jq
steps=$root/raw/vm/steps
order=$steps/ORDER.fix-9064efca
bundle=2.14.0-local.9064efca
for domain in springboard display sensors chrome appkit; do
  out=$root/vm-$domain.json
  recs=$(mktemp -t fxrecs); meta=$(mktemp -t fxmeta)
  : > $recs; : > $meta
  while read -r step; do
    [[ -n $step && -e $steps/fx-$step/records.jsonl ]] || continue
    $jq -c --arg d "$domain" --arg step "fx-$step" --arg b $bundle 'select(.probe | startswith($d + "-")) | . + {step: $step, bundle: $b}
      | walk(if type == "string" then gsub("0x[0-9a-fA-F]{6,}"; "0x*") else . end)' $steps/fx-$step/records.jsonl >> $recs
    if [[ -n $($jq -c --arg d "$domain" 'select(.probe | startswith($d + "-")) | .probe' $steps/fx-$step/records.jsonl | head -1) ]]; then
      $jq -c --arg step "fx-$step" '{step: $step} + .' $steps/fx-$step/rpc.json >> $meta
    fi
  done < $order
  tmp=$(mktemp -t fxout)
  $jq --arg b $bundle --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile recs $recs --slurpfile steps $meta '
    .records = ([.records[] | select((.bundle // "") != $b)] + $recs)
    | .meta.steps = ([.meta.steps[] | select((.bundle // "") != $b)] + $steps)
    | .meta.fix = {bundle: $b, bundle_source: "branch duo-sim-align (worktree HEAD aa274dcc at measurement time, on upstream main 0499378c): V68 product-id, /product/display0+display1 panel nodes, CoreMotion relay through VPhone Host Controls",
                   date: $date, steps: "raw/vm/steps/ORDER.fix-9064efca (directories raw/vm/steps/fx-<label>)",
                   driver: "src/vm/run-fix.zsh", records: "appended records carry bundle and step fx-<label>; records without bundle are from meta.vm.bundle",
                   posture_mechanism: "vphoned display.posture / display.rotation through CoreMotion (libvphonehinge host controls -> locationd CLDeviceStateRelay); no test-automation override, so display.pose (display_pose_stale in meta.steps) is not the pose; read SBFDevicePoseProvider"}' $out > $tmp
  mv $tmp $out
  print "$out: $($jq '[.records[] | select(.bundle == "'$bundle'")] | length' $out) fix records, $($jq '.records | length' $out) total"
  rm -f $recs $meta
done
