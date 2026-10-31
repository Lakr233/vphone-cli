# appkit: what an app sees on the iPhone Duo simulator

Domain notes for `appkit.json` (20 829 records, 54 posture runs). Simulator
`duo-baseline-appkit` (E5E4D334-6E6E-4021-A3A4-DA0A743C8B64), iOS 27.1 24A94425,
Xcode 27.1. All values are as observed; enums are listed in `appkit.json` `meta.enums`.

## Files

| Path | What |
| --- | --- |
| `appkit.json` | all records, README format plus `scenario`, `device_orientation_requested`, `transcript` |
| `probes/appkit-scenes.lldb` | the probe: process, screens, every connected scene, its FBSScene settings and client settings, trait collection, status bar, every window, root view controller, view-controller tree with split state |
| `probes/appkit-introspect.lldb`, `probes/appkit-hinge-classes.lldb` | getter enumeration (`class_copyMethodList` / properties / ivars) used to choose the getters; output in `raw/appkit/introspect-*.txt` |
| `probes/appkit-run.zsh` | driver: posture, launch, probe, screenshots, callback log per state |
| `probes/appkit-merge.zsh` | builds `appkit.json` from `raw/appkit/<app>/<scenario>/records.jsonl` |
| `src/appkit/probe-app/` | VPAppKitProbe source (`main.m`, `Info.plist`, `build.zsh`) |
| `raw/appkit/<app>/<scenario>/` | per state `NN-<label>.txt` (transcript), `.json` (probe output), `.posture.json`, `shots/NN-<label>-d{1,3}.png`, `posture/` (posture.zsh artifacts), `events.jsonl` (VPAppKitProbe callback log) |

Apps: Preferences (SwiftUI `SettingsNavigationSplitView`), MobileSafari, and
VPAppKitProbe, a minimal ObjC UIKit app built for this run (all four orientations in
Info.plist, one window scene, `UIDeviceFamily` 1, a `UIHingeInteraction` on its root view)
that logs every scene, geometry, trait, screen and hinge callback. No Notes / Calendar
exists in this runtime (`simctl listapps`).

## Per app, portrait device orientation

Columns: screen the scene is on, `effectiveGeometry.coordinateSpace.bounds`,
horizontal/vertical size class, interface orientation, window `safeAreaInsets`
(top,left,bottom,right).

| app | posture | screen | scene bounds | size classes | orientation | safe area |
| --- | --- | --- | --- | --- | --- | --- |
| VPAppKitProbe | closed | screens[0] LCD Main | 466×678 | C/R | portrait | 0,0,34,84 |
| VPAppKitProbe | book, open | screens[1] LCD-1 Unknown.main[3] | 951×669 | R/R | landscapeRight | 0,0,34,84 |
| Preferences | closed | screens[0] LCD Main | 466×678 | C/R | portrait | 0,0,34,84 |
| Preferences | book, open | screens[1] LCD-1 | 951×669 | R/R | landscapeRight | 0,0,34,84 |
| MobileSafari | closed | screens[0] LCD Main | 466×678 | C/R | portrait | 0,0,34,84 |
| MobileSafari | book, open | screens[1] LCD-1 | 951×669 | R/R | landscapeRight | 82,0,34,0 |

