# chrome: SpringBoard chrome layout metrics (iPhone Duo simulator)

Simulator `duo-baseline-chrome` (A9C09C26-9AD3-4DF7-809D-E155D2D3F544), iOS 27.1 24A94425, Xcode 27.1.
Output: `chrome.json` (127,674 records, 31 runs, compact JSON, about 54 MB). Raw transcripts: `raw/chrome/`.
Screenshots: `raw/chrome/shots/<run>-{state,lock,hinge}-d{1,3}.png`.

## Files

| Path | What |
| --- | --- |
| `probes/parts/chrome-*.inc` | probe sources: lib (generic getter walk), emit helpers, scene, statusbar, home, wallpaper, lock, hinge, footer |
| `probes/chrome-build.zsh` | assembles `probes/chrome-state.lldb`, `chrome-lock.lldb`, `chrome-hinge.lldb` (one lldb expression each) |
| `probes/chrome-run.zsh` | `posture` (retries once after a status check on exit 3), `state`, `lock` (lock, push 3 notifications, probe, unlock) |
| `probes/chrome-assemble.zsh` | merges the transcripts into `chrome.json` |
| `probes/chrome-discover-*.lldb` | discovery probes (window lists, view trees, class introspection); output in `raw/chrome/discover-*` |
| `raw/chrome/<run>-{state,lock}.txt.gz` | cleaned probe transcripts (gzipped; the `.raw.txt.gz` beside each one is lldb's unedited output) |
| `raw/chrome/<run>-posture.json` | posture.zsh result for each run; `raw/chrome/posture/` holds the posture driver's artifacts |
| `raw/chrome/payloads/` | the `simctl push` payloads (com.apple.Preferences is the only bundle authorized in this sim) |

## Method

- The values come from introspection in SpringBoard, not from guesses. For each object, the probe takes every
  declared ObjC property and every zero-argument method whose name looks like a getter, through the class chain
  down to UIView, UIViewController or NSObject. It reads each one with KVC. A name filter skips
  mutators (`vpDeny`), and only object, scalar or pointer-free struct return types are read.
  Struct values made only of doubles are decoded as `{objCType, fields}`. `*.view` records give
  `frameInWindow` (`convertRect:bounds toView:window`), frame, bounds, transform, layer transform, hidden,
  alpha, safeAreaInsets, and label text and font size or image size where the view has them.
- The probes only read. The exceptions are the actions the matrix needs: the posture swap (`tools/posture.zsh`),
  `lockUIFromSource:1` and `_finishUIUnlockFromSource:14` on the primary scene's `SBLockScreenManager`, and
  `simctl push`. One experimental `[[UIDevice currentDevice] setOrientation:]` call (1, then 3) was made
  during `open-landscapeLeft` before it was clear how orientation works. It changed nothing; SpringBoard
  stayed at 1. Nothing was swizzled. CSQuickActionImageGlyphView was only read.
- Getters that crash or throw are skipped everywhere. They are listed in `meta.skipped_getters`.
- `chrome.json` leaves out two kinds of records, which are still in the transcripts. The first is pointer-only
  object descriptions that have no layout keyword. The second is non-layout getters on large state
  controllers. See `meta.omitted*`.

## Orientation: what actually happens

The cover (SB-main) is **always interface orientation 1** for every `-deviceOrientation`, both on the home
screen and on the lock screen. The inner scene does rotate. It follows the swap's `-deviceOrientation` with
a 90° offset, which matches the panel's native 270° rotation:

| -deviceOrientation | inner interfaceOrientation | inner layout |
| --- | --- | --- |
| portrait | 4 (landscapeLeft) | landscape-shaped 951×669 windows |
| portraitUpsideDown | 3 (landscapeRight) | landscape-shaped 951×669 |
| landscapeLeft | 1 (portrait) | portrait-shaped 669×951 |
| landscapeRight | 2 (portraitUpsideDown) | portrait-shaped 669×951 |
| none: first unfold from closed(boot) | 1 | **landscape-shaped 951×669, the same as 4**. This is a history artifact: the windows were never re-laid out for 1 |

`UIScreen` / `coordinateSpace` bounds for the inner stay 669×951 throughout this run. That run had already
unfolded, so compare the README's 669×951 → 951×669 note for inner `UIScreen.bounds`, which
`screens.json` covers. `chrome.json` names orientations with UIKit interface-orientation names
(3 = landscapeRight, 4 = landscapeLeft). **`tools/smoke.zsh` maps 3 → landscapeLeft and 4 → landscapeRight,
which is the UIDeviceOrientation mapping, not the interface one.** The README says the field is the interface
orientation, so smoke.json's names for 3/4 would be swapped. Smoke only saw 1, so it is unaffected.

## Key metrics (points, window coordinates)

Status bar
- Cover: `STUIStatusBarVisualProvider_AxisAlignableSplitV68Cover` (→ AxisAlignableSplit → Split → Phone → iOS).
  It is a vertical **right-hand status column**. `UIStatusBarManager.statusBarFrame` = {389,0,77,678};
  wrapper `currentHeight`/`defaultHeight` 77; `_statusBarFrameIgnoringVisibility` {0,0,466,77}.
  The foreground view is {378,0,88,176.33}. Sensor/cutout: `sensorAreaRect` = `effectiveSensorAreaRect` =
  cutout guide = `UIScreen._exclusionArea` = {399,30,37,37}. `avoidanceFrame` is {399.67,29.33,37,37}.
  Time label {≈400,83,≈36,19.33} (rounded bold 16 pt), round battery {394.67,106.67,47,47}.
  `isVerticalLayout` YES; `_verticalCombinedBoundingBoxHeight` 104; `_peripheryInsets` top 50.67;
  display corner radius 59.
- Inner: `STUIStatusBarVisualProvider_AxisAlignableSplit2007` (→ AxisAlignableSplit2670 → AxisAlignableSplit).
  - Landscape-shaped (4/3): foreground {863,0,88,123.67}, time at {≈885,30.33}, battery {879.67,54,47,47}.
    `UIStatusBarManager.statusBarFrame` = **{0,0,0,0}** and wrapper `currentHeight` **0**.
  - Portrait-shaped (1/2): foreground {581,0,88,123.67}, `statusBarFrame` {592,0,77,951}, height 77.
  - `effectiveSensorAreaRect` is {0,0,0,0} on the inner. `sensorAreaRect` still reports the cover's
    {399,30,37,37}. The cutout guide is empty.

Home screen
- Root grid on both displays: 4 columns × 6 rows (`maximumIconCount` 24). Icons are 60×60 at scale 3 with a
  15.6 corner radius; the icon view is 60×74. Label font is SFUI-Medium 12 pt (label config: baseline offset 16,
  height 26, extra width 37).
- Cover: portrait insets {top 54, left 27, bottom 70, right 115}, with the right inset reserved for the side
  dock. `effectiveIconSpacing` is 28×38.8. The list spans {0,0,466,678}; the first icon is at {27,54}.
  `numberOfLandscape*` is 0 (no landscape config).
- Inner: portrait insets {82,145.5,219,145.5} and landscape insets {54,0,65,0}; landscape rows×cols 6×4;
  `effectiveIconSpacing` 28×38.
  - Landscape-shaped: the list is 324 wide, at x=470 (open), 459.33 (open after landscapeRight) or
    512.67 (book), and 669 tall.
  - Portrait-shaped: the list spans {0,0,669,951}; the first icon is at {145.67,82}.
- Dock: `SBFloatingDock*` (iPad-style floating dock). `SBDockView` is not present. The dock list grid is
  1×4 portrait, 4×1 landscape (capacity 4). Dock icons are 60×60 in a 48×48 list cell.
  - Cover: the side dock is a vertical column at the right edge. `SBFloatingDockView` {376.17,45,84,678};
    platter 72×72 at {382.17,348} for 1 icon; `floatingDockHeight` 84.
  - Inner landscape-shaped: also a right-hand column, {861.17,45,84,669}.
  - Inner portrait-shaped: a horizontal bottom dock, {0,851,669,100}; `floatingDockHeight` 100;
    platter 244×92.
  - The search button (48×48) sits under the dock: {394.33,606} on the cover, {879.33,597} on the inner.
- App Library (`SBHLibraryPodFolderView`) and the Today view list exist on both displays.
- Wallpaper: `_SBWallpaperSecureWindow` is **portrait-anchored**. It stays {0,0,669,951} on the inner even
  while every other inner window is 951×669; on the cover it is 466×678. The wallpaper is a PosterBoard
  scene (`PBUIPosterSceneLayerHostView`). `SBWallpaperController` exists per scene, and its
  `wallpaperConfigurationManager` reports wallpaperSize {466,678} with wallpaperSizeType "iPhone (N56)".
  `SBWallpaperHingeProgressController` stores no progress value. It only gates: `_enabled` and
  `_backlightOn` are YES on the lit display and NO on the other.

Lock screen (cover sheet)
- Quick actions: two `CSQuickActionsButton`s, **84×84**, both at the same frame. They are **hidden** in every
  posture and orientation of this simulator.
  - Positions: cover {376,573}; inner landscape-shaped {861,564}; inner portrait-shaped {579,846}.
  - Button: `iconImageSize` 48×48, `edgeInsets` 18 on all sides, `containerCornerRadius` 24.
  - `CSQuickActionImageGlyphView`: frame 27×25 at {28.67,29.67} in the button ({10.67,11.67} in the
    48-point icon area). Transform and layer transform are identity. contentMode 1 (aspect fit).
  - The image is 19.33×18 at @3x, so it renders aspect-fit at about 26.85×25.
  - Ratios: glyph/button width 0.321, height 0.298; glyph/iconImage 0.5625; image/glyph-view 0.716.
  - **Caveat:** the image is the SF symbol `questionmark.app`. The simulator has no torch or camera
    action configured, so this is a placeholder glyph, not the flashlight or camera glyph.
- Notifications. Three pushes to Preferences group into one stack of `NCNotificationShortLookView`s:
  - Cover: platter width **350** (bounds); the structured list is 370 at x=12 at boot and 378 at x=8 after open.
  - Inner, open, both shapes: platter **450**; list 478, centred at x=236.5 (landscape-shaped) or x=95.5
    (portrait-shaped).
  - Inner, book, landscape-shaped: platter **350**; list 378 at x=498.25 (or 370 at 502.25), i.e. on the
    right half. Inner, book, portrait-shaped: 450.
  - The stacked platters behind are scaled 0.94 and 0.88. Short-look continuous corner radius is 23.5.
- Clock: `CSProminentTimeView`. The time is drawn by a SwiftUI `TitleLabelView`, so no UIFont is readable.
  - Cover {11,47,372,132.26}.
  - Inner open landscape-shaped {275.5,51.67,400,132.26}; book {487.25,51.67,400,132.26} (right half);
    portrait-shaped {134.5,64.67,400,132.26}.
  - The date (`_UIAnimatingLabel`) is SFUI-Semibold 22 pt.

## Missing / nil / errors

- On the cover, during open/book lock runs, `CSCombinedListView(Controller)`, `NCNotificationStructuredList*`,
  `NCNotificationListView`, and `CSProminentTimeView` are nil: the cover sheet content is on the inner.
  The reverse holds in `closed-after-open`: the inner `SBCoverSheetWindow` still exists but has no content.
  In `closed-boot` (never unfolded) the inner scene has no `SBCoverSheetWindow` at all.
- Skipped because they crash or throw: `SBWindowScene.liftToWakeController` (stack overflow),
  `UIWindowScene._preferredIntelligentAssistantVisibility` / `…Configuration` /
  `SBSUI_preferredSystemRootLayerTransform`, `SBIconView.iconImageAlignment`, and
  `SBIconListPageControl.maximumNumberOfPages`.
- `SBHIconListLayoutProvider` location constants were resolved with dlsym where they exist. The call text
  marks the ones where a literal was used instead.
- Present but empty or zero: inner `UIStatusBarManager.statusBarFrame` (landscape-shaped),
  inner `effectiveSensorAreaRect`.
