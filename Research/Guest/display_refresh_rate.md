# Guest Display Refresh Rate

## Duo inner display: local investigation, 2026-10-29

Historical observation from a release-based local build. The main-based review
candidate keeps upstream's explicit 120 Hz digital-mode setup instead of this
update-rate-only experiment. Exceeding 60 in the window counter did not prove
that ordinary apps saw a 120 Hz inner UIScreen. See the later digital-mode
investigation in iphone_duo_bringup.md for the stronger measurements.

On the iPhone19,4 27.1 (24A94425) guest with cloudOS 26.4
(23E5207q), the cover display reached 119 fps while scrolling Settings,
but the unfolded inner display stayed at 59–60 fps, as counted by the
VM window's framebuffer callback counter. Low Power Mode was off.
`UIScreen.mainScreen.maximumFramesPerSecond` returned 120 from a guest
daemon session, which described the cover and did not establish the inner
display's frame rate.

`FoldDisplayBackboard.m` creates the separate `CAWindowServerVirtualDisplay`
for the inner panel with `kCAVirtualDisplayUpdateRate = 60`. The local fix
sets that option to 120 to match the cover's ProMotion timing. This changes
a guest component, requiring an environment redeployment and reboot rather
than a kernel update or firmware restore.

After deployment as `2.14.0-local.77724db8`, the unfolded Settings scroll
test produced window-counter samples of 82 and 111 fps (previously 59–60).
The release build and bundle admission passed. The previous installer/PAC
and scaled touch-coordinate repairs were retained in the same build.

A vphone guest renders at 60 Hz whatever the host display does. This note
records where the 60 comes from, why no Virtualization setting changes it, and
the kernel patch `kernel-cfw-display_promotion` (titled ProMotion) that makes the
guest display advertise 120 Hz. It is on in `standard` since 2026-10-09; it
shipped opt-in as `kernel-exp-display_refresh_120hz` from 2.4.2. Measured on
2026-10-04 on macOS 27.0.1 (26A434), Apple M5 Pro, built-in 120 Hz display,
cloudOS 26.4 (23E5207q) kernel with an iPadOS 26.6.2 (23G90) userland.

## Where 60 Hz Comes From

### Host: a constant in the VM service

`com.apple.Virtualization.VirtualMachine` (the XPC service that owns the guest)
creates the display with one mode:

```
[[PGDisplayMode alloc] initWithSizeInPixels:… refreshRateInHz:60.0]
```

The double `0x404E000000000000` is materialized inline at three sites, the two
that build a `PGDisplayMode` among them, and the binary holds no `120.0`.
`VZMacGraphicsDisplayConfiguration` has no refresh property, public or private:
its private surface is `_displayMode` (an integer enum, meaning not decoded),
`_connectionType`, `_displayIdentifier` and `_enableHDR`, and the mode is built
the same way whatever they hold. The service lives on the sealed system volume,
so this side is not patchable short of injecting into an Apple process.

### Host: nothing paces the guest

`ParavirtualizedGraphics` has no vsync clock for a `PGDisplay`. A guest present
reaches `-[_PGDisplayNub _presentMappedSurface:…]`, which hands the frame to
`-[_PGDisplay presentFrame:…completionBlock:]` and fires the client's
`newFrameEventHandler`. The VM service's handler calls
`encodeCurrentFrameToCommandBuffer:texture:region:`, `commit` and
`waitUntilScheduled`; it imports no display link. The completion block then
sets event bit 2 in the display's shared state page and raises the display
interrupt. In the guest, `AppleParavirtGPU`'s interrupt handler walks the
per-display bitmask and kicks each display's "VBL timer", an
`IOTimerEventSource` that is only ever armed to fire at once. So the guest's
VBL is the host's present completion, not a clock.

The only timer ivar among the framework's display classes is
`PGEFIDisplay._presentTimer`, on the pre-boot framebuffer.

### The shared state page is the one channel

`-[_PGDisplayNub testUpdateModeList:]` writes each mode into the shared state
page at `+0x210 + 16 × index`, with the count at `+0x208`:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | u16 | width in pixels |
| 2 | u16 | height in pixels |
| 4 | u32 | refresh rate, 16.16 fixed-point Hz (`floor(rate × 65536 + 0.5)`) |
| 8 | u8 | flags (bit 0 EDR, bit 1 10 bpc) |

### Guest: the timing element

`AppleParavirtDisplay::createDisplayAttributes`
(`com.apple.driver.AppleParavirtGPUIOGPUFamily`) builds the display's
`DisplayAttributes`, among them `TimingElements`. For each mode entry it calls
a helper with the index, width, height and the 16.16 rate, and the helper
makes an IOAV timing element from them:

