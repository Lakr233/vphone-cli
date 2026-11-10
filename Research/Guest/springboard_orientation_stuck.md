# SpringBoard orientation arbitration stuck after language-change relaunch

Investigated 2026-10-20 on iPad16,1 / iPadOS 26.6.2 (23G90). Static evidence is
the `23G90__iPad16,1_2` dyld shared cache extraction plus live `log collect`
captures from clean local VMs (`repro26`, `kbdtest-ipad`); every function
cited below was decompiled from the cache's SpringBoard image with REA/Ghidra
12.1.4 (addresses are cache VM addresses, preserved by `ipsw dyld extract`).

## Symptom

After Settings → General → Language & Region applies a new preferred language,
the system relaunches SpringBoard behind a full-screen transition overlay.
From that point every landscape `display.rotation` on the home screen returns
`unavailable: The device did not apply the requested rotation`. Rotation lock
is off. Reproduced deterministically on a clean VM with no third-party apps;
plain respring and respring-with-rotation-lock never trigger it. A respring
clears it; on one machine lock/unlock cleared it, on another it did not.

## The arbitration gate, from the image

`SBTraitsEmbeddedDisplayPipelineManager` (SpringBoard,
`/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard`) owns
device-orientation delivery to the TRA arbiter.

- `_updateOrientationEventsEnabledState` @ `0x22410802c`

  ```
  enabled = [self _isBacklightOn] || [[SBPlatformController sharedInstance] prefersAlwaysOnOrientation]
  if (accelerometer.orientationEventsEnabled != enabled)
      [accelerometer setOrientationEventsEnabled:enabled]
  ```

  iPads carry no always-on display, so the gate is effectively
  `_backlightIsOn` alone. `BKSAccelerometer` (BackBoardServices) stops
  delivering device-orientation notifications to SpringBoard while this is
  false.

- `setupDefaultPipelineForArbiter:` @ `0x224448664` — the seed and its order:

  ```
  [self->_accelerometer setDelegate:self]
  ...
  [self _updateOrientationEventsEnabledState]        // _backlightIsOn is still its default NO here
  ...
  self->_backlightIsOn = [[SBBacklightController sharedInstanceIfExists] screenIsOn]   // seeded, NOT followed by a recompute
  [backlightController addObserver:self]
  ```

  The enable state is computed **before** the seed is written and is never
  recomputed after it. The only later path that recomputes it is the backlight
  observer callback.

- `backlightController:willAnimateBacklightToFactor:source:` @ `0x224108904`

  ```
  log "[EmbeddedPipeline] Backlight is animating with source: %@ to factor: %.1f"
  newOn = (factor != 0)
  oldOn = [self _isBacklightOn]
  self->_backlightIsOn = newOn
  [self _updateOrientationEventsEnabledState]        // every animation
  if (newOn != oldOn) [self _updateOrientationInputsDeferralAnimated:NO]
  ```

- `_updateOrientationInputsDeferralAnimated:` @ `0x2240cc40c`

  ```
  shouldDefer = [self->_systemOrientationLockManager isCurrentlyDeferringOrientationUpdates]
                || ![self _isBacklightOn]
  [self->_orientationLockInputsValidator setPrefersDeferringOrientationUpdates:shouldDefer]
  if (!shouldDefer) [self _noteInputsNeedUpdateAnimated:animated reason:...]
  ```

  While the backlight is considered off, the arbiter itself is told to prefer
  deferring orientation updates — an arbiter-level veto, independent of the
  accelerometer.

- `accelerometer:didChangeDeviceOrientation:` @ `0x22444942c` is the only
  post-boot path that refreshes device-orientation inputs:

  ```
  log "[EmbeddedPipeline][Accelerometer] did change device orientation to: %@"
  [self _evaluateNonFlatOverrideNecessityForCurrentDeviceOrientation:orientation]
  self->_orientationInputs = [self _orientationInputsForDeviceOrientation:orientation]
  [self _updateInputs]
  [self _noteInputsNeedUpdateAnimated:[self _isBacklightOn] reason:"Device orientation change"]
  ```

- `SBDeviceOrientationUpdateManager.deviceOrientationUpdateDeferralAssertionWithReason:`
  @ `0x2240e2f1c` creates an assertion into `_deferralAssertions` and posts a
  notification that reaches `_systemOrientationLockChanged:` →
  `_updateOrientationInputsDeferralAnimated:YES`. Live logs show these
  assertions are only created for `SBLockForScreenFadeOut` and
  `Coversheet dismissal` (lock/unlock) and are released on completion.

