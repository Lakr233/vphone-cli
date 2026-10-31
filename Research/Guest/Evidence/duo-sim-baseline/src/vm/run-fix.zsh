#!/bin/zsh
# run-fix.zsh <phase>: re-measure the rows the duo-sim-align fix can affect, on duobase-01
# with bundle 2.14.0-local.9064efca (branch duo-sim-align). Same probes as run-plan.zsh, but
# each lldb attach is spaced (GAP seconds after the previous one ended, and never sooner than
# 6 s after a posture or rotation), because lldb stops SpringBoard and a burst of attaches
# got it killed once. The SpringBoard pid is checked before and after every attach.
# Steps land in raw/vm/steps/fx-<label>/ (rpc.json, shot.jpg, transcripts, records.jsonl
# with a "bundle" field); step order in raw/vm/steps/ORDER.fix-9064efca.
#
# display.pose reads SpringBoard's test-automation snapshot, which this bundle no longer
# sets, so rpc.json keeps it only as "display_pose_stale"; the pose comes from
# SBFDevicePoseProvider (sensors-springboard).
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
jq=/opt/homebrew/bin/jq
vm=duobase-01
bundle=2.14.0-local.9064efca
steps=$root/raw/vm/steps
order=$steps/ORDER.fix-9064efca
stamp=$here/.fix-last-attach
GAP=${GAP:-45}
R() { vphone-launchpad-cli guest rpc $vm "$@" }
sbpid() { R processes.list '{"filter":"SpringBoard"}' | $jq -r '[.result.processes[] | select(.name == "SpringBoard") | .pid] | first // empty' }
log() { print -r -- "fix $(date +%H:%M:%S): $*" }

# Wait until GAP seconds have passed since the last attach ended.
spacing() {
  local last=$(cat $stamp 2>/dev/null || print 0) now=$(date +%s)
  local wait=$(( last + GAP - now ))
  (( wait > 0 )) && { log "spacing ${wait}s"; sleep $wait }
  return 0
}
pose() { log "posture $1"; mkdir -p $steps/fx-$2; R display.posture "$1" > $steps/fx-$2/posture.json || true; $jq -c '.result // .' $steps/fx-$2/posture.json | cut -c1-300; sleep ${3:-20} }
rot() { log "rotation $1"; mkdir -p $steps/fx-$2; R display.rotation "{\"orientation\":\"$1\"}" > $steps/fx-$2/rotation.json || true; $jq -c '.result // .' $steps/fx-$2/rotation.json | cut -c1-300; sleep ${3:-25} }
app() { log "launch $1"; R screen.unlock '{}' >/dev/null 2>&1 || true; R apps.launch "{\"bundle_id\":\"$1\"}" | $jq -c '.result // .' | cut -c1-200; sleep 8 }

# keep: if SpringBoard was replaced since the idle-timer assertion was taken, stop. A new
# SpringBoard has no assertion, auto-locks after 60 s and darkens the screen, and a fold
# while dark is not published (see vm-notes.md); the caller re-takes it and resyncs.
keep() {
  local p=$(sbpid) held=$(cat $here/.fix-assertion-pid 2>/dev/null || true)
  [[ $p == $held ]] || { log "SpringBoard $p has no idle-timer assertion (held by ${held:-none}); stopping"; exit 3 }
}

# snap <label> <posture-label>: RPC snapshot + screenshot (no probes).
snap() {
  local label=$1 plabel=$2 dir=$steps/fx-$1
  keep
  mkdir -p $dir
  if [[ -z ${VM_NO_UNLOCK:-} ]]; then R screen.unlock '{}' > $dir/unlock.json 2>&1 || true; else print "VM_NO_UNLOCK: left as is" > $dir/unlock.json; fi
  sleep 1
  R screen.screenshot '{}' > $dir/shot.rpc.json || true
  $jq -r '.result.data' $dir/shot.rpc.json | base64 -d > $dir/shot.jpg 2>/dev/null || true
  local lit=$($root/tools/sim.zsh lit $dir/shot.jpg 2>/dev/null || print unknown)
  $jq -n --arg posture "$plabel" --arg lit "$lit" --arg bundle $bundle --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson pose "$(R display.pose '{}' | $jq -c '.result // .')" \
    --argjson orient "$(R display.orientation '{}' | $jq -c '.result // .')" \
    --argjson screen "$(R device.screen '{}' | $jq -c '.result // .')" \
    --argjson shot "$($jq -c '.result | {width, height, coordinate_scale}' $dir/shot.rpc.json)" \
    --argjson sb "$(sbpid)" \
    '{posture: $posture, bundle: $bundle, date: $date, display_pose_stale: $pose, display_orientation: $orient, device_screen: $screen, screenshot: ($shot + {lit: $lit}), springboard_pid: $sb}' > $dir/rpc.json
  rm -f $dir/shot.rpc.json
  touch $dir/records.jsonl
  print -- "$label" >> $order
  log "snap $label: $($jq -c '{deg: .display_orientation.degrees, shot: .screenshot, sb: .springboard_pid, screen: .device_screen}' $dir/rpc.json)"
}

