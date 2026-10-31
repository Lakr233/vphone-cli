#!/bin/zsh
# chrome-assemble.zsh: merge raw/chrome/<label>-{state,lock}.txt into chrome.json (README record format plus
# extra fields: run, screen, display, scene, deviceOrientation, sceneInterfaceOrientation).
set -euo pipefail
root=${0:a:h:h}; cd $root
jq=/opt/homebrew/bin/jq
U=A9C09C26-9AD3-4DF7-809D-E155D2D3F544
work=$(mktemp -d -t chromeasm); trap 'rm -rf "$work"' EXIT
# label | posture(path) | deviceOrientation passed to the swap | note
runs=(
  "closed-boot|closed(boot)|none|fresh boot, never unfolded; lock screen captured first (locked at boot by lldb lockUIFromSource:1), then home after unlock"
  "open-after-closed|open(after-closed)|none|first unfold: closed(boot) -> open, no -deviceOrientation"
  "open-landscapeLeft|open(after-open)|landscapeLeft|open -> open with -deviceOrientation=landscapeLeft"
  "open-landscapeRight|open(after-open)|landscapeRight|after open-landscapeLeft"
  "open-portrait-after-landscapeRight|open(after-open)|portrait|after open-landscapeRight"
  "open-portraitUpsideDown|open(after-open)|portraitUpsideDown|after open-portrait-after-landscapeRight"
  "open-landscapeLeft-2|open(after-open)|landscapeLeft|after open-portraitUpsideDown (repeat of open-landscapeLeft from another orientation)"
  "closed-after-open|closed(after-open)|portrait|fold: open(landscapeLeft) -> closed with -deviceOrientation=portrait"
  "closed-landscapeLeft|closed(after-closed)|landscapeLeft|closed -> closed"
  "closed-landscapeRight|closed(after-closed)|landscapeRight|closed -> closed"
  "closed-portraitUpsideDown|closed(after-closed)|portraitUpsideDown|closed -> closed"
  "book-after-closed|book(after-closed)|portrait|posture.zsh book anchors at closed (instant) then sweeps to 100 deg"
  "book-landscapeLeft|book(after-book)|landscapeLeft|book -> book (POSTURE_ANCHOR=none)"
  "book-landscapeRight|book(after-book)|landscapeRight|book -> book (POSTURE_ANCHOR=none)"
  "book-portraitUpsideDown|book(after-book)|portraitUpsideDown|book -> book (POSTURE_ANCHOR=none)"
  "open-after-book|open(after-book)|portrait|book -> open"
  "closed-after-book|closed(after-book)|portrait|book -> closed (the hinge probe ran here too)"
  "book-hinge|book(after-closed)|portrait|closed -> book (anchored); supplemental SBWallpaperHingeProgressController probe only"
  "open-hinge|open(after-book)|portrait|book -> open; supplemental SBWallpaperHingeProgressController probe only"
)
print -n '[]' > $work/recs.json; print -n '[]' > $work/runs.json
for r in $runs; do
  IFS='|' read -r label posture devo note <<< "$r"
  for screen in state lock hinge; do
    f=raw/chrome/$label-$screen.txt
    [[ -e $f ]] || f=$f.gz
    [[ -e $f ]] || continue
    gzcat -f $f | grep '^{"' > $work/one.json || { print -u2 "no JSON in $f"; continue }
    scr=$(case $screen in (state) print home ;; (lock) print lockScreen ;; (hinge) print home-hingeProbe ;; esac)
    $jq -c --arg run "$label" --arg posture "$posture" --arg devo "$devo" --arg screen "$scr" '
      def orient: {"1": "portrait", "2": "portraitUpsideDown", "3": "landscapeRight", "4": "landscapeLeft"}[tostring] // "unknown";
      .records | map(select((.api | test("^(SBRootFolderView|SBRootFolderController|SBHIconManager|SBHomeScreenController|CSCoverSheetViewController|SBFloatingDockViewController|SBFloatingDockRootViewController|CSProminentDisplayViewController|CSCombinedListViewController|NCNotificationStructuredListViewController|SBIconListView\\[[^]]*\\]\\.firstIconView)\\.[^.]+$")) and ((.api | sub(".*\\."; "")) | test("size|height|width|frame|inset|rect|spacing|count|scale|layout|style|mode|orientation|font|row|column|margin|padding|region|bounds|offset|alignment|position|radius|length|gap|center|origin|edge|metric|configuration|progress|factor|alpha|transform|placement|location|axis|side|display|visible|hidden|grid|max|min|page|dock|label|library|today|widget|sidebar|class|rotat|fold|hinge|cover|notification|list|clock|date|time|quick|button|glyph|image"; "i") | not) | not) | select(((.value|type) == "string" and (.value|test("^<[^>]*0x[0-9a-f]+")) and ((.api + .value)|test("font|Font|Constraint|LayoutGuide|Configuration|Placement|frame|Size|Insets|Orientation|orientation|Display|Screen|Mode|Style|style")|not)) | not)
        | {api, kind, process: "SpringBoard", posture: $posture, orientation: (.sceneOrientation | orient),
        call: (.call | sub("\\[SBWindowScene <SB-main>\\]"; "[cover]") | sub("\\[SBWindowScene <com.apple.springboard.bringup>\\]"; "[inner]")), value, error, run: $run, screen: $screen, display})' $work/one.json > $work/part.json
    $jq -s '.[0] + .[1]' $work/recs.json $work/part.json > $work/n.json && mv $work/n.json $work/recs.json
    pj=null; [[ -e raw/chrome/$label-posture.json ]] && pj=$(cat raw/chrome/$label-posture.json)
    $jq --arg label "$label" --arg posture "$posture" --arg devo "$devo" --arg note "$note" --arg screen "$scr" --arg t "$f" --arg ftag "$screen" \
      --argjson prim "$($jq -c '{primaryScene, primaryOrientation}' $work/one.json)" --argjson pj "$pj" \
      '. + [{run: $label, screen: $screen, posture: $posture, deviceOrientation: $devo, note: $note, transcript: $t,
             screenshots: ["raw/chrome/shots/\($label)-\($ftag)-d1.png", "raw/chrome/shots/\($label)-\($ftag)-d3.png"],
             primary: $prim, posture_driver: $pj}]' $work/runs.json > $work/n.json && mv $work/n.json $work/runs.json
  done
