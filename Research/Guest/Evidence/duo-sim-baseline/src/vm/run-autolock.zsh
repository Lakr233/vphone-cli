#!/bin/zsh
# run-autolock.zsh: the "Power and auto-lock" rows on duobase-01.
# 1. open, unlocked, SpringBoard idle-timer assertions invalidated (vm-springboard-enable-autolock)
#    so the real Auto-Lock (60 s) runs; wait 90 s; snapshot without unlocking.
# 2. fold to closed while auto-locked; snapshot without unlocking (which panel lights).
# 3. unlock, open, idle timer disabled again, simulated lock-button press, fold within ~3 s;
#    snapshot without unlocking.
# 4. back to open, unlocked, idle timer disabled.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
run=$root/probes/vm-run.zsh
R() { vphone-launchpad-cli guest rpc duobase-01 "$@" }
P() { $root/tools/vm-probe.zsh duobase-01 SpringBoard $root/probes/$1.lldb $root/raw/vm/autolock/$2.txt 2>/dev/null || print "probe $1 rc $?"; grep -E 'disabled=|locked|simulated|requested' $root/raw/vm/autolock/$2.txt | tail -2 | cut -c1-200 }
SB=(SpringBoard:springboard-state SpringBoard:display-springboard)
print "== 1"; $run posture al-open '{"hinge":"open-flat","position":"open"}'; sleep 15
R screen.unlock '{}' | /opt/homebrew/bin/jq -c .result
P vm-springboard-enable-autolock enable-1
sleep 90
VM_NO_UNLOCK=1 $run snap open-autolocked 'open(auto-locked)' $SB backboardd:display-backboardd 2>&1 | grep -v '^vm-probe'; print open-autolocked >> $root/raw/vm/steps/ORDER
print "== 2"; $run posture al-fold '{"hinge":"closed","position":"closed"}'; sleep 15
VM_NO_UNLOCK=1 $run snap closed-after-autolock-open 'closed(after auto-lock in open)' $SB backboardd:display-backboardd 2>&1 | grep -v '^vm-probe'; print closed-after-autolock-open >> $root/raw/vm/steps/ORDER
sleep 20
VM_NO_UNLOCK=1 $run snap closed-after-autolock-open-20s 'closed(after auto-lock in open, 20 s later)' SpringBoard:springboard-state 2>&1 | grep -v '^vm-probe'; print closed-after-autolock-open-20s >> $root/raw/vm/steps/ORDER
print "== 3"; $run posture al-open2 '{"hinge":"open-flat","position":"open"}'; sleep 15
R screen.unlock '{}' | /opt/homebrew/bin/jq -c .result
P vm-springboard-disable-autolock disable-2
P vm-lock-press lockpress-1
sleep 3
$run posture al-fold2 '{"hinge":"closed","position":"closed"}'; sleep 12
VM_NO_UNLOCK=1 $run snap closed-after-lockbutton-open 'closed(after lock button in open)' $SB 2>&1 | grep -v '^vm-probe'; print closed-after-lockbutton-open >> $root/raw/vm/steps/ORDER
print "== 4"; $run posture al-restore '{"hinge":"open-flat","position":"open"}'; sleep 15
R screen.unlock '{}' | /opt/homebrew/bin/jq -c .result
P vm-springboard-disable-autolock disable-3
P vm-autolock-state final-state