# probe <label> <proc> <probe>: one spaced attach; records appended to the step.
probe() {
  local label=$1 proc=$2 name=$3 dir=$steps/fx-$1
  local file=$root/probes/vm-$name.lldb; [[ -e $file ]] || file=$root/probes/$name.lldb; [[ -e $here/$name.lldb ]] && file=$here/$name.lldb
  local plabel=$($jq -r .posture $dir/rpc.json)
  spacing
  local before=$(sbpid)
  log "attach $proc:$name ($label), SpringBoard $before"
  PROBE_TIMEOUT=${PROBE_TIMEOUT:-240} $root/tools/vm-probe.zsh $vm $proc $file $dir/$proc-$name.txt 2>>$dir/probe-stderr.txt || log "rc $? for $proc:$name"
  date +%s > $stamp
  local after=$(sbpid)
  if [[ $before != $after ]]; then
    log "SPRINGBOARD PID CHANGED $before -> $after during $proc:$name"
    print "$proc:$name $before -> $after" >> $dir/springboard-restarts.txt
  fi
  grep -E '^\{"(records|orientation|group)"' $dir/$proc-$name.txt | $jq -c --arg proc $proc --arg probe $name --arg posture "$plabel" --arg bundle $bundle '
    def orient: {"0": "unknown", "1": "portrait", "2": "portraitUpsideDown", "3": "landscapeLeft", "4": "landscapeRight"}[tostring] // "unknown";
    . as $g | .records[] | {api, kind, process: $proc, posture: $posture,
      orientation: (($g.orientation // 0) | orient), call, value, error, probe: $probe, bundle: $bundle}
      + (if $g.group then {group: $g.group} else {} end)' >> $dir/records.jsonl 2>/dev/null \
    || log "no JSON from $proc:$name ($(grep -m3 -E 'error|EXC_' $dir/$proc-$name.txt | tr '\n' ' ' | cut -c1-300))"
  log "$proc:$name -> $(grep -c "\"probe\":\"$name\"" $dir/records.jsonl) records"
}

SBP=(springboard-state sensors-springboard)
case ${1:-} in
  respring)
    # Starts open at inner portrait. Fold first so the start mirrors the sim's closed boot.
    rot 90 pre-rot90 10
    pose '{"hinge":"closed","position":"closed"}' pre-closed 20
    old=$(sbpid)
    log "respring (SpringBoard $old)"
    R system.respring '{"force":true}' > $steps/fx-pre-closed/respring.json 2>&1 || true
    new=""
    for i in {1..60}; do
      sleep 3
      new=$(sbpid 2>/dev/null || true)
      [[ -n $new && $new != $old ]] && break
    done
    log "SpringBoard $old -> ${new:-none}"
    [[ -n $new && $new != $old ]] || { log "SpringBoard did not come back within 180 s"; exit 1 }
    sleep 45
    R screen.unlock '{}' | $jq -c '.result // .' | cut -c1-200 || true
    sleep 5
    spacing
    $root/tools/vm-probe.zsh $vm SpringBoard $root/probes/vm-springboard-disable-autolock.lldb $root/raw/vm/autolock/fix-disable-pid$new.txt 2>/dev/null || true
    print $new > $here/.fix-assertion-pid
    date +%s > $stamp
    log "idle-timer assertion: $(tail -c 300 $root/raw/vm/autolock/fix-disable-pid$new.txt | tr '\n' ' ')" ;;
  postures)
    snap closed-sbstart 'closed(after SpringBoard start)'
    for p in $SBP; do probe closed-sbstart SpringBoard $p; done
    pose '{"hinge":"partially-open","position":"book"}' book-after-closed
    snap book-after-closed 'book(after-closed)'
    for p in $SBP; do probe book-after-closed SpringBoard $p; done
    pose '{"hinge":"open-flat","position":"open"}' open-after-book
    snap open-after-book 'open(after-book)'
    for p in $SBP display-springboard; do probe open-after-book SpringBoard $p; done
    probe open-after-book backboardd display-backboardd
    probe open-after-book backboardd sensors-backboardd
    probe open-after-book SpringBoard sensors-identity
    probe open-after-book SpringBoard chrome-state ;;
  postures2)
    pose '{"hinge":"closed","position":"closed"}' closed-after-open
    snap closed-after-open 'closed(after-open)'
    for p in $SBP display-springboard; do probe closed-after-open SpringBoard $p; done
    probe closed-after-open backboardd display-backboardd
    pose '{"hinge":"open-flat","position":"open"}' open-after-closed
    snap open-after-closed 'open(after-closed)'
    for p in $SBP; do probe open-after-closed SpringBoard $p; done
    pose '{"hinge":"partially-open","position":"book"}' book-after-open
    snap book-after-open 'book(after-open)'
    for p in $SBP; do probe book-after-open SpringBoard $p; done
    pose '{"hinge":"closed","position":"closed"}' closed-after-book
    snap closed-after-book 'closed(after-book)'
    for p in $SBP; do probe closed-after-book SpringBoard $p; done ;;
  statusbar)
    # Starts closed. Unfold, then inner interface orientation 1 (display.rotation 0) twice:
    # once right after the rotation, once after a round trip through 180 (the sim's -2 repeat).
    pose '{"hinge":"open-flat","position":"open"}' sb-open 20
    rot 0 open-rot0
    snap open-rot0 'open[home, display.rotation 0 (inner io 1)]'
    probe open-rot0 SpringBoard chrome-state
    probe open-rot0 SpringBoard sensors-springboard
    probe open-rot0 SpringBoard springboard-state
    rot 180 open-rot180
    snap open-rot180 'open[home, display.rotation 180 (inner io 2)]'
    probe open-rot180 SpringBoard sensors-springboard
    rot 0 open-rot0-2
    snap open-rot0-2 'open[home, display.rotation 0 (inner io 1), second time, after 180]'
    probe open-rot0-2 SpringBoard chrome-state
    probe open-rot0-2 SpringBoard springboard-state
    rot 90 open-rot90 ;;
  coremotion)
    # CoreMotion managers: Safari first (a canary for sharedManager now that isAvailable is
    # YES), then SpringBoard. Starts open, inner portrait.
    app com.apple.mobilesafari
    snap open-safari-cm 'open[app:MobileSafari](CoreMotion canary)'
    probe open-safari-cm MobileSafari sensors-coremotion
    probe open-safari-cm SpringBoard sensors-coremotion
    probe open-safari-cm SpringBoard sensors-cmtables ;;
  safari)
    # What an app sees, and the per-panel pose orientation on the cover. Safari in front.
    pose '{"hinge":"closed","position":"closed"}' safari-fold 20
    app com.apple.mobilesafari
    snap closed-safari 'closed[app:MobileSafari](after-open)'
    probe closed-safari MobileSafari appkit-scenes
    probe closed-safari SpringBoard sensors-springboard
    rot 90 closed-safari-rot90
    snap closed-safari-rot90 'closed[app:MobileSafari, display.rotation 90 (landscapeRight)]'
    probe closed-safari-rot90 SpringBoard sensors-springboard
    probe closed-safari-rot90 SpringBoard springboard-state
    probe closed-safari-rot90 MobileSafari appkit-scenes
    rot 270 closed-safari-rot270
    snap closed-safari-rot270 'closed[app:MobileSafari, display.rotation 270 (landscapeLeft)]'
    probe closed-safari-rot270 SpringBoard sensors-springboard
    probe closed-safari-rot270 MobileSafari appkit-scenes
    rot 0 closed-safari-rot0
    pose '{"hinge":"partially-open","position":"book"}' safari-book 20
    snap book-safari 'book[app:MobileSafari](after-closed)'
    probe book-safari MobileSafari appkit-scenes
    probe book-safari SpringBoard springboard-state
    pose '{"hinge":"open-flat","position":"open"}' safari-open 20
    snap open-safari 'open[app:MobileSafari](after-book)'
    probe open-safari MobileSafari appkit-scenes
    probe open-safari SpringBoard springboard-state ;;
  lock)
    # Lock-screen clock and poster on the cover. Starts closed on the home screen.
    R apps.terminate '{"bundle_id":"com.apple.mobilesafari"}' >/dev/null 2>&1 || true
    pose '{"hinge":"closed","position":"closed"}' lock-fold 20
    R input.button '{"name":"power"}' | $jq -c '.result // .' | cut -c1-200 || true
    sleep 4
    R input.button '{"name":"power"}' | $jq -c '.result // .' | cut -c1-200 || true
    sleep 4
    VM_NO_UNLOCK=1 snap closed-lockscreen 'closed(lock screen via two power presses)'
    probe closed-lockscreen SpringBoard chrome-lock ;;
  final)
    R screen.unlock '{}' | $jq -c '.result // .' | cut -c1-200 || true
    pose '{"hinge":"open-flat","position":"open"}' fin-open 20
    rot 90 fin-rot90 20
    R apps.terminate '{"bundle_id":"com.apple.mobilesafari"}' >/dev/null 2>&1 || true
    R screen.unlock '{}' | $jq -c '.result // .' | cut -c1-200 || true
    snap fin-open 'open(final state)' ;;
  *) print "phases: respring postures postures2 statusbar coremotion safari lock final"; exit 2 ;;
esac