## Behavior evidence

| SpringBoard pid | How it started | State | `Backlight is animating` lines | `[Accelerometer] did change` lines |
|---|---|---|---|---|
| 454 | language relaunch | stuck | 2 — only when we locked (0.0) and unlocked (1.0) at 09:38:42–45 | 0, ever |
| 600 | plain respring | working | 0 in capture (capture began after boot) | 1 — rotation applied normally |

Decisive points:

1. The stuck SpringBoard **never receives a backlight animation during or
   after its relaunch**. The language transition overlay holds the display on
   across the entire relaunch, so the new SpringBoard sees no backlight
   off→on edge in its lifetime. `_backlightIsOn` therefore never turns true by
   itself: orientation events stay disabled and the arbiter keeps a
   deferral preference.
2. pid 454 proves the callbacks themselves work in a stuck instance: lock and
   unlock delivered `willAnimateBacklightToFactor:` 0.0 and 1.0, which ran
   `_updateOrientationEventsEnabledState` (re-enable) and
   `_updateOrientationInputsDeferralAnimated:NO` (deferral preference off).
   The accelerometer callback still never fired and rotation stayed stuck.
   Re-enabling is not sufficient — recovery also needs a **device-orientation
   change** delivered after the re-enable, and nothing in the VM produces one:
   - no accelerometer exists, so no gravity stream ever changes orientation;
   - the synthetic-motion providers (`motion.attitude.set`,
     `motion.gyroscope.set`, see `virtual_attitude.md` / `virtual_gyroscope.md`)
     feed CoreMotion, a different sink;
   - AX forced-orientation injection reaches the SpringBoard process but a
     portrait event while the device orientation is already portrait is a
     no-change and fires nothing; the heartbeat campaign also ended before
     the unlock edge in the captured run.
3. No deferral assertion is leaked: `Deferring device orientation updates for
   reason:` appears zero times in either stuck boot's log. The arbiter veto
   comes solely from `_backlightIsOn == NO`. The original leaked-assertion
   hypothesis is disproven for this state.

## Why real hardware never sticks

A real device relaunch blanks the panel, so the new SpringBoard receives a
genuine backlight off→on animation that flips `_backlightIsOn` and re-enables
orientation events; and gravity continuously produces device-orientation
changes that immediately re-drive the arbiter even if a window is missed. The
VM has no real blank across the language overlay and no gravity stream, so a
one-shot Apple edge condition becomes a permanent wedge.

## Recovery and fix surface

- Workaround (proven): respring. Lock/unlock is *not* reliable: it repairs the
  gates but cannot synthesize the missing orientation change.
- Reliable non-respring recovery, if ever wanted: after a lock/unlock edge,
  inject a device-orientation value **different from the current one** and
  then the target value through the backboardd device-orientation sink. A
  same-value injection is a no-change no-op; this is why the portrait-only
  heartbeat campaign failed.
- Systemic fix: give the guest a virtual accelerometer/gravity HID service in
  `backboardd` alongside the existing gyro provider (the
  `libvphonegyro.m`/SystemHook pattern), so device orientation self-drives the
  way real hardware does. It must feed the backboardd device-orientation
  sink — CoreMotion providers do not touch this path.
- The web console can also auto-respring on `unavailable: The device did not
  apply the requested rotation`, but with the HID fix the state should not
  occur in the first place.

## Virtual gravity provider implementation (2026-10-20)

The independent Guest System patch `system-backboardd-cfw-accelerometer`
installs `/usr/lib/libvphoneaccelerometer.dylib`, selected by standard and
experimental on iOS 18+, blocked by both TV presets. Disabling it removes the
library. SystemHook loads it into backboardd and SpringBoard, without a
bootstrap or tweak loader; environment updates replace an installed copy and
request a reboot without restarting backboardd.

The service advertises built-in accelerometer usage page `0xff00`, usage `3`.
This match is observed in the standalone backboardd artifact's
`-[BKOrientationManager _initWithDeviceOrientationManager:]` at `0x10009aaf8`:
`initWithUsagePage:usage:builtIn:dataProvider:(0xff00, 3, YES, ...)`.
Artifact SHA-256:
`050bc2ea69fd76a89ce3c5fa8f3477726a1177c50152d3ba8fd570f0f03f45af`.
This older standalone artifact establishes the match, not full version parity
with the 23G90 shared cache; guest acceptance must establish that separately.
REA/Ghidra output is `/private/tmp/vphone-orientation-bb-init.json`.

