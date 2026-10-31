#!/bin/zsh
# vm-compare.zsh <sim domain.json> <sim posture label> <vm records.jsonl> [api regex]
# Print every (api, call) whose value differs between one simulator posture and one VM step,
# as tab-separated: api, call, sim value, vm value. Addresses are normalised to 0x* on both
# VM call strings are joined with the inner display renamed to the sim names (VPhone Duo Inner -> LCD-1,
# Unknown[7] -> Unknown.main[3]).
# sides; values longer than 300 characters are cut.
set -euo pipefail
jq=/opt/homebrew/bin/jq
sim=$1 label=$2 vm=$3 re=${4:-.}
$jq -n -r --arg label "$label" --arg re "$re" --slurpfile sim <($jq -c --arg label "$label" '[.records[] | select(.posture == $label)]' $sim) --slurpfile vm <($jq -s -c . $vm) '
  def norm: if type == "string" then gsub("0x[0-9a-fA-F]{6,}"; "0x*") else . end
    | walk(if type == "string" then gsub("0x[0-9a-fA-F]{6,}"; "0x*") else . end);
  def key: .api + "\u0001" + (.call | gsub("VPhone Duo Inner"; "LCD-1") | gsub("Unknown\\[7\\]"; "Unknown.main[3]") | gsub("\\[SBWindowScene <SB-main>\\]"; "[cover]") | gsub("\\[SBWindowScene <com.apple.springboard.bringup>\\]"; "[inner]"));
  ($sim[0] | map({key: key, value: {v: (.value | norm), e: .error}}) | from_entries) as $s
  | ($vm[0] | map({key: key, value: {v: (.value | norm), e: .error}}) | from_entries) as $v
  | ([$s, $v] | map(keys) | add | unique)[] as $k
  | select(($k | split("\u0001")[0]) | test($re))
  | select($s[$k] != $v[$k])
  | [($k | split("\u0001")[0]), ($k | split("\u0001")[1]),
     (($s[$k] // {v: "<absent>"}) | if .e then "ERR " + (.e|tostring) else .v | tojson end | .[0:300]),
     (($v[$k] // {v: "<absent>"}) | if .e then "ERR " + (.e|tostring) else .v | tojson end | .[0:300])] | @tsv'
