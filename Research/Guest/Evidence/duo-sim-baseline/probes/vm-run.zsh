#!/bin/zsh
# vm-run.zsh posture <label> '<display.posture json>'   drive the pose, save the reply
# vm-run.zsh rpc <label> <method> '<json>'              any guest RPC, reply saved
# vm-run.zsh snap <label> <posture-label> [proc:probe ...]
#
# One step of the vphone-duo run on duobase-01. `snap` unlocks the guest, records an RPC
# snapshot (display.pose, display.orientation, device.screen, screenshot size and lit/dark,
# SpringBoard pid), then runs each probe (probes/<probe>.lldb, the vm-* variants where they
# exist) in <proc> through tools/vm-probe.zsh. Everything lands in raw/vm/steps/<label>/:
#   rpc.json, shot.jpg, <proc>-<probe>.txt (+ .raw.txt), records.jsonl (tagged records).
# The SpringBoard pid is checked after every probe; a change is printed and stored in rpc.json.
# VM_NO_UNLOCK=1 skips the screen.unlock (auto-lock and lock-screen steps).
set -euo pipefail
here=${0:a:h}
root=${here:h}
jq=/opt/homebrew/bin/jq
vm=duobase-01
R() { vphone-launchpad-cli guest rpc $vm "$@" }
sbpid() { R processes.list '{"filter":"SpringBoard"}' | $jq -r '[.result.processes[] | select(.name == "SpringBoard") | .pid] | first // empty' }

cmd=${1:?verb}; label=${2:?label}; shift 2
dir=$root/raw/vm/steps/$label
mkdir -p $dir
case $cmd in
  posture)
    R display.posture "$1" > $dir/posture.json || true
    $jq -c '.result // .' $dir/posture.json ;;
  rpc)
    R $1 "${2:-{\}}" > $dir/rpc-$1.json || true
    $jq -c '.result // .' $dir/rpc-$1.json | cut -c1-400 ;;
  snap)
    plabel=${1:?posture-label}; shift
    if [[ -z ${VM_NO_UNLOCK:-} ]]; then R screen.unlock '{}' > $dir/unlock.json 2>&1 || true; else print "VM_NO_UNLOCK: left as is" > $dir/unlock.json; fi
    sleep 1
    R screen.screenshot '{}' > $dir/shot.rpc.json || true
    $jq -r '.result.data' $dir/shot.rpc.json | base64 -d > $dir/shot.jpg 2>/dev/null || true
    lit=$($root/tools/sim.zsh lit $dir/shot.jpg 2>/dev/null || print unknown)
    $jq -n --arg posture "$plabel" --arg lit "$lit" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson pose "$(R display.pose '{}' | $jq -c '.result // .')" \
      --argjson orient "$(R display.orientation '{}' | $jq -c '.result // .')" \
      --argjson screen "$(R device.screen '{}' | $jq -c '.result // .')" \
      --argjson shot "$($jq -c '.result | {width, height, coordinate_scale}' $dir/shot.rpc.json)" \
      --argjson sb "$(sbpid)" \
      '{posture: $posture, date: $date, display_pose: $pose, display_orientation: $orient, device_screen: $screen, screenshot: ($shot + {lit: $lit}), springboard_pid: $sb}' > $dir/rpc.json
    rm -f $dir/shot.rpc.json
    $jq -c '{pose: .display_pose, deg: .display_orientation.degrees, shot: .screenshot, sb: .springboard_pid}' $dir/rpc.json
    : > $dir/records.jsonl
    for pp in "$@"; do
      proc=${pp%%:*}; probe=${pp#*:}
      file=$here/vm-$probe.lldb; [[ -e $file ]] || file=$here/$probe.lldb
      before=$(sbpid)
      PROBE_TIMEOUT=${PROBE_TIMEOUT:-240} $root/tools/vm-probe.zsh $vm $proc $file $dir/$proc-$probe.txt 2>>$dir/probe-stderr.txt || print -u2 "vm-run: $label $proc $probe rc $?"
      after=$(sbpid)
      if [[ $before != $after ]]; then
        print -u2 "vm-run: $label: SpringBoard pid changed $before -> $after during $proc:$probe"
        print "$proc:$probe $before -> $after" >> $dir/springboard-restarts.txt
      fi
      grep -E '^\{"(records|orientation|group)"' $dir/$proc-$probe.txt | $jq -c --arg proc $proc --arg probe $probe --arg posture "$plabel" '
        def orient: {"0": "unknown", "1": "portrait", "2": "portraitUpsideDown", "3": "landscapeLeft", "4": "landscapeRight"}[tostring] // "unknown";
        . as $g | .records[] | {api, kind, process: $proc, posture: $posture,
          orientation: (($g.orientation // 0) | orient), call, value, error, probe: $probe}
          + (if $g.group then {group: $g.group} else {} end)' >> $dir/records.jsonl 2>/dev/null \
        || print -u2 "vm-run: $label: no JSON from $proc:$probe ($(grep -m3 -E 'error|EXC_' $dir/$proc-$probe.txt | tr '\n' ' ' | cut -c1-300))"
      print -u2 "vm-run: $label $proc:$probe -> $(grep -c "\"probe\":\"$probe\"" $dir/records.jsonl) records"
    done ;;
  *) sed -n '2,11p' ${0:a} | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