- `[UIScreen mainScreen]` is the cover (`LCD`, `Main`) in every posture. `[UIScreen screens]`
  has **1** entry when closed and **2** in book/open: the inner `UIScreen` exists in the app
  only while the inner panel is lit (`UIScreenDidConnectNotification` on unfold,
  `…DidDisconnect…` on fold). Inner `nativeBounds` 2007×2853, `scale` 3; its `bounds` follow
  the interface orientation (951×669 landscape, 669×951 portrait). No 669×951-at-boot effect
  was seen in apps (the README's SpringBoard history effect); the connect notification
  carries `{669, 951}` for an instant before the scene settles at 951×669.
- `userInterfaceIdiom` is Phone (0) everywhere, also on the inner panel with regular/regular.
- The cover status bar is vertical (`statusBarAxis` 1, `UIStatusBarManager.statusBarFrame`
  466×2), so the cover's safe area is right 84 rather than top. On the inner panel in
  landscape the probe app and Preferences keep right 84; Safari reports top 82 (its client
  `statusBarAxis` 0, horizontal).
- Preferences is portrait-only (`supportedInterfaceOrientations` mask 2, scene
  `_currentlySupportedInterfaceOrientations` 2) yet runs landscapeRight (4) on the inner
  panel in every posture. Safari and the probe app: scene mask 26 (no upside-down); the probe
  app's `supportedInterfaceOrientationsForWindow` is 30.
- Corners: `FBSSceneSettings.cornerRadiusConfiguration` cover (8, 8, 59, 59), inner 55 on all
  corners; `UITraitCollection.displayCornerRadius` and `UIScreen._displayCornerRadius` are
  59 in every posture (`_displayCornerRadius` does not exist on UITraitCollection).
- `ssk_surfaceType` (FBSScene settings, ShellSceneKit): cover 1, inner 2, 4 while a launch is
  still in progress; the probe app does not load ShellSceneKit (does not respond).

## Book vs open

Book and open give the same bounds, size classes and orientation. What differs:

- `FBSSceneSettings.sceneRegions`: the inner scene has `inner` {{0,0},{669,951}},
  `innerRear` {{0,0},{669,475.5}}, `innerCover` {{0,475.5},{669,475.5}}, `fold` (boundary)
  {{0,455.5},{669,40}} margins {20,0,20,0}, `innerCamera` (exclusion, inactive),
  `statusBarOcclusion` {{0,0},{124,84}}. In **book** `innerCover` is `active: YES`, in
  **open** `active: NO`. The cover scene has `cover`, `coverCamera`, `statusBarOcclusion`.
- Preferences' split view: `primaryColumnWidth` **475.67 in book** (the sidebar ends at the
  fold), **320 in open**; client `primaryWindowOverlayInsets.left` 495.67 vs 320. Screenshots:
  `raw/appkit/Preferences/launch-closed/shots/02-book_after-closed_-d3.png` and `03-open_after-book_-d3.png`.
- Hinge state: `_UISceneHingeStateClientComponent.hingeState` partiallyOpen 100° / openFlat
  180°; scene settings `sceneHingeState` partiallyOpen / fullyOpen. Only scenes whose client
  sets `wantsSceneHingeState` get it: the probe app (has a UIHingeInteraction) and Safari
  always, Preferences never (nil). The separate `FBSSceneSettings.hingeAngle/hingeStatus/
  magicPose` getters stay 0 in every posture.
- Public `UIHingeInteraction`: closed status 1 angle 0; book status 2 angle 1.745 (radians);
  open status 3 angle 3.142. Updates stream during the sweep (10–23 per transition).
- No geometry callback between book and open.

## Device orientation (`posture.zsh -deviceOrientation=`)

The swap's device orientation reaches apps (`UIDevice.orientation` and scene orientation):

| posture | requested | probe app / Safari orientation, bounds | Preferences | `UIDevice.orientation` |
| --- | --- | --- | --- | --- |
| open, book | landscapeLeft | portrait, 669×951, safe 82,0,34,0 | portrait 669×951, split 250.33 | 3 |
| open, book | landscapeRight | portraitUpsideDown, 669×951 | portraitUpsideDown 669×951 | 4 |
| closed | landscapeLeft | landscapeRight, 678×466, C/C | portrait 466×678 | 4 |
| closed | landscapeRight | landscapeLeft, 678×466, C/C | portrait 466×678 | 3 |

The inner panel is landscape-native, so a landscape device is a portrait inner panel, and
the inner panel allows upside-down even for portrait-only Preferences. On the cover,
`UIDevice.orientation` is the opposite of the requested name (landscapeLeft → 4), on the
inner panel it matches (landscapeLeft → 3). Cover landscape `statusBarFrame` is 0×0.

## Migration and callbacks

- The scene **migrates**: same `UIWindowScene`, same `persistentIdentifier`, same windows;
  it stays `foregroundActive` through every fold and unfold (no scene lifecycle callback,
  no reconnect). Unfold moves it to `screens[1]` (FBS display `Unknown.main[3]`, hosting
  space `SB-display-<inner UUID>`); fold moves it back to `Main`.
