#!/bin/zsh
# vm-retag.zsh <step-dir>...: rebuild <step-dir>/records.jsonl from the probe transcripts,
# keeping every field a probe emits (chrome-state's scene/display/sceneOrientation, appkit's
# extra fields) and adding process, posture (from rpc.json), orientation and probe.
# vm-run.zsh's own tagging kept only the README fields; this supersedes it.
set -euo pipefail
jq=/opt/homebrew/bin/jq
for dir in "$@"; do
  plabel=$($jq -r .posture $dir/rpc.json)
  : > $dir/records.jsonl.new
  for f in $dir/*-*.txt; do
    [[ $f == *.raw.txt || $f == */probe-stderr.txt ]] && continue
    base=${f:t:r}; proc=${base%%-*}; probe=${base#*-}
    grep -E '^\{"(records|orientation|group|primaryOrientation|primaryScene)"' $f | $jq -c --arg proc $proc --arg probe $probe --arg posture "$plabel" '
      def orient: {"0": "unknown", "1": "portrait", "2": "portraitUpsideDown", "3": "landscapeLeft", "4": "landscapeRight"}[tostring] // "unknown";
      . as $g | .records[] | . + {process: $proc, posture: $posture,
        orientation: (($g.orientation // $g.primaryOrientation // 0) | orient), probe: $probe}
        + (if $g.group then {group: $g.group} else {} end)' >> $dir/records.jsonl.new 2>/dev/null || true
  done
  mv $dir/records.jsonl.new $dir/records.jsonl
  print "$dir: $(wc -l < $dir/records.jsonl | tr -d ' ') records"
done
