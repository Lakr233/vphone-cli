# Local iOS 16.6.1 bring-up experiment

Status: native SpringBoard desktop and mouse interaction are verified on the
fresh iOS 16.6.1 lab. IOSurface and framebuffer protocol adapters restore real
scanout; a missing HID touchscreen and the old backlight publication path were
separate input blockers. Settings now renders General after its battery helper
stopped strongly importing a newer IOKit API. About now works on the same guest
without an additional patch, after its native network initialization wait.
The wallpaper experiment was stopped at the user's request before deployment;
the running lab retains its working 2.15.0-local.7097296f environment.

This remains an experimental, ephemeral UI bring-up. Its fresh keybag-less UI
mode does not unlock encrypted storage or provide working passcodes. Native
MKB/AKS are unchanged. Other applications and persistent protected data are not
claimed to work.

- Guest: iPhone 14 Pro, iPhone15,2/d73ap, 1179x2556 at 3x.
- Userland: iOS 16.6.1, 20G81.
- Boot chain and kernel: cloudOS 26.1, 23B85, vphone600.
- VM: 6 CPUs, 6144 MB RAM, 64 GB disk, no NIC.
- Apple IPSW: `https://updates.cdn-apple.com/2023SummerFCS/fullrestores/042-44327/EDD9D5D2-E1C0-4B64-B6B1-642E087BB595/iPhone15,2_16.6.1_20G81_Restore.ipsw`.
- IPSW SHA-1: `1d80ba85912850bb6cc62540730652b29e4c3e8e` (verified after download).

This branch enables the existing older-userland SwapEnd, thread-guard and
paravirtual-user-client declarations for 16, plus the BSD-only Skywalk boot
argument. It does not enable the iOS 17-specific SpringBoard library on 16.
Firmware preparation is restricted to this exact experimental pairing.

Initial validation: complete native bundle build and admission passed;
69 selected firmware/patch-model tests and 20 guest-device tests passed.
The original IPSW restore completed. Guest installation was then refused by
the host helper while walking the external library path, even though that
directory exists. A separate internal-disk copy is being used to distinguish
host path access from guest compatibility.

On the pristine 20G81 seputil, the existing patch resolved the complete
`%s/%s.gl` literal at 0x10001D3A4 through a code reference at 0x10000BEC4.
It changed only the filename field to `AA` and an immediate second run was
idempotent. This is an offline binary check, not evidence of a normal boot.

The user completed macOS administrator authentication and the internal install
completed. On first normal boot, launchd exits PID 1 with "could not set up
inheritance port". Its call at 0x10001682C is `_mach_ports_register`; the next
instruction branches to that fatal block on failure. XNU 12377.41.6 uses fixed
three-port descriptors for task RPCs 3403/3404; iOS 16 uses an OOL port array.

The opt-in `system-launchd-exp-ios16_mach_ports` selects an API bridge in
launchdhook/SystemHook and its marker. Native self-task register/lookup tests
pass. The VM also blocks `system-launchd-boot-jetsam_panic_guard_bypass`, whose
pattern is absent on 20G81: otherwise the existing grouped launchd patch fails
before it inserts launchdhook. The bridge selection now owns launchd's weak
load and backup in the same group, so installation cannot count only the marker
as success. Guest console confirms register3 succeeds and launchd completes
early boot. Spawned xpcproxy processes then trap before inserted-library
constructors: exception diagnostics locate `__libxpc_initializer.cold.6` at
0x1E6EE647C, reached from the failed `_mach_ports_lookup` call at 0x1E6ECBCA4.

`dyld-exp-ios16_mach_ports_lookup` is a second, explicitly selected cache
patch. It replaces the bounded 388-byte `_mach_ports_lookup` client at
0x1C5FFC078 in libsystem_kernel with the modern inline-three-port reply
decoder, preserving the public allocated-array API. PC-relative request
construction stays in place; the expanded reply frame preserves FP-relative
saved registers and compact unwind. The generated payload validates reply ID,
size, descriptor count and dispositions and preserves error cleanup. Cache
writes are re-attested and recorded for opt-out restoration. No guest success
is claimed for this second patch until normal boot is retested.

