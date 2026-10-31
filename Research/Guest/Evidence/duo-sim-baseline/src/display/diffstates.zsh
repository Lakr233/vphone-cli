#!/bin/zsh
# diffstates.zsh <seqA> <seqB> <backboardd|springboard> : list calls whose value differs (pointer addresses masked)
set -euo pipefail
here=${0:a:h}; jq=/opt/homebrew/bin/jq
norm='def n: if type == "string" then gsub("0x[0-9a-fA-F]+"; "0x?") elif type == "object" then with_entries(.value |= n) elif type == "array" then map(n) else . end; [.records[] | {key: .call, value: ((.value | n | tostring) + (if .error then " ERR:" + .error else "" end))}] | from_entries'
grep '^{"' $here/states/$1-$3.txt | $jq "$norm" > /tmp/vpA.$$
grep '^{"' $here/states/$2-$3.txt | $jq "$norm" > /tmp/vpB.$$
$jq -n -r --slurpfile a /tmp/vpA.$$ --slurpfile b /tmp/vpB.$$ '$a[0] as $A | $b[0] as $B | ($A + $B | keys[]) as $k | select($A[$k] != $B[$k]) | "\($k)\n    A: \($A[$k] // "-" | .[0:300])\n    B: \($B[$k] // "-" | .[0:300])"'
rm -f /tmp/vpA.$$ /tmp/vpB.$$
