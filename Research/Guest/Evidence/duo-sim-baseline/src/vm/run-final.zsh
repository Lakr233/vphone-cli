#!/bin/zsh
# run-final.zsh: the last steps on duobase-01.
# 1. closed, lock screen via a simulated lock button (lockUIFromSource:1 hit EXC_BREAKPOINT
#    when closed, raw/vm/steps/closed-lockscreen-pose/lockcmd.txt): chrome-lock on the cover.
# 2. closed home screen rotated to landscapeRight (redo: the first try lost SpringBoard).
# 3. back to open, portrait (display.rotation 90 on the inner), unlocked, idle timer disabled.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
run=$root/probes/vm-run.zsh
R() { vphone-launchpad-cli guest rpc duobase-01 "$@" }
P() { $root/tools/vm-probe.zsh duobase-01 SpringBoard $root/probes/$1.lldb $root/raw/vm/autolock/$2.txt 2>/dev/null || print "probe $1 rc $?"; tail -2 $root/raw/vm/autolock/$2.txt | cut -c1-200 }
sbpid() { R processes.list '{"filter":"SpringBoard"}' | /opt/homebrew/bin/jq -r '[.result.processes[] | select(.name == "SpringBoard") | .pid] | first // empty' }
print "sb $(sbpid)"
R apps.terminate '{"bundle_id":"com.apple.mobilesafari"}' >/dev/null 2>&1 || true
R apps.terminate '{"bundle_id":"com.apple.Preferences"}' >/dev/null 2>&1 || true
$run posture fin-closed '{"hinge":"closed","position":"closed"}'; sleep 15
R screen.unlock '{}' >/dev/null 2>&1 || true
P vm-lock-press fin-lockpress; sleep 4
VM_NO_UNLOCK=1 $run snap closed-lockscreen-button 'closed(lock screen via lock button)' SpringBoard:chrome-lock SpringBoard:springboard-state 2>&1 | grep -v '^vm-probe'; print closed-lockscreen-button >> $root/raw/vm/steps/ORDER
R screen.unlock '{}' | /opt/homebrew/bin/jq -c .result
P vm-springboard-disable-autolock fin-disable-1
print "sb $(sbpid)"
$run rpc fin-closed-home-rot90 display.rotation '{"orientation":"90"}'; sleep 25
$run snap closed-home-rot90 'closed[home, display.rotation 90 (landscapeRight)]' SpringBoard:springboard-state SpringBoard:sensors-springboard SpringBoard:display-springboard 2>&1 | grep -v '^vm-probe'; print closed-home-rot90 >> $root/raw/vm/steps/ORDER
$run rpc fin-closed-home-rot0 display.rotation '{"orientation":"0"}'; sleep 20
print "sb $(sbpid)"
$run posture fin-open '{"hinge":"open-flat","position":"open"}'; sleep 20
$run rpc fin-open-rot90 display.rotation '{"orientation":"90"}'; sleep 20
R screen.unlock '{}' | /opt/homebrew/bin/jq -c .result
P vm-springboard-disable-autolock fin-disable-2
R display.pose '{}' | /opt/homebrew/bin/jq -c .result
R display.orientation '{}' | /opt/homebrew/bin/jq -c .result
R device.screen '{}' | /opt/homebrew/bin/jq -c .result
R display.auto_lock '{}' | /opt/homebrew/bin/jq -c .result
print "sb $(sbpid)"
