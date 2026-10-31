# vphone-duo (duobase-01) against the simulator baseline: notes

VM `duobase-01`, bundle 2.14.0-local.21dc0c06 (upstream main 82afdb9a, two-display Duo path),
iPhone19,4, iOS 27.1 24A94425. Probes run through `tools/vm-probe.zsh` (guest debugserver,
host lldb over NAT). Raw transcripts under `raw/vm/`.

## EXC_GUARD (code 261, subcode 0xd63f091f) in lldb expressions: isolated

Evidence: `raw/vm/guard/` (diag1, b1, b2, b2-compile, b2-unwind, t1, t23, t4, tv, tfix; JIT
objects saved with `target.save-jit-objects-dir` in `jit*/`).

- lldb sees guest processes as `arm64e.x1-apple-ios27.1.0` and JITs arm64e code (PAC calls),
  and the guest enforces the IA key. code 261 = 0x105 = `EXC_ARM_PAC_FAIL`; subcode
  0xd63f091f is the instruction `blraaz x8`.
- Bisecting `smoke-springboard.lldb`: the `[UIScreen screens]` half with all its blocks runs
  (b1). Adding the coordinator half (b2) faults every time.
- `expr -u false` left SpringBoard at the fault (b2-unwind): `blraaz x8` with
  `x8 = 0x0000000188000800 libobjcMsgSend.dylib`objc_msgSend` — an **unsigned** pointer.
- The JIT objects show why. A cast call `((T (*)(…))objc_msgSend)(…)` becomes a ptrauth
  constant (IA, discriminator 0). lldb signs such constants in the target, in the module
  initializer `lldb.arm64.sign_pointers` (`mov x16,#0; pacia1716`), into a private slot
  (`l___unnamed_N`). But only **one** call site uses that slot. Every other cast-call site of
  `objc_msgSend` in the same expression loads the plain GOT entry `_objc_msgSend` (the one
  ordinary message sends use with `blr`), which lldb fills with the raw address and never
  signs, and calls it with `blraaz` (tv: v1–v4, any return types, with or without loops).
- Confirmed by execution in Preferences (tfix): two cast `objc_msgSend` calls in one
  expression → EXC_GUARD, process killed. One cast call (t1), one cast call inside a `for … in`
  loop (t23, t4), blocks, nested blocks: all fine.

**Trigger: two or more cast `objc_msgSend` call sites in one expression.** Size, blocks and
loops are irrelevant. smoke-springboard.lldb has two (`displayContentModeForWindowScene:` and
`isAppliedDisplayContentModeUserInitiatedForWindowScene:`). The simulator never hits it
because simulator processes are arm64 (no PAC). The same probably holds for any other C
function referenced both directly and through a cast in one expression; not tested.

**Fix used by every `probes/vm-*.lldb`:** take the pointer once and cast the variable:
`void *vpMsg = (void *)objc_msgSend;` then `((long (*)(id, SEL, id))vpMsg)(…)`. One reference
→ one signed slot (tfix "fix ok", two types, inside a `for … in`). A simulator probe with at
most one cast `objc_msgSend` runs unchanged; one with more needs this one-line substitution
(`sed 's/))objc_msgSend)/))vpMsg)/'` plus the declaration).

SpringBoard restarts caused while isolating it: 522 → 647 (b2), 647 → 706 (b2-unwind).
Preferences was killed once on purpose (tfix).

## Two more JIT traps on the VM, and one guest-code trap

- **`strcmp` / `strncmp` return garbage in expressions** (`raw/vm/guard/strncmp.txt`:
  `strncmp("{CGRect=x", "{CGRect=", 8)` = -1944147536, `strcmp("ab","ab")` ≠ 0; `strlen` is
  right). lldb finds libsystem_c's `strncmp` with no address and binds something else. Every
  sim probe that dispatches on a type encoding (`display-*`, `chrome-state`) silently took
  the "unsupported struct return" path, and skip lists keyed on `strcmp` stopped skipping.
  `probes/vm-convert.zsh` now also declares block versions `vpStrncmp` / `vpStrcmp` first in
  each expression and rewrites the calls.
- **EXC_BAD_INSTRUCTION, subcode 0xdac1a7fe** = `PACIBSPPC` (FEAT_PAuth_LR, the "x1" part of
  `arm64e.x1`). The VM's CPU does not implement PAuth_LR, which is why the dyld cache is
  X1-lowered; code that is not lowered faults on its first instruction. Found in backboardd:
  `objc_copyClassList` realizes every class, and one of them runs unlowered code
  (`raw/vm/guard/bbd*.txt`; markers written to `/var/tmp/vpprog.txt` in the guest located it).
  `IOHIDServiceCopyProperty` / `IOHIDServiceGetRegistryID` through `dlsym` pointers are fine.
  `probes/vm-sensors-backboardd.lldb` checks named classes instead (the sim list was empty
  anyway). Avoid `objc_copyClassList` in guest probes. Each of these faults was returned to
  the pre-expression state by lldb; backboardd (pid 61) survived all of them.