Protocol reference: Apple XNU `xnu-12377.41.6`, `osfmk/mach/task.defs` and
`libsyscall/mach/task.c`. The guest runs `kernelcache.release.vphone600`
26.1/23B85 (Darwin 25.1.0, xnu-12377.42.6~55).

The inline-port cache client passes the eighth real boot: libxpc initializes,
system services run and vphoned answers. The full affected cache chunk matches
its pristine input after offline apply/idempotence/undo testing. 70 selected
patch-model tests pass; a subsequent catalogue/plan run passes 41 tests.

The next desktop blocker is measured in backboardd's migration queue, waiting
inside `_DMPerformMigration`. A local opt-in backboard library releases this
call. On the next boot that stack disappears, but SpringBoard still waits in
FBSystemShellInitialize. Static analysis of BKSystemShellSentinel's
`checkInAndWaitForDataMigration:completionBlock:` at 0x100064D30 shows another
wait on `_lock_migratorDidComplete` and `_lock_systemAppBlocked`. PreBoard is
running and holds the alternate-system-app block. The next test asks this
native check-in method to use its existing non-waiting mode. Method encodings
are checked before replacement. No global migration-complete state is written.

After boot, auto-boot is set false by the incomplete migration flow. A small
native libirecovery helper, restricted to this VM's ECID C9E118E06642A328 and
recovery-mode PIDs, restores auto-boot and reboots. This is a lab workaround,
not a general recovery or SEP compatibility fix.

The native EXC_CRASH observer captured the media failure before inserted-library
constructors execute: abort <- cc_abort <- ccrng_getentropy_generate <-
ccrng_process_init <- arc4random_buf <- libobjc initialization. Independent
getentropy/arc4random probes pass as root and mobile, including a probe signed
with the media service's retained entitlements. The investigation read
the faulting thread's errno through THREAD_IDENTIFIER_INFO and the measured
20G81 __error TLS layout. No random bytes are replaced or fabricated.

## Current checkpoint

The active lab is `/Users/Shared/VPhoneLab16/iPhone-14-Pro-iOS16-Lab`.
Use that library root explicitly. The external restored original is retained at
`/Volumes/ZHITAI/Data/VPhone/Library/lab-backups/iPhone-14-Pro-iOS16-Lab-restored-original`.
Before enabling the native ephemeral-storage flags, the mutable disk, SEP
storage, NVRAM, configuration and patch receipts were APFS-cloned under the
internal lab's `BeforeEphemeral` directory. They have not been restored or deleted.

Native probes now report `hw.ephemeral_storage=1` and
`os_variant_uses_ephemeral_storage=1`. PreBoard no longer runs. Backboard's local
shell sentinel reports migration complete, unblocked, and no alternate system
app. SpringBoard's main thread reaches its ordinary run loop. The fresh Data
volume has only session/persona keybags; no system keybag is provisioned.

The measured protocol adaptations are:

- The early Mach-port bridges described above, including an inline-three-port
  cache client for old libxpc.
- IOSurfaceRoot selector 13's capability reply: modern 0x28 to old 0x18, with
  widened integer fields narrowed only when representable.
- IOSurface allocation/lookup reply: modern 0xC68 to old 0xA68, including the
  0x88/0x98 plane header/stride to 0x68/0x80 layout, up to 20 planes.
- IOMFB method-5 input: old 0x46C (or its earlier size-only 0x560 patch) to the
  new 0x560 layout. The nine widened event-value and event-port slots are zero;
  frame token, surface/rectangle fields and measured flags retain their meaning.

Display adaptation patches only an attested framework-private IOKit transport
stub in process-private memory. Generated metadata validates the framework UUID,
original stub and displacement; the shared cache file is not modified by this
runtime adapter. Host metadata is prepared in a child so cache mappings are
released before the installer unmounts its staged volume. Native surface
create/lock/write/read/unlock, ID lookup and Mach-port lookup pass. A manual RGB
frame visibly reaches VZ, followed by native Lock Screen and desktop frames.
Animation samples around 100–120 fps do not establish sustained application
performance; a static screen can correctly report zero new frames.

## Input and fresh-lab UI

