# iPhone Duo simulator baseline: alignment table

Ground truth for vphone-duo, collected 2026-10-29 from Apple's iPhone Duo
simulator (iPhone19,4, V68, iOS 27.1 24A94425, Xcode 27.1). The simulator
folds through SpringBoard's own display-swap coordinator (README.md, "Posture").

The `vphone-duo` column was filled on 2026-10-29 from the VM `duobase-01`
(bundle 2.14.0-local.21dc0c06, upstream main 82afdb9a, two-display Duo path),
iPhone19,4 / iOS 27.1 24A94425, with the simulator probes run in the guest
through `tools/vm-probe.zsh` (VM versions `probes/vm-*.lldb`; why they are
needed is in `vm-notes.md`). Each cell gives the VM value, then **match**,
**differs** or **n/a**. Rows that were marked **VM differs** before the column
was filled say whether the measurement confirmed or corrected that note.
Method, step list and caveats: `vm-notes.md`. VM data: `vm-*.json`, raw
transcripts `raw/vm/steps/<step>/`.

On 2026-10-30 the rows the duo-sim-align fix can affect were measured again on
`duobase-01` with bundle **2.14.0-local.9064efca** (branch duo-sim-align:
V68 `product-id`, `/product/display0`+`display1` panel nodes, CoreMotion's
device-state relay fed through `VPhone Host Controls`). The pose now reaches
SpringBoard through CoreMotion, not through the test-automation override.
Those cells give the new value; where it changed, "(was: …)" holds the first
pass. Rows not named in "Changes since the first VM pass" were not re-measured
unless their cell says so. Records: the `vm-*.json` records with
`"bundle": "2.14.0-local.9064efca"` and `step` `fx-<label>`; transcripts
`raw/vm/steps/fx-<label>/`; method and the two incidents of this pass in
`vm-notes.md` ("2026-10-30").

## Diff summary

Remaining **differs** rows, most consequential first (state after the
2026-10-30 pass). Struck items are aligned now.

