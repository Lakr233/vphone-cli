# Experimental iPhone 15 / iOS 17.7 desktop bring-up

This is desktop-only bring-up, not general iOS 17 support. The guest uses the
actual iPhone15,4 17.7 (21H16) userland and the cloudOS 26.1 (23B85) vphone600
kernel/boot chain. The only accepted 17.x preparation pairing is this one.

## Reproduce

Build and install the complete VPhone bundle as described in the main guide.
Keep other machines on their existing bundles. With the installed version in
`<bundle>`, create a separate disposable guest:

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

The scripted preferences step is currently required; this PR does not claim that
one stock New Machine click completes every display compatibility setting.

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

## Evidence and limits

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
