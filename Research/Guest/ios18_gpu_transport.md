# iOS 18 GPU transport on a cloudOS 26.1 kernel

iPhone17,3 iOS 18.6.2 (22G100) boots the cloudOS 26.1 (23B85) vphone600
kernel, with PR #822 aiming the EXC_GUARD patch. Before this change the guest had
no Metal device: wallpaper black, Settings rows without icons, app status bars
clipped, vphoned screenshots black, and SBRendererService aborting in
`-[NUDevice_iOS _newRendererWithCIContextOptions:]` (`NUDevice.GPU`,
`deviceNotCapable`). Everything drew in software.

`system-systemhook-cfw-ios18_gpu_transport` fixes this in two parts.

## Why there was no device

`fw prepare` stages the paravirtual Metal driver of the paired cloudOS, because
`VPhonePCCGPUDriver.validateBundle` requires its `DTPlatformVersion` to match the
cloudOS release. An iOS 18 base therefore got the 26.1 driver (v63.2.2, built for
26.1). dyld refuses it on iOS 18:
`Symbol not found: _OBJC_IVAR_$_IOGPUMetalHeap._device` (IOGPU.framework), so
`MTLCreateSystemDefaultDevice()` returns nil.

The driver from cloudOS 18.6 (22G86, v40.5.10) loads. Its device is then refused
by the 26.1 kernel, because iOS 18's IOGPU.framework and that driver call user
clients that changed between the two releases.

## The kernel ABI that moved

Found by tracing each IOKit user-client call in a test process, then diffing all
~50 `IOConnectCall*` sites of IOGPU.framework in the 18.6.2 and 26.1 shared caches
(selector immediate, scalar and struct counts, struct sizes):

| iOS 18 call | cloudOS 26.1 | Translation |
| --- | --- | --- |
| IOGPU device method 6 (`IOGPUDeviceCreateWithAPIProperty`: a 16-byte API name, result ignored) | removed | answered locally with success |
| IOGPU device methods 7–255 (7 = command queue create, 9 = resource create, … 0x37) | one lower (6, 8, … 0x36) | selector − 1 |
| Resource create reply: 0x50-byte header + driver tail | 8 bytes inserted at 0x18 | ask for 8 more, drop `[0x18, 0x20)` |
| AppleParavirtGPU method 265 (`-[AppleParavirtDevice setupDeviceInfo]`), 0x10c-byte reply | 0x118 bytes, refused with 0xe00002c2 when asked for 0x10c | ask for 0x118, keep `[0, 0xd8)` and `[0xdc, 0x110)` |

Request layouts did not change: the command queue create struct is 0x408 bytes on
both, and resource create input passes through (variable size, at least 88 bytes).
Paravirt methods 257, 259 and 260 are unchanged. Only the device user client
(type `1 | (api << 16)`) is renumbered. IOGPU's other client types and every other
user client in the process are not.

## How the fix works

- **Driver.** With the patch selected, `fw prepare` stages the driver of the iOS
  release's own cloudOS (`VPhoneFirmwareCatalog.iOS18CloudOS(forVersion:)`, the
  research-board table: cloudOS 18.6 for 18.6.x). It reuses
  `~/.vphone/gpu-drivers/<version>_<build>` when an earlier machine cached it, and
  otherwise recovers it from that cloudOS with the usual temporary restore. The
  project's compiler plugin is merged as before. iOS 18's `MTLCompilerService`
  accepts plugins only under `/System/Library/Extensions/` or
  `/System/Library/PrivateFrameworks/` (`validPathPrefixes`), so the driver has to
  be in the System volume, and the plugin (minos 26.1) loads there.
- **Transport.** SystemHook (`SystemHook/VPhoneIOS18GPU.c`) detours IOKit's
  `IOServiceOpen`, `IOServiceClose`, `IOConnectCallMethod` and
  `IOConnectCallAsyncMethod` with MISFixDetour, which rewrites the callee, so calls
  from inside the shared cache are translated too. An interpose or
  `DYLD_INSERT_LIBRARIES` does not reach those. It records connections opened as
  IOGPU device clients and applies the table above to them only. The rules are in
  `SystemHook/VPhoneIOS18GPUTransport.c`, checked by `make test-ios18-gpu`.
  `IOServiceOpen` is detoured last, so connections are recorded only once both
  call paths translate.
