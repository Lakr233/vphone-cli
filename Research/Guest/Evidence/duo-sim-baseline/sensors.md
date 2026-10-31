# Sensors baseline: hinge, pose, motion and device identity

Domain `sensors` of the iPhone Duo simulator baseline (iPhone19,4, iOS 27.1
24A94425, Xcode 27.1). Simulator `duo-baseline-sensors`
(`C0EF5D72-68AE-4F00-8594-10039EADA1AC`, a clone of `duo-baseline-harness`).
Records: `sensors.json` (README "Record format", plus two extra fields per
record: `group`, the probe expression it came from, and `sim_note`, set when
the value is synthetic or sim-only). Raw transcripts: `raw/sensors/snap/`.

## Files

| Path | What |
| --- | --- |
| `sensors.json` | every record, `meta.postures` holds each `posture.zsh` result in snapshot order |
| `probes/sensors-springboard.lldb` | group `pose`: `SBFDevicePoseProvider` (struct decoded field by field), its settings, observers, source chain, `UIApplication currentHingePoseStateForTesting` |
| `probes/sensors-coremotion.lldb` | group `coremotion`: `CMMagicPoseManager`, `CMDeviceStateManager`, `CMAngleManager`, `CMMotionManager` availability; SpringBoard's own CM managers |
| `probes/sensors-cmtables.lldb` | group `cmtables`: the string tables, `propertyAForConfigType:…`, `orientationForMagicPose:deviceSurface:`, magic pose → device state mapping |
| `probes/sensors-cmquery.lldb` | group `cmquery`: `-[CMDeviceStateManager queryDeviceStateBlocking]` |
| `probes/sensors-uikit.lldb` | group `uikit`: every zero-argument `UIDevice` getter (enumerated with `class_copyMethodList`), requested hinge getters, per-scene hinge state (client component, `FBSSceneSettings`), SpringBoard's `FBSceneWorkspace` scenes |
| `probes/sensors-identity.lldb` | group `identity`: `MGCopyAnswer` for 527 keys, `MGGetLogicalDeviceDisplayCount`, `MGCopyAnswerForDisplayAtIndex`, `sysctl`, `uname`, simulator environment |
| `probes/sensors-backboardd.lldb` | group `hid`: backboardd's HID services, the hinge-angle service and its last events, event processors |
| `probes/sensors-app-hinge-register.lldb` | not a record source: registers a no-op hinge observer in Preferences (see "App side") |
| `probes/sensors-discover-*.lldb` | discovery dumps (method/ivar/property lists, class scans) → `raw/sensors/discovery/` |
| `src/sensors/run-sensors.zsh` | runner: `posture`, `snapshot`, `assemble` |
| `raw/sensors/sim-notes.jq` | the rules that set `sim_note` |
| `raw/sensors/identity/` | the device type's `capabilities.plist` / `profile.plist` as JSON (the source of many MobileGestalt answers), and the MG key list |
| `raw/sensors/snap/<nn>-<posture>/` | per snapshot: transcripts (`<process>-<probe>.txt` and `.raw.txt`), `records.jsonl`, `posture.json` |
| `raw/sensors/posture/` | `posture.zsh` artifacts (screenshots, readbacks) for this simulator |
| `raw/sensors/test/` | probe development runs, including the SIGABRT bisect |

## Snapshot order (history matters)

