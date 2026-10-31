#!/bin/zsh
# run-lockchrome.zsh <posture-json> <label> <posture-label>: lock the primary scene
# (vm-lock.lldb: lockUIFromSource:1, as chrome-run.zsh lock), run chrome-lock without
# unlocking, then unlock (screen.unlock). No notifications are pushed on the VM.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
run=$root/probes/vm-run.zsh
R() { vphone-launchpad-cli guest rpc duobase-01 "$@" }
$run posture $2-pose "$1"; sleep 15
R screen.unlock '{}' >/dev/null 2>&1 || true
$root/tools/vm-probe.zsh duobase-01 SpringBoard $root/probes/vm-lock.lldb $root/raw/vm/steps/$2-pose/lockcmd.txt 2>/dev/null || true
grep 'locked via' $root/raw/vm/steps/$2-pose/lockcmd.txt | tail -1
sleep 3
VM_NO_UNLOCK=1 $run snap $2 "$3" SpringBoard:chrome-lock 2>&1 | grep -v '^vm-probe'; print $2 >> $root/raw/vm/steps/ORDER
R screen.unlock '{}' | /opt/homebrew/bin/jq -c .result