```
ldurh w1, [x8, #-8]     ; width
ldurh w2, [x8, #-6]     ; height
ldur  w3, [x8, #-4]     ; refresh, 16.16 Hz
mov   x0, x21           ; index
bl    <make timing element>
```

`x8` points at the entry's flags byte, hence the negative displacements.
`TimingElements` is the only place the rate appears in the attributes the
driver publishes; the results below show the userland takes its pace from it.

## The Patch

`KernelCustomFirmwarePatcher.patchParavirtDisplayRefreshRate`
(`Kernel/CustomFirmwarePatches/Drivers/KernelCustomFirmwarePatchDisplayRefresh.swift`)
replaces the load of `w3` with `movz w3, #120, lsl #16`, that is 120.0 Hz in
16.16. One instruction, one record: `kernel-cfw-display_promotion`.

Reveal procedure, no offsets:

1. Find the cstring `createDisplayAttributes`, the function name the driver
   passes to its logger.
2. Take its ADRP+ADD references in `__TEXT_EXEC` (23 on 23E5207q) and require
   that they all resolve to one function start.
3. Between that start and the last reference, find three consecutive
   instructions `ldurh w1, [b, #-8]`, `ldurh w2, [b, #-6]`, `ldur w3, [b, #-4]`
   off one base, followed within three instructions by a `bl` with no other
   control flow in between. Require exactly one.
4. Emit `ARM64Encoder.encodeMovzW(rd: 3, imm16: 120, shift: 16)` over the
   `ldur`.

On the 23E5207q research kernelcache the record lands at file offset
`0xEB1A98`.

It is declared in `com.vphone.patchset.kernel.cfw` with no version gate and is on
in `standard`; a VM that blocks it keeps the host's 60 Hz mode. It is a
preference, not a fix: see the cost in the results. See "On in `standard`" below
for why it moved and what happens to a VM that opted in under the old name.

## Results

Test guest: `hz120-ipadpro`, an iPad Pro 13-inch (iPad17,x, 2064×2752) created
with the patch on, 8 vCPUs. Load was driven with vphoned's `input.swipe`; the
host side was read from the GPU accounting in the IORegistry
(`AGXDeviceUserClient` → `AppUsage`), where the VM service's client submits
once per frame it scans out.

| Workload | Frames scanned out | Gap between frames | Guest share of host GPU |
| --- | --- | --- | --- |
| Settings list, continuous scroll | 117.8 per second (112–120 in any one second) | median 8.3 ms, 98% under 12 ms | 30% |
| Home Screen, continuous page swipes | 103.6 per second (102–119) | median 8.4 ms, 90% under 12 ms | 24% |
| Home Screen, static page | — | — | 2% |

The three questions the patch had to answer:

- **The host shows every frame.** Nothing between the guest's present and the
  window drops to 60: the scan-out count follows the guest up to 120.
- **The userland follows the timing element.** backboardd and SpringBoard on
  iPadOS 26.6.2 rendered at the advertised rate with no userland change.
- **It costs what twice the frames cost.** While scrolling, the VM service used
  92–139% of one core and the host GPU tasks 33–40%. For comparison, an
  unpatched iPad mini guest (1488×2266, 60 Hz) scrolling the same list scanned
  out 55 frames per second and took 12–17% of the host GPU; the iPad Pro panel
  has 1.7 times the pixels.

A guest whose product type is a 60 Hz device follows the patch too:
`hz120-ipadmini` (iPad16,1, 1488×2266) scanned out 118 frames per second
scrolling Settings, 97% of them on time, and about 102 swiping Home Screen
pages. The userland does not cap the rate by model.

Not measured here: an iPhone guest, an iOS 27 userland, and a host display that
is not 120 Hz, where the window cannot show the extra frames whatever the guest
renders. An iPhone 26.6.2 guest was measured later; see "iPhone 26.6.2, and the
attitude hook deadlock" below.


## Animations at 120 Hz

Each row is about twelve seconds of one gesture repeated on `hz120-ipadpro`. A
frame is on time when it follows the previous one by less than 12.5 ms; motion is
a run of frames less than 50 ms apart, because an idle screen still scans out
about ten times a second and those ticks are not animation. A gap of 50–90 ms
inside a gesture is counted as a hitch.

| Animation | Frames per second while moving | On time | Hitches | Guest share of host GPU |
| --- | --- | --- | --- | --- |
| Maps, panning | 119 | 98.2% | 0 | 41% |
| Photos, scrolling | 117 | 97.5% | 1 | 19% |
| Settings, scrolling | 117 | 94.6% | 0 | 33% |
| Notification Center, down and up | 116 | 92.4% | 0 | 40% |
| Control Center, down and up | 117 | 92.1% | 16 | 25% |
| App open and close | 107 | 92.3% | 7 | 22% |
| Spotlight, open and dismiss | 105 | 91.0% | 15 | 26% |
| Home Screen page swipes | 103–115 | 89–96% | 6 | 16–31% |
| Today View, in and out | 97 | 87.9% | 23 | 22% |
| Safari, scrolling apple.com/ipad-pro | 70 | 46.3% | 1 | 15% |