The implementation uses Apple's `HIDEvent` accelerometer factory, sequence
accessor, and `HIDVirtualEventService` lifecycle. Its samples are accelerometer
events (type `13`), not quaternion/tilt events or app CoreMotion callbacks.
Gravity in g for interface rotations 0/90/180/270 is respectively
`(0,-1,0)`, `(-1,0,0)`, `(0,1,0)`, `(1,0,0)`. The HID report interval controls
streaming; zero unsubscribes. Enumeration and configuration changes also emit
one sample. Status is refreshed every two seconds only while streaming, and
at state transitions or native orientation delivery.
Service resets cancel before re-registration, and stale delegate callbacks
cannot change the replacement service's state.

### Raw HID alone was insufficient

The first clone run (`2.10.1-local.1215039e`) registered the accelerometer
successfully but never acquired a report interval: `report_interval_us=0`,
`dispatched=0`, no dispatch failures. English → Simplified Chinese relaunched
SpringBoard to pid 490, after which `display.rotation {orientation:90}` still
returned `unavailable`. This is a direct counterexample to the original
proposal that the raw service alone would fix the wedge on this board.

The final implementation includes the missing classification-to-sink stage.
After the built-in service matches, it captures the native
`BKOrientationManager` and its runtime-resolved `_queue`. It classifies the
actual HID sample's stationary gravity with a flat/ambiguous dead band and
posts `_queue_postUpdatedRawAccelerometerDeviceOrientation:` on that queue.
Only changed classifications are posted. All selectors and ivars are resolved
from runtime metadata; no instruction or per-version address is patched.

This sink's BKS orientation values are **1/4/2/3** for 0/90/180/270 degrees;
they are not UIDevice's device-landscape numbering. The first bridge build
used the latter, and gravity-only readback exposed swapped landscapes even
though AX requests temporarily masked the error. The final bridge and tests
use the measured BKS ordering.

SpringBoard loads only the other half of this library: after the original
`setupDefaultPipelineForArbiter:` returns, the hook samples the real
`SBBacklightController.screenIsOn`, seeds `_backlightIsOn` and recomputes both
orientation-event delivery and input deferral. A genuinely off screen remains
off/deferred; rotation-lock policy remains in the native pipeline. This repairs
the ordering defect without permanently forcing orientation events on.

`display.rotation` publishes the matching physical pose before its existing
AX orientation request whenever the HID provider is alive and enumerated.
Mobile preferences retain the pose across a SpringBoard or backboardd restart;
invalid or absent preferences default to stationary portrait. The read form
adds `accelerometer` with the configuration and provider status. Its original
SpringBoard interface-orientation readback still decides request success. A
refused request keeps the pose (see "Held pose after a refusal" below); with
the screen off the AX request is not made at all.
Nested `orientation_sink` reports native readiness, the last BKS orientation
and delivery count separately from HID enumeration/dispatch. The outer
`device_orientation` remains UIDevice's value in vphoned, which does not
subscribe to device notifications; it is not the bridge's readback.

### Verification boundary

`make -C VPhoneGuestComponents test-accelerometer` passed: malformed persisted
values, aliases and gravity axes, real host HID event construction, monotonic
timestamps/sequence, report interval bounds/unsubscribe, stale callbacks and
idempotent termination. Additional native-shaped peer tests cover queue
confinement, classification, deduplication, flat/ambiguous rejection, and the
SpringBoard setup ordering bug with both on/off backlights. Guest arm64e
cross-compilation, injection-environment tests, all 21 patch catalogue tests
and the full `VPhone` bundle build passed.

The clone is `gyro-regress`, made from stopped `ota-canary26` with
`--new-identity`; existing running guests were not stopped.

On `2.10.1-local.e26e2935`, Simplified Chinese → English rebuilt SpringBoard
to pid 441. All four `display.rotation` directions succeeded without a
lock/unlock or respring recovery. More decisively, changing only the mobile
preference `VPhoneAccelerometerOrientation` and posting
`com.vphone.motion.accelerometer.changed` rotated the interface without any
AX request. SpringBoard logged at `2026-10-20T15:24:08Z`:
`[EmbeddedPipeline][Accelerometer] did change device orientation to: Lr`.
This run established the live sink and revealed the landscape enumeration
correction described above. Final calibrated-build acceptance follows below.

### Final calibrated-build acceptance

Verified on `gyro-regress`, iPad16,1 / iPadOS 26.6.2 (23G90), cloudOS 26.4
(23E5207q), bound to `2.10.1-local.a8c22dce`. The user's default bundle and
existing guests were preserved. The clone remains available for inspection.

