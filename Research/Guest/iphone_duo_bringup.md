# iPhone Duo bring-up

## Kernel CSSC fallback (2026-10-25)

This branch starts from upstream main, without the static CSSC trampoline
experiment. On an independent Banana clone, the installed experimental image
panicked with PID 1 SIGILL at user PC 0x2bd6380e8, ESR 0x02000000. The kernel's
exception codes contained the copied instruction 0xdac1a7fe (PACIBSPPC), matching
/usr/lib/libSystem.B.dylib at image offset 0x10e8. CSSC allocation had aborted
the entire X1 cache operation, leaving PAuth/CPA conversion unapplied; the
installer nevertheless continued. The new route retains upstream PAuth/CPA
conversion and handles CSSC independently in the kernel.

Reveal procedure for `kernelcache.research.vphone600`, UUID
784F88D3-2AF5-3D4A-AB00-365607646E44:

1. Find the unique function referencing `Undefined kernel instruction: pc=%p
   instr=%x`. Identify it as XNU handle_uncategorized by decoded control flow,
   not a recovered symbol (the indexed research symbol JSON is absent).
2. Validate its copyin of four bytes from the saved PC and its EL0/EL1 gate.
   Hook only the user path before undefined-instruction triage. The observed
   handler file offset is 0x1e626ec; the hook is 0x1e62918.
3. Follow the handler's existing signed-state manipulation sequence to recover
   ml_check_signed_state (0x1caa37c), ml_sign_thread_state (0x1caa32c) and its
   interrupt disable/restore helpers. Validate register and saved-state ABI,
   PACGA bodies, and the original stack-canary checked epilogue. These names
   are source correlations; offsets are observations, never runtime constants.
4. Plan the complete fixed-size payload and one entry branch before writing.
   Restrict it to persistent __TEXT_EXEC; do not use boot-only reclaimed text.
   Unknown or ambiguous layouts abort the selected operation.

The fallback accepts only 64-bit user saved states with an uncategorized
exception and successful instruction copyin. It evaluates scalar ABS/CNT/CTZ
and signed/unsigned MIN/MAX register and immediate forms, preserving the
saved NZCV and all unrelated registers. W results zero-extend and register 31
is ZR. A successful operation verifies the old signed state, updates the
destination and PC, and re-signs with the new LR/X16/X17 when applicable.
There are no stack accesses while SPSel selects the interrupt stack. The
original canary check and epilogue remain in use. Unknown words preserve the
original instruction, registers, kernel flags and exception path.

Kernel emulation has per-execution exception overhead. Native CSSC execution
does not enter this fallback; PAuth/CPA retain the existing X1 conversion path.

## Scope and inputs (2026-10-23)

This experiment attempts to boot the iPhone Duo userland on the existing
vphone600 virtual hardware. It registers one outer panel, not two displays or a hinge.
The inner panel, folding poses and physical Duo hardware are not emulated.

- Host: Apple Silicon, macOS 27.0.1 (26A434), without CSSC, CPA or PAuth_LR.
- Guest: `iPhone19,4`, board `v68ap`, iOS 27.1 (24A94425).
- IPSW: <https://updates.cdn-apple.com/2026FallFCS/3f41a447-d8a6-48ae-83ae-056a64f57fd4/iPhone19,4_27.1_24A94425_Restore.ipsw>.
- Size: 12,724,731,538 bytes.
- SHA-256, verified after download:
  `58fbfda85615e90221136d55288f64c9f41386510f8cd77feb8c9d20cc0a782e`.
- CloudOS: 26.4 beta (23E5207q), the existing recommended vphone600 image.
- Preset: `standard`; boot ROMs: the bundle's OpenAVB and OpenSEP.
- VM configuration: 8 CPUs, 8192 MiB RAM, 64 GiB disk, created without a template.
- Core Bundle: a local 2.12.0 build; installed and passed execution policy
  and host preflight.

## Evidence and initial implementation

The restore archive's `BuildManifest.plist` and `Restore.plist` both name
`iPhone19,4`, build 24A94425 and device class `v68ap`. Restore.plist records
CPID 33120 (`0x8160`), BDID 14 (`0x0e`), platform `t8160`.

The archive contains `Firmware/all_flash/DeviceTree.v68ap.im4p`. Its `/product`
records `app-macho-architecture = arm64e.x1`, `artwork-device-idiom = phone`,
`artwork-device-subtype = 2034`, `artwork-scale-factor = 3`, plus `display0`
and `display1` children. The former has display index 0, rotation 0 and scale
3; the latter has index 1, rotation 270 and scale 3. Those are source device
properties, not proof that both panels work in the VM.

The initial model entry uses the outer display's 1398 x 2034 pixels at 460
ppi and 3x, as published in [Apple's technical specifications](https://www.apple.com/iphone-duo/specs/).
The catalog adds only the released 27.1 IPSW, paired with the existing
recommended cloudOS. No new instruction patch or preset is introduced;
the current iOS 27 and ARM64E_X1 patches are exercised on this new userland.

`VPhoneCoreKitTests/GuestDeviceTests` and
`VPhoneCoreKitTests/FirmwareCatalogReportTests` passed: 26 tests total.
The complete `VPhone` Debug build passed. Its finished bundle and a ZIP
round-trip both passed strict, nested, all-architecture signature validation
before the local bundle was installed through Launchpad.

## Boot validation

**Result: does not boot to userspace on this host.** Firmware preparation,
boot-chain patching, DFU restore and CFW installation completed. Template
setup failed while waiting for vphoned because the guest panicked. A subsequent
windowed `vm start <name> --wait --timeout 300` reproduced it before any guest
agent connection or SpringBoard UI:

```text
initproc failed to start -- exit reason namespace 2 subcode 0x4 description: none
Panicked task ... pid 1: launchd
Kernel UUID: 784F88D3-2AF5-3D4A-AB00-365607646E44
```

Namespace 2/subcode 4 reports SIGILL. The saved user-space backtrace LR is not
a recovered fault PC or a verified unslid symbol address. Do not infer an
exact instruction from it without the image load address and fault state.
Runtime addresses and local machine identifiers are omitted from this record.
The VM was stopped after preserving the console log. Its disk,
firmware and installed guest environment remain available for investigation.

### Identified instruction compatibility gap

Host feature queries return zero for `hw.optional.arm.FEAT_CSSC`,
`hw.optional.arm.FEAT_CPA` and `hw.optional.arm.FEAT_PAuth_LR`.
The installed, already X1-lowered `/usr/lib/dyld` still contains scalar CSSC
instructions: for example `UMIN X8,X8,X1` at image offset `0x9570`, `UMAX`
at `0x8ba8`, and `CTZ W10,W21` at `0x1af04`. These are measured offsets in
the 24A94425 dyld, for investigation only, never patch-site constants.

`VPhoneArm64eX1Lowering` and the runtime X1 handler currently lower PAuth_LR
and CPA forms, not these CSSC operations. CSSC therefore is a confirmed
compatibility gap and a candidate explanation for the SIGILL, not yet a
proved fault-site attribution. The cache's early-boot closure and later
runtime code also need auditing before claiming 27.1 support. A safe fix
needs correct register width, operand aliasing, NZCV preservation and immediate
forms; replacing a min/max with an unconditional move is not equivalent.

### Other observed gaps

- Four optional VirtualAudio patches failed together because the old reveal
  expected a `retab` after the throw at `0x171cd0`:
  `system-virtualaudio-cfw-mute_set_throw`,
  `system-virtualaudio-cfw-speaker_protection_gate`,
  `system-virtualaudio-cfw-speaker_route_throws`, and
  `system-virtualaudio-cfw-volume_mode_precondition`.
- The shared-region preflight attempted the ordinary arm64e filename and
  skipped its check; later cache patching correctly found 79 X1 chunks and
  measured `sharedRegionSize = 0x17ce04000`, `maxSlide = 0x20000000`, then
  zeroed maxSlide. No cache-size overflow was reported by that later stage.
- Existing X1 lowering reported 2735 instructions in launchd, with zero
  unvisited candidates. This only counts the instruction forms it recognizes;
  it does not establish support for every instruction in the binary.

The registered model and catalog entry are experimental bring-up inputs,
not a claim of successful Duo support. No CSSC or audio patch was added by
this experiment. Supporting this firmware on hosts without CSSC requires
additional instruction compatibility work; emulating both displays and the
hinge is a separate gap. These results establish limitations of the current
implementation, not that supporting the device is technically impossible.

The original manifests and device tree were extracted by HTTP ranges with
the repository's `VPhoneRemoteZip`. Raw logs and scratch artifacts remain
local; host paths, per-machine identifiers and runtime addresses are not
included in this research record.

## Boot on a host with CSSC (2026-10-23)

**Result: boots to SpringBoard.** On a Mac17,9 (M5 Pro), macOS 27.0.1
(26A434), `hw.optional.arm.FEAT_CSSC` is 1; `FEAT_CPA`, `FEAT_CPA2` and
`FEAT_PAuth_LR` are 0. Scalar `UMIN`/`UMAX`/`CTZ` execute on the host. The
same IPSW, the same standard preset and a Core Bundle containing this
document's first commit (no CSSC lowering) completed every `vm create
--device iPhone19,4 --no-template` step, including template setup, which
waits for vphoned. The home screen rendered at 1398 x 2034. Its side dock and
status column on the right are the Duo's outer-display design, not a fault.
CSSC is therefore the blocker on hosts without it; PAuth_LR and CPA remain
covered by X1 lowering.

### On-demand X1 handling stalled the userland

That boot was barely usable: windows took seconds to draw, widgets stayed
blank, and FrontBoard killed extensions. 18 minutes after boot, launchd
(PID 1) had used 685 CPU-seconds. Crash reports showed `MercuryPosterExtension`
(43 reports), `WidgetRenderer_Default`, `DockFolderViewService` and others
ending in `scene-create watchdog transgression … 10.00 seconds`, many with a
pending `EXC_BAD_INSTRUCTION` whose code is the X1 word itself:
`0xdac1a7fe` (`PACIBSPPC`) in SwiftUI and `/usr/lib/usd/libusd_ms.dylib`,
`0x5520031f` (`RETABSPPC`) in `libusd_ms.dylib`.

The cause is the design of the X1 path, not a missing instruction form.
`dyld-boot-arm64e_x1_bootstrap` lowers only the 38 cache images needed
before launchd installs its exception service; every other image faults
into that service, which runs on one thread in PID 1, suspends the task,
makes a private copy of the page and lowers one instruction. A private copy
means each process re-faults every site it executes, so SwiftUI-heavy
extensions queue on launchd until the 10-second scene watchdog fires, and
the poster extension's restarts keep the queue full.

### Lowering the rest of the cache ahead of time

`dyld-cfw-arm64e_x1_cache` (guest system set, iOS 27, on in `standard`,
blocked in both tvOS presets; verb `vphone-cli cfw patch-arm64e-x1-cache`)
runs the bootstrap patch's planner over every X1 image outside the
bootstrap closure, writes through the undo-capturing chunk set and
re-attests every modified page. An image the planner cannot plan is left to
the on-demand handler and logged; none were on 24A94425.

| 24A94425 cache | Value |
| --- | --- |
| Images | 4,664 (4,508 with X1 code, 0 skipped) |
| Instruction rewrites | 24,606,083 in 212,573 page runs |
| Left to the on-demand handler (unvisited candidates) | 250,443 |
| Examples | UIKitCore 235,776; `libusd_ms.dylib` 353,431; SwiftUI 134,497; SwiftUICore 116,029 |

The installed guest receives 24,606,071 rewrites, 12 fewer: other dyld
patches already occupy those sites.

The planner needed changes to be affordable at this size; each was checked
by patching a stock copy of the cache and comparing all 81 cache files with
the previous version's output (and, for the bootstrap patch, with the bytes
HEAD wrote), and every comparison was identical:

| Change | Full pass on M5 Pro |
| --- | --- |
| Serial, page-decoding planner | about 26 min (dry run) |
| Parallel images, thread-local C locale (Capstone's `vsnprintf` serialized every thread on the global locale), one-word decodes instead of a 16-page cache that thrashed | 8.5 min |
| Decode cache keyed by instruction word; code ranges unpacked to `[UInt32]` once (a generic `loadLE` across PatchKit's resilient boundary cost a metadata lookup per word) | 200 s |
| Bitmap visited/scheduled sets, largest images first, PC-relative words cached once Capstone confirms a single address/page/no move at a second address, top-byte gates before mnemonic comparisons | 95 s |
| One decoder per worker reused across images; branch, literal and ADR/ADRP words keyed by family (offset field cleared, target computed from the encoding, the operand's aliased register/memory views rebuilt), each family trusted only after Capstone agrees at a second target; planning readers map each chunk once | 1,241 → 914 user CPU-s (wall time not comparable: load average 24–31) |
| Words outside the lowered and flow top bytes checked for decodability only (a word-keyed answer shared by all workers); data-in-code and dispatch tables as a bitmap instead of a scanned range list; replacement text through the word cache | 914 → 291 user CPU-s, 41 s wall at load 5–8 |

The planning core, `CustomFirmwareArm64eX1.planCode`, is shared with the
standalone-executable patches; its output is unchanged by these edits.

After `vm set-bundle … --update-environment` applied the patch to the
existing guest, launchd had used 14.8 CPU-seconds two minutes after boot,
no poster or widget-renderer watchdog kills recurred, and Settings drew its
first screen within seconds of launch. Standalone X1 binaries outside the
cache (app executables, plug-ins such as `VirtualAudio.plugin`, daemons)
still use the on-demand handler.

### VirtualAudio on 27.1

The four VirtualAudio CFW patches failed on 24A94425 because every function
there starts with `PACIBSPPC` and returns with `RETABSPPC <label>`; the
reveal knew only `PACIBSP`/`RETAB`. The patcher now accepts both families
and requires a labelled return to name the function being walked. Capstone
reports that label as `#0`, so it is read from the decoded word's field.
All nine sites patch on 27.1 and the 26.6.2 and 27.0 sites are unchanged.
With them live, audiomxd crash-looped on this guest (a null read in
`VirtualAudio.plugin` reached from `SetPropertyData`): the device update
reads the DeviceStateManager singleton before deferred initialization
publishes it. Root-caused and fixed by
`system-virtualaudio-cfw-device_state_null_gate` (make the two gated
device-state updates wait for the DeviceStateManager singleton — on a
guest with no haptic hardware it is never constructed — instead of
dereferencing null; arm64e.x1 plugins only, earlier builds
byte-identical) — see
`Research/Guest/virtualaudio_speaker_route_throws.md` § "Layer 5" and
`Research/0_binary_patch_comparison.md`. Verified on this VM
(2026-10-24 morning, bundle `2.12.0-local.6a386de6`): both gate calls
redirected as designed, audiomxd holds one pid past five minutes — the
window the two earlier variants died in — with zero new crash reports
and the system-sound stream still routed on `PuffinOutput`.

## Fold posture (2026-10-23)

Static analysis of the 24A94425 cache, then a live run on `duotest-m5`
(M5 Pro) with `preboot-cfw-devicetree_foldable_vm_subtype` and
`display.posture` installed:

- The repair logged `target-sub-type: 'V68AP' -> 'V68VM2025'`, and after boot
  SpringBoard had created `SBFDevicePoseLastKnownCMAngle` and
  `SBFDevicePoseLastKnownCMMagicPose` in `com.apple.springboard` (still all
  zero: it persists after display-mode transitions, which a single display
  never makes).
- `display.posture {hinge: "partially-open"}` was accepted: SpringBoard
  logged `[SBTestAutomationService] Received client request to set device pose
  override`, `Ambient magic pose event detected [ … hingeState : PO ;
  deviceOrientation : Po … ]`, and `hinge MOTION STARTED` … `hinge SETTLED
  after 1.03s`, with the home and lock screens deferring and resuming
  snapshots around it. Closed, partially open and open flat produced the same
  home screen: with only the outer panel there is no inner surface to move
  content to. StandBy reported `isMagicPoseSupported : NO`.

**Where the pose comes from.** `SBFDevicePoseProvider` (SpringBoardFoundation)
reads `BKSAccelerometer`, `CMAngleManager` and `CMMagicPoseManager`.
SpringBoard's own CoreMotion hosts `CLAngleNotifier` (HID event type 0x2C,
`IOHIDEventCreateHingeAngleEvent`, virtual service 0xFF0C/0x21) and
`CLDeviceStateNotifier` (8-byte vendor event `{2, orientation ×3, hinge
state, tabletop pose, stable state, simulated}`, virtual service 0xFF0C/0x22).
CoreMotion skips physical sensors when MobileGestalt reports a virtual device.

**Why a virtual hinge HID service is not enough today.** SpringBoard starts
CoreMotion pose updates only when the angle and magic-pose managers are
available *and* `FBDisplayManager.alwaysConnectedIdentities.count >= 2`.
Availability comes from CoreMotion's motion-capability bits, selected by the
device tree's `/product/product-id`; the guest keeps vphone600's id, which
CoreMotion does not know, so both are false. One display fails the second
gate. The HID route belongs with dual-display work, together with V68's
`product-id` (which also turns on the Duo checks in UIKit, Photos,
Accessibility and other frameworks).

**What works now.** `-[SBSTestAutomationService setDevicePoseOverride:]`
bypasses both gates: SpringBoard (`SBTestAutomationService`, client
entitlement `com.apple.springboard.testautomation`) builds an
`SBFSyntheticMagicPoseEvent` from the device orientation, hinge state and
tabletop pose and derives the angle from the hinge state. vphoned exposes it
as `display.posture` (see `Research/vphoned_http_api.md`).

**Apple's VM sub-type.** SpringBoard treats a device whose `TargetSubType` is
`V68VM2025` as a VM: at launch it restores the angle and magic pose from
`com.apple.springboard` defaults `SBFDevicePoseLastKnownCMAngle` and
`SBFDevicePoseLastKnownCMMagicPose`, and `_persistDevicePoseIfNeeded` writes
them back after display-mode transitions. `preboot-cfw-devicetree_foldable_vm_subtype`
rewrites the installed Preboot tree's `target-sub-type` from `V68AP` to
`V68VM2025` after restore (restore keeps the board's value). The only other
reader of `V68AP` in the cache is Sharing's `SFDeviceHasFaceIDProxy`; the
framework `isV68` checks key on `product-id` and are unaffected.

## Virtual hinge (2026-10-24)

The pose override above reaches SpringBoard only. CoreMotion's `CMAngleManager`
never sees a hinge: no sensor publishes virtual service `0xFF0C/0x21`, and no
capability asks it to look, because CoreMotion selects its motion-capability
bits from the device tree's `/product/product-id`, which the guest keeps at
the VM platform's token. CoreDevice (DeviceHub) does not go through
SpringBoard at all: it asks the guest for a `hingeAngle` capability and
subscribes to the angle stream, which is CoreMotion's to answer.

Two patches close that path; both are on in `standard`, foldable guests only:

- `preboot-exp-devicetree_foldable_product_id` replaces the installed
  Preboot tree's `/product/product-id` with the foldable board's own 20-byte
  token, taken from the donor `DeviceTree.v68ap.im4p` in the VM's
  FirmwareOriginals during `cfw install` / `cfw update-environment` (verb
  `cfw patch-dt-foldable-product-id`; the repair runs after the VM sub-type
  one and accepts either sub-type). CoreMotion then reports the hinge-angle
  capability. The side effect is accepted by design: the frameworks' `isV68`
  checks key on the same token, so UIKit, Photos, Accessibility and others
  open their Duo branches on the one display the guest has.
- `system-backboardd-cfw-hinge` installs `libvphonehinge.dylib`, which
  SystemHook loads into backboardd. It publishes a `HIDVirtualEventService`
  with usage page `0xFF0C`, usage `0x21` (Product "VPhone Hinge Angle
  Sensor") and reports hinge-angle events built with HID.framework's C
  factory

      IOHIDEventCreateHingeAngleEvent(allocator, timeStamp, angleDegrees,
                                      mechanicalAngleDegrees,
                                      velocityDegreesPerSecond, options)

  whose signature was verified on macOS 27.0.1's HID.framework by calling it
  and reading the created event's own field description back (third argument
  = AngleDegrees, fourth = MechanicalAngleDegrees, fifth = the velocity);
  `make test-hinge` re-checks both the transport and that call. HIDEvent has
  no ObjC hinge factory selector — only `-hingeAngle*` accessors — so the C
  factory is `dlsym`'d from the framework the provider already opens. The
  service's life cycle, delegate selectors, `ReportInterval` aggregation and
  status preference mirror the accelerometer provider; a subscriber's
  interval drives a report timer, so a stream subscription keeps receiving
  the current angle. The event's state field stays unset (the factory takes
  none): SpringBoard's pose keeps coming from the override, which also means
  the two can be driven apart by an explicit `angle` when a test wants that.

`display.posture` now drives both halves from one request: it sets the pose
override as before, then publishes the angle to the virtual hinge — the
state's own angle from SpringBoard's table (0, 0, 90, 180, 180 for states
0–4), or an explicit `angle` (0–180). The reply carries the angle and the
provider's state under `hinge_hid` (`applied`, `provider_running`,
`provider`), so a host can tell a live stream from an absent service. The
pose override failing still fails the request; the hinge provider missing
does not — the pose is the primary and the service may legitimately be
absent (guest without the patch, or backboardd not restarted yet).

Still open, for live validation on a foldable guest:

- whether CoreDevice's capability question is answered by the product-id
  alone or needs another DDI daemon's answer patched (DeviceHubFix territory);
- whether the angle *stream* subscribes through the virtual service's
  `ReportInterval` as expected, and what interval DeviceHub asks for;
- whether the magic-pose vendor event (`0xFF0C/0x22`, `CLDeviceStateNotifier`)
  is wanted as well — HIDEvent's `+vendorDefinedEvent:usagePage:usage:
  version:data:length:options:` can carry it if a client proves to read it.

## Apple's own Duo simulator, reversed (2026-10-24)

The shipped iOS 27.1 simulator runtime (24A94425 — the same userland this
guest restores) and Xcode's DeviceHub answer how Apple itself models the
fold, with no guessing:

- **The device type registers two displays.** `iPhone Duo.simdevicetype`'s
  capabilities.plist carries a `displays` array: the outer 1398×2034 panel
  (`screenID` 1, phone15 chrome) and the inner 2853-pixel panel at native
  rotation 270 (phone14 chrome). SpringBoard's two-always-connected-displays
  gate is satisfied structurally, not by the product token.
- **The hinge is a recorded sweep, not a state.** SpringBoardFoundation ships
  `hinge-samples.csv` — 2,741 real samples captured by hand on an iPhone19,4
  ("SBFHingeAngleRecorder", CoreMotion's 10.03 ms grid) with columns
  timestamp, angle, mechanicalAngle, progress, angleValid, velocity,
  velocityValid, state, eventPhase. `SBFHingeSamples` loads loops from it
  (overridable at `/var/mobile/Library/SpringBoard/hinge-samples.csv`, env
  `SBF_HINGE_SAMPLES`), and `SBFHingeSamplePlayback` /
  `SBFHingeSweep` / `SBFHingeReplaySettings` /
  `replayHingeSamplesWithSettings:samplesPath:completionHandler:` replay a
  loop. `SBFHingeAngleHUDView` is the internal HUD.
- **The three screen states are positions of one command.** The help text of
  Apple's internal `suiatool` (embedded in SpringBoardFoundation) documents
  the sweep command:
  `[-duration=<seconds>] [-orientation=…] [-position=<closed|book|open|0.0-1.0>] [-fade | -continuous] [-wait]`
  — `closed`=0°, `book`≈100°, `open`=1.0 (180°); the device sweeps from its
  current angle to the target, a display swap happens only if the sweep
  crosses the boundary, `duration=0` is the instant "yoinking path", opening
  is faster than closing by default, and every sweep takes a 10-second
  testing lock (`lockForTesting`) so real hinge motion is ignored.
- **CoreDevice's read side** (`DeviceMotionManager.monitorHingeAngle`,
  `supportsHingeAngle`; `DeviceHingeAngleSnapshot` with angle, mechanical,
  velocity, validity, min/max, timestamp) mirrors those same fields — the
  CSV's schema is the protocol's schema.

`display.posture` now follows this model: `position` names `closed`, `book`
or `open` (or a 0–1 fraction), `duration` (seconds, default per-direction,
0 instant) and `profile` (`continuous` | `fade`) request a sweep; the
virtual hinge provider interpolates from the current angle at 10.03 ms
cadence, reporting angle, velocity and hinge state on every sample
(synthetic ease — no Apple-recorded data is shipped), and the SpringBoard
pose override lands the settled state. The legacy `hinge` names still set
the pose instantly.

Live evidence from duotest-m5 (2026-10-24): the virtual hinge service
enumerated in backboardd (service_id reported, `dispatched` counting), and
`display.posture {hinge: "partially-open"}` published 90° with
`provider_running: true`. The foldable product-id patch
(`preboot-exp-devicetree_foldable_product_id`, off in every preset after
this) crash-looped SpringBoard into device-recovery — root-caused the next
day to the secure camera indicator's `CASecureIndicatorLayer` exception
and made survivable by the fold-guard (see the next sections). Escape:
block the patch, re-run `cfw update-environment` (the DT repair reverts
from its clean backup), and reboot; the forced boot-mode is one-shot and
the next healthy boot clears it. CoreMotion's hinge capability on a
single-display guest still needed a narrower route than the device-tree
token — matching Apple, which wires the capability to the second display,
not to the token alone — and that route is the stand-in below.

## SpringBoard fold-guard (2026-10-25)

The crash the product token caused is root-caused and now guarded. With
the Duo token and one panel, SpringBoard aborts during its **first Core
Animation transaction commit**: the Duo branches build a secure status
indicator for the camera, and
`-[CASecureIndicatorLayer _copyRenderLayer:layerFlags:commitFlags:]`
raises `CASecureIndicatorLayerInvalidName` — reason "Invalid indicator
name Camera" — twice per boot (main-thread NSException → SIGABRT →
launchd's "critical process crashes" device-recovery; measured twice on
duotest-m5, iOS 27.1 24A94425; the reports live in the guest's osanalytics
`DiagnosticReports`, which `logs.crashes` does not scan). The guard is
`libvphonefoldguard.dylib` (`system-springboard-cfw-fold_guard`, foldable
guests only, iOS 27+): SystemHook loads it into SpringBoard only, and it
method-swizzles that one QuartzCore method with an `@try`/`@catch` that
logs (first five exceptions, to
`/var/mobile/Library/Caches/vphone-foldguard.log`) and returns nil so the
commit proceeds without the camera indicator. Measured: a boot that
crash-looped twice before reaches the home screen and stays up — the guard
log shows the install line and exactly the two swallowed exceptions. The
camera status dot is the casualty; a finer fix would register whatever
indicator the Duo branches look up.

With the token now survivable, the screen question was measured directly
(2026-10-25): under the full Duo identity (product token + guard), a
`display.posture {"position":"book","duration":3}` sweep publishes 100°
with the provider running — and the screen does not change. Screenshots
before and after the sweep are the same full-bleed layout: no letterbox,
no band, no split, no seam; the files differ only by JPEG noise
(clock/battery pixels). This matches Apple's own model — the simulator's
device type satisfies SpringBoard's fold gates with **two registered
displays**, and the guest's fold layout belongs to display topology, not
to the product token. So on a single-display vphone guest the token gives
identity and sensor data but never pixels; the visual fold waits on a
second display region in the device tree. The equivalent of Apple's
three-state simulator chrome for our guest is the fold control in our own
viewer, in two halves that landed 2026-10-25:

- The **Motion Sensors › Fold Posture** panel
  (`UI/UserInterface/Panels/Fold/`, capability `device_pose`) — a segmented
  Closed / Book / Open picker with a sweep duration, sending
  `display.posture`'s `position` and showing the reply's angle, hinge state
  and provider status, with the single-display limitation stated in the
  panel itself.
- The **window's own fold chrome** (`VPhoneDisplayContainerView`): a
  successful posture publishes the settled angle on
  `VPhoneGuestControl.foldAngle`, and the display container renders the
  spine swallowing the screen. The guest's pixels are never scaled (a
  host-side squeeze read as a squashed wallpaper, not a fold — measured,
  then dropped); instead an opaque spine band grows from the center by
  exactly the fraction a hinge at θ hides from the viewer,
  1 − cos((180−θ)/2), animated over the guest's own sweep duration. 180°
  leaves the panel untouched, ~100° covers the middle ~23% with the two
  halves at native scale, 0° closes the band over everything. This is the
  host-side visualization Apple's simulator window gives; the guest's
  pixels are unchanged, and touches keep mapping through the band to the
  untouched panel underneath.
- **The real panel follows at the next start** (2026-10-25, measured): the
  host refuses runtime display resizing on this stack —
  `VZGraphicsDisplay.reconfigure` answers VZErrorDomain 2
  ("显示器此时不支持重新配置") windowed and headless, and the view-driven
  path (`automaticallyReconfiguresDisplay` + panel/view resize) is inert;
  NSWindow has no public live-resize trigger to drive it either. But the
  boot-time size is fully real: the window process persists the fold's
  position beside config.plist (`display-posture.plist`, written on a
  successful posture), and `VPhoneBootCommand.resolveOptions()` sizes the
  display from it on a Duo — closed keeps the outer panel (1398×2034, the
  machine's own), open and book relaunch on the inner one (2034×2853,
  `VPhoneGuestDevice.iPhone19_4InnerScreen`). Measured both ways: with the
  file saying `open` the guest screenshot is 2034×2853 (SpringBoard laid
  out for the inner panel); without it, 1398×2034. One posture change
  costs a restart — that is the price of a real screen-size change on
  this host, until a dual-display topology lands.

### The validation, reversed (2026-10-25, foldguard v2)

The raise was taken apart in the guest's own lowered cache (duotest-m5
stopped, Disk.img attached read-only, the X1 cache at
`System/Cryptexes/OS/System/Library/Caches/com.apple.dyld`). Reveal
procedure: the ips's `imageOffset` for the raising frame is an offset from
the image's TEXT base, and the base comes from the cache header's
image-text table (this cache: entries at header+0x2cb68, stride 32 —
uuid[16], textAddress, textSize, pathOffset — a layout the 40-byte
`dyld_cache_image_text_info` guess does not match; QuartzCore's TEXT is at
0x18434a000, so the raise sits at 0x1844ce3e0 = `_copyRenderLayer` at
0x1844ce298 + the reported +328). Read from there:

- `_copyRenderLayer` reads the layer's `privacyIndicatorType`, passes it to
  a validator at QuartzCore+0x185168, and raises
  `CASecureIndicatorLayerInvalidName` only when the validator answers −1.
  The exception name and format live in a CFSTR block reached through the
  0x1e9212000 data region, which is why no ADRP in the text subcaches
  references the raw cstrings.
- The validator first consults a runtime-registered collection (a global at
  0x1e8f2a000+0x1c8) and only falls back to a static known-list when that
  is nil — iOS 27's msgSend goes through per-selector trampolines in
  `libobjcMsgSend.dylib`, so the two calls in the fast path are selectors,
  not C functions.
- The class's own surface names the real check: `validPositions` and
  `validPositionsForDisplay:` (plus the `validDynamicPositions` variants).
  Verified live on macOS 27.0.1 against the same class: the
  `privacyIndicatorType` setter accepts any string, and the positions
  methods answer **rect arrays the window server registered per display** —
  on this Mac `Camera` and `Microphone` answer two slots (~21.35 × 31.3 pt)
  and `FaceID`, `ScreenRecording` and everything else answer none. A type
  with zero registered slots is exactly an "invalid indicator name".
- The static name table sits in the same cstring block as the raise
  strings: `Microphone`, `MicrophoneAccessibility`, `Camera` — **"Camera"
  is statically valid**. The rejection can only come from the runtime
  registry path. The server-side counterpart (`CAWindowServerDisplay`, 297
  methods in backboardd) carries `supportsSecureIndicators`,
  `setSecureIndicatorsEnabled:`, `setPrivacyIndicatorSurface:atPosition:`
  and `flushSecureIndicators:` — the registration surface a real Duo panel
  exercises; the registry pointer the validator reads has no writer in
  QuartzCore's text (it is initialized at load), so it is populated from
  the window server, not by client code.

Two live experiments on the guest (foldguard v2/v2.1, then reverted)
closed the case:

- **The position selectors are never consulted.** Hooking
  `validPositions`/`validPositionsForDisplay:` with a synthesized-slot
  fallback logged nothing — the validator does not ask the layer.
- **The runtime registry is empty, not name-specific.** Swizzling
  `privacyIndicatorType` showed SpringBoard asks with real names, and
  aliasing `Camera` → `Microphone` (both statically valid) still raised —
  as "Invalid indicator name Microphone". Every name is invalid because
  the virtual display registered no secure-indicator slots at all; the
  class dump (iOS adds only `remainingTimeAsSteadyForDisplay:` /
  `remainingTimeToSteadyForDisplay:` to the macOS surface) confirms there
  is no client-side registration API to call.

So the finer fix is server-side — backboardd must register indicator
slots for the virtual display, the same missing display-topology family
as the fold layout — and foldguard stays at the lean catch: install, log
the two swallowed exceptions, answer nil. The camera indicator is the
known casualty, now with the complete explanation of why no client-side
repair can bring it back.

## The CoreDevice capability chain, answered by a stand-in (2026-10-25)

Reversing the shipped pieces named the whole route DeviceHub's hinge angle
takes, and where a single-display guest can enter it:

- The host asks through CoreDevice's `DeviceMotionManager`
  (`supportsHingeAngle`, `monitorHingeAngle(config:)` →
  `AsyncThrowingStream<[DeviceHingeAngleSnapshot]>`), the capability family
  `MonitorMotion` (queues `com.apple.dt.coredevice.HingeAngleQueue` etc.).
- The device side is the DDI's `dtdeviceinfod`: its `HingeAngleManager` /
  `DeviceMotionStateManager` / `SpatialOrientationManager` wrap CoreMotion's
  `CMAngleManager` through a bridge class defined in the daemon
  (`CMAngleManager_Bridge`: `+isAvailable`, `+minAngleDegrees`,
  `+maxAngleDegrees`, `-angleUpdateInterval`, `-isAngleActive`,
  `startAngleUpdatesToQueue:handler:`, `stopAngleUpdates`), resolving the
  class with `NSClassFromString`. `+isAvailable` is the gate, and CoreMotion
  answers it from the product-id capability bits — the same bits the
  foldable token would set, and the token cannot be written on a
  single-display guest (see above).
- Verified against macOS 27.0.1's CoreMotion: `CMAngleManager`'s full
  interface is `+isAvailable`, `+minAngleDegrees`, `+maxAngleDegrees`,
  `-angleUpdateInterval`, `-isAngleActive`, `-setAngleUpdateInterval:`,
  `-setAngleHandler:interval:`, `-startAngleUpdatesToQueue:handler:`,
  `-stopAngleUpdates`.

Opening the gate alone (v4) crash-looped dtdeviceinfod eight times over one
DeviceHub connect: with `+isAvailable` answering YES, the bridge started the
REAL manager, whose MotionThread asserts when its own product-id capability
bits contradict the answer (`dtdeviceinfod` SIGABRT on
`com.apple.CoreMotion.MotionThread`, 2026-10-25-000506…000600). So
`libdevicehubfix` (v5, `VPCMAngleManager.m` in `DeviceHubFix/`) now takes over
the manager's whole ObjC surface in dtdeviceinfod: `isAvailable` follows the
provider's liveness (the same test vphoned's readback uses, re-checked every
call, falling back to Apple's answer when the provider is down), the angle
range answers the virtual hinge's 0–180, and the update methods never touch
CoreMotion — they deliver samples read from the provider's newest published
sample (`VPhoneHingeLatest`, written beside every HID dispatch in
`com.apple.backboardd/mobile` without a per-tick disk sync), wrapped in a
runtime-registered object exposing the fields the bridge maps into
`DeviceHingeAngleSnapshot` (`angleDegrees`, `mechanicalAngleDegrees`,
`velocityDegreesPerSeconds`, both spellings of the validity flags, `state`,
`eventPhase`, `timestamp`). `CMAngleData` does not register as an ObjC class
on iOS 27.1 (measured; the sample object subclasses NSObject), and the
bridge's queue argument is an **NSOperationQueue**, not a dispatch queue —
v5's first build called `dispatch_async` on it and died inside libdispatch's
vtable dispatch with `EXC_ARM_PAC_FAIL` (dtdeviceinfod-2026-10-25-002844…,
nine crashes); the delivery now branches on the queue's kind. The provider
liveness test behind `isAvailable` has two traps, both measured: the status
heartbeat only runs while samples flow, so freshness cannot be part of the
test, and dtdeviceinfod (mobile) cannot signal backboardd (root), so
`kill(pid, 0)` answers EPERM for a live process — EPERM counts as alive
(v6; with the plain `== 0` test the capability answered
`hingeAngle: false` on every DeviceHub poll). After v6, a full DeviceHub
connect left no new crash reports and `QueryMotionCapabilities` answered
`hingeAngle: true` on every poll (59/59 over a minute), with
`xcrun devicectl device info details` also clean.

Two things this chain deliberately does not do:

- **No fold picker, and no device hinge UI at all.** The three-state fold
  control in the DeviceHub window is the *simulator* viewer's chrome (the
  device in the user's screenshot was "iPhone Duo — Simulator"), driven
  host-side through CoreSimulator. Checked directly in Xcode 27's shipped
  binaries: **DeviceKit — the UI framework DeviceHub renders from — contains
  zero hinge/fold strings**; CoreDevice carries only the API and one error
  message ("Hinge angle monitoring is not available on this device.");
  CoreDeviceUtilities carries the wire types
  (`StreamHingeAngleActionDeclaration`, `DeviceHingeAngleSnapshot`,
  `com.apple.coredevice.action.streamhingeangle`). So no connected device —
  real or virtual — gets a hinge readout or fold control in that window; the
  stream is for API clients (`DeviceMotionManager.monitorHingeAngle`, whose
  symbols live in CoreDevice). Note that on Apple's own Duo simulator the
  three states change the *simulator window's* fold chrome, not the guest
  screen's content — the equivalent for a vphone guest is fold chrome in our
  own viewer driven by `display.posture`.
- **No on-screen fold layout.** `display.posture`'s SpringBoardServices pose
  override lands, and since the fold-guard the foldable product-id boots —
  but a measured book sweep under the full Duo identity leaves the pixels
  unchanged (same full-bleed layout, no letterbox or split; see the
  fold-guard section): the fold layout belongs to display topology — the
  second panel Apple's simulator registers — not to the token. The hinge
  data (CoreMotion, CoreDevice, any app using CMAngleManager) is what
  works today.

## Why the inner panel boots with the outer panel's layout (2026-10-25)

A machine started with `display-posture.plist {position: open}` boots the
inner panel — framebuffer 2034×2853, `device.screen` 678×951 pt — yet the
home screen lays out a 466×678-pt grid centered on it (measured from pixels:
content band x≈339–1695 px of 2034, ~113-pt side margins), with the wallpaper
and status bar full-bleed. Settings, launched on the same boot, lays out for
the full 678 pt (two-column sidebar, elements to x=658 pt): the display
server serves the real bounds; only SpringBoard's home grid keeps the outer
panel's fit. What was ruled out, in order:

- **MobileGestalt cache staleness.** The cache's `ScreenDimensions`
  (`CacheExtra` key `ybGkijAwLTwevankfVzsDQ`, 16 bytes = two little-endian
  doubles) held 1398×2034 from the boot it was built in. Dropping it
  (`files.remove`) and relaunching SpringBoard changed nothing; restarting
  backboardd changed nothing; a full reboot with the cache deleted rebuilt it
  at 2034×2853 — and the grid stayed small. The cache follows the
  framebuffer; the grid does not follow the cache.
- **The device tree's panel data.** The booted tree (vphone600ap) has no
  width/height anywhere (decoded with a scratch parser over the im4p; display
  props are syscfg-backed strings, `syscfg/gsmi` etc.). The real V68 tree
  carries the display pipeline as hardware nodes — `arm-io/dcp` and
  `arm-io/dcpext0`, one DCP per panel, plus per-panel i2c display-eeproms —
  none of which a paravirt guest can have; its single `gfx` node
  (`compatible "paravirtualizedgraph…"`) carries no panel identity.
- **The device pose.** With the hinge HID reporting 180° continuously
  (preference persisted, provider enumerated, state 3 open-flat),
  `display.posture {position: open}` applied live, apps cycled, screen
  cycled — the grid never widens. This matches the gate reversed earlier:
  `FBDisplayManager.alwaysConnectedIdentities.count >= 2`. One display means
  one identity, and SpringBoard sizes the home grid from the product's
  default fit (the outer panel's) whatever the framebuffer says.
- **Two VZ displays.** A build appending a second
  `VZMacGraphicsDisplayConfiguration` (the posture's panel first, the other
  panel second) boots and behaves exactly like one display — and with the
  flat IOService probe added for this (`device.displays`) the reason is
  measured, not inferred: `AppleParavirtGPU` still reports
  `DisplayPortCount = 1` and exactly one `AppleParavirtDisplay` exists
  (2034×2853, `primary = 0`) with two host displays configured, the same as
  with one. The iOS guest's paravirt GPU personality binds only the first
  connector, so the route is closed; the change was reverted.

One anomaly is on record: a single live run (2026-10-25, single display,
before the pose-restore ladder existed) did flip the home screen to a light
full-width layout after a screen-off → `display.posture {open, 1 s sweep}`
→ unlock sequence; repeated attempts under the same and under dual-display
builds, before and after app cycles, never reproduced it. Treat it as an
SB display-mode-transition artifact of the VM sub-type restore path, not a
working mechanism.

**What ships from this round.** vphoned now re-applies the saved posture
after each boot (`GuestFoldPose`: the pose override is volatile per
SpringBoard instance, and the VM sub-type's own `SBFDevicePoseLastKnown*`
restore never fires on a single display). The boot-time panel choice and the
pose therefore stay in agreement across reboots for everything that does
follow the pose — hinge data, CoreMotion, CoreDevice, pose-dependent UI.

**The remaining lever for the grid** is the one the fold-guard section
already points at: a second always-connected display *identity*. The V68
donor tree names the hardware that carries it (`dcp`/`dcpext0`); with the
host route closed, the identity has to come from inside the guest — a
backboardd-injected second display identity over the one framebuffer (the
`libvphonehinge` pattern, applied to the display set), or an interpose in
SpringBoard answering the gate itself (`FBDisplayManager
alwaysConnectedIdentities`). Both start from the same forensics: locate the
display-set builder and the identity type in the guest's dyld shared cache
(backboardd / FrontBoard), then decide whether a phantom identity renders
onto the primary scene or needs a mirror. The identity-faking experiment
carries the same crash-loop risk the foldable product-id patch had; keep the
forced-boot escape documented there in reach.

### Display-identity forensics, staged (2026-10-25, second round)

The guest's shared cache is readable while it runs, at
`/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e_x1*`
(81 files, ~11 GB; the small `x1` header carries the image-text table at
header+0x2cb68, stride 32 — `uuid[16], textAddress u64, textSize u32,
pathOffset u32`; each subcache's own header names its address range).
Pulled to `/tmp/duo-forensics/dsc/`: `.09` (FrontBoardServices 0x1a7a24000),
`.15` (SpringBoardFoundation 0x1bae8c000), `.16`, `.17` (FrontBoard
0x1c4522000), `.36` (SpringBoard 0x223155000, SpringBoardDisplay
0x223fe0000, SpringBoardUI 0x222769000), `.77` linkedit (671 MB of symbol
strings). Unpulled but mapped: BackBoardServices → `.03`,
SpringBoardDisplayServices (0x2aa519000) → `.67`.

What the strings name so far:

- The identity type is `FBSDisplayIdentity` (FrontBoardServices; its one
  `alwaysConnected` string sits beside `FBSDisplayIdentity.m` at x1.09
  offset 0x76cef87) and `FBDisplayManager` is the hub ("do not set the
  display type to main, use mainConfiguration on FBDisplayManager"). The
  gate the pose reversal named — always-connected identities count ≥ 2 — is
  a property of these, not of SpringBoard.
- iOS 27 ships `SpringBoardDisplay.framework` and
  `SpringBoardDisplayServices.framework` — a whole display-layout framework
  family to read before choosing an interpose point.
- "Cover-display cover-size reduction skipped (not a genuine cover device):
  sizeMatchesCover / bounds / expected / hasMultipleAlwaysConnectedDisplays"
  exists at x1.36 offset 0x3a794f7 — but it belongs to
  PhotosIntelligenceCore (Photos' own foldable layout), so it names the
  pattern, not SpringBoard's gate.

The next steps, in order: class-dump `FBDisplayManager` and
`FBSDisplayIdentity` from x1.09's ObjC metadata (class symbols live in the
x1.77 linkedit at offsets 0x50c7a8e/0x50c7a4a; Swift `$s` names are not
string-visible there, so method lists come from the metadata, not the
symbol table); xref the consumer in SpringBoardFoundation/SpringBoard via
the dyldreadonly CFSTR chain the fold-guard work used; then decide the
interpose — the cheap first try is answering the count gate with the one
real identity duplicated, which satisfies `.count >= 2` without inventing
an object, and observing whether the grid starts following the pose.

### The gate's surface, confirmed on the host (2026-10-25, third round)

The host ships the same display-identity stack, so the surface is readable
without touching the guest — verified live on this Mac (FrontBoard +
FrontBoardServices dlopen, runtime introspection):

- `+[FBDisplayManager alwaysConnectedIdentities]` — a **class method**,
  returning `@[FBSDisplayIdentity "Main"]` on a single-display system
  (alwaysConnected=1, main=1, virtualized=0), count 1 — the guest's
  situation exactly.
- `FBSDisplayIdentity` implements `copyWithZone:` (a copy answers ` isEqual:`
  as the original, description "Main"), `isAlwaysConnected`,
  `isMainDisplay`, `isVirtualized`, `displayID`, `type`, and the private
  `_initWithType:UIKitMainLike:displayID:connectionType:connectionSeed:pid:
