# SpringBoard domain: fold policy, window scenes, rotation, power

Simulator `duo-baseline-springboard` (048B820B-86E8-43F9-9DF1-F76802AD6DB8), iPhone19,4,
iOS 27.1 24A94425. Data: `springboard.json` (37408 records from 45 steps, 734 distinct
`api` keys). Raw transcripts are in `raw/springboard/steps/`, posture artifacts and screenshots
in `raw/springboard/posture/`, and class dumps in `raw/springboard/classdump*.txt`.

## How it was recorded

- `probes/springboard-state.lldb` is one expression that walks from `-[SpringBoard
  _displayToolService]` to the content-mode coordinator, resolver, window-scene manager, pose
  provider and swap coordinator, and from there to each `SBWindowScene` and its controllers. It
  records every getter it lists, and every declared property of `SBWindowScene` and of the
  settings classes (enumerated with `class_copyPropertyList`). Getters run through
  `NSInvocation` after a `respondsToSelector:` check, because lldb expressions cannot catch
  exceptions (`@try` is rejected). Ivars are read by their type encoding.
- `probes/springboard-run.zsh <step> <posture args|status>` runs `tools/posture.zsh` (with
  `POSTURE_OUT=raw/springboard/posture`) and then the state probe.
  `probes/springboard-merge.zsh` builds `springboard.json`; its step table is the run order,
  except that the two `*-initial`/`*-unfold` Safari steps were captured again after the lock
  tests. The first captures were overwritten.
- API naming: `SBWindowScene[cover]` means surfaceType 1 (`SB-main`, display `Main`).
  `SBWindowScene[inner]` means surfaceType 2 (`com.apple.springboard.bringup`,
  `Unknown.main[3]`). `SBFDisplayProxy[cover|inner]` follows the same rule. Object-valued
  `SBWindowScene` properties are recorded as `<ClassName>` (presence and class), not as their
  description. Addresses are normalised to `0x*` in the JSON.
- `orientation` is the primary scene's `UIWindowScene.interfaceOrientation`, as in smoke.json. The
  requested device orientation and any foreground app are in the `posture` label, for example
  `closed[device:landscapeLeft,app:MobileSafari]`.
- Enum values: content mode 1 = disabled, 2 = primaryContent, 3 = auxiliaryContent. Resolver
  `_preferredTransitionStyle` 1 = `.fade`, 2 = `.continuousLive`, 3 = `.continuousSnapshot`.
  `SBBacklightController.backlightState` 1 = on, 3 = always-on (AOD; `screenIsOn` NO,
  lock screen visible and dimmed), 4 = off.

## Results

| posture | prevailing policy | primary scene | cover / inner content mode | backlight cover / inner |
| --- | --- | --- | --- | --- |
| closed (every history) | FullyClosed | cover `SB-main` | 2 / 1 | 1 / 4 |
| book (every history) | FoldingDual | inner `bringup` | 3 / 2 | 4 / 1 |
| open (every history) | FoldingDual | inner `bringup` | 3 / 2 | 4 / 1 |

These rows hold for every orientation and app tried. `activeWindowScene`, the active
lock-screen manager (`SBDisplayContentModeLockScreenActiveDisplayPolicy`), alert items and
keyboard focus all follow the primary scene. `[SBLockScreenManager sharedInstance]`,
`[SBIconController sharedInstance]` and `+[SBBacklightController
sharedInstanceForMainDisplay]` always belong to the **cover** scene. Each scene has its own
home-screen controller, cover sheet window and status-bar window, and each of them sits in
its own scene.

### Rotation

The swap tool's `-deviceOrientation=` reaches the pose. `SBFDevicePoseProvider` stores the
device orientation together with a per-panel orientation: device landscapeLeft (3) gives cover
4 and inner 3, landscapeRight (4) gives cover 3 and inner 4, and portraitUpsideDown (2) gives
2 for both. `UIDevice.orientation` in SpringBoard follows the cover orientation.
`SBFDevicePoseProvider->_accelerometer` is nil in the sim.

- **Cover: home screen refuses landscape; a landscape-capable app gets it.**
  - Home screen: the cover's `SBTraitsParticipantRoleHomeScreen` supports only portrait
    (mask 2). The cover's `systemArbitratedDeviceOrientation` becomes 4, 3 or 2, but
    `systemArbitratedInterfaceOrientation` stays 1.
  - MobileSafari in front: its participant (`SwitcherLiveOverlay`, mask 26) rotates. Device
    landscapeLeft gives cover interface 4 and landscapeRight gives 3.
    `[UIScreen mainScreen].bounds` becomes 678×466. The display 1 capture is 2034×1398 and
    shows Safari laid out in landscape (`raw/springboard/posture/20261029-143539-closed-d1.png`).
  - SpringBoard's own `SBWindowScene[cover].interfaceOrientation` and the cover status bar stay
    1 throughout.
  - So "cover refuses landscape" matches stock behaviour only while the home screen (or another
    portrait-only participant) is in front. It is not a rule for the panel.
- **Inner: accepts all four orientations, home screen and apps alike** (HomeScreen mask 30).
  - The mapping is rotated by 90°: device portrait gives interface 4, landscapeLeft gives 1,
    landscapeRight gives 2 and portraitUpsideDown gives 3.
  - Inner `UIScreen` bounds follow the arbitrated orientation: 951×669 for interface 3 or 4,
    669×951 for 1 or 2.
  - `coordinateSpace.bounds` of the inner `SBWindowScene` stays 669×951.
- Orientation lock: the cover's `SBWindowSceneOrientationLockManager` delegates to the global
  `SBOrientationLockManager` (`_isPerDisplayLockEnabled` NO). The inner has a per-display lock
  (`_isPerDisplayLockEnabled` YES). Neither was locked during the run.