done
runtime=$(xcrun simctl list runtimes -j | $jq -c '.runtimes[] | select(.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-1") | {identifier, version, buildversion}')
device=$(xcrun simctl list devices -j | $jq -c --arg u $U '.devices[] | .[] | select(.udid == $u) | {name, udid, deviceTypeIdentifier}')
xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')
$jq -c -n --argjson runtime "$runtime" --argjson device "$device" --arg xcode "$xcode" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)" \
  --slurpfile runs $work/runs.json --slurpfile recs $work/recs.json '
  {meta: {domain: "chrome", runtime: $runtime, device: $device, xcode: $xcode, host: $host, date: $date,
    posture_mechanism: "SBDisplayToolServiceCoordinator performDisplaySwapWithSettings: (tools/posture.zsh), driven by probes/chrome-run.zsh",
    probes: ["probes/chrome-state.lldb (home: scene, status bar, home screen, dock, wallpaper)", "probes/chrome-lock.lldb (lock screen: scene, status bar, cover sheet)"],
    probe_sources: "probes/parts/*.inc assembled by probes/chrome-build.zsh",
    record_extras: {run: "joins meta.runs[].run (posture path, -deviceOrientation passed to the swap, screenshots, transcript)", screen: "home | lockScreen | home-hingeProbe", display: "cover (scene SB-main, call prefix [cover]) | inner (scene com.apple.springboard.bringup, call prefix [inner])"},
    orientation_names: "orientation is the UIInterfaceOrientation of the scene the record belongs to: 1 portrait, 2 portraitUpsideDown, 3 landscapeRight, 4 landscapeLeft (UIKit interface-orientation names; note smoke.zsh maps 3/4 the device-orientation way)",
    skipped_getters: {"SBWindowScene.liftToWakeController": "EXC_BAD_ACCESS (stack overflow) when read with -valueForKey: + -description", "UIWindowScene._preferredIntelligentAssistantVisibility": "ObjC exception", "UIWindowScene._preferredIntelligentAssistantConfiguration": "ObjC exception", "UIWindowScene.SBSUI_preferredSystemRootLayerTransform": "ObjC exception", "SBIconView.iconImageAlignment": "ObjC exception", "SBIconListPageControl.maximumNumberOfPages": "ObjC exception", note: "the generic getter walk (probes/parts/chrome-lib.inc vpSkip) skips these names on every object; no record is emitted for them"},
    probe_versions: "all home runs used probes/chrome-state.lldb without the hinge part; the hinge part was added afterwards and run alone as probes/chrome-hinge.lldb (runs closed-after-book, book-hinge, open-hinge, screen home-hingeProbe)",
    omitted_state: "for the state-holding controllers and the first icon view (SBRootFolderView, SBRootFolderController, SBHIconManager, SBHomeScreenController, CSCoverSheetViewController, SBFloatingDock*ViewController, CSProminentDisplayViewController, CSCombinedListViewController, NCNotificationStructuredListViewController, SBIconListView[...].firstIconView) only getters whose name has a layout word (size, frame, inset, spacing, count, scale, layout, style, orientation, font, row, column, margin, bounds, offset, radius, position, alignment, configuration, visible, hidden, page, dock, label, icon image ...) are kept; the rest are in the raw transcripts",
    omitted: "records whose value is only an object -description with a pointer and no layout keyword (font|Constraint|LayoutGuide|Configuration|Placement|frame|Size|Insets|Orientation|Display|Screen|Mode|Style) are left out of chrome.json; they are in the raw transcripts",
    value_conventions: "frames in points; *.view records: frameInWindow = [view convertRect:view.bounds toView:view.window]; objects as -description truncated to 400 chars (pointer values included); structs of doubles decoded as {objCType, fields}; non-finite numbers as strings",
    runs: $runs[0]},
   records: $recs[0]}' > chrome.json
print -- "chrome.json: $($jq '.records | length' chrome.json) records, $($jq '.meta.runs | length' chrome.json) runs, $(du -h chrome.json | cut -f1)"