- Probe-app callback order on unfold (`book(after-closed)`): hinge updates status 1→2, a few
  deprecated `windowScene:didUpdateCoordinateSpace:…` calls with no change, then within ~1 ms
  `UIScreenDidConnectNotification` → `windowScene:didUpdateEffectiveGeometry:` (466×678
  portrait → 951×669 landscapeRight) → KVO `effectiveGeometry` → `viewWillTransitionToSize`
  → trait change C→R → layout. Geometry lands ~110 ms after the hinge status flips to 2.
  On fold: trait change R→C first, then `didUpdateEffectiveGeometry:` (→ 466×678 portrait),
  `viewWillTransitionToSize`, then `UIScreenDidDisconnectNotification`; ~70 ms after the
  status flips to 1. Exactly one `didUpdateEffectiveGeometry:` per fold/unfold. The
  deprecated delegate method still fires (7–12 times per transition). Full sequences:
  records `VPAppKitProbe.callbackSequence`, raw logs `raw/appkit/VPAppKitProbe/*/events.jsonl`.
- `UIWindowSceneGeometry.systemFrame` is {inf, inf, 0, 0} and
  `UIApplication.statusBarFrame` {inf, inf, 0, 0} (recorded as the strings "inf");
  `UIScreen.applicationFrame` has NaN y/height.

## History-dependent values

Same posture, different path (all in `appkit.json`; compare `posture` labels):

- `FBSSceneClientSettings.interfaceOrientation` and `UIWindow._sceneClientOrientation`: 1 when
  the app was launched on the cover and unfolded, 4 when it had been on the inner panel
  first; after folding back to the cover from an inner launch they stay **4** on the cover
  (portrait UI). Preferences shows the same.
- `FBSSceneSettings.statusBarAvoidanceFrame`: y 951 after an unfold from closed, 0 otherwise.
- `UIWindowScene._hasOrientationDependentSafeArea{Edge,Corner}Insets`: true after an unfold
  from closed, false after an inner launch (book/open).
- Launch timing: 6 s after `simctl launch` Preferences and Safari launched on the inner
  panel were still `foregroundInactive` (activationState 1, `deactivationReasons` 32, root
  view 0×0, no scene regions, Safari `wantsSceneHingeState` NO). The `launch-settled`
  scenario repeats both launches with 15 s; use those as the steady state.

## Missing / nil / errors

- nil everywhere: `UIWindowScene.sizeRestrictions`, `.windowingBehaviors`, `.focusSystem`,
  `UITraitCollection.typesettingLanguage`, `FBSDisplayConfiguration.uniqueIdentifier`,
  `FBSSceneSettings.traitCollection`, `FBSSceneClientSettings.pairedSceneDisplayConfiguration`,
  `.requestedDisplayMode`, `.displayConfigurationRequest`.
- nil for some: `UISceneConfiguration.name` (Preferences, Safari), hinge state (Preferences
  always; Safari mid-launch), `sceneRegions` / `systemShellHostingSpaceIdentifier` mid-launch,
  `UITraitCollection.deviceDeterminedConfiguration` (Preferences, Safari).
- does not respond: `UITraitCollection._displayCornerRadius` (all), and
  SpringBoard-category getters in apps that do not load those frameworks
  (`ssk_surfaceType`, `sbsui_surfaceTypeClient`, `sb_supportsResizing`, `avkit_screenType`,
  `sbh_screenType`, `sbf_displayProxyIdentifier`, `pui_fbsDisplayIdentity`,
  `isSmallScreenDevice`).
- No fold/hinge/posture trait exists on UITraitCollection (method list enumerated).
- `UIApplication.currentHingePoseStateForTesting` is {0,0,0,0} in every posture.

## Harness notes

- Background apps cannot be probed: the sim suspends them and the lldb expression hangs
  until the watchdog (a VPAppKitProbe probe timed out this way). Probe only the foreground app.
- `simctl launch` of an app that already has a process did not bring it to the front here;
  the driver terminates and relaunches.
- In lldb expressions here `@try` is unavailable and any ObjC exception aborts the whole
  expression: `FBSSettings` throws from `valueForKey:`, and `NSJSONSerialization` throws on
  NaN/inf. The probe calls getters through `NSInvocation` after `respondsToSelector:` and
  turns non-finite numbers into strings. lldb symbol collisions also hit block parameters
  named `d`, `key` and `obj`; `strchr` fails to resolve (use NSString).
- A wait loop using `pgrep -f <script>` matches its own command line; avoid it.