The app switcher and rotation could not be driven through vphoned and are not
in the table. The GPU is never the limit: the worst case for pacing, Safari, is
the cheapest on the GPU.

### Where the time goes

Two profilers, never both at once (see below): the host's `sample` on the VM
service, the compositor's GPU task and `vphone-vm`; and the guest's own
`/usr/sbin/spindump`, run as a temporary launchd job and symbolicated against
the guest's dyld shared cache with `ipsw dyld a2s`.

- **Safari.** No thread is busy: MobileSafari's main thread and the WebContent
  main thread each use about 40% of a core. backboardd's display thread spends
  24% of its time blocked in
  `CA::OGL::MetalContext::create_surface_with_properties` →
  `AppleParavirtGPUMetalIOGPUFamily` → `-[_MTLCommandBuffer waitUntilCompleted]`,
  a synchronous round trip to the host GPU for every offscreen surface the
  render needs, and another 20% in `CA::WindowServer::IOMFBDisplay::swap_wait_timeout`
  waiting for the previous swap to finish. That is the paravirtual Metal driver's
  behaviour, not the page's cost.
- **Today View and Spotlight.** The compositor's display thread is idle about
  70% of the time and SpringBoard's main thread 84–93%. The late frames there
  are not a CPU or GPU limit inside the guest; what delays them was not found.
- **Host.** The eight vCPU threads sit in `hv_trap` and the rest of the VM
  service is small: handling a present costs about 0.8 ms per frame, almost all
  of it `-[_MTLCommandBuffer waitUntilScheduled]` under
  `-[_PGDisplayNub _presentMappedSurface:…]`, and mapping and unmapping guest
  IOSurfaces takes 1–5% of wall time. The compositor's host GPU task uses about
  5% of a core and `vphone-vm` close to none.
- **Idle.** A static Home Screen still scans out about ten frames a second and
  costs about 15% of a host core. The guest capture taken then also shows
  `aonsensed` being respawned by launchd (`throttled after exit`).

### Window visibility and App Nap

`vphone-vm` takes no activity assertion, so macOS naps it once its window has
been covered for a while: every thread drops to priority 4. That does not reach
the guest. The threads that run it and scan it out belong to the VM service,
which stayed at its default priorities (31, a few 37/46) in every state below.
Settings scrolling at 120 Hz, ten seconds per run, measured from the VM service's
GPU submits:

| Guest | Window | Frames per second while moving | On time | Hitches | Swipe RPC |
| --- | --- | --- | --- | --- | --- |
| `narrowtest-ipad` | visible | 113.1–113.5 | 94.3–96.1% | 3–5 | 398–419 ms |
| `narrowtest-ipad` | hidden 20 s | 112.0–115.6 | 94.8–97.1% | 4 | 405–416 ms |
| `gpuaccel-ipad` | covered, napped (priority 4 during the run) | 109.9–113.6 | 93.3–95.9% | 3–6 | 402–438 ms |
| `gpuaccel-ipad` | after waking (37/46) | 109.5–111.2 | 91.5% | 5 | 421–458 ms |

The differences are within run-to-run noise. A napped `vphone-vm` costs nothing
while nobody looks at the window, and vphoned RPCs, which pass through it, were no
slower either. A guest animating on its own while napped (the Weather app, no
input) kept scanning out until the guest's own Auto-Lock turned the screen off
120 s after the last input. So an activity assertion would buy nothing for
rendering.

### Profiling a guest without panicking it

`sample` suspends the target's threads for every sample, the vCPU threads
included. A guest stackshot has to stop every CPU first, and when a vCPU does not
answer in time the guest panics with
`DebuggerXCallEnter> Debugger synch pending on cpu 0`, panicked task `spindump`.
Running both profilers over the same window did exactly that on the third
capture. Take the host sample and the guest spindump in separate runs.

The guest side, with vphoned only:

1. `files.write` a launchd plist whose `ProgramArguments` are
   `/usr/sbin/spindump -notarget <seconds> 10 -file /var/tmp/<name>.txt`, with
   `RunAtLoad`.
2. `services.load {paths: [plist]}`, drive the animation, and wait for
   `services.status` to report no pid.
3. `files.read` the report (`limit` large enough; it is several megabytes),
   then `services.unload` with `force` and remove both files.

The report gives exact CPU time per thread and unsymbolicated frames as
`library + offset [address]`. Subtract the `System Primary` shared cache slide
in the report header from an address and pass it to `ipsw dyld a2s`.

