#!/bin/zsh
# vm-app-keys.zsh <records.jsonl [process] | appkit.json process posture-label>
# The BASELINE "What an app sees" values from appkit-scenes records: screens count, main screen,
# the scene's screen and bounds, size classes, interface orientation, window safe area, idiom,
# corner radii, ssk_surfaceType, scene regions (identifier + active), split column width,
# hinge state, UIDevice.orientation.
set -euo pipefail
jq=/opt/homebrew/bin/jq
if [[ $1 == *.jsonl ]]; then src=($jq -s -c --arg p "${2:-}" '[.[] | select(.probe == "appkit-scenes" and ($p == "" or .process == $p))]' $1)
else src=($jq -c --arg p "$2" --arg l "$3" '[.records[] | select(.process == $p and .posture == $l)]' $1); fi
"${src[@]}" | $jq -c '
  def v($a): [.[] | select(.api == $a) | .value] | first;
  {process: (.[0].process), screens: v("UIScreen.screens"), main: v("UIScreen.mainScreen"), sceneScreen: v("UIWindowScene.screen"),
   screenBounds: (v("UIWindowScene.screen.bounds") | if type == "object" then [.width, .height] else . end),
   io: v("UIWindowScene.interfaceOrientation"), hsc: v("UITraitCollection.horizontalSizeClass"), vsc: v("UITraitCollection.verticalSizeClass"),
   safe: (v("UIWindow.safeAreaInsets") | if type == "object" then [.top, .left, .bottom, .right] else . end),
   idiom: v("UIDevice.userInterfaceIdiom"), deviceOrientation: v("UIDevice.orientation"),
   corners: (v("FBSSceneSettings.cornerRadiusConfiguration") | tostring | .[0:90]),
   ssk: v("FBSScene.ssk_surfaceType"),
   regions: (v("FBSSceneSettings.sceneRegions") | tostring | [scan("identifier: com\\.apple\\.springboard\\.([A-Za-z]+)")] | map(.[0]) | join(",")),
   innerCoverActive: (v("FBSSceneSettings.sceneRegions") | if . == null then null else tostring | split("_UISceneRegion") | map(select(test("innerCover>"))) | first // "" | (capture("active: (?<a>YES|NO)")? // {a: null}).a end),
   hinge: v("_UISceneHingeStateClientComponent.hingeState"),
   split: (v("UISplitViewController.state") | if type == "object" then .primaryColumnWidth * 100 | round / 100 else . end),
   clientIO: v("FBSSceneClientSettings.interfaceOrientation")}'
