#!/bin/zsh
# vm-merge.zsh: build vm-<domain>.json (README record format) from raw/vm/steps/*/records.jsonl.
# Domain = probe prefix: springboard-*, display-*, sensors-*, chrome-*, appkit-*. Steps are
# taken in the order of raw/vm/steps/ORDER (one step label per line); each step's rpc.json
# (display.pose, orientation, screenshot size and lit/dark, SpringBoard pid) goes to
# meta.steps. Addresses (0x + 6 or more hex digits) in string values become 0x*, as in the
# simulator files; raw transcripts keep them.
set -euo pipefail
here=${0:a:h}; root=${here:h}
jq=/opt/homebrew/bin/jq
steps=$root/raw/vm/steps
bundle=${VM_BUNDLE:-2.14.0-local.21dc0c06}
# Rebuild every step's records.jsonl from its transcripts first (keeps all probe fields).
$here/vm-retag.zsh $(sed "s#^#$steps/#" $steps/ORDER | while read -r d; do [[ -e $d/rpc.json ]] && print $d; done) >/dev/null
for domain in springboard display sensors chrome appkit; do
  out=$root/vm-$domain.json
  recs=$(mktemp -t vmmerge); meta=$(mktemp -t vmmeta)
  : > $recs; : > $meta
  while read -r step; do
    [[ -n $step && -e $steps/$step/records.jsonl ]] || continue
    $jq -c --arg d "$domain" --arg step "$step" 'select(.probe | startswith($d + "-")) | . + {step: $step}
      | walk(if type == "string" then gsub("0x[0-9a-fA-F]{6,}"; "0x*") else . end)' $steps/$step/records.jsonl >> $recs
    if $jq -e --arg d "$domain" 'select(.probe | startswith($d + "-"))' $steps/$step/records.jsonl >/dev/null 2>&1 \
       && [[ -n $($jq -c --arg d "$domain" 'select(.probe | startswith($d + "-")) | .probe' $steps/$step/records.jsonl | head -1) ]]; then
      $jq -c --arg step "$step" '{step: $step} + . ' $steps/$step/rpc.json >> $meta
    fi
  done < $steps/ORDER
  $jq -n --arg domain $domain --arg bundle $bundle --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile recs $recs --slurpfile steps $meta '{
      meta: {domain: $domain,
             vm: {name: "duobase-01", bundle: $bundle, bundle_source: "upstream main 82afdb9a, two-display Duo path",
                  device: "iPhone19,4", os: "iOS 27.1 24A94425", host_tool: "tools/vm-probe.zsh (guest debugserver, host lldb)"},
             posture_mechanism: "vphoned display.posture / display.rotation (SpringBoard pose override + virtual hinge HID), not the sim swap tool",
             probes: "probes/vm-*.lldb where present (vm-convert.zsh output plus VM-only fixes, see vm-notes.md), else the simulator probe unchanged",
             normalisation: "0x[0-9a-f]{6,} replaced by 0x* in string values; raw values in raw/vm/steps/<step>/*.raw.txt",
             date: $date, steps: $steps},
      records: $recs}' > $out
  print "$out: $($jq '.records | length' $out) records, $($jq '.meta.steps | length' $out) steps"
  rm -f $recs $meta
done
