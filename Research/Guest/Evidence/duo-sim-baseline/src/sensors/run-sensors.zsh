#!/bin/zsh
# run-sensors.zsh snapshot <seq> <posture-label> full|light
# run-sensors.zsh posture <seq> <posture-label> full|light <posture.zsh args...>
# run-sensors.zsh assemble
#
# The sensors domain runner (hinge, pose, motion, device identity) for the duo-baseline-sensors
# simulator. `snapshot` runs the sensors probes in SpringBoard, backboardd and Preferences
# without changing anything, and writes the transcripts plus a tagged records.jsonl to
# snap/<seq>-<label>/. `full` adds the posture-independent probes (CoreMotion tables, identity,
# blocking device-state query). `posture` drives tools/posture.zsh, saves its JSON into
# snap/<seq>-<label>/posture.json, then takes a snapshot in the given mode. `assemble` merges every snapshot into ../../sensors.json.
set -euo pipefail
here=${0:a:h}
root=${here:h:h}
tools=$root/tools
probes=$root/probes
jq=/opt/homebrew/bin/jq
udid=C0EF5D72-68AE-4F00-8594-10039EADA1AC

tag() { # tag <probe-out.txt> <process> <posture> <default-orientation>
  grep -E '^\{"group"' $1 | $jq -c --arg proc $2 --arg posture $3 --argjson dflt ${4:-0} '
    def orient: {"0": "unknown", "1": "portrait", "2": "portraitUpsideDown", "3": "landscapeLeft", "4": "landscapeRight"}[tostring] // "unknown";
    . as $g | .records[] | {api, kind, process: $proc, posture: $posture,
      orientation: (($g.orientation // $dflt) | orient), call, value, error, group: $g.group}' || {
    print -u2 "run-sensors: no JSON in $1"; grep -v '^{"' $1 | head -20 >&2; }
}

run() { # run <dir> <process> <probe-name> [timeout]
  local dir=$1 proc=$2 name=$3
  PROBE_TIMEOUT=${4:-120} $tools/probe.zsh $udid $proc $probes/sensors-$name.lldb $dir/$proc-$name.txt 2>>$dir/probe-stderr.txt || print -u2 "run-sensors: $proc $name rc $?"
}

snapshot() {
  local seq=$1 label=$2 mode=$3
  local dir=$here/snap/$seq-$label
  mkdir -p $dir
  date -u +%Y-%m-%dT%H:%M:%SZ > $dir/started
  if ! $tools/sim.zsh pid $udid Preferences >/dev/null 2>&1; then
    xcrun simctl launch $udid com.apple.Preferences > $dir/preferences-relaunched.txt; sleep 4
  fi
  run $dir SpringBoard springboard
  local o=$(grep -E '^\{"group":"pose"' $dir/SpringBoard-springboard.txt | $jq -r '.orientation' || print 0)
  run $dir SpringBoard coremotion
  run $dir SpringBoard uikit
  run $dir backboardd backboardd
  run $dir Preferences app-hinge-register
  run $dir Preferences coremotion
  run $dir Preferences uikit
  if [[ $mode == full ]]; then
    run $dir SpringBoard cmtables
    run $dir SpringBoard identity
    run $dir SpringBoard cmquery 60
    run $dir Preferences cmtables
    run $dir Preferences identity
    run $dir Preferences cmquery 60
  fi
  : > $dir/records.jsonl
  for f in $dir/*-*.txt; do
    [[ $f == *.raw.txt || $f == */probe-stderr.txt || $f == *register* || $f == */preferences-relaunched.txt ]] && continue
    local proc=${${f:t}%%-*}
    tag $f $proc $label $o >> $dir/records.jsonl
  done
  date -u +%Y-%m-%dT%H:%M:%SZ > $dir/finished
  print -- "run-sensors: $label: $(wc -l < $dir/records.jsonl | tr -d ' ') records, SpringBoard orientation $o"
}

case ${1:-} in
  snapshot) snapshot $2 $3 $4 ;;
  posture)
    seq=$2 label=$3 mode=$4; shift 4
    dir=$here/snap/$seq-$label; mkdir -p $dir
    rc=0
    POSTURE_OUT=$here/posture $tools/posture.zsh $udid "$@" > $dir/posture.json || rc=$?
    print -- "{\"args\": \"$*\", \"exit\": $rc}" > $dir/posture-exit.json
    print -- "run-sensors: posture $* -> exit $rc: $($jq -c '{hinge: .springboard.hinge_state, pos: .springboard.position, policy: .springboard.prevailing_policy, lit: .screenshots.lit_panel, ok}' $dir/posture.json)"
    snapshot $seq $label $mode ;;
  assemble)
    out=$root/sensors.json
    runtime=$(xcrun simctl list runtimes -j | $jq -c '.runtimes[] | select(.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-1") | {identifier, version, buildversion}')
    device=$(xcrun simctl list devices -j | $jq -c --arg u $udid '.devices[] | .[] | select(.udid == $u) | {name, udid, deviceTypeIdentifier}')
    xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')
    work=$(mktemp -d -t sensors); trap 'rm -rf "$work"' EXIT
    : > $work/records.jsonl; : > $work/postures.jsonl
    for d in $here/snap/*(/); do
      label=${${d:t}#*-}
      cat $d/records.jsonl >> $work/records.jsonl
      if [[ -e $d/posture.json ]]; then
        $jq -c --arg label $label --arg snap ${d:t} --slurpfile ex $d/posture-exit.json '. + {snapshot: $snap, posture_label: $label, exit: $ex[0].exit}' $d/posture.json >> $work/postures.jsonl
      else
        print -- "{\"snapshot\": \"${d:t}\", \"posture_label\": \"$label\", \"note\": \"$( [[ $label == boot ]] && print "no swap: state right after boot" || print "no swap: the state the previous snapshot left" )\"}" >> $work/postures.jsonl
      fi
    done
    $jq -c -f $here/sim-notes.jq $work/records.jsonl > $work/flagged.jsonl
    $jq -n \
      --argjson runtime "$runtime" --argjson device "$device" --arg xcode "$xcode" \
      --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)" \
      --slurpfile postures $work/postures.jsonl --slurpfile recs $work/flagged.jsonl '
      {
        meta: {
          domain: "sensors", runtime: $runtime, device: $device, xcode: $xcode, host: $host, date: $date,
          posture_mechanism: "SBDisplayToolServiceCoordinator performDisplaySwapWithSettings: (tools/posture.zsh); snapshots in order, see postures[].snapshot",
          processes: ["SpringBoard", "backboardd", "Preferences"],
          orientation_field: "interface orientation of the scene the call ran under (SpringBoard: primary window scene; Preferences: its window scene). The device orientation passed to -deviceOrientation= is in the posture label, e.g. closed(landscapeLeft).",
          sim_note_field: "extra per-record field: why a value is synthetic or sim-only and must not be used as an alignment target for the VM; null when the value is a plain OS answer",
          group_field: "extra per-record field: the probe expression the record came from (probes/sensors-<group>.lldb; pose = probes/sensors-springboard.lldb, hid = probes/sensors-backboardd.lldb)",
          postures: $postures
        },
        records: $recs
      }' > $out
    print -- "run-sensors: $($jq '.records | length' $out) records -> $out" ;;
  *) sed -n '2,12p' ${0:a} | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