- `display.auto_lock.set` did not change the effective Auto-Lock here: requests for 0 and
  2147483647 (Never) both read back 60 s, also 10 s later. It was set back to 60 s at once.
  For measurements the probes take SpringBoard's own idle-timer disable assertion instead
  (`probes/vm-springboard-disable-autolock.lldb`, as in the sim), which a SpringBoard restart
  drops.
- `probes/vm-sensors-coremotion.lldb`: three more VM-only changes. `?: [NSNull null]` on the
  handler dictionaries (the VM's `_cmMagicPoseManager` is nil, so the sim's literal threw);
  `+[CMAngleManager shouldEmitWakeLatencySignpostsOnStateChangeForTesting]` not called
  (EXC_BAD_ACCESS at 0x4c); no fresh `[[CMAngleManager alloc] init]` (it blocked SpringBoard's
  main thread until lldb gave up with SIGSTOP). **SpringBoard restart 706 → 1440** followed
  those two runs (start time 20:20:03, seconds after the SIGSTOP run detached).
- `probes/vm-display-backboardd.lldb`, VM-only changes beyond vm-convert:
  `-[CADisplay _copyDebugProperties]` not called (SIGABRT in backboardd; the VM's CADisplays
  have no `stateControl`), `+[BKDisplayBrightnessController sharedInstance]` and
  `+[BKDisplayRenderOverlayManager sharedInstance]` not called (both EXC_BAD_INSTRUCTION
  0xdac1a7fe, the same unlowered PAuth_LR code). Found with
  `src/vm/display/iterate-vm.zsh` (the VM version of `src/display/iterate.zsh`: reads the
  guest's `/var/tmp/vptrace.txt`) and, because the last traced getter is not always the
  culprit (it walks backwards through the getter list when the fault comes later), a debug
  copy that traces every record add (`src/vm/display/dbg.lldb`). backboardd survived every
  interrupted expression (pid 61 throughout).

## How the VM column was measured

- Posture: vphoned `display.posture` (`{"hinge":"closed","position":"closed"}`,
  `{"hinge":"partially-open","position":"book"}`, `{"hinge":"open-flat","position":"open"}`),
  which sets SpringBoard's test-automation pose override and sweeps the virtual hinge HID. The
  sim used SpringBoard's own display-swap coordinator instead; values from
  `SBFDevicePoseProvider` onward compare.
- Rotation: `display.rotation {orientation: degrees}` (lit-panel interface orientation; inner
  0 landscape-left, 90 portrait, 180 landscape-right, 270 upside-down; cover 0 portrait,
  90 landscape-right, 270 landscape-left).
- Each step: `probes/vm-run.zsh snap` (screen.unlock, display.pose, display.orientation,
  device.screen, a screen.screenshot with its size and lit/dark, the SpringBoard pid, then the
  probes), driven by `src/vm/run-plan.zsh` (phases postures, rotations, safari, preferences),
  `src/vm/run-autolock.zsh` and `src/vm/run-lockchrome.zsh`. Step order: `raw/vm/steps/ORDER`.
  `probes/vm-retag.zsh` rebuilds each step's `records.jsonl` from the transcripts;
  `probes/vm-merge.zsh` writes `vm-<domain>.json`. Helpers used to read the results:
  `probes/vm-summary.zsh` (posture table), `vm-chrome-keys.zsh`, `vm-app-keys.zsh`,
  `vm-compare.zsh` (sim vs VM by api+call, inner display names mapped).
- SpringBoard's idle timer was held off with its own disable assertion
  (`vm-springboard-disable-autolock.lldb`, re-taken after a SpringBoard restart), as the sim's
  `SBDisableAutoDim` default does; the guest's Auto-Lock setting stayed 60 s.
- The VM shows one composited panel (the cover `LCD`, the only AppleParavirtDisplay,
  1398×2034). `screen.screenshot` captures it: 1398×2034 portrait when closed, 2034×1398 when
  book/open (the inner content scaled onto the landscape panel). "Which panel is lit" therefore
  comes from SpringBoard (content mode, backlight state) and backboardd (window-server
  enabled/blanked), with the screenshot size as a cross-check.
- `display.rotation` reads `orientation` only as a JSON **string** (`{"orientation":"90"}`);
  a number is silently ignored and the call just reads back. The first rotation phase used
  numbers; those steps are in `raw/vm/steps/discarded/*-numeric-orientation-ignored` and
  were all re-run (`run-plan.zsh rot2`).
- `-[SBLockScreenManager lockUIFromSource:withOptions:]` on the primary scene worked in open
  but hit EXC_BREAKPOINT in closed (`raw/vm/steps/closed-lockscreen-pose/lockcmd.txt`, lldb
  returned SpringBoard to its prior state). Step `closed-lockscreen` is therefore *not*
  locked; the cover lock screen was measured with a simulated lock-button press instead
  (`closed-lockscreen-button`).

## Data

| file | records | steps |
| --- | --- | --- |
| `vm-springboard.json` | 26716 | 32 |
| `vm-display.json` | 30521 | 23 |
| `vm-chrome.json` | 69408 | 10 |
| `vm-appkit.json` | 5542 | 15 |
| `vm-sensors.json` | 1266 | 16 |

Steps, in order (`raw/vm/steps/ORDER`; the posture label is in each record):
open-sbstart, closed-after-open, book-after-closed, open-after-book, book-after-open,
closed-after-book, open-after-closed, Safari (closed, unfold to open, book, fold),
Preferences (closed, book, open, fold), rotations (closed Preferences 90, closed Safari 90 /
270 / 0, closed home 90, open 0 / 180 / 270 / 90), history (Preferences launched on the
inner then folded, Safari with the cover landscape then unfolded), lock screen (open,
closed), auto-lock (open auto-locked, folded, 20 s later, fold after a lock-button press),
closed lock screen via lock button. `raw/vm/rpc/` holds the boot-state `display.modes` and
`device.displays`. Not run: VPAppKitProbe (callback sequence, public `UIHingeInteraction`),
notification pushes (platter widths), CMQuery/blocking probes.

## Results worth reading before the table

- Posture policy, primary scene, content modes and SpringBoard backlight states match the
  sim in every posture and history path. Book is the only posture with a value off: the
  override derives 90° from hinge state 2 (`display.posture`'s reply says `angle 100` and
  the HID gets 100°, but `SBFDevicePoseProvider` and `uiHingeStatus` read 90°).
- Display stack: the VM keeps one real panel (`LCD`, 1398×2034 @3, 120 Hz) and adds the
  inner as a second CADisplay `VPhone Duo Inner` (displayId 7, native 2853×2007 landscape,
  pointScale 1, sRGB, no physical size). No CADisplay has a `stateControl`. FBS/UIKit see
  identity `Unknown[7]` (apps: `Unknown.main[7]`), not UIKitMainLike, not embedded. FBS
  bounds, sbh screen types, exclusion area, BKS surface type, window-server orientations
  and the inner rot90 all match.
- Everything an app sees matches: screens count, main screen, bounds, size classes,
  orientation, safe areas, corners, surface type, scene regions with `innerCover` active
  only in book, the Preferences split widths, hinge-state delivery, and both history
  effects on client orientation.
- Rotation matches in open (4/1/2/3, per-panel pose orientations). Closed, the cover's
  pose orientation equals the device orientation (sim: the opposite landscape). The cover
  home screen stays portrait (mask 2) and vphoned reports the rotation as not applied; a
  landscape app (Safari) does turn the cover landscape. The earlier "VM refuses cover
  landscape outright" was the home-screen case.
- CoreMotion: no magic-pose, device-state or angle manager (all `isAvailable` NO); the
  class-method tables (`orientationForMagicPose:deviceSurface:`, `propertyAForConfigType:…`)
  are CoreMotion's own and equal the sim's everywhere, tabletop and A=7 included.
- No AOD on the VM, so auto-lock turns the panels off instead of dimming them; folding
  while auto-locked moves primary to the cover lock screen with the cover off. Nothing lit
  the folded inner.
- `SBFDevicePoseProvider`: `internal.isOnVM` YES (sim NO), `_accelerometer` is a
  BKSAccelerometer (sim nil), `SBHingeMotionUnintendedInteractionMonitor` nil.
- After `screen.unlock` in open, the cover scene's lock-screen manager stays locked and
  visible while the inner is unlocked (sim: both unlocked). It clears after a fold.

## SpringBoard restarts during this work

| pid | cause |
| --- | --- |
| 522 → 647 | b2: the smoke-probe bisect (EXC_GUARD, two cast `objc_msgSend`) |
| 647 → 706 | b2-unwind: the same expression run with `-u false` to capture the PC |
| 706 → 1440 | sensors-coremotion debugging: a fresh `CMAngleManager` blocked the main thread until lldb stopped it (SIGSTOP); SpringBoard was replaced seconds after detach |
| 1440 → 2384 | rot2 `closed-home-rot90`: before the probe attached; lldb could not connect to the guest debugserver (which had been started with `--attach`), so SpringBoard most likely stayed stopped and was killed. No crash report. Redone on 2384 |

backboardd (pid 61) never restarted. Preferences was killed once on purpose (tfix).

## Final guest state

duobase-01 running, SpringBoard pid 2384, open (`display.pose` hinge 3), device portrait
(inner interface orientation 4), unlocked, Safari and Preferences terminated, Auto-Lock
setting 60 s (unchanged; `display.auto_lock.set` was set back to 60). SpringBoard holds the
probe's idle-timer disable assertion ("vphone baseline: auto-lock off again") so the guest
stays unlocked; it goes away with the next SpringBoard restart.

## 2026-10-30: second pass after the duo-sim-align fix

Bundle **2.14.0-local.9064efca** (branch duo-sim-align, worktree HEAD aa274dcc at
measurement time): V68 `product-id`, `/product/display0` + `display1` panel nodes,
`MGGetLogicalDeviceDisplayCount` 2, CoreMotion's device-state relay fed by libvphonehinge's
`VPhone Host Controls` (0xFF61/0x5B). Same VM, same iOS. Only the rows the fix can affect
were measured; BASELINE.md marks them "2026-10-30" and keeps the first-pass value as
"(was: …)".

### Method

- Driver `src/vm/run-fix.zsh` (phases respring, postures, postures2, statusbar, coremotion,
  safari, lock, final), same probes as before. Every lldb attach waits until 45 s have passed
  since the previous one ended, postures settle 20 s and rotations 25 s before any attach,
  and the SpringBoard pid is read before and after each attach. Steps are
  `raw/vm/steps/fx-<label>/`, in order in `raw/vm/steps/ORDER.fix-9064efca`; logs
  `raw/vm/plan-fix-*.log`. `src/vm/merge-fix.zsh` appends them to `vm-*.json` with
  `"bundle": "2.14.0-local.9064efca"` and `step` `fx-<label>` (meta: `meta.fix`, and the
  step snapshots in `meta.steps` carry the bundle). Re-running it replaces the fx records.
- `display.pose` reads SpringBoard's test-automation snapshot, which this bundle no longer
  writes; `rpc.json` keeps it as `display_pose_stale`. The pose comes from
  `SBFDevicePoseProvider` (`sensors-springboard`), and `display.posture` replies
  `source: coremotion`.
- HID service names come from vphoned's `device.input_devices` (step `fx-hid-rpc`, record
  `vphoned.device.input_devices` in `vm-sensors.json`), not from lldb (next section).