1. **Auto-lock / AOD.** The VM has no always-on display (`DeviceSupportsAlwaysOnDisplay` NO, `BLSHBacklightHost deviceSupportsAlwaysOn` NO). Auto-lock in open turns the inner fully off (backlight 4) instead of AOD (3); folding while auto-locked gives FullyClosed with the cover primary on the lock screen but **off** (4), inner off. The old note "VM lights the folded inner display" did not reproduce: the inner stayed off and blanked.
2. **Inner display identity** (not changed by the fix; another session owns the names). CADisplay `VPhone Duo Inner` / `VPhone Duo Inner` / displayId 7 (sim `LCD-1` / `primary-1` / 3); FBS identity `Unknown[7]` (sim `Unknown.main[3]`), not UIKitMainLike; `UIScreen._isEmbeddedScreen` NO; UIScreen display corner radius 0, sRGB. Re-read on 2026-10-30: unchanged.
3. **Inner display mode.** Now 2007×2853 @3 like the sim (was: native 2853×2007 at pointScale 1), but **120 Hz** (sim 60 Hz), **sRGB** (sim P3), and FBS/UIScreen still list a second mode, 2853×2007 (951×669 @3). The cover runs 120 Hz (sim 60 Hz).
4. **MobileGestalt identity.** `ModelNumber` VM0001 (sim A3447), `RegulatoryModelNumber` nil, `HWModelStr` V68AP (sim iPhone19,4), AOD keys NO. ~~`DisplayExtendedProperties` nil, logical display count 1~~: aligned (item 5 of "Changes").
5. **Display power model** (not re-measured beyond the posture rows; `stateControl` still nil). No `CADisplayStateControl` on any CADisplay. The cover `LCD` is the one real panel (the composited output) and is never blanked while the guest is awake, also in book/open; the inner window-server display is enabled when unfolded and blanked when closed. The sim blanks the cover when open.
6. **Digitizer** (not re-measured). One `Virtual USB Touch Screen` (USB, builtIn) as `mainDisplayDigitizerService`, re-routed to the inner UUID while unfolded; the sim has one CoreDevice touchscreen per panel.
7. **Resolver transition style at a SpringBoard start.** 2 `.continuousLive` right after a SpringBoard start in closed (sim 1 `.fade` until the first swap). After a swap it now matches: 2 in every posture, 3 with Safari in front (was: 0 at start, then 1, 2 or 3 by path).
8. **Per-panel pose orientation when closed.** Device landscapeRight (4) gives cover 4 and landscapeLeft (3) cover 3, now computed by CoreMotion (`cmMagicPose` cover 4 / 3); the sim gives cover 3 / 4. CoreMotion's own table (identical in the sim) maps a closed hinge to the cover unchanged, so the sim's value comes from its synthetic swap-tool pose. Open matches.
9. **Cover corner radii.** `extendedProperties` and MobileGestalt `DisplayExtendedProperties` say [5,5,59,59] (Apple's device tree); the sim's device type says [8,8,59,59]. Everything else in both dictionaries matches.
10. **Pixel density.** Both panels 460×460 ppi (was: inner 0 / nil); the sim reads 316×669 (cover) and 324×654 (inner). The physical sizes are the sim's (3.0391×4.4217 and 4.3630×6.2022 in) with width and height swapped; the sim's ppi is the native pixel size divided by those swapped axes.
11. **Book angle, residual.** 99.444° (position 0.552, closed region 0→0.2747, toClosed 0.5525→0.03) against the sim's synthetic 100° (0.556, 0→0.2761, 0.5556→0.03) (was: 90°, 0.500, 0→0.25). The host controls send 100 and the provider's mechanical angle is 100; CoreMotion's angle is 99.444 (= 100 × 179/180). Not investigated further.
12. **Auto-lock default.** The VM runs the real Auto-Lock (60 s; timer warn 40 s, total 60 s); the sim holds the `SBDisableAutoDim` assertion. Configuration, not behaviour.

Aligned or reclassified by the 2026-10-30 pass (details in the next section):
~~CoreMotion is absent~~; ~~inner `extendedProperties` carry only DeviceSurfaceType~~;
~~MobileGestalt `DisplayExtendedProperties` nil / display count 1~~;
~~hinge HID: one unnamed 0xFF0C/0x21 service~~; ~~book at 90°~~;
~~inner portrait-shaped `statusBarFrame` 0-rect~~; ~~transition style 1/2/3 by
path after a swap~~; lock-screen clock height: **personalization** (the VM's
lock screen uses another poster, `v68.colorB`, with a taller adaptive time;
see "System chrome").

Corrected notes: the VM **does** turn the cover landscape for Safari (678×466,
C/C, `statusBarFrame` 0×0, like the sim); the CoreMotion tabletop and A=7
table rows **match** (they are CoreMotion's own class methods, not
FoldDisplay); the folded inner does **not** light after auto-lock.

## Changes since the first VM pass

Bundle 2.14.0-local.21dc0c06 → 2.14.0-local.9064efca, same VM, same iOS.

| # | item | first pass | now | sim |
|---|---|---|---|---|
| 1 | pose source | test-automation override (`display.pose`) | CoreMotion: `SBFDevicePoseProvider` reads `CMAngleManager` / `CMMagicPoseManager`; `display.posture` replies `source: coremotion` | swap tool writes the provider |
| 2 | book angle / position | 90° / 0.500 | 99.444° / 0.552 (`uiHingeStatus` 99.444, `cmAngle` 99.444, mechanical 100) | 100° / 0.556 |
| 3 | hinge regions in book | closed 0→0.25, toClosed 0.50→0.03 | closed 0→0.2747, toClosed 0.5525→0.03 | 0→0.2761, 0.5556→0.03 |
| 4 | CoreMotion managers | `+isAvailable` NO ×3, `sharedManager` nil, provider managers nil, `_accelerometer` BKSAccelerometer | `+isAvailable` YES ×3; `sharedManager` non-nil and not the provider's (`isSharedManager` NO); provider `_cmMagicPoseManager` registered with both handlers, `_cmAngleManager` active at 0.01 s; `_accelerometer` nil; `currentDeviceState` live | the same objects, frozen at boot values; `_accelerometer` nil |
| 5 | MobileGestalt screen | `DisplayExtendedProperties` nil, `MGGetLogicalDeviceDisplayCount` 1 | 2 entries equal to the sim's except the cover corners; count 2 | 2 entries; 2 |
| 6 | `extendedProperties` | `{DeviceSurfaceType 1}` / `{DeviceSurfaceType 2}` | full dictionaries: DisplayRotation 0 / 270, DeviceSurfaceType and kMGQDeviceSurfaceType 1 / 2, DisplayScale 3, ChromeIdentifier phone15 / phone14, FramebufferIdentifier as the sim, corners [5,5,59,59] / 55×4 | the same, cover corners [8,8,59,59] |
| 7 | inner physical size, ppi | 0×0, 0 / `pixelDensity` nil | 6.2022×4.3630 in, 460×460 (FBS 460×460) | 4.3630×6.2022, 324×654 |
| 8 | inner mode | 2853×2007 pointScale 1 + 951×669 mode, 60 Hz | 669×951@3x (2007×2853/3) current and preferred, + 951×669@3x; 120 Hz | 2007×2853 @3, 60 Hz, one mode |
| 9 | hinge HID services | one unnamed Virtual 0xFF0C/0x21 | `CoreMotion_DeviceStateRelay_Crane` 0xFF0C/0x21 and `_DeviceState` 0xFF0C/0x22 (Virtual), plus `VPhone Host Controls` 0xFF61/0x5B (Virtual) | the two relay services |
| 10 | inner portrait-shaped status bar (io 1) | 0-rect, one capture | {592,0,77,951}, two captures (25 s after the rotation, and again after a round trip through io 2) | {592,0,77,951} |
| 11 | transition style | 0 at start; 1 / 2 / 3 by path | 2 at start; 2 after every swap; 3 with Safari | 1 at boot; 2; 3 with Safari |
| 12 | per-panel pose, closed | cover = device orientation (override) | the same, now from CoreMotion's table: reclassified as a sim artefact | cover = opposite landscape (synthetic) |
| 13 | lock-screen clock | "differs" | personalization: poster `v68.colorB` vs `celosia.timeOfDay` | |

Row 8's refresh rate comes from upstream's "run the inner display at the
panel's 120 Hz" (in this branch), not from the alignment change.

## Data files

These files were deleted on 2026-10-30, after the values worth keeping were
moved into this table, the domain notes and
`Research/Guest/iphone_duo_simulator_reference.md`. Rerunning the probes
recreates them (README.md).

| file | records | scope | notes |
|---|---|---|---|
| `smoke.json` | 60 | harness smoke run | |
| `display.json` + `display.md` | 46085 | backboardd CADisplay / CAWindowServer / BKS, SpringBoard UIScreen / FBS display configurations, digitizers | getters enumerated at runtime; extra field `capture` |
| `springboard.json` + `springboard.md` | 37408 | content-mode coordinator and resolver, window scenes, traits pipeline, continuous fold, backlight, auto-lock | 45 steps, all four device orientations |
| `sensors.json` + `sensors.md` | 10932 | CMMagicPose / CMDeviceStateEvent tables, hinge HID, SBFDevicePoseProvider, UIDevice, 527 MobileGestalt keys | `sim_note` marks 2578 sim-only or synthetic values; do not align to them |
| `appkit.json` + `appkit.md` | 20829 | Preferences, MobileSafari, VPAppKitProbe: scenes, geometry, traits, safe area, migration callbacks | probe app source in `src/appkit/probe-app` |
| `chrome.json` + `chrome.md` | 127674 | status bar, icon grid, dock, quick actions, notification list, clock, wallpaper | `meta.skipped_getters` lists getters that throw |
| `vm-springboard.json`, `vm-display.json`, `vm-sensors.json`, `vm-chrome.json`, `vm-appkit.json` + `vm-notes.md` | see `vm-notes.md` | the same probes on duobase-01 | `meta.vm`, `meta.steps` (per-step display.pose, orientation, screenshot size and lit/dark, SpringBoard pid); extra fields `probe`, `step`. Second pass (2026-10-30): records with `bundle` 2.14.0-local.9064efca and `step` `fx-<label>`, described in `meta.fix` |

Every record has `api, kind, process, posture, orientation, call, value, error`.
`posture` includes the path, e.g. `open(after-closed)`, because many values
depend on history. Display UUIDs change on every boot, so join on name or identity.

```zsh
# every value of one call, by posture
jq -c '.records[] | select(.call | test("primaryWindowScene")) | {posture, orientation, value}' springboard.json
```

## Posture and policy

| posture | hinge | policy | primary scene | content mode cover / inner | backlight cover / inner | vphone-duo |
|---|---|---|---|---|---|---|
| closed | 0°, `.closed` | FullyClosed | `SB-main` (cover) | 2 / 1 | on / off | 0°, `.closed`, FullyClosed, `SB-main`, 2 / 1, on (1) / off (4); screenshot 1398×2034 lit; the same after a SpringBoard start, after open and after book (2026-10-30, CoreMotion) — **match** |
| book | 100°, `.partiallyOpen` | FoldingDual | `com.apple.springboard.bringup` (inner) | 3 / 2 | off / on | **99.444°** (0.552), `.partiallyOpen`, FoldingDual, `bringup`, 3 / 2, off (4) / on (1); screenshot 2034×1398 lit; after closed and after open — **differs** (angle residual 0.556°) (was: 90°, 0.500) |
| open | 180°, `.openFlat` | FoldingDual | inner | 3 / 2 | off / on | 180°, `.openFlat`, FoldingDual, `bringup`, 3 / 2, off / on; screenshot 2034×1398 lit; after book and after closed (2026-10-30) — **match** |

Content mode: 1 disabled, 2 primary, 3 auxiliary. The CA display state is
1 / 0 when closed and 0 / 1 when open, and both panels keep power state 1.
Book and open are identical across the display stack. They differ only in
the scene region `innerCover` (active in book only) and in the hinge state.

VM: the same history paths (after-open, after-closed, after-book, after a
SpringBoard start) give the same rows. There is no `CADisplayStateControl` on
the VM; the window server shows cover `LCD` enabled and unblanked in every
awake posture and the inner enabled when unfolded, blanked when closed
(**differs**, Diff summary 5). Book and open differ only in `innerCover` and
the hinge state on the VM too.

2026-10-30: one exception seen once, outside the measured steps. After an
unplanned SpringBoard restart had dropped the idle-timer assertion, the guest
auto-locked in closed; an unfold then woke it to the lock screen and the
resolver's prevailing policy read **`Yoink(inner)`** instead of FoldingDual in
open and in the following book (`raw/vm/steps/discarded/fx-*-sb1064-autolock-on`).
With the screen kept lit the same paths give FoldingDual. The sim has no
reference for an unfold from a dark, locked cover.

## Display identity

| item | cover | inner | vphone-duo |
|---|---|---|---|
| CADisplay name / deviceName / displayId | LCD / primary / 1, `mainDisplay` | LCD-1 / primary-1 / 3 | cover LCD / primary / 1, `mainDisplay`; inner `VPhone Duo Inner` / `VPhone Duo Inner` / 7 — **differs** (unchanged on 2026-10-30; names owned by another session) |
| CADisplay `tag` | 0 | 65536 | 0 / 65536 — **match** |
| native size, scale, refresh | 1398×2034 @3, 60 Hz, P3 | 2007×2853 @3, 60 Hz | cover 1398×2034 @3, **120 Hz**, P3; inner FBS current/preferred mode 669×951@3x (2007×2853/3), UIScreen currentMode 2007×2853, scale 3, **120 Hz**, **sRGB**; FBS/UIScreen still add a 951×669@3x (2853×2007) mode; CADisplay currentMode 2853×2007 — **differs** (refresh, gamut, extra mode) (was: inner 2853×2007, pointScale 1, 60 Hz, extra 951×669 mode at /2) |
| CAWindowServerDisplay orientation | rot0 / portrait | rot90 / landscapeLeft, from boot | cover rot0 / portrait; inner rot90 / landscapeLeft from SpringBoard start — **match** |
| `extendedProperties` | DisplayRotation 0, DeviceSurfaceType 1, corners 8,8,59,59 | DisplayRotation 270, DeviceSurfaceType 2, corners 55×4 | cover DisplayRotation 0, DeviceSurfaceType 1, kMGQDeviceSurfaceType 1, DisplayScale 3, ChromeIdentifier `…chrome.phone15`, FramebufferIdentifier `1C896A2B-…`, corners **5,5,59,59**; inner DisplayRotation 270, DeviceSurfaceType 2, kMGQDeviceSurfaceType 2, DisplayScale 3, `…chrome.phone14`, `BF0DC480-…`, corners 55×4 — equal to the sim's dictionaries key by key except the cover corners — **differs** (cover corner radii only: Apple's device tree vs the sim device type) (was: `{DeviceSurfaceType 1}` / `{DeviceSurfaceType 2}` only) |
| `BKSDisplayService traitsForDisplayUUID:` surfaceType | 1 | 2 | inner 2 (also on 2026-10-30); cover not queried (its `UIScreen._displayID` is nil, so the probe has no cover UUID) — **match** (inner), cover n/a |
| UIScreen | index 0, `Main`, 466×678, `_isMainScreen` YES | index 1, `Unknown.main[3]`, `_isMainScreen` NO, `_isEmbeddedScreen` YES | cover index 0, `Main`, 466×678, YES; inner index 1, `Unknown[7]`, `_isMainScreen` NO, **`_isEmbeddedScreen` NO**, `_isMainLikeScreen` NO, corner radius 0, sRGB — **differs** (unchanged on 2026-10-30) |
| FBSDisplayIdentity | type 0, isMain, isMainRoot, isRoot | type 7, displayID 3, isRoot, UIKitMainLike, alwaysConnected | cover type 0, isMain, isMainRoot, isRoot; inner type 7, **displayID 7**, isRoot, **not UIKitMainLike**, alwaysConnected — **differs** (unchanged on 2026-10-30) |
| FBS config name / bounds | Main / 466×678 | Unknown / 669×951 (never rotates) | Main / 466×678; Unknown / 669×951, unchanged through all four inner orientations — **match** |
| `_exclusionArea` | {399,30,37,37} | the same {399,30,37,37}, copied from the cover | {399,30,37,37} on both — **match** |
| pixelsPerInch | 316×669 | 324×654 | cover 460×460; inner CADisplay 460×460, FBS `pixelDensity` 460×460; physical size cover 4.4217×3.0391 in, inner 6.2022×4.3630 in (the sim's 3.0391×4.4217 and 4.3630×6.2022 with the axes swapped; the sim's ppi divides the native pixels by those swapped axes) — **differs** (was: inner 0×0, `pixelDensity` nil, physical size 0) |
| `sbh_screenType` | 31 | 32 | 31 / 32 — **match** |
| digitizer | `CoreDevice touchscreen(<cover UUID>)`, main display digitizer | `CoreDevice touchscreen(<inner UUID>)` | one `Virtual USB Touch Screen` (USB, builtIn, authenticated) = `mainDisplayDigitizerService`, mapped to the inner UUID while unfolded and to the main display when closed — **differs** |

