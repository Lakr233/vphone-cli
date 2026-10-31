#!/bin/zsh
# chrome-run.zsh <verb> <label> [posture args...]
#   posture <label> <closed|book|open> [swap options]   drive posture (retry once on exit 3), save JSON
#   state <label>      run probes/chrome-state.lldb in SpringBoard + screenshots
#   lock <label>       lock (SBLockScreenManager lockUIFromSource:1 on the primary scene), post 3 test
#                      notifications to com.apple.Preferences (simctl push), run probes/chrome-lock.lldb,
#                      screenshots, then unlock (_finishUIUnlockFromSource:14 withOptions:nil; unlockUIFromSource: returned NO here)
# Artifacts: raw/chrome/<label>-{posture.json,state.txt,lock.txt}, raw/chrome/shots/<label>-*.png
set -euo pipefail
here=${0:a:h}; root=${here:h}; cd $root
U=A9C09C26-9AD3-4DF7-809D-E155D2D3F544
out=raw/chrome; mkdir -p $out/shots $out/posture
verb=$1; label=$2; shift 2
lsm='NSObject *vpLSM = nil; NSObject *vpDCM = [[[UIApplication sharedApplication] valueForKey:@"_displayToolService"] valueForKey:@"_displayContentModeCoordinator"]; UIScene *vpP = (UIScene *)[vpDCM valueForKey:@"primaryWindowScene"]; vpLSM = [vpP valueForKey:@"lockScreenManager"];'
case $verb in
  posture)
    rc=0; POSTURE_OUT=$out/posture tools/posture.zsh $U "$@" > $out/$label-posture.json || rc=$?
    if (( rc == 3 )); then
      print -u2 "chrome-run: posture $* did not verify; status, wait 11 s, retry"
      POSTURE_OUT=$out/posture tools/posture.zsh $U status > $out/$label-posture-status.json || true
      sleep 11; rc=0; POSTURE_OUT=$out/posture tools/posture.zsh $U "$@" > $out/$label-posture.json || rc=$?
    fi
    /opt/homebrew/bin/jq -c '{posture, swap_options, hinge: .springboard.hinge_state, pos: .springboard.position, lit: .screenshots.lit_panel, ok}' $out/$label-posture.json
    exit $rc ;;
  state)
    tools/probe.zsh $U SpringBoard probes/chrome-state.lldb $out/$label-state.txt
    tools/sim.zsh shot $U $out/shots $label-state
    grep -q '^{' $out/$label-state.txt || { print -u2 "chrome-run: no JSON in $label-state.txt"; exit 1 } ;;
  lock)
    tools/probe.zsh $U SpringBoard - $out/$label-lockcmd.txt <<EOT
expr -l objc -O -- $lsm ((void (*)(id, SEL, int, id))objc_msgSend)(vpLSM, @selector(lockUIFromSource:withOptions:), 1, nil); [NSString stringWithFormat:@"locked via %@ isUILocked=%@", [vpP valueForKey:@"_persistenceIdentifier"] ?: vpP.session.persistentIdentifier, [vpLSM valueForKey:@"isUILocked"]]
EOT
    sleep 2
    for f in Preferences.json pref-2.json pref-3.json; do
      p=$out/payloads/$f; [[ $f == Preferences.json ]] && p=$out/payloads/com.apple.Preferences.json
      xcrun simctl push $U com.apple.Preferences $p >/dev/null
    done
    sleep 4
    tools/probe.zsh $U SpringBoard probes/chrome-lock.lldb $out/$label-lock.txt
    tools/sim.zsh shot $U $out/shots $label-lock
    tools/probe.zsh $U SpringBoard - $out/$label-unlockcmd.txt <<EOT
expr -l objc -O -- $lsm ((void (*)(id, SEL, int, id))objc_msgSend)(vpLSM, @selector(_finishUIUnlockFromSource:withOptions:), 14, nil); @"unlock requested"
EOT
    sleep 3
    tools/probe.zsh $U SpringBoard - $out/$label-unlockcheck.txt <<EOT
expr -l objc -O -- $lsm [NSString stringWithFormat:@"isUILocked=%@", [vpLSM valueForKey:@"isUILocked"]]
EOT
    grep isUILocked $out/$label-unlockcheck.txt | tail -1
    grep -q '^{' $out/$label-lock.txt || { print -u2 "chrome-run: no JSON in $label-lock.txt"; exit 1 } ;;
  *) sed -n '2,9p' ${0:a}; exit 2 ;;
esac