A HID monitor proves normalized digitizer events reach backboardd. Its first
rejection was "AX event, but main screen digitizer is missing". The new manual
`system-vphoned-exp-ios16_touchscreen` registers a display-integrated built-in
HID touchscreen only if none exists. Backboard then acquires its main digitizer.
The next rejection was "backlight dim/off": SpringBoard's newer brightness path
never published the legacy HID factor. The desktop library now forwards the
native requested backlight state and publishes its native factor through the
system-app API with the correct BOOL publication flag. Actual Home events now
change the protected factor from 0 to 1, and real mouse swipes/clicks respond.

The empty lab's native keybag query still returns lock state 1; a single native
nil-passcode check returns -8. No passcode was supplied or created. The manual
`system-springboard-exp-ios16_keybagless_ui` is a UI-only experiment: vphoned,
as root, checks explicit markers, native ephemeral storage and a root-owned
keybag directory containing only the measured session/persona files. Any unknown
entry, system bag, symlink or read error refuses the mode. A root-owned atomic
lease expires after three seconds. Only while it is valid, the selected
SpringBoard library uses the unprotected UI model through three signature-checked
Objective-C getters. It does not replace MKB/AKS, alter a credential or decrypt
protected data. Keep this separate from genuine keybag compatibility.

The selected lab uses standard with explicit manual allows for:
`system-launchd-exp-ios16_mach_ports`, `dyld-exp-ios16_mach_ports_lookup`,
`kernel-exp-frida_syscall_filter_off`, `system-keybag-exp-ios16_ephemeral`,
`system-backboard-exp-ios16_migration`, `system-springboard-exp-ios16_desktop`,
`system-systemhook-exp-ios16_surface`, `system-systemhook-exp-ios16_framebuffer`,
`preboot-exp-ios16_ephemeral_storage`, `system-vphoned-exp-ios16_touchscreen`,
and `system-springboard-exp-ios16_keybagless_ui`.
The unvalidated `system-posterboard-exp-ios16_cpu_preview` remains disabled.
The unmatched `system-launchd-boot-jetsam_panic_guard_bypass` remains blocked.
All new declarations remain off in every bundled preset and with no explicit
plan. Newer guests do not select these iOS 16 paths.

## Settings and validation

Settings initially exits in dyld before main because libbatteryhealthfix
strongly imports IOPSCopyPowerSourcesByTypePrecise, absent from 20G81's IOKit.
The import is now weak; older bases can use the existing ByType path, while
newer bases retain Precise. A host dyld compatibility probe passes, and the
actual guest now renders Settings > General.

Opening About then blocks in PSGAboutDataSource._macAddress ->
_SCNetworkInterfaceCopyAllWithPreferences, waiting on a background Ethernet
watcher's once token and IOKit quiescence. The real FrontBoard watchdog report
is Preferences-2026-11-01-205100.ips. Before a proposed fallback was deployed,
the user confirmed that the native page works on 2.15.0-local.7097296f and
provided a screenshot showing 16.6.1, iPhone 14 Pro and 64 GB. The fallback was
withdrawn from the final source and never selected or installed. Initial
quiescence can still delay this page.

Wallpaper settings opens. Add New Wallpaper instead crashes PosterBoard in
PBFHomeScreenPreviewImageBuilder._imageForView:, whose Metal renderer inserts
a nil command queue into an options dictionary. A native probe confirms that
MTLCreateSystemDefaultDevice returns nil. The new manual-only software-preview
patch replaces only that signature-checked helper when Metal is unavailable,
using a bounded UIKit bitmap renderer. Its actual gallery and static wallpaper
application validation was stopped at the user's request. The build was
interrupted and no wallpaper prototype was installed. Dynamic wallpaper
rendering is not claimed.

The selected catalogue/plan/parser/encoder/device-tree run passes 50 tests in
five suites before the wallpaper addition. Native ASan/UBSan surface conversion and
lab-lease policy tests pass. Full bundle builds and admission pass at each
reported deployed checkpoint. The wallpaper addition still needs its final build,
selection validation and real UI test.

Audio/media routing, widget contents and flashlight remain unavailable. Network
is intentionally none. The iOS 17 PR source branch is unchanged and clean; no
iOS 16 work has been pushed.
