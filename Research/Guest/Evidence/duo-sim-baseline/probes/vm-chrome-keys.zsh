#!/bin/zsh
# vm-chrome-keys.zsh <records.jsonl | chrome.json posture-label>
# The BASELINE "System chrome" values, per display: status bar provider class, statusBarFrame,
# root icon list frame + spacing, floating dock view frame, wallpaper window frame, quick
# action button frame/hidden, notification platter width, clock frame (the last three only
# exist in a lock-screen run).
set -euo pipefail
jq=/opt/homebrew/bin/jq
if [[ $1 == *.jsonl ]]; then src=($jq -s -c '[.[] | select(.probe | test("^chrome"))]' $1); else src=($jq -c --arg l "$2" '[.records[] | select(.posture == $l)]' $1); fi
"${src[@]}" | $jq -c '
  def fr: if type == "object" and has("x") then . elif type == "object" then (.frameInWindow // .frame) else . end | if type == "object" then [.x, .y, .width, .height] | map(. * 100 | round / 100) else . end;
  group_by(.display)[] | . as $r | ($r[0].display) as $d | {display: $d,
    io: ([$r[] | select(.api == "UIWindowScene.interfaceOrientation") | .value] | first),
    provider: ([$r[] | select(.api == "STUIStatusBar.visualProvider") | .value | tostring | capture("VisualProvider_(?<c>[A-Za-z0-9]+)").c] | first),
    statusBarFrame: ([$r[] | select(.api == "SBWindowSceneStatusBarManager.statusBarFrame") | .value | fr] | first),
    rootList: ([$r[] | select(.api == "SBIconListView[SBIconListView/SBIconLocationRoot#0].view") | .value | fr] | first),
    rootSpacing: ([$r[] | select(.api == "SBIconListView[SBIconListView/SBIconLocationRoot#0].effectiveIconSpacing") | .value | [.width, .height] | map(. * 100 | round / 100)] | first),
    dock: ([$r[] | select(.api == "SBFloatingDockView.view") | .value | fr] | first),
    wallpaperWindow: ([$r[] | select(.api | test("WallpaperSecureWindow.*view$|^_SBWallpaperSecureWindow.view$")) | .value | fr] | first),
    quickAction: ([$r[] | select(.api | test("^CSQuickActionsButton#0.view$")) | .value | {f: fr, hidden: .hidden}] | first),
    platterWidth: ([$r[] | select(.api | test("NCNotificationShortLookView.*view$")) | .value | .bounds.width] | first),
    clock: ([$r[] | select(.api | test("^CSProminentTimeView.view$")) | .value | fr] | first)}'