- CoreMotion managers: `sensors-coremotion` ran in MobileSafari first as a canary (now that
  `+isAvailable` is YES, `+sharedManager` creates objects), then in SpringBoard. Neither hung.
  No fresh `CMAngleManager` was created.
- Lock screen: two `input.button {"name":"power"}` presses in closed (lock, then wake to the
  lock screen), then `chrome-lock` without unlocking (`fx-closed-lockscreen`, lit screenshot).

### Incident 1: the backboardd HID probe wedged CoreMotion

`probes/vm-sensors-backboardd.lldb` in backboardd (step `fx-open-after-book`, 01:29) was
interrupted with SIGSTOP about 9 s after it started, without output; lldb returned backboardd
to its prior state. From then on SpringBoard's pose stayed at open/180° through closed, open,
book and closed requests (`raw/vm/steps/discarded/fx-*-locationd-wedged`), although
libvphonehinge kept sweeping and dispatching host-control events (its status counters kept
rising). vphoned's `device.input_devices`, which copies properties of every HID service, then
hung for 120 s and the guest agent dropped its connection once (`raw/vm/steps/fx-diag/`).

The probe calls `IOHIDServiceCopyProperty` for every service from backboardd's main thread.
On this bundle that includes the two `CoreMotion_DeviceStateRelay_*` services, which
locationd owns; on the first-pass bundle they did not exist and the same probe ran cleanly
(step `open-sbstart`). Which side was left blocked is not settled. Recovery: SIGTERM to locationd
(`processes.kill` with `force`, pid 66). launchd restarted it (1060), and **backboardd
(516 → 1061) and SpringBoard (518 → 1064) restarted with it**, start times within 0.3 s. After
that `device.input_devices` answered at once and CoreMotion followed the fold again.

