# iPhone Duo single-display bring-up

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
