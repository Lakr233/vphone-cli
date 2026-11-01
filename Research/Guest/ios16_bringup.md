# Local iOS 16.6.1 bring-up experiment

Status: original IPSW restored and guest custom firmware installed. Launchd,
libxpc, backboardd and vphoned run. SpringBoard now reaches its main run loop;
its unavailable media controllers, widget fetch, flashlight and three media
Control Center modules have been bypassed. The latest main-thread sample is
idle in CFRunLoopRunSpecific/UIApplicationMain. Desktop display has not been
verified: the computer-use tool reports the host Mac is locked, and the user
has been asked to unlock it. The actual Preboot kernel contains the measured
syscall-filter relaxation. The original media executable is restored, and both
temporary dyld close patches are undone and removed from the final source.

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
with the media service's retained entitlements. The current investigation reads
the faulting thread's errno through THREAD_IDENTIFIER_INFO and the measured
20G81 __error TLS layout. No random bytes are replaced or fabricated.

## Current checkpoint

The active lab is `/Users/Shared/VPhoneLab16/iPhone-14-Pro-iOS16-Lab`.
The untouched external restore copy was moved out of the machine list to
`/Volumes/ZHITAI/Data/VPhone/Library/lab-backups/iPhone-14-Pro-iOS16-Lab-restored-original`.
Use the internal library root explicitly. The current running bundle is
2.15.0-local.eda73803; the cleaned build has not yet been deployed because
visual verification of the running guest awaits host unlock.

The standard preset has six explicit allows: registered Mach-port bridge,
early cache lookup, existing syscall-filter relaxation, ephemeral keybag init,
backboard migration wait, and SpringBoard desktop startup. The unmatched
launchd jetsam pattern remains blocked. All new declarations are off in every
bundled preset. Audio, widget content, flashlight and media Control Center
modules are unavailable. This is experimental startup, not supported iOS 16.

The cleaned native bundle build and admission pass. The 47 catalogue/plan/parser
tests pass after removing discarded experiments; the native Mach-port test
passes register/lookup round-trip, empty slots and count bounds. Earlier
full-cache apply/idempotence/undo reproduced the pristine affected chunk.
The iOS 17 PR branch remains unchanged and clean. No iOS 16 work was pushed.