Do not run `vm-sensors-backboardd.lldb` (or any lldb `IOHIDServiceCopyProperty` walk in
backboardd) on a guest with the relay; use `device.input_devices`. `systemEventOfType:0x2c`
was therefore not re-read in this pass.

### Incident 2: SpringBoard 1064 had no idle-timer assertion

The restart in incident 1 dropped the probe's idle-timer assertion. In the next run the
guest auto-locked in closed; the unfold woke it to the lock screen, `isUILocked` read YES,
the resolver's prevailing policy read `Yoink(inner)` in open and the following book, and one
unfold made while the screen was dark was never published (SpringBoard stayed on the cover,
`device.screen` 466×678, while the hinge provider was at 180°). `display.rotation` was refused
while locked. Those steps are in `raw/vm/steps/discarded/fx-*-sb1064-autolock-on` and
`fx-sb-open-aborted` / `fx-open-rot0-aborted`. The assertion was taken again
(`raw/vm/autolock/fix-disable-pid1064.txt`), the fold resynced with the screen lit (closed,
then open), and the posture paths re-run. `run-fix.zsh` now stops a step when SpringBoard
does not hold the assertion (`keep`).

### Results

- Posture table: FullyClosed / FoldingDual, primary scene, content modes 2/1 and 3/2,
  backlight 1/4 and 4/1 match in closed, book and open on both history orders. Book reads
  99.444° (position 0.552; mechanical 100); closed region 0→0.2747 and toClosed 0.5525→0.03
  in book, 0→0.47 otherwise.
