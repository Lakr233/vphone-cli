#!/bin/zsh
# run-plan.zsh <phase>: the duobase-01 measurement sequence, one phase at a time.
# Each step drives the guest (display.posture / display.rotation / apps.launch), waits for it
# to settle, keeps the guest unlocked with SpringBoard's idle timer disabled (re-taken after a
# SpringBoard restart), then runs probes/vm-run.zsh snap. Steps are appended to raw/vm/steps/ORDER.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
run=$root/probes/vm-run.zsh
R() { vphone-launchpad-cli guest rpc duobase-01 "$@" }
sbpid() { R processes.list '{"filter":"SpringBoard"}' | /opt/homebrew/bin/jq -r '[.result.processes[] | select(.name == "SpringBoard") | .pid] | first // empty' }
last=$(cat $here/.sbpid 2>/dev/null || true)
keep() {
  local p=$(sbpid)
  if [[ $p != $last ]]; then
    print "plan: SpringBoard pid $last -> $p; settling 60 s"; sleep 60
    R screen.unlock '{}' >/dev/null 2>&1 || true
    $root/tools/vm-probe.zsh duobase-01 SpringBoard $root/probes/vm-springboard-disable-autolock.lldb $root/raw/vm/autolock/disable-pid$p.txt 2>/dev/null || true
    last=$p; print $p > $here/.sbpid
  fi
}
pose() { print "plan: posture $1"; $run posture $2 "$1"; sleep ${3:-20} }
rot() { print "plan: rotation $1"; $run rpc $2 display.rotation "{\"orientation\":\"$1\"}"; sleep ${3:-25} }
app() { print "plan: launch $1"; R screen.unlock '{}' >/dev/null 2>&1 || true; R apps.launch "{\"bundle_id\":\"$1\"}" | /opt/homebrew/bin/jq -c '.result // .'; sleep 6 }
snap() { keep; local label=$1; shift; print "plan: snap $label"; $run snap $label "$@" 2>&1 | grep -v '^vm-probe'; print $label >> $root/raw/vm/steps/ORDER }
SB=(SpringBoard:springboard-state SpringBoard:display-springboard SpringBoard:sensors-springboard)
case $1 in
  postures)
    pose '{"hinge":"closed","position":"closed"}' closed-after-open
    snap closed-after-open 'closed(after-open)' $SB SpringBoard:chrome-state SpringBoard:sensors-uikit backboardd:display-backboardd
    pose '{"hinge":"partially-open","position":"book"}' book-after-closed
    snap book-after-closed 'book(after-closed)' $SB SpringBoard:chrome-state backboardd:display-backboardd
    pose '{"hinge":"open-flat","position":"open"}' open-after-book
    snap open-after-book 'open(after-book)' $SB SpringBoard:chrome-state backboardd:display-backboardd
    pose '{"hinge":"partially-open","position":"book"}' book-after-open
    snap book-after-open 'book(after-open)' $SB
    pose '{"hinge":"closed","position":"closed"}' closed-after-book
    snap closed-after-book 'closed(after-book)' $SB
    pose '{"hinge":"open-flat","position":"open"}' open-after-closed
    snap open-after-closed 'open(after-closed)' $SB SpringBoard:chrome-state ;;
  rotations)
    rot 0 open-rot0
    snap open-rot0 'open[inner io landscapeLeft via display.rotation 0]' $SB SpringBoard:chrome-state
    rot 180 open-rot180
    snap open-rot180 'open[inner io landscapeRight via display.rotation 180]' $SB
    rot 270 open-rot270
    snap open-rot270 'open[inner io upside-down via display.rotation 270]' $SB
    rot 90 open-rot90
    snap open-rot90 'open[inner io portrait via display.rotation 90]' $SB SpringBoard:chrome-state
    pose '{"hinge":"closed","position":"closed"}' closed-home-before-rot
    rot 90 closed-rot90
    snap closed-home-rot90 'closed[home, display.rotation 90 (landscapeRight)]' $SB
    rot 0 closed-rot0 ;;
  safari)
    app com.apple.mobilesafari
    snap closed-safari-portrait 'closed[app:MobileSafari](just launched)' $SB MobileSafari:appkit-scenes MobileSafari:display-safari
    rot 90 closed-safari-rot90
    snap closed-safari-rot90 'closed[app:MobileSafari, display.rotation 90 (landscapeRight)]' $SB MobileSafari:appkit-scenes
    rot 270 closed-safari-rot270
    snap closed-safari-rot270 'closed[app:MobileSafari, display.rotation 270 (landscapeLeft)]' $SB MobileSafari:appkit-scenes
    rot 0 closed-safari-rot0
    snap closed-safari-rot0 'closed[app:MobileSafari, back to portrait]' SpringBoard:springboard-state MobileSafari:appkit-scenes
    pose '{"hinge":"open-flat","position":"open"}' open-safari-unfold
    snap open-safari-after-closed 'open[app:MobileSafari](after-closed)' $SB MobileSafari:appkit-scenes MobileSafari:display-safari
    pose '{"hinge":"partially-open","position":"book"}' book-safari
    snap book-safari-after-open 'book[app:MobileSafari](after-open)' SpringBoard:springboard-state MobileSafari:appkit-scenes
    pose '{"hinge":"closed","position":"closed"}' closed-safari-fold
    snap closed-safari-after-book 'closed[app:MobileSafari](after-book)' SpringBoard:springboard-state SpringBoard:display-springboard MobileSafari:appkit-scenes ;;
  preferences)
    app com.apple.Preferences
    snap closed-prefs 'closed[app:Preferences](just launched)' SpringBoard:springboard-state Preferences:appkit-scenes
    rot 90 closed-prefs-rot90
    snap closed-prefs-rot90 'closed[app:Preferences, display.rotation 90 (landscapeRight)]' SpringBoard:springboard-state Preferences:appkit-scenes
    rot 0 closed-prefs-rot0
    pose '{"hinge":"partially-open","position":"book"}' book-prefs
    snap book-prefs-after-closed 'book[app:Preferences](after-closed)' SpringBoard:springboard-state Preferences:appkit-scenes
    pose '{"hinge":"open-flat","position":"open"}' open-prefs
    snap open-prefs-after-book 'open[app:Preferences](after-book)' SpringBoard:springboard-state Preferences:appkit-scenes
    pose '{"hinge":"closed","position":"closed"}' closed-prefs-fold
    snap closed-prefs-after-open 'closed[app:Preferences](after-open)' SpringBoard:springboard-state Preferences:appkit-scenes ;;
  rot2)
    # Rerun of every rotation step: the first runs passed the orientation as a JSON number,
    # which display.rotation ignores (it only reads a string); those steps are in
    # raw/vm/steps/discarded/*-numeric-orientation-ignored. Starts closed with Preferences in front.
    pose '{"hinge":"closed","position":"closed"}' r2-closed 15
    app com.apple.Preferences
    rot 90 r2-closed-prefs-rot90
    snap closed-prefs-rot90 'closed[app:Preferences, display.rotation 90 (landscapeRight)]' SpringBoard:springboard-state Preferences:appkit-scenes
    rot 0 r2-closed-prefs-rot0
    app com.apple.mobilesafari
    rot 90 r2-closed-safari-rot90
    snap closed-safari-rot90 'closed[app:MobileSafari, display.rotation 90 (landscapeRight)]' $SB MobileSafari:appkit-scenes
    rot 270 r2-closed-safari-rot270
    snap closed-safari-rot270 'closed[app:MobileSafari, display.rotation 270 (landscapeLeft)]' $SB MobileSafari:appkit-scenes
    rot 0 r2-closed-safari-rot0
    snap closed-safari-rot0 'closed[app:MobileSafari, back to portrait after landscapeLeft]' SpringBoard:springboard-state SpringBoard:display-springboard MobileSafari:appkit-scenes
    R apps.terminate '{"bundle_id":"com.apple.mobilesafari"}' >/dev/null 2>&1 || true
    R apps.terminate '{"bundle_id":"com.apple.Preferences"}' >/dev/null 2>&1 || true
    sleep 5
    rot 90 r2-closed-home-rot90
    snap closed-home-rot90 'closed[home, display.rotation 90 (landscapeRight)]' $SB
    rot 0 r2-closed-home-rot0
    pose '{"hinge":"open-flat","position":"open"}' r2-open 20
    rot 0 r2-open-rot0
    snap open-rot0 'open[home, display.rotation 0 (inner landscape-left)]' $SB SpringBoard:chrome-state
    rot 180 r2-open-rot180
    snap open-rot180 'open[home, display.rotation 180 (inner landscape-right)]' $SB
    rot 270 r2-open-rot270
    snap open-rot270 'open[home, display.rotation 270 (inner upside-down)]' $SB
    rot 90 r2-open-rot90
    snap open-rot90 'open[home, display.rotation 90 (inner portrait), after rotations]' $SB SpringBoard:chrome-state ;;
  hist)
    # History rows: cover UIScreen after a landscape app, app client orientation when launched
    # on the inner. Starts open, home screen, inner portrait.
    R apps.terminate '{"bundle_id":"com.apple.Preferences"}' >/dev/null 2>&1 || true
    app com.apple.Preferences
    snap open-prefs-launched-open 'open[app:Preferences](launched on the inner)' SpringBoard:springboard-state Preferences:appkit-scenes
    pose '{"hinge":"closed","position":"closed"}' h-prefs-fold 20
    snap closed-prefs-launched-open 'closed[app:Preferences](launched on the inner, folded)' SpringBoard:springboard-state Preferences:appkit-scenes
    app com.apple.mobilesafari
    rot 90 h-closed-safari-rot90
    pose '{"hinge":"open-flat","position":"open"}' h-safari-unfold-landscape 25
    snap open-after-cover-landscape 'open[app:MobileSafari](after the cover was landscapeRight)' SpringBoard:springboard-state SpringBoard:display-springboard MobileSafari:appkit-scenes
    rot 90 h-open-rot90
    snap open-after-cover-landscape-portrait 'open[app:MobileSafari, inner portrait](after the cover was landscapeRight)' SpringBoard:display-springboard ;;
  *) print "phases: postures rotations safari preferences rot2 hist"; exit 2 ;;
esac