| Check | Observed result |
| --- | --- |
| Gravity only; no `display.rotation` / AX request | 90 → 90, 270 → 270, 180 → 180, 0 → 0 |
| Rotation lock at portrait, then gravity 90 | Interface stayed 0 while locked; followed 90 after unlock |
| English → Simplified Chinese; physical pose remains 90 | New SpringBoard pid 494 returned 90 before a new AX request; same-value `display.rotation {orientation:90}` then succeeded |
| Remaining gravity-only directions after language relaunch | 270, 180 and 0 each read back correctly |
| Final provider state | backboardd pid 56, enumerated, 13 HID dispatches, 11 native sink deliveries, zero failures, no errors |

No lock/unlock or respring recovery was performed after the final language
transition. The first read four seconds into that transition was null because
SpringBoard was not ready yet, and an immediate rotation request failed;
once pid 494 finished starting, interface readback was already 90. This fix
does not make orientation RPCs usable while SpringBoard is still restarting.

At `2026-10-20T15:44:11Z`, the new SpringBoard logged
`[EmbeddedPipeline][Accelerometer] did change device orientation to: Ll`
during the final gravity-only run. Capture:
`/private/tmp/vphone-orientation-final-gravity-springboard.json`.
The earlier gravity-only callback capture is
`/private/tmp/vphone-orientation-hid-only-springboard.json`.

Final guest resource SHA-256:

| Resource | SHA-256 |
| --- | --- |
| `libvphoneaccelerometer.dylib` | `8ee426c72b294a97f0021da39a2b08c770c90c5814e09a9ca756453af0fa16c9` |
| `SystemHook-vphone.dylib` | `86f48ae50e6a258f1b05444929f2c44cb33452fe9bfe7f8a27e039a61b1cce8b` |

The two hashes were also read back through the guest's `environment.status`.
Other iOS versions have not been guest-tested in this change; missing native
classes/selectors leave the affected bridge inactive and report that state.

