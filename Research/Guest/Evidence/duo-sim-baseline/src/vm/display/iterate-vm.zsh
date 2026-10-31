#!/bin/zsh
# iterate-vm.zsh <process> <vm-probe.lldb>: the VM version of src/display/iterate.zsh. Run the
# probe; when it is interrupted (ObjC exception, SIGABRT, bad instruction), read the getter it
# traced last from the guest's /var/tmp/vptrace.txt, add its selector to vpThrowSels, retry.
# At most 10 rounds.
set -euo pipefail
here=${0:a:h}; root=${here:h:h:h}
proc=$1 probe=$2
R() { vphone-launchpad-cli guest rpc duobase-01 "$@" }
for i in {1..10}; do
  R files.remove '{"path":"/var/tmp/vptrace.txt"}' >/dev/null 2>&1 || true
  $root/tools/vm-probe.zsh duobase-01 $proc $probe $here/iterate-$proc.txt 2>/dev/null || true
  if grep -qE 'Expression execution was interrupted' $here/iterate-$proc.txt; then
    why=$(grep -m1 'interrupted' $here/iterate-$proc.txt)
    last=$(R files.read '{"path":"/var/tmp/vptrace.txt"}' | /opt/homebrew/bin/jq -r '.result.content // empty')
    sel=$(print -- $last | awk '{print $NF}')
    print -- "round $i: $why; last: $last"
    [[ -n $sel ]] || { print "no trace; giving up"; exit 1 }
    perl -pi -e "s/^NSArray \\*vpThrowSels = \\@\\[/NSArray *vpThrowSels = \\@[\\@\"$sel\", /" $probe
  else
    print -- "round $i: done, $(grep -c '^{"orientation' $here/iterate-$proc.txt) JSON line(s)"; exit 0
  fi
done
exit 1
