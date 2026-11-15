# Experimental iOS 17.7 desktop bring-up

The experimental guests use iOS 17.7 userland with the cloudOS 26.1 vphone600
kernel and boot chain. The [original iPhone 15 bring-up](https://github.com/Lakr233/vphone-cli/pull/794)
uses the iPhone15,4 IPSW. The SE 3 uses its own iPhone14,6 IPSW (21H16) and
requires cloudOS build 23B85.

## Reproduce

Build and install the complete VPhone bundle as described in the main guide.
With the installed version in `<bundle>`, create a separate iPhone 15 guest:

```sh
vphone-launchpad-cli vm create ios17-test --bundle '<bundle>' \
  --device iPhone15,4 --cpu 6 --memory 6144 --disk-size 64 --network none \
  --iphone-source 'https://updates.cdn-apple.com/2024FallFCS/fullrestores/062-78954/8A879FCE-CD96-4FEB-BAFB-0FF58CCB5058/iPhone15,4_17.7_21H16_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349' \
  --no-template --keep-artifacts \
  --allow system-springboard-exp-ios17_desktop
```

Creation may report non-applicable camera, audio and launchd patch failures;
they are not silently counted as applied. Keep those logs. Wait for vphoned,
then apply the same uncompressed CoreAnimation defaults as the iOS 18 route.
Before changing an existing guest, save its global preferences with `guest pull`
if the file exists; preserve the absence of a previously absent file too.
The following script merges only the three keys, retaining other preferences:

```sh
vphone-launchpad-cli guest rpc ios17-test script.eval '{"source":"var p=\"/var/preferences/.GlobalPreferences.plist\"; var C=ObjC.use(\"NSMutableDictionary\"); var d=C.dictionaryWithContentsOfFile_(p); if(!d)d=C.new(); for(var k of [\"CAEnableIOSurfaceCompression\",\"CAEnableFramebufferCompression\",\"CAEnableDeepFramebuffer\"])d.setObject_forKey_(false,k); d.writeToFile_atomically_(p,true)"}'
vphone-launchpad-cli vm stop ios17-test
vphone-launchpad-cli vm start ios17-test --wait
vphone-launchpad-cli guest unlock ios17-test
```

### iPhone SE (3rd generation)

Use the same cloudOS source and SpringBoard selection with the D49AP restore:

```sh
vphone-launchpad-cli vm create iPhone-SE3-iOS17 --bundle '<bundle>' \
  --device iPhone14,6 --cpu 6 --memory 6144 --disk-size 64 --network none \
  --iphone-source 'https://updates.cdn-apple.com/2024FallFCS/fullrestores/062-79092/3B7E217F-B59B-4FBB-B682-A1154B0B7039/iPhone14,6_17.7_21H16_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349' \
  --no-template --keep-artifacts \
  --allow system-springboard-exp-ios17_desktop
```

Run the preferences, restart and unlock commands above with
`iPhone-SE3-iOS17` as the machine name. The existing SE 3 presentation path
uses a 750×1334 panel at scale 2 and keeps the donor Home button type in the
installed device tree.

For GPU acceleration on either model, prepare and restore with a bundle that
includes the legacy GPU transport. Firmware preparation stages the cloudOS
18.6 driver. An existing installation that still carries the 26.1 driver
needs the staged 18.6 driver and a CFW install.

## What changed and why

- Device description for iPhone15,4/D37AP: 1179x2556 at 3x.
- Existing SwapEnd patch: the 17.7 userland sends 0x508; the 26.1 kernel accepts
  0x560. The existing semantic decoder finds the selector-5 call and size load.
- Existing thread-guard and paravirtual-user-client compatibility patch gates
  include 17. No new kernel instruction encoding is introduced.
- The existing BSD-only skywalk boot argument also covers 17. The older
  Network.framework otherwise traps in `os_channel_create_extended`, including
  chronod; SpringBoard synchronously waits for its extension subscription.
  Networking remains unvalidated, so this recipe deliberately uses no NIC.
- seputil's full `%s/%s.gl` format literal is referenced by ADR on 21H16, rather
  than ADRP+ADD. Recognizing that decoded reference lets the existing two-byte
  data patch select AA.gl. No device UUID is embedded in code or in the recipe.
- The new opt-in `system-springboard-exp-ios17_desktop` stages
  `libvphoneios17desktop.dylib`. The installer adds a weak load to SpringBoard
  and backs up the original executable; the library also checks process name
  and OS major at runtime.
  It skips `CHSWidgetExtensionProvider`'s initial synchronous content load and
  disables AVFlashlight construction/capability. Thread traces identify these
  two synchronous service dependencies as desktop startup blockers. Widgets and
  flashlight are sacrificed explicitly, not reported as supported.

## Undo

Turn off `system-springboard-exp-ios17_desktop` through Patch Settings or
`fw set-patches --block`, then run `cfw update-environment` while stopped and
restart. The selection restores the original SpringBoard and removes the library;
the next process starts with native methods again. There is no shared-cache edit or permanent method modification
for this workaround. The native desktop may stall again when it is off.
Restore the saved global preferences (or their original absence) to undo the
separate CoreAnimation defaults. CPU, memory and NIC configuration are ordinary
VM settings. No host security or global default bundle setting is changed.

## iPhone 15 evidence and limits

The first prototype booted and cold-rebooted, reported iPhone15,4 and iOS 17.7.0,
completed first-boot migration, unlocked, and displayed the Home Screen icons and
Dock. The user confirmed the desktop in a screenshot. The prototype's temporary
UUID hard link and direct SpringBoard load command are not the integrated path:
the integrated installer uses the seputil patch and a selection-owned,
backed-up weak load.

A separate guest was restored from the two original IPSWs with the integrated
boot patches, then updated to the final guest installer. It cold-booted and
unlocked to Home Screen icons and Dock; Calendar displayed its date and empty
agenda while Weather reported unavailable. The installed SpringBoard had the
weak library dependency. Turning the selection off, updating the environment
and rebooting removed the library and restored SpringBoard byte-for-byte to
the original (matching SHA-256). Re-enabling, updating the environment and
cold-booting again returned to the Home Screen.

- Wallpaper remains black; widget discovery is bypassed and widget behavior is
  incomplete or unvalidated. Widgets can appear blank or unavailable.
- No compatible Metal driver is claimed. The 26.1 driver cannot be assumed to
  work against the 17.7 IOGPU framework.
- Camera, flashlight, audio feature coverage and network usability are not
  validated. The scope is reaching the desktop.
- Some stock services still crash or fail to execute across the version gap.
- Do not describe this as a native iOS 17 kernel or support for every 17.x build.

Automated validation and a separate integrated clean-restore result are recorded
in the PR description, with prototype observations distinguished from that run.

## SE 3 evidence and limits

On 2026-11-13 a fresh standalone VM completed DFU restore, CFW installation,
first-boot migration and setup. After setting the three CoreAnimation defaults,
it completed an explicit stop and start with a new boot-session UUID. vphoned
answered after five seconds and reported iPhone14,6, iOS 17.7.0 and 375×667
points at scale 2. The Home Screen and Dock rendered at 750×1334. Taps
opened Calendar and dismissed its welcome sheet to show the day view. The
virtual Home button returned to the Home Screen.

The restore logs show Home button type 2 in the restore tree, type 1 in the
installed tree and LLB scale 2. CFW installed the existing SpringBoard weak
load and applied both the SwapEnd resize (0x508 to 0x560) and the seputil
gigalocker name change. The release pairing required only a preparation
validation change. The bundle build, 43 device and catalog tests, and an
explicit refusal of the SE 3 IPSW with cloudOS 26.4 passed.

Settings twice timed out while creating its scene, including after a cold
start. The first watchdog report shows a wait on iconservices, and an
iconservicesagent report records a crash in `CI::GLContext::init()`. The
default wallpaper was black, and both widgets displayed placeholders. The
`AegirPoster` crash report shows an assertion during Metal pipeline creation
in `NUNICalliopeResourceManager`. A native Color wallpaper set through the
Lock Screen gallery rendered on both screens after a cold start. The
[iOS 18 GPU transport](ios18_gpu_transport.md) uses a driver and ABI adapter
measured for 18.6, so this test used the existing iOS 17 rendering path.
Networking was disabled for this run. Camera, audio and Metal were outside
that first validation.

## iOS 17.7 GPU rendering

The cloudOS 26.1 GPU driver fails to load on iOS 17.7 because its IOGPU
dependency lacks `_OBJC_IVAR_$_IOGPUMetalHeap._device`. The cloudOS 18.6
driver loads. Its Metal device uses the existing 18.6 transport, with two
additional adapters for 17.7:

- The IOGPU single-buffer submission uses trap 0 with a 40-byte entry.
  The adapter forwards it through the existing widened method submission.
- The IOGPU completion reader allocates 32 bytes. The cloudOS queue writes
  40 bytes, and the original dequeue returns `kIOReturnNoSpace`. The
  adapter dequeues the actual 40-byte entry and returns its first 32 bytes,
  which contain the original callback token, timestamps and status.

The 18.6 driver loads the transport before registering a Metal device.
On an SE 3 guest that kept its original wallpaper selection, the App Library
rendered a blurred background and translucent materials after a cold start.
A Metal probe read back a 4096-byte blit fill, 1024 compute results, and
256 render pixels. Settings opened and showed its row icons. The wallpaper
gallery displayed thumbnails and opened the Astronomy editor. The existing
wallpaper selection still rendered black, and the Astronomy preview showed
artifacts.

On iPhone 15 (D37AP), a fresh restore and cold boot also rendered App Library's
blurred backdrop and translucent search field. The Metal probe passed the same
blit, compute and render readbacks at 3× display scale. The stock iOS 17
wallpaper (CollectionsPoster identifier `7565`) remained black in the active
lock screen and the editor. Its 393×852-point layered animation and HEIC
resources were present. In the editor, CollectionsPoster loaded bundle
`7565` and configured its layers, then ImageIO logged `CGImageBlockCreate
… data is NULL` and `decodeImageImp failed - NULL _blockArray`, including
at the stock background's 1700×1300 dimensions. This identifies a failure
to produce decoded pixel data in the wallpaper extension. The reason that
ImageIO returns no data remains unconfirmed.

## Stock wallpaper image assets

The Standard preset on iOS 17.7 with cloudOS 26.1 enables
`system-wallpaper-cfw-ios17_image_assets`. The host decodes the original
HEIC layers of wallpaper `7565` and writes PNG copies beside them. The
installer changes the corresponding image references in each CAML document.
The layer tree, animation and appearance states, original HEIC files, and
SpringBoard's selected poster stay in place.

The patch works on an existing guest through `cfw update-environment`.
After a cold start the original wallpaper rendered on the Lock Screen and
Home Screen on iPhone 15 and iPhone SE 3. The installed documents referenced
39 image files on iPhone 15 across the three supplied screen variants and
13 on iPhone SE 3. Blocking the patch and updating the environment restores
the backed-up CAML documents and removes the PNG copies. On SE 3, a rollback
restored a sampled CAML document byte for byte and removed its PNG copies.
Re-enabling the patch restored the PNG references. Reversing the reference
substitutions in the sampled patched document reproduced the original bytes.