- While a panel is dark, its pipeline holds a "Backlight off" device-orientation deferral, so
  that panel's `systemArbitratedDeviceOrientation` goes stale. An example is the cover reading
  2 while the inner is open in portrait.
- `SBTraitsContinuousFoldDeviceOrientationLockAssertion` was never held at rest:
  `_continuousFoldLockValidator`, `_continuousFoldDeviceOrientationDeferralAssertion` and
  `_settleOrientationLock` were nil and `_continuousFoldHolderCount` was 0 in every step. It
  exists only during a sweep, and no probe ran mid-sweep.

### History-dependent values

- **Inner `SBWindowScene.interfaceOrientation` (and `effectiveGeometry`) is 1 from boot until the
  first rotation that reaches the inner panel**, even though SpringBoard arbitrates 4 for it and
  inner `UIScreen` bounds are already 951×669 after the first unfold. After any inner rotation
  it tracks the arbitrated value (4 in portrait). This was confirmed on a second boot
  (`open-boot2` gives 1; `open-boot2-landscapeLeft` then `open-boot2-portrait` gives 4). It is
  not a SpringBoard-relaunch effect.
- Inner `UIScreen.bounds` is 669×951 at boot, before the inner has been lit. After that it
  follows the inner's arbitrated interface orientation (see above). The README's "951×669 after
  the first unfold" is the portrait case of this.
- Resolver `_preferredTransitionStyle` is 1 (`.fade`) at boot until the first swap, then 2
  (`.continuousLive`). It is 3 (`.continuousSnapshot`) while MobileSafari is in front.
- `SBDisplayToolServiceCoordinator._currentDirection`, `continuousFoldController._lastHingeAngleDegrees`
  and `_lastContinuousFoldPosition`, and the resolution's stored `devicePose` (for example
  "pose: 100.0°" while open) keep the values of the last sweep. Compare them by path, not by
  posture.
- `coverSheetWindowIfLoaded` is nil on both scenes until the first swap, and loaded and hidden
  afterwards.
- The traits-arbiter participant count varies with history: 25–29 per scene. Duplicate
  `CoverSheetGrabber` participants accumulate over book sweeps.

### Power and lock

- In the sim, auto-lock is off: `SBIdleTimerGlobalCoordinator` holds the disable assertion
  "SBDisableAutoDim user default.", `idleTimer` is `SBDisabledIdleTimer`, and the enabled
  descriptor is Auto, warn 40 s, total 60 s. `probes/springboard-enable-autolock.lldb`
  invalidates the assertion, which arms the real idle timer.
  `probes/springboard-disable-autolock.lldb` takes the assertion again.
- When auto-lock fires in open or book, the inner goes to AOD (state 3) and stays primary. The
  cover stays off.
- **Folding to closed while auto-locked lights the cover, not the inner.**
  - The policy becomes FullyClosed, the cover is primary in AOD (state 3, lock screen
    dimmed) and the inner is off (state 4, display 3 captures black).
  - This holds both from open and from book.
  - The VM's "closing after auto-lock lights the folded inner display" does not happen in the
    sim.
- Folding shortly after a lock-button press from open (rather than auto-lock) turned the cover
  fully on (state 1, lock screen).
- `_simulateHomeButtonPressWithCompletion:` does nothing on this device. `_simulateLockButtonPress`
  wakes it. `attemptUnlockWithPasscode:nil finishUIUnlock:YES` unlocks it only while the idle
  timer is not expired.

## Missing, nil, errors

- `SBWindowScene.liftToWakeController` crashes the probe expression (EXC_BAD_ACCESS on the
  stack) and is recorded as an error, not called.
- `SBFDevicePoseProvider->_accelerometer` (BKSAccelerometer) is nil.
- Nil in every step:
  - Transition state: `currentTransitionContext` (coordinator and resolver), resolver
    `_currentTransitionCoordinator`, `displayContentModeContext.swapTarget` and `_currentContext`.
  - Unused orientation and lock state: `overrideActiveLockScreenManager`, the continuous-fold
    lock state listed above, and the `SBContinuousFoldCoordinator` and hinge-monitor assertions.
  - `SBWindowSceneManager._continuityDisplayWindowScene` and `_extendedDisplayWindowScene`.
  - `SBWindowScene` properties: `commandTabController`, `hardwareButtonBezelEffectsCoordinator`,
    `interactiveScreenshotGestureManager`, `manualActivationShieldWindow`,
    `medusaHostedKeyboardWindowController`, `menuBarManager`, `modalLibraryController`,
    `phoneRLController` and `reachabilityController`.

## Incidents and tool notes

- **SpringBoard crashed once** (pid 50307, `raw/springboard/crash/`). It hit SIGSEGV in
  `-[_SBSystemApertureContainerViewRotatingContentView setTransform:]`, about 18 s into an inner
  landscapeLeft → landscapeRight rotation. `posture.zsh`'s readback probe had stopped
  SpringBoard during the rotation animation. That step was discarded
  (`raw/springboard/failed-steps/`). Repeating the same rotation with `POSTURE_SETTLE=25` (no
  probe during the animation) did not crash, so later orientation steps used
  `POSTURE_SETTLE=15–25`. Steps after the crash are labelled "after SpringBoard relaunch".
- The `posture.zsh` default `POSTURE_SETTLE=3` lets the readback probe stop SpringBoard
  mid-animation. This is harmless for posture swaps but caused the crash above during a 180°
  inner rotation.
- One stray `posture.zsh status` run of mine wrote to the shared `raw/posture/`. It was moved to
  `raw/springboard/posture/misplaced/`.
- `closed` after `book` stopped at 3.6° in the resolution's stored pose, while the pose provider
  read 0.
