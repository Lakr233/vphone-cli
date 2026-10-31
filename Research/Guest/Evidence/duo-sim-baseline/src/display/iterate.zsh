#!/bin/zsh
# iterate.zsh <body> <process>: run the probe; on an ObjC exception, add the traced selector to vpThrowSels and retry.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
trace=/private/tmp/claude-501/-Users-Jacky--claude-spares-spare-SBbPAl/57b50db2-159e-4729-b15b-b24d84c6e854/scratchpad/vptrace.txt
for i in {1..25}; do
  rm -f $trace
  $here/gen-probe.zsh $1 >/dev/null
  $root/tools/probe.zsh duo-baseline-display $2 $root/probes/display-$1.lldb $here/test-$1.txt 2>/dev/null || true
  if grep -q 'exception breakpoint' $here/test-$1.txt; then
    sel=$(awk '{print $NF}' $trace)
    print -- "throws: $(cat $trace)"
    perl -pi -e "s/^NSArray \\*vpThrowSels = \\@\\[/NSArray *vpThrowSels = \\@[\\@\"$sel\", /" $here/src/helpers.lldbfrag
  else
    grep -E '^error' $here/test-$1.txt | head -5 || true
    print -- "done: $(wc -c < $here/test-$1.txt) bytes"; break
  fi
done