Gravity-only reproduction (substitute the clone's name when different):

```sh
vphone-launchpad-cli guest rpc gyro-regress settings.set \
  '{"domain":"com.apple.backboardd","key":"VPhoneAccelerometerOrientation","type":"int","value":90}'
vphone-launchpad-cli guest rpc gyro-regress notify.post \
  '{"name":"com.vphone.motion.accelerometer.changed"}'
# Read after the native orientation animation settles.
vphone-launchpad-cli guest rpc gyro-regress display.orientation
vphone-launchpad-cli guest rpc gyro-regress display.rotation
```

Continuous samples with an unchanged pose are not themselves orientation
changes. Nor can an accelerometer alone release an independently disabled
SpringBoard backlight/deferral gate. Do not describe HID enumeration or
dispatch as proof that the language-change wedge is fixed: acceptance needs
the actual language transition, orientation callback and successful interface
readback, including a request following the transition without lock/unlock.

## Held pose after a refusal (2026-11-10)

Until this change a refused `display.rotation` put the previous pose back, so
the guest behaved as if the device had never turned: a landscape request made
in a portrait-only iPhone app (Settings) left the device portrait, and Safari
stayed portrait when it came to the front afterwards. The VM window follows the
interface, so it turned back too. A real device held sideways stays sideways
and the next app that allows it turns. Measured on `rot-ipad26` (iPad16,1 /
26.6.2) and `rot-ios26` (iPhone17,3 / 26.6.2), driving the AX request alone
through `script.eval` (`AXSpringBoardServer.server().setOrientation_(n)`) and
the pose alone through the preference and notification above:

| Sequence | Interface afterwards |
| --- | --- |
| iPhone, Settings in front: pose 90, then Safari / Settings / Safari | 90 / 0 / 90 |
| iPhone, Settings: pose 90 + AX 90 (refused), then Safari | 90 |
| iPhone, Settings: pose 90 + AX 90 + AX 0 (the old "ask again"), then Safari | 0, pinned |
| iPad, locked: pose 270 + AX 270 (refused), unlock | 270 |
| iPad, locked: pose 270 + AX 270 + AX 0, unlock (4 of 4 runs) | 0, pinned |
| iPad, pinned as above, then pose 90, 270, 0 | follows each |
| iPad, screen off: pose 90 alone, wake | 0 (no wake delivery) |

The second AX request, made to turn iPadOS's pointer back, is what pins the
interface: SpringBoard holds an AX orientation until the device orientation
next changes, and a virtual device that holds still never changes it. It is
gone. The pointer it fixed was turned only by an AX request refused with the
screen off; a probe app logging `UITouch` locations (pointer clicks through
`input.pointer` at 0.25, 0.25) recorded:

| iPad, portrait-only probe in front | Click landed at |
| --- | --- |
| locked, pose 270 / + AX 270 / + AX 0 / pose 180 + AX 180 | 0.25, 0.25 each |
| screen off: pose 180 + AX 180, wake | 0.75, 0.75 (mirrored) |
| screen off: pose 180 + AX 180 + AX 0, wake | 0.25, 0.25 |
| screen off: pose 180 alone, wake | 0.25, 0.25 |

So with the screen off vphoned publishes the pose and makes no AX request. On
iPadOS 26 a portrait-only app does not refuse: `UIRequiresFullScreen` no
longer limits orientations, SpringBoard turns the interface and shows the app
pillarboxed upright, so an iPad refuses only while locked or dark.

The last row is the wake gap. `_updateOrientationEventsEnabledState` stops
`BKSAccelerometer` delivery while the backlight is off, and turning it back on
does not deliver the orientation backboardd already holds. The SpringBoard
half of the library now hooks
`backlightController:willAnimateBacklightToFactor:source:` and, for a nonzero
factor, calls `accelerometer:didChangeDeviceOrientation:` with the
`currentDeviceOrientation` of a `BKSAccelerometer` of its own (SpringBoard's
`_accelerometer` answered 0 after a SpringBoard restart, until its first
delivery; it stands in only when the new instance cannot answer). After it,
on `rot-ipad26`: screen off, pose 90 → wake 90; pose 270 → wake 270; pose 0 →
wake 0.

### Acceptance (bundle `2.16.0-local.70ae5170`)

Five clones, each bound to the build and checked for the bundle's vphoned and
`libvphoneaccelerometer.dylib` hashes through `device.info` and
`environment.status`: iPhone17,3 18.6.2 (cloudOS 26.1), 26.6.2 and 27.0.1,
iPad16,1 26.6.2 and 27.0.1 (cloudOS 26.4). Each ran the scenario twice, 10 of
10 runs clean. iPhone: Settings refuses 90 with the pose held, Safari takes it,
Settings returns to portrait, Safari takes it again; rotation lock refuses 270
and unlocking turns to it; with the screen off 90 is refused at once and waking
turns to it. iPad: the lock and screen-off cases, then an upside-down request
with the screen off, waking to 180, and a pointer click at 0.25, 0.25 in the
probe landing at 0.25, 0.25. An iPadOS 18 guest was not tested: no iPad pairing
in the firmware catalog starts below 26.0.

The VM window (on `rot-ios26` with `2.16.0-local.9a402bd4`, which adds only the
host's rotation-generation guard; the Device menu's Rotate Right, the view
rotation sampled every 0.1 s through `display.geometry`) stayed still for
refused turns, turned once when the guest turned for an accepted one, and
turned by itself on wake and on switching to Safari.

## Residual unknowns

- `BKSAccelerometer` internals (`setOrientationEventsEnabled:`,
  `_orientationDidChange`, re-registration semantics after re-enable): the
  standalone BackBoardServices image OOMs Ghidra 12.1.4 (the Mach-O loader
  resolves its dependency libraries into the host macOS dyld cache and the
  slide-fixup map exceeds the heap even at 16 GB). The SpringBoard-side
  behavior is fully covered without it.
- Whether `screenIsOn` returned false at the stuck boot's seed (both orders —
  seed false, or seed true without a recompute — terminate in the same state;
  distinguishing them needs a runtime ivar read).
- The exact code site that emits `The device did not apply the requested
  rotation` (consistent with arbiter refusal; not chased).

## Artifacts

- Cache extraction and decompilations:
  `/private/tmp/claude-501/.../scratchpad/rea/` (`SpringBoard`,
  `BackBoardServices`, `sb_*.json`, address table in `pm_re.txt`/`mgr_re.txt`).
- Log captures: same scratchpad `lang_sb.json`, `lang2_sb.json`, `ok_sb.json`,
  `reset_sb.json` (SpringBoard) and `*_bb.json` (backboardd).
- REA CLI recipe used here: `JAVA_HOME=<openjdk@21>
  GHIDRA_INSTALL_DIR=/opt/homebrew/opt/ghidra/libexec npx rea-agents@6.5.0
  function <image> <cache-vm-address> --provider ghidra --format json`.
  Procedure names from `ipsw class-dump <DSC> <image> --class <Cls> --re -V`.
