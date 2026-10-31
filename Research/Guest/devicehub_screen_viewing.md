# DeviceHub screen viewing

For host DDI selection, the newer cryptex protocol and the HomePod-specific
staging investigation, see [Developer disk images on virtual guests](developer_disk_images.md)
(2026-10-23). Its live HomePod result does not extend the validation below to
HomePod screen streaming.

Xcode 27 ships `DeviceHub.app` (`Xcode.app/Contents/Applications`, bundle id
`com.apple.dt.Devices`). It lists vphone guests as "iPad / iPhone — Virtual
Machine" and, for a paired guest with its developer disk image (DDI) mounted,
opens a live view of the screen. Before this work the view spun forever on
every guest, 26.x and 27.x alike.

Measured with Xcode 27.0 (27A266a) and CoreDevice 642.16 on macOS 27.0.1,
against `iPad16,1` 26.6.2 (23G90) and 27.0.1 (24A446) and `iPhone17,3` 26.6.2
and 27.0.1 guests over cloudOS 26.4, 2026-10-06 and 2026-10-07.

Status: the live view works on iPadOS 26, iOS 26 and iOS 27 (an iPhone Duo
follows its fold, see [iPhone Duo: the fold](#iphone-duo-the-fold)); iPadOS 27 refuses
pairing and is untested. Known issue: under load (several VMs streaming, or the
Mac busy restoring or downloading) the view can stall for seconds or fall
seconds behind and stay there until the stream restarts. A single stream on a
quiet Mac showed no growing delay in two hours, though two short encode stalls
still occurred (see
[Known issue](#known-issue-stalls-and-growing-latency-under-load)). A stream
that splits each frame into bands deadlocked the host GPU until the library
also loaded into `avconferenced` (see
[Banded streams](#banded-streams-deadlock-the-host-gpu)).

## What stopped it

Each version stopped at a different place, and a 27.x iPhone stopped at all
four:

| Stage | Symptom | Affects | Fixed by |
| --- | --- | --- | --- |
| DDI mount | "connected (no DDI)" for good | 27.x | `cryptexd` hook |
| Feature query | `supportedFeatures: 0`, view spins | every guest | `dtremotedisplayd` hook |
| Capture display | stream starts, view stays black | 27.x | conditional IOMFB dispatch |
| Display metadata | screen drawn over the bezel corners | 27.x iPhone | `dtdeviceinfod` hook |

### iOS 27: the DDI does not mount

CoreDevice personalizes the cryptex DDI (TSS succeeds) and hands it to the
guest, then nothing more happens. The device stays "connected (no DDI)" and
DeviceHub logs `No providers can handle Display ID: 1 … (bootState: Booted,
ddi: false)`. The guest's `cryptexd` says why:

```text
[protex] set protection class: [1: Operation not permitted]
[protex] copy asset: im4m: [1: Operation not permitted]
[protex] copy assets failed: [1: Operation not permitted]
[codex] system: staging failed [1: Operation not permitted]
```

In `__protex_stage_continue` (`/usr/libexec/cryptexd`, 27.0.1) each staged
asset is opened `O_RDWR` and given class D with
`fcntl(fd, F_SETPROTECTIONCLASS, 4)`. A failure other than `ENOTSUP` (45)
aborts staging, and the guest returns `EPERM`. iOS 26 guests mount the DDI
without this.

### Every guest: no media stream features

DeviceHub asks the device for its media stream features before it starts a
stream (`MediaStreamGetSupportInfoActionDeclaration`, forwarded to the device
feature `com.apple.coredevice.feature.getmediasupportinfo`) and repeats the
question with backoff (1 s, 2 s, 4 s … 30 s) until the answer is non-empty. A
guest answers every time with

```text
SupportInfo: supportedFeatures: 0 (No supported features are available:  (Raw Value: 0),
    avcFrameworkVersion: Optional("2215.5.1"), coreDeviceVersion: nil)
```

and DeviceHub logs `No framebuffer provider found for Display ID: 1 —
creators tried: [… AVConferenceDisplayViewFramebufferProviderCreator=
canProvideView:false …]`. The Mac reports its own features as
`Primary video display mirrored output stream, System audio output stream,
Display information (Raw Value: 140)`.

The answer comes from the DDI's `dtremotedisplayd`
(`/System/Developer/usr/libexec/dtremotedisplayd`, LaunchDaemon
`com.apple.coredevice.dtremotedisplayd`, user `mobile`). Its remote service
`com.apple.coredevice.displayservice` carries `getmediasupportinfo`,
`getmediastreamserverstatus`, `startaudiooutput`, `startvideooutput`,
`startmediastream` and `stopmediastream`. It returns
`MediaStreamSupportedFeatures.current` from the DDI's
`CoreDeviceUtilities.framework`
(`$s19CoreDeviceUtilities28MediaStreamSupportedFeaturesV7currentACvgZ`).

`current` builds a `CurrentDevice` and calls
`forDeviceInfo(osBuildUpdate:platform:deviceType:isVirtualDevice:mode:isProductionFused:hasInternalOSBuild:hasInternalDDI:)`.
Its log strings name the policies, and none of them is a capability check:

- `Remote control restricted. Device is customer-restricted (production
  fused, customer OS, customer DDI) and running pre-27.0 OS`. The predicate
  `CurrentDevice.isCustomerRestricted(isProductionFused:hasInternalOSBuild:hasInternalDDI:)`
  disassembles to `isProductionFused && !hasInternalOSBuild &&
  hasInternalDDI == false`. Every 26.x guest is refused here.
- `Remote control is only available on iOS 27.0, watchOS 27.0, or tvOS 27.0
  or later.`, shown when the device is not an iPhone, Apple Watch or Apple TV.
  Every iPad guest is refused here, whatever its version.
- A per-build table (`MediaStreamSupportedFeatures.MinimumVersions`) keyed by
  build, platform and device type, which also takes `isVirtualDevice`.

The guest does not persist the info-level `inputs:` line, and the hook replaces
the answer on every version, so the branch a 27.x iPhone would take on its own
was not observed. `current` also returns no features when `CurrentDevice.init`
cannot build the device identity (version number, build update, device type);
there is no compositor-readiness gate in it.

Feature bits (`MediaStreamSupportedFeatures` static getters):

| Bit | Meaning |
| --- | --- |
| `0x4` | primary display mirrored output (screen sharing) |
| `0x8` | system audio output |
| `0x40` | virtual external / secondary virtual display output |
| `0x80` | display information |
| `0x100` | video output by display ID |
| `0x200` | screenshot capture |

`devicectl device capture screen-record` is a separate feature
(`com.apple.coredevice.feature.screenrecording`) that a guest does not list,
so it is no way around this.

### iOS 27: the capture display is black

With the DDI mounted and features reported, a 27.0.1 stream starts but shows
black, and the guest's `FigVirtualDisplayProcessor` reports `Submits 0 /
Encodes 0`. backboardd logs, about fifty times a second:

```text
[WindowServer] display 2 get_wireless_surface_options returned error e00002d5 / e00002be
[WindowServer] display 2 swap_end returned error 10000003
```

Display 2 is the capture display the stream adds. `10000003` is
`MACH_SEND_INVALID_DEST`.

The cause is the iOS 27 force-kern patch (row 11 of the guest DSC table in
`Research/0_binary_patch_comparison.md`). iOS 27 presents the paravirtual
main display through IOMobileFramebuffer's in-process `_virt_Swap*` path,
which never reaches the 26.4 kernel's paravirtual GPU. The patch therefore
sent every public `_IOMobileFramebufferSwap*` call to `_kern_Swap*`, which
calls the kernel userclient. The capture display, however, is a genuine
virtual display: it has no userclient port, so its kernel swaps fail, and its
frames never reach the in-process consumer that `_virt_SwapEnd` hands surfaces
to. `get_wireless_surface_options` then has nothing to return
(`e00002be` is `kIOReturnNoResources`, `e00002d5` `kIOReturnBusy`).

Every `_kern_Swap*` implementation loads the connection's IOConnect port from
`[x0, #0x14]`. That port is non-zero for the paravirtual main display and zero
for the capture display.

### iOS 27 iPhone: no framebuffer mask

DeviceHub draws the screen inside a device chrome and clips it with a
framebuffer mask. The DDI's `dtdeviceinfod` (not `dtremotedisplayd`)
implements the DisplayInfo and DisplayInfoUpdates actions. It reads
`MGCopyAnswer("DisplayExtendedProperties")` and otherwise falls back to
`ChromeIdentifier` and `FramebufferIdentifier`. On the 27.0.1 guest these
answer `null`, `com.apple.dt.devicekit.chrome.phone11` and `null`. With a
chrome but no mask, DeviceKit falls back to a rounded rectangle and the
content runs over the bezel corners.

`/Library/Developer/DeviceKit/chrome_map.plist` maps `iPhone17,1` to `phone11`
with mask `4E5532ED-1470-47D1-BDF4-7AA90C26957A` (and `iPhone17,3` to
`phone9` with `A6AC96E7-…`). It has no entry for the guest's `iPhone99,11`.
`DeviceTreeGuestDevicePatches` deliberately keeps the virtual
`framebuffer-identifier` while copying the real board's chrome properties, so
the device tree is not the place to fix this. Matching the guest's resolution
to an iPhone 16 (1179x2556) did not change the overflow either.

## The fix

### `libdevicehubfix.dylib`

`VPhoneGuestComponents/DeviceHubFix/libdevicehubfix.c`, installed as
`/usr/lib/libdevicehubfix.dylib`. Both spawn hooks insert it into four
processes only (`vpIsDeviceHubFixTarget` in `Shared/InjectionEnvironment.h`):

- **`cryptexd`**: interposes `fcntl`. An `EPERM` from `F_SETPROTECTIONCLASS`
  is reported as `ENOTSUP`, which takes the path `cryptexd` already has for a
  filesystem without protection classes. Every other call and failure is
  untouched.
- **`dtremotedisplayd`**: interposes `MediaStreamSupportedFeatures.current`,
  which answers `0x184`: `0x8c`, what a Mac host reports for itself (the host
  intersects it with its own), without system audio `0x8` (the VM window
  plays the guest's audio already, and DeviceHub played it a second time),
  plus video output by display ID `0x100`, which an iPhone Duo's inner panel
  streams through (see
  [iPhone Duo](#iphone-duo-the-fold)); and `CurrentDevice.isCustomerRestricted`, which
  answers false. The struct is resilient (the framework is built for library
  evolution), so the getter returns it indirectly through `x8`; the
  replacement is three instructions of assembly.
- **`dtdeviceinfod`**: interposes `MGCopyAnswer`. Only when
  `FramebufferIdentifier` is missing and `ChromeIdentifier` is exactly
  `phone11`, it answers with Xcode's matching mask `4E5532ED-…`, retained under
  the Copy ownership rule. Existing answers and other chromes are unchanged.
  This is display metadata, not a change to the guest's hardware identity.
  On an iPhone Duo it also stands in for CoreMotion's hinge angle and device
  state managers and reports the inner display as integrated (see
  [iPhone Duo](#iphone-duo-the-fold)).
- **`avconferenced`**: replaces `VCPSideCarMetal`'s two band reads and runs
  one synchronous scaler transform before the first read of each frame (see
  [Banded streams](#banded-streams-deadlock-the-host-gpu)).

Interposing works because `cryptexd`, `dtremotedisplayd`, `dtdeviceinfod` and
`CoreDeviceUtilities` are standalone images, not shared-cache ones, so dyld
binds their imports through the interposing table. `CoreDeviceUtilities` lives
on the DDI and not in the SDK, so its two symbols are weak flat-namespace
imports (`-Wl,-U`) and resolve to nothing outside `dtremotedisplayd`.
`VideoProcessing` is in the shared cache, which an interpose does not reach,
so the band reads are replaced through the Objective-C runtime.

The library ships with `system-launchdaemons-boot-environment`. An existing
guest gets it from the environment update when it next starts on a bundle
that has it.

### Conditional IOMFB dispatch

`DyldSharedCacheIOMFBForceKernPatcher` now rewrites each public swap
trampoline as:

```text
cbz   x0, <original failure>
ldr   w16, [x0, #0x14]       ; IOConnect port, zero for the capture display
cbnz  w16, _kern_Swap<Name>
b     _virt_Swap<Name>
```

`x16` is an intra-procedure-call scratch register, so the arguments reach
either implementation intact. The public, `_kern_` and `_virt_` siblings are
resolved by name; only operations with all three take part, and `SwapBegin`,
`SwapEnd` and `SwapSetLayer` must be covered. Capstone checks the trampoline
shape and the port load's operands, `ARM64Encoder` produces all four words
(`encodeCompareBranch` is new, pinned against keystone), and the 16-byte write
spans are re-attested. On 24A446 it rewrites ten entry points and leaves
`SwapSignal`, which is not a thin trampoline, on its existing path. The
`0x14` port offset was verified on 24A446 only.

### Upgrading an existing iOS 27 guest

Nothing to do by hand: bind the machine to the new bundle with its guest
environment (Launchpad's bundle switch, or `vm set-bundle <vm> <version>
--update-environment`), or run `cfw install` / `cfw update-environment`.

The patch identifier did not change, and `applyDyldPatches` normally skips an
enabled patch whose identifier is already in the guest receipt, which would
leave the old 31 four-byte sites in place for good. The undo log tells the two
implementations apart: the old one recorded 4 bytes per entry point, the new
one 16. `DyldSharedCacheUndoLog.outdatedImplementations` names that shape, and
for such a patch the installer reverts its records and applies the current
implementation in the same run. A second run finds 16-byte records and leaves
the cache alone. If the revert succeeds and the new write fails, the patch is
reported as failed and left out of the receipt rather than listed as applied.

A guest patched before the undo log existed has no records, so it cannot be
reverted this way and keeps the old bytes; it needs a restore.

**Validated (2026-10-07, `iPhone17,3 27.0.1`):** the guest was put back on the
old implementation with bundle 2.6.0 (`31 newly forced`), then bound to the new
bundle with `--update-environment`. The log shows `an earlier implementation is
applied; reverting it and applying the current one`, 31 four-byte reverts and
`10 newly forced, 0 already conditional`. A further `cfw update-environment`
did not touch the patch. After boot the VZ window scanned out and DeviceHub
showed the guest live, 30–40 ms behind the VZ window.

## Validation

- **`iPad16,1 26.6.2 (23G90)`, new test VM.** DeviceHub receives
  `supportedFeatures: 140`, `MediaStreamStart` succeeds for audio and video,
  and the view shows the live home screen, also after a cold start on the
  built bundle. SystemHook logs `inserted+devicehubfix` for `cryptexd` and
  `dtremotedisplayd`. `cryptexd` never takes the `EPERM` path on 26.x. An
  unpatched 26.6.2 iPad kept answering 0 throughout.
- **`iPhone17,3 27.0.1 (24A446)`, new test VM.** Without the hook the DDI
  never mounts. With it the hook logs `F_SETPROTECTIONCLASS EPERM, reported as
  ENOTSUP` once and the device becomes `connected` with DDI services.
  - With the old patch the stream starts but stays black (above).
  - After reverting and reapplying with the conditional dispatch, the VZ
    window still scans out, the guest encodes 41–60 fps, and DeviceHub shows
    the home screen and Settings live.
  - With the mask, DeviceHub logs `Found FramebufferMaskIdentifier from
    displayInfo` with the `phone11` UUID, and the home screen and Settings are
    clipped inside the chrome at all four corners.
  - A swipe sent to the guest moved the Settings list identically in the VZ
    window and in DeviceHub.
- **`iPhone17,3 26.6.2 (23G90)`, new test VM (2026-10-07).** Paired on its
  own, `supportedFeatures: 140`, live view 50–150 ms behind the VZ window. It
  reports `phone11` chrome without a mask too; the `dtdeviceinfod` hook fills
  it and the corners are clipped inside the chrome.
- **`iPad16,1 27.0.1 (24A446)`, new test VM (2026-10-07).** The conditional
  dispatch writes the same ten sites and the VZ window scans out normally, so
  the patch does not regress iPad. DeviceHub could not be tested: the guest
  refuses pairing (`kAMDUserDeniedPairingError`, from `devicectl manage pair`
  and from Xcode alike) without showing a trust alert. That happens before
  any of this code is involved and is left for separate work.
- **Tests.** `InjectionEnvironmentTests` covers the four targets and their
  near-miss suffixes. The seven real-cache force-kern tests (pristine 24A435
  cache via `VPHONE_DSC_PRISTINE`) cover conditional routing, the preserved
  null check, symbol discovery, dry run and idempotence, and pass. `ARM64CompareBranchTests` pins the new encoder.

Touch input sent from inside DeviceHub reaches the guest (checked by hand),
but has no automated check.

## Banded streams deadlock the host GPU

Fixed. A stream can split each frame into bands that are encoded separately
(`tilesPerFrame` in the stream configuration). With four bands and a changing
screen, the 27.0.1 iPhone guest froze within 16–35 s: the picture stopped
while touch still worked, then the guest turned green and the VZ window
stopped, until the VM was restarted. The Mac logged `Timeout in timestamp
wait` and restarted its GPU, and the guest never got it back. A still screen
produces no new frames and did not freeze; a single-band stream never froze.

Measured with macOS 27.0.1 (26A434) on an M2 Mac and `iPhone17,3` 27.0.1
(24A446) over cloudOS 26.4 (23E5207q), 2026-10-07 and 2026-10-08.

### Who writes the frame and who reads it

- backboardd's CoreAnimation display thread
  (`com.apple.coreanimation.display.primary`) writes each capture frame (420f,
  1320x2868) with the M2 scaler, through
  `IOSurfaceAcceleratorTransformSurface`.
- `avconferenced` gets the frame before that transform has run on the Mac and
  does not wait for it: IOSurface implicit synchronization orders its reads
  after the write.
- With bands, VideoProcessing's `VCPSideCarMetal` reads the frame on the GPU
  once per band, in `temporalTransitionScore:previousFrame:forRegion:`
  (current and previous frame) and `copyFromFrame:toTile:origin:size:withFence:`.
  Each command buffer samples the frame's two planes as two textures. With one
  band neither method runs and the GPU does not read the frame.

Both run on the Mac. The guest's Metal commands are replayed by one
`ParavirtualizedGraphicsGPUTask` process per guest process, and scaler
requests (`AppleM2ScalerParavirtDriver`) by the VM process. Both end in the
Mac's IOSurface implicit synchronization, which the guest cannot see.

### Host synchronization

From the Mac's kdebug class `0x8521` (see [Measuring](#measuring)):

- The VM process runs scaler requests one at a time, and registers the write
  0.25–0.8 ms after taking a request.
- The GPU task registers a command buffer's accesses on its own path, and can
  register a band read inside that window, before the write.
- A command buffer registers each texture on its own, so the frame's two
  planes are two registrations, and another registration can land between
  them.
- Once a writer waits, new readers queue behind it.

At the deadlock, a band read registered plane 0 of the current frame, the
scaler's write registered 1 µs later and waited for it, and the same command
buffer's plane 1 registration 1 µs after that queued behind the write. The
surface was never released again; the scaler queue and the GPU FIFO stopped
together. In two traced runs a band read registered before the write in 26 of
779 and 20 of 564 frames. Most such inversions are harmless, because the write
waits for the read; only the 1–2 µs between two plane registrations
deadlocks, which fits a freeze after tens of seconds.

### The fix

Before the first band read of each frame (keyed by IOSurface ID),
`avconferenced` runs one synchronous transform between two scratch surfaces,
64x64 to 32x32. When `avconferenced` reads a frame, the VM process has always
taken the request that writes it already (779 of 779 frames, at least 234 µs
earlier), and a synchronous transform returns only after the host released its
write. The scaler runs requests in order, so when the barrier returns the
frame's write is done and no band read can meet it.

Neither method takes a floating-point argument, and the score method returns a
C++ future through `x8`, so the replacement saves `x0`–`x8`, calls the barrier
with the frame and continues into the original. If either method is missing,
nothing is replaced and the library logs `VCPSideCarMetal band reads not
found`.

Ruled out:

- `IOSurfaceLock` before the reads returns within microseconds without waiting
  for the host's write, and still deadlocked after 25 s.
- Waiting after the write in backboardd: QuartzCore reaches the scaler through
  a branch island, not its GOT, so an interpose does not see the call.
- One band per frame avoids the deadlock but gives up the lower latency bands
  are for.
- Leaving the scaler out of the VM configuration
  (`_VZMacScalerAcceleratorDeviceConfiguration`) would change every guest
  process that uses it; not tried.

### Validation

Four bands while swiping back and forth on the home screen, unless noted:

| `avconferenced` | Duration | Result |
| --- | --- | --- |
| unchanged | 18 s | deadlock |
| `IOSurfaceLock` before the reads | 25 s | deadlock |
| barrier | 60 s | no scaler write waited, no GPU error |
| barrier, after a reboot, traced | 180 s | no IOSurface access waited; every band read of 6258 frames after the write's release |
| barrier, after another reboot | 300 s | no GPU error, about 41 fps |
| barrier, one band | 90 s | about 55 fps as before, no barrier transform |

The barrier relies on two host behaviors that were observed, not documented:
scaler requests run one at a time and in order, and a frame's request is taken
before `avconferenced` reads the frame. A surface reused for two consecutive
frames would skip the second barrier; this was not seen, since
`temporalTransitionScore` holds the previous frame, and all 74651 band-read
command buffers of the 180 s run came after their frame's barrier.

### Cost

- Only `avconferenced`, and only when frames are split into bands: the two
  methods are not called otherwise. A single-band stream keeps its frame rate
  and the host sees no barrier transform.
- `avconferenced` waits in the barrier about 2 ms a frame, but without it most
  band reads waited on the host for the same write. What the barrier adds is
  the time from the write's release to the first band read: 760 µs median,
  442 µs at least.
- Four bands ran at 35–41 fps with the barrier, against about 29 fps without
  it before the deadlock.
- The host runs one extra 64x64 to 32x32 transform per frame.

## Known issue: stalls and growing latency under load

Not fixed. What a user sees and what helps:

- With several VMs streaming, or while the Mac restores or downloads, the
  DeviceHub view can freeze for 1–3 s, or its delay can climb in steps to a
  couple of seconds and stay there.
- A new stream clears the accumulated delay; this was verified by restarting
  the guest's `avconferenced`. Whether reopening the device in DeviceHub alone
  starts a new stream was not checked.
- In testing, one VM streaming on an otherwise quiet Mac showed no growing
  delay; two encode stalls of up to 1.4 s still occurred in two hours.
- The VM's own window is unaffected, so it remains the reference for timing.

The guest's HEVC encode is paravirtualized to the Mac and shared by every VM
([Encoding happens on the Mac](#encoding-happens-on-the-mac)), which fits the
dependence on load, but no profile of a stall has been caught yet. The
sections below are the evidence so far.

### Latency grows over a long session

Measured on the 26.6.2 iPad from a guest screen change (an `apps.launch` RPC)
to the first changed DeviceHub frame; the VM's own window takes about 0.4 s
for the same change:

| Stream age | DeviceHub |
| --- | --- |
| new | 0.48 s |
| about 12 min | 0.55–0.59 s, rising in steps |
| about 50 min | 2.6 s |

Recreating the stream (killing the guest's `avconferenced`) resets it.

Ruled out:

- **Mac receiver.** For the whole session the video jitter queue stays at
  100 ms (briefly up to 500 ms), one frame is pending, and the playback offset
  is constant. The image queue displays about 25 ms after enqueue. DeviceHub
  and `avconferenced` use a few percent CPU.
- **Guest encoder and transport.** HEVC encoding takes about 5 ms a frame,
  RTT is 2 ms, the one-way delay estimate 9 ms, with no loss.
- **The audio stream.** The audio path is unhealthy (erasures, late packets,
  an audio jitter queue that reached 11.76 s before it was discarded), but a
  video-only stream (features `0x84`) grew at the same rate.
- **Clock drift.** The guest's monotonic clock runs within 3 ppm of the host's.

So the frames already carry late timestamps when they reach the Mac. The
likely place is the guest's mirroring into the capture display, ahead of the
encoder (backboardd to `FigVirtualDisplayProcessor`). Confirming it needs
per-frame timing inside the guest; the logs are too coarse.

### Stalls after a cold start

Separately, on the 27.0.1 iPhone, DeviceHub sometimes stuttered for a few
seconds right after a cold start while the VZ window stayed fluid. In the one
confirmed case the Mac's HEVC decoder received nothing for about five seconds
while the receiver still counted packets. DeviceHub then sent a FIR with
reason `No video displayed timeout fail safe` and recovered. In another cold
start, while the guest was still booting, the guest's encoder and
`FigVirtualDisplayProcessor` reports stopped for about 17 seconds while
transport health messages continued. On recovery, 22 `VTP_Send` calls failed
with `ENOBUFS` and one encode took 125 ms, which looks like a consequence of
the burst rather than its cause. Nine other cold starts were healthy (newest
presentation under 25 ms old), and a run under the same test load as the
failure peaked at 240 ms. This also points at the guest's capture or encode
path.

`alarmsSentForDecodeButNotDisplayedCount=16` stays at its threshold even
after presentation recovers, so that warning is no failure detector.

### Encoding happens on the Mac

A targeted spindump of the guest's `avconferenced` shows the queues
`com.apple.videotoolbox.paravirtualization.guest` and
`…paravirtualization.host-to-guest`: the guest's VideoToolbox HEVC encoder is
paravirtualized, and the conversion ahead of it goes through
`AppleM2ScalerParavirtDriver` and IOSurface kernel calls. Encoding a frame is a
round trip to the Mac's VideoToolbox and scaler, which every running VM
shares.

That fits the worst events seen on 2026-10-07: two VMs streaming at once
(26.6.2 iPad and 27.0.1 iPhone) logged `Delay Warning: Encoding time=…` at the
same second, up to about 1.2 s a frame against about 5 ms normally, and both
DeviceHub views fell 1.9–2.7 s behind, then recovered within about ten
seconds. The VZ windows stayed fluid throughout, so only the encode path
stalled, not the guests.

What triggers it is not established:

- Two such events fell in minutes where the Mac had 40–100 MB free and was
  compressing and paging in tens of thousands of pages a second. A later VM
  restore that paged just as hard did not reproduce a stall (encodes peaked at
  229 ms, DeviceHub stayed at 10–120 ms), so memory pressure alone is not it.
- Both events also coincided with starting screen-capture measurement
  processes. A burst of captures later, including one that hung, did not
  reproduce it either.

The slow growth in a single long session (above) is a different shape: no
encode warnings, just a lag that ratchets up. A 26.6.2 iPad stream that had
run for about an hour was measured at 2.1 s on 2026-10-07 as well.

### A single stream on a quiet Mac does not ratchet

On 2026-10-07 the 26.6.2 iPad streamed alone for about two hours, with the
other test VMs stopped and about 20 GB free, the frame-code probe running and
the guest's `avconferenced` log captured throughout:

| Condition | Duration | Result |
| --- | --- | --- |
| Probe animating, sampled every 5 s | 30 min | 0–70 ms, five-minute means −1 to 13 ms |
| Home screen idle 60 s, then the probe | 5 rounds | normal on every return |
| Screen off and locked 90 s, then unlock | 3 rounds | normal on every return |
| Home / app switch every ~40 s, spindump running | 14 min | no encode warning |
| Same, no capture vs. capturing the VZ window every 2 s | 6 phases of 6–8 min | 1 phase with 6 warnings (max 584 ms), the repeat 0 |

So neither idling, screen lock, UI transitions nor screen capture produce the
ratchet or the long encode stalls on their own. Both were only seen while
several VMs streamed or the Mac was busy restoring and downloading, which fits
the encode path being a shared paravirtual resource. Two stalls did occur in
this session (12:13 and 12:15 local, up to 1.4 s a frame) without such load;
none of the 29 spindumps taken around Home presses caught one.

During stalls `VCScreenCapture` logs `Frame PresentationTime … going backwards
… Dropping frame`. MediaToolbox's `FigVirtualDisplayProcessor` stamps a
submitted frame with the compositor's timestamp and, after `max(2 frame
intervals, 50 ms)` without one, re-encodes the last frame on its own timer;
when the two interleave a real frame can land 1–28 ms behind an idle one and
is dropped. The offsets do not accumulate, so this costs single frames, not
seconds.

## iPhone Duo: the fold

Measured 2026-10-29 with Xcode 27.1 against `iPhone19,4` 27.1 (24A94425).

Xcode 27.1 draws a foldable as a 3D V68 model
(`DeviceKit.framework/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin`,
log subsystem `com.apple.dt.coredevicepop`, with the host CoreDevice plugin
`CoreDevicePopCoreDeviceExtension.coredeviceplugin`). It picks the fold and
the lit panel from the device's pose, which is CoreDevice's device motion
state stream (`com.apple.coredevice.action.streamdevicemotionstate`). The
DDI's `dtdeviceinfod` (`DeviceMotionStateManager`) answers it from
CoreMotion's `CMDeviceStateManager`, reading each `CMDeviceStateEvent`'s
`propertyA` (device orientation), `propertyB` (hinge state 1 closed, 2
partially open, 3 open flat) and `propertyC`. On a guest the manager is
unavailable, DeviceHub logs `Pose monitoring failed … Code=1001` every second,
and draws the device closed whatever the hinge angle stream says.

`libdevicehubfix` answers it in `dtdeviceinfod` (`VPCMAngleManager.m`, beside
the hinge angle stand-in): `isAvailable` follows the hinge provider, and
updates are real `CMDeviceStateEvent`s built from the provider's newest
sample, sent at start and on every change. `propertyA` is the device
orientation vphoned publishes (`VPhoneDeviceOrientation` in
`com.apple.backboardd`, portrait until a rotation or DeviceHub's orientation
picker sets one), `propertyB` the provider's hinge state.

DeviceHub's model (decompiled, `CoreDevicePopDeviceKitExtension`):

- `PhysicalState.update` reads only `propertyA`, `propertyB` and `propertyC`
  (each a `CodableValue.int`). Closed pins the angle at 0°, open flat at
  180°; partially open keeps the angle from the hinge angle stream
  (`streamhingeangle`, samples with `isAngleValid`, a `Measurement` in
  degrees).
- The focused panel (the face the model shows, and whose stream it draws) is,
  in order: the panel a command is heading for, cover when closed, the active
  display DisplayInfo reports (accepted only fully open or closed), then the
  hinge: partially open at 55° or more is the inner panel, 45° or less the
  cover.
- The model's rotation comes from the pose orientation and the focused panel,
  not the hinge state; `DisplayInfo.orientation.currentDeviceOrientation`
  stands in only while the device lies face up or down. The pose buttons'
  icons turn with `propertyA`.
- The presets are closed 0°, partially open **130°** and open 180°.

The hinge angle stand-in's three angles are **floats**: `dtdeviceinfod`'s
`CMAngle_Bridge` declares `angleDegrees`, `mechanicalAngleDegrees` and
`velocityDegreesPerSeconds` as `Tf` and reads `s0`. The first stand-in
returned doubles, whose low half is zero for every whole angle, so DeviceHub
read 0° throughout. Open and closed hid it (their hinge states pin the
angle); in book DeviceHub drew the device nearly shut and focused the cover,
whose stream is the composited portrait output, so the inner picture looked a
quarter turned. Reporting landscape right made that picture upright only by
rolling the whole model.

Each panel streams on its own. DeviceHub shows its pose controls only when
DisplayInfo lists the inner display as `integrated` with its own ID, and then
draws that panel from that display's stream (feature `0x100`) and geometry.
FoldDisplay publishes the inner display with the hardware's shape: a portrait
2007×2853 framebuffer at 3×, mounted at 270° (`DisplayRotation`, as the
simulator's inner `CADisplay`), into which SpringBoard lays the inner UI out
at interface orientation 90. In `dtdeviceinfod` the library reports that
display as integrated at point scale 3 (`displayType`, `pointScale` on the
`CADisplay` named `VPhone Duo Inner`). An earlier landscape inner display
streamed pillarboxed with black bars, and with the mirror of display 1 the
picture came out turned a quarter.

DeviceHub's controls reach the guest as vendor-defined HID events (usage
page `0xFF61`, usage `0x5B`) from the DDI's `dtuhidd` virtual service
`CoreDevice avpCustom`. The payload is an IOKit binary-serialized dictionary
(`IOCFUnserializeBinary`): `provider` `com.apple.Virtualization.VirtualMachines`,
`source` `hinge-slider-control` (`type` range, `value` degrees, sent every
frame of DeviceHub's own animation) or `orientation-picker-control` (`type`
enum, `value` `portrait`, `portraitUpsideDown`, `landscapeLeft` or
`landscapeRight`). vphoned watches for them on an iPhone Duo
(`vphoned_devicehub.m`, an unmatched HID event monitor; matching by usage
missed them) and acts through the `display.posture` paths
(`GuestDeviceHubControl`): a run of slider values is folded once it has been
quiet for 200 ms, to where it ended, and a picker value sets the pose
orientation with the hinge where it is, as `display.rotation` does. The
orientation DeviceHub reads back changes only once SpringBoard's interface
has turned, and a refused turn gets the old pose orientation back (SpringBoard
keeps a refused one, and later folds carry it). Book is left alone: the
override means 90° there and slides the fold toward the cover. Measured with
`display.rotation` on the open inner panel: 0, 90, 180 and 270 all turn, and
DeviceHub turns its model with each, picture upright. The picker itself was
not pressed.
DeviceHub then waits for its hinge
reading to agree; vphoned moves the virtual hinge to the target as
SpringBoard's sweep starts, since a stale angle through the sweep made
DeviceHub's slider send the old angle back and fold the guest again.


`dtdeviceinfod` aborted whenever it let a `CMAngleManager` go, as when
DeviceHub quit or reconnected: `-[CMAngleManager dealloc]` stops
CoreMotion's own manager, and `-[CMAngleManagerInternal
stopAngleUpdatesPrivate]` asserts `CLAngleNotifier::isAvailable()`
(`CMAngleManager.mm` line 214), which is false on a guest without the
foldable product-id. The relaunched `dtdeviceinfod` left DeviceHub without
the device state, and its fold controls stopped working until DeviceHub was
restarted. The stand-in now skips that internal stop, since under it the
real manager never started. Its `minAngleDegrees` and `maxAngleDegrees` also
return floats, as declared. Six crash reports with the same stack were
collected on 2026-10-29 and 2026-10-30. With the fix, `dtdeviceinfod` kept
running through a DeviceHub quit and relaunch, and DeviceHub followed the
guest to book and closed afterwards.

Restarting backboardd breaks `dtuhidd`'s HID connection and DeviceHub keeps
the dead one: restart DeviceHub after a respring.

Measured on the same guest, portrait: closed and open from DeviceHub's
buttons settle without bouncing and the guest follows; book at 130° (folded
by `display.posture`) draws the inner face upright with the crease vertical,
as DeviceHub draws a simulator Duo in book. Not yet repeated from DeviceHub's
own book button since the float fix. Once, after DeviceHub's close from book,
the cover came up in landscape (interface 90°); it did not recur in 48
scripted folds over every path, and the guest's device orientation had been
left non-portrait by rotation experiments just before, which the swap keeps.

With the foldable's product-id (`preboot-cfw-devicetree_foldable_product_id`,
on in standard since Lakr233/vphone-cli#778) CoreMotion has its own angle and
device-state managers, and locationd's device-state relay reads the host
controls (`0xFF61/0x5B`). Both `dtdeviceinfod` stand-ins then step aside, and
DeviceHub reads the real managers. dtuhidd's "CoreDevice avpCustom" service
carries the same usage, so the relay takes DeviceHub's controls itself, as on
Apple's VM host, and the guest follows the slider as it moves. The virtual
hinge, which resends its stored values every 5 s for a restarted locationd,
stores each slider value quietly (a `quiet` configuration: no host-control
event): while it kept the old angle until a debounced fold, a resend landing
inside a run sent the fold back, and sending each value again reached the
relay late, behind DeviceHub's own, and swung the hinge back and forth across
the swap (the panel changed hands eight times on three clicks). An opening run from
closed lights the screen first, as `display.posture` does; with a sleeping
cover SpringBoard's pose provider commits no moving pose and the inner
display stayed black. The picker sets the hinge's orientation. The provider
check keeps vphoned from following the hinge's own dictionaries, which carry
none. The SpringBoard display-swap path above is for guests without the
relay; there vphoned also writes each slider value as the hinge sample the
stand-ins read, without moving the hinge, because a reading left at the old
pose until the fold pulled DeviceHub's model back there (closed, open,
closed).

Measured on sbdisplay-duo after the product-id patch (2026-10-30): every
DeviceHub click folds the guest once, following the slider. The black on
opening out of closed is SpringBoard's fold effect on one shared panel; see
`iphone_duo_bringup.md`, "2026-10-30: the fold's fade to black on one
panel". DeviceHub no longer gets the guest's system audio (`0x184`): the VM
window plays it, and DeviceHub played it again.

## Encoding only when the screen draws

An open DeviceHub viewer cost the host about a core while the guest sat on
its Home Screen (iPhone19,4, iOS 27.1 24A94425, macOS 27.0.1 on an M5 Pro):
the VM process at 91%, against 14% with DeviceHub closed. The guest itself
used about a third of a core (`avconferenced` 17%).

The encoder runs on the host. `avconferenced` calls VideoProcessing's
`VCPCompressionSessionCreate` directly (AVConference `EncCreateHandle`), and
that real-time encoder wraps
`paravirtualized:com.apple.videotoolbox.videoencoder.ave.hevc`, the host's AVE
hardware. The real-time encoder runs AVE in user-DPB mode
(`VCPCompressionAllocateDPB`, `kVTEncodeFrameOptionKey_DPB_ReferenceFrames_*`),
so each encoded frame carries nested reference-frame dictionaries. A host
`sample` of the VM process showed, per stream, an `AVE_UCRecv` thread at
about 36% in `VTParavirtualizationHostEncoderSessionEmitEncodedFrame →
VTParavirtualizationCreateSerializedAtomDataBlockBufferForSampleBuffer →
CFPropertyListCreateData` and about 22% more in a synchronous wait for the
guest's reply, plus the `AppleM2ScalerDevice` queue at about 39%. No guest
setting leaves user-DPB mode: it is how the real-time encoder controls its
rate. The Mac decodes with `VCPDec`, about 1.2 ms a frame.

The cost scales with the frame rate, and the rate did not follow the screen.
The Mac's `avconferenced` logs each stream's input rate
(`[VCPDecStatsMonitor] … Input_fps=`): the idle Home Screen streamed about
42 fps on each of the Duo's two displays. The capture is FigVirtualDisplay's
writeback clone of each lit display in backboardd
(`IOMFBDisplay::clone_update`); after the screen draws it keeps writing frames
back at the capture rate for about a second, and a still screen sends nothing
(Settings left alone dropped to 0 fps, with or without the change below). The
live Clock icon on the Home Screen draws about ten times a second
(`CARenderServerGetFrameCounterByIndex(0, 0)`, the main display), so that
second never ends.

`libdevicehubfix` (`VPScreenCaptureIdle.c`) replaces
`-[VCScreenCaptureFigCaptureController
screenCaptureController:didReceiveSampleBuffer:transformFlags:]` in
`avconferenced`: a frame passes when the main display's frame counter moved
since the stream's last frame, and otherwise once every 250 ms. A frame that
carries a change can arrive after the counter moved; the 250 ms frame bounds
that delay and lets the encoder refine a still image. On the Duo the main
display is the panel the inner display is shown on, so one counter covers both
streams.

| sbdisplay-duo, DeviceHub open | before | after |
|---|---|---|
| idle Home Screen, input rate per display | 41–45 fps | 10 fps |
| idle Home Screen, host VM process | 91% | 46–50% |
| idle Home Screen, guest `avconferenced` | 17% | 7% |
| scrolling Settings, input rate per display | 58–60 fps | 54–60 fps |
| Settings left alone | 0 fps after ~1 s | 4 fps for ~1 s, then 0 |

A first version also passed eight frames after each change; with the Clock
icon changing every 100 ms that never ran out (30 fps with two frames).

## Other open items

- iPadOS 27 refuses pairing (see Validation), so DeviceHub is untested there.
- Touch input sent from DeviceHub has no automated check.
- The `0x14` port offset in the conditional dispatch is fixed, not derived;
  check it on the next 27.x build.
- The band-read barrier was tested on the 27.0.1 iPhone only. It depends on
  two private `VCPSideCarMetal` method names; if they change, the library logs
  that they were not found and banded streams can deadlock again.
- The idle-frame filter depends on the private
  `VCScreenCaptureFigCaptureController` callback and
  `CARenderServerGetFrameCounterByIndex`; if either is missing, the library
  logs it and every captured frame is encoded, as before.

## Measuring

- **Open a guest in DeviceHub without clicking:** `open
  "devices://device/open?id=<CoreDevice identifier>"`, using `identifier` from
  `xcrun devicectl list devices --json-output -` (not the UDID). It opens or
  raises a viewer window and starts the stream.
- **DeviceHub's windows are not in the accessibility tree.** Capture them
  with `screencapture -x -o -l <CGWindowID>`, the ID from
  `CGWindowListCopyWindowInfo` filtered by DeviceHub's pid.
- **Latency:** run a guest app that draws the guest's clock every frame as a
  machine-readable pattern (a green frame around a 4×8 grid: 24 bits of
  epoch ms / 10 and an 8-bit checksum), capture the VZ window and the
  DeviceHub window at the same moment, decode both, and subtract. That gives
  DeviceHub's delay over the VZ window to about ±30 ms, every few seconds,
  without touching the guest. Without such an app, change the guest screen
  through vphoned and capture until the frame differs, with the VM window as
  the baseline.
- **Capturing windows:** ScreenCaptureKit (`SCScreenshotManager` with
  `desktopIndependentWindow`) captures covered windows correctly, but two
  capturing processes at once hang each other; sample several window pairs
  from one process. `CGWindowListCreateImage` (looked up at run time) returned
  a frame minutes old for DeviceHub's main window, and `screencapture -l` is
  live but its timing varies by hundreds of milliseconds. DeviceHub has one
  viewer window: opening a second device with `devices://` reuses it.
- **Host logs:** `/usr/bin/log show` (zsh shadows `log`). In DeviceHub,
  `MediaStreamGetSupportInfo` and `MediaStreamStart` replies. In the Mac's
  `avconferenced`, `Health: VideoReceiver` (`videoJitterQueueSize`),
  `Health: VCVideoPlayer` (presentation times) and `VCPDec` (decoder input).
  Player addresses are reused across streams, so start a stream's series at
  its `displayLinkTickCount=0` line rather than matching the pointer.
- **Host IOSurface synchronization:** `sudo ktrace dump -b 1024 -T 210s -f
  C0x85 <file>` while streaming, then `ktrace trace -R <file> -N --ndjson`. In
  class `0x8521`, `0x85210000` registers an access, `0x85210004` waits,
  `0x85210008` is granted and `0x8521000c` releases; `arg1` is 1 for the
  scaler and other non-GPU access in the VM process and 2 for the GPU, `arg2`
  the surface ID, `arg3` 1 for a read and 2 for a write. `0x8521001c` is the
  scaler looking up a surface as it takes a request. A run writes 1–1.5 GB.
- **Guest logs:** vphoned `logs.syslog` takes `level` `all`, `error` or
  `fault`; info lines are not persisted. `avconferenced` prints
  `fvdp_statsReport`, `VCPEnc` and `Health: VideoTransmitter` every second.
- **Guest profiling:** follow `Research/Guest/display_refresh_rate.md` and
  never sample the host VM process at the same time. A targeted capture is
  enough: `spindump avconferenced 40 20 -onlyTarget -wait -noBinary -file
  <report>`.
- **Restarting the stream:** `processes.kill` sends `SIGTERM` by default,
  which `dtremotedisplayd` ignores; pass `"signal": "KILL"`. The stream
  itself lives in `avconferenced`.
- **Screenshots are no evidence of scanout.** vphoned's `screen.screenshot`
  and the control socket's `screenshot` read the guest, and DeviceHub's saved
  screenshot showed the home screen while its live panel was black. Look at
  the VZ window and DeviceHub's live panel directly.