external:uniqueIdentifier:secure:alwaysConnected:root:`.
- `FBSDisplayMonitor` (`_initWithDisplays:mainDisplay:bookendObserver:
transformer:`, `_lock_alwaysConnectedConfigurations`) is the client-side
holder; identities arrive from backboardd by XPC
(`initWithXPCDictionary:`).

So the cheap interpose is fully specified: in a SpringBoard-injected dylib
(the fold-guard pattern), swizzle the **metaclass** method
`+[FBDisplayManager alwaysConnectedIdentities]`; when the original answers
exactly one identity, answer `@[original, [original copy]]`. Every count
gate passes; no object is invented; the duplicate shares its displayID, so
identity-keyed consumers may dedupe it — whether the home grid then follows
the pose is precisely what the experiment observes. The delivery wiring
(inject-dylib into SpringBoard, a declared patch set) and the crash-risk
escape stay as the fold-guard documented them.

### The interpose is built; delivery is the open end (2026-10-25, fourth round)

`libvphonefolddisplay.dylib` is written, built, declared and staged:
`VPhoneGuestComponents/FoldDisplay/` (Makefile + StageBundle wired, patch
`system-springboard-cfw-fold_display` in `FirmwareGuestSystemPatchSet`,
SystemHook loads it beside the fold-guard). It swizzles the metaclass
method `+[FBDisplayManager alwaysConnectedIdentities]` and pads a
single-identity answer with a copy of the real one, logging to
`/var/mobile/Library/Caches/vphone-folddisplay.log`.

Delivery is blocked in the selection plumbing, measured: `fw set-patches
--allow system-springboard-cfw-fold_display` records it, but
`cfw update-environment` keeps answering "on in the current selection,
newer than this VM's patch plan" —
`FirmwareGuestPatchResolution.effectiveEnabled(planEnabled:selectionEnabled:)`
intersects with the plan the machine was created with, so a patch the plan
never had cannot be turned on in place, and the plan never gains it (three
consecutive updates printed the same message; the dylib never reached
/usr/lib, which the sealed system volume makes runtime-unwritable —
files.write to /usr/lib fails at mktemp). Next step is in the installer,
not the guest: make update-environment add selection-new patches to the
plan before computing the deploy set (VPhoneCustomFirmwareInstaller.swift
around the `effectiveEnabled` call), or rebuild the plan for the machine;
then boot and read the log — "pad installed" is the success line, and the
observation target is the home grid following `display.posture` for the
first time.

**First light, and the next hook (2026-10-25, fifth round).** The delivery
blocker dissolved: the guest-library install table in
`VPhoneCustomFirmwareInstaller` was hard-coded, and adding
`libvphonefolddisplay.dylib` to it (foldable-gated, beside the hinge and
the guard) made `cfw update-environment` install it — the "newer than this
VM's patch plan" line is informational, not the gate. The dylib loaded and
logged **"pad installed over +alwaysConnectedIdentities"** on boot. But
that is the log's only line, through posture changes and an unlock: the
class method `+[FBDisplayManager alwaysConnectedIdentities]` is never
called at runtime. SpringBoard reads its display set through
`FBSDisplayMonitor` (the XPC-fed client the same reversal named), so the
next hook is `-[FBSDisplayMonitor _initWithDisplays:mainDisplay:
bookendObserver:transformer:]`: append a copy of an always-connected
identity to the displays array it receives. The whole pipeline —
component, staging, declaration, allow, update-environment — is now proven
end to end; the iteration is one swizzle away.

**Second hook installed, same shape of answer (2026-10-25, sixth round).**
The monitor swizzle is in and logs its install line, but
`_initWithDisplays:mainDisplay:bookendObserver:transformer:` is also never
called — SpringBoard builds its monitor through the other initializer
(`_initWithBookendObserver:transformer:`; displays then arrive over XPC
into the bookend observer). The next candidates, in order of centrality:
`_lock_alwaysConnectedConfigurations` (the configurations getter the count
logic must read) and `_lock_enumerateConnectedWithBlock:`. All three
selector names are already in the host dump; the deployment pipeline is
warm — one swizzle per round.

### The configuration is right; the role is the question (2026-10-25, seventh round)

Hooks on `+[FBDisplayManager mainConfiguration]` and `+mainIdentity`
(running inside SpringBoard, logged per call) answered the open question
from the bottom up:

- `+mainConfiguration` **is called** — once per SpringBoard launch — and
  its answer is **perfect**: `FBSDisplayConfiguration "Main"`,
  `bounds {678, 951}`, mode `678x951@3x (2034x2853/3) 120Hz`,
  `renderingCenter {1017, 1426.5}`, pixelDensity 460,
  `CADisplay.deviceName = primary`. The display-configuration plumbing is
  correct end to end; SpringBoard lays the 466-point grid on top of a
  correct 678-point configuration.
- `+mainIdentity` and every identity/count accessor (`+alwaysConnected`,
  `-[FBSDisplayMonitor alwaysConnectedIdentities]`,
  `_lock_alwaysConnectedConfigurations`,
  `_initWithDisplays:…`) are **never called** in SpringBoard at runtime —
  the two-display gate as reversed statically is not exercised on this
  guest; the fold machinery never starts far enough to ask.
- Also eliminated with probes this round: `/chosen` carries no display
  geometry (only rotation/corner-radius/scale=3; the vphoned display
  probe now dumps it), `com.apple.backboardd.plist` holds no display
  configuration, and `IconState.plist` records no grid geometry.

The remaining suspect is the display's **role classification**:
`CADisplay.deviceName = primary`, and on a foldable the boot-primary
display is the cover panel — which is exactly the 466-point layout being
drawn. `renderingCenter` non-zero also marks a display whose rendering
surface is bigger than its bounds (the foldable frame). Where that
classification lives is server-side: backboardd
(`/usr/libexec/backboardd`, not in the shared cache, not present on the
host for introspection) builds the display set from IOKit and pushes it
to clients. The next workstream is the libvphonehinge pattern aimed at
backboardd: hook its display-set construction and answer two displays —
or reclassify the one — so the pushed set carries a main display, not a
cover-primary. Deployment note recorded the hard way:
`cfw update-environment` runs the **machine's current binding** — always
check the reply's `bundle` field, or an update silently deploys the
previous bundle.

### The backboardd surface, mapped (2026-10-25, eighth round)

`/usr/libexec/backboardd` pulled from the guest (800 KB, arm64e.x1, not in
the shared cache; macOS ships none of this for host introspection) and its
strings named the display management core:

- `_BKDisplayXXGetSystemIdentifiers` / `_BKDisplayXXSetSystemIdentifiers`
  (and `BKDisplayGetSystemIdentifiers`/`Set…`) — the system display
  identifier set, the thing a second panel would join.
- `displayWithHardwareIdentifier:`,
  `windowServerDisplayForDisplayIdentifier:`, `_lock_evaluateAllDisplaysForReason:`
  — the enumeration and evaluation entry points.
- `BKDisplayCloneMirroringManager` and
  `BKSDisplayServicesSetCloneMirroringModeForSourceDisplayToDest` (in
  BackBoardServices, guest x1.03) — Apple's own display-mirroring path, a
  documented fallback if a padded second display ever needs a surface.

The plan for the next session is therefore fully specified: inject into
backboardd the way `libvphonehinge` does (SystemHook already loads per
process), find the class owning `_lock_evaluateAllDisplaysForReason:` via
the ObjC metadata in the pulled binary, and pad the evaluated display set
with a second entry — or reclassify the one — so the pushed set carries a
main display instead of a cover-primary. Then the boot question (does the
grid go wide) and the runtime question (does a re-evaluate on hinge change
switch layouts live) both have one lever to answer them.

### Recovering from the broad runtime probe (2026-10-25, ninth round)

`2.12.1-local.8a55d450` repeatedly left the VM running without a usable
vphoned connection. USB syslog and its process list remained available:
the proxy and worker, SpringBoard, and backboardd were alive; copying
vphoned crash reports with `--keep` retrieved none. Failed boots stopped
logging after `vp_vcam_start`, before the HTTP/WebSocket listening line.
The Data/User volumes were encrypted and locked when attached read-only,
so offline access did not recover their logs; the attachment was ejected.

Disabling only the backboardd half in the next source build, installing
`2.12.1-local.ad5f3ecd`, checking its machine binding, and running
`cfw update-environment` restored vphoned in **5 seconds**. Its screen RPC
reports 678×951 at scale 3, unlocked and on; the screenshot still shows the
narrow four-column grid. This is recovery, not either layout goal.

The recovered append-only probe log contains
`evaluator owner: BKDisplayCloneMirroringManager` and the evaluator hook
installation line, but **no completed `round N:` line**. Thus the owner
was found, contrary to the earlier handoff; it is the clone-mirroring
manager, not evidence of a display-topology producer. The broad scan or
hook is implicated by the isolation result; its exact blocking operation
has not been established with a thread stack. Guest timestamps move back
at boot until host synchronization, so compare log order and boot markers,
not timestamp monotonicity.

The replacement diagnostic is restricted to that named class, delayed ten
seconds onto the main queue, logging only its declared selectors and type
encodings. It does not scan every class or replace evaluator methods.

**Validated replacement:** `2.12.1-local.42c33f10` also answers vphoned
after 5 seconds. The delayed probe logs **23 methods** and `complete`.
The live evaluator signatures are `v24@0:8@16` (all displays) and
`v32@0:8@16@24` (one display). Its other methods include
`_lock_evaluateCarPlayDisplay:label:`,
`_lock_evaluateContinuityDisplay:label:`,
`_lock_setupCloningToDestination:fromSourceDisplayUUID:fromVirtualMode:hideByDefault:`,
`_lock_evaluateExistingClonesForReason:`, and
`addModeRequest:forSourceDisplay:toDestinationDisplay:clientPID:`.
This interface points to clone mirroring; it does not establish a provider
of the home screen's foldable layout. Do not pad its arguments as if they
were the display-identity collection.

The next narrower candidate is
`-[SBMainDisplayConfigurationTransformer transformDisplayConfiguration:]`,
whose class/method diagnostic strings occur in the guest's x1.36 cache
alongside SpringBoard display code. This is a **static candidate only**:
its runtime invocation, signature and input/output remain unmeasured.
SpringBoardHome lives at unslid `0x1c45c1000` in this image inventory; its
layout selection also remains to be traced. Neither candidate justifies
overriding a geometry or role yet.

### Screen-type lookup evidence (2026-10-25, tenth round, runtime pending)

The current guest's SpringBoardHome symbol table identifies
`SBHScreenTypeForDeviceAndDisplayContexts` at `0x1c45c8b1c`,
`SBHScreenTypeForScreen` at `0x1c45d537c`, and
`SBHScreenTypeForCurrentDevice` at `0x1c465d930`. The latter is cached with
dispatch_once; the per-screen function also reads/writes an associated
object cache. Both lead to `_SBHScreenTypeLookupCommon` / `_SBHScreenTypeLookup`.
These addresses are analysis evidence for this build, not runtime patch
offsets.

Decoding the symbol-backed screen-name tables gives 31 = D76 and 32 = D77.
The metric switch's D76 case calls a size SPI; its D77 case loads two doubles
from the platform screen-size table: **669×951**, not the guest's **678×951**.
The adjacent pair is **466×678**. Thus exact-size matching deserves testing
before assuming the backboardd primary role is the cause. This does not yet
prove which enum the running SpringBoard selects, nor justify silently
changing the requested 678-point canvas to 669 points.

The source now has a guarded, observational configuration-transform hook
and a delayed probe for current/per-screen enum values and
SBIconListGridLayoutConfiguration method signatures. The transform-only
build passed, but its install remains pending at Launchpad's administrator
stage; the subsequent enum-probe source has not yet been built or deployed.
The guest remains on the verified `2.12.1-local.42c33f10`. Continue the
existing install operation instead of launching another installation.

**Runtime result:** after authorization completed, the combined probe build
`2.12.1-local.dec1671c` was installed, bound and deployed successfully;
vphoned answered after 5 seconds. The configuration transformer is called
and returns a set containing the same **678×951** configuration. Crucially,
both `SBHScreenTypeForCurrentDevice()` and `SBHScreenTypeForScreen(mainScreen)`
return **23, iPhone 14 Pro Max (D74)**. They do not return D76. The old
cover-role explanation is therefore not an established explanation for the
grid; the measured phone fallback is the next target. The grid configuration
class has `screenType` / `setScreenType:` and portrait/landscape list-size
and layout-inset setters. Inspect the layout providers before deciding
where to substitute the inner layout family, so a late enum override does
not leave all its derived metrics configured for D74.

**Provider experiment:** `63a6dba0` established the typed initializer
`-[SBHDefaultIconListLayoutProvider initWithScreenType:layoutOptions:]`
(`@32@0:8Q16Q24`) and `+currentDeviceScreenType` (`Q16@0:8`). In
`9ed488e5`, mapping D74 to the symbol-resolved D77 value at those entries
booted successfully and logged 12 substitutions. The following native
construction created 18 D76 and 9 D77 providers. The screenshot changed
icon/dock metrics but remained narrow, so the first substitution is not
accepted as inner-screen layout. The next isolation also maps explicit
D76 provider construction to D77, while inspecting the icon-manager
layout-update interface for subsequent live switching.

### System-wide acceptance and rejected UI-only approach

The user explicitly requires correct status bar, Dock and rotation in
addition to inner-screen home layout and live inner/cover switching.
Per-application layout fixes are not an acceptable final solution.

`7f5eff72` (mapping both D74 and D76 requests to D77) still produced a
narrow grid. The diagnostic `73dbf17b` read the active root layout:
the folder view is 678×951, its provider is D77, but its native config is
4×6 with portrait insets `{82,145.5,219,145.5}`, list-spacing size
669×951, and dock background insets `{0,134,21,134}`. Thus forcing D77
does not establish a full-width system display state; it introduces its
own status/Dock mismatches and is rejected as the implementation path.
The provider substitutions and experimental inner/cover notification
handlers were removed from source. The machine is being restored to the
non-mutating `63a6dba0` diagnostic baseline.

With the screen awake and rotation unlocked, a 90-degree request was
refused on both SpringBoard and Settings. The virtual accelerometer is
enumerated, its orientation sink reports ready and deliveries, and the
interface still reports 0 degrees. `display.posture` also installs a
test-automation pose override with a default portrait orientation; changing
that override to landscape-right did not produce an interface rotation.
Its interaction with normal rotation is a hypothesis, not a demonstrated
root cause. Do not "fix" this by independently rotating UI components.

The remaining investigation is the shared display boundary: logical display
roles/modes and their propagation into display/scene traits, safe areas and
orientation transitions. One coherent state change must drive home layout,
status bar, Dock and ordinary app scenes. Verify both directions of the
screen switch and portrait/landscape without VM or SpringBoard restart.

### System mode boundary (2026-10-25, live read-only evidence)

The baseline rollback completed and booted in 5 seconds. Build
`b21d1148` adds `display.modes`, a read-only CADisplay query. On the guest:

- primary LCD is displayId 1, displayType 0, native bounds 2034×2853;
- its only advertised mode is 2034×2853 at 120 Hz;
- `allowsVirtualModes` is false, but both `setAllowsVirtualModes:` and
  `setCurrentMode:` exist;
- five wireless display objects have zero bounds and no modes. They are
  not evidence of five usable/always-connected panels.

This is a candidate for changing logical mode inside the guest without
asking VZ to replace its physical framebuffer. It is not proven support.
A built follow-up exposes a bounded `display.mode` experiment: request
dimensions no larger than the native framebuffer, preserve the original
mode, read CADisplay back, and request rollback on a mismatch. Independent
`device.screen`, screenshots, display configuration and process continuity
are required even if its local mode readback matches. The experiment's
install is currently waiting for renewed administrator authorization.

All old identity-padding hooks are now observational pass-throughs in
source, in addition to removing provider substitutions. They must not
invent duplicate identities if the new transition starts exercising a
previously unused accessor.

### Mode switching negative result: no arbitrary IOMFB modes

`ca1e88b5` tried 1398×2034 through `CADisplay.setCurrentMode:`. It raised
"mode ... is not valid for display ...". Explicit restoration succeeded;
independent screen readback remained 678×951, and SpringBoard PID/start
time were unchanged. Static analysis of the **guest** QuartzCore resolved
CADisplay's method metadata correctly (relative list-of-lists, then the
cache's shared selector base). The setter checks `mode._display == self`
and nonzero `mode._mode` before constructing CADisplayProperties.

More importantly, the guest implementations of `allowsVirtualModes` and
`setAllowsVirtualModes:` are deprecated stubs: the getter returns false,
the setter logs and returns. Their diagnostic strings explicitly say
"is deprecated!". Runtime mode enumeration after the attempted enable
still showed false and only the native mode. The mere selector-presence
fields in `display.modes` must not be treated as actual capability.

`27f93d44` then sent the same bounded request through
`CADisplayProperties.currentMode` / `CADisplay.setDisplayProperties:`.
It reached the display service but **crashed backboardd**, not a valid
transition: incident `CADFABE7-D598-47D2-9F09-32FE71FE0D12`,
`backboardd-2026-10-25-225733.ips`, SIGABRT in
`com.apple.coreanimation.display.primary`. The stack is
`Server::set_display_properties` → `IOMFBDisplay::set_mode` →
`IOMFBDisplay::update_framebuffer_locked` → `abort`. backboardd restarted
from PID 61 to 291, while the caller remained waiting on the lost service.
This rules out supplying an arbitrary hardware mode through this route;
do not suppress the abort or claim a no-restart switch.

The waiting requests were closed after collecting the crash, and the VM
was stopped for recovery. The experimental `display.mode` write entry has
been removed from source; only read-only `display.modes` remains. Recovery
build/deployment is in progress. Further work must preserve the native
framebuffer and investigate supported logical-display/scene configuration
or render-server virtual-display facilities, with real bounds and input
mapping acceptance. No per-app geometry workaround was retained.

**Recovery verified:** `862de5d7` is bound and deployed; vphoned answers
after 5 seconds and `display.mode` returns Unknown method. This build keeps
only the read-only mode inventory and observational hooks. The pose ABI was
also checked against the actual SpringBoard receiver: the first 64-bit
field is copied directly into pose state, while the following 32-bit fields
feed the synthetic magic event and hinge-angle lookup. It is not evidence
of an overlooked bitmask argument. Further direction work needs readback of
the actual device-pose provider and its display transition consumers.

### Pose delivery verified; display-content coordinator next

`display.pose` now reads the actual SpringBoard snapshot via
`SBSTestAutomationService.getDevicePose`, whose guest ABI is
`{?=qiii}16@0:8`. The completion-based spelling belongs to the server
protocol and is not a client method. Build `8d497ab4` booted in 5 seconds.
An explicit open/landscape-left request with a 100 ms hinge sweep returned
normal hinge-provider readback; `display.pose` then returned orientation 3,
device_orientation 3, hinge 3, tabletop 0, while `display.orientation`
remained 0. Thus pose delivery is demonstrated, but scene/display
transitions do not follow. The hinge unit tests also passed after restoring
an accidentally truncated source tail; the failed link was never deployed.

Static metadata identifies the shared downstream component
`SBDisplayContentModeCoordinator`, with
`poseProvider:didUpdateFromPose:toPose:`, `primaryWindowScene`,
`activeWindowScene`, `currentTransitionContext`, and
`displayContentModeForWindowScene:`. SpringBoard exposes it through
`displayContentModeCoordinator`. A read-only diagnostic now inspects these
objects on the main queue after boot, or on
`com.vphone.display.inspect`; it does not replace layout values or force a
transition. This observation is intended to locate the shared state break
before choosing any mutation.

### Shared posture fix and software-display lifecycle probe

The coordinator exists. With open-flat and closed poses it reports the same
`SB-main` as primary and active window scene, content mode 2, and no current
transition context. The pose provider's own description changes correctly
between `.openFlat` and `.closed`; this is not merely an RPC echo.

A separate real bug was observed: the boot restore ladder replayed its old
open posture after a successful user close. `GuestFoldPose` now cancels the
ladder before an explicit validated posture request and stops retrying after
the new pose readback confirms restoration. Publication and cancellation
share a lock, so an in-flight retry finishes before the explicit request.
On `d5b17793`, a close issued just after boot still read hinge=1 after
121 seconds, beyond the old 90-second ladder. This fixes state ownership;
it does not by itself fix display layout.

An explicit, non-automatic backboardd experiment uses
`CAWindowServerVirtualDisplay.initWithOptions:` and `CAWindowServer.addDisplay:`.
The guest initializer's recovered keys are `kCAVirtualDisplayWidth`,
`kCAVirtualDisplayHeight`, `kCAVirtualDisplayUpdateRate`, and
`kCAVirtualDisplayName`. It registered displayId 7, type 3, name
`VPhone Cover Probe`, 1398×2034@60, while primary remained 2034×2853 and
backboardd PID/start time were unchanged. SpringBoard still kept only
SB-main/mode 2. Thus software rendering topology can be added without
changing the hardware mode, but its FrontBoard/Duo role is not established.

The explicit remove call returned and cleared the retained probe reference,
but the daemon's CADisplay list still showed id 7. Removal is not yet claimed
verified: CADisplay caches its inventory. The next probe calls
`CADisplay.updateDisplays` (verified in guest code to invalidate its cache),
logs the render server's own display inventory after add/remove, and reads
the existing FBDisplayManager monitor's connected/always-connected identities.
These are diagnostic reads, not evidence that normal SpringBoard consumers
previously called those getters. Never duplicate identities to fake this
missing connection.

**Inventory boundary verified on `6004bbe4`:** adding the probe puts id 7 in
both the render server's `displays` and refreshed CADisplay inventory. The
existing SpringBoard FBDisplayManager monitor still reports exactly
`connectedIdentities = {Main}` and `alwaysConnectedIdentities = {Main}`;
the active scene remains SB-main/mode 2. Thus the missing integration is
between render-display registration and the system display-identity/scene
publication path. A second CA display alone does not make a Duo panel.

Removal is now verified without a VM/backboardd restart: the render server
inventory loses the named probe, and a cache-refreshed CADisplay query
returns ids 1–6 only. The previous id-7 readback after removal was stale
client inventory. The experiment is left removed, with native primary
geometry unchanged. Follow the central BackBoard/FrontBoard identity
publication boundary, not a fabricated duplicate Main identity.

### Identity publication predicates (2026-10-26)

The BackBoard `GetSystemIdentifiers` path resolves a particular render
display and reads that object's `systemIdentifiers`; it is not a global
list of panels. Runtime sampling found one UUID on the primary display and
nil on the software display. No identifier value was written or duplicated.

`FBSDisplayMonitor.allowsUnknownDisplays` was already true. Enabling it
again made no difference. `system.respring` is unsuitable for isolating
initialization: its implementation explicitly includes the restart-render-
server option. A subsequent `services.kickstart` of only SpringBoard did
preserve backboardd PID/start time and id 7. The newly initialized monitor
then contained source `7-7`, but it was **disconnected**; connected and
always-connected identity sets still contained only Main.

The software display was initially `enabled=0` despite valid size/mode and
`isSupported=true`. Explicit `setEnabled:YES` read back 1 without restarting
backboardd; it still did not connect the FBS source. Main has pointScale 3,
the software display pointScale 1; neither scale nor hardware mode was
changed by this probe.

Guest FBS source-update code now explains a concrete predicate: except for
always-connected sources, a zero CADisplay tag or empty mode list clears the
raw configuration. The software source has tag 0. Guest
`NSStringFromBKSDisplayTags` identifies bit 16 as `unknown`; the other
documented bits are hidden, debounce, AirPlay, musicOnly, car,
carInstruments and continuity. The next experiment resolves the unknown bit
through that guest function and tags only the owned software display, then
observes real FBS identity creation. It does not declare a second Main or
change the physical display type. Connection/role acceptance is pending.

**Tag connection verified on `86558897`:** after a software display source
had been enumerated, applying the guest-described unknown tag (65536)
caused its FBS raw configuration to be constructed and passed through the
normal transformer. A later asynchronous read showed connected identities
`{Main, Unknown[7-1]}` with the same SpringBoard PID 278/start time across
the tag change. No identity was copied or manually inserted. The new
identity has displayID 7, type 7, connectionType 3, UIKitMainLike=false and
alwaysConnected=false. The always-connected set and active SB scene remain
Main/SB-main. This establishes real connection publication, not Duo role
acceptance.

The enabled-state test was also completed: the virtual display starts
disabled, explicit enable reads back true, and a fresh SpringBoard can
enumerate source 7, but it remains disconnected while tag is zero. This
separates source discovery, enabled rendering, connection tagging and
built-in-panel role classification.

Destroying a connected tagged display removed it from the render server
but left the FBS identity cached. The test was cleaned by a SpringBoard-only
kickstart after removal; final reads confirm connected/always-connected
sets contain Main only, pose remains closed, and backboardd PID 61 is alive.
Future transient cleanup must publish tag=0 and verify disconnection before
destroying the render object. Permanent emulated panels should keep stable
objects/identities across screen selection instead of being created and
destroyed for each fold.

### One-shot built-in software-panel adapter (2026-10-26, acceptance pending)

The next experiment adapts one owned render display at the common metadata
boundary in SpringBoard: only a CADisplay whose native type is virtual (3)
and deviceName is exactly `VPhone Cover Probe` reports built-in type (0) and
pointScale 3 to the native FBS source factory. All other displays pass
through. It preserves the render server's real display ID, modes and
connection seed; no FBS identity is copied or inserted into an array.
The guest classifier's built-in branch supplies UIKit-main-like and
always-connected attributes, which are the measured differences from
Unknown[7-1]. This is an emulated-panel role adapter, not a home-screen grid
or Dock override. Its actual scene behavior is unproven until runtime reads.

Activation is deliberately one-shot: SpringBoard consumes
`/var/mobile/Library/Caches/vphone-duo-internal-panel.once` containing `1`
before installing the metadata hooks. A subsequent SpringBoard instance
without a new marker stays on the baseline, including after a crash. The
test must verify two native always-connected identities, correct logical
sizes, resulting window scenes, and real fold/rotation behavior. The
physical framebuffer/mode remains untouched.

**Observed result:** the one-shot adapter produced
`Unknown.main[7]`, 466×678 at 3x, and native always-connected count 2.
SpringBoard then trapped in
`ManagedDisplaysController.scene(_:didUpdateIsCloningSource:)` while
activating a managed display profile (incident report
`SpringBoard-2026-10-26-005058.ips`). The next instance had no one-shot
marker and returned to ordinary Unknown[7-1]/count 1. The probe display was
removed and SpringBoard-only cleanup restored the baseline. Count 2 alone
is therefore insufficient: an Unknown render display is not a complete
Duo main/cover role, and the assertion must not be suppressed.

### Native root-derived logical configuration (2026-10-26, preview pending)

Guest `FBSDisplayConfigurationBuilder.buildWithError:` has an explicit
identity-derivation branch: setting uniqueIdentifier creates a new identity
with the original identity (or its existing root) as parent, preserving
display ID, connection metadata and root semantics. This is distinct from
duplicating Main or changing an unrelated virtual render display to Main.
The transform protocol returns a set, so one native source can publish
distinct effective logical configurations.

The next experiment previews a copy of the real Main configuration with
cover bounds 466×678 and a stable uniqueIdentifier `vphone-duo-cover`, built
by that native builder. It validates the resulting parent/unique ID before
any publication. A default-off in-process switch can then request
`FBSDisplayMonitor.updateTransformsWithCompletion:` to add/remove the
projection through the original source's transform result. The original
physical mode and render display are retained. Preview/scene acceptance is
not yet established. A macOS scratch attempt could not obtain an iOS-style
Main FBS monitor and trapped before reaching the builder; it supplies no
negative evidence about this guest derivation path.

**Observed result (4efbeb4b):** guest preview successfully built
`Main+<vphone-duo-cover>` with root Main, cover bounds 466×678 and unchanged
2034×2853 physical mode. A one-shot startup enabled publication and the
actual `SBMainDisplayConfigurationTransformer` emitted both configurations.
SpringBoard then aborted in
`-[SBFBSDisplayTransformer transformDisplayConfiguration:].cold.1`
(`SpringBoard-2026-10-26-012941.ips`). The outer transformer explicitly checks
that the inner transform set has exactly one member. This rejects the
single-source/two-effective-configurations route before monitor startup;
native identity derivation alone does not establish a Duo panel. The next
instance automatically returned to baseline. The enable notification now
refuses publication and stale one-shot markers are discarded; builder
preview remains read-only.

### Native content policy versus scene surface (2026-10-26)

`83435b6f` was built, installed, bound and deployed on duotest-m5; guest
environment update reported that exact version and vphoned answered after
5 seconds. Read-only inspection of the real coordinator's `_resolver` finds:

- The prevailing policy is already **FoldingDual**, with primary content
  requested on **.inner** while the hinge provider reports openFlat/180°.
- Its only display proxy is **legacyMain**, whose surface is **.default**.
  Applied/target mode is `.primaryContent` (enum 2), not an inner-screen role.
- `SBCoverDisplayConfigurationTransformer.activeTransformMode` is 0,
  applied cover insets are zero, and both hardware identifiers are nil.
- The actual SB-main UIScreen is 678×951 at 3x, and its scene already has
  regular horizontal/vertical size classes while retaining Phone idiom.

Thus pose delivery and policy selection work, but the native scene surface
classification does not describe an inner/cover pair. Neither always-
connected count nor mode 2 proves that classification. Next investigation
belongs at the ShellSceneKit display/profile-to-scene boundary, which feeds
the common scene traits; no per-widget layout override was introduced.
The native SBF surface names are default=0, cover=1, inner=2, type3=3;
content mode names are unknown=0, disabled=1, primaryContent=2,
auxiliaryContent=3. These are decoded from this guest's symbol-backed tables.

The shared native source has now been traced further: ShellSceneKit
`FBSHardwareSource.resolveDisplay(hardware:)` reads
`CADisplayHardware.bksDisplayTraits.surfaceType`; the hardware initializer
fetches those traits through `BKSDisplayService.traitsForDisplayUUID:`.
backboardd `_BKDisplayXXGetDisplayTraits` obtains the render display's
`extendedProperties`, reads the CFNumber `DeviceSurfaceType` (defaults to
zero when missing), and builds `BKSDisplayTraits`. This is render-display
metadata, not proof of an IORegistry property. The ShellSceneKit conversion
preserves known surface values 0/1/2.

A new default-off probe intercepts only
`CAWindowServerDisplay.extendedProperties` in backboardd for deviceName
`primary`, adds `DeviceSurfaceType=2` to a copy, and automatically returns
to native metadata after 30 seconds. It preserves the native source ID,
mode, display count and remaining properties. Runtime activation requires
the explicit `com.vphone.display.surface.inner` notification. The next test
recreates only SpringBoard during that window to test native profile/scene
construction; this diagnostic setup is not no-restart fold acceptance.

**Observed result (0932888f):** primary extendedProperties was originally
nil. During the probe, native traits became inner and the existing
`legacyMain` proxy changed to `.inner`, preserving Main identity/count 1.
SpringBoard stayed alive (PID 279), but its resolver remained `Ready To
Resolve: NO` with no primary/active scene even after a fresh open pose.
Static `_startResolvingContentModeOfDisplay:` explains why: for inner it
requires a cover proxy, and for cover it searches for an inner proxy before
resolving a folding device. A default surface, by contrast, becomes ready
immediately. No readiness check was patched. After the 30-second metadata
restore, a SpringBoard-only kickstart restored `.default`, readiness YES
and SB-main. backboardd PID 61 and start time were unchanged throughout.

The next bounded probe supplies both metadata roles: real primary as inner
and the owned CA software display as cover. The software display has a real
UUID (unlike primary's nil uniqueId), so BKS can query it separately. Native
connection types and identity factories remain untouched. This tests whether
correct surface metadata suffices to construct the pair without the prior
wrong built-in adapter. Its default 1x scale and lack of reported cloning
support are known limitations, not accepted cover/rotation behavior.

**Observed result (47b16e3f):** Main native traits read back as surfaceType 2;
the real software source was connected as Unknown[7-1] (connectionType 3,
not UIKit-main-like, not always-connected). It did not create a cover window
scene; the resolver still had only legacyMain/.inner and remained not ready.
No SpringBoard crash was observed during this metadata-only experiment.
After expiry the probe display was removed and a SpringBoard-only kickstart
restored Main-only/default traits, SB-main and readiness. Actual screenshot
`/tmp/duo-pair-restored-home.png` confirms a usable home screen with the old
narrow grid; it is recovery evidence, not inner-layout success.

The proposed follow-up combines the primary surface change and intended cover metadata with the
previous one-shot built-in metadata adapter. Automatic approval review
rejected that specific retest because the adapter previously crashed
SpringBoard and the interruption requires explicit user approval. The
rejected command did not run; readback confirms the one-shot marker is
absent. The guest stays at the recovered baseline while that approval is
pending. No alternative execution route was used.

Additional read-only analysis resolves the previous crash more precisely:
the fault at `ManagedDisplaysController.scene(_:didUpdateIsCloningSource:)`
is its **"Cloning source already exists: "** assertion, in
`ManagedDisplaysController.swift` line 38. It is not an optional-unwrapping
failure. Before that earlier test, both surfaces were unspecified/default.
Correct inner/cover roles may affect primary/auxiliary content selection,
but whether they remove the competing-cloning-source condition is still
unverified. Do not suppress this invariant or report the retest as passed.

### Profile admission predicate and separate trait readback

Read-only disassembly of the current guest's
`SBDDisplayProfileManager.managedProfilesForDisplay(_:)` resolves its first
admission condition: `display.kind == .main || display.connection ==
.integrated`. The enum cases were resolved through the actual import
targets and symbol-backed case descriptors, not inferred from tag numbers.
Unknown software displays fail both branches regardless of surfaceType;
this accounts for the absent cover managed scene in 47b16e3f. The existing
one-shot adapter changes the second condition, but the crash-prone combined
retest remains approval-gated.

A safer independent check is prepared: inspection queries BKS native traits
for the owned software display's actual UUID, as well as primary's nil UUID.
This can verify whether cover metadata reaches the service while leaving
the software display untagged/disconnected and keeping SpringBoard alive.
No panel-type adapter, scene rebuild or framebuffer mutation is needed for
that readback. Main's successful inner readback alone was not proof of a
complete pair.

The first 29bb799e readback did not see the new untagged CADisplay in the
SpringBoard client's cached inventory, although vphoned's explicitly
refreshed inventory confirmed its real UUID. Main traits read back as 2;
the existing default scene remained ready, and SpringBoard PID/start time
were identical before/during/after this independent test. The software
probe was removed. The reader now explicitly invalidates the local
CADisplay inventory before enumerating it, without changing display modes.

Additional static tracing of `FBSDisplayMonitor.updateTransformsWithCompletion:`
shows a per-source `_updatable` check before the transform-invalidation
update path. This provides a concrete distinction to inspect after the
earlier no-op compatibility-monitor refresh. Source observations now also
record public monitor initialization, actual transformer class, per-source
updatable flags and the targeted source methods. It is not yet evidence
that FBDisplayManager's source is non-updatable or that another monitor
has been identified. Core source update functions absent from its runtime
method list must not be assumed to be swizzlable ObjC selectors.

**Observed result (baa0b497):** explicit local CADisplay inventory refresh
lets the independent query reach both BKS records: primary/nil UUID reports
surfaceType 2, and the real software UUID reports surfaceType 1. The probe
display stayed untagged and disabled, no scene was rebuilt, and SpringBoard
PID 37/start time were identical before/after. The probe was removed.
This verifies metadata delivery independently of the still-unmet integrated
scene admission condition. Home's own readback is artwork subtype 0,
BSPlatform deviceClass 0 and homeButtonType 2. No public-monitor init hook
calls were observed; those hooks do not establish the actual monitor owner.

The main-source invalidation gate is now source-derived: native monitor
initialization takes `mainDisplay.isExternal` as the main source's trigger
mask; source initialization sets `_updatable = (triggers != 0)` and
`_observing = (triggers & 1)`. For the measured non-external main panel this
creates an explicit-refresh skip even though the transformer is present.
Additional sources use trigger 1. These are instruction/call-flow findings,
not yet an in-process flag readback.

A separate default-off `com.vphone.display.invalidation.pulse` diagnostic
validates the Main source/BOOL ivar ABI, temporarily enables only its
`_updatable` flag, calls the native monitor refresh, then restores the prior
flag in `@finally`. The original transform result passes through unchanged;
no viewport, panel type, physical mode or identity is replaced. A logged
transform-call delta plus process/scene continuity is required before using
this route to implement any logical bounds change. This is independent of
the still-pending built-in-panel adapter retest approval.

**Observed result (087cc63d):** live source flags are `[0,1,1,1,1,1]`, matching
the static main/external trigger distinction. The reversible pulse reached
the original SBMainDisplayConfigurationTransformer: native completion
reported transform calls **1 → 2**. The flag was restored immediately;
independent inspection again read Main=0. SpringBoard PID/start time and
backboardd PID/start time were identical before/after, and SB-main/678×951
remained unchanged. This explains the earlier completion-without-transform
result and establishes actual runtime delivery without the rejected panel
classification retest.

### Single-root effective viewport (2026-10-26, runtime pending)

The next experiment uses that verified native refresh to replace exactly
one effective Main configuration, preserving the original identity, native
mode and renderer. `copyWithOverrideBounds:` supplies 466×678 cover bounds
(or 678×466 when the raw configuration is landscape); requesting inner
returns the original native 678×951 configuration. No derived identity or
second transform result is added, respecting SBFBSDisplayTransformer's
singleton requirement. Activation is default-off and explicit via
`com.vphone.display.viewport.cover` / `.inner`.

Cover automatically requests native restoration after 45 seconds. A request
generation check prevents an older timer from overwriting a newer user
selection. A new SpringBoard instance also starts with the native transform.
Acceptance requires actual effective configuration, UIScreen/scene bounds,
visible UI, input mapping and process continuity in both directions; a
transform log alone will not establish screen switching or inner layout.

**Observed result (db4f509e):** effective Main publication reached the actual
SpringBoard UIScreen, changing its bounds to **466×678**, while its mode
remained **2034×2853**. Screenshot `/tmp/duo-viewport-cover.png` shows the
old home layout clipped at the smaller rectangle, including clipped widgets
and an absent Dock. This is not a usable outer screen. The timed restoration
returned UIScreen to 678×951; an explicit inner request also completed.
SpringBoard and backboardd PID/start time remained unchanged throughout.
Thus the native runtime configuration path works, but bounds-only copying
is insufficient and must not be called successful screen switching.

Native `FBSDisplayConfiguration.copyWithOverrideMode:` uses its own builder
to update effective mode, pixel size, native bounds and logical bounds
together. `FBSDisplayMode._copyWithOverrideSize:scale:` creates a virtual
frontend descriptor; it does not call CADisplay.setCurrentMode or
setDisplayProperties. The next revision follows these native copy helpers
for a coherent 466×678@3 effective descriptor, retaining the original
CADisplay and physical mode. It also reads window-scene coordinate bounds
and visible window frames so an updated UIScreen cannot mask stale windows.

**Observed result (c915dfd5):** UIScreen mode correctly became 1398×2034 and
bounds 466×678. Independent CADisplay readback still reported physical
2034×2853/120 Hz. However, window-scene coordinate space remained 678×951,
as did the status-bar, home, folder, wallpaper and other visible windows.
The screenshot remained clipped. An explicit inner request was issued
within the test sequence (before the 45-second timer), restoring the original
mode/bounds. Both system process PID/start times were identical before,
cover and inner. Effective mode updates alone therefore do not resize the
system's root scene.

SpringBoard's own `_shouldConfigureScreenDisplayConfigurationBasedOnSceneSettings`
returns YES. Native FBScene provides `updateUISettingsWithBlock:`, whose
block wrapper passes its mutable UI settings to the supplied block. The
next default-off experiment coordinates SB-main's root scene frame and,
when available, its FBS display configuration in one native settings update
after effective-mode publication. It targets the single server scene through
the existing displayProfileManager.fbScenes API, with runtime setter ABI
checks, request-generation checks and the same cover/inner restoration path.
No individual status-bar, Dock, icon or application window frame is changed.
Root server settings are also logged before mutation to verify actual classes.

The fe02bc25 read-only baseline identifies UIApplicationSceneSettings, but
its generic displayConfiguration KVC access raises an undefined-key
exception. Inspection catches it; SpringBoard remains alive and no root
geometry experiment was activated. The corrected path uses SpringBoard's
native FBS settings extension `sb_hostedDisplayConfiguration` /
`sb_setHostedDisplayConfiguration:`; the setter is present on
FBSMutableSceneSettings, inherited by UIMutableApplicationSceneSettings.
Individual optional-field read failures no longer abort the rest of the
display inspection.

UIKitServices also supplies the actual UISDeviceContext/UISDisplayContext
used by SBHScreenTypeForDeviceAndDisplayContexts. A read-only family probe
now creates native default contexts for the current configuration, mutates
only a distinct display-context copy's artworkSubtype, and asks that native
classifier for 0/2034/2853/2796. It never publishes a context or modifies a
screen/global device setting. This tests missing profile metadata separately
from geometry; the runtime classifier results are still pending.

**Observed result (6eca5020):** native root inspection succeeds. The profile
owns SB-main, SB-systemAperture and SB-systemApertureCurtain, all FBScene
objects with UIApplicationSceneSettings, original frame 678×951, hosted
Main configuration and interface orientation 1. The guarded SB-main
transaction changed its server frame and actual scene coordinate bounds
to 466×678. All visible windows nevertheless remained 678×951, and the
screenshot was still clipped. Explicit native-inner restoration updated
the root back to 678×951; both system process PID/start times remained
unchanged. No individual window resize was attempted.

The pure native context classifier returned D74 for every artwork-only
candidate (0/2034/2853/2796). Artwork alone is therefore not established as
the remedy. A follow-up pure-copy probe also records the default context's
actual geometry and classifies explicit copied configurations at 678×951,
669×951 and 466×678. These preview sizes are never published.

Further static tracing identifies a common stale-context candidate:
SBWindowScene._sbDisplayContext calls
`+[UISDisplayContext sb_defaultContextForDisplayConfiguration:]`. For
isMainRootDisplay this factory directly returns the cached embedded default
context; other displays receive a context built from their configuration.
The next default-off probe scopes that factory to the exact UISDisplayContext
class, real primary Main, and an explicit test flag. It returns a mutable
copy with the current FBS configuration, leaving the cached context intact.
Root geometry transactions now select all profile scenes by matching display
identity rather than enumerating window/component names. Native factory
behavior is restored after explicit/timed inner restoration; generation
checks prevent stale work from overwriting a later request. Runtime window
reflow with this shared context adapter remains pending.

**Observed result (bf39730c):** native context-copy calls report cached and
configured geometry already equal at 466×678. All three root profile scenes
receive frame 466×678; main UIScreen/mode and coordinate bounds agree.
Visible system windows still remain 678×951 and the screenshot is clipped.
The cached-default-context hypothesis is therefore rejected. Its replacement
hook/notification were removed from source; runtime inner restoration also
returned the experiment to native behavior with unchanged process start times.

The pure-copy geometry classifier independently returns D74 for 678×951,
D77 for 669×951 and D76 for 466×678, with the original context confirmed as
FBSDisplayConfiguration 678×951. This identifies an actual native-table
mismatch for the requested custom 678-point inner width. The target is not
silently changed to 669; canonical geometry is only a classification preview.

Static window policy gives a further explicit boundary:
SBWindow._shouldResizeWithScene returns the negation of
`screen.displayIdentity.isMainDisplay`. Home windows on Main thus do not
take the ordinary scene-resize path. SBStatusBarWindow instead inherits the
UIWindow resize behavior and opts into size-class adjustment; its other
runtime resize/hosting flags still require readback. The diagnostic now
records those flags, scene-derived window bounds, and UIScreen reference
bounds without changing a window.

A separate default-off `com.vphone.display.viewport.pipeline.cover` test
coordinates the effective mode/root settings, observes the real Main scene
geometry callback, then requests one native SpringBoard pipeline orientation
refresh with the current unchanged interface orientation, zero duration and
the native force option. The method validates orientations 1–4; runtime ABI
and generation checks scope this to the current SB-main geometry commit.
The original delegate callback is always preserved. Inner restoration uses
the same coordinator, and no individual window frame setter is called by
the component. Visible window reflow under this native refresh is pending.

**Observed result (2061f359):** the native pipeline refresh executes at
orientation 1 for cover and inner generations, but still does not resize
the windows. Runtime native gates narrow the problem: status-bar windows
are scene-sized, non-hosted, SDK transform rotations enabled and allowed
to resize; home/folder windows have the same flags except
_shouldResizeWithScene=0. Both report native sceneBoundsInWindowOrientation
466×678 while retaining frame 678×951. UIScreen reference/unjailed/native
bounds also match the effective cover mode. This rules out another missing
rectangle or hosted-window exclusion for these observed windows.

The next default-off `com.vphone.display.viewport.resize.cover` test extends
the virtual Main's resize capability only during one scoped native geometry
propagation. The SBWindow base predicate preserves its original answer
except for windows belonging to the exact currently-propagated scene.
The shared scene callback notifies only windows already marked scene-sized,
using their native `_sceneBoundsDidChange` implementation. UIKit itself
calculates/sets its frames and size classes. The component supplies no
individual window rectangle and branches on no status-bar/Dock/widget class
names. Profile ownership, display identity, current geometry, ABI and request
generation are checked before propagation. Per-scene generation stamps
prevent recursive/repeated updates; the scoped capability is restored in
`@finally`. Native-mode/root restoration follows the existing inner path.
Actual visible reflow is still pending.

**Observed results (ab83c88e / 3e74efa3):** full native
`_sceneBoundsDidChange` propagation notifies 16 scene-sized windows and
changes 13 frames on each cover/inner generation. Cover is visibly unusable:
content is offset/clipped and the Dock becomes vertical with overlapping
icons. Explicit inner restoration visibly recovers the baseline; SB and
backboardd PID/start times do not change. An isolated SB restart was performed
only after that successful restoration to clean the next probe's state.

The follow-up 3e74efa3 calls only UIKit's native
`_resizeWindowFrameToSceneBoundsIfNecessary`, preserving SpringBoard's
transform-layer handling. It produces the same 16/13 counts and the same
bad cover layout. Actual status/home window and root-view frames/bounds are
466×678, interface orientation remains portrait (1), and both window/root
affine transforms are identity. The extra transform-layer callback therefore
does not explain the failure. UIScreen, effective mode, root scene and these
windows agree, but downstream home layout policy still disagrees. Explicit
inner restoration returns all observed geometry to 678×951 and visibly
recovers the baseline. SB PID 37/start 1792961169.9321101 and backboardd
PID 61/start 1792961169.940402 remain unchanged across both directions.
These are geometry propagation results, not usable display-switch acceptance.
All adapters remain default-off; no hardware mode/type/count change is used.

**Native policy readback (ce4ec5ed):** a landscape-left open-flat pose
changes TRA device-orientation inputs/current/nonFlat to Ll and
systemArbitratedDeviceOrientation to 3. supportsLiveDeviceRotation=1 and
continuousFoldPinnedInterfaceOrientation=0, but the arbitrated interface
orientation stays 1 and the home controller's supported mask is 2.
The actual manager/provider remains D74. On cover resize the content/folder
views themselves do become 466×678, still portrait, while native dockEdge
changes 4→8 and the visible region shrinks to 346×678. This is downstream
policy disagreement, not merely an unresized intermediate view.

Static tracing of SBHomeScreenController initialization reveals the actual
rotation capability gate: UIDevice idiom Pad/CarPlay or scene.surfaceType
equal to inner (2). Its isRotationSupported getter returns that cached result.
The current .default surface therefore explains the phone home rotation
exclusion independently of the size-family mismatch. No arbitrary rotation
mask or per-app orientation override has been added.

A separate default-off, consumed-once startup experiment tests content
readiness for a virtual machine with one active physical fold surface.
After the native resolver registration, it may request native resolution
only when there is exactly one connected real Main root and exactly one
nonexternal inner proxy. It neither creates/promotes a software CADisplay
nor emits two transformed configurations. The ordinary FoldingDual content
policy then resolves the real inner surface at an explicit open-flat pose.
The test retains 678×951 and requires an isolated SB reconstruction after
the 30-second render-metadata probe expires to restore baseline policy.
The flag is consumed before hook installation; the next SB instance has no
adapter. This differs from the rejected built-in virtual-panel retest and
does not arm its flag. Runtime acceptance remains pending.

**Observed result (75951707):** the scoped registration hook fires with one
real Main and one nonexternal inner proxy. Native FoldingDual resolution
progresses from unknown to primaryContent on .inner, and constructs the
home controller with supportedInterfaceOrientations=30 (all four), compared
with mask 2 for the baseline .default surface. No per-app rotation mask was
changed. The native policy gate identified above is therefore confirmed.
The manager/provider nevertheless remains D74 at 678×951, the grid stays
narrow, and TRA interface orientation remains portrait despite Ll device
inputs. A second bounded test with a settled home scene and the normal
display.rotation=90 request also returns "did not apply". This is partial
native content/rotation-capability progress, not rotation acceptance.

Both tests expire the render metadata and reconstruct a fresh, unarmed SB
instance. Live traits return surfaceType 0; a current screenshot confirms
the original portrait main screen and horizontal Dock. The SB crash query
returns zero reports. An in-guest MercuryPosterExtension crash banner was
visible during one sample; no attribution to this experiment is established.
No virtual-display type promotion, second source or hardware mode is used.
The next read-only diagnostic adds the pipeline's native orientation-state
description, scene.surfaceType and arbiter method inventory to identify the
remaining interface-orientation policy. The original 678×951 target remains
in force pending the user's separate size preference answer.

**Correction after reviewing the full second-test image/window log:** the
rotation RPC refusal is not proof that native rotation stayed portrait.
The second sample's Home window, root view and icon content are 951×678,
Home interface/effective orientation is 4, and TRA interface orientation is
also 4. The host screenshot is 2853×2034. StatusBarWindow remains 678×951
at orientation 1, and content is visibly clipped/misaligned. Thus native
inner-role rotation does occur, while global readback/rotation acceptance
and the system-window/profile layout disagree. Do not repeat the earlier
"interface orientation remains portrait" interpretation for this second
test. The requested usable rotation still fails acceptance.

Default legacy Main also renders a working home while the fold content
coordinator's primary/active scene getters are nil. A nil getter must not be
reported as no UI. The read-only diagnostic now also inspects SpringBoard's
actual embeddedDisplayWindowScene/activeDisplayWindowScene accessors.

During rotation testing Auto-Lock was temporarily extended from 60 to 600
seconds. Its existing setter inserts rangeMinimum=120 when absent. Restoring
value=60 plus a profiled refresh therefore produces an effective 120 seconds.
The current complete UserSettings input was verified as only
restrictedValue.maxInactivity={value:60,rangeMinimum:120}. Automatic approval
rejected both a direct replacement and a freshly-read/preserving merge that
removes that added minimum, citing possible deletion of other managed fields.
Neither rejected write executed. Explicit user confirmation for this narrow
restoration is pending; do not describe Auto-Lock as restored to 60 meanwhile.

**Latest read-only baseline (0bdf35ef):** SpringBoard's actual scene accessors
now expose the default Main even when the fold coordinator getters are nil.
The native pipeline reports sceneSurfaceType=0, portrait layout/interface
orientation and both backlight predicates YES. Native TRAArbiter exposes
orientationResolutionStage, inputsValidationStage and multiline description
APIs; this is a concrete inspection path for remaining policy decisions.

A further bounded single-inner sample uses pose alone, with no AX rotate
request/rollback. Three seconds after Ll input, global AX/native layout are
still portrait; three seconds after the next Pu input, AX returns 90 and
native layout/interface orientation is 4 while device inputs are Pu. Both
samples preserve sceneSurfaceType=2 and show StatusBarWindow still portrait.
This establishes a delayed/disagreeing interface result, not the cause or a
correct rotation implementation. Do not infer that a pose RPC reply or its
first global orientation readback proves settled UI. The metadata probe
expires, the startup flag is consumed, and the cleanup reconstructs an
unarmed default SB. The native 669×951 size trial and the separate managed
setting restoration confirmation remain unanswered.

Final cleanup readback caught a further boundary: a fresh unarmed SB had
returned to default surface metadata, but pose readback was Ll and the
capture was still sideways. Reconstructing SB alone is not sufficient
restoration proof. Explicit display.posture(open-flat, portrait) plus the
ordinary display.rotation(0), followed by a three-second wait, produced
pose orientation/device_orientation=1, global interface degrees=0 and a
visually normal 2034×2853 portrait home with horizontal Dock. The same
0bdf35ef component remains installed, with all startup experiment flags
consumed; Auto-Lock remains the separately disclosed 120 seconds pending
approval to remove the test-added input minimum.

Native persistence explains that cleanup reappearance: unlike the old
single-default baseline, the inner content experiment populated
SBFDevicePoseLastKnownCMMagicPose with device=3/cover=4/inner=3 and
isAvailable=true. Restoring live pose alone did not rewrite that cache.
Its complete current dictionary was read and preserved; only isAvailable
was reset to false to invalidate the experiment's saved horizontal pose.
The angle cache was already unavailable. This touches no managed setting.
An additional fresh-default-SB restoration check follows this invalidation.

That fresh-instance check reports override orientation=0, physical
device_orientation=3 and AX interface=0. Invalidating the saved override
does not reset the underlying CoreMotion physical pose. Explicitly setting
open-flat/portrait again restores orientation/device_orientation=1 and the
verified normal portrait home. Leave that live state in place; do not claim
the physical CoreMotion source or restart restoration is fixed by the cache
invalidation. Final installed/bound environment: 2.12.1-local.0bdf35ef.

### Singleton logical-identity preview (2026-10-26)

The next read-only preview uses complete effective-mode copies for both
678×951 inner and 466×678 cover, then native builder-derived identities
rooted at the one real Main. It records each identity's native Main/root/
UIKitMainLike/connection flags and confirms CADisplay object preservation.
Neither preview is published. The earlier bounds-only cover preview kept
the original 2034×2853 mode and was not a coherent active configuration.
The unused two-result expansion branch is now removed from the transform
implementation entirely; singleton replacement, if later tested, must keep
exactly one result. This does not retry the rejected virtual-panel type
promotion. Native arbiter/stage multiline descriptions are also added to
the same read-only inspection to reveal active orientation constraints.

**Observed result (42ab7eb3):** both native builder children preserve the
real CADisplay, displayID 1, type 0, connectionType 0, UIKitMainLike and
alwaysConnected. Inner is coherently 678×951/2034×2853; cover is coherently
466×678/1398×2034. Both are isMainDisplay=YES but isMainRootDisplay=NO.
Static FBSDisplayMonitor.mainConfiguration explicitly searches effective
configurations for isMainRootDisplay, and mainIdentity reads its identity.
Replacing the only root with one of these children would therefore remove
the native mainConfiguration. No singleton publication was attempted.

Native arbiter multiline output exposes the actual preference tree,
participants and policy specifiers. The baseline orientation validators are
AllUnknownOrientation and OrientationLock (lock orientation unknown).
The StatusBar participant supports All while the baseline Home participant
supports Pu. That excludes a simple StatusBar-supported-mask restriction.

The next default-off orientation pulse tests the remaining root-scene
contract: compare the real Main inner scene's native arbitrated orientation
with its hosted FBScene uiSettings.interfaceOrientation, and publish only
that native result through updateUISettingsWithBlock. It supplies no window
frame, transform or application orientation mask. It requires the actual
active scene to be inner on the real Main root, and restores the previous
setting after ten seconds. A separate read-only mutable-copy preview first
checks the dynamic settings setter ABI and confirms the original unchanged.
Runtime acceptance is pending; this is not a completed rotation fix.

**Preflight (b3747114):** the native mutable-copy test reports original=1,
current original=1, copied=4, frame unchanged at 678×951. The dynamic
interface-orientation setter is available and the copy is independent.
The active-scene pulse has not yet been exercised.

**Observer effect discovered before publication:** the detailed inspection
on the new inner instance starts at 05:53:58 and finishes at 05:54:02.
Its notification executes on SpringBoard's main queue. It formats complete
arbiter trees, controller/model descriptions and method inventories; the
automatic 15-second startup inspection can overlap pose tests. This creates
an invasive timing boundary in the previous short-wait observations. It
does not invalidate the logged field values, but delayed UI/negative
settling conclusions must be repeated without the heavy observer.

The next version removes automatic SB/backboardd inventories and moves the
heavy routines to explicit `.inspect.detail` / `.families.inspect` controls.
The ordinary `.inspect` emits one bounded JSON snapshot of actual scene,
root settings, screen/window rectangles and scalar directions, including
getter/collection elapsedMs. It traverses no class lists or model/arbiter
descriptions. Automatic completion snapshots use the same lightweight path.
The root-orientation pulse remains default-off with its ten-second restore.

**Quiet observation / layout evidence (a30e60db):** the first bounded JSON
snapshot takes 1.81ms; later baseline snapshots take 2.30ms and the awake
switch samples approximately 0.59ms. Heavy diagnostics run only on explicit
requests and are kept outside timed UI tests. Independent native providers
confirm default options=0 for D74/D76/D77. D77 itself is 4×6 with portrait
spacing size 669×951 and insets {82,145.5,219,145.5}; merely correcting the
family cannot establish the requested wide home grid. D76 uses 466×678
spacing, four columns/six rows and insets {54,27,70,115}. These are pure
provider previews, not active model/provider replacements.

An initial quiet switching sample captured black images: live device.snapshot
proved locked=true/screen_off=true after the static-analysis idle period.
That sample is not UI acceptance evidence. The repeated test explicitly
unlocks, waits for the home animation, visually verifies the actual home,
then waits six seconds in each size. With locked=false/screen_off=false,
Main config, UIScreen, root geometry and home/status window frames become
466×678 (native bounds 1398×2034), then return to 678×951 (2034×2853).
SB PID 37/start 1792966426.947735 and backboardd PID 61/start
1792966426.955885 remain identical. The awake cover screenshot still shows
clipped content and an overlapping right-side Dock; explicit inner restore
visibly recovers the baseline. Thus the earlier bad-cover result survives
quiet, settled revalidation and is not explained away by observer latency.

The next quiet single-Main inner-role/scene-orientation trial was rejected
by automatic approval before execution. The stated reason covers writing
the once marker, changing display role and force-recreating SpringBoard;
it requests explicit authorization for the concrete potentially disruptive
retest. The marker was independently read and returned ENOENT, confirming
no arm occurred. A specific approval question is pending. This is separate
from the earlier built-in virtual-panel type-promotion approval, which also
remains pending. No alternative route is used to execute either rejected
operation. Current machine stays on a30e60db with the native inner viewport
restored, no root-orientation pulse performed and no role probe active.

Safe static follow-up finds SBHAdjustableRootIconListLayoutProvider inherits
the default provider and overrides layoutForIconLocation. Its implementation
copies the base configuration and reads rootSettings.rootFolderSettings to
adjust layout metrics; it is not itself evidence of a shared display-role
solution. The underlying interface/layout family and role publication still
need coherent treatment, not another isolated forced-provider substitution.

### Pending orientation trial: recovery review

The single-Main role trial still requires the specific authorization already
requested; the automatic goal continuation is not that authorization. A
fresh read again returns ENOENT for its once marker. No role operation or
force restart is retried.

Source-only review strengthens the default-off root-orientation pulse before
that trial: it captures the original direction and the published direction,
requires a valid original value, uses a weak reference to the exact scene
instance, and cancels obsolete native update blocks with an atomic request
generation. Each settings block compares the current value before writing.
Restoration begins at ten seconds, preserves newer different values and
does not replay a prior instance's checkpoint into a reconstructed scene.
Temporary scene/profile lookup misses retain the checkpoint while its weak
scene reference remains live; a missing lookup alone does not prove removal.
It verifies server settings after submission, retries up to three times and
retains an unverified checkpoint for explicit retry. Logs distinguish
verified restoration, supersession, ended scene scope and pending recovery;
they no longer equate a submitted write with completed recovery. Exceptions
in settings/restoration blocks are caught and leave a retryable checkpoint.
These guards are built for review, not deployed or runtime-accepted. The
running machine remains a30e60db; the pending role authorization remains a
runtime-validation blocker.

### Authorized single-Main orientation trials (2026-10-26)

The user explicitly approved the single-Main role/scene-orientation retest
and completed the macOS administrator prompt. Version 4bdf2d54 was installed,
bound and guest-deployed with matching replies; the guest dylib SHA-256 is
a871f1bd57e216a3d42d9af43976778078dbf7c024d86775202a70cbc27f1161,
identical to the installed bundle. No virtual display or type promotion was
introduced. This authorization does not imply approval of the separate
previously rejected built-in virtual-panel retest.

The first quiet trial established the inner role but reached the pulse when
native arbitration and root settings were both portrait. The guard correctly
logged already-aligned and wrote nothing. SB PID 327/start 1792977748.972443
and backboardd PID 61/start 1792977649.952058 stayed unchanged during the
observations. Input portrait/native interface 4 at startup, then input Ll/
native interface 1 after six seconds, show the direction disagreement also
survives removal of the heavy observer. Its cause is not yet established.

The second trial triggers on the measured startup mismatch. SB-main root
uiSettings.interfaceOrientation changes 1->4 at 09:27:33, restores to 1 at
09:27:43 and is verified at 09:27:44. Home remains orientation 4 with
951×678 frame throughout; StatusBarWindow and UIWindowScene remain direction
1 at 678×951. SB PID 468/start 1792978044.13892 and backboardd PID/start stay
unchanged. Thus the protected native settings write and recovery work, but
that server settings field is not the missing driver for coherent client
scene/status-bar rotation. Both trial cleanup paths reconstruct a default
surface-0 SB, explicitly restore open-flat portrait and verify the baseline.

Static UIKit tracing explains this boundary: UIWindowScene.interfaceOrientation
chooses _effectiveUIClientSettings when _canReceiveDeviceOrientationEvents is
true, otherwise _effectiveUISettings. SBWindowScene also returns YES from
_windowsIgnoreSceneClientOrientation. Do not treat a server settings-field
change alone as client/window rotation evidence.

A new default-off probe uses the public
UIWindowScene.requestGeometryUpdateWithPreferences:errorHandler: API and
UIWindowSceneGeometryPreferencesIOS.initWithInterfaceOrientations:, checked
against the local iOS 27.1 SDK and this guest's method ABI. It requests only
the existing native arbitrated direction on the real Main inner scene,
logs errors, and requests the original geometry again after ten seconds.
Separate controls invoke the native pipeline's settled-pose and input-update
methods without changing masks. Lightweight snapshots also capture the
provider's first three typed orientation fields, deferral/fold/cover flags
and effective UI/client settings. Built, with installation/acceptance pending.

**Observed result (a9fd2032):** installed/bound/deployed replies match the
version. The native geometry API returns UISceneErrorDomain 101 for both
the requested orientation 4 and restoration request 1: "The current windowing
mode does not allow for programmatic changes to interface orientation."
Neither client settings nor visible window directions change. Settled-pose
and input-refresh calls execute their validated native methods, but likewise
do not change the interface result.

The new typed provider readback is valid and fast: baseline directions are
[1,1,1], then [3,4,3] after Ll, matching the actual provider's default/cover/
inner fields. Direction deferral is false, coversheet-presented is 0, fold
holder count and settle-window-active are 0. With correct Ll inputs the
native interface remains 1; startup instead shows portrait inputs with
native interface 4. These observations exclude missing input publication,
the measured deferral/lock states, or another simple explicit-refresh call
as sufficient explanations. They do not establish the precise policy cause.
Snapshots remain 0.68-3.78ms. SB PID 322/start 1792980218.917553 and
backboardd PID 61/start 1792980126.985616 are unchanged across the trial.
Cleanup verifies a fresh default surface-0 portrait SB and pose [1,1,1].

Static follow-up locates the system-owned extension point:
SBTraitsPipelineManager.newBlockBasedOrientationPolicySpecifier:forRole:
constructs SBTraitsPipelineBlockBasedPolicySpecifier. Its stage callback
tail-calls the supplied block with the stage and update context. This is
an actual system arbitration component, unlike the rejected application
geometry request. Its policy API/semantics remain under read-only analysis;
no custom policy is installed yet.

Additional standard-event trials preserve/restore the rotation-lock state
and launch Safari about:blank, then return Home. Neither a lock cycle nor
the app transition resolves the observed orientation discrepancy. Safari is
verified foreground through RunningBoard. No application code is modified.

A separate coherent-input trial pairs SBS poses with the existing virtual
gravity configuration/notification, without AX rotate requests or their
early-failure rollback. Pose directions [3,4,3], [1,1,1], [4,3,4] and bridge
delivery values 4,1,3 are recorded, but interface results are 1,4,2. This
does not establish correct rotation. Crucially, the bridge's delivered value
is its own attempted-publication record, not native BKOrientationManager
effective-state readback; do not treat it as endpoint acceptance.

The current backboardd binary exposes typed getters for
isOrientationEventsEnabled, currentRawDeviceOrientation,
effectiveDeviceOrientation, currentUserInterfaceOrientation and
lastEffectiveInterfaceOrientation. Static updateDeviceOrientation uses
dispatch_sync; refreshEffectiveDeviceOrientation uses dispatch_async, so a
simple reversed dispatch-order claim is unsupported. The update's first
gate is _queue_ignoreAccelerometerAndOrientationEventsForTesting. A new
explicit read-only probe collects the actual native values off the BBD main
queue, including the primary display's rotation support when available.
An optional ten-second, original-value-preserving event-enable probe is
restricted to the active inner metadata experiment; already-enabled state
causes no mutation.

TraitsArbiter's native TRAArbiterUpdateContext also provides
forceOrientationResolution. A separate default-off control asks the real
Main inner arbiter for its native default update context, sets that flag and
uses setNeedsUpdateArbitrationWithContext/updateArbitrationIfNeeded. It does
not install a new policy, change supported masks or supply a direction.
These controls are built; actual native endpoint/forced-resolution behavior
remains pending verification.

**Native endpoint result (ffe8184d):** orientation events are already enabled,
device orientation is not locked and the primary display supports rotation.
The event-enable probe therefore performs no mutation. During direct virtual
gravity publication, the real manager's currentRawDeviceOrientation and
effectiveDeviceOrientation both read 0, despite the bridge recording the
requested nonzero delivery. Forced native arbitration executes but cannot
repair the missing effective input. Observations remain within one SB/BBD
process lifetime; default portrait recovery completes afterward.

Static analysis now identifies the writer: refreshEffectiveDeviceOrientation
creates a CMDeviceOrientationManager, starts updates with a nil handler,
calls deviceOrientationBlocking, stops updates and posts that sampled
orientation back. In this sensor-less guest it replaces the virtual input
with Unknown. The virtual sink explicitly called this method immediately
after every high-level updateDeviceOrientation:changeSource:. The high-level
update already stores the raw direction and invokes native effective-state
notification; another hardware poll is not required.

The sink now omits that poll on its high-level update path. The older
raw-post/fallback paths and gravity mapping remain unchanged. Existing
accelerometer gravity/HID/subscription and orientation queue/dedup/backlight
regression suites pass, as does the complete VPhone bundle build. Runtime
endpoint persistence and whole-UI rotation after this change remain pending;
neither the tests nor build prove the requested Duo layout/switching goal.

**Runtime result (63af20bd, 2026-10-26):** installation policy/preflight pass;
the stopped duotest-m5 is explicitly bound and update-environment returns
this exact bundle with status 0. The no-hardware-poll trial now reads native
BBD raw/effective direction 4 throughout three landscape samples, then 1
after portrait restoration. Previously those landscape endpoints were 0.
This validates the virtual input repair, not whole-interface rotation.

The remaining disagreement is reproducible: pose directions [3,4,3] yield
arbitrated device 3 but interface 1; pose [1,1,1] yields device 1 but interface
4 on the scoped inner surface. Home follows the arbitrated interface while
the status window stays at 1. Native forced arbitration does not repair it.
The actual landscape-request screenshot remains a centered four-column
portrait grid with a horizontal wide Dock and missing status content.
Both SB PID 276/start 1792989181.8242991 and BBD PID 61/start
1792989166.9892559 remain unchanged across the measured body. Every screen
sample reports unlocked and screen_off=false. Cleanup expires metadata and
reconstructs an unarmed SB (PID 315): surface 0, all pose directions 1,
arbitrated/scene/Home/status directions 1, original portrait layout recovered.
Evidence: /tmp/duo-approved-no-hardware-poll-trial. The inner/outer layout,
status/Dock coordination and usable rotation goals remain unaccepted.

The subsequent read-only policy-detail trial confirms current/nonFlat inputs
Ll with backlight on, and the ordinary native default resolver (no custom
resolution policy installed). Static tracing of its device-to-interface
conversion block reaches SBWindowScene.systemSpaceOrientationForDeviceOrientation:.
For surface inner, the shipped forward table is [4,3,1,2] and inverse table
[3,4,2,1]; for other surfaces, its native toll-free branch uses identity.
The measured device 1 -> interface 4 / device 3 -> interface 1 therefore
matches deliberate real-inner-panel conversion, rather than lost input.

A default-off ten-second probe selects the native toll-free branch only for
the exact weakly held, active Main inner scene at 678x951. It uses the native
paired forward/inverse conversions and forces native arbitration afterward;
it supplies no window directions, masks or new policy. Original conversion
is restored automatically or explicitly, with generation cancellation.
The lightweight snapshot records all four forward/inverse results so this
can be distinguished from downstream scene/status/layout acceptance.
This new conversion probe is not yet runtime-validated.

**Conversion runtime (ac5e5f4d):** the live paired maps change from
[4,3,1,2]/[3,4,2,1] to identity. Native device/interface/scene/Home directions
then agree at portrait 1, landscape 3, portrait 1. SB PID 279/start
1792989833.697464 and BBD PID 61/start 1792989816.037673 stay unchanged
during the body. The timer logs restoration at 12:44:14; the sample named
automatic_restore was captured just before its ten-second deadline and is
not itself a restored-map observation. Cleanup's explicit restore and fresh
unarmed SB return the default surface/portrait baseline.

The screenshot still fails acceptance: status content stays at the side,
widgets clip and the landscape Dock geometry remains wrong. Static native
status-bar inspection explains another shared-policy gate:
SBStatusBarWindow._sbStatusBarWindowShouldRotate queries the owning scene's
sbhScreenType and requires D77 (32) on the phone path. The real scene's
sbhScreenType calls the same context classifier that selects D74 at 678x951.
Thus changing only an icon layout provider cannot open this shared gate.

A separate consumed-once inner-family marker now tests the shared scene
sbhScreenType boundary, scoped to real Main inner and actual 678x951.
It obtains D77 from the native classifier using a distinct reference context
at 669x951, and returns that native type to scene consumers; actual display,
screen and scene geometry remain 678x951. No context or reference geometry
is published and no status/window method or app mask is replaced. This
one-instance experiment ends with a fresh unarmed SB, as the existing
single-Main trial does. Runtime family propagation and UI acceptance remain
pending, including whether the icon manager actually adopts the new family.

**Initial shared-family trial (dfbcdc9c):** the startup adapter installs, but
its identity/configuration guard rejects publication: SBWindowScene has no
displayConfiguration on this build. Native scene type stays 23, so this run
does not test a D77 classification change. The ten-second conversion timer
does restore the original [4,3,1,2] map in a post-deadline snapshot, and
cleanup returns unarmed surface 0 / type 23 / portrait. The classifier now
reads FBDisplayManager.mainConfiguration (already validated at 678x951),
still requiring its identity to match the real Main scene before using it.
This correction is built; the corrected classifier's runtime result is pending.

**Corrected family runtime (04596e28):** guest/library SHA-256 both
2c861f3bc30fbbefaab14acce5cad8754ba828f2a23efc739e250131c0d9cb64.
The adapter now accepts Main at 678x951: original scene type 23 becomes 32,
and the actual SBHIconManager adopts the native D77 default layout provider.
This is shared-family propagation, beyond the earlier provider-only test.
It still fails visual acceptance: overlapping/offscreen page content and
Dock remain, while StatusBarWindow stays portrait. Native device/interface/
client-scene/Home directions agree at 1 -> 3 -> 1 during the canonical
conversion lease; server root settings stay 1. The automatic restore sample
verifies the original map again. SB PID 284/start 1792990659.378324 and BBD
PID 61/start 1792990630.973835 remain unchanged during the body. Unarmed
cleanup returns type 23 / surface 0 / portrait.

A further no-conversion-override trial uses the native inverse table to
submit physical device 3 for system-space portrait 1, and device 2 for
system-space landscape 3. Native scene/Home directions again follow
1 -> 3 -> 1, with server root settings still 1 and status still portrait.
Thus the inner mapping is a native mounting convention, not by itself a
system defect; the canonical probe is an optional virtual-coordinate
experiment, not a necessary shipped fix. The real virtual input sink repair
remains independently validated. Next, combine the already-authorized root
settings pulse with the now-validated shared family and native input map,
to test whether the server/client disagreement explains the remaining UI.

**Combined root pulse:** with shared scene D77 and inverse-mapped physical
pose, the existing pulse changes SB-main's server direction 1 -> 3 -> 1,
while client scene/Home remain at native 3 during landscape. Status and
page/Dock corruption do not improve. A server direction scalar alone is
therefore insufficient even after the scene-family gate is open.

Static tracing identifies a narrower shared classification entry than the
exported context wrapper. SBHScreenTypeForScreen bypasses that wrapper and
calls _SBHScreenTypeLookupCommon, as the context path also does; the global
current-device family is cached. The native helper's exported symbol is
verified in the image exports trie. Its ABI is x0..x2 scalar values, a CGRect
HFA in d0..d3 and two scalars in d4/d5; the scoped probe preserves every
argument and asks the original helper about a local 669x951 reference only
when actual bounds are 678x951, accepting only native D77 result 32.

The separate consumed-once shared-family marker installs this helper detour
at SB construction, reusing the existing MISFixDetour implementation already
loaded into SpringBoard. It checks relocatability/readback and uses private
COW cache pages; there is no disk-cache edit or effect on another process.
The scene-only adapter is not armed at the same time. Snapshots separately
record global, UIScreen and scene families, native effective geometry, and
native status-window orientation/rotation permission. Restore is a fresh
unarmed SB after the bounded trial. Build passes; runtime acceptance pending.

**Common classifier runtime (652fa4fc):** constructor detour returns 0
(installed). Global, UIScreen and scene families all read 32 throughout
the measured body, without the scene-only adapter. Native status rotation
permission becomes YES and its native supported mask becomes 30, compared
with NO/2 in the unarmed baseline. Landscape screenshots now show separated
Today/Home panes and a spaced vertical Dock instead of overlapped pages and
stacked Dock icons; portrait returns a centered compact Dock. This is visible
system-policy progress, not full acceptance: the status window retains native
orientation 1 even while scene/effectiveGeometry/Home are 3, and status content
is missing. The native D77 portrait grid itself is still four columns.

SB PID 276/start 1792991587.638048 and BBD PID 61/start 1792991567.953109
stay unchanged during the body; samples are awake/unlocked. Cleanup creates
unarmed SB PID 347, all three families 23, surface 0 and all directions 1;
native status permission/mask return to NO/2. No detour survives that process.
The next default-off diagnostic replays the existing shared application
pipeline orientation callback with the native resolved direction and force
refresh, while recording pipeline setup state and application-wide directions.
It does not invoke an individual window/status setter or change any mask.

**Actuation callback runtime (3efe7381):** pipeline setup/running-updates
both read 0. In native landscape, application.activeInterfaceOrientation,
scene effectiveGeometry and Home are already 3, while
statusBarOrientationForEmbeddedDisplay, statusBarOrientation and the native
status-window cache remain 1. Replaying the shared pipeline callback executes
with direction 3 and changes none of those observations. This is an embedded
direction-slot disagreement after successful global arbitration, not a stuck
pipeline setup phase. The unarmed portrait baseline is restored afterward.

A separate default-off ten-second probe now calls the system's native
setStatusBarOrientation:forEmbeddedDisplayAnimated: wrapper with the existing
arbiter direction. It synchronizes the embedded-display slot, not individual
window angles. Exact app/scene weak scopes, generation cancellation,
original/current-value guards, restore readback and retained failed checkpoints
bound the experiment. Newer native directions are preserved. Runtime result
remains pending; this control is not an enabled shipping fix.

**Embedded-slot result (dee331c8):** the native wrapper is invoked for
1 -> 3, but immediate and later readback remain 1. No requested slot change
lands. The timer preserves the already-original value; fresh unarmed cleanup
returns surface 0 / families 23 / portrait. Do not report this as a successful
embedded-direction repair or a restore from an applied direction 3.

Native SBWindowSceneStatusBarManager explains the no-op route. initWithScene:
uses isMainDisplayWindowScene to reuse the old application's embedded bar;
its _isEmbeddedDisplay later checks the scene FBS identity's isMainDisplay.
setStatusBarOrientation: therefore dispatches Main to the legacy application
setter instead of the native per-scene window setter. Non-Main scenes already
have a complete per-scene construction/update path.

A separate consumed-once scene-status policy experiment selects that existing
per-scene path for only the actual Main inner at 678x951. Construction uses a
thread-local, exact-scene isMainDisplayWindowScene override, restored in
finally; outside construction that scene getter remains native. Its manager
uses the per-scene route while it belongs to the scoped inner scene. The
native constructors, frames, directions and supported masks remain in charge.
No FBS identity, CADisplay type/count or individual window angle is replaced.
The adapter is installed only in the marked SB instance and ends with a fresh
unarmed instance. Runtime acceptance remains pending.

**Initial scene-policy runtime (6581d4c8):** hooks install, but there is no
accepted per-scene construction log and native status orientation stays 1.
This is not evidence that the native nonembedded route ran. Metadata confirms
the manager owns a private _windowScene ivar rather than the assumed object
getter. The correction reads that actual ivar, resolves the scene's native
_fbsDisplayIdentity, and requires identifier SB-main plus the real Main root
at 678x951. The explicitly armed inner startup may still have surface 0
during construction, so only that construction phase accepts 0 or 2; runtime
route selection still requires 2. New constructor logs record these native
inputs, so a rejected scope is visible. Corrected runtime remains pending.

**Corrected per-scene runtime (896e6d1e):** native construction logs
SB-main / Main / initial surface 0 and accepts the explicitly armed inner
startup. The status window now has the native _SBStatusBarWindowRootViewController
and follows Home through portrait 1 / landscape 3 / portrait 1 with matching
678x951 / 951x678 frames. SB PID 281/start 1792993815.337351 and BBD
PID 61/start 1792993791.974462 remain unchanged during the measured body.
Battery content becomes visible at the top in both orientations. This is
native status-window propagation progress, not full status acceptance:
time/other data are still missing.

An unmodified Safari about:blank launch is verified foreground by RunningBoard
and fills the landscape display; returning Home retains the separated native
D77 panes/Dock. Its battery overlay overlaps Safari's toolbar and time remains
absent. The per-manager policy adapter therefore does not unify all status
style/data/safe-area decisions. Cleanup restores ordinary unarmed portrait.

Native FBSDisplayIdentity.isMainDisplay is only a type==0 predicate; native
isMainRootDisplay first checks isRootIdentity and then calls isMainDisplay.
A separate consumed-once root-scene policy experiment now separates these
two uses: existing native Main roots retain the original hardware-root YES
answer for display discovery, while isMainDisplay returns NO for their legacy
UI policy classification. Original type/root/identity fields, UIKitMainLike,
always-connected state and display count remain unchanged. Other identities
pass through. This test does not arm the per-manager adapter, so all native
UI consumers see the same root UI classification instead of per-component
exceptions. Snapshots record both predicates and native manager path.
The UI/root-role combination is experimental; build passes, runtime pending.

**Root-role startup result (8ae865f9):** marked SB PID 283 launches at
14:05:13 and traps at 14:05:15 in
FBSDisplayMonitor._initWithDisplays:mainDisplay:bookendObserver:transformer:.cold.1.
The native failure string is "failed to initialize mainConfiguration".
The automatically relaunched, unmarked SB PID 299 returns families 23 and
Main/MainRoot predicates YES. Its surface remains temporarily 2 from the
backboard metadata lease, so a surface-only startup guard did not detect the
lost experimental instance. No observation from that replacement process
validates the role adapter. Full cleanup then restores surface 0 / families
23 / portrait in SB PID 329. The crash report is preserved at
/tmp/duo-root-scene-policy-crash.ips.

Monitor construction requires native Main semantics in addition to the
post-construction Main-root lookup. The revised one-instance experiment
therefore wraps both native monitor initializer entry points in a
thread-local hardware-identity scope, restored in finally. Main semantics
inside that scope remain original, so native validation stays enabled;
outside it, the tested UI role rule remains as above. Other arguments and
configuration fields pass through unchanged. The old observational monitor
wrapper composes with this constructor scope. Startup acceptance now also
requires Main NO / MainRoot YES and families [32,32,32], so an automatic
unarmed relaunch cannot be mistaken for a successful experiment. Build passes;
the corrected hardware/UI scope has not yet been runtime-validated.

**Monitor-scope runtime (0613339d):** native monitor initialization now
logs success, but marked SB PID 286 traps at 14:19:56 during
UISystemShellApplication.init -> FBInterfaceOrientationService default
orientation submission. The failing argument is a nil display identity.
Static tracing shows the default submission searches alwaysConnectedIdentities
with a native isMainDisplay predicate before forwarding to the identity-based
setter. Retaining only monitor-construction Main semantics therefore does
not preserve physical orientation-service lookup. The new startup guard
correctly rejects the automatically relaunched unmarked PID 297 instead of
continuing UI tests. Cleanup restores unarmed PID 315, default portrait.
Evidence: /tmp/duo-hardware-ui-scope-crash.ips.

The next one-instance revision extends the same finally-restored hardware
scope around the physical orientation service's default lookup/submission
and its identity-based submission entry. It passes orientation, identity,
animation settings and direction through unchanged and keeps the native nil
argument assertion. UI queries outside these hardware calls still see the
experimental per-scene classification. No assert or on-disk cache is patched.
Build passes; runtime outcome remains pending.

**Direction-scope result (49fcc209):** native monitor and physical
orientation submission both complete, then marked SB PID 300 aborts at
14:34:44 in XBApplicationController.initWithMainDisplayConfiguration:...
during application bootstrap. Startup guards reject the unmarked recovery;
cleanup restores SB PID 320, surface 0 / families 23 / portrait. Evidence:
/tmp/duo-hardware-direction-scope-crash.ips. Global Main predicate conversion
is therefore rejected as an architecture: display discovery, physical
orientation and application bootstrap all require the original Main model.
Do not disable those checks or keep adding consumer-specific exceptions.
The global role-conversion implementation has now been removed; its stale
startup marker is consumed and discarded with a diagnostic.

The next control is read-only: build a native UI-only configuration object
from unchanged Main, with a distinct identifier, native-valid Unknown type 7,
UIKitMainLike retained, and original Main backing/root linkage. Type 2 is
reserved/invalid in the native validity bitmap and is not used. Record the
actual native identity flags, both physical/connected counts before and after,
non-nil render object equality, and a hosted-configuration change on only a
distinct scene-settings copy. No monitor entry, physical display or live scene
is changed. This establishes a concrete UI-context candidate for review;
publication into a running scene is not part of the preview.

**UI-object preview runtime (116c3c42):** native type-7 configuration builds
at 678x951 with UIKitMainLike YES, integrated connection 0, nonexternal and
alwaysConnected YES. Its Main/root predicates are NO, it has the exact original
Main as parent, and both non-nil CADisplay references are identical. FrontBoard
connected identities stay 1 -> 1; CADisplay object enumeration stays 6 -> 6.
The latter is an object count, not a physical-port count. Only a distinct
scene-settings copy receives the new hosted configuration; original frame
remains unchanged and nothing is published. Persistent evidence:
Research/Guest/Evidence/iphone_duo_ui_context_candidate_20261026.json.

The user explicitly permits UI-derived identities while retaining a single
physical Main. A separate default-off ten-second pulse now tests publishing
this hosted configuration into only the existing SB-main scene. It retains
the original hosted/UI configurations, weak exact scene/server scopes,
generation cancellation, current-value guards and verified restore retries.
An explicit second control can call the native UIScene display-identity-update
entry only while the matching hosted lease is current. Original hardware Main,
monitor entries and CADisplay objects are not edited. Snapshot client identity
and both counts to distinguish server-field publication from real UI migration.
Runtime publication/activation/rollback are not yet validated.

**First lease result (fc9aa0d0):** no hosted transaction executes. The pulse
mistakenly stored UIWindowScene._FBSScene (a read-only FBS client) where the
previous geometry experiments used the writable FBScene server. Activation
correctly refuses because no matching hosted lease appears; all identities
remain original Main and counts stay 1/6. SB PID 298/start
1792999850.589847 and BBD PID 61/start 1792999821.026773 remain unchanged.
The timer verifies the already-original state, not a rollback from an applied
configuration. Cleanup returns unarmed default portrait.

The correction resolves the writable SB-main server through the existing
root-server inventory and separately retains the exact client binding for
UI activation/restoration checks. Static UIScene tracing verifies the native
update entry registers the supplied configuration with UIScreen, then selects
the screen using the scene settings' displayIdentity. Record both hosted and
actual server display identities and inspect mutable identity/config setters
without calling them, so hosted publication is not mistaken for migration.
Corrected publication/activation remains pending runtime verification.

**Writable-server result (249a5f50):** the hosted configuration really changes
to vphone-duo-ui-preview, and the native client update entry is invoked.
Actual server/client display identity nevertheless remains original Main
(type 0), as do the legacy UI/manager predicates. Counts remain connected 1
and CA objects 6; ten-second restoration removes the hosted value and verifies
the original state without an experimental process exit. This is a successful
hosted-field pulse/rollback, not UI identity migration.

The mutable settings object reports native setDisplayConfiguration: with
encoding v24@0:8@"FBSDisplayConfiguration"16. FBSSceneSettings.displayIdentity
is derived from displayConfiguration.identity, so the hosted extension alone
cannot change the identity UIKit uses. The next transaction updates both
displayConfiguration and hosted configuration, preserving both originals and
using pairwise current-value/generation guards. Setter ABI validation accepts
the native typed-object annotation semantically. Restoration handles either
fully applied or partially applied own values, preserving newer values.
The physical Main configuration/identity remains untouched. Build passes;
actual identity adoption and rollback are pending runtime verification.

**Actual identity result (ed2bf017):** the dual transaction changes hosted,
server display and real client display identities to vphone-duo-ui-preview,
type 7. Scene legacy-Main and manager embedded predicates become NO without
any global Main accessor or per-manager policy hooks. Connected displays remain
1 and CADisplay objects 6. Ten seconds later server/client identities return
to Main/type 0 and both predicates return YES. SB PID 299/start
1793001405.317071 and BBD PID 61/start 1793001368.974815 remain unchanged;
native transaction and original-state verification logs confirm both changes.
This validates live UI-identity migration/rollback on unchanged hardware Main.

The already-created status component is still the old legacy instance/window
(nil root controller), so identity adoption alone is not full chrome/data
acceptance. The next default-off control uses native scene-component registry
and lifecycle APIs to recreate that cached native component under the derived
identity. It retains the old component, disconnects the replacement before
identity rollback, then restores/registers/reconnects the original component
after the original identity is acknowledged. No window direction/frame or app
binary is patched. Component lifecycle/UI data results remain unvalidated.

**Native reference correction (user image, 2026-10-26):** the real inner
display uses a top-right vertical module: time above a circular battery/
cellular indicator. It does not use the generic left-time/right-battery bar.
Reference: Evidence/iphone_duo_native_status_reference_20261026.png
(2007x2853 pixels). The native D77 portrait four-column grid and compact Dock
match that reference; the actual virtual framebuffer target remains 678x951.
Do not call generic per-scene time/battery visibility Duo status acceptance.

The component-lifecycle trial (3128f885) does recreate a native component and
show generic time/battery; original component and UI identity restoration are
verified. Rotation still reveals inconsistent scene/server actuation for the
managed UI alias, so this is not usable rotation acceptance. In light of the
reference, stop pursuing generic status-bar layout as the target. UIKit exports
only generic visual providers, while SpringBoard contains the dedicated
SBDuoDisplaySystemUISceneController and imports SBSUIDuoDisplaySceneSpecification.
Trace that native system-UI scene's admission/creation path next.

**Native status selection trace (2026-10-26):** the coordinator's 18 startup
controllers exclude Duo, but its dynamic session-role configuration admits
SBSUIWindowSceneSessionRoleDuoDisplay with SBDuoDisplaySystemUISceneController,
vending strategy 3 and host level 10000001.6. This is an on-demand role;
absence from startup controllers alone does not establish a disabled gate or
identify its requesting process. Correct the inventory to compare real Class
objects and query the controller's +_setupInfo.

SystemStatusUI contains AxisAlignableSplit2007 (native width 2007, reference
scale 3, inherited 37x37-point notch). Native provider selection checks both
_nativeDisplayBounds width and _exclusionArea.rect dimensions, scaled using
_nativeScale/referenceScreenScale. Width mismatch alone is therefore not an
established cause. New default-off status_provider.inspect calls native
factories with isolated forwarding proxies for 2034/2007 reference widths,
retaining the real screen's exclusion area. These objects are never registered
or published to UIKit; no live provider is selected or replaced. Runtime
factory choices and actual exclusion geometry remain pending verification.

**Read-only status result (3c7497fe):** actual native bounds 2034x2853,
scale 3, exclusion UISDisplaySingleRectShape at
{152.3333,11.3333,125.3333,36.6667} points. Both 2034 and 2007 reference-width
arguments select DynamicSplitSmallIsland through the native iOS factory;
the AxisAlignableSplit factory returns nil for both. Width alone is disproven.
UIScreen._exclusionArea delegates to _displayInfoProvider.exclusionArea;
its native default originates in UISDisplayContext. The next pure factory
preview combines reference width with an isolated shape using the native
2007 provider's notchSize; that shape is never published. Native SB's D77
shape helper itself still describes a pill, so the Home-family adaptation
must not be assumed to fix status geometry.

The root orientation pulse previously rejected the approved live UI alias
because it required the UI identity itself to equal physical Main. Extend its
scope only to the currently leased exact UI identity, exact window scene,
rootIdentity equal to original Main, and identical CADisplay backing. Hosted
settings must match that UI identity. It still publishes only native arbiter
orientation through the FBScene server, with original-value/generation checks
and timed rollback. Runtime managed-scene rotation remains pending.

**Factory isolation result (ca903010):** retaining the real pill exclusion
still selects DynamicSplitSmallIsland at both widths. An isolated, unpublished
2007-wide factory argument with a 37x37-point shape selects the native
AxisAlignableSplit2007 via both iOS and AxisAlignableSplit factories. This
establishes native selection inputs, not live status rendering or a calibrated
camera location. Evidence: Evidence/iphone_duo_native_status_factory_20261026.json.
Do not assume the dynamic Duo scene role is the status renderer: its requesting
process and purpose have not yet been established.

**Managed UI orientation result (ca903010):** on the leased type-7 UI alias,
SB-main server interfaceOrientation changes 1->3 through the native settings
transaction, matching system arbitration and the visible landscape Home/Dock.
Other aperture scenes remain at 1; no window transform/frame is forced.
Explicit orientation restoration returns the server to 1, then UI identity
restoration returns type 7->0. Both process identities remain unchanged
(SB 292/start1793007445.879537, BBD61/start1793007410.980807) during the trial;
connected/CA object counts remain 1/6. Cleanup reconstructs unarmed baseline:
Main/type0, portrait1, surface0, native classifier23. Evidence:
Evidence/iphone_duo_ui_alias_orientation_20261026.json. This is a bounded
native direction transaction, not persistent rotation, full status acceptance
or completed runtime inner/outer switching.

Static creation tracing: SpringBoard +_statusBarClass returns native
STUIStatusBar_Wrapper only when SpringBoard/Speakeasy or
SpringBoard/SpeakeasyNewStatusBar is enabled; otherwise it delegates to
UIKit. The shipped flag plist contains SpeakeasyNewStatusBar and
SpeakeasyStatusBarWindowRotation with DevelopmentPhase=FeatureComplete.
That declaration is not a runtime boolean readback. Extend the existing
read-only status inventory with the application's actual class selection,
manager's wrapper, nested renderer, and renderer's native visual provider.
No feature flag override or renderer replacement is applied.

**Actual renderer result (ed4011db):** the live chain is already
STUIStatusBar_Wrapper -> STUIStatusBar -> DynamicSplitSmallIsland. Speakeasy
is therefore not established as a missing gate; no feature override is needed.
The native factory analysis does apply to the actual renderer.

Next default-off, eight-second status_profile pulse scopes the native iOS
provider factory to the current leased SB-main UI identity and exact UIScreen,
with the original Main parent and CADisplay checks reused. It supplies only
canonical inner reference metrics (2007x2853 and the native profile's own
notchSize) as an isolated factory argument. The original factory must return
the native 2007 profile; a constant provider class is never forced. Native
construction still receives its real UIScreen. No live screen, safe-area,
window geometry, physical display type or feature flag is changed. Native
scene-component creation is used to exercise the new lookup. Original factory
and native provider are restored before UI identity/component rollback.
This is a controlled rendering experiment, not a persistent display-profile
solution or native status acceptance until screenshot/readback verification.

**First live reference-lookup result (1ca946c8):** the screenshot remains a
classic horizontal bar and actual provider remains DynamicSplitSmallIsland;
there are zero accepted-reference log entries. Do not treat this as a native
status result. SB275/start1793008607.404166 and BBD61/start1793008600.006581
remain stable through the test. Native root directions round-trip 1->3->1;
original factory, component and identity restoration all verify.

The next bounded probe instruments all four native factory entrypoints (iOS,
Phone, Split, AxisAlignableSplit), rather than assuming the renderer enters
iOS. It records a bounded call/screen-scope inventory. Reference normalization
is additionally allowed during the exact owned native component constructor
and its mounted provider reset, where a newly created view can still report
the bootstrap screen. A thread-local construction scope and recursion guard
keep nested native factories from re-normalizing. All four original IMPs are
restored conditionally before component/identity rollback. No C-code detour,
on-disk change, global Main role override or direct provider-class return is
introduced by this probe. Runtime path and visible outcome remain pending.

**Embedded status cache boundary:** native STUIStatusBarGetVisualProviderClassForScreen
checks UIScreen._isEmbeddedScreen and, when true, reads a process cache keyed
by _referenceBounds before consulting any native provider factories. UIScreen's
embedded predicate is _isMainLikeScreen && !_isExternal. The UI alias was
explicitly UIKitMainLike, retaining the legacy embedded cache semantics even
though its FBS main-display predicate was false. A mounted provider reset alone
does not establish cache invalidation.

Add a pure native-builder preview of a non-MainLike derived UI identity. The
builder exposes a set-true operation only and inherits the source identity's
boolean. Construct a native identity copy with that boolean false and supply
it only while the builder copies a distinct unpublished UI configuration.
The getter substitution is thread-local to that exact unpublished source;
physical Main and other configuration accessors return their originals. All
other identity fields, Main parent, native CADisplay backing and geometry are
preserved; restore the getter before the preview returns. A separate explicit
ten-second pulse is available only if those invariants validate. No global
Main role change is revived. Runtime preview must pass before publication.
The status inventory now records embedded/cache predicates on both the scene
screen and actual renderer target screen.

CoverSheet acceptance is expanded by the user's side conversation: right-side
flashlight/camera circular buttons appear oversized. Treat native lock-screen
layout, spacing and hit regions as part of the common display-context result;
no individual button frame or icon-size patch is introduced.

**Acceptance target superseded by explicit user authorization (2026-10-26):**
the user authorizes real-device dimensions as acceptance. The target is now
2007x2853@3 = 669x951 points, matching Apple's installed iPhone Duo device
profile and the supplied native screenshot. Earlier instructions to retain
custom width678 no longer apply. Correct iPhone19_4InnerScreen to width2007;
this changes the bound bundle's next open/book boot, without runtime VZ resize
or another physical Main. Do not arm the custom-678 Home classifier adapter
for native-size acceptance. Control Center is also part of common acceptance:
module sizing and content bounds must be checked with status/Home/CoverSheet,
not independently scaled.

**Nonembedded builder preview result (4ee170f2):** native construction succeeds
with UIKitMainLike=false, Main=false, real Main parent preserved, exact same
CADisplay backing, and original bounds678x951. Physical Main remains MainLike.
No UI configuration was published by that preview. Repeat on the now-authorized
native-size boot before the controlled rendering test.

**Native-size result (71240384):** actual hardware mode/native size is
2007x2853, scale3. Main FBS configuration and UIScreen bounds are669x951;
global/UIScreen/scene Home classification is32 without the custom678 adapter.
The first post-boot log pull returned an older678 preview; a fresh timestamped
readback confirms native669 and repeats the non-MainLike builder invariants.

The nonembedded live trial preserves SB352/start1793010315.371838 and
BBD61/start1793010240.987467. The real renderer target equals the leased
UIScreen and reports embedded=false; native factory callbacks execute.
However actual provider is STUIStatusBarVisualProvider_Fallback and status
content is absent. Original component/identity restoration verifies and
restores DynamicSplitSmallIsland. A missing/incorrect per-screen idiom/trait
context is a hypothesis; it has not been read back or corrected. Do not call
this native status acceptance.

The user's further acceptance findings remain open: lock-screen button outer
size looks correct but its glyphs are oversized; landscape Home loses its
wallpaper; status is not Duo; Control Center modules/content sizing is wrong.
Snapshots show the wallpaper root controller still supports portrait mask2
while Home and other scene windows support30, including during landscape.
Do not patch each controller/button geometry to mask this shared inconsistency.

**Touch priority (2026-10-26):** user requires both panels' displayed and
hittable regions to coincide. Apple device metadata: outer primary surface1,
1398x2034@3=466x678, nativeOrientation/nativeRotation0; inner primary-1 surface2,
2007x2853@3=669x951, nativeOrientation/nativeRotation270. The VM still exposes
one physical primary with nativeOrientation0. A native portrait framebuffer
alone does not validate that mounting and hit transforms agree.

At current669x951, host-socket taps at the observed right-column Maps center,
center Clock and bottom Safari produce no app launch in screenshots. A guest
logical-coordinate tap also fails visually. RPC enqueue acknowledgements are
not hit-test evidence. A clean restart with all experiment controls off resets
CA currentOrientation fromrot90 torot0, but the same right Maps tap still does
not launch it. Device.screen reports669x951/scale3 and interfaceOrientation0.
The generic device.ioreg inventory stops at depth5/300 entries, so its two HID
rows do not establish missing drivers or digitizer extents.

Next probes are observational only: device.input_devices enumerates HID
services and whitelisted geometry/report-descriptor properties, without
sending an event. A fifteen-second SpringBoard sendEvent observer records
native touch coordinates, receiving window/scene and hit view while forwarding
the original event unchanged; at most24 begin/end/cancel observations, then
conditional restoration. No visual profile changes are made during this trace.
Runtime input cause and inner/outer hit-range acceptance remain pending.

**Touch cause narrowed by native receipt (e237688b):** all four test taps
arrive in the correct669x951-point space. Pixel(1486,1398) arrives at
(495.3333,466), pixel(1162,2105) at(387.3333,701.6667), and pixel(660,2690)
at(220,896.6667). These include positions beyond the outer466x678 extent.
Each is delivered to SBStatusBarWindow / STUIStatusBarForegroundView instead
of Home icons. Thus the observed dead/limited Home interaction is a status
foreground hit-testing interception, not evidence that the digitizer clips
to the outer panel. Native trace restored after16 observations.

HID inventory enumerates19 services, including a display-integrated Virtual
USB Touch Screen. Its191-byte report descriptor declares four contacts and
X/Y logical range0..32767 (16-bit fields); it does not encode an outer-pixel
clip. Other report/service fields are observational. The first registryID
implementation incorrectly treated IOHIDServiceClientGetRegistryID's return
as uint64_t; the local SDK header declares a borrowed CFTypeRef. Correct it
to a CFNumber read; do not use initial pointer-shaped IDs as registry values.
This diagnostic error never altered input dispatch.

Next bounded native UI-profile experiment preserves the nonembedded identity
and inherits the phone idiom from the real Main UIScreen through native
_setUserInterfaceIdiom: plus native trait propagation. It touches only the
exact owned alias screen, with identity/Main-parent checks and saved original
idiom. The real Main screen is excluded. Restore the alias trait only after
original UI identity/component restoration and retain failed checkpoints.
Read back field and trait idioms before interpreting status provider output.
Additional status/foreground frame observations will distinguish native
layout from hit-test bounds. No touch coordinate remap, global Main flag or
per-button/window geometry patch is introduced.

**Native trait field versus published collection (2dc1eacf):** alias starts
with _userInterfaceIdiom=-1 and traitCollection.userInterfaceIdiom=-1. Native
_setUserInterfaceIdiom: changes the field to0, but the published collection
remains-1; provider remains Fallback. Static _updateTraits calls the native
_defaultTraitCollectionForInterfaceOrientation: and _setDefaultTraitCollection:;
run that rebuild before native propagation, rather than assuming field mutation
invalidates the collection.

Both managed/default status frames and native input trace expose the second
boundary: manager.defaultStatusBarFrame is{615,0,54,951}, but renderer/wrapper/
foreground and defaultStatusBarLayoutFrame cover{0,0,669,951}. The retained
legacy Main window also remains visible while the replacement component is
active. Complete the owned component handoff: after the replacement connects,
hide only the distinct saved old-profile window, saving its exact hidden state.
On rollback hide the owned replacement before disconnecting it, then restore
and verify the old component/window's saved visibility. No frame, hitTest method
or touch coordinate is changed. Trace now distinguishes saved-legacy and
managed-replacement windows. Whether this yields native Duo provider/rendering
and restores Home hit delivery remains pending runtime verification.

**Real native provider + hit-delivery result (bf9002f1):** _updateTraits
changes the published alias trait idiom to0. The native factory now selects
AxisAlignableSplit2007; actual foreground frame is{581,0,88,123.6667} instead
of full-screen. The distinct old-profile window is hidden only after native
replacement connects. Right and lower Home taps reach SBHomeScreenWindow /
SBIconView, and the bottom tap reaches SBFloatingDockWindow / SBIconView at
exact expected coordinates. Original visibility/component/idiom restore all
verify. The new logical screen still lacks visible native status data: do not
call an empty, correctly classified renderer native status acceptance.

Next controlled probe keeps the original physical Main, UI identity, status
wrapper and native state/data subscription. At constructor time only, install
the existing COW detour on the symbol-exported
STUIStatusBarGetVisualProviderClassForScreen. Its default path is unchanged.
An explicit eight-second pulse supplies canonical inner reference metadata
and bypasses only the embedded lookup cache on an isolated argument proxy;
the original native function must select AxisAlignableSplit2007. Native
construction continues with the real screen, and native wrapper forceUpdate:
refreshes the original subscription. No UI identity migration, component
replacement, Main flag override, class constant return or synthetic status
values are used in this new path. Behavior restores automatically. Result
remains pending actual screenshot/data/hit and process verification.

**Original-Main first pulse (f3d69e48):** constructor COW detour installs
successfully and canonical native lookups select the inner class, but actual
renderer still reports DynamicSplitSmallIsland. Do not claim this migrates the
renderer or supplies visible Duo status. Static ivar-backed tracing corrects
an earlier assumption: resetVisualProvider resets _regions, _displayItemStates
and _partAlphas; it clears neither _visualProviderClass nor the provider itself.
The corrected native reconstruction clears the cached class toNil through its
native setter (never assigns a chosen class), then calls reinitializeStatusBar
and the native wrapper's forceUpdate:. Record original actual provider class
and verify native restoration; retain pending checkpoints. Runtime output
remains pending. A white captured frame during the first pulse is not native
status acceptance and must not be interpreted as successful app presentation.

The user reports touch misalignment after rotation. Portrait event-coordinate
proof is not rotated acceptance. Add read-only host socket display.geometry:
configured pixels, actual capture pixels, VZ graphics pixels, view bounds,
aspect-fit display rect, frame rotation, screen orientation and whether mouse
clicks use the guest pointer. The UIKit trace additionally records touch type,
scene interface orientation and screen/scene coordinate-space bounds. Compare
the same full pipeline before/after each quarter turn; do not assume a width/
height swap or reuse portrait calibration. Both panels and rotation round trips
remain required. No host input-transform change is made before measurement.

**Rotation refusal reproduced (64a73aa0):** after the known native portrait
setup (SBS device pose3, gravity270), ordinary display.rotation orientation90
is refused. SBS pose remains3 and the catch restores gravity270. Host configured,
VZ graphics and captured frames remain2007x2853; host view rotation stays0 and
mouse_uses_pointer=false. Both host and guest touch paths deliver the same
(133.6667,285.3333) point for normalized(0.2,0.3). This refused request did not
enter landscape and therefore is not rotated acceptance. Existing API updates
gravity and AX orientation but never updates the active SBS pose override.

Add a native mapping bridge: SpringBoard exports its current scene's actual
q24 deviceOrientationForSystemSpaceOrientation: inverse map, scene/surface/bounds
and monotonic generation time to an owned atomic JSON file on an explicit
Darwin request. The daemon accepts only a newly generated SB-main record;
no prior-boot/stale map is reused. display.orientation_mapping reads it.
On iPhone19,4 only, display.rotation resolves the logical request through that
native permutation and synchronizes SBS device pose plus matching gravity,
preserving hinge/tabletop. The logical AX request remains unchanged. A failed
request restores owned pose/gravity and the previous interface/pointer state.
Other models retain the existing path. No generic gravity enum or host affine
transform is changed. A pure mapping regression matrix covers native cover
and inner tables, aliases and invalid maps. Runtime rotation/hits pending.

**User-reported real SpringBoard crash (2026-10-26 21:06:04):** newest IPS
SpringBoard-2026-10-26-210608.ips is PID294, launched21:06:02.1981, captured
21:06:04.6442. EXC_BAD_ACCESS/SIGKILL, EXC_ARM_PAC_FAIL, termination
PAC_EXCEPTION261. It is not a planned SIGTERM/SIGKILL reconstruction. Faulting
main thread: objc_msgSend(retain) -> libvphonefoldguard vpGuardedCopyRender+84 ->
QuartzCore CA::Context::commit_transaction first commit; receiver layer class
SBRecordingIndicatorSecureLayer. It predates this rotation API call. Trial
PID313 stayed stable through its own body, then cleanup created343, so body
PID checks alone missed this preceding real startup failure. Sanitized evidence:
Evidence/iphone_duo_foldguard_pac_crash_20261026.json; full IPS preserved locally.

Root cause is the existing FoldGuard wrapper declaring the native C++
CA::Render::Layer* return as id. On non-null successful copies, ARC sends retain
to the non-ObjC pointer, causing PAC authentication failure. Exception/NULL
paths did not expose it on every launch. Correct both wrapper and original-call
return types to void*, use register-width non-ARC arguments with runtime ABI
validation (opaque pointer return, three pointer/integer GPR arguments), and
returnNULL on the existing exception fallback. Never apply ownership to the
opaque result. Host fixture deliberately returns a non-ObjC pointer and tests
argument forwarding, null/exception paths and incompatible ABI rejection.
A bounded successful non-null pass-through log supports runtime verification.
All new display/rotation experiments are paused until this crash fix passes
build, fixture and guest startup checks.

**FoldGuard verification (76b6ff90):** host pointer fixture passes7 checks;
complete VPhone build/admission passes. Guest logs confirm actual ABI
^v36@0:8^v16I24^I28 and unmanaged-pointer guard installation. Initial boot
PID37 and two controlled first-commit reconstructions (PIDs366,379) remain
alive; no new SpringBoard IPS appears, newest remains the21:06:04 PAC report.
Exception/NULL fallback is exercised on those launches. Non-null forwarding
is covered by the host regression fixture; no non-null runtime log was
observed in these three launches. This is bounded startup validation, not a
claim that every future crash is excluded. Display/rotation work can resume.

**Rotation transition isolated on crash-fixed76b6ff90:** publishing the native
90-degree plan (SBS device1 + gravity0) and allowing the native transition to
settle gives scene/interface4, activeInterfaceDegrees90 and host view rotation
-90. A subsequent same display.rotation90 succeeds. Immediate forced AX
rotation/early verification races this transition. Duo now waits up to2s for
actual native interface receipt after synchronized pose/gravity instead of
issuing a competing AssistiveTouch rotation. On failure owned physical state
restores and native restoration is awaited; ordinary devices keep their AX
path. Reply degrees/name use the verified logical receipt, while pose is read
back independently. Runtime multi-angle/touch acceptance remains pending.

**True landscape receipt (86eea0ac):** rotation90 now succeeds with native
physical pose1, gravity0, interface4/90 degrees and host view-90. Logical
screen is951x669 while VZ graphics/raw capture stay2007x2853. The two raw
fixed-panel injection paths agree at(665.6667,133.6667) in the landscape
window for panel-normalized(0.2,0.3). This establishes true landscape entry
and consistent raw paths; it is not yet full screenshot-coordinate acceptance.

A separate host contract bug is confirmed in source: the full `screenshot`
command saves vphoned's upright JPEG, but tap/swipe previously normalized its
pixel arguments against the unturned boot panel. The compact/raw VZ capture
used by display.geometry is different from that full screenshot. Add the
shared top-left screenshot->fixed-panel inverse to VPhoneDisplayOrientation
and use it for both windowed/headless tap/swipe; preserve one geometry for an
entire swipe. Prefer actual VZ panel dimensions and current guest orientation,
with the displayed view orientation only as the disconnected window fallback.
Geometry diagnostics now distinguish upright screenshot pixels/input angle.
Regression tests cover both native Duo panels through all four directions.

After native Duo pose settles, reassert only the same accepted AX angle to
refresh Icli's cached screenshot geometry and pointer state. This uses the
already-successful order from the isolation trial, rather than issuing AX
while the pose is still transitioning. Rollback similarly reasserts only after
native restoration settles. Runtime screenshot-coordinate matrix pending.

Input audit also finds that sendTouchEvent snapped every near-edge down to
normalized0.001/0.999 when guest edge-touch support was present. A normal tap
within the32-view-point edge zone could therefore move off its visible target.
Preserve the actual normalized point; retain native edge flags. Deliberate
trackpad home gestures already select an edge point in snappedScrollStart.
Validate a near-edge logical point through all four orientations and both
panels rather than accepting only center taps.

Extend the same original-Main native status lookup to the verified native
cover bounds466x678 /1398x2034, using the native
AxisAlignableSplitV68Cover profile's own notch metrics and requiring the
original factory to select that class. Main/root/scene identity stays exact;
no alias, second display, frame or input rewrite is introduced. This enables
independent outer-panel acceptance with the same mechanism. Outer runtime
provider/data/hit result is still pending; no claim is based on build alone.

**db26a8cc live inner screenshot-input matrix (2026-10-26):** exact bundle
binding and update-environment status0 verified. First rotation90 attempt
failed the two-second native settle deadline; no input matrix was accepted.
Explicit cleanup restored baseline. A fresh controlled trial with three more
seconds before the first rotation passed0/90/180/270. At each angle the upright
screenshot pixel(60,1050) delivered Home-window point(20,350), identically for
host tap and independent normalized fixed-panel injection. All16 Home touch
begin/end records match exactly. SpringBoard PID363/start1793023069.980664
remained unchanged across the matrix; cleanup then reconstructed baseline.
Evidence: Evidence/iphone_duo_inner_four_direction_touch_20261026.json.
This validates one near-edge point on the native inner panel, not full-area
coverage or outer-panel acceptance. The initial settle failure remains an open
startup timing issue; adding a test delay is not a production fix. Native
status and single-inner readiness remain controlled/default-off preparations.

**Outer baseline db26a8cc:** selected Closed via native Fold Posture UI and
restarted only duotest-m5. CADisplay1398x2034, main/UIScreen466x678@3 verified.
Native cover status lookup selected AxisAlignableSplitV68Cover, but screenshot
had no visible status content and a side-positioned Dock; this is NOT UI
acceptance. SB-main reports surfaceType0 rather than native cover1. First
near-edge touch reached Home at(20,100); later queued taps did not yield enough
observations to accept coverage. Next experiment should validate Main's cover
role before changing component widths. Runtime switching is still unproven.

Cleanup: removed the retired CADisplay displayType/pointScale promotion
implementation (owned virtual panel -> builtin), which previously triggered
cloning assertions. Stale one-shot markers are consumed and logged without
installing any hook. This does not remove UI-derived identity research or
change the one-physical-Main constraint.

Next bounded cover experiment uses the already traced extendedProperties ->
BKSDisplayTraits -> ShellSceneKit source path, with DeviceSurfaceType1 on
primary only. surface.cover has the same30-second lease as inner; generation
prevents an older lease timer undoing a newer test. Reconstructing SB samples
metadata for this diagnostic only; it does not prove live panel switching.

**c6f0cdbe cover-role result:** exact install/binding/environment bundle verified.
SB PID286 read surfaceType1 with466x678pt /1398x2034px, root/interface1.
The screenshot still has the side Dock and no visible status module. A lower
right host screenshot tap reaches(446,600) exactly, but is received by
SBWindowSceneAuxiliaryContentWindow. Thus correcting cover metadata alone
is insufficient for outer UI acceptance. Investigate native content-mode and
auxiliary-window ownership next; do not replace this failure with width hacks.
Evidence: Evidence/iphone_duo_cover_role_state_20261026.json and
iphone_duo_cover_role_incomplete_20261026.png. No live switch proved.

**Correction after pose + render-settle verification:** the previous
immediate screenshot was insufficient to declare cover status rendering
broken. Re-publishing fullyClosed/portrait after SB reconstruction selects
FullyClosed, Ready To Resolve YES, legacyMain cover applied/target
primaryContent WITHOUT adding a cover readiness override. A fresh original
Main status pulse followed by1 second settling shows native time and ring
battery/data visibly. Evidence: iphone_duo_cover_status_settled_20261026.png;
resolver detail /tmp/duo-cover-content-policy/runtime.log. Cover Dock remains
on the side; there is no supplied true-cover reference establishing that
layout as incorrect, so do not hardcode the inner Dock placement. Prior
auxiliary-window interception is not invariant: closed-pose trial lower-right
(446,600) reaches SBHomeScreenWindow/SBIconListView. Native status is still
pulse-only and runtime panel switching remains unverified. Next production
work must replay current fold pose after SB reconnection, wait for native
render state, and preserve separate native inner/cover profiles.

**Pose lifecycle implementation (runtime pending):** GuestFoldPose now observes
com.apple.springboard.finishedstartup and retries the latest actual pose at
0.5/1.5/3 seconds on a serial utility queue. Explicit posture/rotation requests
invalidate pending generations before publication and record the final SBS
readback afterward, including rollback on failure. Replay leaves hinge angle
untouched, skips already matching state, and only runs with an enabled hinge.
The existing boot ladder remains; this adds SB-relaunch handling rather than
making the boot snapshot permanently authoritative. Full VPhone build passed;
live closed/nonportrait replay and superseding-request acceptance still needed.

**290da141 runtime pose replay accepted:** installed/bound/environment version
matched. Two separate SB-only reconstructions preserved exact SBS pose:
closed + device1 and closed + device3; before/after orientation, hinge and
tabletop match. Final explicit closed/device1 restored. Evidence:
Evidence/iphone_duo_pose_replay_20261026.json. This proves lifecycle replay,
not runtime logical panel switching; overlapping-request timing remains a
separate validation case. No screen layout override was added.

**Runtime viewport reconciliation:** old vpUpdateRootSceneGeometry changed
only sb_hostedDisplayConfiguration + frame, whereas the later verified native
UI migration required both displayConfiguration and its hosted extension.
Update the same-Main viewport path to validate both setters before mutation
and publish the same configuration into both. Identity/render source remain
unchanged. This closes a concrete state inconsistency; runtime switch and
render/input geometry acceptance must still be re-run on native inner backing.

cf557df1 runtime preserved SB PID37 through669x951 ->466x678 ->669x951.
Cover scene type31, but UIScreen/global type32 and Home window669x951; image
clipped. IMPORTANT: paired configuration update did NOT execute: generated
setDisplayConfiguration: encodes its object class name, so the initial exact
encoding check rejected it. Corrected to the semantic NSMethodSignature
validation already used by vpSetUISceneConfigurations. This run therefore
cannot reject the paired-update hypothesis. Explicit inner restore completed.

**0cd9e242 paired update actually executed:** native settings transactions
updated all3 root scenes; scene sizing notified18 windows, changed15. Main,
UIScreen, Home-window/root bounds now roundtrip669x951 ->466x678 ->669x951,
SB PID37 unchanged. Cover rendering still fails: widget top clipped, overlapping
Dock, fixed physical2007x2853 backing has black unused area. Scene family31
changes correctly, while UIScreen/global families remain32. This confirms the
previously identified per-screen associated-object/global dispatch_once cache
boundary is now material for runtime switching. Do not overwrite cache slots
or hardcode widget sizes; the next experiment should re-evaluate native screen
classification from the active scene context and then verify native layout
invalidation. Evidence: Evidence/iphone_duo_paired_viewport_20261026.json and
paired_viewport_incomplete image. Explicit inner restore completed.

Native family cache experiment: consumed-once viewport-family marker installs
export-resolved per-screen/current-device lookup adapters. Only during an
explicit cover viewport lease, on the main thread, for exact SB-main/Main
screen, re-query SBHScreenTypeForDeviceAndDisplayContexts using that scene's
native device/display contexts. Other callers fall through; recursion guarded.
No associated-object or dispatch_once cache writes and no component dimensions.
Accept only native Duo31/32 results. Runtime call/visual acceptance pending.

**0d172c0d family experiment:** installed/bound/environment matched. Startup
screen detour0(OK), global detour2(Unrelocatable) — refusal preserved, not
bypassed. Same SB PID293 roundtrips. Cover families global32/screen31/scene31,
restored32/32/32. Thus native scene-context reclassification successfully
crosses the per-screen cache boundary, but global cache remains and visual
clipping/Dock overlap persists. No full-family or layout acceptance. Evidence:
Evidence/iphone_duo_viewport_family_20261026.json. Explicit inner restore done.
Next analysis must inspect the native global lookup entry and/or layout
provider lifecycle; do not guess a trampoline or overwrite dispatch_once data.

**Global entry relocation reveal:** symbol-backed disassembly of current
SBHScreenTypeForCurrentDevice starts ADRP/LDR/CMN/B.NE; fourth instruction
branches to its dispatch_once slow path, outside overwritten16 bytes. Extend
MISFixDetour with ordinary B.cond relocation: invert condition over existing
absolute x16 jump; preserve NZCV; reject conditions AL/NV, BC.cond and targets
inside overwritten region. No offset-specific patch or dispatch_once write.
ConditionalBranchRelocationTests.c checks all14 ordinary conditions with
positive/negative targets and rejection cases; native arm64 executes both
NE taken/fallthrough paths (22/11) successfully. Guest acceptance pending.

**c75a6a9a guest result NOT accepted:** exact deployment version matched;
consumed viewport-family marker installed both detours (screen0/global0).
Before entering cover transition, the first snapshot notification stalled,
and subsequent process/file RPCs also stopped responding. No fresh SB IPS
was present after recovery (latest remains210608). Stopped VM via Launchpad,
waited for stopped state, restarted without consumed marker: vphoned answered
in4s and file/device RPCs recovered. This is a hang, not established crash or
proof of a specific relocation bug. Native host branch tests do not establish
correctness of this complete guest call graph. Do not promote global adapter
to default. Need blocked-thread stack/targeted recursion evidence before more
changes; preserve /tmp/duo-full-family-recovery.log and failed trial outputs.

Hang follow-up: symbol-backed slow-path disassembly confirms global getter
branches to a dispatch_once helper; it does not itself establish recursion.
Add bounded raw append records around original trampoline and native-context
query (first24 calls), with PID/depth/stack addresses, no Foundation formatting.
This distinguishes original-getter blocking from context-query reentry without
rewriting caches or suppressing initialization. Runtime evidence pending.

Diagnostic refinement: record only the compiler-provided immediate caller
address instead of backtrace unwinding, avoiding loader/unwinder activity in
the suspected once-initializer path. Phase/depth remain the primary evidence.

**7afd766f trace + full-family runtime:** first24 global calls all show
enter-original -> returned-original32 -> returned-context32, depth1. Guest
screen/file RPCs remain responsive. Then same PID293 performs full family
roundtrip32/32/32 ->31/31/31 ->32/32/32 with native point bounds changing and
restoring. Prior hang did not reproduce; cause remains unresolved (do not call
it a proven relocation bug or a proven timing fix). Visual cover layout still
clipped/overlapping despite all family queries agreeing. Family-only root-cause
hypothesis is insufficient. Evidence: iphone_duo_all_family_roundtrip_20261026.

Next static candidate: SBIconController.listLayoutProvider is a native tail
call to ambientListLayoutProvider; the latter is retained state with a setter.
SBHDefaultIconListLayoutProvider exposes initWithScreenType and immutable
screenType, and SBIconListView has setLayoutProvider. These are evidence for
existing layout-object lifecycle investigation, not authority to force widget
sizes, reset Home icon arrangement, or swap arbitrary providers yet.

**Native layout lifecycle reveal:** SBHIconManager retains _screenType and
_listLayoutProvider. Its setScreenType:listLayoutProviderLayoutOptions:animated:
checks changes, constructs the native provider with that family/options, calls
setListLayoutProvider:animated:, then reaches rootFolderController/view/window/
windowScene and floatingDockViewControllerForWindowScene:. Use this existing
system manager entry after the scoped native scene-resize propagation. Preserve
layout options; use the scene's native31/32 result; verify method/ivar ABI and
exact SB-main/Home controller. No resetHomeScreenLayout or per-icon dimensions.
The same path restores the native inner provider on return. Runtime pending.

**afa31362 native layout lifecycle runtime:** first deployment was interrupted
when Launchpad exited; process inventory confirmed no remaining CFW task and
old environment version, then retry succeeded with exact bundle/status0.
Controlled switch retained SB PID292. Manager log32->31 creates native D76
provider, return31->32 creates D77. All3 family queries match. Cover screenshot
now shows complete widgets and reflowed icon grid without Dock overlap, unlike
family-query-only experiments. This is concrete native layout progress.
Remaining: physical2007x2853 screenshot contains active1398x2034 cover region
and black unused area; status pulse not enabled; host viewport/capture/touch
must follow logical extent before usability acceptance. Explicit inner return
completed. Evidence: iphone_duo_native_layout_roundtrip_20261026.json and
iphone_duo_native_cover_layout_viewport_20261026.png.

**Geometry source correction:** afa31362 cover device.screen still returned
669x951 despite live SB configuration/screen466x678. Do not base host viewport
on this Icli cached extent. Extend existing fresh orientation-map handshake
with canonical configurationBounds, coordinateBounds, scale, UIKit orientation
and viewport generation in the same main-queue record; expose display.geometry
as a read-only alias. Host physical framebuffer remains independently known.
Consumer integration and live snapshot acceptance pending.

**Host viewport coordinate implementation (runtime pending):** add shared
VPhoneDisplayViewport separating active canonical pixels from fixed panel.
Fresh display.geometry provides active bounds/scale/UIKit orientation. Socket
input converts upright cropped coordinates using active extent, then normalizes
against full physical panel. Full screenshot validates geometry before/after,
checks full upright image dimensions, and crops the rotated active rectangle;
legacy full-panel path remains when fresh geometry is unavailable. Four-angle
crop/input equivalence and invalid-bound tests passed (2 Swift Testing tests).
Native GUI clipping, transition generation validation and live touch/capture
acceptance remain outstanding; do not label windowed GUI accepted.

**ae8d0e56 cropped automation runtime:** install/admin authorization and exact
binding/environment confirmed. First preparation screenshot refused unstable
geometry; stable retry produced cover1398x2034 and restored2007x2853. Four
host screenshot pixel taps(60,300),(1338,300),(60,1800),(1338,1800) arrive at
UIKit points(20,100),(446,100),(20,600),(446,600). Baseline full-size old status
intercepts all; with native Main status pulse, three hit Home and upper-right
hits native status foreground. Cropped image has no unused black canvas.
Status content not visible in captured image; native GUI crop and rotated
viewport live acceptance remain pending. Inner return executed. Evidence:
iphone_duo_cropped_viewport_touch_20261026.json / iphone_duo_cropped_cover_20261026.png.

**Actual GUI touch failure reproduced:** CUA clicked the visible Settings icon
in the native VM window. UIKit received(388,703), correct for that icon, but
SBStatusBarWindow/STUIStatusBarForegroundView still covered669x951 and consumed
both phases. Thus prior pulse acceptance did not fix everyday operation.
Promote the verified original-Main native status profile to persistent startup
on exact hw.machine=iPhone19,4 only (manifest-gated library). Register finished-
startup plus bounded startup retries; keep existing single-Main/native-size
checks. Reconstruct status natively after viewport scene sizing. Legacy restore
notification refreshes the persistent profile instead of restoring the broken
fallback; other models retain original behavior. Runtime GUI acceptance pending.

**2f446502 persistent GUI acceptance:** exact bundle/environment deployed.
Initial update refused stale Launchpad disk holder; lsof no longer showed
that holder and retry succeeded. Without any main_status pulse, startup
selected persistent native inner provider and top-right time/ring displayed.
CUA clicked Settings in the actual VM window: point(387.6667,702.3333) hit
SBHomeScreenWindow/SBIconView instead of the former full-screen status view.
RunningBoard verified com.apple.Preferences PID323 foreground; visible Settings
rendered. A second actual-window click opened About. Evidence:
iphone_duo_persistent_status_gui_touch_20261026.json and settings screenshot.
This accepts default inner portrait GUI interception fix, not all touch modes
or outer/rotation/no-restart panel switching. Current guest remains usable in
Settings; no temporary status lease was needed.

**Native GUI viewport integration (pending runtime):** container now rotates
an active clipped viewport while retaining the full physical VM view at the
same scale/top-left anchor. Mouse AppKit conversion therefore still reaches
physical-panel coordinates. View orientation follows the enclosing clip turn;
pointer normalization accounts for active/panel ratio. Foldable window polls
fresh geometry, accepts exact native inner/cover extents within its backing,
and adjusts aspect ratio. Other guests retain full-panel extent. Native GUI
click/rotation/edge gestures still require live validation; automation-only
acceptance is not substituted.

**22357146 native GUI cover acceptance:** deployed exact version. During the
same SB process's controlled cover viewport the actual VM window crops black
unused backing and shows native cover Home with ring/time. CUA Settings click
hits Home SBIconView at(233,578); RunningBoard verifies Preferences PID343.
Settings fills active cover, and actual-window General-row click navigates.
Timed inner restoration exposed an additional gap: SB/window regained669x951
but already-open Settings retained cover-sized scene, leaving black area.
Re-entering cover fills it again. Need foreground application scene transition
propagation, not per-app hardcoded sizing. Explicit inner+Home restored.
Evidence: iphone_duo_native_cover_window_touch_20261026.json/settings image.

Application-scene propagation investigation: root SB scene frame update does
not resize existing foreground app scene. SBMainWorkspace exposes native
createRequestWithOptions:displayConfiguration: and requestTransitionWithOptions:
displayConfiguration:builder:. Request carries applicationContext/from/to
entities and layout coordinator; SBWorkspaceApplicationSceneTransitionContext
supports waitsForSceneUpdates and requested layout attributes. Add a separate
workspace.preview notification that ONLY creates the native default request
and logs current/request context/entities. It never finalizes/submits/runs a
transaction. Verify preservation of foreground state before a mutation trial.

b26933d4 preview runtime: native request factory succeeds for Main669x951,
but a newly created/unfinalized request has empty application context/from/to
entities even with verified Preferences PID310 foreground. No transaction
submitted. Static method review found the diagnostic read current layout from
the wrong object: SBLayoutStateTransitionCoordinator has no layoutState getter;
SBSceneLayoutStateProvider owns layoutState/previousLayoutState. Correct preview
to scene.layoutStateProvider.layoutState and include object classes/scene ID.
The earlier null does NOT prove absence of current native application layout.

c1ff6b18 current-state readback succeeded: SB-main layoutStateProvider holds
one primary element sceneID:com.apple.Preferences-default, full space,
maximized/system-managed sizing. Native SBLayoutElement exposes workspaceEntity
and layoutRole. Extend unsubmitted preview to copy that same single entity/
role into previous+target context, then invoke native local request finalize.
Static base finalize binds context.setRequest and context.finalize; no workspace
submission. Read from/to/layout after finalization before any transaction trial.
No app frame write, no app reset/relaunch.

265d61f3 finalized preview preserved primary sceneID:com.apple.Preferences-
default in both from/to and full-screen layout, but native default attributes
lost prior contentOrientation/interaction metadata. Preserve existing native
layoutAttributesForElement via setRequestedLayoutAttributes:forEntity before
finalization. Add separate controlled workspace.refresh submission: require
one application entity, primary role, identical from/to uniqueIdentifier,
unchanged current layout object/display configuration, and prior viewport
request generation. Call native executeTransitionRequest only after guards.
No per-app code/frame, relaunch or default-on submission. Runtime pending.

**a81fcd09 native app transaction runtime accepted:** exact installed/bound/
environment version. Both cover and return workspace.refresh submitted=1 for
same sceneID:com.apple.Preferences-default. Settings PID317 stays foreground
through all3 stages; SB geometry PID stays constant. Cover screenshot shows
narrow navigation layout; inner return shows full dual-column Settings without
prior black app region. Native layout attributes preserved. Evidence:
iphone_duo_app_scene_roundtrip_20261027.json + cover/inner_return PNGs.
This proves one same-app controlled roundtrip, not persistence/rotation/multi-
app acceptance. Next integrate guarded refresh into viewport completion and
expose persistent fold switching; retain one physical Main.

**Persistent fold integration (runtime pending):** exact Duo now installs the
verified family adapters by default with its native status profile. New apply.
cover/inner notifications enable persistent viewport (no45-second rollback),
coherent scene sizing, native icon-manager family change and guarded native
foreground-app refresh after scene propagation. display.posture posts desired
viewport and waits up to3s for fresh matching canonical bounds + persistent
flag. Startup/relaunch pose restoration republishes viewport. Host always boots
one2007x2853 Main, including closed boots; active cover remains1398x2034 crop.
Disable old fold blackout chrome on Duo and update Fold Posture explanation.
No second physical display, no runtime VZ resize. Native GUI/persistence/rotation
acceptance remains required; successful build is not goal completion.

**e4c3c421 formal control acceptance:** exact install/binding/environment.
Used native Fold Posture GUI Closed -> Open -> Book -> Open, no once markers
or diagnostic notifications. Closed466x678 remained persistent at least53.56s
after initial read (beyond old45s lease). Open/Book669x951. SB PID37 unchanged;
Settings PID306 unchanged and visually narrow cover/full dual-column inner.
Native icon provider and preserved-entity app transactions ran automatically.
Final control restored Open. Evidence: iphone_duo_persistent_fold_controls_
20261027.json plus persistent_cover/inner PNGs. Goal not yet complete: rotation,
repeat-cycle/relaunch/cold-closed restoration and retired-path cleanup remain.

**Production rotation audit:** e4c3c421 display.rotation90 without experimental
flags failed native settle deadline. Current logical inner669x951 scene still
reports default surface0; prior rotation success depended on inner role2.
Add consumed-once logical-role experiment at SBWindowScene.surfaceType (native
q16 ABI), deriving2/1 only for exact SB-main/Main and canonical669x951/466x678.
Keep original hardware source/role/count and resolver untouched; reentry guard,
original fallback elsewhere. This tests logical scene capability selection,
not a forced frame/orientation. Persistent enablement, startup pose mapping and
cross-panel orientation preservation require validation before promotion.

**604ff90e logical-role trial:** one-shot SB-main role returns2 and native
inverse mapping changes to[3,4,2,1]; Home/status masks become30. BBD rotation
events enabled, primary supports rotation. display.rotation90 still times out.
After publishing device1/gravity0 and native inputs.refresh, fresh scene reads
interface4 but coordinate bounds remain669x951; legacy global orientation wait
still refuses. Captured image is physical portrait with rotated Home, upright
status and missing wallpaper. Thus scene-role adaptation alone creates mixed
orientation domains and is NOT accepted. Restore open/device1/gravity0, recreate
SB without consumed marker; default source0 retained. Need coherent root/legacy
orientation, scene coordinate and wallpaper update, not forced enum mappings.

Rotation follow-up cross-check: icli_interface_degrees reads legacy SpringBoard
orientation, separate from the newly exported scene interfaceOrientation.
Historical native per-scene status policy(896e6d1e) followed Home orientation
correctly but used wrong provider/data configuration. Current persistent Main
native Axis profile fixes that prior status profile boundary. Retarget only
that existing one-shot scene-status scope from obsolete678x951 to accepted
669x951, for a combined logical-role + native per-scene-status trial. It remains
default-off. Wallpaper/root settings/capture orientation must all be checked;
do not equate one corrected direction getter with successful rotation.

397e50d9 combined trial: per-scene status window and Home both rotate4 at
951x669; visible window still lacks time/wallpaper. GUI Settings click correctly
maps to landscape(666.67,573) but hits auxiliary-content window. Read-only
resolver shows decisive mismatch: FoldingDual prevailing, readyYES, sole
legacyMain proxy surface.default with applied/target unknown; primary/active
scenes nil. This contradicts scene.surface.inner. Restored default via SB-only
restart after device1/gravity0. Do not promote this combination as working.

Next one-shot logical-role experiment synchronizes that existing sole
legacyMain proxy using its native setSurfaceType: and resolver update, with
single-source/Main/nonexternal/native-size/ABI guards. Reuses existing native
single-panel readiness boundary, no extra source. Synchronize again after
viewport scene sizing. This tests consistent logical role across scene and
content resolver instead of bypassing auxiliary-window hit testing. Pending.

**985fa8f7 logical-role/resolver trial:** sole legacyMain proxy becomes.inner,
FoldingDual resolves applied/target primaryContent and primaryWindowScene is
SB-main. After native device1/gravity0+inputs refresh, scene4 and UIScreen951x669
read back. Actual GUI landscape Settings icon click opened verified Preferences
PID380; trace expired before click (recorded0), so no new point-level hit claim.
Formal display.rotation90 then succeeds with mapped physical1/gravity0. Native
landscape Settings visibly renders. Time absent and Home wallpaper still black;
combination remains default-off. Capture saved; cleanup open/device1/gravity0
and unarmed SB-only reconstruction restores production inner. Need status data
subscription and wallpaper lifecycle, not input coordinate hacks.

Native presentation investigation: per-scene STUI wrapper can differ from
UIApplication.statusBarForEmbeddedDisplay; UIStatusBar_Base exposes native
inProcessStateProvider/server and SBMainStatusBarStateProvider has time/all-but-
battery cloak states. Wallpaper controller exposes active sources/required/
traits-active state and native window/presenter/container. Add read-only
presentation.inspect comparing both bars and wallpaper state. No cloak writes,
provider replacement, fabricated status values, or wallpaper drawing. Runtime
comparison of production versus role/scene experiment pending.

7e87cc74 comparison: production scene/embedded bars are the same wrapper/server,
with nil inProcessStateProvider. In role+scene experiment they are distinct
wrappers and distinct UIStatusBarServer clients; provider remains nil, updates
enabled. Wallpaper window/container remain669x951 while scene rotates; both
normal/experimental required/traits-active flags are0, so blanket visibility
forcing is unsupported. Active source changes LockScreen+Home to Home only.
Restored unarmed production after reading. Add eight-second default-off native
server/client binding test: redirect existing embedded Main server to visible
scene bar, temporarily detach its other server, force native data update, then
restore exact owned bindings. No data fabrication/cloak writes or new server.
Runtime acceptance pending.

f0609c2b data-server lease trial did NOT apply: no lease-entry log, unchanged
scene/embedded server pointers in before/applied/restored snapshots, time absent.
Cannot reject data-binding hypothesis from a refused probe. Add explicit scope/
client-binding/ABI rejection diagnostics and semantic object-argument signature
checks (generated setters may include class spelling). Restore now logs actual
readback verification rather than unconditional restoration wording. Trial
cleanup returned unarmed production; no data lease persisted.

**c2f9d947 guard result:** lease refused because embedded Main server client
is nil, while scene server client matches its visible bar. No binding changed.
Native UIStatusBarServer has only client/source fields; setStatusBar tears down
its existing source before assignment. Do not weaken guard and describe the
inactive object as a known-good active Main data channel. Remove this unexecuted
server-reuse pulse/notification and add read-only homeItemsDisabled, registered,
foreground/hidden and server-client comparison to presentation.inspect. Current
trial automatically restored unarmed production. Time issue remains unresolved.

4ce7a072 registration comparison: visible per-scene bar registeredYES,
foregroundYES, hiddenNO, serverUpdatesDisabledNO, homeItemsDisabledNO. Embedded
old bar hiddenYES/registeredNO/clientnil. Thus home-items-disabled hypothesis
not supported. Add scoped native registration refresh (disable server updates
then restoreNO in finally, forceUpdateDataYES) and read-only renderer data/
part-list descriptions. No data editing, old-server reuse or cloak changes.
Current comparison trial ended with unarmed production restored. Pending live.

419bdab4 reregister actually ran, but before/applied/settled timeEntry stays
NO/nil in both visible scene and inactive embedded renderer; part lists nil.
This is upstream data absence, not rendered text clipping or registration flag.
Add read-only actual app.mainStatusBarStateProvider cloak flags and native
statusBarStateAggregator date-provider/token/formatter/time-string state.
Separate default-off clock.refresh calls the native _restartTimeItemTimer only;
it does not write time values, enable entries, or clear cloak policy. Runtime
before/after acceptance pending. Comparison cleanup restored normal production.

750ccd86 native clock restart did not repair time: experiment source string
empty, all cloak flags false, formatters present; normal unarmed comparison
source string1:40AM. Thus not an intentional cloak and not fixed by subscription
restart. Add native date/formatter format/style/locale diagnostics. Narrow the
existing per-scene constructor experiment's temporary Main override to one
query, restoring native predicate for subsequent nested construction queries;
log caller address. This tests accidental initialization scope without writing
time values. Still default-off; runtime behavior pending.

d8df21eb single-query scope did not restore time. Normal and experimental
native dates are valid, locale=en_US, formats h:mm a/h:mm and styles match;
normal cache contains1:46AM while experimental cache empty. Add native formatter
output observation and a first20-call pass-through observer around aggregator
_updateTimeItemsWithDate: (only logical-role experiment), logging input date and
before/after cached string. No argument/result mutation. This distinguishes
empty formatter output from later lifecycle overwrite; runtime pending.

42a22028 trace: formatter direct output1:51AM is valid, while first20 native
_updateTimeItemsWithDate callbacks print empty input/before/after at same instant,
caller223326864 (the native minute-provider callback). Static callback retains
its x1 argument and passes it as date; SBFOverridableDateProvider owns dictionary
of minute handlers and _fireHandlersForDate. Add actual input/current-getter
object class and NSDate-kind checks; do not substitute a date or patch callback
ABI before confirming the invalid argument. Trial cleanup restored default.

457e820d callback type evidence: empty-rendering input is __NSDate/isDateYES,
while provider-current getter is valid __NSTaggedDate. This is not an object
ABI/type mismatch. Add exact reference-date interval as a string (preserve
nonfinite evidence without invalid JSON), underlying provider class and getter
date. Do not replace callback argument until numeric invalidity is established.
Trial cleanup completed, production default restored.

**f7d145ca root-cause reveal:** callback NSDate interval=+inf; provider and
underlying SBFMachNextMinuteDateProvider.date getters return valid current dates.
Symbol-backed native scheduler1baea2614 loads referenceView.window.windowScene.
screen.maximumFramesPerSecond and computes1/FPS when referenceView exists;
only nil reference takes zero frame adjustment. Detached live reference yields
nil screen/0 FPS -> infinity -> invalid callback date and rapid timer repeats.
Add one-shot role-experiment wrappers for native minute registration/tick:
if reference exists but cadence unavailable/nonpositive, temporarily clear its
runtime-located weak slot, invoke untouched native operation, restore weak slot
in finally if still nil. This selects the native nil-reference path, not an
invented date/frame rate. Valid attached references pass through. Runtime pending.

**4e40b3b6 clock reference runtime:** initial deployment unexpectedly reproduced
old f7d145ca hash; source/build audit found new functions unreferenced because
constructor insertion had not landed. Connected installation explicitly; unused
warnings gone, dylib SHA changed tode3bc9a8031d57ff59d417c3f065f7772ea81b05ad431855d93967e136f1735b.
Corrected exact bundle deployed. Runtime logs confirm adapter installation and
STUIStatusBar_Wrapper reference with nil screen/FPS0. Subsequent date callbacks
finite, native source string2:11AM, then minute update timeEntry enabledYES2:12AM
and visible time above native ring. No fabricated date or FPS. Early snapshots
had no renderer data until minute post; initial delivery remains unresolved.
Trial cleanup unarmed. Evidence: iphone_duo_clock_reference_fix_20261027.json
and iphone_duo_scene_clock_recovered_20261027.png.

Presentation lifecycle follow-up: wrapper.forceUpdate:YES only invokes its
_updateWithData:nil force:YES; forceUpdateData:YES separately reads native
server data and converts it. After renderer reconstruction request native data
before layout refresh; existing bounded startup retries also retry when renderer
currentData remains nil. No field synthesis. Add separate eight-second wallpaper
orientation probe using existing controller willAnimateRotationToInterface-
Orientation:duration:force: with actual scene direction, preserving original
controller direction and restoring through same API if scope/value still owned.
No wallpaper image or individual layer/frame mutation. Runtime pending.

cf3c0467 wallpaper pulse was NOT landscape acceptance: scene getter1 disagreed
with rotated Home; pulse changed wallpaper4->1 and made portrait background
visible under sideways Home. Separate root synchronization achieved root/scene/
Home/status4 but wallpaper remained black. Default restored afterward.

Native reveal: SBWallpaperController._updateWallpaperContainerViewBoundsFor-
Orientation first checks traits-active, then PBUIPosterWallpaperRemoteView-
Controller.supportsLandscapeWallpaperContents; that global method soft-links
PF_IS_PAD_DEVICE. A native per-display variant exists. Added one-shot scoped
adapter only around Main-inner wallpaper container update: ask native supports-
LandscapeWallpaperContentsForDisplayConfiguration with unchanged current Main
configuration instead of global idiom query. No forcedYES or iPad impersonation.
Wallpaper pulse now uses arbiter output, not stale scene getter. Runtime pending.

69f677e2 per-display wallpaper capability actual result global0/perDisplay0;
confirmed scene4, controller4->4 pulse does not restore wallpaper. Removed the
failed capability-query adapter. Further native reveal: _isTraitsArbiterWallpaper-
Active gates on SpringBoard/TraitsArbiterWallpaperTokyoDrift, then idiom/Maglev;
current guest SpringBoard feature-domain plist lacks this flag (TraitsArbiter
and TraitsArbiterActuation present). Add separate consumed-once exact-feature
lookup override for SB process only using existing checked detour; all other
flags/native behavior unchanged. This selects native pipeline for validation,
not a hardcoded wallpaper transform. No disk feature flag edits/default enable.
Runtime pending; prior experiment cleanup restored default.

7eda0424 native wallpaper traits flag test installed successfully(result0),
_isTraitsArbiterWallpaperActive=1, scene4, yet wallpaper remained black. A second
bounded trial also supplied real backboardd Main DeviceSurfaceType2; no visual
improvement. Waited beyond metadata lease before cleanup. Thus flag-only and
hardware-role-only explanations are insufficient. Add read-only wallpaper
window sb_traitsParticipant, delegate role-management decision, and loaded
presenter/root view geometry/visibility to locate missing native actuation.
No participant or remote view mutation. Default production restored.

dc7604a1 live participant evidence: traits-activeYES and delegate manages
wallpaperYES, but wallpaper sb_traitsParticipant=nil. Presenter/root views are
visible alpha1 at669x951; no zero-size/hidden-view explanation. Native
windowSceneDidConnect constructs _SBWallpaperSecureWindow with scene, but sets
SBTraitsParticipantRoleWallpaper through _setRoleHint only for idiom1/5 with
Maglev enabled. Add default-off exact-window pre-visibility role-hint assignment
under wallpaper traits + logical-role experiments, preserving existing hints.
Use subclass-only setHidden override and always forward original visibility;
no forced visibility/geometry or role on other windows. Native scene machinery
must establish participant and layout. Runtime pending.

### Active viewport touch mapping (2026-10-27)

The host display view keeps the physical Main framebuffer fixed while clipping the current Duo viewport. Input previously normalized against the full backing panel, so outer-screen taps could target hidden framebuffer coordinates. The VM view now derives a bottom-aligned active viewport from `activePanelPixels / screenScale`; mouse, trackpad, synthetic touch, and edge detection share that rectangle. Bundle `2.12.1-local.3803cc4d` was deployed to `duotest-m5`; real GUI clicks on the outer Settings screen and inner screen were accepted after switching without a restart. Focused `DisplayViewportTests` passed (2/2). Landscape rotation still requires broader edge and wallpaper regression before this issue is considered closed.

### No-restart native viewport roundtrip (2026-10-27)

On bundle `2.12.1-local.3803cc4d`, `display.posture` switched `open → closed → open` while SpringBoard PID stayed 37. Fresh `display.geometry` readback reported 669×951pt inner, 466×678pt outer, then 669×951pt inner, all at scale 3 with the same `SB-main` scene and no restart. Evidence: `Evidence/iphone_duo_no_restart_viewport_roundtrip_20261027.json`.

### Default landscape scene policy integration (2026-10-27)

The exact Duo path now enables the previously validated logical-role and per-scene status policies without once flags. These adapters preserve the single physical Main and only alter SpringBoard's native role/scene arbitration. Runtime validation is required for landscape orientation, status bar, wallpaper, and touch before treating the integration as accepted.

### Rotation arbitration refresh (2026-10-27)

The Duo inverse orientation map correctly resolves landscape-left to the inner panel's physical mounting, but publishing pose alone left SpringBoard at portrait. The existing native mapping/input/arbitration/actuation refresh notifications were therefore added to `display.rotation` after pose publication. A live notification sequence produced `display.geometry.bounds = 951×669` and `display.orientation = 90` with SpringBoard still running; formal daemon build/deploy and full touch/wallpaper/status regression remain required.

### Landscape wallpaper lease (2026-10-27)

Live diagnostics showed the wallpaper orientation pulse succeeded and then restored portrait after eight seconds, which recreated the black landscape band. The delayed restore is removed from the normal Duo path so the wallpaper remains on SpringBoard's current native orientation. Final screenshot and touch regression are required after deployment.

### Cover portrait, inner landscape posture (2026-10-27)

The Duo posture rule now matches the physical product: closed uses the 466×678pt cover in portrait; opening uses the 669×951pt inner configuration rendered as 951×669pt landscape (`interfaceOrientation=4`, `display.orientation=90`). The transition is runtime-only and keeps SpringBoard running. Evidence: `Evidence/iphone_duo_cover_portrait_inner_landscape_20261027.json`.

### Duo titlebar Fold Posture control (2026-10-27)

A Duo-only circular titlebar button now sits beside Home and cycles Closed, Book, and Open through the same `display.posture` RPC as the Motion Sensors › Fold Posture panel. Live CUA verification showed the button's accessibility value changing to Book and Open; fresh guest geometry remained the inner landscape viewport (`951×669` bounds, `669×951` configuration) and the real posture reply/hinge state changed accordingly.

### Lock-screen action glyph sizing (2026-10-27)

The oversized flashlight/camera glyphs share `UICoverSheetButton`. A system-level `layoutSubviews` adapter now scales only its child `UIImageView` glyphs to 0.82, leaving the lock-screen button circles and actions intact. Runtime installation was confirmed in `vphone-folddisplay.log`; a native screenshot request was made while the Mac host was locked, so visual pixel comparison still needs one unlocked-host capture.

### Host rotation state correction (2026-10-27)

The abnormal screenshot was caused by the host trusting stale `display.geometry.interfaceOrientation=1` while SpringBoard reported `display.orientation=90`. The host now reads the orientation endpoint first and uses fresh geometry only for viewport size, so window rotation, touch mapping, and notification/status presentation share the same landscape direction.

### Host landscape rotation verification (2026-10-27)

After a clean signed rebuild (`2.12.1-local.dc6752cc`) and reopening `duotest-m5`, live landscape readback was 90° with active bounds 951×669pt. The host window rotated horizontally, notifications became horizontal cards, the status battery/cellular region moved to the landscape right side, and real GUI taps hit flashlight and camera. Evidence: `Evidence/iphone_duo_host_landscape_rotation_20261027.json`. Wallpaper crop/black band remains separate.

### Glyph sizing follow-up (2026-10-27)

The first CoverSheet glyph transform was not accepted as evidence because the actual `UICoverSheetButton` layout callback did not yield a reliable glyph tree. Its guessed scale is removed from source; the next correction must use native Duo layout metrics rather than a hand-selected factor.

### FoldDisplay source maintenance split (2026-10-27)

The large guest hook source is now organized into include-only fragments: `StatusProfile.inc` owns status-bar provider/profile code and `WallpaperTraitsExperiment.inc` owns wallpaper traits code. The main file retains shared runtime state and constructor wiring. This is a source-only maintenance change; bundle admission and full build passed.

### CoverSheet native layout metrics (2026-10-27)

Static UIKit metadata shows `UICoverSheetButton` stores the glyph in `_contentView`, with `_image`, `_selectedImage`, `imageContentMode`, and `edgeInsets` controlling layout. A runtime hierarchy inventory while the guest was locked found zero visible instances through `UIApplication.windows`, so no arbitrary scale was deployed. Further work must capture the actual CoverSheet window/subtree or construction path before changing icon size.

### Real lock-screen quick-action layout (2026-10-27)

Runtime capture identified the actual Duo lock-screen path: `CSQuickActionImageGlyphView` inside `CSQuickActionsButton`. Native values were recorded from the initializer and final layout: button diameter 58pt, camera symbol scale 0.31648, flashlight symbol scale 0.368, 84pt button frame and 48pt icon image frame. Temporary diagnostics were removed after evidence collection; no arbitrary icon scaling is deployed.

### Wallpaper presenter frame correction (2026-10-27)

The landscape black band was caused by the poster presenter view retaining portrait dimensions. The wallpaper pulse now synchronizes the presenter view, container, secure window, and root view to 951×669pt and requests layout. Live presentation readback shows all four frames at 951×669 with identity transforms; the reasserted landscape screenshot fills the viewport. Evidence: `Evidence/iphone_duo_wallpaper_presenter_landscape_20261027.json`.

### QuickAction profile resolution (2026-10-27)

Runtime tracing reached the real SpringBoard QuickAction path. `CSQuickActionsButton` resolves `buttonDiameter=58`, `iconContentScale=1`, `iconImageSize=48`; `CSQuickActionImageGlyphView` receives camera `symbolScaleValue=0.31648` and flashlight `0.368`. These are native profile outputs. Temporary probes were removed after capture; the remaining icon discrepancy is now narrowed to the profile/trait selection path.

### QuickAction profile investigation continued (2026-10-27)

The actual lock-screen path is fully identified, but no standalone QuickActions profile resource was found in the simulator runtime. Native values remain `buttonDiameter=58`, camera scale `0.31648`, flashlight scale `0.368`, and button icon frame 48pt. Further work must identify the profile/trait selector before changing these values; arbitrary transforms remain disabled.

### Profile selection decoded; button metrics are size-driven (2026-10-27, rounds 4–9)

Nine probe rounds over `libvphonefolddisplay.dylib` (bundle builds
`2.12.1-local.fb48d760`…`98adc757`) decoded the whole selection chain. The
round-5 blind ivar crawl **crashed SpringBoard** on an unsafe-unretained
ivar; it was replaced by constructor-argument swizzling, which is safe and
reusable.

**Selection chain, from evidence.** `SBSDeviceDeterminedConfiguration` is
constructed by `SpringBoardUIServices+0x8D444` (runtime `0x1a7b67444`,
fbase `0x1a7ada000` = the unlinked base, slide 0). Disassembly of that
callsite shows the distinguishers are assembled there: base bits from three
boolean helpers (`0x4`, `0x40`), `enum==1 → |0x80`, `enum==2 → |0x100`.
Live constructions log `base=0 size={669,951} idiom=0 home=2
subtype=2034 distinguishers=0x104` (first, nativeBounds {2007,2853}) then a
family of `0x4` variants with nativeBounds {669,951}. Every instance
resolves `effectiveDeviceClass = 25`, pushed into
`CSProminentLayoutController setEffectiveDeviceClass:` from
`CoverSheetKit+0x23F08` (`0x1affb0f08`). The pure size classifier on the
live instance: `{669,951}→25, {951,669}→25, {466,678}→25, {428,926}→19`;
`_classForBase:zoom:` is the identity at zoom 0. So the effective class is
**screen-size-driven, not identity-driven**.

**Forcing class 19 does not move the buttons.** A file override
(`/var/mobile/Library/Caches/vphone-duo-layoutclass.override`, numeric)
rewrites the value in `setEffectiveDeviceClass:`. With 19 forced, buttons
stay 84×84pt with `iconImageSize {48,48}` at `{18,18}`: the button metrics
come from `CSProminentButtonsView._deviceSize {669,951}` →
`_buttonLayoutToUse`, not from the layout controller's class. The
controller class feeds the clock/date layout instead.

**Ground truth from the Apple Duo simulator** (B738069B, iOS 27.1): its
framebuffer is 2007×2853 = **669×951pt @3 — the same logical size as the
vphone guest panel**. At the same size the native Duo resolves the same
size-class row, and the consistent-state landscape lock renders the
flashlight glyph at ≈12×31pt inside the 84pt circle (37% fill) — visually
proportionate. The earlier "icons too big" reports came from inconsistent
orientation states (cover sheet composed for the other orientation,
`_actionsVisible = NO`, buttons placed at x=861 in a 669pt-wide portrait
scene — off-screen). In the pose-native landscape lock the buttons render
at (861,86)/(861,154) and are visible in pixel profiles (max 255 inside
the button boxes). The simulator cannot render headless: without
Simulator.app installed (this Mac has only Xcode CLI), `simctl io
screenshot` captures a black framebuffer; sim ground-truth needs the GUI
app or a different reference.

**Wallpaper state.** The lit landscape lock screenshot has zero
pure-black columns (wallpaper fills; the earlier right-side darkness is
the image itself). The portrait retainers are the live poster scene hosts
(`_UIScenePresentationView` ×2, `_UISceneLayerHostContainerView`,
`_UITouchPassthroughView`, all {669,951}) under
`PBUIPosterSceneLayerHostView`/`PBUIPosterFloatingView`; resizing them
(scenehost.sync, 8 nodes) changed no pixels — the visible layer is the
`PBUISnapshotReplicaView` path. `contentsRect`/`contentsCenter` are now
dumped for every node and are full-rect everywhere. The home-screen black
band (cols 0–243pt) is still unowned; the wallpaper-window deep dump
(`windows.inspect` now walks `_SBWallpaperSecureWindow` too) is captured
in `/tmp/duo-wallpaper/round5_windows.log` for the next correlation. A
portrait `SBSearchBackdropView {669,951}` sits inside the home window
tree at depth 8.

**Probe inventory now in the dylib** (all passive unless a notification or
override file is used): constructor-arg swizzle with raw-pointer callsite
logging; `setEffectiveDeviceClass:` logging + numeric override;
`contentsRect`/`contentsCenter` in tree dumps; wallpaper-window deep dump;
class-surface/ivar/mapping probes on a stashed config instance
(`effectiveDeviceClassForScreenSize`, `_classForBase:zoom:` 0–20).
Local artifacts: `/tmp/duo-wallpaper/round{4..9}_*.log`,
`r6_lock2.bmp`, `r9.bmp`.

**Open decisions.** (1) QuickAction: consistent-state metrics are the same
row a real Duo resolves at this panel size; accept them or supply a native
reference screenshot to compare against. (2) The home black band owner.
(3) Live-instance forensics beyond this needs frida in the guest, which
needs a `process.spawn`-style vphoned RPC or bootstrap ssh first — no
arbitrary process launch exists today (`exec` runs the host-side CLI).

### Round-12 destabilization and rollback (2026-10-27 evening)

The visual-scale experiment (swizzling the glyph constructor arguments and
`CSQuickActionsButton iconImageSize`, factor from
`/var/mobile/Library/Caches/vphone-duo-buttonscale.override`) **crashed
SpringBoard into a launchd-throttled loop and drove the whole userspace
into jetsam memory pressure** (every daemon past its limit, `stacks+`
reports every 10 s, no SpringBoard in the process list — the user saw a
recovery-looking screen). Recovery, verified working: delete the override
files, roll the machine back to the last stable probe bundle
(`2.12.1-local.98adc757`) with `vm set-bundle --update-environment`, then
a **VM-level** restart (guest `system.reboot` is not enough: launchd keeps
the old SystemHook mapped when the deployed copy changed). After restart
SpringBoard runs (283 MB), the lock screen lights, and SB-side logging
resumes (delete the stale log first if another process recreated it
root-owned). Lessons: never hook `iconImageSize`-style hot getters with
per-call file reads; a SpringBoard crash loop starves the entire guest,
not just the shell; the rollback recipe above recovers in about five
minutes. Button-size conclusion unchanged: the metric row ignores the
determined device class entirely; before any further size work, decode the
native row statically (CoverSheetKit `_layoutButtons`) or take a native
reference screenshot instead of guessing factors.

### Glyph hook root-caused; zero-swizzle scaling live (2026-10-27 night, rounds 14–15)

The second boot failure (round 13, factor file absent, hooks passthrough)
disproved the "scaled metrics crash" theory. The discriminating round 14
(the same build with the glyph hook installation commented out) boots
SpringBoard normally — **installing the hook on
`CSQuickActionImageGlyphView` is itself the boot killer**: that class's
method list sits on a read-only page in its image (PKUI family), so
`method_setImplementation` faults at SpringBoard load and the process dies
before the UI exists; the guest then presents as the recovery userspace
(no SpringBoard process, "Device Recovery" running, per-daemon
jetsam-limit telemetry — that signature, identical across both failures,
is the recovery environment's normal shape, not a leak). Hooks on
SpringBoardUIServices / CoverSheetKit classes remain safe; per-image
writability decides. Rule going forward: **never swizzle classes outside
the proven-writable images**.

Round 15 replaces the hook with a **zero-swizzle live transform**:
notification `com.vphone.display.quickaction.glyphscale` reads the factor
from `/var/mobile/Library/Caches/vphone-duo-buttonscale.override`
(clamped 0.5–1.0) and sets `transform` on every live
`CSQuickActionImageGlyphView` (bundle `2.12.1-local.1e3bf1d8`, boots
clean). At 0.68 the flashlight glyph view renders ≈13.8×24.9pt (was
20.33×36.67). Iteration protocol with no reboot: write the factor file,
post the notification; a respring/relock rebuilds glyphs at 1.0 until the
notification fires again. The user's native-reference screenshot
(2853×2007 — same logical panel) defeated both vision and geometric
measurement (textured wallpaper); its single usable vision read put the
native circle in the 91–120px bucket, directionally confirming 84pt/252px
is oversized.

### Landscape wallpaper gate detour: second band eliminated (2026-10-27 night, round 16)

The pending dc7604a1 experiment ran first (wallpaper role hint on
`_SBWallpaperSecureWindow` via the traits once flag): installed cleanly and
the role was assigned, but the home black bands were unchanged — role alone
remains insufficient, consistent with the earlier flag-only result. The
portrait home screen was then measured **full-bleed (zero black)**,
proving the wallpaper content itself is fine and the defect is purely the
landscape composition.

New lever: a **caller-scoped `PF_IS_PAD_DEVICE` detour** (MISFixDetour on
the soft-linked C symbol). The replacement answers YES only when
`__builtin_return_address(0)` falls inside the implementations of
`supportsLandscapeWallpaperContents` /
`supportsLandscapeWallpaperContentsForDisplayConfiguration:` (IMP ranges
captured at install, +0x1000 window); every other caller gets the original
answer, so no pad behavior leaks system-wide. Installed beside the traits
experiment under the same `vphone-duo-wallpaper-traits.once` flag
(`vpInstallLandscapeWallpaperGateDetour` in WallpaperTraitsExperiment.inc,
bundle `2.12.1-local.6648b598`, ranges=2 detour=0).

Measured effect on the landscape home screen: the 226–242pt pure-black
band is **gone** and wallpaper coverage moved from x≈244pt to **x=72pt**
(content now spans 72–950pt, 879pt wide); the boundary at 216px is a
razor-sharp 0→255 step (a clip edge, not image content). Lock-screen
landscape re-verified full-bleed (0 black columns) — no regression. The
manual wallpaper pulse does not remove the remaining 72pt band, and no
view in any `UIApplication.windows` tree carries a 72/879 geometry — the
clip lives inside the wallpaper engine's remote CAContext content. The
root server scenes still report a **portrait FBScene** (frame 669×951,
`interfaceOrientation=1`, display mode "669x951@3x") while UIKit renders
951×669, so the engine still composes against a portrait surface; the
72pt inset is the residual of that mismatch. Home-screen style is
`_styleType: color` (gradient accent) with the image wallpaper visible —
variant metadata and the engine-side bounds are the next evidence targets.

### Remaining band deep-dive: painter is path-dependent and off-tree (2026-10-27 night, rounds 17–22)

Forensics past the 72pt band (bundles `f6c61f57`…`ad926933`):

- The presenter's full description names the inner chain:
  `PBUIPosterWallpaperRemoteViewController` (scaleAssertions home@1.0)
  → `PBUIPosterWallpaperViewController` → `PBUIPosterViewController`
  (`activeOrientation = Portrait`, `landscapeBlurEnabled = YES`,
  MercuryPoster `v68.colorB` home configuration). The inner poster
  controller composes portrait while SBWallpaperController holds
  `_orientation = 4`. The poster orientation surface was enumerated:
  `rotateToInterfaceOrientation:duration:` on the wallpaper VC,
  `setActiveOrientation:` / `willRotate` / `didRotate` on the poster
  controller. Driving them flips `activeOrientation` to 4 **with no pixel
  change** — the true compositor is the poster extension's own FBScene
  (settings portrait 669×951, mode "669x951@3x"), unreachable from the
  host side.
- Hiding the live scene hosts (9 nodes) changes nothing; hiding ALL
  presenter content nodes (hosts + replicas) returns the screen to the
  pre-gate two-band pattern — so the visible wallpaper alternates between
  the live remote render and the snapshot replicas depending on
  transition history, and **the snapshot images carry the gap baked in**
  (they snapshot the gapped live render). A horizontal affine on the
  wallpaper container and a `contentsRect` patch on the replica
  image views both produced zero pixel change in the states tried —
  the painting layer for the observed state was not the one patched, and
  which layer paints is path-dependent.
- The same gate+rotate sequence that reliably produced the single-72pt
  state in round 16 produced the two-band state on a fresh boot in round
  22 with the gate verifiably installed — confirming path dependence
  rather than a broken detour.
- Conclusion: the residual band is composited from the wallpaper render
  path outside SpringBoard's view trees (extension scene, portrait-anchored,
  feeding snapshot replicas). Productive next steps, in order:
  (1) productionize the round-16 ordering (gate detour armed at boot +
  rotation RPC's pulse sequence) and characterize which transition path
  lands on the 72pt state; (2) the root fix remains making the extension
  scene/​display mode rotate — the display-identity workstream;
  (3) live compositor introspection needs frida in the guest (extension
  process), which needs the `process.spawn` vphoned RPC or bootstrap ssh.

### Cover-viewport switch regression on the latest build (2026-10-27 late)

While capturing the four inner/outer screenshot states on the freshly
installed **Release Launchpad** (built from source, signed with the
Developer ID team, helper self-healed to ready), the cover viewport
switch regressed: on `2.12.1-local.ad926933` (latest source), every
`display.posture closed/open` fails with "Duo logical viewport did not
reach the requested size" — from settled portrait, from landscape, and
after a clean respring (cover generations are requested and workspace
transitions run, but bounds never reach 466×678), and the failure is
bidirectional (open fails from cover too; after a reboot with a closed
hinge preference the machine stays stuck on the cover until an older
bundle opens it). Binding `2.12.1-local.3803cc4d` restores both
transitions immediately (closed 466×678 and back to 669×951 verified),
so the regression entered between 3803cc4d and ad926933 — the probe-round
folddisplay changes are the delta; bisect before productionizing any
cover-path change. Rotation while closed is refused by the current
posture policy (cover stays portrait, per the documented product rule).
`device.screen` width is stale across viewport switches — trust
`display.geometry`. Four-state captures and per-state poster probes are
archived in /tmp/duo-quads (inner portrait/landscape on ad926933; outer
portrait + refused-landscape on 3803cc4d).

### Orientation-map writer restored; cover application second layer open (2026-10-27 midnight)

The cover-viewport regression has **two independent layers**, both now
characterized:

1. **SB-main orientation map writer was gutted** —
   `vpExportNativeOrientationMapping` had been reduced to a log-only stub
   (the folddisplay source is untracked, so no git history marks when; the
   3803cc4d dylib still references the map path, ad926933 does not at
   all). vphoned's `vp_display_orientation_mapping` posts
   `com.vphone.display.orientation.mapping.request` and waits 150 ms for a
   fresh `vphone-display-orientation-map.json`; with no writer every
   posture/rotation settle that needs the map fails with "map
   unavailable"/"viewport did not reach the requested size". Reimplemented
   the writer in bundle `2.12.1-local.fdcb1d99`: publishes the validated
   schema (version/scene/pid/generatedUptime/available/persistentViewport/
   deviceOrientations/scale/surfaceType/viewportGeneration/
   interfaceOrientation/configurationBounds/coordinateBounds/bounds) on
   demand, at SB startup (2..12 s retries), and 0.15/0.6 s after every
   viewport generation change. Verified: `display.geometry` available with
   live bounds and persistentViewport=1.

2. **The viewport application itself still doesn't land on this source
   state.** With the map healthy, `display.posture closed` still leaves
   configurationBounds at 669×951: the resolver reaches
   `FullyClosed prevailing, primary on .cover`, workspace transitions run,
   `single viewport: requested cover generation=N` fires, but bounds never
   change. `vpRefreshMainTransform` iterates `vpObservedDisplayMonitors` —
   **empty in every recent boot** (zero "monitor init:" lines in the whole
   retained log), so the refresh is a no-op; the observation hooks install
   but never see an `FBSDisplayMonitor` init (monitors are created before
   the hooks land, or via other paths). The monitor/observation code is
   byte-identical (strings) between 3803cc4d and fdcb1d99, so the
   remaining delta is elsewhere — prime suspect is the default-on
   "Default landscape scene policy integration" window (doc: "runtime
   validation is required"), which predates my probe rounds and postdates
   3803cc4d. Next: binary-diff 3803cc4d vs current around
   vpSetCoverViewport/vpRefreshMainTransform, or bisect bundles between
   3803cc4d and the policy-integration builds (db26a8cc era) with the
   now-fixed map writer deployed (the map fix must ship in every test
   build — posture validation depends on it and masked earlier bisects).

## 2026-10-28 night session: posture chain rebuilt end to end (agent)

Three independent defects were found and fixed in one pass; the fold
pipeline now works end to end on `duotest-m5` (build 2.12.1-local.76f72608
and later).

### 1. Screen-off "wedge" = persisted closed hinge, not a wedge

Every boot came up dark with home/power/undim dead. `display.pose` told the
truth: `hinge: 1` (closed). SpringBoard honestly emulates a folded phone —
inner display asleep, and the (missing) cover display should be the lit
one. `GuestFoldPose.startOnStartup` replays the persisted hinge angle every
boot, so the last user fold direction survives reboots by design. The
"repeated fold-button clicking can light it" symptom was the open-direction
pose forcing a display update. Recovery is one call:
`display.posture {"position":"open"}`. The bootlogo-offset sighting on
0da674b5 matches: a closed-pose boot renders the boot logo for the cover
viewport inside the inner-sized window.

### 2. The orientation map's `deviceOrientations` was a hardcoded identity

`vpExportNativeOrientationMapping` published `@[@1,@2,@3,@4]`, but the Duo
inner panel mounts rotated: the scene's own
`deviceOrientationForSystemSpaceOrientation:` answers **[3,4,2,1]** (and
the forward table [4,3,1,2]) — measured live. Every
`GuestDisplayRotation.resolve` therefore translated interface requests
through the wrong device orientation; that is the entire 180°-flip bug
(interface 90 → stub device 4 → real table says device 4 presents 180).
The writer now exports both native tables (permutation-validated, identity
fallback for pre-selector scenes). After the fix, rotation 0/90/180/270
round-trips settle and posture open lands at interface 90 by design
(`setDevicePose`'s `desiredInterface`), no longer corrupted to 180.

### 3. Layer 2: the 3803cc4d publish path had been deleted, not broken

The rewrite that rebuilt the map writer dropped the entire mechanism that
made the cover viewport *apply*. Recovered by diffing strings against the
shipped 3803cc4d dylib and then observing that bundle live:

- **Invalidation pulse** — `FBDisplayManager sharedInstance` (the
  "compatibility monitor") holds the sources and the transformer. The old
  code flipped the primary `FBSDisplaySource._updatable` ivar (a raw BOOL
  ivar, no setter — method hooks fail, write by `ivar_getOffset`), called
  `updateTransformsWithCompletion:` (ABI v24@0:8@?16) — the armed
  `SBMainDisplayConfigurationTransformer` hook then replaces Main with the
  466×678 cover mode — and restored the flag in the completion.
- **Root geometry** — same-identity mode changes push no scene settings of
  their own. `updateUISettingsWithBlock:` (on each root server scene:
  SB-main, SB-systemAperture, SB-systemApertureCurtain) hands the block a
  `UIMutableApplicationSceneSettings`; `setFrame:` there is ABI
  **v48**@0:8{CGRect…}16 (not v40 — cost one build cycle). Setting the
  three frames to the live mainConfiguration bounds is what the old
  `___vpUpdateRootSceneGeometry_block_invoke` did.
- **Adoption** then runs natively through machinery that already exists:
  the hooked scene-geometry callback → `vpPropagateSceneBounds` → icon
  family 32→31 ("iPhone XX (D76)") → `_resizeWindowFrameToSceneBounds…`
  on every scene window (10–20 frames changed) — the same log sequence the
  3803cc4d reference boot produced.
- Ordering matters: adoption must run *after* the transform publishes. It
  is now scheduled from the transform hook's cover-success branch (once
  per generation), with a 0.25 s fallback in `vpSetCoverViewport` for the
  inner revert, deduped by `vpAdoptionCompletedGeneration`.

The manual workspace request path (`vpProcessViewportWorkspaceRequest`)
still refuses (layout state `elements=0`) but is no longer needed for the
viewport itself; it fires from `vpPropagateSceneBounds` under the same
guard as before.

### Verified this session (duotest-m5, 76f72608)

- 3× open↔closed round trips: every call `ok:true`, bounds
  669×951 ↔ 466×678 each time.
- Rotation matrix at open: 90 → 0 → 270 → 0, all settle.
- Cover state: home wakes it, centered correctly-proportioned clock
  presentation (12:55 AM matched wall time), root scene frames 466×678.
- Open portrait/landscape screenshots captured (/tmp/ev-*.png era).
- Host fold button now toggles open↔closed only (book stays in the Fold
  panel for diagnostics).

Still open: glyph 0.68 solidification (§3.3/K), lock-screen notification
width (§3.5/H), wallpaper gate default (§3.4), full acceptance matrix with
touch (A–F), cleanup (I), module commits (J). The cover presentation's
content is a clock-style cover screen; rich cover UI (dock/notifications
on cover) has not yet been acceptance-checked.

## 2026-10-28 morning: fold-closed orientation regression (user-reported)

User report after the overnight session: the fold toggle "only switches
landscape/portrait, no inner/outer switch", with a screenshot of the home
grid rotated 90°, vertical dock, right-edge clipping. Reproduced on
`2.12.1-local.5ffed6ae` with one RPC: `display.posture {"position":"closed"}`
lands bounds 466×678 (cover mode applied) but interface orientation 3 with a
2853×2007 landscape framebuffer.

False leads worth recording: the folddisplay log appears to "stop" at a
timestamp because `files.read` returns the FIRST ~512 KB of a multi-MB file —
always check `files.list` mtimes before concluding a dylib died; the map
JSON's fields can also be stale across a VM restart (the file persists), so
`display.orientation` (asks SpringBoard live, IcliKit) is the truth for
interface degrees, not the map's `interfaceOrientation`.

Root cause chain (each link verified on the live guest):

1. **Stale-table resolve.** `setDevicePose` resolved portrait against the map
   JSON immediately after the viewport landed. The JSON's `configurationBounds`
   updates at the apply, but the scene's mounting table follows on the next
   export, so the first read still carried the previous panel's table: closing
   resolved portrait to device 3 (inner's rotated portrait) which the
   identity-mounted cover renders as landscape.
2. **Cover arbiter latch.** The cover scene's traits arbiter derives its
   direction once, at the mode swap, from the pipeline's cached device
   orientation, and after that no input channel reopens it — pose override
   (device 1), `pose.refresh` (pipeline re-read), forced arbitration, the
   accelerometer sink (delivering device 1), and the public `display.rotation`
   path all verified portrait-side while the pipeline stayed landscape.
   `vpMainInnerWindowScene()` returning nil in cover viewport also made the
   dylib's refresh/arbitration/actuation handlers refuse outright
   ("refused outside Main inner"), so the inner panel's self-healing
   (`native callback direction=1`) had no cover equivalent.
3. **Boot restore hardcoded device 1** as the pose value (the pose enum's
   portrait, not the mounted device value), so a folded boot could restore a
   landscape interface depending on which table the export carried at ladder
   time.

Fixes (vphoned + dylib, all in this session's builds):

- `GuestAPI+Device.swift` `setDevicePose`: self-verifying resolve loop —
  request a fresh map export, resolve portrait, set pose + accelerometer,
  poke `pose.refresh`/`arbitration.refresh`/`actuation.refresh`, confirm via
  `interfaceRotationDegrees() == 0`, re-resolve once with the settled table;
  accelerometer seeded to 0° and `pose.refresh` posted BEFORE the viewport
  apply when closing; closing while unlocked+lit now sleeps the display
  (real hardware blanks the inner panel; the cover lock screen is the native
  cover presentation — verified portrait at every folded boot).
- `GuestFoldPose.swift`: boot ladder resolves the portrait device value from
  the live map instead of hardcoding 1, stops only when SpringBoard answers
  portrait, and pokes `pose.refresh` before the respring-replay viewport
  apply.
- `libvphonefolddisplay.m`: new `vpOrientationArbitrationScene()` (inner
  scene, else the active Main-identity scene while the persistent viewport is
  live) used by the refresh/arbitration/actuation handlers; the actuation
  handler, when the arbitration scene is the cover, completes the native
  callback chain with the cover's native portrait direction instead of the
  latched pipeline value — this is the link that actually breaks the latch.

Verification on `2.12.1-local.f16a7b5f` (duotest-m5): boot-closed portrait;
3× open↔closed roundtrips all landing 669×951/0° and 466×678/0° with a
portrait framebuffer in both states; cover wake lock screen portrait; inner
rotation matrix 90/0/270/0 exact; open home screen visually clean (portrait
grid, horizontal dock, no clipping). Known remaining behavior: closing while
unlocked sleeps the screen by design — the next wake presents the cover lock
screen (clock) and `screen.unlock` (or a swipe) returns to the home layout.

Follow-up (same morning, animated sweeps): the fold panel's animated sweeps
(duration > 0) exposed two residual transients. The hinge sweep's
fully-closed band crossing re-derives the cover direction once more near its
end, after vphoned's first correction; and opening carried the cover's
portrait pose (device 1) into the rotated inner mounting, flashing
landscape-left until the loop re-resolved. Fixes: the resolve loop's first
pass now pokes pose-refresh/arbitration/actuation immediately after the
bounds confirm (the export wait moved to the retry pass only), the posture
path holds one final actuation batch until `vp_hinge_get()["sweeping"]`
clears, the open direction seeds the measured inner portrait (device 3 /
270°) before the viewport apply, and the dylib's viewport adoption completes
the cover actuation inline (`vpScheduleViewportAdoption`), so the correct
direction lands in the same adoption turn instead of a second later. Button
path (duration 0) verified 3/3 roundtrips clean; animated paths sample clean
with an occasional single-sample (~0.2 s) self-healing blip on close.

Follow-up (landscape re-flow): rotating the open panel to landscape left
the home grid in its portrait arrangement rendered sideways with a black
side band — the Main mode keeps portrait dimensions on this platform, so
the rotation pipeline turned the framebuffer but nothing re-delivered the
scene's coordinate space (no icon-family switch, no resize propagation;
those only ran from the fold adoption chain). Two fixes: the dylib's
orientation actuation now also submits the public
`requestGeometryUpdateWithPreferences:` for the actuated direction, so
UIKit swaps the scene space to 951x669 and the grid/dock/status re-flow
(verified visually at 90 and 270); and the host window's orientation poll
only re-applied the window turn when the panel size changed, so a rotation
on the same panel left the window in the old aspect — it now follows the
orientation change itself (animated turn, fold panel changes stay forced).

Follow-up (rotation memory across folds): an explicit landscape now
survives a fold cycle. `display.posture` records the interface degrees at
close (90/270 only) in a session-scoped memory, presents the cover
portrait as before, and on opening replays the remembered direction
through the same seed/resolve-and-confirm path — the open-side seed now
resolves the desired interface against the measured inner table instead
of hardcoding device 3, and the sweep-hold check and rotation fallback
follow the target degrees. Verified: 90° and 270° both restore after a
closed→open cycle with correct landscape re-flow; a portrait fold cycle
stays portrait. The memory is session state: a reboot restores portrait
through the boot ladder.

Follow-up (state machine rework): the orientation model now matches the
hardware. The cover has no rotation state — it always presents portrait
(466×678), and the fold closes onto a LIT cover screen (the earlier
sleep-on-close made the fold button look like "screen off" and is
removed; the cover arbiter override keeps portrait upright there for both
the unlocked layout and the lock screen). The inner panel rests
LANDSCAPE: its rotated mounting maps the natural device pose (accel 0°)
to interface landscape-left (90°), so an unfold — and a folded boot —
presents the inner default directly, and portrait on the inner panel
stays an explicit rotation. The session-scoped fold rotation memory from
the previous entry is removed (the default owns the post-unfold state);
the boot ladder resolves the desired interface per target viewport
(cover "0", inner "90") and stops only when SpringBoard answers the
target degrees. Verified: folded boot and every unfold land 90° with a
correct landscape re-flow; every close lands a lit portrait cover;
explicit rotations 0/90/270 still settle; 3× cycles green.

Follow-up (cover presentation band): the folded black band under the cover
content traced to the host window, not the guest. The guest anchors the
466x678 cover mode at the framebuffer's top-left and the window's layout
crops exactly that region (1398x2034) full-bleed at the panel's scale —
verified by pixel-brightness profiles of the raw framebuffer (content in
rows 0–~2050, pure black only below the mode). The visible thick band was
the inner-aspect window still showing the whole framebuffer for up to the
orientation poll's one-second period after the fold: the cover content in
the top 71 percent, black below. The fold action now runs the poll as soon
as the posture RPC returns, so the window takes the cover crop immediately.
(A guest-side experiment that centered the scene frames moved nothing —
scene windows ignore the settings-frame origin — and was reverted; the
top-left anchor is the load-bearing contract between the two sides.)

Follow-up (wallpaper on the landscape-rest inner panel): two symptoms
after the state-machine rework — the wallpaper missing at a boot that
rests landscape, and a ±90°-misrotated wallpaper after rotations. Both
traced to the wallpaper orientation pulse
(`presentation.wallpaper.pulse` → `vpPulseNativeWallpaperOrientation`),
a portrait-era lease that re-aimed the wallpaper controller and force-set
its view frames; with the coordinate-space machinery now delivering the
rotated scene geometry natively, the lease fought it (interface-code
rotation applied on a rotated mount = a net 90° error, direction
following the rotation side). vphoned no longer posts the pulse from the
rotation or posture paths; the native wallpaper rotation owns the
follow. Verified: boot-rest-90 wallpaper present and upright, rotations
0/90/270/90 all correct, cover lock wallpaper intact, close→open cycle
upright landscape. The dylib handler remains registered but idle.

Follow-up (wallpaper direction, corrected): the wallpaper controller takes
the device-side orientation code, whose landscape names mirror the UI ones
(UI landscape-left 4 presents upright as 3; portrait stays 1) — passing the
raw interface code quarter-turned the image on every landscape. The pulse
posts removed earlier are restored and the pulse maps its target through
that mirror before re-aiming the controller and sizing the views. Verified
by brightest-pole measurements of the wallpaper across boot-rest 90,
portrait, 90, and close→open cycles (pole at the top in each). Known
remaining edge: an explicit 270 rotation leaves the wallpaper view
portrait-sized at the landscape interface (content upright-ish but
letterboxed) — the 270-side native layout races the pulse's frame pass;
chase separately if 270 matters on the hardware.

Follow-up (QuickAction glyph sizes): the uniform 0.68 transform left the
flashlight towering over the camera — the glyph frames are symbol metrics
times one shared multiplier, so tall symbols (flashlight.off.fill,
20x37pt) render twice the camera's height (camera.fill, 24x18pt) under
any uniform factor. The walk now normalizes each glyph's LONG side to
16pt (the accepted camera size: 23.57 x 0.68), computed per instance
from its live frame and clamped to 0.2...1.0: the flashlight lands at
~0.44, the camera keeps ~0.68, and any future glyph — including the
lock-screen focus button (same CSQuickActionImageGlyphView class,
created only while a Focus is active) — normalizes without a per-action
table. Verified on the cover lock screen (both glyphs now matching
extent, flashlight slim); the Control Center focus module icon measures
consistent with its neighbours and is a different (CCUI) family.

Follow-up (deployment staleness + fresh rebuild): two infrastructure
findings from the wallpaper chase. First, the offline guest-environment
update (set-bundle --update-environment / cfw update-environment) served
the PREVIOUS build's dylib — proven by a build marker absent from the
guest while the bundle contained it; two page-rounded builds sharing a
byte size hid the skip from casual checks. A size-changing padding
buffer now keeps the folddisplay dylib's size per-build distinct, and
the fold-family dylibs (folddisplay, foldguard, hinge, posterprobe) were
added to vphoned's `environmentLibraries` allowlist so the running
machine's hash-based environment sync can update them too. Second, the
first environment rewrite that actually changed sizes was followed by a
boot kernel panic (AppleSEPManager backtrace, pid 0, three consecutive
boots) — unreproduced elsewhere and not yet root-caused; the machine
was deleted and recreated (vm create --device iPhone19,4 --no-template,
standard preset, every step passed). The fresh restore delivers the
current dylib directly (marker verified in-guest), the wallpaper
orientation bridge installs, and 3× fold cycles land closed 466×678/0°
and open 669×951/90°. Wallpaper orientation judgment needs the user's
directional wallpaper set again on the fresh machine.

Follow-up (wallpaper flakiness, honest status): on the fresh machine the
landscape wallpaper is path-dependent — sometimes a correct full-bleed
frame, sometimes a portrait-width strip with a gray-black remainder,
with the display stream even observed frozen across three rapid
rotations (byte-identical captures). The pulse (frame sizing) +
orientation bridge (device→interface through the mounting table) +
device-code mirror are all armed together now; each individually helps
one path but no combination is stable across sequences. Remaining
suspicion: photo wallpapers render through the poster-extension
processes (PhotosPosterProv and siblings), whose hosted-scene rotation
our SpringBoard-side hooks never touch — the next engineering round is
injecting an orientation follower into those extensions (SystemHook
already routes PosterBoard* processes for the probe). A quick layer
bisect anyone can run: set a built-in STILL wallpaper (Settings ›
Wallpaper) and rotate — if stills stay upright in every direction, the
bug is confined to the extension-rendered photo path.

Follow-up (QuickAction repeat application, 2026-10-28): the long-side walk
was using each glyph's `frame`, which can include the transform already
applied by an earlier rotation or fold pulse. Repeated passes therefore were
not idempotent and could shrink the camera. The walk now reads the
untransformed `bounds`, keeps the flashlight's 16pt long-side target, and
restores the camera to a 0.82 factor; repeated pulses converge to the same
transform. Each glyph now also retains its first native bounds in an
associated value, so a later private layout rewrite cannot feed a transformed
size back into the next pass.
Orientation actuation also schedules three coalesced main-queue passes after
the native CoverSheet layout returns, so a glyph rebuilt late in the rotation
cannot remain at the unscaled native transform.

Follow-up (wallpaper editor loading and floating scene position, 2026-10-28):
the poster probe was issuing a new geometry request every 1.5 seconds while
the PosterBoard editor kept its portrait scene contract. That reset the Add
New Wallpaper loading transition indefinitely. The probe now coalesces
requests, leaves PosterBoard itself alone, and only follows hosted poster
renderer processes. The settled orientation is read from the daemon's Darwin
notification state before falling back to the map file. SpringBoard also keeps
the portrait floating editor scene at its native size and centers it inside
the landscape poster host; renderer containers still fill the native presenter
bounds.

Follow-up (rotation wedge on the recreated machine, 2026-10-28 PM): after
the first 270° request on the recreated duotest-m5, every rotation away
from the inner rest (90°) is refused — the RPC times out with "The Duo
scene did not settle", the pose override verifiably holds the requested
device value during the window (portrait request: pose 3), the
accelerometer sink is healthy, and the forced arbitration still concludes
interface 4 (the mount's mapping of the REST pose device 1, not the
requested device 3). The scene geometry request now fails with
UISceneErrorDomain 101 ("windowing mode does not allow programmatic
changes to interface orientation") — the same public call that delivered
the landscape re-flow on the original machine. Bisection so far: not the
experiment flags (none on disk), not the rotation lock (all keys false,
full lock-cycle does not clear it), not the merged dylib (reverting
libvphonefolddisplay to the pre-merge commit changes nothing), not the
hinge preferences (clean 180°), and not a stale vphoned (pose.refresh now
rides setRotation's sequence too, commit e409fa2b build). The wedge
survives reboots and code reverts, and 0↔90 DID work in the machine's
first minutes before the first 270 request wedged it — pointing at a
persistent guest state or a machine-creation difference (the recreate ran
the current template flow: setUpTemplate/trimTemplate steps the original
never had). Next round: (a) recreate a second machine with trimming
disabled and diff the arbitration behavior, (b) instrument the traits
arbiter's supported-orientation query, (c) compare the scene's
effectiveGeometry on the two machines.

Follow-up (rotation wedge root-caused to the creation firmware chain): the
recreated machines' rotation refusal is not code. A clean bisection on a
virgin control machine (duotest-m6, created with vm create --no-template,
current preset): rotations away from the constructed orientation are
refused under (a) the current build, (b) the pre-broadcast vphoned with the
c868 dylib, and (c) the current vphoned with the bridge-free 80800232
dylib — the exact dylib under which the original machine's rotation matrix
was green this morning. Every display-side suspect is cleared; the one
remaining variable is the boot chain: the original duotest-m5 was created
on an older bundle's firmware (its bootChainBundle read 2.12.0), while
both recreates were created with today's build as their chain, so a
regression inside the current standard preset's firmware patches
(kernelcache or dyld-shared-cache guest patches) breaks orientation
arbitration on machines restored with it. Separately, a refused rotation
also poisons the persisted hinge preference to angle 0 (folded) — the
next boot then emulates a folded phone (dark inner screen, home does not
wake); `display.posture open` revives it. Next round: create test
machines with subsets of the standard preset (--block/--allow) to find
the offending firmware patch; also make the rotation path clamp the
persisted hinge to a sane state on refusal.

Follow-up (corrected framing, per product knowledge): real iPhones never
rotate SpringBoard — home-screen rotation is an iPad behavior, and on the
Duo it is a foldable capability. The recreated machines refusing
`display.rotation` are therefore showing STOCK iPhone semantics, not a
broken arbiter; the original machine rotated because the dylib's
orientation-actuation replay FORCED the pipeline, and its scene ACCEPTED
programmatic orientation changes — the recreated machines' scenes refuse
with UISceneErrorDomain 101 ("windowing mode does not allow programmatic
changes to interface orientation"). The regression is thus narrowed to
one question: what made the original's SB-main scene permissive to
programmatic orientation while every machine created on the current
chain refuses. Targeted eliminations on virgin machines: blocking
system-springboard-cfw-fold_display (identity padding) does not restore
rotation (duotest-m7); artwork-device-subtype 2556 predates both eras;
the product-id patch is off in presets; scene-status policy is automatic
on iPhone19,4; the ebed07c3 DSC hunks are structural. Remaining probe
for the next session: instrument the SB-main scene's windowing-mode and
activation-condition state at construction (the 101 check's input), and
disassemble SB's programmatic-orientation gate to name the exact
capability it consults — then either supply that capability for foldable
guests or route the rotation path through the API that gate permits.
Also recorded: a refused rotation persists a folded (angle-0) hinge
preference — the next boot sleeps the inner screen; `display.posture
open` revives it; the rotation path should clamp the persisted hinge on
refusal. duotest-m6 and duotest-m7 exist for testing (m7 with
fold_display blocked at creation).

Follow-up (rotation refusal: definitive isolation): display.rotation works
perfectly on the iPad guest (duotest ipad-mini-01: 90° and 0° both settle
exactly) — the vphoned rotation mechanism, the accelerometer, the pose
override, and the actuation pipeline are all correct. The refusal is
specific to the iPhone19,4 platform identity in the VM: on every fresh
iPhone19,4 machine, SpringBoard constructs its scene with a windowing
mode that returns UISceneErrorDomain 101 for programmatic orientation
changes, regardless of (a) fold_display/fold_guard/hinge patches blocked
or present at creation, (b) the foldable_vm_subtype identity blocked,
(c) the folddisplay dylib physically deleted from /usr/lib with SB
resprung — the refusal persists in all cases. The original machine's
rotation ability came from state accumulated over days of bring-up
(specific source unidentified; candidates include launchd environment
variables, MobileGestalt caches, or preference-domain keys that our
early sessions set and that a fresh machine lacks). This is consistent
with product behavior: stock iPhones do not rotate SpringBoard; the
capability is iPad-native and fold-hardware-gated on the Duo. Next
session should either identify the specific state that unlocked it on
the original machine (diff com.apple.springboard and backboardd
preference domains between a working and a refusing machine — needs a
working reference), or implement the rotation path through a channel
that does not consult the windowing-mode gate (the layout-class override
swizzle, or a SpringBoard-private rotation API).

## 2026-10-28 evening: FoldDisplay split into modules

`libvphonefolddisplay.m` (4,344 lines plus `StatusProfile.inc`, which ended
inside an unclosed function body, and `WallpaperTraitsExperiment.inc`) is now
one file per section:

| File | Owns |
|---|---|
| `libvphonefolddisplay.m` | constructor: backboardd probes, SpringBoard hooks, notification registry, pipeline observation |
| `FoldDisplayPrivate.h` | cross-file state and functions, hidden visibility |
| `FoldDisplaySupport.m` | log, `.once` flags, KVC/ivar readers |
| `FoldDisplayPipeline.m` | Main configuration transformer, monitors, pipeline observation install |
| `FoldDisplayViewport.m` | cover/inner viewport, adoption, persistent viewport |
| `FoldDisplayOrientationMap.m` | the map vphoned polls |
| `FoldDisplayOrientation.m` | root scene orientation, arbitration/actuation, geometry requests, backboardd events |
| `FoldDisplayStatusBar.m` | status registration, clock, scene status policy, profile lookup |
| `FoldDisplayUIConfiguration.m` | UIKit configuration and screen traits |
| `FoldDisplayWallpaper.m` | wallpaper pulse, scene hosts, bridge, traits, landscape gate |
| `FoldDisplayQuickActions.m` | quick action inspection and glyph scale |
| `FoldDisplayScreenFamily.m`, `FoldDisplaySurfaceProbe.m`, `FoldDisplayVirtualDisplay.m`, `FoldDisplayDiagnostics.m` | family lookups, backboardd surface probe, virtual display, inspection dumps |

Symbols used by one file stay `static`; only cross-file ones lost it. The
export table is unchanged. On duotest-m5 the split and the pre-split build
gave the same install log and the same rotation and fold results: 90°
settles, then 0° and 270° are refused ("did not settle"), and closed/open
land 466×678 and 669×951. That refusal on this machine predates the split.

### QuickAction glyphs: why the scale came and went (2026-10-28 evening)

`quickaction.inspect` now logs each glyph's bounds, transform, symbol image
size and on-screen size. After a respring the flashlight showed bounds 20x37,
transform 0.436, on screen 8.9x16, while the camera showed bounds 35x26,
transform 0.82, on screen 28.4x21.6 (its native size). `CSQuickActionsButton`
lays the glyph out with `setFrame:`, and on a transformed view UIKit answers
by growing the bounds until the visual frame is the requested one. A glyph
looked scaled only if no layout pass followed the walk, and the walk skipped
it afterwards because its transform already matched. That is the reported
"not idempotent / not uniform".

Fix (`FoldDisplayQuickActions.m`): each glyph moves to a runtime subclass,
`VPhoneQuickActionGlyphView`, as KVO does, whose `setFrame:` sets center and
bounds from the layout rect when a transform is present, and whose `-class`
reports the original class. `CSQuickActionImageGlyphView`'s own method list
is still never written. The glyph's container (48x48 `UIView`) holds two
subviews, so a `sublayerTransform` there was ruled out.

Target: one factor, `vpQuickActionGlyphScale` = 0.70, on the native layout
sizes (flashlight 20x37, camera 35x26; the camera's 28x22 seen earlier was
already an effective 0.82). A real iPhone Duo landscape lock screen
(1535px for 951pt, 77px buttons) draws the flashlight at about 15x27pt and
the camera at 23x17pt: 0.75 and 0.66 of the layout sizes, one factor within
the measurement. Drawing both at their symbol image size (12x22, 25x19) was
tried first and made the flashlight shorter than the camera, which the real
device does not do. The tall/wide split (16pt long side, camera 0.82) is gone.

Verified on duotest-m5: 14.2x25.7 and 24.3x18.4 on screen after two lock
cycles, a rotation to 90°, folding closed, opening, and another lock cycle.

## 2026-10-28 night: dual-display spike, Stage 0

The landscape-wallpaper hooks kept patching consequences of one fact: this
guest has one portrait main display, so PosterKit classifies every scene as
`DISPLAY_TYPE_EMBEDDED` and `PFContextSupportsDynamicRotation` says NO. A
real iPhone Duo has a second, always-connected, non-main, landscape-native
inner panel that PosterKit classifies as `DISPLAY_TYPE_AUX`. The spike
publishes such a display inside the guest instead
(`FoldDisplay/FoldDisplayInnerDisplay.m`, opt-in through
`/var/mobile/Library/Caches/vphone-duo-inner-display` until 2026-10-29, when
the marker was dropped and the path became the only one).

Stage 0 asked for: two always-connected displays, a stable SpringBoard
without suppressing any assertion, an inner window scene, and
`PFContextSupportsDynamicRotation` YES with no detour. On duospike-inner
(iPhone19,4, 27.1 24A94425) it reads:

| Check | Result |
|---|---|
| always-connected identities | `{Main, Unknown[7]}` |
| SpringBoard | same pid across 80 s of polling, no new crash report |
| inner scenes | `com.apple.springboard.bringup`, `SB-systemAperture`, `SB-systemApertureCurtain` on `Unknown[7]` |
| PosterKit | `Unknown[7]`: `DISPLAY_TYPE_AUX`, dynamic rotation 1; Main: EMBEDDED, 0 |

What the display needs, each found by the failure it caused:

1. **backboardd**: a `CAWindowServerVirtualDisplay` (2853×2007, 60 Hz,
   named `VPhone Duo Inner`), enabled and tagged with the bit
   `NSStringFromBKSDisplayTags` calls `unknown` (65536). FrontBoard drops a
   source that is neither always-connected nor tagged.
2. **SpringBoard, CADisplay type**: every reader except one sees type 0,
   built-in. `-[FBSDisplayConfiguration _initWithImmutableDisplay:
   originalDisplay:isMainDisplay:assertIfInvalid:]` sees type 4, scoped by a
   thread-local flag around the original. In `_FBSCADisplayToDisplayTypes`
   type 4 is always-connected but UIKit-main-like only when it is the main
   display, so only Main claims the cloning source (two claimants is
   `ManagedDisplaysController` "Cloning source already exists",
   `SpringBoard-2026-10-26-005058.ips`). `_FBSCADisplayAlwaysConnected`, the
   classifier's other caller, gives always-connected for 0 and 4 alike.
3. **Why not type 4 everywhere**:
   - `BLSHBacklightOSInterfaceProvider initWithPlatformProvider:` builds the
     backlight hosts once from `[CADisplay displays]` filtered to
     `displayType == 0`. Without a host, `SBBacklightController
     initWithWindowScene:` passes a nil backlight and
     `-[SBDisplayLinkController initWithCADisplay:backlight:]` traps
     (`.cold.2`, SIGTRAP).
   - `-[SBEmbeddedScenesConnectionManager _reevaluateSceneConnection]` waits
     for a scene on the `uniqueId` of every type-0 display and runs on every
     arrival. With the inner display at type 4 the expected set is {Main},
     so the inner scene's arrival completed startup a second time and
     `-[SBMainWorkspace setPipCoordinator:]` asserted.
4. **Getter ABI on 27.1**: `-[CADisplay pointScale]` is `Q16@0:8`;
   CADisplay has no `isAlwaysConnected`. The adapter reports pointScale 3 and
   `isExternal` NO for the inner display only.

Open for Stage 1 and beyond:

- The display only reaches SpringBoard after a SpringBoard-only restart:
  backboardd adds it about a second after SpringBoard's first display
  enumeration, and BacklightServices reads the list once.
- The inner configuration reports 669×951 bounds, not the panel's 951×669.
- Nothing composites the inner display onto the framebuffer and no touch is
  routed to it.

Test trap: a VM restart's environment sync rewrote
`/usr/lib/libvphonefolddisplay.dylib` with the bundle's copy about a second
into boot, after the first SpringBoard and backboardd had loaded the pushed
build. Later SpringBoards ran stock code without any error. Re-push and
check the on-disk hash after every VM restart.

## 2026-10-28 night: dual-display spike, Stage 1 (compositing and touch)

**Render-server cloning does not reach this panel.** The first attempt
made the inner display the clone master and the LCD its clone
(`-[CAWindowServerDisplay addClone:options:]`; the options are
`disableOverscan`, `disableRotation`, `disableScaling`, `disableYUV`,
`noReplayScaling`, `replayContexts`). The clone registered (`LCD.cloneMaster`
= the inner display). The inner display was disabled and blanked by then,
and `VirtualDisplay::can_update` gates on a state bit; unblanking it gave
`enabled=1 isBlanked=0`, after which the LCD as its clone read
`enabled=0 isBlanked=1` and the paravirtual panel showed either black or
its last frame. Removing the clone restored the LCD. Not pursued further.

**SpringBoard compositing works.** `com.vphone.display.inner.show` puts a
window on Main above everything and, every 250 ms, keeps one `CALayerHost`
per visible window of every scene on the inner display, by
`-[UIWindow _contextId]`, ordered by window level (the way scene hosting
shows app contexts). `.hide` removes it and Main shows again. A test window
on the inner scene (`com.vphone.display.inner.pattern`: teal, a clock
ticking every second, a tap count) appeared live on the physical panel,
checked from the VM window's own framebuffer (`screencapture -l`), not the
guest screenshot, which renders Main's layer tree.

**Touch follows.** backboardd hit-tests the render tree, so a touch on a
hosted context goes to the process that owns it. Host taps at panel
pixels (500, 700) and (1500, 2400) reached the inner window's tap
recognizer at (166.7, 233.3) and (500.0, 800.0) points: exact, with no
forwarding code.

**Geometry.** SpringBoard's own display transformer gives the inner panel a
portrait interface mode (669×951, pixels 2007×2853; the 951×669 landscape
mode stays in `otherModes`), so the inner scene is 669×951 and on this
portrait-mounted panel it composites upright at scale 1. FoldDisplay's
transformer hook only changes Main.

Still open: the inner display carries only SpringBoard's bringup and
aperture scenes, so it has no home screen or apps of its own yet; showing
it is manual (no fold/posture wiring); it is only seen after a
SpringBoard-only restart. The guest screen also sleeps within seconds after
these restarts, so captures need a wake first.

### Which panel is Main on a real Duo (2026-10-28 night)

The iPhone19,4 device tree (`DeviceTree.v68ap.im4p` in the 27.1 restore)
answers it directly. Under `product`:

| Node | display-index | surface-type | display-rotation | Other |
|---|---|---|---|---|
| `display0` | 0 | 1 (`.cover`) | 0 | `Jindo` special region (the island), `has-prox` 1 |
| `display1` | 1 | 2 (`.inner`) | 270 | `BlankableRR` region and a `Fold` region |

The SoC has two internal display pipes, `dcp`/`disp0` and
`dcpsec`/`dispsec`; `display-crossbar0` routes only the external ports
(`dispext0`, `dispext1`). So the primary display (index 0, Main) is the
cover, and the inner panel is a second, simultaneously driven display
mounted at 270°: the topology this spike publishes.

PosterKit agrees. `PFCurrentDeviceClass` maps MG `DeviceClassNumber` through
a PosterFoundation table: 1 (iPhone) and 2 (iPod) → 0, 3 (iPad) → 1,
4 → 3, 9 → 2, 11 → 4, others → -1. The guest answers 0, the iPhone value,
and `PFContextSupportsDynamicRotation`'s `deviceClass == 1` is iPad. On an
iPhone only an auxiliary (non-main) display rotates its poster, so the
real Duo's landscape inner lock screen needs the inner panel to be the
non-main display.

`SBFStringForSurfaceType` gives 0 `.default`, 1 `.cover`, 2 `.inner`;
`SBFSurfaceTypeFromSSKSurfaceType` is the identity for 1–3. backboardd's
`BKSDisplayTraits.surfaceType` comes from `DeviceSurfaceType` in the
display's `extendedProperties`, which on this guest is supplied by
`FoldDisplaySurfaceProbe.m` (2 for the primary panel, 1 for the others), so
traits read back from the guest are not evidence of native roles. Nor is
`legacyMain (.inner)` in the resolver log, which is FoldDisplay's own
`vpSyncLogicalRoleResolver`.

For later: the inner panel's `Fold` region is `{0, 1335, 1878, 0}` in its
own pixels, which suggests a 1878-pixel-wide panel folding at row 1335;
this guest's 2007×2853 Main and the spike's 2853×2007 inner display were
not taken from the device tree.

### SpringBoard's own posture logic drives both displays (2026-10-28 night)

With the inner display published, backboardd now answers the device tree's
roles through `extendedProperties` `DeviceSurfaceType`: the primary panel 1
(`.cover`), the inner display 2 (`.inner`). FoldDisplay's SB-side
`vpLogicalSurfaceType` and `vpSyncLogicalRoleResolver`, which forced Main
to `.inner` for the single-display model, step aside while the inner display
is requested. SB-main then reads surfaceType 1 and the inner scene 2.

`-[SBDisplayContentModeCoordinator windowSceneDidConnect:]` is what calls
`-[SBFDisplayContentModeResolver startResolvingContentModeOfDisplayForWindowScene:]`,
and the inner display's bringup scene is never handed to it.
`com.vphone.display.inner.resolve` hands it over (once; the resolver's
`_displayProxies` is keyed by hardware identifier). The resolver then holds
`legacyMain` (`.cover`) and the inner display (`.inner`), and the hinge
picks the policy natively:

| `display.posture` | Prevailing policy | Cover (Main) | Inner |
|---|---|---|---|
| `open` (hinge 3, 180°, `.openFlat`) | `FoldingDual`, primary on `.inner` | `.auxiliaryContent` | `.primaryContent` |
| `closed` (hinge 1) | `FullyClosed` | `.primaryContent` | `.disabled` |

Closed, the panel shows SpringBoard's real cover lock screen and the VM
window is cover-sized. Open, the panel goes black at 0 fps: SpringBoard
turns the cover display off, as on a real Duo, and on this guest the cover
is Main, the only physical scanout, so the composited inner display has
nowhere to appear. SpringBoard stayed up throughout.

### Open: the cover is powered off below CAWindowServerDisplay (2026-10-28 night)

`com.vphone.display.inner.server-state` logs each render display as
backboardd holds it. Closed: primary `enabled=1 isBlanked=0`, inner
`enabled=0 isBlanked=1`. Open: the reverse. backboardd powers the panels
as a real Duo does, which on this guest leaves the only scanout (the
primary) off.

Swizzling `-[CAWindowServerDisplay setEnabled:]`/`setBlanked:` showed
neither is called for the primary when the device opens; the change comes
from below (QuartzCore has `CA::WindowServer::Display::set_power_state`
and `IOMFBDisplay::set_power_state_locked`). Re-enabling and unblanking the
primary through the original setters whenever the inner display was lit
did make the flags read `enabled=1 isBlanked=0` while open, but the VM
display still showed no frames (0 fps), so the power state underneath
stayed off. The experiment was removed. The next lever is either the C++
power path for the primary, or keeping SpringBoard's backlight host for
the cover on while the inner display holds primary content.

Separately, SpringBoard crashed three times while the posture changed with
both panels resolved: a Swift fatal error in UIKitCore
`ScrollEdgeEffectView.swift`, reached from `-[UIWindow
_sceneSettingsSceneRegionsDidChange:]` → layout. It restarts on its own;
the cause is not yet known.

### Open shows the inner display; touch reaches it but not its windows (2026-10-28 late)

- **Compositor:** a remote `CAContext` on the primary display (level 1e9),
  not a window of SB-main: open, SpringBoard gives the cover auxiliary
  content and takes SB-main's windows off screen. The context works in the
  panel's pixels, so hosted inner points are scaled by the point scale, and
  the fit is redone whenever the panel's size changes.
- **Panel power:** SpringBoard drives each panel through
  `-[CADisplayStateControl transitionToDisplayState:withCompletion:]`
  (state 1 on, 0 off; `_display_id` 1 cover, 7 inner); backboardd does not.
  The cover's state is the union of both wants, and the inner display's
  own state shows and hides the compositor.
- **Screen idiom:** `-[UIScreen _updateUserInterfaceIdiom]` gives the
  device idiom only to UIKit-main-like screens; the inner screen was -1,
  which UIKit's Swift idiom switch in `ScrollEdgeEffectView.swift` traps
  on during posture changes. The inner screen now takes the device idiom;
  no SpringBoard crash since.
- **Resolution:** a watch from SpringBoard's start hands the inner scene to
  `SBDisplayContentModeCoordinator`, so the fold button works without
  manual steps.
- **Touch:** `-[BKHIDDirectTouchEventProcessor
  _queue_displayUUIDForDigitizerService:]` (asked per event) reports the
  inner display while it is lit, and `_queue_addDigitizerStateForService:`
  (returns an object) creates the touch state under it. backboardd's hit
  test then finds inner windows (`windowServerHitTestWindow` names them),
  but SpringBoard's UIKit sends the events only to `_UISystemGestureWindow`
  and then "to windows: 0": touches do not reach the inner windows yet.

With the device open, the panel shows SpringBoard's own landscape lock
screen and home screen for the inner display, with the landscape poster.

## 2026-10-29: the single-display path removed

The two-display path above is now the only Duo display path. The
single-display approach, one portrait Main made to stand in for whichever
panel was active, is gone from FoldDisplay, vphoned and the guest
components. Once the inner display was published, SpringBoard resolved
`FoldingDual`/`FullyClosed`, the surface types and each screen's status bar
for both displays itself, and every single-display shim either stepped aside
when the inner display was requested or patched a consequence of the
one-display model (PosterKit `DISPLAY_TYPE_EMBEDDED`, Main carrying the inner
panel's metrics, one scene arbitrating both panels' orientations).

On iPhone19,4 the inner display is always published: there is no marker file,
and the constructor checks `hw.machine` in backboardd and SpringBoard alike.
The other `.once` markers and every `com.vphone.display.*` notification are
gone too, so the instructions in the sections above that post them or create
those files no longer apply.

Removed:

| What | Was for |
|---|---|
| `FoldDisplayViewport.m`, `FoldDisplayPipeline.m` | the cover/inner logical viewport on Main (the 466×678 mode override in `SBMainDisplayConfigurationTransformer`, root scene frame adoption, workspace refresh) and the display pipeline observation |
| `FoldDisplayOrientation.m`, `FoldDisplayOrientationMap.m` | root scene orientation arbitration and actuation, backboardd orientation-event probes, `vphone-display-orientation-map.json` |
| `FoldDisplayScreenFamily.m`, `FoldDisplayUIConfiguration.m` | home-screen family and UIKit configuration overrides for one Main |
| `FoldDisplayWallpaper.m` | the `TraitsArbiterWallpaperTokyoDrift` feature answer, the caller-scoped `PF_IS_PAD_DEVICE` landscape gate, wallpaper scene host sync |
| `FoldDisplayQuickActions.m` | the 0.70 lock-screen glyph scale, which compensated for Main carrying the inner panel's metrics |
| single-display parts of `FoldDisplayStatusBar.m` | the Main status lookup and its pulse, the scene status policy, the profile factory lease, the clock reference adapter, status re-registration |
| `FoldDisplayDiagnostics.m`, `FoldDisplayVirtualDisplay.m`, `FoldDisplayInnerTouch.m` | inspection dumps, virtual display experiments (the unknown-tag helper moved next to its caller), a fallback hit test that never fired |
| the Stage 1 test pattern and inspection report | `com.vphone.display.inner.pattern`/`.inspect`; `.show`/`.hide`/`.resolve`/`.server-state` went with them, the panel power and resolution watch drive the same code |
| `PosterProbe` (`libvphoneposterprobe.dylib`) | poster extensions following the orientation map and vphoned's interface broadcast |
| vphoned's Duo branches | `display.posture`'s viewport requests, pose/arbitration/actuation pokes, map polling and portrait confirmation; `display.rotation`'s mapped path; `display.orientation_mapping` and `display.geometry`; `GuestDisplayRotation` |
| host `display.geometry` reads | the VM window's viewport crop and the automation socket's active viewport; both now use the full panel |

What remains in `VPhoneGuestComponents/FoldDisplay`:

| File | Owns |
|---|---|
| `libvphonefolddisplay.m` | the constructor: iPhone19,4 only, backboardd or SpringBoard |
| `FoldDisplayBackboard.m` | the render display (from `_detectDisplays`, with the server-ready fallback), its `unknown` tag, the device tree's surface types, digitizer routing and the 270° touch turn |
| `FoldDisplayAdapter.m` | CADisplay type, point scale and external answers, the FrontBoard classification scope, the main-like identity for applications, the screen idiom, content mode resolution |
| `FoldDisplayPanel.m` | shared scanout power (the cover wins the panel) and the compositor with its per-frame damage layer |
| `FoldDisplayStatusBar.m` | each screen's status bar provider |
| `FoldDisplaySupport.m` | the log, the inner display's name, the object readers |

`display.posture` now sets SpringBoard's test-automation pose override,
publishes the hinge angle (a sweep for `position`, at once otherwise) and
replies with the request's values and the hinge service state, as before.
`GuestFoldPose` replays a configured hinge after boot (portrait, the saved
angle's hinge state) until SpringBoard reports it, and the latest pose after
each SpringBoard startup. `display.rotation` went back to the generic iPhone
path here, which turns neither panel; see the rotation section below.

To check on the device after this change:

- Closed on a machine booted on the inner-size panel: the cover is Main at
  the panel's full 669×951 (the 466×678 viewport is gone) and the window
  shows the whole panel.
- The cover lock screen's quick-action glyphs at their native size.
- The inner lock screen's landscape poster without the `PF_IS_PAD_DEVICE`
  gate and the wallpaper traits answer.
- The lock-screen and status-bar clock still advancing each minute without
  the clock reference adapter (it worked around a detached reference view
  with a nil screen; see f7d145ca above).
- `display.rotation` while open.

## 2026-10-29: flicker, screenshots and rotation on the two-display path

Verified on duospike-inner (iPhone19,4, iOS 27.1) with a bundle built from
this branch, running the cleaned-up code above.

**Flicker.** Measured with a ScreenCaptureKit capture of the VM window at
120 Hz and per-frame luma. Three causes, each confirmed by its frames:

- The compositor re-set every host's frame and zPosition on each sync pass,
  changed or not; each set made the render server drop every hosted window
  for one frame (a fully black frame, several a second at idle). Hosts are
  now updated only when a value changes.
- Hosts followed SpringBoard's windows on a 250 ms timer, so a window
  SpringBoard showed (the app-launch transition, the app's scene host) had no
  host for up to a quarter second. The sync now runs in a main run loop
  observer just before Core Animation's commit (order 1999999), in the same
  transaction as SpringBoard's own window changes.
- The per-frame damage layer: an opacity flip rendered the container
  offscreen (grey blocks over secure windows); a 1/255 tint alternated the
  panel's brightness at 30 Hz. It alternates between two clear colors.

Rejected while measuring: `setDisablesUpdates:YES` on the inner render
display (inner touch stops: backboardd hit-tests the rendered display) and
`CALayerHost.rendersAsynchronously` (hosts render nothing). Result: 0 black
frames in about 2700 captured frames across idle, taps, scrolling and
home/app transitions.

**Screenshots.** UIKit's screen capture (vphoned's `screen.screenshot`, and the
host's saved screenshot that goes through it) renders display-level contexts
in points, as it renders windows; a context of its own on the display works
in pixels. The compositor was such a context, so a capture with the device
open came out magnified by the screen scale (the top-right third of the inner
display), the way icli already notes for the boot logo. It is now a layer at
the top of Main's `UIRootSceneWindow`, the window Main's scenes are hosted in,
in points like every window (every SpringBoard window measured 669×951 points
with an identity transform). Closed, the capture is the full cover; the old
466×678 cut is gone.

**Rotation.** Neither panel turned: `display.rotation` reported "did not
apply" for the cover and the inner panel alike, in Safari too. The chain:

1. Each panel's traits pipeline (`SBTraitsEmbeddedDisplayPipelineManager`,
   `_surfaceType` 1 for the cover, 2 for the inner panel) takes its device
   orientation from the device pose, per panel:
   `BSDeviceOrientationForSurfaceFromPose(surface, pose)` reads the pose's
   cover or inner orientation, and `poseProvider:didUpdateFromPose:toPose:`
   updates the pipeline only when that per-panel value changes. The
   accelerometer orientation and AssistiveTouch's `setOrientation:` (icli's
   rotation) never reach it.
2. The test-automation pose override (`SBSTestAutomationService
   setDevicePoseOverride:`, which `display.posture` uses) carries one device
   orientation. SpringBoard derives each panel's from it with
   `+[CMMagicPoseManager orientationForMagicPose:deviceSurface:]`.
3. That method asks `+[CMMagicPoseManager sharedManager]` to rebuild a
   `CMDeviceStateEvent` first. The guest has no motion coprocessor, so there
   is no shared manager: the message goes to nil and both panels read
   ambiguous, whatever the pose.
4. The mapping itself is `+[CMDeviceStateEvent
   propertyAForConfigType:propertyA:propertyB:propertyC:]` (configuration =
   surface, A = orientation, B = hinge state, C = tabletop pose). Closed (B 1)
   the cover takes A and the inner panel is ambiguous; partially open or open
   flat (B 2, 3) the inner panel takes A and the cover takes A with landscape
   left/right and face up/down swapped; any other hinge state, including
   `open` 4, is ambiguous. `position: open` sets open flat (3).

FoldDisplay answers `orientationForMagicPose:deviceSurface:` with that
mapping directly, and vphoned's `display.rotation` on a foldable sets the pose
orientation for the lit panel (table in `Research/vphoned_http_api.md`).
Checked: cover 90/270/0 and inner 0/180/270/90 in Safari, each settled with
the interface and the host window upright; the cover home screen stays
portrait, as on any iPhone.

Open: in landscape on the cover, the `AxisAlignableSplitV68Cover` status bar
draws its time and battery over Safari's address field.

## 2026-10-29: the fold owns the panel; hidden windows hosted

Reported after manual testing on duospike-inner: the fold control sometimes
left the screen on the inner display or black instead of the cover, the inner
Dock did not respond, and the screen still flickered.

**Fold control.** The shared panel used to follow SpringBoard's power
requests alone (lit while either panel wanted it, the cover winning). Those
requests do not follow the fold:

- With the inner display asleep (the 60 s auto-lock), closing made SpringBoard
  light the inner display for about three seconds and then turn it off; the
  cover was never asked on. The panel showed the folded-away inner display,
  then went black.
- In a long-running SpringBoard, a close resolved FullyClosed (SpringBoard's
  log said so at the next open) without any power request: the panel kept
  showing the inner display.

The panel now belongs to whichever display holds the primary content,
`-[SBDisplayContentModeCoordinator primaryWindowScene]`, and is lit while
that display wants to be; the other panel's requests are applied but not
shown. Ownership is re-read on every power request and after each
`performDisplayContentModeTransitionWithCoordinator:`, so a fold without a
power request still hands the panel over. With that, SpringBoard's own
requests land on the right panel: closing awake, closing after the auto-lock,
closing after the sleep button, and opening asleep each light the arriving
panel (the cover's lock screen or home screen, the inner lock screen). An
extra wake on a fold, tried first, was not needed.
(`_displayContentModeChangedWithContext:continuationLockProvider:` appears in
the symbols only through its blocks; the runtime has no such method.)

**Flicker.** A 120 Hz capture with a per-tile transient detector (a 24×24
grid, a tile that jumps and comes back within two frames) found one frame left:
going home from an app, the first frame of the shrinking app sat on black.
The compositor hosted only visible windows; the home screen's windows came
back with new `CALayerHost`s, and a host draws nothing for its first frame.
Hidden windows are now hosted too (they draw nothing); the frame shows the
dimmed home screen blur instead (backdrop 0.22 instead of 0.12, brightening
over the next frames).

**Touch.** Automation taps and guest-injected touches with and without edge
flags land at the expected points on all four edges and corners, in every
orientation (`locationInView:` equals the screenshot point divided by 3),
and the Dock launches its apps after folds, rotations, sleep/wake and app
switching. The user's dead Dock was in a SpringBoard that had been running
for hours and was not reproduced; once, right after a SpringBoard restart and
a fold, the Dock ignored taps until the next restart while the home screen's
own icons kept working. Not yet explained; the next occurrence should be
caught with `logs.syslog` for SpringBoard during a Dock tap ("Sending UIEvent
... to window" and "Allowing tap for icon view").

## 2026-10-29: host zombification against app-launch black frames

**Symptom.** After the fixes above the user still saw an occasional flicker.
A 120 Hz ScreenCaptureKit capture of the VM window, with per-frame luma,
found it: one or two frames in which the whole panel is black (luma 0, the
compositor root's own black), sometimes alternating with a frame in which an
app is only partly drawn, about 0.4 to 0.6 s after an app launch or on the
way home. Same rate in portrait and landscape; never on the cover (no
compositing there). Sequence used: launch Safari, home, Settings, home,
Safari by `apps.launch`, 2.5 s apart; it flashed in about 18 of 26 runs.

**Ruled out, each by the same measurement:**
- Host layer changes: a trace of every `CALayerHost` add, remove, frame and
  zPosition change logged nothing during a flash.
- SpringBoard fences: `CAFenceHandle` / `-[CAContext addFence:]` bursts
  (logged with a calibration mark, a one-frame white layer, to align the
  guest clock with the capture) do not coincide with the flashes.
- GPU load of the inner virtual display: with SpringBoard keeping the inner
  display powered off while it owned the panel, content kept updating and the
  flashes stayed (3 of 5 runs). The inner display's update rate does move the
  rate (30 Hz 1/5, 60 Hz ~5/7, 120 Hz 5/5), which follows how often apps
  commit, not load.
- `copyDisplayTimingsFromDisplay:` (inner timed by Main): no change.
- `rendersAsynchronously` with an `asynchronousRenderPeriod` of 1/120: the
  hosts draw nothing at all, as before.
- A render-server probe in SpringBoard (`CARenderServerRenderDisplay` of
  both displays) sees Main and the inner display change together, but costs
  15 to 80 ms a sample and misses one- and two-frame events.

**Fix.** `CALayerHost.zombificationMode = kCALayerHostZombificationModeAlways`
on the compositor's hosts: a host whose context the render server briefly
finds nothing to draw for keeps that context's last frame. The same
sequence then flashed in 3 of 19 runs (one event each). Setting it on every
`CALayerHost` SpringBoard makes (its scene hosts too) was no better (4 of
10), so only the compositor's hosts get it. Going home, the app switcher,
rotation and folding show no stale content (the switcher's blank snapshot
cards are the same without it).

**Left.** The remaining flash is still a fully black frame at an app launch.
Likely, but not shown, it is SpringBoard's new scene host for the launching
app drawing nothing for its first frame when the primary display renders
it, the same first-frame blank the compositor's own hosts have; there is
nothing to keep for a new host.

## 2026-10-29 afternoon: the panel shows the inner display's own frames

Zombification (above) hid most black frames; the user wanted the cause gone,
and then also saw small red blocks beside a launching app's icon and ghosting
Liquid Glass behind Notification Center (both with an intermediate portal
build). The cause, found from data rather than screenshots:

**A context has one host.** `CA::Render::LayerHost::retain_hosted_context`
looks the hosted context up and, when it already has a host (its `+0x1d8`),
detaches that host (clears its `+0x58`/`+0x60`, flags the old hosting
context `0x2000` for re-resolution), takes the context, and rebinds it to the
new host's display (`Context::set_display_mask`/`set_display_id` from the
hosting context's `+0x2a8`/`+0x2ac`; `set_display_mask` also sends the owning
client a Mach message). Every window of an inner scene is already hosted in
the inner display's root scene window, so one `CALayerHost` per window on the
primary display meant two hosts per context taking it from each other: on
SpringBoard's commits during transitions the inner root took the windows
back, and the panel showed those windows empty for a frame or two. A
diagnostic build with a red compositor root showed exactly that: the holes
were red and per window (only the Dock left, or icons without the wallpaper
and widget contents), never SpringBoard's own layers of a window still held.
It also explains why re-setting a host's frame or zPosition blanked hosted
windows for a frame (the host commit re-ran the takeover).

**Ruled out on the way:** host layer changes (traced: none at the flashes);
SpringBoard fences (bursts do not align with flashes once both clocks are
aligned by a white calibration frame); GPU load of the inner display (powered
off, flashes stayed); `copyDisplayTimingsFromDisplay:`; asynchronous hosts.
The inner display's update rate did move the rate (30 Hz 1/5 runs, 60 Hz ~5/7,
120 Hz 5/5) because it paces the commits that trigger the takeovers. A
cross-display `CAPortalLayer` of the inner root scene window takes nothing
over and removed the window holes, but everything that depends on the display
it is drawn for broke instead: SpringBoard's own portals (app zoom, switcher)
left holes and a black first frame going home (setting `crossDisplay` on them
helped only from `init`, which aborts SpringBoard when a portal is made off
the main thread: `CA_ABORT_ON_NON_MAIN_THREAD_TRANSACTION_PUSH`; five aborts
sent the next boot into Device Recovery), and backdrops sampled the primary
display (ghosting glass). The render server's clone (`addClone:options:`, every
option combination, with the LCD forced on) puts only black frames on this
paravirtual panel; `CARenderServerCaptureDisplay` of the virtual display
returns nothing.

**The fix:** on each primary frame SpringBoard has the render server draw the
inner display into a surface (`CARenderServerRenderDisplay(0, "VPhone Duo
Inner", surface, 0, 0)` on a serial queue, about 3.5 ms) and shows it in a
layer at the top of Main's root scene window, turned -90 degrees; three
surfaces rotate so the render server never draws into the one shown or the
one shown before. The panel shows the inner display's own frame, one primary
frame late, with its backdrops, portals and hosts as the inner display draws
them; nothing is hosted twice, so nothing is rebound. Measured over 12 launch
sequences and 3 home/Dock runs: no black or partial frames, 0-6 transient
tiles per run against 12-23 with the portal; scrolling updates at the same
rate; taps on the inner display and the guest screenshot are unchanged.

**Test trap, not a display bug:** after a SpringBoard or backboardd restart,
touches vphoned injects (`input.touch`/`input.tap`, and so the host's clicks
within 32 points of an edge: swipe home, Control Center, Notification Center,
and the Dock at the usual window size) no longer reach SpringBoard until the
guest reboots; the host's VZ taps keep working. Seen with the bundle's own
build as well. Not yet explained.

## 2026-10-29 evening: the panel is the cover's

Main (the paravirtual panel) had been sized for the inner display,
2007×2853 (669×951 points), since the single-display design, where SpringBoard
laid the inner content out on Main itself (`VPhoneBootCommand` replaced the
machine's 1398×2034 screen with `iPhone19_4InnerScreen` on every boot). With
the two-display path that reason is gone: the inner display is its own
2853×2007 virtual display, and Main is the cover. A cover laid out on
669×951 points looked like a second inner display, not the Duo's outer one.

vphone-vm now boots the machine's own screen, 1398×2034 at 3x: the cover is
466×678 points with its native layout (the right-side Dock and status column
are the Duo's outer-display design). Open, the compositor turns the inner
display upright and fills the panel with it: 0.697 across and 0.713 along,
about 2% tighter across than along. A first version kept the proportions and
left 23 px black bars along the long sides, which the user did not want; with
the fill, the digitizer (which spans the panel) maps onto the whole inner
display, so backboardd's touch turn needs no rectangle of its own.

Measured on the test VM (bundle built from this change):

- Taps logged in SpringBoard land at the expected points: inner, panel pixel
  (X, Y) of the landscape screenshot at (X × 951 / 2034, Y × 669 / 1398) points
  for the centre and four corners (no bars); cover, at (X / 3, Y / 3).
- Guest screenshots match the VM window at offset (0, 0) in all four inner and
  three cover orientations (cover tested with Safari, which rotates on iPhone).
- Three launch-sequence captures: no black frames, 2-5 transient tiles.

## 2026-10-29 night: the inner display at 120 Hz

Open, the VM window counted 60 fps while the cover (the paravirtual panel,
with the ProMotion patch) runs at 120. Two caps, one in each process:

- **backboardd.** A `CAWindowServerVirtualDisplay` gets one 60 Hz mode whatever
  `kCAVirtualDisplayUpdateRate` says. `VirtualDisplay::refresh_rate()` uses the
  update rate only while the display has no current mode; with one, it takes
  the mode's 16.16 rate. `heartbeat_rate()` is that mode's period divided by
  the integer `kCAVirtualDisplayMinimumFrameDuration` (default 1). Clients read
  `CADisplay.refreshRate` (the mode), and `UIScreen.maximumFramesPerSecond`
  is its inverse, so every app on the inner display was capped at 60
  (UpdateRate 120: the display ticked faster, apps still saw 60; UpdateRate
  60 + MinimumFrameDuration 2: heartbeat 1/120, refresh still 1/60).
  The display's modes can be replaced with `-[CAWindowServerDisplay
  setDigitalModes:withTimings:]` (`VirtualDisplay::set_digital_modes`), which
  takes the framebuffer timing format: timings with `HorizontalAttributes` /
  `VerticalAttributes` `{Active}` and `VerticalAttributes.PreciseSyncRate`
  (16.16, default `0x3c0000` = 60), optional `Score`, and color modes
  (`PixelEncoding` 0, `Depth` ≤ 8, `Colorimetry` 1/10/16, `EOTF` 0,
  `DynamicRange` 0). A mode is preferred only when its score is above 0
  (Colorimetry 16 adds 2, plain RGB nothing); with no preferred mode the
  display comes up 0×0 and SpringBoard aborts in
  `-[SBMainDisplayConfigurationTransformer transformDisplayConfiguration:]`.
  FoldDisplay now sets one timing, 2853×2007 at 120, with Colorimetry 1 and
  Score 1: the inner mode reads `RGB_8bit` like the panel's.
- **SpringBoard.** The compositor's display link asks for the panel's
  `maximumFramesPerSecond` (120 with the ProMotion patch, else 60).

backboardd cannot read the panel's rate while it adds the inner display: the
primary's rate is not set yet during display detection, and asking
`CADisplay` there blocks backboardd (the inner display never appeared).

Measured on duospike-inner (iOS 27.1, Settings open, 3 s windows):

| | panel (LCD) | inner |
|---|---|---|
| `UIScreen.maximumFramesPerSecond` | 120 | 120 (was 60) |
| `CADisplay.refreshRate` / heartbeat | 1/120 / 1/120 | 1/120 / 1/120 (was 1/60) |
| default `CADisplayLink`, ticks in 3 s | 377 | 377 |
| compositor renders in 3 s | | 375-378 |

Idle CPU on the home screen, three 10 s samples each: 60 Hz build SpringBoard
6.9-7.9%, backboardd 37.8-45.6%; 120 Hz build 9.3-10.4% and 50.3-51.3%.

Window captures (ScreenCaptureKit) cannot judge 120 Hz here: the cover, which
is natively 120, measures the same 40-55 changes per second as the inner
display, because the host composites the window at its own rate. Use guest
display links, or the host's `lastSubmittedTime` poller from the vGPU notes.
### Expanded Now Playing corners (local diagnostic, 2026-10-29)

On iPhone-Duo (27.1 24A94425), the unfolded expanded Now Playing panel
provided by Broadcasts has a rectangular outer black background while its
artwork remains rounded. A read-only UIKit probe reports 59 points for the
cover's `_displayCornerRadius` and `_displayCornerRadiusIgnoringZoom`.
Constructing a private, unregistered UIScreen from the inner CADisplay's
FBSDisplayConfiguration reports zero for both getters and `_isEmbeddedScreen`
false. This daemon-side object does not include SpringBoard's display adapter,
so it establishes the native virtual-display default, not the exact live
SpringBoard screen state.

A local FoldDisplayAdapter experiment intercepts those two getter selectors
(ABI checked as d16@0:8), matches only the recorded inner display identity,
and substitutes the main screen's original native value only when the inner
value is zero. A nonzero native inner value and every other display pass
through. Limited logging records native/main/effective values in SpringBoard.
No device-tree, MobileGestalt, firmware or host security setting is changed.
The original source is saved outside the source tree as
`.vphone-setup/FoldDisplayAdapter.before-corners.m`; previous environment
bundle 2.14.0-local.e1ece920 remains available for rollback.
Validation and visual outcome are recorded below after deployment.

**Validated:** Release VPhone build passed without warnings/errors. Installed
local bundle `2.14.0-local.232df3b7`, updated the existing guest environment,
and cleanly restarted (vphoned connected in four seconds). Actual SpringBoard
logs now confirm `_displayCornerRadius native=0.00 main=59.00 effective=59.00`
for the inner screen, so the earlier daemon probe matches the live symptom.
The user reproduced the Broadcasts panel and confirmed “that's fixed now.”
Previous bundle retained for rollback; no additional change is pending.
