#!/bin/zsh
# Opens {"t":"shell"} sessions on a running VM's vphone.sock one after another
# and counts the opens that fail. Needs a booted VM; not part of an offline gate.
#
# Usage: run-shell-open-live.sh <vphone.sock> [count]   (count defaults to 200)
# Exit: 0 no failed open, 1 any failed open, 2 usage error.
set -u

name=${0:t}
usage() {
    print -u2 "usage: $name <vphone.sock> [count]"
    exit 2
}

sock=${1:-}
count=${2:-200}
[[ -S $sock ]] || usage
[[ $count == <1-> ]] || usage

failures=0
for attempt in {1..$count}; do
    reply=$(print -r -- '{"t":"shell","cols":80,"rows":24}' | nc -U -w 3 "$sock" 2>&1)
    if [[ -z $reply || $reply == *'"ok":false'* ]]; then
        failures=$((failures + 1))
        print -r -- "attempt $attempt: ${reply:-<empty>}"
    fi
done
print "failures: $failures/$count"
(( failures == 0 ))