## On in `standard` (2026-10-09)

The patch leaves `standard`'s block list and
`FirmwarePatchSetCatalog.manualOnlyPatches`, so every new VM gets the 120 Hz
timing element. The measurements above are why it can: the host scans out every
frame up to 120, the userland follows the advertised rate with no change of its
own, an iPad guest whose model is a 60 Hz device follows it too, and a static
screen costs what it did at 60 Hz. The 2026-10-05 kernel update round
(`Research/0_binary_patch_comparison.md`, "The kernelcache reaches an installed
guest without a restore") toggled it on an iPhone17,3 27.0 (24A435) guest, which
booted. The cost while animating is unchanged: up to twice the host CPU and GPU
of a 60 Hz guest.

### iPhone 26.6.2, and the attitude hook deadlock

Checked on 2026-10-09 on a dedicated VM: iPhone17,3 26.6.2 (23G90), cloudOS 26.4
(23E5207q) kernel, `standard` from a bundle built from this change (2.9.0 base),
`--no-template`. The kernelcache record landed at `0xEB1A98`, as on the iPad.

With the 2.9.0 guest components the guest never left the Apple logo. In three
boots at 120 Hz (the first boot after the restore and two reboots) SpringBoard and
backboardd stopped at 3–4 s of CPU and stayed there; every SpringBoard-bound vphoned
call (`apps.launch`, `apps.foreground`) hung. A guest spindump (launchd job, 5 s)
reported the deadlock itself:

- SpringBoard's main thread: `_SBFApplyParallaxSettingsToViewWithFactor` →
  `-[UIView _updateParallaxEffectWithAltitude:bias:]` → `-[UIView addMotionEffect:]`
  → `-[_UIMotionEffectEngine init]` → `-[_UIMotionEffectCoreMotionEventProvider init]`
  → `VPhoneInterval` (`libvphoneattitude.dylib`, the `setDeviceMotionUpdateInterval:`
  hook, holding `@synchronized(session)`) → Core Motion's native setter, waiting for
  the MotionThread.
- `com.apple.CoreMotion.MotionThread`: a Core Motion callback → `VPhoneActive` (the
  `isDeviceMotionActive` hook) → `objc_sync_enter`, waiting for the main thread.

The hook image was matched by UUID (`BFDEACD1-AAAB-324E-8A5C-5ACF6135EE47`, this
build's `libvphoneattitude.dylib`) and the system frames symbolicated against the
23G90 shared cache with `ipsw dyld a2s`. This is the lock-order bug that
Lakr233/vphone-cli#643 fixes, not the display patch: #643 reports it at 60 Hz on
every 2.9.0 iOS 26.6.2 template build. Here, with the same guest data, a 60 Hz
kernelcache (`fw set-patches --block`, `cfw update-kernel`) booted once without
hanging, so 120 Hz seems to make the race easier to lose; one 60 Hz boot does not
show that 60 Hz is safe.

With #643's hook fix (12c72fa) cherry-picked onto the same bundle and the guest
environment redeployed (`vm set-bundle --update-environment`), the 120 Hz kernel
booted. Setup Assistant was skipped, SpringBoard relaunched and reached the Home
Screen. Continuous Settings scrolling for 12 s scanned out 119.3 frames per second,
with a median gap of 8.2 ms and 98.5% of the gaps under 12.5 ms.

So `standard` with ProMotion needs #643's attitude fix on an iOS 26 guest. Ship it
in a bundle that also carries #643.

The pipeline's no-plan fallback in `buildComponentList` is now on as well, so a
pipeline built without a preset agrees with `standard`. The patcher's own
`applyProMotion` default stays false, so the kernel CFW reference comparison is
unchanged.

**Renamed.** The `{component}-{effect}-{name}` rule gives `cfw` to a patch
`standard` turns on, and the editor now titles it ProMotion, so the identifier is
`kernel-cfw-display_promotion`. Unlike the earlier renames, the old identifier
shipped (2.4.2 onwards) and a VM may have checked it, so
`FirmwarePatchSetCatalog.renamedPatches` maps it. `VPhonePatchPresetStore` reads
`PatchSelection.plist`, `PatchPlan.plist` and `PatchReceipt.plist` through that
map: a VM that opted in under the old name resolves instead of failing `fw patch`
with `unknownPatch`, and a kernelcache already patched under the old name counts
as carrying the new one rather than as drift.

**Existing VMs.** A `standard` VM whose kernelcache was patched without it now
reads as wanting it. Its guest keeps 60 Hz until `cfw update-kernel` (or a
restore) writes the re-patched kernelcache.

**Opting out.** `vphone-cli fw set-patches <vm> --block
kernel-cfw-display_promotion`, then `cfw update-kernel`.
