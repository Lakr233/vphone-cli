#!/bin/zsh
# springboard-run.zsh <step-label> <posture verb> [posture args...]
# springboard-run.zsh <step-label> -            (no posture change: state probe only)
#
# One step of the SpringBoard-domain baseline: drive the posture with tools/posture.zsh
# (artifacts in raw/springboard/posture), then run probes/springboard-state.lldb in
# SpringBoard and keep its JSON line. Results:
#   raw/springboard/steps/<label>.posture.json   posture.zsh output (+ "exit" field)
#   raw/springboard/steps/<label>-state.txt      cleaned transcript (+ .raw.txt)
#   raw/springboard/steps/<label>.records.json   {"orientation": n, "records": [...]}
# Environment: POSTURE_ANCHOR / POSTURE_SETTLE are passed through to posture.zsh;
# SB_NO_RETRY=1 keeps an unverified posture (exit 3) instead of retrying it once.
set -euo pipefail
here=${0:a:h}
root=${here:h}
jq=/opt/homebrew/bin/jq
sim=048B820B-86E8-43F9-9DF1-F76802AD6DB8
label=${1:?label}; shift
steps=$root/raw/springboard/steps
mkdir -p $steps

if [[ ${1:-} != - ]]; then
  rc=0
  POSTURE_OUT=$root/raw/springboard/posture $root/tools/posture.zsh $sim "$@" > $steps/$label.posture.tmp || rc=$?
  if (( rc == 3 )) && [[ -z ${SB_NO_RETRY:-} ]]; then
    # Not verified: wait out the 10 s testing lock, read the status, retry once.
    print -u2 "springboard-run: $label: posture exit 3, retrying after the testing lock"
    POSTURE_OUT=$root/raw/springboard/posture $root/tools/posture.zsh $sim status > $steps/$label.status-before-retry.json || true
    sleep 11
    rc=0
    POSTURE_OUT=$root/raw/springboard/posture $root/tools/posture.zsh $sim "$@" > $steps/$label.posture.tmp || rc=$?
  fi
  $jq --argjson rc $rc '. + {exit: $rc}' $steps/$label.posture.tmp > $steps/$label.posture.json
  rm -f $steps/$label.posture.tmp
  print -u2 "springboard-run: $label: posture exit $rc lit=$($jq -r .screenshots.lit_panel $steps/$label.posture.json) policy=$($jq -r .springboard.prevailing_policy $steps/$label.posture.json)"
fi
PROBE_TIMEOUT=${PROBE_TIMEOUT:-150} $root/tools/probe.zsh $sim SpringBoard $here/springboard-state.lldb $steps/$label-state.txt
grep -E '^\{"(records|orientation)"' $steps/$label-state.txt > $steps/$label.records.json || {
  print -u2 "springboard-run: $label: no JSON in $steps/$label-state.txt"; exit 1 }
print -u2 "springboard-run: $label: $($jq '.records | length' $steps/$label.records.json) records, primary orientation $($jq .orientation $steps/$label.records.json)"