- **Gate.** The declaration applies to iOS 18.6 on cloudOS 26.1, the pair that was
  measured. `cfw install` writes `/usr/lib/vphone-ios18-gpu` only when the
  installed driver's `DTPlatformVersion` is the iOS release. A machine prepared
  before this change, which still has the 26.1 driver, gets no marker and a note
  to run `fw prepare` again. Switching the patch off removes the marker. The
  marker is written once, so its creation time says when the guest got a GPU.
- **Icon store.** Without a GPU, iconservicesagent rendered every graphic icon
  (an SF Symbol on a colored square, declared as `com.apple.graphic-icon.*` in
  `MobileCoreTypes.bundle`) fully transparent, stored the result in
  `systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache`,
  and kept serving it: Settings' rows stayed blank after the GPU worked. At
  startup vphoned removes that store when it was created before the marker and
  stops the agent (`GuestIconServicesCache`), because the Data volume is out of
  the host's reach. A machine created with the transport on renders its icons
  with the GPU from the first boot, so it never drops.

## Retargeting to another pairing

Do not widen the gate without repeating the measurement:

1. Extract IOGPU.framework from both shared caches
   (`ipsw dyld extract … IOGPU`), disassemble with symbols, and list each
   `bl _IOConnectCall*` with the selector in `w1` and the size arguments.
2. Pair the sites by caller symbol. Any change other than the shift above needs
   a new rule.
3. For the driver, probe each paravirt method's accepted struct sizes against the
   target kernel from a guest test binary (size sweep; refusals are 0xe00002c2).
4. Repeat the guest checks below.

## Verified

Test process on `exc822-1862` (iPhone17,3 18.6.2 over cloudOS 26.1, bundle
2.15.2-local, 2026-11-04), with the 18.6 driver and the prototype of this
transport: `MTLCreateSystemDefaultDevice` returned "Apple Paravirtual device GPU".
Blit fill 4096/4096, render-pass clear read back 4096/4096, IOSurface render
target and shared event (signaled 7), shader compile through `MTLCompilerService`,
and a compute pipeline whose dispatch read back 1024/1024. No IOKit call returned
an error.

System-wide on the same machine (2026-11-05), bundle built from this change plus
PR #822, driver staged as `fw prepare` now stages it, then `cfw install`:

- `cfw install` wrote `/usr/lib/vphone-ios18-gpu` over the 18.6 driver.
- IORegistry: paravirt device clients held by backboardd, SpringBoard,
  runningboardd, Preferences, iconservicesagent, cameracaptured, mediaanalysisd
  and the poster and widget extensions.
- Lock screen wallpaper with the depth clock, home screen widgets and dock
  material, Settings with an unclipped status bar, and the vector map in Maps
  (a sandboxed app) all render. SpringBoard and backboardd kept their pids
  across the session. No panic in four boots.
- A probe in the `temporary-sandbox` profile, with SystemHook loaded inside the
  sandbox, reads the marker and gets a device.

Open:

- `com.apple.MapKit.SnapshotService` aborted once in each of the first two boots,
  about 9 s after SpringBoard started, in `-[AppleParavirtDevice setupCompiler]`
  (`compilerTargetInfo.shaderVersionMajor >= 2`). That field comes from the
  device-info reply, so that call was not translated there. It did not recur in
  the next two boots and could not be started on demand. The cause is unknown.
- cameracaptured aborts in `MPSLibrary::MPSKey_Compile` (`MTLReportFailure`)
  while prewarming its matting inference, three to five times in some boots and
  not at all in others. That is an MPS kernel compile failure under a working
  device. Not yet explained.

Settings icons (2026-11-05): an icon probe got a non-placeholder, fully
transparent 87×87 image for `com.apple.graphic-icon.gear` at
`kISImageDescriptorTableUIName`, while a synchronous render at an unused size
was correct (system-gray enclosure). With the agent stopped first and the store
moved aside, the same request rendered and Settings showed every row icon.
Renaming the store while the agent runs does not work: the agent keeps writing
into the renamed folder and later deletes it. With the bundle's vphoned the store
created on 2026-11-04 was dropped at the next boot (new store born 00:59:35 UTC,
after the marker's 00:37:25), the icons rendered, and a further boot kept it.