- CoreMotion: all three managers available, SpringBoard's provider holds CoreMotion's
  managers (handlers registered, angle updates at 0.01 s), `sharedManager` exists and is a
  separate instance, `_accelerometer` nil: the sim's structure, with live values.
- HID: `CoreMotion_DeviceStateRelay_Crane` 0xFF0C/0x21 and `_DeviceState` 0xFF0C/0x22
  (Virtual), plus `VPhone Host Controls` 0xFF61/0x5B.
- Display identity: `extendedProperties` and MobileGestalt `DisplayExtendedProperties` equal
  the sim's except the cover corner radii ([5,5,59,59] against [8,8,59,59]); display count 2;
  inner 460 ppi, physical size 6.2022×4.3630 in; inner mode 669×951@3x at 120 Hz, sRGB,
  with the extra 951×669@3x mode. Names and FBS identity unchanged.
- Transition style 2 straight after the forced respring (closed), 2 after every swap, 3 with
  Safari in front.
- Inner portrait-shaped status bar (interface orientation 1): {592,0,77,951} in both
  captures. At orientation 1 straight after a SpringBoard start, before any rotation:
  0-rect, as in the sim.
- Closed with Safari on the cover: device 4 → cover 4, device 3 → cover 3, from CoreMotion's
  `cmMagicPose`. CoreMotion's table maps a closed hinge to the cover unchanged, so the sim's
  opposite landscape is its swap tool's.
- What Safari sees in closed / book / open matches the sim (screens, bounds, size classes,
  orientation, safe areas, corners, surface type, regions, hinge state 0 / 99.4 / 180).
- Lock-screen clock: the VM's active lock-screen poster is
  `com.apple.MercuryPoster:configuration:v68.colorB`, a photo poster with an adaptive
  (stretched) time: `adaptiveTimeTextHeight` 213.01, font weight `wght3200000`, 128.77 pt,
  clock 372×240.28. The sim's is `celosia.timeOfDay`: adaptive height 105, `wght2800000`,
  110.03 pt, clock 372×132.26. The layout limits (104.74 / 303.68) and styles are the same,
  so the height difference is the poster's personalization, not layout.

### SpringBoard restarts in this pass

| pid | cause |
| --- | --- |
| 37 → 518 | the allowed forced `system.respring`, in closed, for the transition-style row; backboardd also restarted (61 → 516) |
| 518 → 1064 | SIGTERM to the wedged locationd (incident 1); backboardd 516 → 1061 restarted with it |

No attach changed the SpringBoard pid.

### Final guest state (2026-10-30)

duobase-01 running bundle 2.14.0-local.9064efca, SpringBoard 1064, backboardd 1061,
locationd 1060. Open (`SBFDevicePoseProvider` `.openFlat`, 180°), device portrait, inner
landscape-shaped home screen, unlocked, Safari terminated. SpringBoard 1064 holds the
probe's idle-timer assertion ("vphone baseline: auto-lock off again") until its next
restart; the Auto-Lock setting is still 60 s.
