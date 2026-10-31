#!/bin/zsh
# capture.zsh <seq-label> <posture-label> <requested-orientation> <posture.zsh args...|status>
#   Drives the posture (posture.zsh output -> raw/display/posture), then runs the backboardd and
#   SpringBoard display probes and stores their transcripts as raw/display/states/<seq-label>-*.txt.
#   Appends one line to raw/display/states/manifest.jsonl.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
jq=/opt/homebrew/bin/jq
sim=duo-baseline-display
seq=$1 plabel=$2 reqo=$3; shift 3
mkdir -p $here/states
pjson=$here/states/$seq-posture.json
rc=0
POSTURE_OUT=$here/posture $root/tools/posture.zsh $sim "$@" > $pjson || rc=$?
if (( rc == 3 )); then
  print -u2 "capture: posture not verified (exit 3); waiting out the testing lock and re-checking status"
  sleep 11
  POSTURE_OUT=$here/posture $root/tools/posture.zsh $sim status > $here/states/$seq-posture-recheck.json || true
fi
$here/gen-probe.zsh backboardd >/dev/null; $here/gen-probe.zsh springboard >/dev/null
$root/tools/probe.zsh $sim backboardd $root/probes/display-backboardd.lldb $here/states/$seq-backboardd.txt
$root/tools/probe.zsh $sim SpringBoard $root/probes/display-springboard.lldb $here/states/$seq-springboard.txt
for p in backboardd springboard; do
  grep -q '^{"' $here/states/$seq-$p.txt || { print -u2 "capture: no JSON in $seq-$p.txt"; grep -m3 -E '^error' $here/states/$seq-$p.txt >&2 || true; }
done
$jq -c --arg seq $seq --arg posture $plabel --arg reqo $reqo --arg args "$*" --argjson rc $rc \
  '{seq: $seq, posture: $posture, requested_orientation: $reqo, posture_args: $args, posture_exit: $rc, lit: .screenshots.lit_panel, hinge: .springboard.hinge_state, policy: .springboard.prevailing_policy, primary_on: .springboard.primary_on}' $pjson | tee -a $here/states/manifest.jsonl
for p in backboardd springboard; do grep '^{"' $here/states/$seq-$p.txt | $jq -c --arg p $p '{p: $p, n: (.records|length), orientation, errors: ([.records[] | select(.error != null)] | length)}' || true; done