| # | posture label | how | mode |
| --- | --- | --- | --- |
| 00 | `boot` | fresh boot, no swap yet (cover lit, CoreMotion's own values) | full |
| 01 | `book(after-closed)` | `posture.zsh book` (anchors closed, sweeps to 100°) | full |
| 02 | `open(after-book)` | `open` | full |
| 03 | `closed(after-open)` | `closed` (fold from open) | full |
| 04 | `open(after-closed)` | `open` (unfold from closed) | light |
| 05 | `book(after-open)` | `POSTURE_ANCHOR=none book` | light |
| 06 | `closed(after-book)` | `closed` | light |
| 07/08 | `closed(landscapeLeft/Right)` | `closed -deviceOrientation=…` | light |
| 09/10 | `book(landscape…,after-closed)` | `book -deviceOrientation=…` | light |
| 11/12 | `open(landscape…)` | `open -deviceOrientation=…` | light |
| 13/14 | `open(portrait,…)`, `closed(portrait,…)` | back to portrait | light |
| 15 | `closed(after-open,final)` | no swap; full rerun with the extended CoreMotion tables (tabletop 0..11) | full |

`full` = SpringBoard (pose, coremotion, uikit, cmtables, identity, cmquery),
backboardd (hid), Preferences (coremotion, uikit, cmtables, identity, cmquery).
`light` drops cmtables, identity and cmquery (posture-independent; checked
identical in 00–03). Every posture.zsh run verified (exit 0).

`orientation` in each record is the scene's interface orientation, as the
README defines it (SpringBoard: the primary window scene; Preferences: its
own window scene; backboardd and the posture-independent groups take
SpringBoard's). The device orientation passed to the display tool is in the
posture label. They differ on the inner panel, which is mounted a quarter
turn from the cover: Preferences on the inner reports interface orientation
4 (landscapeRight) for a portrait device, 1 for device landscapeLeft and 2
for device landscapeRight; on the cover it stays 1 (Preferences and the home
screen do not rotate on the cover). SpringBoard's primary scene is `SB-main`
(1) when closed and `com.apple.springboard.bringup` when open. The bringup
scene's interface orientation depends on history: it stayed 1 through the
portrait book/open/closed runs (00–09, including book landscapeLeft), became
2 with a landscapeRight device (10, 12), and after the landscape runs it was
**4** for open portrait (13) and stayed 4 on the dark inner panel after
closing (14). So `open` portrait reads SpringBoard orientation 1 in
`open(after-book)` but 4 in `open(portrait,after-open)`; compare against the
VM with the same history.

## What is synthetic (do not align the VM to these)

The simulator has no hinge, accelerometer, gyro or magnetometer. Three
different sources answer, and only one of them follows the posture driver:

1. **SpringBoard's display tool (follows the posture).**
   `posture.zsh` runs `SBDisplayToolServiceCoordinator`, which pushes
   `SBFSyntheticCMAngle` / `SBFSyntheticMagicPoseEvent` through
   `SBFDevicePoseProvider`. Everything downstream of the provider follows the
   posture: `currentPose` (hinge state/position/regions, `cmAngle`,
   `cmMagicPose`, `uiHingeStatus`, cover/inner orientation), the
   `FBSSceneSettings` hinge fields SpringBoard sends to scenes, the scene
   hinge client components, Preferences' `_UIHingeState`, `UIDevice
   orientation`, and SpringBoard's `currentHingePoseStateForTesting`. These
   are the values the VM is meant to reproduce, but their CoreMotion-shaped
   fields are synthetic: `cmMagicPose.hingeState` is 3 (OpenFlat) after
   *every* swap, closed included, and `cmAngle.timestamp` only becomes
   non-zero once the tool has run. `sim_note` says "synthetic: written by
   SpringBoard's display tool sweep".
2. **CoreMotion / locationd (frozen at the boot value).** In the sim,
   locationd's `CMDeviceStateRelayManager` publishes two virtual HID services
   into backboardd: `CoreMotion_DeviceStateRelay_Crane` (usage page 0xFF0C,
   usage 0x21, the hinge angle; `ReportInterval` 10000, event mask bit 0x2C)
   and `CoreMotion_DeviceStateRelay_DeviceState` (0xFF0C / 0x22, vendor
   defined). Their last events, the device state CoreMotion hands out
   (`propertyA` 1 portrait, `propertyB` 1 closed, timestamp 319060.797), and
   the device state SpringBoard's own `CMMagicPoseManager` received are the
   same in every snapshot: closed, 0°, portrait, timestamps unchanged. Nothing
   the posture driver does reaches CoreMotion or HID. `sim_note` says "sim
   has no hardware backing".
3. **Host / CoreSimulator (sim-only).** `sysctl hw.model` `Mac17,9`,
   `hw.target` `J714sAP`, `kern.*` (host macOS 27.0.1), the `SIMULATOR_*`
   environment, `UIDevice name` (the sim's name), and MobileGestalt answers
   that come from the host (`ProductTypeDesc*` `Mac17,9`, `HWModelDescription*`
   `J714sAP`, `HardwarePlatform` `t6050`, `DeviceMemorySize` 64 GB, `CPU*`,
   `IsSimulator` true, `device-name` "iPhone Simulator") or from the device
   type's `capabilities.plist` (screen, artwork, DeviceSupports* entries it
   lists). These do not exist in this form on the VM.

## SpringBoard's pose path (source chain)

- `-[SpringBoard devicePoseProvider]` is one `SBFDevicePoseProvider`; the same
  instance sits in `SBDisplayToolService`, `SBDisplayToolServiceCoordinator`,
  `SBDisplayContentModeCoordinator` (also its `likelyTransitionDelegate`),
  `SBHingeMotionUnintendedInteractionMonitor` and
  `SBAmbientPresentationCoordinator` (`raw/sensors/discovery/springboard-selectors.txt`).
- Its inputs: `_cmAngleManager` (a `CMAngleManager`, `isAngleActive` YES,
  interval 0.01 s), `_cmMagicPoseManager` (its own `CMMagicPoseManager`, not
  `+sharedManager`; its `CMDeviceStateManager` is registered for
  notifications and holds the boot device state), `_accelerometer` **nil**,
  and the display tool, which overwrites the pose. Its heartbeat source is
  the `SB-main` scene.
- Observers (record `SBFDevicePoseProvider._observers`): scene region
  updaters, `SBDisplayContentModeCoordinator`, `SBFDisplayContentModeResolver`,
  `SBHomeScreenController`, two `SBTraitsEmbeddedDisplayPipelineManager`,
  `SBBiometricOcclusionMonitor` ×2, `AMAmbientPresentationTriggerManager`,
  the UI scene controllers, and SpringBoard itself.
- `currentPose.internal.isOnVM` is **NO** in the sim (worth comparing: the
  provider has a VM flag), `isDisplaySupport3Set` NO, `hingeRegionsAreDefault`
  YES, `usesStrictCoreMotion` NO, `invertHingeAngles` NO,
  `flipState.isAvailable` NO, `continuousFoldEnabled` YES, transition style 2.
- Boundaries (`SBFDevicePosePTSettings`): opens at 5°, closes at 175°, flat
  at 175°; swap degrees 85 (continuous live), 20/85 (snapshot open/close),
  85 (fade). `settings.closedToPartiallyOpenBoundary` moves with history: 85
  at boot, 20 after a sweep that ended open.
- Hinge regions move with history (provider description): at boot `closed`
  is 0.00→0.47; after book 0.00→0.28 (partiallyOpen 0.28→0.97, toClosed
  0.56→0.03); after a fold from open or book 0.00→0.11. Open is the same from
  either path.

| snapshot | hinge state @ position | uiHingeStatus {status, magicPose, angle} | pose orientation / cover / inner | cmMagicPose {orient, cover, inner, hinge} |
| --- | --- | --- | --- | --- |
| boot | 1 closed @ 0 | 1, 0, 0 | 1 / 1 / 1 | 1, 1, **0**, **1** (CoreMotion's own) |
| book(after-closed) | 2 partiallyOpen @ 0.556 | 2, 3, 100 | 1 / 1 / 1 | 1, 1, 1, 3 |
| open(after-book) | 3 openFlat @ 1 | 3, 0, 180 | 1 / 1 / 1 | 1, 1, 1, 3 |
| closed(after-open) | 1 @ 0 | 1, 0, 0 | 1 / 1 / 1 | 1, 1, 1, 3 |
| open(after-closed), book(after-open), closed(after-book) | same as the rows above for that posture | | | |
| closed(landscapeLeft) | 1 @ 0 | 1, 0, 0 | 3 / 4 / 3 | 3, 4, 3, 3 |
| closed(landscapeRight) | 1 @ 0 | 1, 0, 0 | 4 / 3 / 4 | 4, 3, 4, 3 |
| book(landscapeLeft) | 2 @ 0.556 | 2, 5, 100 | 3 / 4 / 3 | 3, 4, 3, 3 |
| book(landscapeRight) | 2 @ 0.556 | 2, 6, 100 | 4 / 3 / 4 | 4, 3, 4, 3 |
| open(landscapeLeft) | 3 @ 1 | 3, 0, 180 | 3 / 4 / 3 | 3, 4, 3, 3 |
| open(landscapeRight) | 3 @ 1 | 3, 0, 180 | 4 / 3 / 4 | 4, 3, 4, 3 |
| open(portrait), closed(portrait) after landscape | as open / closed portrait | | 1 / 1 / 1 | 1, 1, 1, 3 |

`uiHingeStatus.magicPose` uses the tabletop pose numbering (3
PartiallyOpenPortrait, 5 PartiallyOpenLandscapeLeft), not CoreMotion's hinge
state. `UIDevice orientation` (SpringBoard and Preferences alike) is the lit
panel's device orientation: closed landscapeLeft → 4 (the cover's), book
landscapeLeft → 3 (the inner's).

## App side (Preferences)

- `_UISceneHingeStateClientComponent` exists on every scene but holds no
  state until something observes it (`wantsSceneHingeState: NO`,
  `hingeState` nil). `probes/sensors-app-hinge-register.lldb` registers one
  no-op observer per scene, the way `UIHingeInteraction` does: a runtime class
  `VPSensorsHingeObserver` whose callback IMP is `-[NSObject self]`, kept alive
  by an associated object on `UIApplication` (no block escapes). After that
  the component reports, per posture: closed `status` 1 / angle 0, book
  `status` 3 / `magicPose` 3 / angle 100, open `status` 4 / angle 180. Note
  the numbering differs from SpringBoard's `uiHingeStatus.status` (1/2/3).
- Preferences' `FBSSceneSettings` hinge fields (`hingeAngle`, `hingeStatus`,
  `magicPose`, …) stay 0 in every posture; the state arrives in
  `sceneHingeState` instead.
- `UIApplication currentHingePoseStateForTesting` is {0,0,0,0} in
  Preferences in every posture (it is SpringBoard's testing state; in
  SpringBoard it follows the pose, e.g. {3,3,3,0} for closed landscapeLeft).
- CoreMotion in the app: same frozen device state as SpringBoard;
  `queryDeviceStateBlocking` returns nil at once in both processes.

## HID (backboardd)

- `[[BKHIDSystem sharedInstance] IOHIDServicesMatching:nil]` lists 15
  services (an empty dictionary matches none; `IOHIDEventSystemCopyServices`
  on its `_HIDEventSystem` gives the same 15). Two are CoreMotion's virtual
  relays (`Transport` Virtual, `VendorID`/`ProductID` 0xFF00):
  - `CoreMotion_DeviceStateRelay_Crane`, `PrimaryUsagePage` 0xFF0C,
    `PrimaryUsage` 0x21 — the same usage pair the VM's Hinge dylib publishes.
    `IOHIDServiceCopyEvent(svc, 0x2C)` returns a hinge-angle event:
    `AngleDegrees` 0, `MechanicalAngleDegrees` 0, velocity NaN, `State`
    Closed, phase Changed, with a vendor-defined child (usage 0x80, 21 bytes).
  - `CoreMotion_DeviceStateRelay_DeviceState`, 0xFF0C / 0x22: last event is
    vendor defined, data `02 01 01 00 01 00 00 01`.
- Both events carry the same timestamps (mach 7657459129569 / …269) in every
  snapshot: **the posture driver produces no HID hinge event**; it bypasses
  HID and CoreMotion entirely and writes SpringBoard's pose provider. On the
  VM, which injects `IOHIDEventCreateHingeAngleEvent` into a 0xFF0C/0x21
  virtual service, the event path is real; in the sim it only carries the
  boot value.
- No `BK*`/`Sim*`/`HID*` class with "hinge" in its name is loaded in
  backboardd; `BKHIDEventProcessorRegistry` has no hinge processor (list in
  `BKHIDEventProcessorRegistry.eventProcessors`). `HIDVirtualEventService`
  exists. `-[BKHIDSystem systemEventOfType:0x2C …]` returns the DeviceState
  relay's vendor event, not a hinge event.
- The rest are the simulator's HID services (SimulatorHID: digitizers 0x0D/0x04
  for each display, keyboard, buttons, game controller, Indigo `0xacefade…`
  services); full properties in `IOHIDService.properties`.

## UIDevice

Every zero-argument getter of `UIDevice` (instance and class, from
`class_copyMethodList`) is recorded; serial/UDID/vendor-identifier getters,
allocators and `_tapticEngine` are recorded as skipped. Highlights:
`model`/`localizedModel` "iPhone", `systemName` "iOS", `systemVersion` "27.1",
`userInterfaceIdiom` 0, `sf_productType` "iPhone19,4", `_hasTouchPad` YES,
`_supportsForceTouch` NO, `_nativeScreenGamut` 1, `_feedbackSupportLevel` 0,
`batteryLevel` -1, `+_hasHomeButton` NO. There is **no** hinge, tabletop,
posture or fold getter on `UIDevice` in iOS 27.1: `hingeState`,
`tabletopPose`, `_hingeState`, `hingeAngle`, `isFoldable`, `_isFoldable`,
`foldState`, `posture`, `_userInterfaceIdiom` and `_deviceOrientation` all
fail `respondsToSelector:` (recorded with that error).
`+[UIDevice currentDeviceOrientationAllowingAmbiguous:YES]` is 0 in SpringBoard
in every posture, while in Preferences it follows the lit panel's device
orientation like `-orientation` (1 portrait, 3/4 for book landscape).

## CoreMotion mapping tables (posture-independent)

Identical in every full snapshot, in SpringBoard and Preferences.
`+[CMMagicPoseManager orientationForMagicPose:deviceSurface:]` equals
`+[CMDeviceStateEvent propertyAForConfigType:surface propertyA:orientation
propertyB:hinge propertyC:tabletop]` for every input (checked row by row;
`createDeviceStateEventFromMagicPoseEvent:` copies orientation, hinge state
and tabletop pose unchanged). In the sim `sharedManager` exists, unlike the
VM. Rows: result for device orientation A = 0..7 (0 Ambiguous, 1 Portrait,
2 UpsideDown, 3 LandscapeLeft, 4 LandscapeRight, 5 FaceUp, 6 FaceDown, 7
invalid). All rows not listed are 0 (ambiguous).

| surface / configType | hinge B | tabletop C | A = 0..7 → |
| --- | --- | --- | --- |
| 0 and 1 (cover) | 1 Closed | any 0..11 | 0,1,2,3,4,5,6,7 (identity) |
| 0 and 1 | 2 PartiallyOpen, 3 OpenFlat | 0 or 11 | 0,1,2,**4,3,6,5**,0 (L/R and face up/down swapped) |
| 0 and 1 | 2, 3 | 1/2/3/4/5/6/7/8/9/10 | constant 3/4/1/2/6/3/4/5/6/1 |
| 2 (inner) | 1 Closed | any | 0 (ambiguous) |
| 2 | 2, 3 | 0 or 11 | 0,1,2,3,4,5,6,0 (identity) |
| 2 | 2, 3 | 1, 2 | 0 |
| 2 | 2, 3 | 3/4/5/6/7/8/9/10 | constant 1/2/3/4/6/6/5/1 |
| any | 0, 4 OpenAmbiguous, 5 OpenTransitioning, 6 | any | 0 |
| 3, 4 | any | any | 0 (CoreMotion logs "Invalid configType: 3") |

Against FoldDisplay's hard-coded mapping (VM, commit bb690532): B 1 → cover
takes A, inner ambiguous: **matches**. B 2/3 → inner takes A, cover takes A
with L/R and face up/down swapped: **matches for tabletop 0** (and 11). B 4
and others → ambiguous: **matches**. Not covered by the VM's mapping: a
non-zero tabletop pose with B 2/3 replaces A with a constant (table above),
and orientation 7 maps to 0 when open. Surface 0 behaves like surface 1.

String tables (`stringFor…` records): magic pose hinge state 0 Ambiguous, 1
Closed, 2 PartiallyOpen, 3 OpenFlat, 4 OpenAmbiguous, 5 OpenTransitioning;
tabletop 1 ClosedLandscapeLeft, 2 ClosedLandscapeRight, 3
PartiallyOpenPortrait, 4 …PortraitUpsideDown, 5 …LandscapeLeft, 6
…LandscapeRight, 7 PartiallyOpenFaceDown, 8 OpenFlatFaceDown, 9
OpenFlatFaceUp, 10 OpenFlatPortrait; device state properties are named
ParameterA… (B: 9 = Max, C: 11 = Max).

## Identity (MobileGestalt, sysctl, environment)

527 `MGCopyAnswer` keys (list: `raw/sensors/identity/mg-keys-queried.txt`,
taken from the strings of the sim's `libMobileGestalt.dylib` filtered to
screen/fold/device-class/layout/identity names, plus every key in the device
type's `capabilities.plist`, plus a few guessed fold keys that come back nil).
Values are identical in SpringBoard and Preferences and in every posture.
Selected answers: `ProductType`/`HWModelStr`/`SubProductType`/
`ThinningProductType` iPhone19,4; `DeviceClass` iPhone, `DeviceClassNumber` 1;
`ModelNumber`/`RegulatoryModelNumber` A3447; `DeviceVariant` A;
`marketing-name` "iPhone Duo"; `HomeButtonType` 2; `DeviceCornerRadius` 59;
`HasThinBezel`, `IsLargeFormatPhone`, `DeviceSupportsDynamicIsland`,
`DeviceSupportsAlwaysOnDisplay`(+Flipbook, AlwaysOnTime) true;
`DeviceSupportsEnhancedMultitasking` and `…SingleDisplayEnhancedMultitasking`
false; `main-screen-width/height/scale/pitch` 1398/2034/3/460 (the cover);
`ScreenCaptureWidth/Height` 1398/2034; `ArtworkTraits` phone, subtype 2034,
scale 3, P3, "iPhone Duo", APPLE11; `DisplayExtendedProperties` two entries:
cover (`DeviceSurfaceType` 1, rotation 0, corners 8,8,59,59) and inner
(`DeviceSurfaceType` 2, rotation 270, corners 55×4);
`MGGetLogicalDeviceDisplayCount` 2. Nil in the sim: `DeviceSurfaceType`,
`main-screen-class`, `main-screen-orientation`, `MainScreenClass`,
`MainScreenScale`, `MainDisplayRotation`, `DisplayBootRotation`,
`MainScreenCanvasSizes`, `ScreenDimensions(Capability)`, `idiom`, `subtype`,
`HasPartiallyOccludedDisplay`, `OLEDDisplay`, `DisplayMaxNits`, and every
fold/hinge-named key tried. `MGCopyAnswerForDisplayAtIndex` returns nil for
all ten `kMGDisplayIndexedQuery*` keys at indices 0..2 (the keys are
self-pointers; both call forms tried, `raw/sensors/discovery/mg-display-index.txt`).

## Missing, nil or errored

- `UIDevice` has no `hingeState`, `tabletopPose`, `_hingeState`, `hingeAngle`,
  `isFoldable`, `_isFoldable`, `foldState`, `posture`, `_userInterfaceIdiom`,
  `_deviceOrientation`.
- `SBFDevicePoseProvider._accelerometer` nil.
- `+[CMFactoryAngleManager isAvailable]` raises SIGABRT in SpringBoard
  (`raw/sensors/test/bisect.txt`); recorded as not called.
- `-[CMDeviceStateManager queryDeviceStateBlocking]` nil in both processes.
- `SBFDevicePoseDefaults lastKnownCMAngleDictionary` /
  `lastKnownCMMagicPoseDictionary` nil.
- `CMMotionManager` accelerometer/gyro/magnetometer/deviceMotion unavailable,
  `availableAttitudeReferenceFrames` 0 (yet MG `accelerometer`,
  `magnetometer` true from capabilities.plist).
- Scene hinge client components on SpringBoard's system-aperture scenes: nil
  state; on the app scene: nil until an observer registers.
- MobileGestalt: see the nil list above; 249 of 527 keys are nil.

## Harness notes and workarounds

- lldb expressions here reject messages to `id` and `@try`; locals are typed
  `NSObject *`, chained KVC is cast at each step, scalar ivars are read
  through `class_getInstanceVariable` + offset (KVC on CoreMotion internals
  aborted), `strrchr`/`strstr`/`isnan`/`isinf` do not link (use NSString and
  comparisons). A sanitizer turns NaN/Inf into strings before
  `NSJSONSerialization` (the hinge HID event's velocity is NaN).
- `IOHIDServicesMatching:@{}` matches nothing; pass nil.
- `posture.zsh` defaults `POSTURE_OUT` to the shared `raw/posture`; the runner
  sets `raw/sensors/posture`.
- `SpringBoard` responds to `devicePoseProvider` but not to
  `_displayToolService` (that is only an ivar), so `respondsToSelector:` must
  test the former to detect SpringBoard.
- App scene persistent identifiers are UUIDs (Preferences' was
  `20901331-…` for the whole run); join app-scene records on the display
  identity in the `call` (`on Main` / `on Unknown.main[3]`), not the UUID.