CAWindowServer lists five displays: LCD, TVOut, LCD-1, Wireless, Resizable.
VM: seven, `LCD`, `Wireless`, `Wireless-1`…`Wireless-4`, `VPhone Duo Inner` (no TVOut, no Resizable).

## Orientation

| item | sim | vphone-duo |
|---|---|---|
| inner interface orientation for device portrait / landscapeLeft / landscapeRight / upside-down | 4 / 1 / 2 / 3 | 4 / 1 / 2 / 3 (`display.rotation` 90 / 0 / 180 / 270 in open) — **match** |
| inner accepts | all four orientations, home screen (mask 30) and apps | all four on the home screen, HomeScreen participant mask 30 — **match** |
| cover with home screen or lock screen in front | stays portrait (participant mask 2), device orientation still changes | home screen stays portrait (mask 2): device 4, `systemArbitratedDeviceOrientation` 4, interface 1; vphoned reports "The device did not apply the requested rotation" — **match** |
| cover with a landscape-capable app in front (Safari, VPAppKitProbe) | **goes landscape**: 678×466, size classes C/C, `statusBarFrame` 0×0 | Safari: 678×466, interface 4 (`display.rotation` 90) or 3 (270), C/C, `statusBarFrame` 0×0, safe area 0,0,34,84 / 0,84,34,0, SwitcherLiveOverlay mask 26 — **match**. The old note "VM refuses cover landscape outright" is corrected: only the home screen refuses, as in the sim |
| cover, portrait-only app (Preferences) | stays portrait | stays portrait 466×678 with `UIDevice.orientation` 4 — **match** |
| `UIDevice.orientation` | follows the lit panel; on the cover the name is the opposite of the requested one (landscapeLeft → 4) | follows the lit panel (open: 3 for landscapeLeft; closed: equals the cover's orientation) — **match**; the cover mapping is the next row |
| per-panel pose orientation | landscapeLeft: cover 4 / inner 3; landscapeRight: cover 3 / inner 4 | 2026-10-30, through CoreMotion: open, `display.rotation` 0 → device 3, cover 4 / inner 3; 180 → device 4, cover 3 / inner 4 — **match**. **Closed with Safari on the cover**: `display.rotation` 90 → device 4, **cover 4**, inner 1 (`cmMagicPose` 4 / 4 / 0); 270 → device 3, **cover 3**, inner 1 (`cmMagicPose` 3 / 3 / 0); Safari interface 4 / 3, 678×466 — **differs (sim synthetic)**: CoreMotion's own table (the "propertyA table" row, identical in the sim) maps a closed hinge to the cover unchanged, so the VM value is CoreMotion's and the sim's cover 3 for device 4 comes from its swap tool. Upside-down not measured (the host controls have no upside-down orientation) (was: the same cover values from the override) |

## History-dependent values

| item | sim | vphone-duo |
|---|---|---|
| inner UIScreen bounds | 669×951, orientation 0, size classes 0/0 at boot; afterwards it follows the inner's orientation (951×669 for 3/4) | 669×951 at boot (observed before this run); 951×669 at orientation 4 or 3, 669×951 at 1 or 2, Regular/Regular after an unfold — **match** (boot size classes not measured) |
| inner `SBWindowScene.interfaceOrientation` | 1 from boot until the first rotation reaches the inner panel, then 4 in portrait | 1 from SpringBoard start (two starts: pid 1440, 2384) through every fold and unfold, then 1/2/3/4 with the rotations and 4 in portrait — **match** |
| cover UIScreen after a landscape app | keeps 678×466 while the inner is in use | cover rotated with Safari, then unfolded: 678×466, orientation 4, also after the inner returned to portrait — **match** |
| resolver `_preferredTransitionStyle` | `.fade` until the first swap, then `.continuousLive` (`.continuousSnapshot` with Safari) | 2026-10-30, after a forced respring in closed: **2** before any swap (sim 1), then 2 after every fold and unfold (book, open, closed, both history orders, and after rotations), 3 with Safari in front (closed landscape, book, open) — **differs** at the start only (was: 0 after a SpringBoard start; 1 after the first fold; 2 after book→open; 1 or 3 with Safari/Preferences by path) |
| app client orientation | 1 if launched on the cover and then unfolded; 4 if launched on the inner, and stays 4 after folding | Safari and Preferences launched on the cover, unfolded: 1; Preferences launched on the inner: 4, still 4 on the cover after folding — **match** |
| hinge regions (hysteresis) | closed region 0→0.47 at boot, 0→0.28 after book, 0→0.11 after a fold | 2026-10-30: 0→0.47 after a SpringBoard start (closed), after open and after every fold; **0→0.2747** after book (toClosed 0.5525→0.03, partiallyOpen 0.2747→0.97), from the 99.444° angle — **match** within the angle residual (sim 0→0.2761, toClosed 0.5556→0.03) (was: 0→0.25, toClosed 0.50→0.03). The sim's own `springboard.json` also reads 0→0.47 after folds; 0→0.11 is from `sensors.md` |

## Hinge, pose and identity

| item | sim | vphone-duo |
|---|---|---|
| hinge HID service | `CoreMotion_DeviceStateRelay_Crane`, 0xFF0C/0x21 (sibling `_DeviceState` 0xFF0C/0x22), frozen at boot values | 2026-10-30 (vphoned `device.input_devices`): `CoreMotion_DeviceStateRelay_Crane` 0xFF0C/0x21 and `CoreMotion_DeviceStateRelay_DeviceState` 0xFF0C/0x22, Transport Virtual, published by locationd's relay, plus the feed `VPhone Host Controls` 0xFF61/0x5B (Virtual, from libvphonehinge in backboardd); values live, not frozen — **match** (names, usages, transport). `systemEventOfType:0x2c` not re-read: the backboardd probe that reads it wedged locationd's relay (`vm-notes.md`) (was: one unnamed Virtual 0xFF0C/0x21, no 0x22 sibling) |
| CoreMotion device state | frozen at boot: the sim fold bypasses HID and CoreMotion and writes into `SBFDevicePoseProvider` | 2026-10-30: `+isAvailable` YES for `CMDeviceStateManager`, `CMMagicPoseManager`, `CMAngleManager` (SpringBoard and Safari); the provider's `_cmMagicPoseManager` (registered, client and internal handlers set) and `_cmAngleManager` (`isAngleActive` YES, interval 0.01) are CoreMotion objects as in the sim; `_accelerometer` nil (sim nil); `currentDeviceState` live (open: propertyA 1, propertyB 3); `cmMagicPose` follows the hinge (1 / 2 / 3), the sim's stays at boot values; `internal.isOnVM` still YES — **match** (was: `+isAvailable` NO, managers nil, pose from vphoned's override) |
| `CMMagicPoseManager sharedManager` | non-nil | 2026-10-30: non-nil, its `_manager` a `CMDeviceStateManager` with no handlers, and not the provider's instance (`isSharedManager` NO, as in the sim) — **match** (was: nil, `+isAvailable` NO). `+orientationForMagicPose:deviceSurface:` is CoreMotion's own class method and runs normally (next row) |
| `orientationForMagicPose:deviceSurface:` | equals `propertyAForConfigType:surface propertyA:orientation propertyB:hinge propertyC:tabletop` for every input | identical to the sim on all 896 sim inputs; tabletop 0..11 probed — **match** |
| propertyA table, tabletop 0 | surface 1: hinge 1 → identity, hinge 2/3 → 0,1,2,4,3,6,5,0; surface 2: hinge 1 → 0, hinge 2/3 → 0,1,2,3,4,5,6,0; hinge 0/4/5/6 → 0 | identical on all 1120 sim inputs — **match** |
| propertyA, tabletop 1..10 with hinge 2/3 | constants (surface 1: 3,4,1,2,6,3,4,5,6,1; surface 2: 0,0, then 1,2,3,4,6,6,5,1) | surface 1: 3,4,1,2,6,3,4,5,6,1; surface 2: 0,0,1,2,3,4,6,6,5,1 — **match** (corrects "FoldDisplay does not model tabletop": the table is CoreMotion's) |
| propertyA, A=7 with hinge 2/3 | 0 | 0 — **match** (corrects "not covered") |
| hinge enums | SpringBoard `uiHingeStatus` 1/2/3; app `_UIHingeState` 1/3/4; public `UIHinge` status 1/2/3, angle in radians | 2026-10-30: `uiHingeStatus` 1/2/3 (angle 0 / 99.444 / 180); Safari `_UIHingeState` closed / partiallyOpen (99.4) / openFlat (180), scene `_UISceneHingeState` closed / partiallyOpen / fullyOpen — **match** (was: angle 90 in book); public `UIHingeInteraction` not measured (VPAppKitProbe not installed) — n/a |
| hinge state delivery | only to scenes whose client sets `wantsSceneHingeState`; `FBSSceneSettings.hingeAngle/hingeStatus/magicPose` stay 0 | 2026-10-30: Safari (`wantsSceneHingeState` YES) gets it closed / book / open; `FBSSceneSettings.hingeAngle` and `hingeStatus` 0 — **match**; Preferences (nil in the first pass) not re-measured |
| MobileGestalt identity | iPhone19,4, DeviceClass iPhone, A3447, "iPhone Duo", HomeButtonType 2, DeviceCornerRadius 59, DynamicIsland, AlwaysOnDisplay, EnhancedMultitasking false | iPhone19,4, iPhone, **VM0001** (RegulatoryModelNumber nil), "iPhone Duo", 2, 59, DynamicIsland YES, **AlwaysOnDisplay NO**, EnhancedMultitasking NO; HWModelStr V68AP (sim iPhone19,4) — **differs** (re-read on 2026-10-30: unchanged) |
| MobileGestalt screen | main-screen 1398×2034 @3, pitch 460 (the cover); `DisplayExtendedProperties` has 2 entries; logical display count 2 | 2026-10-30: 1398×2034 @3, pitch 460; `DisplayExtendedProperties` 2 entries, equal to the sim's except the cover's `DeviceCornerRadius` [5,5,59,59] (sim [8,8,59,59]); `MGGetLogicalDeviceDisplayCount` 2 — **differs** (cover corner radii only) (was: `DisplayExtendedProperties` nil, count 1) |
| UIDevice | no hinge, tabletop, fold or posture getter exists | none exists — **match** |

## What an app sees

| item | closed (cover) | book / open (inner) | vphone-duo |
|---|---|---|---|
| `[UIScreen mainScreen]` | cover | cover | cover (`screens[0] LCD Main`) in every posture; 2026-10-30, Safari closed / book / open: the same — **match** |
| `[UIScreen screens]` count | 1 | 2 (the inner connects and disconnects with the fold) | 1 / 2; 2026-10-30 Safari: 1 / 2 / 2 — **match** |
| scene bounds | 466×678 | 951×669 | 466×678 / 951×669 (Safari and Preferences); 2026-10-30 Safari: 466×678 / 951×669 / 951×669 — **match** |
| size classes | C/R | R/R | C/R / R/R; 2026-10-30 Safari: C/R / R/R / R/R — **match** |
| interface orientation (device portrait) | portrait | landscapeRight (4) | 1 / 4; 2026-10-30 Safari: 1 / 4 / 4 — **match** |
| safe area t,l,b,r | 0,0,34,84 (right status column) | 0,0,34,84; Safari 82,0,34,0 | 0,0,34,84 / 0,0,34,84; Safari 82,0,34,0; 2026-10-30 Safari: the same — **match** |
| idiom | Phone | Phone | Phone (0) — **match** |
| scene `cornerRadiusConfiguration` | 8,8,59,59 | 55×4 | 8,8,59,59 / 55×4; 2026-10-30 Safari: the same (the scene keeps 8,8,59,59 although `extendedProperties` now say 5,5,59,59) — **match** |
| `ssk_surfaceType` | 1 | 2 (4 during launch) | 1 / 2 (no launch-time capture); 2026-10-30 Safari: 1 / 2 / 2 — **match** |
| scene regions | | `fold` {0,455.5,669,40}, `innerCover` active in book only, `statusBarOcclusion` {0,0,124,84} | cover: cover, coverCamera, statusBarOcclusion; inner: innerCover, innerRear, inner, fold {0,455.5,669,40} margins 20, innerCamera, statusBarOcclusion; `innerCover` active YES in book, NO in open; 2026-10-30 Safari: closed cover, coverCamera, statusBarOcclusion active; book innerCover, innerRear, inner, fold active; open innerCover, innerRear, fold inactive — **match** |
| Preferences split column | compact | 475.67 in book (sidebar ends at the fold), 320 in open | collapsed (466) / 475.67 in book, 320 in open — **match** |

Migration moves the existing scene: same `UIWindowScene`, same persistent
identifier, foregroundActive throughout, with no lifecycle callbacks.
- Unfold: hinge 2, then about 110 ms later `UIScreenDidConnect` → one
  `didUpdateEffectiveGeometry:` → trait C→R.
- Fold: hinge 1, then about 70 ms later trait R→C → geometry → `UIScreenDidDisconnect`.

VM: the callback sequence was not measured (it needs VPAppKitProbe). In the
app the inner screen's identity is `Unknown.main[7]` and its `_name` is
`VPhone Duo Inner`.

## System chrome (points)

| item | cover | inner, landscape-shaped (orientation 4/3) | inner, portrait-shaped (1/2) | vphone-duo |
|---|---|---|---|---|
| status bar class | `…AxisAlignableSplitV68Cover` | `…AxisAlignableSplit2007` | same | the same classes — **match** |
| status bar frame | right column {389,0,77,678} | `statusBarFrame` 0-rect; foreground 88×123.67 top right | {592,0,77,951} | cover {389,0,77,678}; inner landscape 0-rect — **match**; 2026-10-30 inner portrait-shaped (interface orientation 1, `display.rotation` 0): **{592,0,77,951}**, wrapper height 77, in both captures (25 s after the rotation, and after a round trip through orientation 2) — **match** (was: 0-rect, one capture). At orientation 1 straight after a SpringBoard start, before any rotation, it is 0-rect, as in the sim's `open-after-closed` and first `open-landscapeLeft` runs |
| icon grid | 4×6, 60×60 icons, label 12 pt, spacing 28×38.8 | 4×6, list 324 wide at x=470 (open) / 512.67 (book) | 4×6 over 669×951 | cover spacing 28×38.8, list 466×678; inner list 324×669 at x=470 (open) / 512.67 (book), spacing 28×38; portrait-shaped list 669×951 — **match** |
| dock | right side column {376.17,45,84,678}, capacity 1×4 | right side column {861.17,45,84,669} | bottom dock {0,851,669,100} | {376.17,45,84,678}; {861.17,45,84,669}; {0,851,669,100} — **match** (the VM dock holds 4 icons, the sim 1) |
| quick action button | 84×84 at {376,573} | 84×84 at {861,564} | 84×84 at {579,846} | 84×84 at {376,573}, {861,564}, {579,846} — **match**; the VM shows them (hidden NO) with the real torch and camera glyphs (28.33×22 and 17.33×30.67 in the 48-point icon area), the sim hides them with a placeholder |
| notification platter width | 350 (list 370 at boot, 378 after open) | open 450 (list 478, centred); book 350 (list 378, right half) | 450 | no notifications on the VM (no `simctl push`) — n/a |
| clock frame | 372×132.26 at {11,47} | open 400×132.26 at {275.5,51.67}; book x=487.25 | | cover 372×240.28 at {11,47}; inner open 400×232.16 at {275.5,51.67} (2026-10-30; first pass 235.61) — **personalization (poster: VM `com.apple.MercuryPoster` `v68.colorB`, sim `celosia.timeOfDay`)**. The height follows the poster's adaptive time: `adaptiveTimeTextHeight` 213.01 (sim 105), time font `.SFAdaptiveSoftNumeric` weight `wght3200000` at 128.77 pt (sim `wght2800000` at 110.03 pt), `intrinsicContentSize` 272×244.67 (sim 196.67×131.67); the limits are the same (`minimum`/`maximumAdaptiveTimeTextHeight` 104.74 / 303.68), as are `titleContentStyle` (vibrant material) and the glass renderer. Screenshots: `raw/vm/steps/fx-closed-lockscreen/shot.jpg` (photo poster, tall time) against `raw/chrome/shots/closed-after-open-lock-d1.png` (abstract time-of-day poster) |
| wallpaper window | | portrait-anchored 669×951 while the other windows are 951×669 | | cover 466×678; inner 669×951 while the other inner windows are 951×669 — **match** |

Quick action glyph: button 84, icon area 48 (insets 18), glyph view 27×25,
image 19.33×18. Glyph/button is 0.321 × 0.298. The sim hides the quick action
buttons and shows the placeholder symbol `questionmark.app`, so this does not
measure the flashlight or camera glyph. The VM's 0.68 glyph scale has no
direct sim reference.

## Power and auto-lock

| item | sim | vphone-duo |
|---|---|---|
| auto-lock default | off (`SBDisableAutoDim` assertion); real timer dim 40 s, lock 60 s | on: Auto-Lock 60 s, `SBBacklightIdleTimer` warn 40 s, total 60 s, no disable assertion — **differs** (configuration) |
| auto-lock in book/open | inner goes always-on dimmed and stays primary | measured in open: inner stays primary but goes **off** (backlight 4, not 3), both panels off, screenshot black, window server blanks both — **differs** (no AOD) |
| fold after auto-lock | FullyClosed; the cover becomes primary, always-on dimmed, lock screen; inner off | FullyClosed, cover primary on the lock screen but **off** (4), inner off (4) and blanked; still so 20 s later; screenshot black — **differs** (no AOD). Corrected: the folded inner does **not** light |
| fold right after a lock-button press | the cover turns fully on | cover on (1), lock screen, inner off; screenshot lit — **match** |

## Limits

- The sim fold does not go through HID or CoreMotion, so the VM's
  HID → CoreMotion → pose provider path has no reference. Only values from
  `SBFDevicePoseProvider` onward compare.
- Values with `sim_note` (host Mac model, memory, CPU, `IsSimulator`, the
  `SIMULATOR_*` environment) do not exist on the VM.
- `posture.zsh`'s 3 s readback during a 180° inner rotation once crashed
  SpringBoard mid-animation (`_SBSystemApertureContainerViewRotatingContentView setTransform:`).
  Use a longer settle for rotations.
- Known harness defects, worked around but not fixed in `tools/`:
  - `POSTURE_OUT` defaults to the shared `raw/posture`.
  - `smoke.zsh` labels interface orientations 3 and 4 with device-orientation names.
  - `posture.zsh unlock` releases the testing lock, not the device lock screen.
  - `sim.zsh pid` fails while lldb is attached.
- VM side: see `vm-notes.md` for the lldb traps (EXC_GUARD from more than one cast
  `objc_msgSend` per expression, garbage `strcmp`/`strncmp`, unlowered PAuth_LR code) and
  the getters skipped on the VM.
- 2026-10-30, bundle 2.14.0-local.9064efca: do not run `probes/vm-sensors-backboardd.lldb`
  (an `IOHIDServiceCopyProperty` walk from backboardd's main thread). With the CoreMotion
  relay present it was interrupted and left the relay wedged until locationd was restarted,
  which restarted backboardd and SpringBoard too. Read the service list with vphoned's
  `device.input_devices` instead (`vm-notes.md`, "Incident 1").
