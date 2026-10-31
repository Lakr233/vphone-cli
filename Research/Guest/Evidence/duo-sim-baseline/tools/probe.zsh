#!/bin/zsh
# probe.zsh <udid|name> <process|pid> <cmdfile|-> [out.txt]
#
# Attach lldb to one process inside one simulator, source prelude.lldb (thread 1 + module
# imports) and then <cmdfile> (or stdin for "-"), detach, and quit. Commands keep running
# after an error. The cleaned transcript goes to out.txt (or stdout); the untouched lldb
# output goes next to it as out.raw.txt.
#
# Environment:
#   PROBE_TIMEOUT=120       seconds before the watchdog interrupts lldb (SIGINT, twice, then SIGTERM)
#   PROBE_FULL_SYMBOLS=1    load every symbol table up front (≈16 s per attach instead of ≈3 s)
#   PROBE_NO_PRELUDE=1      skip prelude.lldb
#
# Exit status: lldb's status, or 124 if the watchdog fired. The target is checked after
# lldb exits: a process left stopped (state T) is sent SIGCONT and a warning is printed.
set -euo pipefail
here=${0:a:h}

(( $# >= 3 )) || { sed -n '2,17p' ${0:a} | sed 's/^# \{0,1\}//'; exit 2 }
udid=$($here/sim.zsh udid $1)
proc=$2 cmd=$3 out=${4:-}
if [[ $proc == <-> ]]; then pid=$proc; else pid=$($here/sim.zsh pid $udid $proc); fi

work=$(mktemp -d -t probe)
trap 'rm -rf "$work"' EXIT
if [[ $cmd == - ]]; then cat > $work/cmd.lldb; cmd=$work/cmd.lldb; fi
[[ -r $cmd ]] || { print -u2 "probe.zsh: cannot read $cmd"; exit 2 }
cmd=${cmd:a}
raw=$work/raw.txt

args=(--batch --no-lldbinit)
[[ ${PROBE_FULL_SYMBOLS:-0} == 1 ]] || args+=(-O "settings set symbols.load-on-demand true")
args+=(-O "settings set auto-confirm true" -p $pid)
[[ ${PROBE_NO_PRELUDE:-0} == 1 ]] || args+=(-o "command source -e false -s 0 $here/prelude.lldb")
args+=(-o "command source -e false -s 0 $cmd" -o "process detach" -o "quit")

lldb "${args[@]}" > $raw 2>&1 &
lpid=$!
timeout=${PROBE_TIMEOUT:-120}
(
  sleep $timeout; print -- "probe.zsh: timeout after ${timeout}s, interrupting lldb" > $work/timedout
  kill -INT $lpid 2>/dev/null; sleep 10
  kill -INT $lpid 2>/dev/null; sleep 10
  kill -TERM $lpid 2>/dev/null
) &
wpid=$!
rc=0
wait $lpid || rc=$?
pkill -P $wpid 2>/dev/null || true
kill $wpid 2>/dev/null || true
wait $wpid 2>/dev/null || true
if [[ -e $work/timedout ]]; then rc=124; cat $work/timedout >> $raw; print -u2 -- "$(cat $work/timedout)"; fi

# The target must be running again.
state=$(ps -o stat= -p $pid 2>/dev/null || true)
if [[ -z $state ]]; then
  print -u2 "probe.zsh: WARNING: pid $pid ($proc) is gone after the probe"
elif [[ $state == *T* ]]; then
  print -u2 "probe.zsh: WARNING: pid $pid was left stopped; sending SIGCONT"
  kill -CONT $pid 2>/dev/null || true
fi

# Keep only what the command file produced: from its "command source" echo onward, minus
# lldb's own chatter.
clean() {
  awk -v marker="command source -e false -s 0 $cmd" '
    !on { if (index($0, marker)) on = 1; next }
    /^Executing commands in / { next }
    /^Enter expressions, then terminate with an empty line to evaluate:/ { next }
    /^note: Expression evaluation in pure Objective-C not supported/ { next }
    /^warning: warning: got name from symbols:/ { next }
    /^\(lldb\) process detach$/ || /^Process [0-9]+ detached$/ || /^\(lldb\) quit$/ { next }
    { print }
  ' $raw
}

if [[ -n $out ]]; then
  mkdir -p ${out:h}
  cp $raw ${out:r}.raw.txt
  clean > $out
  print -u2 "probe.zsh: pid $pid rc $rc -> $out"
else
  clean
fi
exit $rc
