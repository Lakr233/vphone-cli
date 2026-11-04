# Experimental iOS 16.6.1 desktop bring-up

This is an opt-in fresh-lab experiment, not general iOS 16 support. The measured
VM reaches the native SpringBoard desktop, accepts mouse clicks and swipes, and
opens Settings > General > About. About shows iOS 16.6.1, iPhone 14 Pro and 64 GB.
The native keybag remains locked: UI-only lab mode does not decrypt protected
data, implement credentials, or support migrating an existing user's device.

## Measured configuration

- iPhone 14 Pro: iPhone15,2/d73ap, 1179 × 2556 at 3x.
- Userland: iOS 16.6.1, 20G81.
- Boot chain/kernel: cloudOS 26.1, 23B85, vphone600.
- 6 CPUs, 6144 MB RAM, 64 GB sparse disk, network `none`.
- [Apple IPSW](https://updates.cdn-apple.com/2023SummerFCS/fullrestores/042-44327/EDD9D5D2-E1C0-4B64-B6B1-642E087BB595/iPhone15,2_16.6.1_20G81_Restore.ipsw).
- IPSW SHA-1: `1d80ba85912850bb6cc62540730652b29e4c3e8e`.

Firmware preparation accepts this exact experimental pairing. The existing
older-userland SwapEnd, thread-guard and paravirtual-user-client paths also
accept 16; the BSD-only Skywalk boot argument is used. The iOS 17 desktop hook
is never enabled for 16.

## Selection and deployment

Every experimental addition is disabled in all shipped presets and without an
explicit plan. Start with `standard` and explicitly allow these identifiers:

```text
system-launchd-exp-ios16_mach_ports
dyld-exp-ios16_mach_ports_lookup
kernel-exp-frida_syscall_filter_off
system-keybag-exp-ios16_ephemeral
system-backboard-exp-ios16_migration
system-springboard-exp-ios16_desktop
system-systemhook-exp-ios16_surface
system-systemhook-exp-ios16_framebuffer
preboot-exp-ios16_ephemeral_storage
system-vphoned-exp-ios16_touchscreen
system-springboard-exp-ios16_keybagless_ui
```

Explicitly block `system-launchd-boot-jetsam_panic_guard_bypass`: its pattern is
absent on 20G81 and otherwise aborts the grouped launchd patch before hook load.
Pass these selections to `vm create` or `fw set-patches`; the latter replaces
its entire override record, so retain every required allow when changing it.
Use Launchpad's CLI and a complete locally built `VPhone.bundle`, not a detached
copy of the host executable. See `Documents/en/launchpad/launchpad-cli.md` for installing
that bundle and binding a machine without changing other machines' versions.

Boot-chain changes require firmware preparation/patching and restore. The
post-restore device-tree step owns the ephemeral-storage flags. Guest markers,
cache metadata and inserted libraries are selection-aware and synchronized by
`cfw install` / `cfw update-environment` while stopped. Cache metadata generation
runs in separate CLI child processes so cache mappings do not hold installation
mounts open. A successful command is insufficient evidence of a usable desktop;
check the guest UI after a cold boot.

Retain an offline backup of Disk.img, SEPStorage, nvram.bin, configuration and
patch records before enabling native ephemeral storage. The lab used APFS
clones before that transition. These backups are part of the VM's retained
`BeforeEphemeral` directory. The lab was later copied to an external APFS volume;
main and backup disk logical contents were compared before the external copy
was successfully cold-booted. Machine configuration uses relative file paths.

## What each adaptation fixes

Launchd initially dies at `mach_ports_register` with "could not set up inheritance
port". The native hook translates old out-of-line self-task calls to XNU's newer
inline-three-port RPCs. Spawned libxpc initializes before constructors, so its
old `mach_ports_lookup` client also needs a bounded, symbol-derived cache patch.
The modern reply decoder preserves allocated-array semantics and error cleanup.

Backboard initially waits inside `_DMPerformMigration`. The local migration hook
skips that measured wait, completes/unblocks the native shell sentinel, and
suppresses its PreBoard-only re-block. Native ephemeral-storage device-tree
flags then make `hw.ephemeral_storage` and `os_variant_uses_ephemeral_storage`
report 1; PreBoard no longer runs. SpringBoard's native setup setter clears its
local setup reason. Unavailable media/widget/flashlight startup waits are omitted.
No persisted migration-complete record or setup preference is fabricated.

IOSurfaceRoot capability replies grew from 0x18 to 0x28 and allocation/lookup
replies from 0xA68 to 0xC68. The converter checks narrowing of widened values and
maps the changed header and up to 20 planes. Offline metadata identifies the
framework-private IOKit stub by decoded calls/literal references and records its
UUID and expected bytes. Runtime installation uses a process-private COW page,
suspends peers during replacement, and never keeps a page writable/executable.
Other processes and the shared-cache file are not modified by the detour.

IOMobileFramebuffer's SwapEnd payload grew from 0x46C to 0x560. Its converter
inserts nine event-value slots and nine port slots, preserving the measured frame
token, surfaces, rectangles and flags. Native IOSurface create/lock/write/read/
unlock, ID lookup and Mach-port lookup pass. Submitted color bars, Lock Screen
and the real SpringBoard desktop become visible. This does not implement Metal.

Backboard drops injected touches when no main-screen digitizer exists. The
selected daemon registers a built-in touchscreen only if none is present.
SpringBoard also publishes its native backlight-state changes through the legacy
HID factor API; its third argument is a publication Boolean, not the source enum.
A Home press changes the measured factor from 0 to 1. Real mouse swipes and
clicks then respond. A blank screen after idle can still be normal display sleep.

The fresh guest contains only session/persona keybags. A single native
nil-passcode probe returned -8 and left MKB lock state 1; no password was supplied
or created. The UI-only selection requires a root daemon's strict directory
allowlist and an atomic, root-owned, single-link, magic-checked lease refreshed
every second. A lease older than three seconds is rejected. Three signature-
checked UI getters use an unprotected UI model only during a valid lease;
MKB/AKS and key material are untouched. Unknown files or read errors refuse mode.

Settings originally crashes before main because the existing battery helper
strongly imports `IOPSCopyPowerSourcesByTypePrecise`, absent on 20G81. It now
weak-imports that API and uses its existing ByType implementation on older bases.
A native host weak-import/interpose probe passes and the real Settings app opens.
About initially waited on SystemConfiguration's Ethernet-watcher once token and
IOKit quiescence; it subsequently worked without an additional patch.

## Verification and limitations

The PR branch, rebased onto upstream fd1610d7, passed complete native Debug
bundle build and bundle admission. Its selected catalogue, plan, parser, encoder,
device-tree and guest-patch resolution run passed 102 tests in seven suites;
20 guest-device tests also passed. The guest archive contains both iOS 16 hook
libraries. Native Mach-port register/lookup, empty-slot and count-bound tests
pass. ASan/UBSan conversion and lease-policy tests cover field bounds, narrowing,
inserted slots, lease freshness, timestamps, ownership, file types and modes.
The real guest displayed Home Screen and Settings/About with working mouse input.
These are bounded bring-up results, not full OS or every-application validation.

The unrestricted firmware test run was also attempted: it reports missing local
reference fixtures (dyld caches, Mach-O binaries and raw firmware payloads),
including tests that deliberately fail rather than silently pass without data.
That full run was not green; the 102-test result above is the selected run,
not a claim that all 818 firmware tests passed. Reference Apple binaries are not
included in this PR. The three native compatibility test targets are wired into CI.

Wallpaper stays black. Add New Wallpaper crashes its Metal preview because the
guest has no Metal device; the cancelled software-preview prototype is excluded.
The proposed About fallback was never installed and is also excluded. Widget
content, audio/media routing, camera, flashlight, networking and persistent
protected data remain unavailable or unverified. The IPSW contains only a Files
app placeholder, not a complete executable. Dynamic wallpapers, iOS 15 and other
iOS 16 releases have not been demonstrated.
