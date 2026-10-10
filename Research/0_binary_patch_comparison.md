# Patch Comparison: Regular / Development / Jailbreak / Experimental

> **iOS 27 locationd startup (2026-10-08):**
> `system-locationd-cfw-disable_auto_cohort` disables only `CLAutoCohort` in
> `System/Library/FeatureFlags/Domain/CoreLocation.plist`. The guest system set
> selects it for iOS 27 only; `cfw install` and environment updates back up the
> original plist and restore it when deselected. Independent location silos
> avoid the startup queue hangs/PAC failures seen with automatic cohorts on
> the cloudOS 26.4 research kernel. No executable or PAC instruction is patched.
> On `loc27-iphone` (24A435), 20 locationd restarts and 5 cold boots answered
> before watchdog recovery; restoring the original flag brought back repeated
> launches and a watchdog kill. A fresh iPad16,1 24A446 guest reproduced the
> same PAC failure with stock cohorts; with this change, another 20 restarts
> and 5 cold boots passed, with no new crash reports or watchdog actions. See
> [evidence and verification](Guest/locationd_27_0_1_startup_race.md).

> **Patch sets and presets (2026-09-28):** every patch is now *declared*, and
> selection happens before any byte is written. The declarations live in nine
> bundled patch sets under `VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/`
> (`bootchain`, `kernel.base`, `kernel.cfw`, `kernel.hypervisor`,
> `kernel.frida`, `devicetree`, `guest.system`, `guest.display`,
> `guest.identity`), listed by `FirmwarePatchSetCatalog`. A declaration's
> identifier is the record identifier the patcher already emits, or the common
> prefix when one patch writes several sites — so `jb.kcall10` is one selectable
> patch covering its four records, and `sandbox_ext` covers every
> `sandbox_ext_<index>`. 122 patches are declared in total. `vphone-cli fw patches`
> prints them; `--json` is what the Launchpad patch editor reads.
>
> Two presets ship, prewritten, in
> `VPhone.bundle/Contents/Resources/patches_presets/`. Both name all nine sets and
> differ only in their selection: `standard` (the default, and what a VM gets
> unless `--preset` says otherwise) blocks the two Frida Stalker relaxations, the
> three `hv_vmm_present` concealment patches, and the iPhone17,3 identity rewrites;
> `extended` blocks nothing.
>
> **iPad guests (2026-10-01; every current iPad 2026-10-02):** five DeviceTree
> patches, on in `standard`, exist only for a VM whose userland comes from an
> iPad restore IPSW (iPad mini A17 Pro, iPad A16, iPad Air M3 11/13, iPad Pro
> M4 and M5 11/13 — see `VPhoneGuestDevice.known`). Since 2026-10-02 their
> values are read at `fw patch` time from the board's own
> `DeviceTree.<board>.im4p` in the restore tree rather than a table, so an
> M-series board keeps Stage Manager (no `disable-chamois`) and the iPad (A16)
> has no `medusa-overlay-app-capability`: `devicetree-cfw-ipad_artwork`,
> `devicetree-cfw-ipad_product`, `devicetree-cfw-ipad_buttons`,
> `devicetree-cfw-ipad_identity` and (2026-10-02) `devicetree-cfw-ipad_audio`,
> which takes the board's `/product/audio` node. (`/product/haptics`, which no
> iPad tree has, is not one of them: since 2026-10-03
> `devicetree-cfw-product_haptics_node` removes it from every guest's tree,
> iPhone and iPad alike — see "Why the haptics node goes" below.) They are
> written to a second device tree,
> `Firmware/all_flash/DeviceTree.vphone600ap.guest.im4p`, which `fw prepare`
> copies from the vphone600 one and the hybrid manifest names as `DeviceTree`;
> `RestoreDeviceTree` keeps pointing at the original, so restore still boots
> the `iPhone99,11` identity `restored_external` checks. On that copy the
> iPhone-shaped base properties (`artwork_device_subtype`,
> `island_notch_location`, camera offsets) and the `-exp-` identity rewrites
> are not applied; the iPad edits set the root `model` / `target-type` /
> `target-sub-type` / `compatible` to iPad16,1 / J410 / J410AP /
> `J410AP, VPHONE600AP, AppleVirtualPlatformARM`, `/product`
> `artwork-device-idiom` to `pad` (subtype 2266, scale 2), fill the `syscfg`
> placeholders J410AP carries with its values, add the iPad multitasking
> capabilities, and remove the phone-only placeholders and the ringer switch.
> GPU, framebuffer and boot properties stay vphone600's. `cfw install` skips
> `preboot-exp-devicetree_identity` on an iPad guest. Values were copied from
> `DeviceTree.j410ap.im4p` in `iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw`.
>
> A fifth, `llb-cfw-display_scale`, fixes the screen scale. UIScreen's scale is
> MobileGestalt's `main-screen-scale`, and libMobileGestalt — the only reader
> of the property in the 26.6.2 userland — takes it from
> `IODeviceTree:/chosen/display-scale`. LLB (single-stage boot) writes that
> property as `((v_depth >> 16) & 0xff) + 1` from the boot video word, which
> the paravirtual display always reports as 3x, whatever the panel's size or
> the `pixelsPerInch` VZ is given (264 and 326 were tried). At 3x the iPad
> mini's 1488x2266 panel is 496x755 points and iPadOS lays its home screen
> out over itself. The patch, anchored on the ADRP+ADD of the `display-scale`
> literal and the following `ubfx wN, wM, #16, #8 ; add wN, wN, #1 ;
> str wN, [x0]`, replaces the `add` with `mov wN, #<artwork scale>`
> (`ARM64Encoder.encodeMovzW`). Found at `LLB.vresearch101.RELEASE` 0xB9CC in
> cloudOS 26.4 (23E5207q). Editing the MobileGestalt cache's cached screen
> struct (`oBbtJ8x+s1q0OkaiocPuog`, `{1488, 2266, 326, 3.0f}`) does not change
> the live scale. Emitted only for an iPad guest.
>
> See `Documents/Guides/ipados.md`.
>
> **Other iPhone models (2026-10-05, issue #576):** the four
> `devicetree-cfw-ipad_*` presentation patches and `devicetree-cfw-ipad_audio`
> now apply to every guest device except the iPhone17,3
> (`VPhoneGuestDevice.presentsBoard`): the iPhone 16 Plus, 16 Pro, 16 Pro Max
> and 16e (iPhone17,4/1/2/5) and the iPhone 17, Air, 17 Pro, 17 Pro Max and 17e
> (iPhone18,3/4/1/2/5). No patch is new and the IDs keep their `ipad_` names,
> which presets list. Such a guest gets the separate installed tree, the board's
> identity, `/product` and audio node, and skips
> `preboot-exp-devicetree_identity`, as an iPad does. The phone properties
> (`island-notch-location`, `ui-reachability`, `oled-display`, volume-button
> geometry, `watch-companion`, `carplay-2`) take the board's values instead of
> being removed. `llb-cfw-display_scale` is emitted only when the guest's scale
> is not 3x, so it stays iPad-only. Checked on iPhone18,1 (V53AP) 26.6.2
> (23G90) with cloudOS 26.4 (23E5207q): installed tree `model` iPhone18,1,
> artwork subtype 2622 at 3x, `/product/audio` acoustic ID 8021 from the board;
> the guest booted to the home screen at 402x874 points. See
> `Documents/Guides/iphone-models.md`.
>
> **Only the camera remains of EXP by default (2026-09-28).** `standard` is now the
> JB baseline plus the virtual camera. Off by default, besides the concealment
> below: `watchdogd.hv_vmm_cache` (moved into
> `FirmwarePatchSetCatalog.hypervisorConcealmentPatches`, and no longer
> `bootEssential` — watchdogd only panics once the OID is renamed), the eight
> DeviceTree identity rewrites (`devicetree.target_sub_type`,
> `compatible_secondary`, `product.fdr_product_type`, `product.sub_product_type`,
> `product.unique_model`, `product.gestalt_variants_rename`,
> `arm_io.device_type`, `arm_io.soc_generation`), and the post-restore Preboot
> DeviceTree rewrite, now declared as `preboot_devicetree.identity`
> (`.prebootDeviceTree`, Guest Identity set). Until now that rewrite was undeclared
> and `cfw install` ran it on every VM; it now asks the plan first, and a VM with
> no plan still gets it. The last two groups are
> `FirmwarePatchSetCatalog.experimentalIdentityPatches`. Still on: the four board
> presentation properties, camera offsets, the camera / FaceTime / audio / IOPM /
> SMC / ISP nodes, and `camera_dsc`. Camera support reads `/product/camera`
> through MobileGestalt and does not depend on the identity rewrites. Issue #438
> (no location with EXP) is the reason. The `libvlocation.dylib` app hook that
> worked around it is removed, and `location.*` is back on IcliKit's locationd
> simulation with read-back. The Preboot DeviceTree comes from restore, so a VM
> restored with the identity on keeps it until it is restored again.
>
> **`hv_vmm_present` concealment is opt-in as of 2026-09-28, and it is not a
> preference.** `kernelcache_exp.hv_vmm` (the kernel OID rename plus the
> kernel-internal cstring mangle) and `hv_vmm_dsc` (the shared-cache mangle the JB
> system installer runs) were made default-on by commit 228326d; on a freshly
> restored 26.4 guest they are a brick. `bluetoothd` on 23E246 caches its
> `sysctlbyname("kern.hv_vmm_present")` answer in a `dispatch_once`, gets ENOENT and
> caches 0, and its chip-selection singleton then picks a transport from
> `MGIsDeviceOneOfType` — nothing matches a virtual iPhone, the singleton stays
> NULL, and it faults and crash-loops until launchd throttles it. `locationd` blocks
> on a synchronous call to the throttled Bluetooth XPC service, the
> `com.apple.locationd.migrator` datamigrator plugin hangs, and SpringBoard waits on
> migration: black screen, no panic. The addresses and the full chain are in
> `Research/Patches/hv_vmm_present_usermode_xrefs.md` (B.3 correction).
>
> Neither half is useful alone — the rename without the cache mangle breaks the
> graphics and ML paths, the mangle without the rename does nothing — so they are
> declared as a pair, `FirmwarePatchSetCatalog.hypervisorConcealmentPatches`, and a
> catalogue test refuses a shipped preset that enables one without the other. Both
> lost `bootEssential`, which they never were: a shipped preset that drops a
> boot-essential patch warns on every run. (The other former EXP patches stayed on
> in this first change; the note above turns everything but the camera off.) A VM
> records only the boxes its owner changed, in
> `<vm>/PatchSelection.plist`, and `fw patch` writes what it resolved to
> `<vm>/PatchPlan.plist` for `cfw install` to reuse.
>
> **Patch sets also load from outside the bundle.** A `.vphonepatchset` is a macOS
> loadable bundle whose `Contents/Resources/Manifest.plist` is read before any of
> its code is mapped, and whose executable exports one symbol,
> `vphone_patch_set_principal`, returning a `VPhonePatchSetPrincipal` that hands the
> pipeline one `BufferedPatcher` per component the plan enabled. Not
> `NSPrincipalClass`: PatchKit is built for library evolution, so a subclass of a
> PatchKit class is registered with the ObjC runtime only when its metadata is first
> realized, and `Bundle.principalClass` therefore resolves to the wrong class
> entirely. `VPhoneExecutable/VPhoneCommand/VPhonePatchSetExample` is the template
> and is what the loader tests load.
>
> An external set can patch the boot chain only, and reaches a run through a preset
> in `~/.vphone/patches_presets/` naming it by identifier *and* path — the manifest
> at that path has to declare that identifier. `vphone-cli patchset import` copies a
> set into `~/.vphone/patchsets` and ad hoc signs it, which is what makes a bundle
> straight out of Xcode loadable at all: the linker signs the Mach-O but seals no
> resources, so `codesign --verify` rejects it until one `codesign --force --sign -`
> pass over the bundle fixes it. The signature is re-verified from disk at every
> load. Root `cfw install` loads no external set, so nothing here is on a privileged
> path.
>
> **Version gates replaced three flags.** The patches `--frida`,
> `--force-exc-guard` and `--force-dsc-maxslide` controlled now carry a structured
> `VPhonePatchApplicability`: `kernel-boot-thread_guard_violation` is pinned to
> `iOSBase: .major(18)` (whose runningboardd trips a flavor-10 Mach port guard and
> crash-loops the UI), `dyld-boot-maxslide` to `.major(27)`, and the two
> `kernel-exp-frida_*` patches to `cloudOS: .atLeast(26, 4)`. A preset can turn a
> patch off, and a VM can turn one on that its preset leaves off, but neither can
> widen a version gate — so forcing the guard or the slide onto a 26.x base is no
> longer possible. That capability was opt-in for third-party RASP SDKs and was
> never required to boot.
>
> Two of the three flags are gone from the surface as well: `--force-exc-guard` no
> longer exists, and `--frida` survives only on the `patch-component` developer
> subcommand, not on `vm create` or `fw patch`. `--force-dsc-maxslide` is gone too
> (2026-09-30): it was removed from `vm create`, `restore`, `cfw install`,
> `VPhoneVirtualMachineCreateOptions`, the Launchpad new-machine sheet, the
> Launchpad control verbs and the helper's `installCustomFirmware` XPC signature.
> On a 27 base it never reached the patcher at all: the installer passed `--force`
> only in a branch below the `27.` and `26.0`/`18.` cases, which the plan had
> already closed. A helper built before this change has a different hash and shows
> as outdated, so Launchpad reinstalls it before it is called with the new signature.
>
> The `iosBaseIs18` / `iosBaseIs27` booleans are gone from the pipeline too: it now
> carries a parsed `VPhoneVersion` (major, minor, patch). Two things still branch
> on the release rather than on a selection, because they change *which shapes a
> patch looks for* rather than whether it runs: the 18.x skywalk-netagent
> boot-arg, and `KernelJailbreakPatcher.applyIOS27`.
>
> **Byte-identity check (2026-09-28):** the golden corpus was re-run over cloudOS
> 26.4 with iOS 26.1, 26.4 and 27.0 bases. `--preset standard` reproduced the
> pre-patch-set output for all three, digest for digest, and `--preset extended`
> reproduced the old `--frida` case exactly. No run emitted the
> `declared by no patch set` warning, so every record the boot chain emits is
> covered by a declaration. The one case that no longer exists is
> `--force-exc-guard` on a 26.1 base, for the reason above.

> **Current product scope (September 2026):** the tables below preserve the
> historical patch comparison. The public runtime now exposes only JB. Guest
> package managers, Procursus, and first-boot package setup are outside this
> repository. The native Swift JB install retains the base system patches,
> launchd jetsam guard, debugserver entitlement edit, iOS 27 Campo entitlement
> edit, GPU driver, mandatory vphoned, and the small vphone launchd hook described
> below. The JB firmware pipeline also runs the former EXP DeviceTree
> identity/camera patches. The JB system installer runs the former EXP DSC camera
> patch, watchdogd patch, and post-restore Preboot DeviceTree rewrite. The former
> EXP kernel OID rename and its DSC half are the exception: declared, but off in
> `standard` since 2026-09-28 for the reason in the note above. `SPOOF_BUILD` remains opt-in and updates the
> rootfs and installed SystemOS SystemVersion.plist copies, plus the Preboot
> Cryptex copy when present. These are install-time integrations;
> successful patch dry-runs do not establish guest boot or Camera.app behavior.
> Old variant rows are research history,
> not available install modes.

> **Integration check (2026-09-25):** A clean `/tmp` restore tree assembled
> from cloudOS 26.4 (23E5207q) and iPhone17,3 iOS 27.0 (24A435) completed
> the public `fw patch` command with 191 records: 7 former EXP kernel records
> and 23 DeviceTree records. The unchanged BuildManifest retained its input
> SHA-256. Against the existing iOS 27 VM's read-only system image,
> `patch-hv-vmm-dsc --dry-run` found 29 writable cstrings and 15 blacklist
> entries; `patch-camera-dsc --dry-run` found six methods. A copy of that
> VM's watchdogd was patched, passed `codesign -v`, and was unchanged on a
> second run. The Preboot DT rewrite succeeded on a copy and was likewise
> unchanged on a second run. The original VM disk was not modified or booted.

> **Camera hooks and environment update (2026-09-25; not yet verified in a
> guest):** `cfw install` also places `libvcamcaptured.dylib` and
> `libcamfix.dylib` in `/usr/lib`. SystemHook treats
> `/usr/libexec/cameracaptured` as an injection target and loads
> `/usr/lib/libvcamcaptured.dylib` there, and loads `/usr/lib/libcamfix.dylib`
> into app processes that already have AVFoundation loaded. Neither needs
> ElleKit or a bootstrap: both hooks install their own Objective-C method
> replacements. A missing library is skipped silently; other load failures are
> logged to `vphone-systemhook.log`. A running guest receives changed copies of
> all four `/usr/lib` libraries through the vphoned environment update
> (`Research/vphoned_http_api.md`). Validation: `processes.list` shows
> `cameracaptured`, `vphone-systemhook.log` records `camera-hook=... result=loaded`
> for its PID, and `vcamcaptured.log` shows the hook installing its source.

> **Camera hook: front lookups and data-output frames (2026-10-10):** no new
> patch and no new library; `libcamfix.dylib` changes behaviour only. It
> answers front-camera lookups with the single vcam device and delivers
> data-output frames at the session preset's size, orientation and pixel
> format with device exposure values. Details and validation:
> [`Guest/virtual_camera_transport.md`](Guest/virtual_camera_transport.md#front-camera-clients-and-data-output-frames-2026-10-10).

> **3D gyroscope core (2026-10-08; guest acceptance pending):**
> `system-backboardd-cfw-gyroscope`, declared in the Guest System set and
> selected by both presets on iOS 18+, installs `/usr/lib/libvphonegyro.dylib`.
> SystemHook loads it into backboardd through the same no-bootstrap daemon
> route as the camera hook. It publishes a virtual HID gyro (page `0xff00`,
> usage `9`); vphoned's `motion.gyroscope.set/get/clear` sends an atomic
> three-axis rad/s configuration through mobile's backboardd preferences and
> a Darwin notification. There is no system executable, kernel or DSC byte
> change. Disabling the patch removes the added library; live environment
> sync cannot reinstall an absent selected library. A provider/library update
> needs a reboot, without silently restarting backboardd. The VM display app's
> Features → Motion Sensors → 3D Gyroscope panel sends valid three-axis edits immediately,
> with a simulation checkbox that retains values and a reset that zeros all
> axes. `motion.gyroscope.set` accepts an optional Boolean `enabled` (default
> true); the panel checks `motion_gyroscope_toggle` support. Writes serialize
> and coalesce, preserve the latest values across old acknowledgements, and
> retry pending state after reconnect. HID enumeration
> and dispatch are observable separately from CoreMotion app acceptance; the
> platform capability gate and optional IMU match still require guest proof.
> Reveal evidence and manual acceptance: `Research/Guest/virtual_gyroscope.md`.

> **Device attitude (2026-10-08; guest acceptance pending):**
> `system-apps-cfw-attitude` in Guest System is selected by both presets on
> iOS 18+. It adds `/usr/lib/libvphoneattitude.dylib`, loaded by SystemHook
> into apps, with no system executable, kernel or DSC byte change. Public
> CMMotionManager methods supply a stationary XArbitraryZVertical pose through
> polling/callbacks. vphoned persists degrees and publishes one packed Darwin
> notify state; apps receive radians, quaternion, matrix and matching gravity.
> Disabling restores the native path; removing the library and relaunching apps
> reverts injection. Live sync cannot reinstall an absent selected library.
> Features → Motion Sensors → Device Attitude provides live angle editing,
> a simulation checkbox and zero reset. Native host subscription tests and
> guest cross-compilation passed; manual guest acceptance remains.
> Contract and validation: `Research/Guest/virtual_attitude.md`.

> **Device attitude respring fix (2026-10-09; guest acceptance pending):**
> Two iOS 27.0.1 SpringBoard reports (19:41:21 and 19:42:51) show a
> Core Motion thread `SIGSEGV` at `0x10`, while the main thread calls native
> stop through `VPhoneAttitudeSession` during UIKit motion-effect subscription.
> The app-path loader had admitted SpringBoard; a fresh simulated session also
> stopped native updates without a preceding native start. SystemHook and the
> attitude dylib now exclude `/System/Library/` services and SpringBoard copies;
> native stop runs only for a previously forwarded native subscription.
> `system-apps-cfw-attitude` keeps its identifier, selection and iOS 18+ gate;
> no kernel, DSC or system executable patch is added. The new sensorless
> lifecycle regression fails before the stop guard and passes after it;
> sample, real host hook and injection-scope tests also pass. All 51 catalogue/
> model tests in six suites passed, and the full VPhone Debug bundle built,
> passed admission and strict deep signature verification. Updating the
> guest environment and rebooting is required for deployment verification.

> **Current launchd hook (2026-09-25; isolated VM verification):**
> `cfw install` now places `launchdhook-vphone.dylib` and a diagnostic
> `SystemHook-vphone.dylib` in `/usr/lib`, links `/vh` to the launchd hook,
> inserts a weak `/vh` load command for the
> launchd hook after `patch-launchd-jetsam`, and re-signs launchd. Until
> 2026-09-29 the hook also extended launchd's `Paths` and `LaunchDaemons`
> cache values with the bootstrap's `Library/LaunchDaemons`, under distinct
> `/System/Library/LaunchDaemons/vphone.*.plist` keys (the tested iOS 26.6.2
> cache loader ignored `/var/jb/...` and `/Library/...` keys). Those jobs did
> not match the plist path a package script boots out, so the hook no longer
> touches `xpc_dictionary_get_value`: vphoned loads the bootstrap's daemons
> after boot, as RootHide's `jbctl startup` does (`Research/roothide_loader_links.md`).
> The old binary in `zqxwce/vphone-cli-storage` at `2ef6b06` uses the real
> `/var/jb` key and `MSHookFunction` to intercept `xpc_dictionary_get_value`;
> it also requires `/cores/systemhook.dylib` and `/cores/libellekit.dylib` at
> startup. The bootstrap root is `/var/jb` or the one RootHide root vphoned
> installs, `.jbroot-000114514191980C`; spawns look for it until it appears.
> The hook also tries to remove PID 1's existing
> jetsam limit and suppresses future fatal task-limit assignments for PID 1.
> The launchd hook interposes PID 1's `posix_spawn` without loading ElleKit,
> so process injection remains available before a package manager installs it. It adds
> `DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib` to `xpcproxy`,
> directly spawned bootstrap programs, and app executables under the system
> or application bundle paths. `SystemHook-vphone.dylib` interposes
> `posix_spawnp` inside `xpcproxy` to carry that environment into the final
> executable. Both stages preserve an existing `DYLD_INSERT_LIBRARIES`, avoid
> duplicate insertion, and honor `DISABLE_TWEAKS`, `_SafeMode`, and
> `_MSSafeMode` in the target environment. PID 1 logs child PID, executable
> path, and spawn status under `/var/mobile/Library/Caches`. SystemHook logs
> there when permitted and falls back to the app's own `Library/Caches` under
> its sandboxed home directory.
> SystemHook now carries the selected physical bootstrap path in
> `VPHONE_JB_ROOT` and loads that root's `usr/lib/TweakLoader.dylib` for App
> and bootstrap executables when it exists. ElleKit owns individual tweak
> selection and loading. `xpcproxy` only propagates the hook; unrelated
> system daemons do not load TweakLoader. Injected App and bootstrap processes
> also propagate to targeted `posix_spawn`, `posix_spawnp`, and `execve` calls.
> RootHide sandbox behavior and real ElleKit tweak loading still require
> runtime validation.
> On the rootless iOS 26.6.2 clone, `xpcproxy` called `posix_spawnp` for the
> package probe, and the final daemon reported
> `DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib` and
> `systemhook_loaded=1`, including after its timed restart. Hooking only PID 1
> reached `xpcproxy` but did not reach the final daemon; the `posix_spawnp`
> bridge closes that observed gap. With `DISABLE_TWEAKS=1` in that same daemon
> plist, the final process instead reported `DYLD_INSERT_LIBRARIES=<absent>`
> and `systemhook_loaded=0`; the bridge logged `decision=disabled`. This
> chain was also tested with a RootHide-shaped `.jbroot-<16 hex>` fixture on the
> cloned VM: launchd imported its plist, translated `/usr/bin/...` to the
> physical randomized root, loaded ElleKit from that root, and the final
> daemon reported `systemhook_loaded=1` both at load and after its timed
> restart. This validates path handling and injection through the randomized
> root, not a complete RootHide bootstrap or a real tweak package.
> Apps use a separate direct launchd spawn path on this iOS 26.6.2 VM. On the
> rootless clone, launchd logged the Calculator app spawn with PID 454 and
> injection enabled; the app's own
> `Library/Caches/vphone-systemhook.log` recorded the same PID and Calculator
> executable path. The app reached the foreground and rendered normally.
> In the subsequent chain-load test, a signed diagnostic `TweakLoader.dylib`
> under the rootless bootstrap ran its constructor in the final daemon and in
> Calculator PID 403. Calculator's sandboxed container recorded the physical
> bootstrap path and a successful `dlopen`; the App stayed frontmost. Three
> separate RunAtLoad daemon probes with `DISABLE_TWEAKS=1`, `_SafeMode=1`, and
> `_MSSafeMode=1` each reported no `DYLD_INSERT_LIBRARIES` and
> `systemhook_loaded=0` after reboot. This diagnostic library proves the
> loading path, not real ElleKit or a tweak package.
> On 2026-09-25, the launchd and SystemHook spawn bridges gained a shared
> RootHide loader-link helper. Before a bootstrap executable is spawned, it
> creates or validates the `.jbroot` link beside that executable, accepting
> `/var` and `/private/var` spellings of the same root. On an isolated clone
> of `vphone-27.0-cloudos-26.4`, Xrash and Irisin App launches each created a
> missing link and reached the foreground. A dynamically loaded LaunchDaemon
> did not traverse the observed interposers; it still needed its link before
> service load. vphoned's initial fixed-directory link seeding remains in place.
> A bootstrap CLI probe then spawned itself with explicit stripped
> environments. Its `posix_spawn`, `posix_spawnp` (absolute program path), and
> `execve` children all reported `systemhook_loaded=1`,
> `VPHONE_JB_ROOT=/private/var/jb`, and the expected DYLD insertion. The first
> attempt exposed an alias gap: a `/var/jb/...` path was not recognized as
> the physical `/private/var/jb/...` root; both forms are now accepted.
> The previous central-log-only probe could not observe sandboxed apps even
> when SystemHook was loaded.
> The cloned `vphone-launchdhook-lab-26.6.2` booted with the weak dylib and
> retained a healthy vphoned API. Rootless and RootHide probes, each tested
> after reboot, were imported and spawned by launchd. The RootHide probe's
> plist named `/usr/bin/vphone-hook-daemon-probe`, which does not exist outside
> its randomized root; successful spawn confirms the in-memory physical-path
> translation. A read-only `MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES` probe
> returned active/inactive `-1/-1` for PID 1 with this hook. With `/vh`
> removed but the existing `patch-launchd-jetsam` left in place, the same
> probe returned `50/50` MB with fatal attributes. These tests used a cloned
> VM disk and separate host API port; the original VM was not modified.
> On 2026-09-25, the new interposed spawn hook was installed on the existing
> `vphone-launchdhook-lab-26.6.2` rootless VM and read back byte-for-byte.
> After a cold boot, launchd imported `wiki.qaq.ighostvtd.plist`; the service
> and its `wiki.qaq.ighostvt.service` Mach endpoint were running. The daemon's
> `DISABLE_TWEAKS=1` kept TweakLoader out of that process. Launchd logged a
> successful Calculator spawn; Calculator reached the foreground and its own
> sandbox log recorded `SystemHook-vphone.dylib` and a successful load of the
> installed ElleKit `TweakLoader.dylib`. This checks the injection chain, but
> does not prove that a particular tweak took effect.

> **`scripts/patchers/*.py` no longer exists.** The tables below cite those
> filenames throughout, because that is where each patch was first written and
> where its on-device validation notes were recorded. Every one is now a Swift
> patcher reached through `vphone-cli cfw <verb>` — read a citation as "the
> patch this became", and recover the Python itself from git history at
> `78cbeea` if you need to run it. The port is documented in the three
> "Swift port status" sections further down.

> **EXP is a JB superset.** Everything in the baseline tables below that is `Y`
> for JB is also `Y` for EXP. The columns are kept at three variants to avoid
> noise — the only place EXP and JB diverge is the **Experimental additions**
> below, all of which are EXP-only (JB and the other variants are deliberately
> unaffected). The EXP-only items, taken together:
>
> - **Kernel** — `KernelEXPPatcher` runs the `hv_vmm_present` sysctl OID rename
>   plus kernel-internal caller cstring/sandbox-profile-token mangle (formerly
>   wired into JB Group B as JB-26 — moved out).
> - **DeviceTree at fw_patch time** — 8 identity-rewrite property patches
>   (Tier 1b + 1c) flipping userland-visible identity surfaces toward
>   D47AP / iPhone17,3.
> - **DSC user-mode** — byte-5 cstring mangle of `kern.hv_vmm_present` with a
>   sign-in blacklist + per-page slot re-attestation (`cfw_patch_hv_vmm_dsc.py`),
>   companion to the kernel rename.
> - **watchdogd (EXP-JB-3.5)** — surgical 2-instruction patch + slot re-attest;
>   forces the cached "am I a VM?" byte to `1` so watchdogd's clean-exit branch
>   runs.
> - **Post-restore DT rewrite (EXP-JB-6)** — host-side rewrite of `devicetree.img4`
>   on the ramdisk's mounted rootfs for the three restore-fatal identity
>   properties (root `model`, `target-type`, `compatible[0]`) that broke
>   restore when applied at fw_patch time.
> - **SystemVersion.plist `ProductBuildVersion` (EXP-JB-7, opt-in)** — gated on
>   `SPOOF_BUILD=<id>`. Rewrites the build identifier in the rootfs and
>   cryptex copies of `SystemVersion.plist`.
> - **Camera.app accessibility** — at fw_patch time: the `/product/camera`
>   node, two `/product` cam-offset rewrites (Tier B), three new
>   `/product` child nodes `facetime` / `audio` / `iopm` (Tier C), and
>   five minimal `/arm-io` stubs `isp` / `ispRtb` /
>   `smc/iop-smc-nub/smc-ext-charger` carrying camera-front, camera-rear
>   and camera-driver (Tier F). At install time: the 5
>   `+[_NUStyleTransfer*Processor processWithInputs:...]` DSC
>   short-circuits in NeutrinoCore plus a 1-instruction
>   `+[AVCaptureDevice authorizationStatusForMediaType:]` rewrite in
>   AVFCapture that returns `Authorized` for any media type
>   (Stage 0 of the vcam stack — auth gate only; downstream
>   cameracaptured/vcamd plumbing for actual frame delivery is open
>   work). Together these make Camera.app's icon show on the home
>   screen and in Spotlight, the viewfinder render, and arbitrary apps
>   stop bailing on the camera permission check. The NeutrinoCore patch
>   stops the viewfinder's CIImageProcessorKernel chain from asserting
>   on a nil descriptor when ANE detection comes back NO on the VM.

## Boot Chain Patches

### AVPBooter

| #   | Patch        | Purpose                          | Regular | Dev | JB  |
| --- | ------------ | -------------------------------- | :-----: | :-: | :-: |
| 1   | `mov x0, #0` | DGST signature validation bypass |    Y    |  Y  |  Y  |

### iBSS

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBSS" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass (`b.ne` -> NOP, `mov x0,x22` -> `mov x0,#0`)                                                      |    Y    |  Y  |  Y  |
| 3   | Skip `generate_nonce`               | Keep apnonce stable for SHSH (`tbz` -> unconditional `b`)                                                          |    -    |  -  |  Y  |

### iBEC

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBEC" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
| 4   | Modern bootx-handoff panic bypass   | `IBootPatcher.patchBootxPrecondition` NOPs gate TBZ via structural anchor (no hash/line tied); no-op pre-26.4      |    Y    |  Y  |  Y  |
| 5   | Ramdisk boot-args overwrite         | `ramdisk_build.py:patch_ibec_bootargs` rewrites string to `... rd=md0 ... wdt=-1 ...` (ramdisk-send iBEC only)     |    Y    |  Y  |  Y  |

### LLB

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded LLB" in serial log                                                                                         |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
| 4   | Rootfs bypass (5 patches)           | Allow edited rootfs loading                                                                                        |    Y    |  Y  |  Y  |
| 5   | Panic bypass                        | NOP `cbnz` after `mov w8,#0x328` check                                                                             |    Y    |  Y  |  Y  |

### TXM

| #   | Patch                                             | Purpose                                   | Regular | Dev | JB  |
| --- | ------------------------------------------------- | ----------------------------------------- | :-----: | :-: | :-: |
| 1   | Trustcache binary-search bypass                   | `bl hash_cmp` -> `mov x0, #0`             |    Y    |  Y  |  Y  |
| 2   | Selector24 bypass: `mov w0, #0xa1`                | Return PASS (byte 1 = 0) after prologue   |    -    |  Y  |  Y  |
| 3   | Selector24 bypass: `b <epilogue>`                 | Skip validation, jump to register restore |    -    |  Y  |  Y  |
| 4   | get-task-allow (selector 41\|29)                  | `bl` -> `mov x0, #1`                      |    -    |  Y  |  Y  |
| 5   | Selector42\|29 shellcode: branch to cave          | Redirect dispatch stub to shellcode       |    -    |  Y  |  Y  |
| 6   | Selector42\|29 shellcode: NOP pad                 | UDF -> NOP in code cave                   |    -    |  Y  |  Y  |
| 7   | Selector42\|29 shellcode: `mov x0, #1`            | Set return value to true                  |    -    |  Y  |  Y  |
| 8   | Selector42\|29 shellcode: `strb w0, [x20, #0x30]` | Set manifest flag                         |    -    |  Y  |  Y  |
| 9   | Selector42\|29 shellcode: `mov x0, x20`           | Restore context pointer                   |    -    |  Y  |  Y  |
| 10  | Selector42\|29 shellcode: branch back             | Return from shellcode to stub+4           |    -    |  Y  |  Y  |
| 11  | Debugger entitlement (selector 42\|37)            | `bl` -> `mov w0, #1`                      |    -    |  Y  |  Y  |
| 12  | Developer mode bypass                             | NOP conditional guard before deny path    |    -    |  Y  |  Y  |
| 13  | Pre-check admission: `mov w8, #0xa`               | Tolerated validation-type byte (iOS 27+)  |    -    |  Y  |  Y  |
| 14  | Pre-check admission: `strb w8, [x19]`             | Write the type byte to the out param      |    -    |  Y  |  Y  |
| 15  | Pre-check admission: `mov w0, #0x90`              | The policy walk's PASS status             |    -    |  Y  |  Y  |
| 16  | Pre-check admission: `b <epilogue>`               | Skip the policy callback walk             |    -    |  Y  |  Y  |

> **Pre-check admission (2026-10-04):** rows 13–16 (`txm-boot-precheck_admission`,
> iOS 27+ only) force the selector-24 pre-check policy walk in TXM 187.100.3
> (cloudOS 26.4) to its PASS exit. On an iOS 27.0.1 iPhone guest that walk
> rejects every manifest — Apple's own launchd included, re-signed or pristine —
> because the trust state it consults never loads from a 27.0.1 restore; the
> selector-24 caller then exhausts its ad-hoc / CMS / third fallback ladder and
> kills init (`0x32202`, previously misread as `0x12491`). The anchor is the
> walk's unique `mov x17, #0x7e51 ; blraa x8, x17` policy-callback invocation
> combined with its post-indexed `ldr x22, [x20], #0x40` table walk; on
> 187.100.3 that pair resolves to exactly one function. Full analysis and the
> experiment trail: `Research/Firmware/txm_selector24_cms_gate.md`.

## Kernelcache

### Base Patches (All Variants)

| #     | Patch                      | Function                         | Purpose                                            | Regular | Dev | JB  |
| ----- | -------------------------- | -------------------------------- | -------------------------------------------------- | :-----: | :-: | :-: |
| 1     | NOP `tbnz w8,#5`           | `_apfs_vfsop_mount`              | Skip root snapshot sealed-volume check             |    Y    |  Y  |  Y  |
| 2     | NOP conditional            | `_authapfs_seal_is_broken`       | Skip root volume seal panic                        |    Y    |  Y  |  Y  |
| 3     | NOP conditional            | `_bsd_init`                      | Skip rootvp not-authenticated panic                |    Y    |  Y  |  Y  |
| 4-5   | `mov w0,#0; ret`           | `_proc_check_launch_constraints` | Bypass launch constraints                          |    Y    |  Y  |  Y  |
| 6-7   | `mov x0,#1` (2x)           | `PE_i_can_has_debugger`          | Enable kernel debugger                             |    Y    |  Y  |  Y  |
| 8     | NOP                        | `_postValidation`                | Skip AMFI post-validation                          |    Y    |  Y  |  Y  |
| 9     | `cmp w0,w0`                | `_postValidation`                | Force comparison true                              |    Y    |  Y  |  Y  |
| 10-11 | `mov w0,#1` (2x)           | `_check_dyld_policy_internal`    | Allow dyld loading                                 |    Y    |  Y  |  Y  |
| 12    | `mov w0,#0`                | `_apfs_graft`                    | Allow APFS graft                                   |    Y    |  Y  |  Y  |
| 13    | `cmp x0,x0`                | `_apfs_vfsop_mount`              | Skip mount check                                   |    Y    |  Y  |  Y  |
| 14    | `mov w0,#0`                | `_apfs_mount_upgrade_checks`     | Allow mount upgrade                                |    Y    |  Y  |  Y  |
| 15    | `mov w0,#0`                | `_handle_fsioc_graft`            | Allow fsioc graft                                  |    Y    |  Y  |  Y  |
| 16    | NOP (3x)                   | `handle_get_dev_by_role`         | Bypass APFS role-lookup deny gates for boot mounts |    Y    |  Y  |  Y  |
| 17-26 | `mov x0,#0; ret` (5 hooks) | Sandbox MACF ops table           | Stub 5 sandbox hooks                               |    Y    |  Y  |  Y  |
| 27    | `PACIBSP→RET`              | `_thread_guard_violation`        | Disable fatal EXC_GUARD (Mach port guard) delivery. Dev variant + iOS 18 bases always. The old `--force-exc-guard` opt-in for other bases is gone; `kernel-boot-thread_guard_violation` is pinned to `iOSBase: .major(18)` (see note below). | Y* | Y | Y* |

† Always required on iOS 18 bases (18.6.2's runningboardd/SpringBoard trip `GUARD_TYPE_MACH_PORT` "flavor 10", crash-looping the UI — the VM won't boot without it there). On other bases this is opt-in, not always-on: some third-party apps shipping crash-reporting/RASP SDKs (Bugly, Crashlytics, KSCrash, ...) call `task_swap_exception_ports()`, which the research kernel can enforce as a fatal `GUARD_TYPE_MACH_PORT`/`KOBJECT_REPLY_PORT_SEMANTICS` violation (see [upstream issue #291](https://github.com/Lakr233/vphone-cli/issues/291), reproduced and confirmed via crash logs against a `kernelcache.research.vphone600 (26.1/23B85)` build) — but it's not required for the VM itself to boot on 26.x, so it stays opt-in rather than always-on for regular/jb/exp. `applyExcGuard` in `FirmwarePipeline`/`KernelPatcher` is `iosBaseIs18 || forceExcGuard`; pass `--force-exc-guard` to `patch-firmware` (or `FORCE_EXC_GUARD=1` to the relevant `make fw_patch*` target) to enable it on a base that needs it. `iosBaseIs18` (from `iPhone-BuildManifest.plist`'s `ProductVersion`) also still gates the unrelated 18.x skywalk-netagent boot-arg workaround. **Superseded:** the `--force-exc-guard` / `FORCE_EXC_GUARD=1` opt-in and the `iosBaseIs18` boolean no longer exist. The patch is declared with `iOSBase: .major(18)`, and no preset or VM selection can widen that gate, so it cannot be applied on 26.x.

### JB-Only Kernel Methods (Reference List)

> **⚠ iOS-27 hard-gate (2026-07-20).** Every patch below whose Purpose cites "iOS 27" / "27.0 on the 26.4 kernel" is **hard-gated to a 27.x base** via `KernelJBPatcher.applyIOS27` — set by `FirmwarePipeline` from the iPhone base `ProductVersion` (mirroring the `applyExcGuard`/iOS-18 mechanism at patch 27 above; standalone `patch-component` defaults it true, override with `--target-os`). Gated set: **JB-02b, JB-02d, JB-09 (the `ops[124]` add, plus on 27 the `ops[267]` removal — handed to JB-29; the other 201..316 hooks stay), JB-10b, JB-26, JB-27, JB-28, JB-29**. On an 18.x/26.x base **none** of them run. This supersedes the per-row "No-op-in-effect for version-matched userlands" notes: those describe the effect *if applied*, but **JB-27 is NOT a no-op on 26.x** — its `cmp 0x588→0x6e0` retarget makes the 26.x userclient reject its own native 0x588 SwapEnd → dead display (the 26.5 regression that motivated the hard-gate). **Verified 2026-07-20 (JB-29 addendum 2026-07-23):** a 26.5 base produces a **byte-identical** kernelcache to pre-branch `main` (`patch-component --component kernel-jb --target-os 26.5` vs main's output — `cmp` clean, 83 records each; re-confirmed unchanged after JB-29 by `sha256`, since `ops[267]` stays blanket-neutered on 26.5), and a 27.0 base emits **95** records on the `c0ecdb4b` deployment kernel: the 11 gated records above **plus JB-29's 2** (`jb.fpfs_scoped_open.{ops_retarget,cave}`), with `sandbox_ext_267` suppressed (JB-29 owns `ops[267]` on 27 → the FileProvider-scoped trampoline instead of the blanket allow-stub).

> **Frida Stalker support is opt-in (`--frida`).** JB-23b and JB-25c run only when firmware patching is invoked with `--frida` (`vphone-cli vm create … --frida`, `vphone-cli fw patch <vm> -V jb --frida`, `patch-firmware … --frida`, `patch-component --component kernel-jb --frida`, or `make fw_patch_jb FRIDA=1`), gated by `KernelJBPatcher.applyFrida` (set by `FirmwarePipeline` from `enableFrida`). Baseline JB/EXP output is **byte-identical** when off (26.4 emits 83 records without `--frida`, 87 with — the 4 being JB-23b's 2 thread_set_state setters and JB-25c's 2 vm_map_delete gates). Frida itself is installed through the existing extra-debs mechanism: on a `--frida` create the orchestrator sets `VPHONE_FRIDA=1`, `fetch_debs.sh` resolves the latest `frida_<ver>_iphoneos-arm64.deb` (== `re.frida.server`: no `Depends`, rootless `/var/jb` layout) from the Frida GitHub releases into the debs cache, `cfw_install_{jb,exp}.sh` stage it, and the first-boot "5b/8 INSTALL EXTRA DEBS" step `dpkg -i`'s it — no APT source, marker, or dependency resolution.

| #     | Group | Method                                | Function                                                                                             | Purpose                                                                                                                                                                              | JB Enabled |
| ----- | ----- | ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :--------: |
| JB-01 | A     | `patch_amfi_cdhash_in_trustcache`     | `AMFIIsCDHashInTrustCache`                                                                           | Always return true + store hash                                                                                                                                                      |     Y      |
| JB-02 | A     | `patch_amfi_execve_kill_path`         | AMFI execve kill return site                                                                         | Convert shared kill return from deny to allow (superseded by C21; standalone only)                                                                                                   |     N      |
| JB-02b| C     | `patch_exec_security_policy_kill`     | XNU exec `imgp->ip_mac_return` gate (kern_exec, `os_reason_create(OS_REASON_EXEC, EXEC_EXIT_REASON_SECURITY_POLICY)` site) | Flip `cbz wN, <skip>` → unconditional `b <skip>` so the exec-time MAC-verdict `SECURITY_POLICY` kill is unreachable. **Needed to run a userland NEWER than the kernel (iOS 27.0 on the 26.4 kernel):** AMFI's exec hooks reject the newer binaries' code-sign validation category, setting `ip_mac_return != 0` → core daemons (backboardd/cfprefsd/containermanagerd/…) die at exec (`namespace 9 / code 0x8`) → boot deadlock. Validated on 27.0/26.4: 0 SECURITY_POLICY kills, daemons launch, networking + SSH come up. No-op-in-effect for version-matched userlands (ip_mac_return == 0 there, so the original cbz already skips). |     Y      |
| JB-02d| C     | `patch_container_manager_upcall`      | sandbox `_hook_cred_label_update_execve` container-manager upcall guard: the `cbz w0,<success>` after `bl <container_manager_get_process_containers>`, on the `"failed to upcall to containermanagerd for a platform app"` fall-through | Flip `cbz w0,<success>` → unconditional `b <success>` so a FAILED exec-time container-manager upcall takes the success path instead of autobox/kill. **Needed to run iOS 27.0 on the 26.4 kernel:** iOS 27 DELETED the kernel-side containermanagerd upcall — the stock 27 kernel has no `HOST_CONTAINERD_PORT` / `CM_KERN_*` protocol (container resolution moved out of the kernel), so 27's containermanagerd no longer implements the reply server. On the 26.4 kernel the exec upcall therefore fails (`MACH_SEND_INVALID_DEST`) for every 27 platform app → they are autoboxed into the restrictive `temporary-sandbox` profile, which denies e.g. `mach-lookup com.apple.backboard.display.services` → Campo (the wallpaper renderer) crash-loops (no wallpaper) + intelligencetasksd/feedbackd. Re-registering the container-manager host special port is NOT viable: the 26.4 kernel then SENDS the synchronous `CM_KERN` MIG request and BLOCKS for a reply 27 cannot produce → early-boot deadlock (verified: boot hangs, never reaches SpringBoard). Anchor is structural (string xref to `"failed to upcall to containermanagerd"` → the `cbz w0` immediately preceding the string-load `adrp`, itself immediately preceded by the upcall `bl`; backward branch to the success continuation; unique). Replacement `b` from the Keystone-backed `ARM64Encoder`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 wallpaper renders, Campo/SpringBoard/backboardd stable, boot clean (no freeze, no panic).** No-op-in-effect for version-matched userlands (there the upcall succeeds → the original cbz already branches to `<success>`). |     Y      |
| JB-03 | C     | `patch_cred_label_update_execve`      | `_cred_label_update_execve`                                                                          | Reworked C21-v3: C21-v1 already boots; v3 keeps split late exits and additionally ORs success-only helper bits `0xC` after clearing `0x3F00`; still disabled pending boot validation |     N      |
| JB-04 | C     | `patch_hook_cred_label_update_execve` | sandbox `mpo_cred_label_update_execve` wrapper (`ops[18]` -> `sub_FFFFFE00093BDB64`)                 | Faithful upstream C23 trampoline: copy `VSUID`/`VSGID` owner state into pending cred, set `P_SUGID`, then branch back to wrapper                                                     |     Y      |
| JB-05 | C     | `patch_kcall10`                       | `sysent[439]` (`SYS_kas_info` replacement)                                                           | Rebuilt ABI-correct kcall cave: `target + 7 args -> uint64 x0`; re-enabled after focused dry-run validation                                                                          |     Y      |
| JB-06 | B     | `patch_post_validation_additional`    | `_postValidation` (additional)                                                                       | Disable SHA256-only hash-type reject. **FIX (2026-09-22):** logged `[-] expected 1 postValidation compare site, found 0` on every run, which `make test_fw_patches` is built to fail on. Cause: this patch and base-layer item 9 (`KernelPatchPostValidation`) reveal the *same* site the *same* way — same `"AMFI: code signature validation failed"` string anchor, same caller walk, same `cmp w0,#imm ; b.ne` preceded by a BL (item 9 searches a 2-instruction BL window, this one a wider 3) — and both rewrite it to `cmp w0,w0`. Item 9 runs first and takes the site (observed at file offset `0xDE8360`, `cmp w0,#2` → `cmp w0,w0`), so by the time this runs the only candidate no longer has an immediate operand and a search for one finds nothing. The `[-]` was therefore a redundant no-op, not a missed patch. `patchPostValidationAdditional` now also recognizes `cmp w0,w0` in that slot (same BL-precedence anchor) and reports `[=] already cmp w0,w0 ... (base postValidation patch owns this site)` returning success; the failure message additionally reports how many already-patched sites it saw, so a genuine miss is still distinguishable from this case. |     Y      |
| JB-07 | C     | `patch_syscallmask_apply_to_proc`     | syscallmask apply wrapper (`_proc_apply_syscall_masks` path)                                         | Faithful upstream C22: mutate installed Unix/Mach/KOBJ masks to all-ones via structural cave, then continue into setter; distinct from `NULL`-mask alternative                       |     Y      |
| JB-08 | A     | `patch_task_conversion_eval_internal` | `_task_conversion_eval_internal`                                                                     | Allow task conversion                                                                                                                                                                |     Y      |
| JB-09 | A     | `patch_sandbox_hooks_extended`        | Sandbox MACF ops (extended)                                                                          | Stub remaining 30+ sandbox hooks (incl. IOKit 201..210) + `mpo_proc_check_syscall_unix` (`ops[124]`) → allow. **The ops[124] hook is the iOS-27 DDI-mount syscall fix:** MobileStorageMounter's `mount_apfs` needs the `mount(2)` syscall (unix 167) to mount the personalized DDI at `/System/Developer`; on the 26.4-kernel / 27-userland hybrid the kernel Sandbox otherwise denies it (`Protobox: mount_apfs deny(1) syscall-unix 167`). Index calibrated against the reference-XNU `mac_policy_ops` struct order (co-verified: mpo_vnode_check_open=267, mpo_vnode_check_fsgetpath=316). Validated live on `c0ecdb4b` 26.4 (DDI auto-mounts). |     Y      |
| JB-10 | A     | `patch_iouc_failed_macf`              | IOUC MACF shared gate                                                                                | A5-v2: patch only the post-`mac_iokit_check_open` deny gate (`CBZ W0, allow` -> `B allow`) and keep the rest of the IOUserClient open path intact                                    |     Y      |
| JB-10b| A     | `patch_iouc_failed_sandbox`           | IOUC *sandbox* shared gate (string `"IOUC %s failed sandbox in process %s"`)                          | **THE iOS-27 display fix (CONFIRMED 2026-07-15).** Sibling to JB-10: the IOUserClient open path has a SEPARATE Sandbox gate beyond the MACF one. On 27 userland / 26.4 kernel it spuriously DENIES the render server (backboardd) its IOMobileFramebuffer/IOSurface/HID userclient opens (27-specific: ABSENT on native 26.4; backboardd absent from every `IOUserClientCreator`) → no present (no Apple logo) + `mainDisplay=nil` → SpringBoard FBSDisplayMonitor crash-loop. Gate shape (same fn as JB-10): `blraa` sandbox check (PAC-indirect) → `cmp w0,#0xe00002c7` (kIOReturnNotPermitted) `b.eq <ALLOW>`; `ldr w8,[sp,#x]; cbnz w8,<DENY>` (other error → deny block w/ fail-log ADRP → returns error); w0==0 path → `b <ALLOW>`. Patch rewrites `<DENY>`'s first insn → `b <ALLOW>` (deny → allow-proceed), leaving the w0==0 path intact. Anchor is structural (fail-log string xref → the CBNZ whose target encloses it → the preceding `b.eq` allow target). Verified: backboardd then holds an IOMFB userclient, `[CADisplay mainDisplay]` resolves to `LCD/primary`, SpringBoard runs with 0 crashes. |     Y      |
| JB-11 | B     | `patch_proc_security_policy`          | `_proc_security_policy`                                                                              | Bypass security policy                                                                                                                                                               |     Y      |
| JB-12 | B     | `patch_proc_pidinfo`                  | `_proc_pidinfo`                                                                                      | Allow pid 0 info                                                                                                                                                                     |     Y      |
| JB-13 | B     | `patch_convert_port_to_map`           | `_convert_port_to_map_with_flavor`                                                                   | Skip kernel map panic                                                                                                                                                                |     Y      |
| JB-14 | B     | `patch_bsd_init_auth`                 | `_bsd_init` rootauth-failure branch                                                                  | Ignore `FSIOC_KERNEL_ROOTAUTH` failure in `bsd_init`; same gate as base patch #3 when layered                                                                                        |     Y      |
| JB-15 | B     | `patch_dounmount`                     | `_dounmount`                                                                                         | Allow unmount via upstream coveredvp cleanup-call NOP                                                                                                                                |     Y      |
| JB-16 | B     | `patch_io_secure_bsd_root`            | `AppleARMPE::callPlatformFunction` (`"SecureRootName"` return select), called from `IOSecureBSDRoot` | Force `"SecureRootName"` policy return to success without altering callback flow; implementation retargeted 2026-03-06                                                               |     Y      |
| JB-17 | B     | `patch_load_dylinker`                 | `_load_dylinker`                                                                                     | Skip strict `LC_LOAD_DYLINKER == "/usr/lib/dyld"` gate                                                                                                                               |     Y      |
| JB-18 | B     | `patch_mac_mount`                     | `___mac_mount`                                                                                       | Upstream mount-role wrapper bypass (`tbnz` NOP + role-byte zeroing)                                                                                                                  |     Y      |
| JB-19 | B     | `patch_nvram_verify_permission`       | `_verifyPermission` (NVRAM)                                                                          | Allow NVRAM writes                                                                                                                                                                   |     Y      |
| JB-20 | B     | `patch_shared_region_map`             | `_shared_region_map_and_slide_setup`                                                                 | Force root-vs-process-root mount compare to succeed before Cryptex fallback                                                                                                          |     Y      |
| JB-20b| B     | `patch_shared_region_size`            | `vm_shared_region_create` arm64 case                                                                 | **Widen the shared region 6→7 GiB for an iOS 27 userland (2026-10-06, issue #596).** `kernel-boot-shared_region_size`, applicability `iOSBase: .major(27)`, runs under the existing `applyIOS27` gate so a 26.x/18.x base keeps a stock kernel. The 26.4 kernel bakes `SHARED_REGION_BASE_ARM64 == SHARED_REGION_SIZE_ARM64 == 0x180000000`; a 27.0.1 iPhone18,x cache spans `0x185804000`, over the region even at slide 0, so `_shared_region_map_and_slide` ENOMEMs and launchd dies on libSystem — zeroing `maxSlide` (row 10) is not enough. Because base == size, the compiler issued one register for both and `dup v0.2d`-splatted it into the nesting pair, so the arm64 case is rewritten as a 4-instruction block (anchor: the `dup Vd.2d, Xn` between two `#0x180000000` materialisations; window confirmed with Capstone; exactly one hit required; branch preserved): `movz/movk x22` build size `0x1C0000000`, the kernel's own single-instruction base word (`mov x26, #0x180000000`, an ORR logical-immediate alias — one `movz` cannot spell `0x180000000`, bits 31+32 straddle lanes) is reused verbatim, and `stp x26, x22, [sp, #0x70]` replaces the dup/str nesting pair. Replacement words keystone 0.9.2 via `ARM64Encoder.encodeMovzX/encodeMovkX/encodeStpX`; downstream `csm_setup_nested_address_space`, `pmap_set_shared_region` and both `vm_map_create_options` calls take x26/x22 as base/size (verified register-for-register against `vm_shared_region.c` on both variants — research `0x1E0F4E8` / release `0x1D074E8`, byte-identical). Size choice: Apple's iOS 27 value `0x380000000` cannot be copied — the 26.4 kernel's task-map ceilings (`ARM64_MAX_OFFSET_DEVICE_SMALL 0x358000000`, `LARGE 0x458000000`) are compiled from the stock region and iOS 27 raised its own; `0x1C0000000` tops the region at `0x340000000`, under every tier, while covering the worst known cache + full 512 MiB slide (`0x1A5804000`). `cfw install` mirrors this: the region check uses `DyldSharedCacheMaxSlidePatcher.patchedKernelSharedRegionSize` when the VM's kernelcache receipt lists the patch (a VM with no receipt falls back to a `27.*` base), so iPhone18,x installs proceed instead of refusing; `patch-dsc-maxslide` still zeroes the slide (conservative slide-0 first boot). Full analysis: `Research/KernelCustomFirmwarePatches/patch_shared_region_size.md`. **Boot validated 2026-10-06** on iPhone18,2 27.0.1 + cloudOS 26.4 (bundle 2.6.0-local.0d5e6f90, `cfw update-kernel` + `cfw install` over the #596 repro machine): `dyld cache mapped system-wide`, 0 panics, vphoned answers as 27.0.1, home screen at 440x956 @3x — SPTM and TXM accept the `0x1C0000000` nesting range. | `27.*` |
| JB-21 | B     | `patch_spawn_validate_persona`        | `_spawn_validate_persona`                                                                            | Upstream dual-`cbz` persona helper bypass                                                                                                                                            |     Y      |
| JB-22 | B     | `patch_task_for_pid`                  | `_task_for_pid`                                                                                      | Allow task_for_pid via upstream early `pid == 0` gate NOP                                                                                                                            |     Y      |
| JB-23 | B     | `patch_thid_should_crash`             | `_thid_should_crash`                                                                                 | Prevent GUARD_TYPE_MACH_PORT crash                                                                                                                                                   |     Y      |
| JB-23b| B     | `patchThreadSetStateEntitlementFlag`  | `thread_set_state_from_user` / inlined `act_set_state_from_user` flags materialization               | **Frida Stalker existing-thread support (opt-in `--frida`).** Stalker updates an existing thread's core registers via `thread_set_state_from_user`, which passes `flags = TSSF_TRANSLATE_TO_USER \| TSSF_CHECK_ENTITLEMENT` (0x201) into `thread_set_state_internal`; the inlined `thread_set_state_allowed()` then demands `com.apple.private.thread-set-state` (which the target lacks) → `GUARD_TYPE_MACH_PORT / THREAD_SET_STATE`. Rather than NOP the entitlement check, clear TSSF_CHECK_ENTITLEMENT (bit 9) in the flags the user setters pass: rewrite `mov w6, #0x201` → `mov w6, #0x1`. This preserves TSSF_TRANSLATE_TO_USER (user-pointer translation) and leaves the independent `TH_IN_MACH_EXCEPTION` guard enforced — it only stops user-initiated `thread_set_state` from being entitlement-gated. Anchor: entitlement-string xref cluster → the single containing function (thread_set_state_internal); then its direct `b`/`bl` callers that set `w6` (the 7th-arg = flags, a calling-convention anchor, not an allocation guess) to 0x201. Both setters (`thread_set_state_from_user` + inlined `act_set_state_from_user`) are patched. No offsets/VAs/registers/bytes hardcoded; replacement from the Keystone-backed `ARM64Encoder.encodeMovzW`, Capstone-verified. Kernels without the shape are skipped (fail-open no-op). Verified on the `c0ecdb4b` 26.4 kernel (UUID `BCD06230-CCBE-8E48-50FF-D9C166D83CD5`): exactly two records at file-off `0x1D95720`/`0x1D9594C`. | `--frida` |
| JB-24 | B     | `patch_vm_fault_enter_prepare`        | `_vm_fault_enter_prepare`                                                                            | Force `cs_bypass` fast path in runtime fault validation                                                                                                                              |     Y      |
| JB-25 | B     | `patch_vm_map_protect`                | `_vm_map_protect`                                                                                    | Skip upstream write-downgrade gate. Shape A (26.1–26.4) active; **Shape B (26.5) disabled 2026-07-05** — widened the `~VM_PROT_WRITE` COW strip (vm_map.c:6202) instead of the RWX gate (vm_map.c:5997), breaking COW and crashing the debugger (SPTM `VIOLATION_ILLEGAL_MAP`). Retired on 26.5+: SPTM code-mod (debugger + Substrate tweaks) uses write-then-flip via `vm_protect(VM_PROT_COPY)` → `XNU_USER_DEBUG`, so no RWX patch is needed. **SHAPE C ADDED (2026-09-22, cloudOS 26.4 `c0ecdb4b…`, jb):** the patch logged `[-] vm_map_protect write-downgrade gate not found` on this base, which `make test_fw_patches` is built to fail on. Two independent causes, both confirmed by disassembling the 26.4 research kernelcache. **(1) The gate is compiled differently.** Where 26.1/26.3 emit a flag-setting `bics` plus a separate `tbnz wFlags,#22,skip`, 26.4 folds the two conditions into a conditional compare and leaves one branch: `and wFlags,wFlags,#0x400000` / `mov wMask,#6` / `bic wMask,wMask,wProt` / `cmp wMask,#0` / `ccmp wFlags,#0,#0,eq` / `b.ne skip`, with `and wProt,wProt,#0xfffffffb` (clear `VM_PROT_EXECUTE`, keep R|W) inside the guarded block. Same mask `#6`, same entry bit 22, same downgrade — rewriting that single `b.ne` to an unconditional `b` bypasses both conditions at once, exactly as Shape A's rewrite does (there the `tbnz` becomes dead). Observed at VA `0xFFFFFE0008DCAEA0` → `0xFFFFFE0008DCAED0` (file `0x1DC6EA0`). **(2) The search window stopped short.** `findFuncEnd` ends at the next `pacibsp`; on 26.4 the block holding the `"vm_map_protect("` panic string ends at its own prologue `0x6B8` bytes *before* the gate, so the window derived from the string anchor never reached it. **Reveal procedure for Shape C:** the signature is its own anchor rather than a byte window — across the whole `com.apple.kernel __TEXT_EXEC` (8.4 MB) even the bare `mov wMask,#6 ; bic wMask,wMask,wProt` prefix occurs **exactly once**, and the matcher additionally requires the bit-22 mask before it and the execute-clearing `and` inside the guarded block, then demands a unique hit across all code ranges. Widening by an offset was rejected as an offset-shaped anchor. **Backward compatibility:** Shape A is untouched and still tried first, so 26.1/26.3 take precisely the path they always took and Shape C is unreachable there. **VALIDATED on-device (2026-09-23, `17,3_26.4_23E246` + cloudOS 26.4 `23E5207q`, JB, `vm create` host-mount deploy):** the deployed `kernelcache.research.vphone600` carries the rewritten gate — `0xFFFFFE0008DCAEA0` disassembles as unconditional `b #0xfffffe0008dcaed0` with `and w8,w8,#0x400000 / mov w9,#6 / bic w9,w9,w20 / cmp w9,#0 / ccmp w8,#0,#0,eq` intact above it — and the VM boots clean: zero `panic(` / `stackshot` markers across the whole boot log, SpringBoard up, Safari and Sileo both running, so the JB userland and TweakLoader come up with the patch live. The gate is the same one on a 26.4 base whichever userland rides on top, since `fw_patch_jb` patches the cloudOS kernelcache, not the iOS one. Matching was separately checked on `17,3_27.0_24A435` + the same base. **Still not exercised:** a debugger attach or a tweak RWX write specifically — that is the failure mode Shape B produced (broken COW, SPTM `VIOLATION_ILLEGAL_MAP`), and a clean boot with Sileo running is good evidence but not that test. Note the source also disagreed with itself about the covered range — headers said "Shape A (26.1 / 26.3)", line 69 said "26.1-26.4"; on 26.4 the answer is neither, it is Shape C. **PREFILTERED (2026-09-28, no change to the gate or the patch):** because the Shape C scan is deliberately unscoped it walks all 8.4 MB of kernel text, and it was decoding five instructions at every one of the ~2.1M offsets only to reject almost all of them on the first one. Sampling a Release `fw patch` (8623 samples, `sample`) put 93% of the whole run in `scanRange` → `ARM64Disassembler.disassemble`, and 72% of that inside `cs_disasm` — not in the decoder but in Capstone's *printer*: `printInst` / `printAliasInstr` / `matchAliasPatterns`, `vsnprintf` / `SStream_concat`, and `map_set_alias_id` → `name2id`'s `strcmp` chain. `AArch64_LLVM_getInstruction`, the actual decode, was 6%. A rejection-only raw-word gate now runs first (`ARM64Inst.isMOVZW` + `movImm16 == 6`, or `isORRImmW` + `rn == 31`), so Capstone is only asked about offsets that could open with `mov wMask,#6`. **Nothing is decided by the prefilter** — survivors take exactly the decode and the checks they always did, and every positive determination is still Capstone's. Both encodings of `mov wD,#6` are accepted although only MOVZ can reach the existing `mnemonic == "mov"` check (the MOV-bitmask alias applies only when the immediate is *not* MOVZ-encodable, so `orr w9,wzr,#6` = `0x321F07E9` prints as `orr`), which keeps the gate independent of that aliasing rule; `ARM64InstTests` pins both words and the printer's answer for each. The same treatment was applied to the one other full-text scan, `patchThreadSetStateEntitlementFlag` (`isBorBL`, extended-only). Measured on `17,3_26.4` + cloudOS 26.4, Release: the patch step 28.81 s → 1.28 s, whole `fw patch` 48.98 s → 21.68 s standard and ~61 s → ~28 s extended, instructions retired 1.006e12 → 5.38e11. **Verified byte-identical:** all four bases (26.1 / 26.4 / 26.6.2 / 27.0) × both presets, HEAD vs HEAD+prefilter, every file in each restore tree hashed — 12/12 identical (196/186/186/185 files), same 172 standard / 183 extended patch counts, same `0x1DC6EA0` rewrite, no undeclared-patch warnings. |    Y/N     |
| JB-25c| B     | `patchVmMapDeleteImmutableCode`       | `_vm_map_delete` permanent-entry immutable-code exception (vm_map.c:8855)                            | **Frida Stalker repeated-`VM_PROT_COPY` fix (opt-in `--frida`).** Stalker's write-then-flip leaves a CSM-associated permanent entry at current `RW` / max `RWX`; XNU's "debugger may undo executable mappings" exception tests `entry->protection & VM_PROT_EXECUTE` (current, bit 9), which is clear, so the entry stays permanent and the next fixed overwrite returns `KERN_PROTECTION_FAILURE`. Retarget the execute test to the packed `max_protection` bit (bit 9 → bit 13; `protection:3`@7..9, `max_protection:4`@11..14 in the `[entry,#0x38]` flags word). Semantic matcher: packed-flags load + `vme_permanent` (bit 19) + the inlined `developer_mode_state()` byte-bit-0 read + the current-X test bound to the immutable-code cluster (Shape A: shares the remove-flags fallback target; Shape B: branches to the permanent-continuation target). The remove-flags bit is matched structurally (a test of a non-entry register), not by source constant (VM_MAP_REMOVE_* bit numbers drift across XNU versions). The later CSM current-X `#9` test in the same window is deliberately excluded (different branch target). Exactly two gates or fail closed; branch bytes from the Keystone-backed `ARM64Encoder.encodeTestBitBranch`, Capstone round-trip verified (sense/bit/target). Verified on the `c0ecdb4b` 26.4 kernel: two records at file-off `0x1DBE14C` (`tbz w8,#9→#0xd`) and `0x1DBE828` (`tbnz w8,#9→#0xd`). | `--frida` |
| JB-26 | B     | `patch_iomfb_swapend_variable_size`   | IOMFB userclient method-5 (SwapEnd) `__DATA_CONST` dispatch entry (`checkStructureInputSize`)        | **iOS-27 VZ-view fix, kernel half — paired with DSC force-kern (DSC-patch item 11).** The 26.4 userclient's method-5 dispatch entry hard-checks `checkStructureInputSize == 0x588`; forced-kern iOS 27 sends its native `0x6e0`. Rewrite the size field to `kIOUCVariableStructureSize (0xFFFFFFFF)` so `IOUserClient::externalMethod` accepts 27's struct and reaches the handler. Anchor (structural): the sole `__DATA_CONST` entry `{ptr(ptrauth, top-byte≥0x80), scalarIn=0, structIn=0x588, scalarOut=0, structOut=0}` (verified unique; decompressed file-off 0x9c7228). No-op-in-effect for version-matched 26.x (sends 0x588). Re-enabled 2026-07-15 (was disabled when 27 present-path was still unknown). |     Y      |
| JB-27 | B     | `patch_iomfb_swapend_handler_size`    | method-5 handler internal size gate (`cmp w2,#0x588 ; b.ne <err>`)                                   | Companion to JB-26: beyond the dispatch-table check the handler re-checks the struct size (`cmp w2,#0x588 ; b.ne <kIOReturnBadArgument>`; verified unique at decompressed file-off 0x16ae22c; success path forwards the raw struct ptr to a `vtable+0x590` paravirt swap method). Retarget the `cmp` immediate to `0x6e0` so forced-kern iOS 27's native SwapEnd reaches real swap processing (27's IOMFBSwapRec prefix matches 26.x → handler reads valid fields). Semantic anchor (`cmp w2,#imm` word + following `b.ne` decode). Enabled together with JB-26 + DSC force-kern for iOS 27. |     Y      |
| JB-28 | A     | `patch_disk_images2_client_abi`       | `com.apple.driver.AppleDiskImages2` kext: `DIDeviceCreatorUserClient::CreateDevice` + `DIDeviceIOUserClient::Connect` ABI-version gates, and the `AllocPortsArray`/`RegisterNotificationPort` notif-port sizing | **iOS-27 DDI (`/System/Developer`) auto-mount — attach layer.** `pymobiledevice3 mounter auto-mount` on the 26.4-kernel / 27-userland hybrid fails at attach: the kernel DiskImages2 driver is ABI v9, the 27 userland's DiskImages2 controller/daemon is ABI v11 (`DIDeviceCreatorUserClient::CreateDevice: Incompatible client: expected ABI version 9 actual 11`). Three layers: **GATE1** NOPs the CreateDevice controller-ABI `cmp #9 ; b.ne` reject; **GATE2b** NOPs the Connect daemon-ABI `cmp #9 ; b.ne` reject (both anchored on the C++ signature cstring → unique `cmp #9`/`b.ne`; version-robust; no-op-in-effect on version-matched userlands where ABI 9==9). **GATE2** (array + 2 bound checks) fixes a RegisterNotificationPort off-by-one (userland registers at index==maxPorts, one past the array) by widening the AllocPortsArray allocation (`lsl x1,xN,#3` → `mov x1,#0x4000`) AND both bound-check field loads (`ldrh [.,#0xd8]`/`ldr [.,#0xe8]` → `mov wD,#0x800`); applied **all-or-nothing** (widening the bound checks without the backing array would let RegisterNotificationPort write past it → corruption) and skipped/logged on builds whose notif-port codegen differs (the off-by-one is 26.4-hybrid-specific). Pairs with the sandbox ops[124] allow (JB-09) and the diskimagesiod userland patch (CFW binary-patch #13). Anchors structural (Capstone decode of the pinned function's instructions); replacement bytes from the Keystone-backed `ARM64Encoder`. **GATE2a anchor note:** the AllocPortsArray size-shift is matched on `lsl` mnemonic + destination `x1` (the unique size-writing lsl in the function) — NOT a 3-operand `lsl xd,xn,#imm` shape, because Capstone on this toolchain decodes the lsl-immediate (a UBFM alias) as **2 operands**; requiring 3 operands makes GATE2 silently skip (the all-or-nothing returns a harmless no-op). Verified on the `c0ecdb4b` 26.4 deployment kernel via `patch-component --component kernel-jb --records-out`: all five di2 records emit (`di2_createdevice_abi`, `di2_connect_abi`, `di2_allocports_size`, `di2_notif_boundcheck_d8`, `di2_notif_boundcheck_e8`) — always verify the di2 records EMIT, not merely that the JB suite reports "no failures". No-op-in-effect for version-matched userlands. |     Y      |
| JB-29 | C     | `patch_fpfs_scoped_vnode_open`        | Sandbox MACF `mpo_vnode_check_open` (`ops[267]`) → per-process trampoline code cave                  | **iOS-27 random-respring fix (fpfs balloon).** JB-09 blanket-neuters `mpo_vnode_check_open` (`ops[267]` → allow) so processes can read `/var/jb`. But FileProvider's fpfs parent-walk (`fpfs_pkg_fd_lookup` → `openbyid` climbing via `getattrlistat(ATTR_CMN_PAROBJID)`) uses the stock check's EACCES at the domain-container boundary as its terminus; neutered, the walk climbs unbounded → `ResolverService` (FileProviderResolver) balloons to ~12 GB → `vm-compressor-space-shortage` jetsam → backboardd killed → **respring** (seen on 27b4/24A5390f). Fix keeps the global bypass and enforces the real check for the FileProvider daemons only: on 27, `ops[267]` is left un-neutered (removed from JB-09's blanket list — conditional `if !applyIOS27` in `patchSandboxHooksExtended`), then retargeted to a 20-insn code-cave trampoline that inlines `current_proc` (`mrs tpidr_el1` → `ldr [+0x3F0]` uthread → `ldr [+0x18]` proc), loads `p_comm` (`+0x56C`), compares the first 8 bytes to `"Resolver"`/`"fileprov"`, and on match `b`s to the real `vnode_check_open` (restores the terminus) else returns allow (`mov x0,#0 ; ret` → `/var/jb` reads + Sileo/TrollStore icons unaffected). Register-only (x8–x10), no frame/call (~18 insns/open). Struct offsets recovered via the VZ gdb stub on vphone600; cave bytes from the Keystone-backed `ARM64Encoder`, verified by Capstone round-trip; the `ops[267]` retarget preserves the auth-rebase high bits (same encoder family as JB-09). **VALIDATED on-device (2026-07-23, `17,3_27.0_24A5390f` + cloudOS 26.4, JB, `setup_machine` deploy): resprings stop; Sileo/TrollStoreLite icons render.** Backward-compat: a 26.5 base is unaffected (`ops[267]` still blanket-neutered there) — verified byte-identical kernelcache pre-vs-post (`cmp` clean, `sha256` unchanged). See `KernelJBPatchFpfsScopedOpen.swift`. |     Y      |
| JB-30 | B     | `patchParavirtDisplayRefreshRate` (record `kernel-cfw-display_promotion`; introduced as `kernel-exp-display_refresh_120hz`, renamed when `standard` turned it on) | `AppleParavirtDisplay::createDisplayAttributes` (AppleParavirtGPUIOGPUFamily), the per-mode timing element call | **ProMotion: 120 Hz display timing (on in `standard` since 2026-10-09; it shipped opt-in from 2.4.2).** The host VM service builds its one `PGDisplayMode` with a constant 60.0 Hz and writes it into the display shared state page as a 16-byte entry (u16 width, u16 height, u32 refresh in 16.16 Hz, flags); the guest turns each entry into an IOAV timing element with `ldurh w1,[xN,#-8]; ldurh w2,[xN,#-6]; ldur w3,[xN,#-4]; bl`. The `ldur w3` becomes `movz w3,#120,lsl #16`. Anchor: the `createDisplayAttributes` logger cstring (all refs in one function) + the only w1/w2/w3 load triple off one base at -8/-6/-4 ahead of a call. Gated by `KernelCustomFirmwarePatcher.applyProMotion`, set from the plan. See `Research/Guest/display_refresh_rate.md`. |     Y      |
| JB-31 | C     | `patchParavirtUserClientsNarrow` (records `kernel-cfw-paravirt_user_clients.redirect` / `.cave`; introduced as `kernel-exp-paravirt_user_clients`, renamed when `standard` turned it on) | Same IOUserClient Sandbox gate; the deny block's `ldr Xt,[sp,#imm]` eight bytes before the fail-log `adrp` | **Paravirtual device access on a 26.x / 18.x base (on in `standard` since 2026-10-04; it shipped opt-in).** Narrow replacement for the broad gate-off: at the deny point the class-name C string is already in x0, so a code-cave trampoline reads its first eight bytes and branches to the gate's NotPermitted allow target only for `ApplePar` / `AppleVid` / `AppleVir` / `IOSurfac` (AppleParavirt\*, AppleVideoToolboxParavirt\*, AppleVirtIO\*, IOSurfaceAcceleratorParavirtClient); every other denial runs the displaced `ldr` and falls through to the real deny. Fixes `MTLCreateSystemDefaultDevice()` nil in daemons/CLI and the VideoToolbox/ANE/IOSurface denials (upstream issue #22) without opening the rest. Cave words verified by clang/as + capstone round-trip; the two `b` words via `ARM64Encoder`. Gated by `KernelCustomFirmwarePatcher.applyParavirtUserClients`, set from the plan when `applyIOS27` is false. See `Research/Guest/gpu_acceleration.md`. |     Y      |

### EXP-Only Kernel Methods (Reference List)

Runs in `KernelEXPPatcher.findAll()` (chained after `KernelPatcher` +
`KernelJBPatcher` for the `.exp` variant only — JB and other variants
do NOT execute these).

| #      | Group | Method                | Function                                                              | Purpose                                                                                                                                                                                                                                                                                                                                                                       | EXP Enabled |
| ------ | ----- | --------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------: |
| EXP-01 | B     | `patch_hv_vmm_rename` | sysctl OID name cstring `"hv_vmm_present"` → `"Xv_vmm_present"` (Part A) + every kernel-internal occurrence of `kern.hv_vmm_present` cstring/sandbox-profile token mangled at byte 5 (Part B) | Rename the `kern.hv_vmm_present` OID's name in place (`'h' → 'X'` at offset 0 of the 14-byte cstring). After this: `sysctlbyname("kern.hv_vmm_present")` returns ENOENT; `sysctlbyname("kern.Xv_vmm_present")` returns the original int value (1). Part B mangles every kernel-internal caller — AMFI, IOCryptoAcceleratorFamily, sandbox-profile token, apfs — so they keep hitting the renamed OID. Companion to the user-mode blacklist-flip mangle in `cfw_patch_hv_vmm_dsc.py`. |      Y      |

## CFW Installation Patches

### Binary Patches Applied Over SSH Ramdisk

| #   | Patch                     | Binary                 | Purpose                                                       | Regular | Dev | JB  |
| --- | ------------------------- | ---------------------- | ------------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | `/%s.gl` -> `/AA.gl`      | `seputil`              | Gigalocker UUID fix                                           |    Y    |  Y  |  Y  |
| 2   | NOP cache validation      | `launchd_cache_loader` | Allow modified `launchd.plist`                                |    Y    |  Y  |  Y  |
| 3   | `mov x0,#1; ret`          | `mobileactivationd`    | Activation bypass                                             |    Y    |  Y  |  Y  |
| 4   | Plist injection           | `launchd.plist`        | bash/dropbear/trollvnc/vphoned daemons                        |    Y    |  Y  |  Y  |
| 5   | `b` (skip jetsam guard)   | `launchd`              | Prevent jetsam panic on boot                                  |    -    |  Y  |  Y  |
| 6   | Weak dylib load injection | `launchd`              | Load short alias `/b` (copy of `launchdhook.dylib`) at launch. On by default; set `DISABLE_LAUNCHD_HOOK=1` to skip because this pid-1 hook path is boot-critical and has produced boot-analysis failures |    -    |  Y  |  Y  |
| 7   | cstring byte 5 mangle `'h' → 'X'` (`"kern.hv_vmm_present"` → `"kern.Xv_vmm_present"`) + per-page slot-hash re-attestation, BLACKLIST semantics — **EXP only** | DSC dylibs        | Companion to EXP kernel rename (`KernelEXPPatcher.patchHvVmmRename`). The mangle is applied to every DSC dylib EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness consumers, ~15 entries). Patched dylibs query `kern.Xv_vmm_present` and get the truthful 1 (graphics / accel passthrough). Blacklisted dylibs keep the original cstring, hit ENOENT on the renamed kernel, cache 0, lie about VM presence. On `codeSigningMonitor == 2` hardware the byte-mangle alone causes `CODESIGNING/Invalid Page` SIGKILL because TXM enforces per-page hashes; the re-attestation pass recomputes the SHA-256 slot in the chunk's `CS_CodeDirectory` for every modified 16 KiB page. See `scripts/patchers/cfw_dsc_codesign.py` and `cfw_patch_hv_vmm_dsc.py`. |    -    |  -  |  -  |
| 8   | (removed — was: standalone-binary mangle in 6 rootfs Mach-Os via SSH) | n/a               | Removed in the blacklist-flip redesign. With the EXP kernel rename in place, the 6 rootfs binaries (MobileActivationMigrator, CheckerBoard, StoreKitUISceneService, storekitd, appstored, CorePrescriptionService) get the desired "cache 0 / not in a VM" behavior for free: they keep their original cstring, hit ENOENT on the renamed kernel sysctl, defensive `cbnz w0, skip` leaves the cached byte at BSS-zero. No SSH-time standalone patch needed. |    -    |  -  |  -  |
| 9   | `mov w3,#<size>` -> `mov w3,#<base-size>` in `_kern_SwapEnd` — **26.0/26.0.1 and 18.x** | DSC `IOMobileFramebuffer` | Fixes host VZ GUI black-screen with the available PCC vphone600 userclient: the userclient does an exact `checkStructureInputSize` check on external-method-5 (SwapEnd) input, so a userland whose `_kern_SwapEnd` sends a different-sized state gets `kIOReturnBadArgument` and the host display stays black (guest still renders — the Apple logo is visible over VNC, just not in the vphone-cli view). **The accepted size is a property of the base kernel, not the userland**: 26.1 base -> **0x560**, 26.4 base (xnu-12377) -> **0x588**. The 0x588 value is confirmed two ways: the sole dispatch-shaped entry in `kernelcache.*.vphone600` with `checkStructureInputSize==0x588` (scalarIn=0, scalarOut=0, structOut=0, preceded by a ptrauth code ptr, at decompressed file offset 0x9c7228), and empirically — native 26.5 userland sends 0x588 and displays correctly on this stack. Source (userland-sent) sizes observed: 18.6.2 = 0x514, 26.0/26.0.1 = 0x548, 27.0 (24A5380h) = 0x6e0. The patcher is semantic (anchors on `mov w1,#5` -> `mov w3,#imm` -> `mov x4,#0`/`mov x5,#0` -> `bl` inside `_kern_SwapEnd`) and idempotent — rewrites the size to `--target-size` regardless of source and re-attests the modified DSC page. Install gate: `26.0*` / `18.*` -> 0x560 (26.1 base). Validated after host install on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and `17,3_18.6.2_22G100` (Apple logo renders) against the 26.1 base. **CORRECTION (2026-07-15): iOS 27.0 is NO LONGER handled here.** 27 presents the paravirt display via IOMFB's `_virt_*` callback path — external method 5 is NEVER called — so no SwapEnd *size* change can help 27 (confirmed by kernel trace + live AppleParavirtGPU idle scheduler). iOS 27 now uses **force-kern (item 11)** to route present back onto method 5; this row applies to 26.0/26.0.1/18.x only. |    Y    |  Y  |  Y  |
| 10  | Zero `maxSlide` in `dyld_cache_header` (`@0xF0`) — **iOS 27.0 / any userland whose cache overflows the 6 GiB region** | DSC `dyld_shared_cache_arm64e` header | Fixes pid-1 `launchd` panic at boot on the vphone600 26.x kernel. The kernel reserves `SHARED_REGION_SIZE_ARM64 = 0x180000000` (6 GiB) and, at map time, needs room for the cache's mapped span **plus** the header `maxSlide` (ASLR range). iOS 27.0's cache (span `0x17c830000` ≈ 5.95 GiB) + `maxSlide 0x20000000` = `0x19c830000` > 6 GiB, so `_shared_region_map_and_slide` returns `ENOMEM`, dyld cannot map `libSystem.B.dylib`, and `launchd` panics (`initproc failed to start`). Zeroing `maxSlide` (LE u64) in the main chunk maps the cache at slide 0 (fits with ~58 MiB spare). Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base skips it entirely). The patcher additionally self-gates (`patch-dsc-maxslide`): no-op unless span + maxSlide > `0x180000000`, kept as defense-in-depth so 26.x / 18.x are untouched even if the install gate were removed. **The non-27 opt-in is gone** (2026-09-30): `FORCE_DSC_MAXSLIDE=1`, later `--force-dsc-maxslide`, no longer exists on any command or in Launchpad. `dyld-boot-maxslide` is declared `iOSBase: .major(27)`, so non-27 bases keep their native slide. `patch-dsc-maxslide --force` remains on the standalone verb for hand use; `cfw install` never passes it. **24A435 (27.0 RC) checked 2026-09-30** for issue #531: the pristine SystemOS cryptex header reads `sharedRegionStart 0x180000000`, `sharedRegionSize 0x17D504000`, `maxSlide 0x20000000`, so span + slide is `0x19D504000`. `vphone-cli cfw patch-dsc-maxslide --dry-run` (2.1.6) reports `overflow` and would zero it; an installed 24A435 guest reads `maxSlide 0x0` and boots. The self-gate therefore patches 24A435 without force. The 512 MiB slide is the cache builder's fixed iOS arm64 value, so every 27 cache overflows this region. Source check (xnu-12377, `shared_region_map_and_slide_2_np`, `vm_shared_region_map_file_setup`, `vm_map_locate_space_fixed`): the kernel picks a 16 KiB-aligned slide strictly below `maxSlide` and maps each range FIXED inside the `0x180000000` submap. With no twig rounding and no reserved area, `size + maxSlide <= 0x180000000` is a sufficient test, one 16 KiB page stricter than needed. The #531 panic therefore came from a guest whose cache was never patched. Most likely its CFW install had not completed, because `cfw install` swaps in its clone only on success. It did not come from the gate. **No** page re-attestation (header metadata, not a `cs_validate`'d code page — confirmed empirically). Validated on `17,3_27.0_24A5380h` + cloudOS 26.4 (`c0ecdb4b…`): `dyld cache mapped system-wide`, launchd reaches first unlock, vphoned connects as iOS 27.0.0, 0 panics. See `scripts/patchers/cfw_patch_dsc_maxslide.py`. |    Y    |  Y  |  Y  |
| 11  | Retarget public `_IOMobileFramebufferSwap*` trampolines -> `b _kern_Swap*` (force-kern) — **iOS 27.0** | DSC `IOMobileFramebuffer` | **iOS-27 VZ-view (host paravirt-GPU scanout) fix, userland half.** The host `VZVirtualMachineView` is fed by the guest `AppleParavirtGPU` scanout, which the 26.4 kernel drives ONLY from the IOMFB userclient SwapEnd (external method 5) — the `_kern_Swap*` path. iOS 27 defaults the paravirt display's present to IOMFB's parallel `_virt_Swap*` path (`_virt_SwapEnd` does no userclient call — it invokes an in-process callback `blraaz [conn+0xe68]` and hands the IOSurface to a virtual-display consumer), so the paravirt GPU never scans out → host VZ window black (guest still composites; GUI visible over in-guest TrollVNC; AppleParavirtGPU `SchedulerState` idle). The public `_IOMobileFramebufferSwap*` entrypoints are thin trampolines (`cbz x0; ldr xN,[x0,#slot]; cbz xN; braaz xN`) that tail-call the per-connection swap fp (kern or virt impl). This patch rewrites each trampoline's first insn to `b _kern_Swap<Name>`, forcing present onto method 5 regardless of how 27 classified the display (tail-call, args intact → behaviourally identical to selecting the kern fp). Fully dynamic: public + `_kern_` addrs resolved by name via `ipsw dyld symaddr`, trampoline shape verified by Capstone, branch bytes from Keystone `asm_at()`, modified DSC code pages re-attested. Requires ≥{SwapBegin,SwapEnd,SwapSetLayer} or raises (dry-run retargets 31 entrypoints on 24A5380h, skips 4 non-trampolines). **Pairs with the JB kernel patches (`patchIomfbSwapEndVariableSize` + `patchIomfbSwapEndHandlerSize`)** which relax the 26.4 userclient's two exact `0x588` size gates to accept 27's native `0x6e0` IOMFBSwapRec (prefix matches 26.x, so the paravirt swap handler reads valid fields). Install gate: `27.*`. See `scripts/patchers/cfw_patch_iomfb_force_kern.py`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 userland renders AND is interactive in the native VZ view (not just TrollVNC); clean boot — no `kIOReturnBadArgument`/SwapEnd rejection/panic.** Runtime confirmed 31 entrypoints retargeted (4 non-trampoline setters left on virt). **Conditional since 2026-10-07 (DeviceHub):** forcing every trampoline also sent the capture display that Xcode's DeviceHub stream adds to the kernel; it has no userclient port, so backboardd logged `display 2 swap_end returned error 10000003` (`MACH_SEND_INVALID_DEST`) and the stream was black. Each trampoline is now `cbz x0, <fail>` / `ldr w16, [x0, #0x14]` / `cbnz w16, _kern_Swap<Name>` / `b _virt_Swap<Name>`: a connection with an IOConnect port (the paravirtual main display) still presents through method 5, a virtual display keeps its in-process path. Only operations with public, `_kern_` and `_virt_` siblings take part (ten on 24A446; `SwapSignal` is not a trampoline). The `0x14` port offset is the one every `_kern_Swap*` passes to the external method, verified on 24A446. The identifier is unchanged; the installer recognizes the old 4-byte undo records (`DyldSharedCacheUndoLog.outdatedImplementations`), reverts them and applies the conditional form in the same `cfw install` or environment update, so an installed guest upgrades without manual steps. Validated on `iPhone17,3 27.0.1 (24A446)`: VZ scanout unchanged, DeviceHub live. See `Research/Guest/devicehub_screen_viewing.md`. |    Y    |  Y  |  Y  |
| 12  | NOP `-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]` entitlement gate + per-page re-attest — **iOS 27.0** | DSC `CoreServices` (LaunchServices) | **iOS-27 app-registration fix.** lsd gates `-[_LSDModifyClient performPostInstallationRegistration:operationUUID:reply:]` (and the containerized/rebuild registration paths) behind `clientIsEntitledForEmbeddedRegistrationOperations`, which does `xpc_connection_copy_entitlement_value` on the XPC peer for any of `com.apple.private.coreservices.lsaw` / `com.apple.private.installcoordinationd.daemon` / `com.apple.private.coreservices.can-register-install-results`. A client without one gets `NSOSStatusErrorDomain -54` (permErr, `LSDModifyService.mm:1639`), so `registerApplicationDictionary:` / `registerContainerizedApplicationWithInfoDictionaries:` fail and no app can (re)register — blocking vphoned's installer, TrollStore, and uicache/Sileo alike. The entitlement route is a dead end even for a launchd platform daemon (vphoned) whose validated csblob (`csops CS_OPS_ENTITLEMENTS_BLOB`) contains all three: LS registration is proxied, so the XPC peer lsd inspects is not the registering process. Fix: NOP the final `cbz w0, <not_entitled>` (the conditional branch whose fall-through sets the `mov w<reg>,#1` result) so the method always returns YES. Fully dynamic: method resolved via the DSC's own `.symbols` in-image local-symbol table (ipsw `symaddr -a`/`a2s` time out on this cache), gate located by control-flow shape in Capstone, NOP from Keystone `asm("nop")`, modified 16 KiB page re-attested (`cfw_dsc_codesign.py`; TXM enforces per-page). The resulting CDHash change is accepted by the JB always-true AMFI cdhash-trust patch. Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base does not apply it). The patcher additionally self-gates (`patch-lsd-embedded-reg`): no-op on pre-iOS-27 userlands where the method is absent. **Pairs with vphoned's `vp_register_path` containerized-registration fallback** (`registerContainerizedApplicationWithInfoDictionaries:...:registrationError:`, treating a nil `registrationError` as success since it returns NO even when it registers). Also paired with **`/cores/vpregister`** (built + deployed by `cfw_install_jb.sh` / `cfw_install_exp.sh`, invoked by `vphone_jb_setup.sh` at first boot — 27-gated by DEPLOYMENT: `cfw_install_jb.sh`/`cfw_install_exp.sh` copy `/cores/vpregister` only when the mounted rootfs `SystemVersion.plist` is `27.*`, and the setup script's `[ -x /cores/vpregister ]` presence check is the runtime gate. Do NOT gate the invocation on a guest `sw_vers` check — the hybrid guest does not reliably report the 27 userland version at first boot, which silently skipped registration): it registers JB app bundles (Sileo) via the same containerized API, because `uicache -a`'s `registerApplicationDictionary:` is a deprecated no-op on iOS 27 (lsd logs *"you cannot use ... to register applications anymore. These interfaces have been deprecated for years."*). **VALIDATED (2026-07-17, `17,3_27.0_24A5380h` + cloudOS 26.4, JB): -54 gone; Sileo registers (`uicache -l` 0→1) via `vpregister`; vphoned installs+registers a test IPA (`com.vphone.vptest`) to `/var/containers/Bundle/Application/` end-to-end. Clean boot (re-attest correct; no CoreServices page rejection).** See `scripts/patchers/cfw_patch_lsd_embedded_reg.py` and `Siblings/VPRegister/vpregister.m`. **FIX (2026-08-10):** `_find_gate` only matched the live `cbz`/`cbnz` branch shape, so re-running `cfw install` (host-mount flow, `myphone` VM, `17,3_27.0_24A5390f`) against a cache where this gate was already NOP'd from a prior pass raised `ValueError: ... entitled-result gate ... not found` instead of recognizing the idempotent state (unlike the Cryptex/IOMFB steps, which log `already ... idempotent` and skip cleanly). Confirmed live via host-mount disassembly: the third check's `bl <check3>` is followed by a bare `nop` at the gate site (exact match against `asm("nop")` bytes) immediately before `mov w20, #1` — i.e. already patched. `_find_gate` now also matches `nop` immediately preceding `mov w<reg>,#1` as an already-patched gate, so a re-run just re-attests the page instead of erroring. |    Y    |  Y  |  Y  |
| 13  | `mov x0,#1; ret` on `-[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:]` — **iOS 27.0** | `diskimagesiod` | **iOS-27 DDI (`/System/Developer`) auto-mount — mount-gate.** After the personalized DDI attaches (kernel side: JB-28 + JB-09), MobileStorageMounter waits on diskimagesiod's `-[DIDiskArb waitForDAMountWithExpectedCount:diskTracker:]` before it does the real (nobrowse) mount at `/System/Developer`. That wait loops until `isMountComplete` (= `callbackReached \|\| (appearedDiskCount>=expectedCount && mountedDiskCount>=mountableDiskCount)`) is YES; on the 26.4-kernel / 27-userland hybrid it never becomes true (not all of the DMG's IOMedia "appear" to diskimagesiod's DiskArbitration session, and diskarbitrationd never auto-mounts the volume), so the wait hangs and pmd3 times out. diskimagesiod itself does NOT mount the DDI (its `-[DIDiskArb mountWithDeviceName:...]` is dead code) — it only gates MobileStorageMounter. Forcing `isMountComplete` → YES lets the wait return so MobileStorageMounter proceeds. IMP resolved via LC_SYMTAB or ObjC metadata (selector → `__objc_selrefs` → `__TEXT,__objc_methlist` relative method list → IMP); prologue overwritten `mov x0,#1 ; ret` (safe — the method returns to the caller's unsigned LR without pushing a frame). **Gated to 27.\*** in `cfw_install.sh` (same `$IOS_VERSION` as the DSC patches): on a version-matched userland the native wait completes correctly and forcing it early could race the real mount, so it is NOT applied there. Embedded sandbox profile + private DA/apfs entitlements preserved on re-sign (`ldid_sign_ent`). **Validated on `c0ecdb4b` 26.4 + 27.0 userland: `pmd3 mounter auto-mount` → rc=0, DDI at `/System/Developer`, idempotent across fresh boots.** See `scripts/patchers/cfw_patch_diskimagesiod.py`. |    Y    |  Y  |  Y  |
| 14  | Merge backboard/frontboard launch mach-services into `com.apple.security.exception.mach-lookup.global-name` + `ldid_sign_ent` re-sign — **iOS 27.0** | `/Applications/Campo.app/Campo` | **iOS-27 Campo (wallpaper renderer) crash-loop fix — sandbox half.** Campo declares `com.apple.private.sandbox.profile:embedded = temporary-sandbox` + `no-container`, so it runs under the `temporary-sandbox` profile. On the 26.4 vphone600 kernel that builtin profile predates iOS 27 and DENIES the `mach-lookup` of the backboard/frontboard launch services, so `BKSDisplayServicesStart` (looks up `com.apple.backboard.display.services`) and then `+[BKSHIDEventDeliveryManager sharedInstance]` (HID) fail, log *"backboardd isn't running -- or we couldn't talk to it"*, and `brk #0` ~34 ms after launch → continuous crash-loop, no wallpaper (launchd eventually throttles it off). **JB-02d is NOT sufficient here:** it stops the exec-time container-manager-upcall autobox *KILL*, but Campo is still placed in `temporary-sandbox` (its own declared profile — confirmed the JB-02d `b`-flip is present in the running kernel yet Campo still traps), and that profile still denies the lookups. Fix: append the needed services to Campo's OWN `com.apple.security.exception.mach-lookup.global-name` array — the Apple-sanctioned escape hatch, which `temporary-sandbox` honors (Campo already ships ~20 such exceptions; these launch services simply aren't among them because 27's profile allows them directly). Services added (backboard names exact, from `com.apple.backboardd.plist` MachServices): `com.apple.backboard.display.services`, `com.apple.iohideventsystem`, `com.apple.CARenderServer`, `com.apple.backboard.hid.services`, `com.apple.backboard.hid-services.xpc`, `com.apple.backboard.TouchDeliveryPolicyServer`, `com.apple.backboard.system-app-server`, `com.apple.backboard.watchdog`, `com.apple.backboard.oswatchdog`, `com.apple.backboard.altsysapp`, `com.apple.AttentionAwareness`, `PurpleSystemEventPort`, `PurpleWorkspacePort`, `com.apple.frontboard.systemappservices`, `com.apple.frontboard.workspace`, `com.apple.frontboardservices.systemappmanager`, `com.apple.frontboard.watchdog`. Merge is done by the external helper `scripts/patchers/campo_mach_lookup_exceptions.py` (Python `plistlib`, not `plutil` — the entitlement key contains dots that `plutil` keypaths would mis-split; idempotent, preserves the existing array); re-signed with the JB `signcert.p12` via `ldid_sign_ent` (AMFI enforcement is relaxed on the research VM, so the re-signed cdhash loads and the entitlements are honored). Applied at host-mount build time in `cfw_install_jb.sh` / `cfw_install_exp.sh` step **[JB-3b]**, **hard-gated to `27.*`** via the mounted rootfs `SystemVersion.plist` `ProductVersion` (same gate as the vpregister/DSC patches) — skipped entirely on 26.x/18.x, which don't need it and where `Campo.app` also exists. **VALIDATED on-device (2026-07-21, `17,3_27.0_24A5390f` + cloudOS 26.4, JB): Campo launches and stays up (stable pid, no BKSDisplayServicesStart/BKSHIDEventDeliveryManager trap, no crash-loop); first-cut display-only exception advanced the trap from display→HID, confirming the mechanism, then the full service set cleared it.** See `scripts/cfw_install_jb.sh` / `scripts/cfw_install_exp.sh` step JB-3b and the merge helper `scripts/patchers/campo_mach_lookup_exceptions.py`. |    -    |  -  |  Y  |
| 15  | Derive `matched` from `error_code` + drop the `brk #1` in libxpc `_xpc_token_satisfies_lwcr` (`cset w8,ne; eor w8,w0,w8; tbz w8,#0` → `cset w0,eq; nop; nop`) + per-page re-attest — **iOS 27.0** | DSC `libxpc.dylib` | **iOS-27 daemon crash-loop fix (Lightweight Code Requirement).** iOS 27 lets an XPC server pin a "lightweight code requirement" (LWCR) on its listener — `xpc_connection_set_peer_lightweight_code_requirement`, or the Swift `XPCPeerRequirement.hasEntitlement(_:)` wrapper (→ `xpc_peer_requirement_create_entitlement_exists` → `_xpc_peer_requirement_create_lwcr_entitlement_requirement` → `xpc_peer_requirement_create_lwcr`). Creating the requirement runs a self-check, `_xpc_token_satisfies_lwcr`, which calls an internal matcher returning a `matched` bool (w0) plus a `match_result.error_code` (`AICMR_MATCH == 0`), then hard-asserts they agree (`matched == (error_code == 0)`) via `_os_crash_msg` → `brk #1`. On stock iOS the two always agree; under our JB code-signing environment the matcher's query writes `error_code = MATCH(0)` yet returns a failure status, so the matcher yields the forbidden `(matched=0, error_code=0)` pair and libxpc aborts. Because EVERY daemon that pins an entitlement peer-requirement at startup hits it, `intelligencetasksd` / `searchpartyd` / `transparencyd` / `bluetoothd` (and others) crash-loop continuously from boot (launchd re-spawn + ReportCrash churn). Fix: recompute `matched` from `error_code` and make the abort unreachable — `cset w8,ne; eor w8,w0,w8; tbz w8,#0,<abort>` → `cset w0,eq; nop; nop`; the function now returns `(error_code == 0)`, which reproduces stock's verdict when the two agree and resolves the contradiction toward "satisfied" when error_code says MATCH (real allow/deny for genuinely (un)satisfied peers is unchanged, since those set `error_code` != 0). Fully dynamic: resolved via the DSC's own `.symbols` in-image local-symbol table as `__xpc_token_satisfies_lwcr` (the double-underscore mangled name; a single-underscore lookup silently skipped every iOS-27 build until fixed 2026-08-11), the check located by control-flow shape in Capstone (`cset wC,ne; eor wE,w0,wC; tbz wE,#0`), replacements from Keystone, modified 16 KiB page re-attested (`cfw_dsc_codesign.py`; TXM enforces per-page; CDHash change accepted by the JB always-true AMFI cdhash-trust patch). Install gate: **`27.*`** (in `cfw_install.sh`, same block as maxSlide/lsd). Patcher additionally self-gates (`patch-xpc-lwcr`): no-op on pre-iOS-27 userlands where the symbol is absent. **VALIDATED on-device (2026-07-22, `17,3_27.0_24A5390f` + cloudOS 26.4, JB, host-mount deploy): patched bytes live (`e0179f1a 1f2003d5 1f2003d5`); the four LWCR crash-loopers disappear from the crash census after boot; launchd itself (which links libxpc) boots clean past first unlock — patch does not brick boot. NOTE: does NOT stop the resprings — those are a separate `FileProviderResolver` ResolverService memory-balloon → jetsam → backboardd kill (see investigation notes).** See `scripts/patchers/cfw_patch_xpc_lwcr.py`. **FIX (2026-09-22):** same idempotence gap as row 12, and for the same structural reason: `_find_consistency_check` searches for `cset wC,ne; eor wE,w0,wC; tbz wE,#0`, which is precisely the idiom this patch replaces, so on a cache it had already patched the search returned `None` and raised `ValueError: LWCR consistency idiom ... not found`. The per-edit `already patched` byte comparison further down could never run, because it needs the addresses that search has to supply first. Hit live on `17,3_27.0_24A435` (RC) + cloudOS 26.4, JB, host-mount flow, when a first `cfw_install_host` pass completed phase 1/7 and then failed later at JB-1 (missing `insert_dylib`); the retry died here. Confirmed by read-only host-mount disassembly of `__xpc_token_satisfies_lwcr` @ `0x1805DD5BC`: `cmp w8,#0; cset w0,eq; nop; nop` — already patched. A new `_find_patched_shape` now recognizes that post-patch shape (`cset w0,eq` + two `nop`s, anchored on the `cmp wX,#0` that feeds it) and returns a no-op instead of raising. Checked against the live cache (dry run returns rather than raises) and with negative controls: fed the pre-patch stream the detector stays silent and the normal idiom search still matches, so the patching path is intact on a pristine cache. |    Y    |  Y  |  Y  |
| 16  | NOP the sysctl-error `b.eq <os_crash>` in libSystem `___os_lockdown_mode_enabled_block_invoke` (`cmn w0,#1; b.eq <crash>` → `nop`) + per-page re-attest — **iOS 27.0** | DSC `libSystem` (`lockdown_mode.c`) | **iOS-27 launchd (pid 1) boot-panic fix.** iOS 27's `os_lockdown_mode_enabled()` resolves Lockdown Mode once via `sysctlbyname("security.mac.lockdown_mode_state_public", &out, &len, 0, 0)`; on a -1 return it `os_crash`es (`lockdown_mode.c:os_lockdown_mode_enabled_block_invoke:47`). The vphone base kernel (cloudOS 26.x) does not implement that MAC sysctl, so the call returns -1/ENOENT and the first process to query Lockdown Mode after "Continuing system boot" aborts — that process is launchd (pid 1), so the kernel panics `initproc exited -- exit reason namespace 2 subcode 0x6 description: none`. b4 (24A5390f) boots on the same kernel; the sysctl query is new in b5 (24A5408d). The block pre-zeroes its output buffer (`stp x8, xzr, [sp]`), so NOPping the error branch falls through to the normal path, reads 0, records "Lockdown Mode disabled", and returns cleanly; on a kernel that implements the sysctl the branch is never taken (w0==0), so the patch is behavior-neutral. Dynamic: `___os_lockdown_mode_enabled_block_invoke` resolved via the DSC's own `.symbols` local-symbol table; the `cmn wR,#1; b.eq` sysctl-error idiom located by control-flow shape in Capstone; NOP from Keystone; modified 16 KiB page re-attested (`cfw_dsc_codesign.py`). Install gate: **`27.*`** (same block as maxSlide/lsd/lwcr). Self-gates: no-op where the symbol is absent (pre-iOS-27 userlands). **Root-caused + verified on-device 2026-08-11** (`17,3_27.0_24A5408d` + cloudOS 26.4, JB): abort message read live via the kernel GDB stub (patched `_abort`→`b .` to freeze launchd's spinning vCPU, then read its registers + the libSystem crash-info global) = `lockdown_mode.c:os_lockdown_mode_enabled_block_invoke:47: No such file or directory`; with the NOP applied the panic is gone and boot continues past "Got first unlock" into normal daemon startup. See `scripts/patchers/cfw_patch_lockdown_mode.py`. **FIX (2026-09-22):** third instance of the row-12 idempotence gap, found immediately after the row-15 one on the same `17,3_27.0_24A435` (RC) + cloudOS 26.4 JB host-mount re-run. `_find_error_gate` required the slot after `cmn wR,#1` to be a `b.eq`; once patched it holds the `nop` this patch writes, so the search returned `None` and raised `ValueError: ... sysctl-error gate not found` — again before the `cur == nop` byte comparison below it could ever be reached. Confirmed by read-only host-mount disassembly of `___os_lockdown_mode_enabled_block_invoke` @ `0x237EF2260`: `bl <sysctlbyname>; cmn w0,#1; nop` at `0x237EF2298`. The gate slot now also matches `nop`, which lets the existing byte comparison report the already-patched state; the `bl` + `cmn wR,#1` anchor is unchanged, and re-writing a NOP over a NOP is inert. Negative controls checked: an unrelated instruction in the slot, a `cmn` with no preceding `bl`, and a `cmn` with the wrong immediate are all still rejected, and the pre-patch stream still resolves to the `b.eq`. |    Y    |  Y  |  Y  |
| 17  | `mov x0,#0 ; retab` over the two instructions after the prologue `pacibsp` of `checkTrustAndAuthorization` — **all bases** | DSC `libmis.dylib` | **Free-certificate app-launch fix (online authorization).** A guest restored by this project is hacktivated — `mobileactivationd.should_hactivate` forces `-[DeviceType should_hactivate]` to YES so the VM never contacts Apple's activation service. The consequence nobody had traced until now is that it also never receives an **activation record**: `/private/var/root/Library/Lockdown/` holds `data_ark.plist`, `escrow_records` and `pair_records` but no `activation_records/`, while `data_ark.plist` still says `-ActivationStateAcknowledged = true`. With no activation record there is no device identity to sign an authorization request with, so the chain is `online-auth-agent: Failed to copy activation record.` (MobileActivation `-1`) → `Couldn't get device identity … "online-auth-agent is not allowed to use this API."` (MobileActivation `-25`) → `Could not perform authorization attempt`, and `Preferences: MDMProvisioningProfileTrust failed to verify provisioning profile <uuid> with error 4`. libmis's `checkTrustAndAuthorization` therefore returns `0xE8008026`, which SpringBoard reports as `validation failed because of missing trust and/or authorization (0xe8008026)` followed by `signature state: Profile Needs Network Validation, reason: Requires Network Validation`, and FrontBoard refuses the launch (`FBSOpenApplicationErrorDomain 3`, *"…or its profile has not been explicitly trusted by the user"*). **This only bites free personal-team profiles**; a paid team's profile is not marked as needing online authorization, and Settings' "Verify App" can never clear the free one because the network step it offers is exactly the step that cannot complete. **Not to be confused with `0xE8008012`** (`misagent: attempt to install invalid profile`), which is the ordinary "this UDID is not in the profile's `ProvisionedDevices`" refusal and is correct behaviour — installation itself needs no patch. Fix: short-circuit `checkTrustAndAuthorization` to return success. Its prologue seeds the failure code into the register it returns (`mov w21,#0x8026 ; movk w21,#0xe800,lsl #16`) and the body subtracts its way to the neighbouring MIS errors (`sub w21,w21,#0x2` → `0xE8008024`, `#0x25` → `0xE8008001`, `#0x9` → `0xE800801D`) or replaces it with 0; both call sites inside `MISValidateSignatureAndCopyInfoWithProgress` treat 0 as success. The two instructions after the prologue's `pacibsp` (`sub sp,sp,#0xa0` and `stp x28,x27,[sp,#0x40]`) become `mov x0,#0 ; retab`. **`pacibsp` is deliberately kept** rather than overwritten: it signs LR with SP as the modifier and `retab` authenticates against the SP it sees, so returning before the frame is built leaves the pair balanced — a plain `ret` over `pacibsp` would also work but makes the larger claim. The optional out-parameter is safe to leave unwritten: one caller passes NULL for it outright (`mov x5,#0`), the other pre-zeroes the slot (`str xzr,[sp,#0x68]`) and skips the merge while it is still NULL (`cbz x8`). Fully dynamic, and the function is **static — it carries no symbol**, so neither the cache's `.symbols` table nor `ipsw symaddr` can name it: it is anchored instead on the log string that names it outright, `"cdHash (%p) or matchedProfileIDs (%p) NULL in checkTrustAndAuthorization"` (one of four `checkTrustAndAuthorization` / `checking trust and authorization` literals, all four of which xref inside this one function), whose containing image is confirmed to be `/usr/lib/libmis.dylib` via `findMachOHeaderBefore` + `readInstallName`; the ADRP+ADD pair that materialises the literal is matched on Capstone operand semantics, the nearest preceding `pacibsp` gives the function start, and that prologue is then **required** to seed `0xE8008026` within 48 instructions before anything is written — two independent routes that must agree, in the manner of `CustomFirmwareMobileActivation.locateIMP`. Replacement bytes are `ARM64.movX0_0` + `ARM64.retab`, both existing keystone-checked constants (no new encoder, no keystone trip). Modified 16 KiB page re-attested. **Install gate: none, but OFF in `standard` since 2026-09-30** — the guest is hacktivated on every base, so the failure exists on every base; the declaration (`dyld-exp-mis_trust_auth`, in `com.vphone.patchset.guest.system`, renamed from `dyld-cfw-` when it left `standard`) carries no `applicability` and is not `bootEssential`. See "The MIS online-authorization patch leaves `standard`" at the end of this document for why it is now opt-in and what replaced it. Self-gating: a cache whose libmis lacks the naming literal reports absent and exits 0, an already-patched cache is a no-op (the byte comparison is against this patch's own output), and a cache with the literal but **neither** the seeding prologue **nor this patch's own `pacibsp ; mov x0, #0 ; retab`** is an **error** rather than a guess. **The second half of that sentence is a fix, made 2026-09-30 for issue #532, and it matters:** `locateSite` originally *required* the seed, and the seed is not guaranteed to outlive the write. On the 26.6.2 cache the compiler puts it at `functionVMA + 0x4C` (`checkTrustAndAuthorization @ 0x1BC6AE364`, seed at `0x1BC6AE3B0`), well clear of the two words at `+4`, so the byte comparison saw its own output and a second `cfw install` was already a no-op. On the 27.0 guest in the report the seed *was* the two words this patch overwrites (`checkTrustAndAuthorization @ 0x22406F814`), the first run destroyed it, and every later run died with `Patch site not found: … does not seed 0xE8008026 — MIS has been rewritten`, taking the whole install down after `dsc_maxslide` and before everything that follows. `DyldSharedCacheMISTrustAuthPatcher.isShortCircuited` now recognises the patch's own three words off the Capstone decode (`pacibsp`, `mov` with decoded destination `x0` and decoded immediate 0, `retab`) — the same "recognise your own output" fix `DyldSharedCacheXPCLWCRPatcher.findPatchedShape` and `DyldSharedCacheLockdownModePatcher.findErrorGate` got on 2026-09-22 — and `Site.shape` now carries `.seedsFailure(seedVMA:resultRegister:)` or `.alreadyShortCircuited` instead of a non-optional seed address. The genuine "MIS has been rewritten" hard failure is unchanged for a prologue that is neither shape. Covered by `DyldSharedCacheMISTrustAuthPatcherTests`, which builds a synthetic one-chunk cache (mapping table, `LC_ID_DYLIB` = `/usr/lib/libmis.dylib`, the naming literal, an ADRP+ADD that materialises it, and a real `CS_CodeDirectory` with SHA-256 page slots) in **both** seed layouts, because the 24A435 fixture can only exhibit the one that already worked. **VALIDATED on-device (2026-09-30, `iPhone17,3 26.6.2 (23G90)` + cloudOS 26.4 (23E5207q), JB, fresh `vm new` → `fw patch` → `restore` → `cfw install` into a new VM `05-mis-test`): an app signed with a free personal-team certificate now installs, verifies, launches, and Xcode `attach` to it succeeds.** The shape was first derived statically, from the `libmis.dylib` Xcode extracted from the live guest `01-use-me-rh` (`iPhone99,11 26.6.2 (23G90)` + cloudOS 26.4) into `iOS DeviceSupport/…/Symbols/usr/lib/`, where the two `#0x8026` immediates in the entire library are both inside this function; the patcher then reached exactly that site through the DSC chunk path, with both routes agreeing — `checkTrustAndAuthorization @ 0x1BC6AE364 in /usr/lib/libmis.dylib`, named by the literal referenced at `0x1BC6AE6B4`, prologue seeding `w21=0xE8008026` at `0x1BC6AE3B0`, written at `0x1BC6AE368` — and one 16 KiB page re-attested (slot 3260 of `dyld_shared_cache_arm64e.19`). The guest then booted normally through Setup Assistant to the home screen, so TXM accepts the re-attested page: the patch does not brick boot **on 26.6.2**. **It does on 27.0** (issue #532, `17,3_27.0_24A435` + cloudOS `26.4-23E5207q`): `TXM [Error]: Errno: selector: 45 | 78`, then `dyld[1]: Library not loaded: /usr/lib/libSystem.B.dylib … (no such file, no dyld cache)`, then `initproc failed to start`. Excluding only `mis_trust_auth` boots. That is not reproducible here — no 27.0 guest exists on this machine — so it is reported, not measured. **The direction taken is to stop editing the cache for this and express the same behaviour as a userspace hook instead**, and the disassembly says that is possible *without* rewriting any return value, because the whole branch is reachable from the caller's options dictionary. Read off libmis on `01-use-me-rh` (`iPhone99,11 26.6.2 (23G90)`, `MISValidateSignatureAndCopyInfoWithProgress @ 0x1BC6ABA4C`): the options are parsed into stack bytes by a `getBoolOption(dict, CFStringRef, char *out)` helper (`0x1BC674C60`) that **writes only when the key is present**, so every flag defaults to 0; `UnauthoritativeLaunch` or `AuthoritativeLaunch` then force `RespectUppTrustAndAuthorization = 1`, `HonorBlocklist = 1`, `ValidateSignatureOnly = 1`, `OnlineAuthorization = 0` as a *default set* that an explicit key still overrides; the explicit `RespectUppTrustAndAuthorization` read lands in `[sp+0x97]`, and `checkTrustAndAuthorization` is **only called at all** when the word derived from it (`[sp+0x2C]`) is nonzero — `ldr w8,[sp,#0x2c] ; cbz w8, <skip>` immediately before the call at `0x1BC6ACCE8`. Passing `RespectUppTrustAndAuthorization = kCFBooleanFalse` therefore skips the call, and `0xE8008026` cannot be produced on this path. Inside the callee the same flag arrives twice — `w4` gates the trust/authorization tests that re-seed `0xE8008026`, `w3` (`respectUpp && !predicate`) gates the second test whose failure yields `0xE8008025` — and `w2` is `HonorBlocklist`, forwarded to `appApprovalState`, whose states map to `0xE8008024` (2), `0xE800801D` (4) and `0xE8008001` (unknown). One route already exists in stock code: at `0x1BC6ABEE4` libmis asks MobileGestalt `IsVirtualDevice` and, when that is true **and** a second answer compares equal to `CFSTR("Internal")`, forces `RespectUppTrustAndAuthorization = 0` and `OnlineAuthorization = 0` outright — worth probing before any hook is written. **A hook must steer the call, not the return:** on the `0xE8008026` path the function logs `validation failed because of missing trust and/or authorization (0x%x)` and branches straight to the shared cleanup at `0x1BC6ABB48`, which releases and returns the status **without ever writing the `info` out-parameter** — the dictionary carrying `CdHash`, `Entitlements`, `SignerType`, `TeamID`, `SigningID`, `ProfileUUID` and the rest is built only on the success path at `0x1BC6ACF74`. Rewriting the return code to 0 would hand the caller success with an untouched `info`. **That hook now exists and ships** — `libmisfix.dylib` (`VPhoneGuestComponents/MISFix/MISFixSignature.c`) passes `RespectUppTrustAndAuthorization = kCFBooleanFalse` alongside `AllowAdHocSigning`, and `cfw install` injects it into `installd` and `misagent` — which is why this patch left `standard`. See `DyldSharedCacheMISTrustAuthPatcher` and the `cfw patch-mis-trust-auth` verb. |    Y    |  Y  |  Y  |
| 18  | **Superseded 2026-09-30 — no load command any more; the spawn hooks insert libmisfix, see "One route for libmisfix, SpringBoard included".** `LC_LOAD_WEAK_DYLIB /usr/lib/libmisfix.dylib` injected into `installd`, which interposes `MISValidateSignatureAndCopyInfo` and `MISValidateSignatureAndCopyInfoWithProgress` — **all bases** | `/usr/libexec/installd` (+ new guest dylib `libmisfix.dylib`) | **Xcode-install fix: let the guest install an app it did not get from Apple.** `xcrun devicectl device install app` with a bundle that is ad-hoc signed, fake-signed or signed by anything other than an Apple leaf fails at `0xE8008014`. Measured, not inferred: a probe app linked against `libmis` on `05-mis-test` (`iPhone99,11 26.6.2 (23G90)` + cloudOS 26.4) walked the option matrix over a real `.app` and found that **the whole gate is this one call** — no options → `0xE8008014`; `AllowAdHocSigning = kCFBooleanTrue` → **`0x0` with a complete `info` dictionary** (`CdHash`, `SignerType`, `SigningID`, `TeamID`, `SignatureVersion`, `IsNativeForPlatform`), so the hook has to synthesise nothing and the `info`-out-parameter hazard that rules out rewriting row 17's return value does not arise here; and stripping the signature off entirely is *not* a way through — that stays `0xE800801C` even with the option. Everything behind the call already accepts uncertificated code on a CFW guest (kernel AMFI, `lsd`, SpringBoard), so nothing else needs patching. Two findings cost real time and are recorded so nobody repeats them: **the first argument is a path `CFStringRef`, not a `CFURLRef`** — passing a URL crashes the caller with `-[NSURL length]: unrecognized selector`; and **the option keys are plain `CFString`s, not exported symbols** — `kMISValidationOptionAllowAdHocSigning` is absent from the cache's export trie, so grepping for the symbol says "this option does not exist on 26.6.2", which is wrong. The keys `libmis` parses are `UnauthoritativeLaunch`, `AuthoritativeLaunch`, `ExpectedHash`, `AllowAdHocSigning`, `ValidateSignatureOnly`, `LogResourceErrors`, `UniversalFileOffset`, `UseSoftwareSigningCert`, `OnlineAuthorization`, `OnlineCheckType`, `RespectUppTrustAndAuthorization`, `HonorBlocklist`, `DetachedSignature`, `TrustCacheOnly`, `SkipProfileIdentifierPolicy`, `AllowLaunchWarnings`, `GetLocalLaunchWarningData`, `MainExecutablePath` and `OnlineAuthorizationOnAllMatchingProfiles`. Fix: `vpWidenedOptions` copies the caller's dictionary (or creates one when it is NULL), sets `AllowAdHocSigning = true` and `RespectUppTrustAndAuthorization = false`, and forwards. The second key is row 17's behaviour expressed from the caller's side — same outcome, **no cache page written and no re-attestation**, which is the whole point given that row 17 is what bricks a 27.0 boot (issue #532). Delivery is `dyld` interposition: `__DATA,__interpose` lands in `__AUTH_CONST` on arm64e (signed pointers) and dyld honours it anyway, including for the shared cache's own uses of the interposed symbol — measured on `05-mis-test`, a linked call with no options returns `0x0` hooked against `0xE8008014` unhooked. The dylib is built by `VPhoneGuestComponents/Makefile` against `libmis.tbd` and `libMobileGestalt`, with `-Wl,-not_for_dyld_shared_cache`, and installed as `/usr/lib/libmisfix.dylib`; injection goes through the existing `patchMachO(… injectedDylibPath:)` path, which captures entitlements before the edit and re-signs with `VPhoneSigner` afterwards — verified to preserve `com.apple.installd` and all 31 of installd's entitlements. **Not applied to SpringBoard**, which would close the free-personal-team *launch* gate the same way: SpringBoard's Mach-O has no free header space (`load-command padding at 0x548 is not empty; inserting would overwrite 56 bytes of the first section`), so that path needs the `SystemHook` `posix_spawn` route instead and row 17 remains the only fix for it today. Declared `system-installd-cfw-adhoc_signature` in `com.vphone.patchset.guest.system`; no `applicability`, not `bootEssential`, on in `standard`. **Partially validated (2026-09-30, `06-xcode-27`, `17,3 27.0 (24A435)` + cloudOS 26.4 (23E5207q)):** `cfw install` reports `[+] LC_LOAD_WEAK_DYLIB /usr/lib/libmisfix.dylib -> installd`, the guest boots through Setup Assistant to the home screen, and `installd` is running with the dylib loaded — so the injection breaks neither the daemon nor the boot. The end-to-end install has **not** been demonstrated on that guest: `devicectl` will not complete a session against it on this host (`device info details` hangs with nothing reaching `lockdownd`), which is a host-side CoreDevice problem unrelated to this patch. See `VPhoneGuestComponents/MISFix/MISFixSignature.c` and `Research/Guest/xcode_install_signature_gate.md`. |    Y    |  Y  |  Y  |
| 19  | **Superseded 2026-09-30, as row 18.** The same `libmisfix.dylib` injected into `misagent`, where it interposes `MGCopyAnswer` / `MGCopyAnswerWithError` and answers `UniqueDeviceID` from a config file — **all bases** | `/usr/libexec/misagent` (+ `/usr/lib/libmisfix.plist`) | **Let a provisioning profile written for a device you already own install on the guest.** `0xE8008012` (`misagent: attempt to install invalid profile`) is the ordinary refusal when the profile's `ProvisionedDevices` does not list this device — correct behaviour, and distinct from row 17's `0xE8008026`. It blocks the case the user actually wants: reusing a paid team's already-registered device rather than burning a registration slot on every VM. The UDID being compared comes from `MGCopyAnswer(kMGUniqueDeviceID)`, and three cheaper routes were ruled out by measurement before any hook was written. (1) **AMFI cannot supply it**: `security.codesigning.config` is a 4-byte flags word (read back as `0x000000CC`), not a string, so `amfi_emulate_device_udid` is dead on this board. (2) **No daemon can write it**: `/private/var/root/Library/Lockdown/data_ark.plist` carries no `UniqueDeviceID` — lockdown derives it each boot. (3) **The real source is out of reach**: TXM composes `UniqueDeviceID` from the device tree's `/chosen/chip-id`, `/chosen/unique-chip-id` and `/product/udid-version` *before the kernel runs*, and `chip-id` is fixed at `0x0000FE01` while `unique-chip-id` is the ECID the SHSH blob is bound to — changing it means the VM no longer restores. So `MGCopyAnswer` is necessarily where this is done. Fix: interpose it in `misagent` only, return a `+1` copy (matching `MGCopyAnswer`'s contract) of the configured string for `UniqueDeviceID`, and fall through untouched for every other property. Configuration is `/var/db/vphone/misfix.plist`, falling back to `/usr/lib/libmisfix.plist`, cached against mtime and size so editing the file takes effect on the next query with no restart — that is the "put it in the plist and it applies" entry point. The shipped plist is **empty**: with no `UniqueDeviceID` key the interpose returns NULL and the patch is inert, so it changes nothing until someone deliberately pastes a real device's UDID in. `installMISFixDefaults` writes the fallback plist **only when it is absent**, so re-running `cfw install` never clobbers a configured value. **Accepted inconsistency, agreed with the user rather than hidden:** only `misagent`'s profile matching sees the borrowed UDID. Xcode, lockdown and `devicectl` keep reporting the VM's own (`0000FE01-…`), because those come from a different process that is not hooked. The two therefore disagree, which is exactly what makes the profile match while the device stays identifiable as itself. Declared `system-misagent-cfw-device_identity` in `com.vphone.patchset.guest.system`; no `applicability`, not `bootEssential`, on in `standard` but inert without a configured UDID. **Partially validated (2026-09-30, `06-xcode-27`):** `cfw install` reports `[+] LC_LOAD_WEAK_DYLIB /usr/lib/libmisfix.dylib -> misagent` and `misagent` runs normally on the booted guest. Installing a real paid-team IPA against a borrowed UDID is **not** yet demonstrated, for the same host-side `devicectl` reason as row 18. See `VPhoneGuestComponents/MISFix/MISFixDeviceIdentity.c`, `MISFixConfig.c` and `Research/Guest/xcode_install_signature_gate.md`. |    Y    |  Y  |  Y  |
| 20  | No binary change: the launchd hook inserts `libmisfix.dylib` into `SpringBoard` at spawn, beside SystemHook, and both spawn hooks do the same for `installd`, `misagent`, `lockdownd` and `remoted` (the last two for the UDID override only) — **all bases** | none (the guest environment's `launchdhook-vphone.dylib` and `SystemHook-vphone.dylib`) | **Let an installed developer-signed app launch.** SpringBoard validates the app with MIS again before launch and, on a hacktivated guest, fails row 17's `checkTrustAndAuthorization` with `0xE8008026` ("Unable to Verify App"). The hook's `MISValidateSignatureAndCopyInfoWithProgress` detour passes `RespectUppTrustAndAuthorization = false`, so the check is never called — row 17's effect with no shared-cache write, which is what makes it usable on 27.0. launchd starts SpringBoard itself rather than through xpcproxy, so the libraries it gets are the launchd hook's choice; that hook now asks the same `vpIsMISFixTarget` SystemHook does. `MISFixInstallPolicy` stays out of it. No declaration of its own: it ships with `system-launchdaemons-boot-environment`. A load-command version (`/mf` alias, `LC_SOURCE_VERSION` dropped) was committed and reverted the same day. See "One route for libmisfix, SpringBoard included (2026-09-30)" below. |    Y    |  Y  |  Y  |
| 21  | No binary change: SystemHook `dlopen`s `libhapticsfix.dylib` into `SpringBoard` at startup, where it replaces every `CHHapticEngine` initialiser's IMP so the initialiser returns nil — **all bases** | none (new guest dylib `VPhoneGuestComponents/HapticsFix/libhapticsfix.c`, installed at `/usr/lib/libhapticsfix.dylib`) | **Stop SpringBoard dying the first time UIKit plays a haptic.** The VM has no haptic device — Virtualization.framework exposes none on any base — and a real device without one gets nil from `CHHapticEngine`'s initialisers, so UIKit runs with no feedback, as on every non-Pro iPad. A guest reporting an iPad Pro model instead has an OS that *expects* the haptic stack, and CoreHaptics treats its absence as an internal error: measured on `iPad16,1 26.6.2 (23G90)`, 4h14m after launch, the first feedback event ran `-[_UIFeedbackCoreHapticsIgnoreCaptureHapticsOnlyEngine _internal_createCoreHapticsEngine]` → `-[CHHapticEngine initWithAudioSession:sessionIsShared:options:error:]` → `createHapticPlayerWithOptions:` → `Haptic_RaiseException` → `objc_exception_throw`, and the unwind resumed at an address inside a `---/---` Memory Tag 255 COW region next to the commpage — `EXC_BAD_ACCESS (SIGBUS)`, `KERN_PROTECTION_FAILURE`, a dead SpringBoard. The hook restores the no-hardware answer before UIKit can reach an initialiser: the constructor `dlopen`s CoreHaptics (it is not loaded that early, and the class must be in the runtime before UIKit asks), then `method_setImplementation` on every selector that is `init` or `init` + uppercase part — covering `initWithAudioSession:sessionIsShared:options:error:` today and any renamed sibling on other bases — with one IMP that ignores its arguments and returns nil, the framework's own answer on haptic-less hardware. Scope is SpringBoard only (`vpIsSpringBoard` in SystemHook, loaded before the app/bootstrap gate that would otherwise return first): it is the one UIKit process measured creating the haptics-only engine without asking CoreHaptics first, and apps that follow the documented `capabilitiesForHardware` path already answer no on the guest. Loaded like the camera hooks rather than inserted like libmisfix because interposing must be in place at launch while a method swizzle just has to run before first use; `DISABLE_TWEAKS` and safe mode skip it with everything else SystemHook loads. Ships with `system-launchdaemons-boot-environment`; existing guests receive it through the vphoned environment update (a missing file reports no hash, which is what triggers the push) and need a respring, which is deliberately the caller's call. See `VPhoneGuestComponents/HapticsFix/libhapticsfix.c`. |    Y    |  Y  |  Y  |
| 22  | No binary change: `libvcamcaptured.dylib` (already loaded into `cameracaptured` by SystemHook) wraps `+[FigCaptureSourceBackingsProvider sharedCaptureSourceBackingsProvider]` from its constructor; when the original returns nil it returns a microphone-only provider instead — **iOS 26.6+ layout, measured on iOS 27.0** | none (`VPhoneGuestComponents/VCamCaptured/Microphone/VCamMicrophoneSource.m`) | **Give an audio-only `AVCaptureSession` its microphone on a guest with no camera.** The built-in sources come from one provider that CMCapture builds only after `BWFigCaptureDeviceVendor` creates the `Default` camera device; a VM has no ISP plugin, so `Cannot create device without create function!`, -12786, `Wiping com.apple.cameracapture.volatile`, and no provider — the microphone, described by the same `AVCaptureSession.plist` call, is lost with the camera, and iOS 27 Voice Memos fails with `CaptureSessionRecorderError` 1 (`failedToCreateAudioDevice`). The wrapper feeds the exported `FigCaptureCreateSourceInfoArrayFromDeviceAndModelSpecificPlist` a NULL device and the shipped product plist (the guest's own `VPHONE600` has none; `D47` on the iPhone17,3 image) reduced to its `"soun"` entries, without persisting, and builds the provider with `-initWithSourceInfoDictionaries:commonSettings:`. A provider the daemon built itself passes through untouched. While that provider is in use, the same dylib also makes `-[AudioRemixSessionManager startNewSessionBlocking]` report success (0) without building the SoundAnalysis Audio Mix session, whose neural net faults cameracaptured 2 s into every spatial recording on the guest (`BNNSGraphContextMakeStreaming`, `KERN_INVALID_ADDRESS 0x300`). Success, not an error: `BWAudioRemixAnalysisMetadataNode` forwards a Stop marker on its metadata output only when the next session starts, and an error there left the movie-file sink waiting forever (measured with the first version, which returned -16992). With no session the node passes audio through and the Audio Mix metadata track is written without samples. It also logs the level of the audio passing the node. `VCamCaptured/Microphone/VCamMicrophoneRemix.m`. See `Research/Guest/ios27_capture_microphone_source.md`. |    Y    |  Y  |  Y  |
| 23  | No binary change: `libvcamcaptured.dylib`, which SystemHook already loads into `cameracaptured`, rewrites the `bl PrewarmThreadSafeSBPs` in `__FigCapturePreloadShadersInternal_block_invoke_2` to `nop` in the daemon's own memory. This runs from the dylib's constructor and only when the paravirtual Metal driver is installed — **all bases** | none (guest dylib `VPhoneGuestComponents/VCamCaptured/Prewarm/`, installed at `/usr/lib/libvcamcaptured.dylib`) | **Stop `cameracaptured` crashing at every boot, and the SpringBoard freeze that follows.** At launch the daemon preloads its shaders. `PrewarmThreadSafeSBPs` runs each video processor's `-prewarm`, and NRFV3's reaches `-[ToneMappingCurves initWithWithContext:]`, which fills textures made from a shared `MTLHeap` with `-replaceRegion:…`. The cloudOS 26.4 `AppleParavirtGPUMetalIOGPUFamily` never sets `_dimension` (a texture's CPU layout) in `-initWithHeap:resource:offset:length:descriptor:`, and `-replaceRegion:` loads it unchecked, so the daemon faults with `KERN_INVALID_ADDRESS` at `0xc` (measured on `iPad16,1 26.6.2 (23G90)`, `standard`: launchd at `successive crashes = 6`). While the daemon crash-loops, SpringBoard's main thread blocked in a synchronous XPC to it as soon as an app started recording. The daemon does have a Metal device, so `kernel-exp-paravirt_user_clients` does not help. Prewarming is only an optimisation, and nothing waits on that function: no return value, no global, no signal. The rest of the preload (processor flags, data migration, and the deferred shader cache copy, whose semaphore deferred processing waits on) is kept. The call site is found from the exported `FigCapturePreloadShaders`: its `b` to the internal function, that function's one `adrp/add/pacia x16` block invoke, then the block's one `ldr x0, [xN, #0x20]; bl` into CMCapture's `__text`. That gives `0x1aeb2fd68` on 23G90 and `0x1b0759d10` on 24A435. Any mismatch leaves the prewarm in place and logs the step that failed. Host test: `make -C VPhoneGuestComponents test-vcam-prewarm`. Validation: `vcamcaptured.log` has `gpu prewarm: … skipped`, no new `cameracaptured` crash report, and `successive crashes = 0`. See `Research/Guest/gpu_acceleration.md` ("Heap Textures Have No CPU Layout"). |    Y    |  Y  |  Y  |
| 24  | No binary change: both spawn hooks insert `libbatteryhealthfix.dylib` into `Settings` (`/Applications/Preferences.app/Preferences`) beside SystemHook, where it interposes `IOPSCopyPowerSourcesInfo`, `IOPSCopyPowerSourcesByType`, `IOPSCopyPowerSourcesByTypePrecise`, `notify_register_check` / `notify_get_state` / `notify_cancel` and `MGGetBoolAnswer` — **all bases** | none (new guest dylib `VPhoneGuestComponents/BatteryHealthFix/libbatteryhealthfix.c`, installed at `/usr/lib/libbatteryhealthfix.dylib`) | **Stop Settings → Battery → Battery Health & Charging loading forever.** The VM's battery is Virtualization.framework's synthetic power source (charge and connectivity only), and the health half of a real battery's description comes from AppleSmartBattery, which no VM has. Measured on `iPhone17,3 27.0 (24A435)`: powerd's internal battery description has one `BatteryPacks` entry holding only `PackID`, `Cycle count` and `Transport Type`, no `Battery Service State`/`Flags` or `Maximum Capacity Percent` anywhere, and `com.apple.thermalmonitor.ageAwareMitigationState` stays 0. `-[BatteryHealthUIController specifiers]` asks `-[BatteryHealthUIInformation batteryDataUnavailable]`, which answers YES while `+getManagementState` is 0, while no pack parses (`-[BatteryHealthUIPackInformation initWithPowerSourceInformation:]` drops a pack without service flags and state), or while the overall genuine status is -1 — and it is -1 because `MGGetBoolAnswer("D6/BMDrlb8V3WSiqL8gL+w")` (HasBatteryModuleAuth, `+[PLGestaltUtilities hasBatteryModuleAuth]`) answers 1 on the guest, sending `+genuineBatteryStatusForPackIndex:` to an `AppleBatteryAuth`/`AppleAuthCPRelay` service that does not exist. The controller then shows its global spinner and re-asks on a timer. iPadOS 26.6.2 (23G90) has the same gate in `+[BatteryUIResourceClass batteryDataUnavailable]`, reading the flat keys of `IOPSCopyPowerSourcesByType`'s array, the same notify name and the same MobileGestalt key. The hook answers as a new battery without battery authentication: each internal-battery description is copied with `Battery Service State` 0, `Battery Service Flags` 0, `Maximum Capacity Percent` 100 and `Cycle count` 0 at the top level, and each of powerd's packs (or one new pack) completed with a `BatteryHealth` dictionary of the same three numbers plus `Date of manufacture`/`Date of first use` (the birth time of `/private/var/mobile`, i.e. the restore); keys already present are never replaced, and a description that already has them is passed through. A mitigation state of 0 on a token registered for the age-aware name reads as 2 ("supporting normal peak performance"). HasBatteryModuleAuth reads as no only while `IOServiceGetMatchingService("AppleBatteryAuth")` finds nothing. Interposing reaches the callers because `BatteryUsageUI.bundle` is a standalone Mach-O bound through dyld's interposing table (cache-to-cache calls are not; see `MISFix/MISFixSignature.c`), and inserting it — rather than SystemHook `dlopen`ing it like row 21 — is what puts the table in place before the bundle loads. `vpInsertedLibraryFor` in `Shared/InjectionEnvironment.h` picks it or libmisfix for a path; the two target sets do not overlap. Ships with `system-launchdaemons-boot-environment`; existing guests get it from the vphoned environment update on their next start with the new bundle (offline `cfw update-environment` only replaces libraries a VM already has). launchd starts Settings itself, so it is the launchd hook that inserts it: a guest updated only by that online sync needs one more reboot before launchd runs the new hook, which the update already reports as `reboot_required`; an offline environment update replaces the hook before boot. **Validated (2026-10-04, `bhtest-iphone`, `iPhone17,3 27.0 (24A435)` + cloudOS 26.4):** before, the page showed only the spinner and the two charging switches; after, Maximum Capacity 100%, Peak Performance Capability "Your battery is currently supporting normal peak performance", the two switches, no spinner; the hook's log shows all three answers taken once per process. Re-checked on the final bundle after a reboot of the same guest, with the launchd hook logging `inserted+batteryhealthfix` for each Settings launch. **iPad16,1 26.6.2 (23G90), `bhtest-ipad`, created with the new bundle:** the hook is inserted and stays inert, and Settings runs without a crash; that iPad has no Battery Health page at all, because `-[BatteryUIController setUpBatteryHealthGroup]` offers the row only on an iPhone or, through `+[PLBatteryUIBackendModel shouldShowModifiedHealthController]`, on an iPad that supports the fixed charge limit with the `PerfPowerServices/battery_health_details` feature on — the model decides, as on hardware. The 26.x gate inside the page is from static analysis; no 26.x iPhone image was at hand to run it. |    Y    |  Y  |  Y  |
| 25  | No binary change: `libvcamcaptured.dylib` stops every other thread in `cameracaptured` (`task_threads` + `thread_suspend`, self excluded, one patcher at a time) around each `vcc_patch_word` / `vcc_patch_two_nops` text rewrite — **all bases** | none (guest dylib `VPhoneGuestComponents/VCamCaptured/Image/VCamCodePatch.m`, installed at `/usr/lib/libvcamcaptured.dylib`) | **Stop the hook's own runtime patching from crashing `cameracaptured`, which froze the whole VM when the camera was opened.** The hook rewrites CMCapture shared-cache `__text` through `vm_protect(RW|COPY)` → write → `vm_protect(RX)`; for the whole flip the 16K page carries no execute permission, and the pages it touches (the `-12783` error-code sites, the master-clock gate, the prewarm call) are live XPC server code. Two crash reports caught a thread fetching an instruction in a page mid-flip while the patching thread was in `vcc_patch_word` on the same boot: `ipad-mini-01` `cameracaptured-2026-10-03-045638.ips` died in `__FigFlashlightGetClassID_block_invoke` on `com.apple.coremedia.flashlight(34)-messages`, and `ipad-pro-13` `cameracaptured-2026-10-04-225558.ips` died in `captureSourceServer_handleRegisterNotificationForProprietaryDefaultChangesMessage` on `com.apple.coremedia.capturesource(523)-messages` — the register-for-source-changes XPC that camera enumeration itself sends. Both are `EXC_BAD_ACCESS (SIGBUS)`, `KERN_PROTECTION_FAILURE` on an instruction fetch, in a region snapshotted `r-x/rwx`, `SM=COW` (the rwx max-protection is the flip's fingerprint). The card: with row 23 removing the boot crash, any later `cameracaptured` restart (jetsam, another crash) while a camera client reconnects sends its first XPCs straight into the +3 s reinstall window; one SIGBUS → launchd throttles → every AVCapture client, SpringBoard's main thread included, blocks forever in a synchronous XPC — the "VM 卡死" report of 2026-10-05. The stopped section is exactly two `vm_protect` calls, the word write and `sys_icache_invalidate`: no locks, no allocation, no logging, so a frozen thread holding any userspace lock cannot deadlock the patcher; every `vcc_log` moved after the resume, and a mutex serialises patchers (constructor prewarm patch vs the +3 s install block). All five runtime text-patching call sites (`vcc_scan_and_patch` ×2, the prewarm NOP, the session-hook pair, the source-installation NOPs) funnel through the two fixed functions. Validation: kill-and-relaunch stress with Camera.app auto-reconnecting (the same collision that produced both crashes) produces no new `cameracaptured` crash report, and the boot log's `patch_word OK` lines are unchanged. See `Research/Guest/virtual_camera_transport.md` ("The patch race that froze the whole VM"). |    Y    |  Y  |  Y  |
| 26  | No binary change: both spawn hooks insert `libdevicehubfix.dylib` into `cryptexd`, the DDI's `dtremotedisplayd` and `dtdeviceinfod`, and `avconferenced`. In `cryptexd` it interposes `fcntl` and reports an `EPERM` from `F_SETPROTECTIONCLASS` as `ENOTSUP`; in `dtremotedisplayd` it interposes `MediaStreamSupportedFeatures.current` (answers `0x8c`) and `CurrentDevice.isCustomerRestricted` (answers false) from the DDI's `CoreDeviceUtilities`; in `dtdeviceinfod` it interposes `MGCopyAnswer` and fills a missing `FramebufferIdentifier` for `phone11` chrome; in `avconferenced` it replaces `VCPSideCarMetal`'s two band reads through the Objective-C runtime and runs one synchronous scaler transform before the first read of each frame — **all bases** | none (new guest dylib `VPhoneGuestComponents/DeviceHubFix/libdevicehubfix.c`, installed at `/usr/lib/libdevicehubfix.dylib`) | **Let Xcode 27's DeviceHub show the guest's screen.** On iOS 27 `cryptexd` stages each DDI asset with `open(O_RDWR)` + `fcntl(F_SETPROTECTIONCLASS, 4)` and accepts only `ENOTSUP` as a failure; a guest answers `EPERM` (`set protection class: [1: Operation not permitted]`, `staging failed`), so CoreDevice shows the device as "connected (no DDI)" for good. With the DDI mounted, DeviceHub asks `dtremotedisplayd` for its media stream features and gets 0 from CoreDeviceUtilities' policy: `isCustomerRestricted` (`isProductionFused && !hasInternalOSBuild && hasInternalDDI == false`) refuses every pre-27.0 device, and remote control is limited to iPhone, Apple Watch and Apple TV, which refuses every iPad. `0x8c` is what a Mac host reports for itself (mirrored primary display 0x4, system audio 0x8, display information 0x80). The 27.x iPhone guest reports `phone11` chrome with no `FramebufferIdentifier`, so DeviceHub drew the screen over the bezel corners; the hook answers only that missing key with Xcode's matching mask `4E5532ED-1470-47D1-BDF4-7AA90C26957A` from `/Library/Developer/DeviceKit/chrome_map.plist`. Interposing reaches all of them because `cryptexd`, `dtremotedisplayd`, `dtdeviceinfod` and `CoreDeviceUtilities` are standalone images; the two Swift symbols are weak flat-namespace imports, resolving to nothing outside `dtremotedisplayd`. On 27.x the view also needs row 11's conditional dispatch, or the capture display stays black. A stream that splits each frame into four bands (`tilesPerFrame` 4) deadlocked the host GPU within 16–35 s of screen activity: `VCPSideCarMetal` reads every frame once per band while the paravirtual scaler's write of that frame can still be unregistered on the host, and a band read that registers the first of the frame's two planes before the write and the second after it waits on the write, which waits on it (`Timeout in timestamp wait`, the guest loses its GPU). Waiting for one synchronous transform puts the band reads behind the frame's write. `VideoProcessing` is in the shared cache, so this part is a method replacement, not an interpose. Ships with `system-launchdaemons-boot-environment`; an existing guest gets it from the environment update. Details: `Research/Guest/devicehub_screen_viewing.md`. **Validated (2026-10-06/07):** `iPad16,1 26.6.2 (23G90)`: DeviceHub receives `supportedFeatures: 140`, `MediaStreamStart` succeeds and the view shows the live home screen. `iPhone17,3 27.0.1 (24A446)`: the DDI mounts (`F_SETPROTECTIONCLASS EPERM, reported as ENOTSUP`), and with row 11's conditional dispatch DeviceHub shows the home screen and Settings live, clipped inside the chrome (`Found FramebufferMaskIdentifier from displayInfo`). **Band reads validated (2026-10-07/08, `iPhone17,3 27.0.1 (24A446)`):** a four-band stream with screen activity deadlocked after 18 s without the barrier and ran 60, 180 and 300 s with it without a GPU error; in the host trace of the 180 s run no IOSurface access waited, and every band read of 6258 frames registered after the frame's write was released, a median 0.76 ms after it. Open: latency that grows over a long session and occasional stalls after a cold start, both upstream of the Mac receiver. |    Y    |  Y  |  Y  |
| 27  | No binary change: both spawn hooks insert `libdevicename.dylib` into `configd` and `lockdownd` (after `libmisfix.dylib`, the first process to take two inserted libraries). In `configd` it interposes `SCDynamicStoreSetMultiple` and `SCDynamicStoreSetValue` and pins `Setup:/System`'s `ComputerName`; in `lockdownd` it interposes `SCPreferencesSetComputerName`, `SCPreferencesSetHostName` and `SCPreferencesSetLocalHostName` and refuses every rename with `kSCStatusAccessError`. Inert unless `/var/db/vphone/devicename.plist` holds a valid `DeviceName` — **all bases** | none (new guest dylib `VPhoneGuestComponents/DeviceName/libdevicename.c`, installed at `/usr/lib/libdevicename.dylib`; vphoned `device.name.get`/`device.name.set`) | **Pin the guest's device name to the VM's name.** The name is `System/System/ComputerName` in `preferences.plist`; configd's PreferencesMonitor (`updateConfiguration`, 24A435 `0x100062098`) flattens it into `Setup:/System` with one `SCDynamicStoreSetMultiple`, and every reader (`SCDynamicStoreCopyComputerName` in lockdownd's `copy_device_name`, MobileGestalt `UserAssignedDeviceName`, `UIDevice.name`) reads the store. The hook rewrites that publication, not the preferences read: the monitor's model-change path (`sub_10006155c`) writes the `kSCPrefSystem` value it reads back to disk, and the publication route leaves `preferences.plist` with the guest's own name. A publication that leaves `Setup:/System` out as unchanged gets the store's value pinned; one that removes it gets the pinned name instead. `vphone-vm` sends the VM's name to vphoned's `device.name.set` after every connect; vphoned writes the file (one rename, 0644) and applies the preferences unchanged, so configd publishes again and the new pin, or the guest's own name when the file is removed, is live within a second. The file outlives a reboot, so configd's first publication at boot carries it. The library re-reads the file when its inode, size or mtime change. lockdownd's `set_device_name` (`0x1000073b0`) is the only caller of the three setters; it logs their failure and still commits, and the `SetValue DeviceName` handler ignores the result, so a host rename reports success and the name stays. The pinned name itself is refused too: lockdownd runs `set_device_name(copy_device_name())` whenever it starts, and a lockdownd restarted after configd published would otherwise write the pinned name and derived host names into `preferences.plist` (seen once). An NVRAM variable was the first channel and never reached the guest: iBoot keeps only the variables it knows (even `vphone-vm`'s `boot-args` write is replaced). Interposing works because both daemons are standalone images. Ships with `system-launchdaemons-boot-environment` and the environment update; takes effect at the next boot. Verified on iOS 27.0 (24A435) on 2026-10-07: pin at boot and live, host rename refused, `vm rename` followed, preferences untouched. CoreDevice (`devicectl`, DeviceHub) reads the name when the device appears and can lag one boot after a rename. Details: `Research/Guest/device_name_pinning.md`. |    Y    |  Y  |  Y  |


### Swift port status — the eight DSC patchers (2026-09-23)

The rows above describe the patches, which have not changed. What is new is that
each now has an in-process Swift implementation on the validated DSC foundation
(`DSCChunkSet`, `DSCCodeSignature`, `DSCLocalSymbolTable`, `DSCSymbolResolver`).
Every one was proven on the real 24A435 arm64e cache — `ipsws/ref_extract/dsc_pristine`,
79 chunks + `.symbols` = 80 files, 6.7 GB — by running the Python on one `cp -c`
clone and the Swift on another and comparing all 80 files. Every `cfw.py` call
site is now a `vphone-cli cfw` verb — see "the CFW verbs" below.

| Python | Swift | Sites | Parity on the real cache |
| --- | --- | --- | --- |
| `cfw_patch_dsc_maxslide.py` | `DSCMaxSlidePatcher` | 1 (header `@0xF0`) | 80/80 identical. vs pristine exactly 1 byte differs (`0xF3`, `0x20`→`0x00`). Logs character-identical. No re-attestation on either side (header, not a code page) — confirmed by hashing the CD blob. |
| `cfw_patch_lockdown_mode.py` | `DSCLockdownModePatcher` | 1 + 1 slot | Same gate `b.eq @0x237EF2298` (`20010054`→`1f2003d5`), same slot 7868 of `.40`, same hash. `diff -rq` clean over 80 files; second pass a no-op both sides. |
| `cfw_patch_lsd_embedded_reg.py` | `DSCLSDEmbeddedRegPatcher` | 1 + 1 slot | Same gate `cbz w0 @0x186EEA024`, same slot 6842 of `.01`. 0 differing files. Cross-run both ways: each re-run over the other's output is a no-op. |
| `cfw_patch_xpc_lwcr.py` | `DSCXPCLWCRPatcher` | 3 + 1 slot | Same three addresses `0x1805DD644/8/C`, same slot 119 of `.01`. `diff -rq` clean. |
| `cfw_patch_camera_dsc.py` | `DSCCameraPatcher` | 6 + 5 slots | Both families. 0 differing files; exactly 2 chunks differ from pristine. |
| `cfw_patch_iomfb_force_kern.py` | `DSCIOMFBForceKernPatcher` | 31 retargeted | Trampoline shape verified by Capstone, branch bytes from Keystone. |
| `cfw_patch_iomfb_swapend.py` | `DSCIOMFBSwapEndPatcher` | 1 | Size **discovered, never matched**; anchored on the method-5 call set-up. |
| `cfw_patch_hv_vmm_dsc.py` **+** `cfw_patch_hv_vmm.py` | `DSCHVVMMPatcher` | blacklist-flip mangle | Both halves in one type. The migration plan called `cfw_patch_hv_vmm.py` dead code; **it is not** — the DSC module live-imports `NEEDLE` / `MANGLED_NEEDLE` / `MANGLE_OFFSET` / `ORIGINAL_BYTE` / `MANGLED_BYTE` from it. |

Each port was checked by a second agent that rebuilt the evidence rather than
reading it: own drivers linked against the module, whole-cache byte comparison,
and for `lsdreg` a differential sweep of both gate-finders over 33,000 function
addresses (49 gates each, zero verdict differences).

**Two defects that review found and this branch fixed:**

* `DSCCameraPatcher` wrote each site as it classified it and re-attested once at
  the end, so a throw in the second family left the first family's five writes on
  disk with stale signature slots — half-patched *and* SIGKILL-on-page-in under
  `codeSigningMonitor == 2`. `apply` now plans every family before writing any of
  them, so a failure writes nothing. Pinned by
  `DSCCameraPatcherTests.failureWritesNothing`, which fails and names
  `dyld_shared_cache_arm64e.15` if the old shape is restored.
* `DSCLockdownModePatcher.disassembleBlock` did not stop at an undecodable word.
  `ARM64Disassembler` sets `cs.skipData = true` and the reference's `_cs`
  (`cfw_asm.py:14`) does not, so where the Python's stream ends this one walked
  past the data to its 60-instruction ceiling. On a userland with an inline
  literal before the gate that inverts the failure mode: the Python stops the
  install loudly, this would decode into unrelated code and could NOP a branch
  there *and re-attest that page*. It now breaks on `insn.id == 0`, as
  `DSCLSDEmbeddedRegPatcher.disassembleFunction` already did.

**Known, not fixed** (all LOW, none changes a byte on this cache):

* `DSCIOMFBSwapEndPatcher` — on the already-correct path it clears recorded
  writes and re-attests nothing, so the returned `DSCReattestation` has empty
  arrays and `isFullyAttested` is **vacuously true**. The Python re-hashes the
  page and compares. Unreachable through today's shell graph; a footgun for the
  Swift driver that is meant to replace it.
* `DSCXPCLWCRPatcher` — a dry run returns `status == .patched, siteCount == 3`
  although nothing was written; `DSCIOMFBSwapEndPatcher` takes the opposite
  convention (`0`). A driver summing these for a preview gets a wrong total.
* `DSCLSDEmbeddedRegPatcher` — record text says `cbz w0, 0x186eea048` where the
  captured Python reference says `cbz w0, #0x186eea048`. libcapstone-spm
  (Capstone 6) omits the `#` the Python patchers' Capstone 5.0.7 emitted. Bytes are
  identical; a field-level diff against `reference_patches/` will flag it.
* `DSCHVVMMPatcher.findStringSites(inMachO:)` skips a string section whose
  declared extent overruns EOF, where the Python truncates and scans what is
  there — a malformed binary reads as a clean no-op. No caller in the repo today.
* `DSCMaxSlidePatcher` — the `sharedRegionSize >= mapped span` corroboration
  couples the patch to `DSCChunkSet`'s file-exclusion policy, so a stray
  cache-shaped file in the chunks directory turns a working patch into a hard
  abort. Fail-closed, and left alone deliberately.

### Swift port status — the six independent Mach-O patchers (2026-09-23)

Rows 1, 2, 3, 5 and 13 above, plus the EXP `watchdogd` patch, now have Swift
implementations under `Sources/FirmwarePatcher/CustomFirmware/ExecutablePatches/`. The patches did not
change. Each was run against its Python on two `cp -c` clones of the real 24A435
binary in `ipsws/ref_extract/macho_pristine/`, both with re-attestation off (what
the Python emits) and on (against `cfw_macho_codesign.reattest_modified_offsets`).

| Python | Swift | Sites | Parity on the real binary |
| --- | --- | --- | --- |
| `cfw_patch_seputil.py` | `CFWSeputil` | 1 (+1 slot) | `%s`→`AA` at `0x1BDD2`; sha256 `75dc86f8…` both sides. Re-attested: slot 27 identical. Anchored on the whole `__cstring` literal plus the `adrp`+`add` that builds it, not the Python's file-wide `find`. |
| `cfw_patch_cache_loader.py` | `CFWCacheLoaderPatcher` | 1 (+1 slot, opt-in) | `cbz x0 @0xC7C` → `nop`; sha256 `17c5b00c…` both sides, 4 bytes differ from pristine. |
| `cfw_patch_mobileactivationd.py` | `CFWMobileactivationd` | 1 (+1 slot) | `-[DeviceType should_hactivate]` at `0x2EC368`; sha256 `9f26bf92…` both sides. Re-attested: slot 748 identical. The Python's symbol match is a substring search that sees four candidates on this image; the Swift matches the exact selector and cross-checks ObjC metadata. |
| `cfw_patch_jetsam.py` | `CFWJetsamPatcher` | 1 | `cbz w0 @0xFA98` → `b` (`launchd`); sha256 `cae806f5…` both sides. |
| `cfw_patch_watchdogd.py` | `CFWWatchdogd` | 2 × 2 insns + 2 slots | Sites at `0x100004754` and `0x10000AB30`, slots 4 and 10; sha256 `963cd445…` both sides, `codesign -v` passes. |
| `cfw_patch_diskimagesiod.py` | `CFWDiskimagesiod` | 1 (+1 slot) | `isMountComplete…` IMP at `0x320C0`, found through the relative method list; sha256 `41daf01d…` both sides. Re-attested: slot 50 identical. |

**Every port is idempotent, and three of the Pythons are not.** A second Python
run over its own output walks past the first patch and changes something else:
`cache_loader` NOPs the `cbnz x0 @0xC84` log-file guard, `jetsam` rewrites the
`b.ne @0xFAB0` in the same return block, and `seputil` exits 1. The shell never
hit this because it always copies from the `.bak` first. The Swift reports
`already patched` and writes nothing, which is what the in-place call site in
`CryptexFilesystemPatcherGuestPayload` needs.

**Wired in.** `CryptexFilesystemPatcherGuestPayload` calls
`CFWCacheLoaderPatcher` and `CFWMobileactivationd` in process. Every shell call
site (`cfw_install*.sh`, `cfw-kit`, `patch_{camera,hv_vmm}_userland.sh`) now runs
`vphone-cli cfw <verb>` — see the next section.

**A defect that review found and this branch fixed:** `CFWCacheLoaderPatcher`
trapped on every patch with logging on, which is the default. The before/after
window starts two instructions ahead of the gate, and it converted that negative
delta with `UInt64(Int)`, which traps even under `-O`. Every test passed
`log: nil`, so none reached it. Now covered by `loggingPathDoesNotTrap`.

**A second defect, found when the CLI verbs landed and fixed here:** a Mach-O
whose load-command table runs past EOF — a 64-byte truncation is enough — made
*all six* patchers die with SIGTRAP (`BinaryBuffer.swift:9` precondition, exit
133), not a catchable error. `MachOParser` walked the table checking only that
each command's 8-byte header fit, then read fields up to `+0x38` inside it.
`MachOParser.forEachLoadCommand` now bounds every command by `cmdsize` and by
the file, and each branch checks its own minimum command size; a truncated file
yields no segments and the patcher throws `invalidFormat` like any other bad
input.

**Known, not fixed** (all LOW, none changes a byte on these binaries):

* `CFWCacheLoaderPatcher.flagSetterOnResult` accepts a flag-setting instruction
  with `x0`/`w0` in any operand, including as the destination.
* `CFWMobileactivationd`'s ObjC cross-check is scoped to the selector, not the
  class: it takes the first relative-method-list entry with that name.
* `CFWJetsamPatcher`'s `.alreadyPatched` is silent. If a later firmware emits an
  unconditional `b` into the return block ahead of the real gate, it would read
  as already patched.
* `CFWWatchdogdTests.swift` converts a VA to a file offset by subtracting the
  arm64 image base as a constant, in a test only.

### The CFW verbs, and the end of `scripts/patchers` (2026-09-23)

The fourteen ports above had no caller outside the two in-process call sites, so
the installers still ran `cfw.py`. They no longer do. Every patch is a
`vphone-cli cfw <verb>` with the Python's exact verb name, positional arguments
and flags, so the shell diff is a prefix swap:

```
-  "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-seputil "$bin"
+  "$VPHONE_CLI" cfw patch-seputil "$bin"
```

26 call sites across `cfw_install{,_dev,_jb,_exp,_host}.sh`,
`patch_{camera,hv_vmm}_userland.sh` and `cfw-kit`, whose `cfw_py` seam became
`cfw_cli`. Each verb was proven through the built binary against its Python on
`cp -c` clones of the real 24A435 references: the six Mach-O verbs byte-identical
(`cmp` + matching sha256, both exit 0), the eight DSC verbs `diff -rq` clean over
all 80 cache files on first run, second run and dry run.

**Parity evidence is now frozen, not re-measured.** The CFW test suites used to
spawn `.venv/bin/python3 scripts/patchers/…` and compare live. They now compare
against constants recorded from that same Python at commit `78cbeea`, each with a
provenance comment naming the command and the input digest, and each suite checks
the fixture is the one the goldens were taken over — so a different firmware fails
on that line instead of looking like a patcher bug. Two structural fixes were
needed for the freeze to mean anything: the re-attester parity test was reading a
**build product**, whose bytes change every build, and the device-tree golden is a
digest map keyed by input digest, because that input exists in two cloudOS IPSWs.

The build product in question was `.build/release/vphone-letmein`, picked as the
nearest real ad-hoc-signed thin arm64 Mach-O with a non-page-aligned `codeLimit`.
The tests asserting a frozen digest moved off it first, onto the real 24A435
`seputil`; the rest of `CFWMachOTests` — structural cases that only needed *some*
signed Mach-O — kept pointing at the build product, and that stopped being viable
when `vphone-letmein` was deleted from the tree (see
`Research/Host/host_binary_split.md`). All of `CFWMachOTests` now takes its fixture
the way the sibling CFW parity suites do: `macho_pristine/seputil`, resolved
through `VPHONE_MACHO_PRISTINE` with `ipsws/ref_extract/macho_pristine` as the
default, **failing** rather than skipping when it is absent, since a skipped test
reads like a passing one. `VPHONE_MACHO_FIXTURE_OPTIONAL=1` turns that back into
a skip for a machine that cannot carry the extracted IPSW.

**The lesson generalises past this one binary: a test fixture must never be
something the build produces**, whether or not the assertion is a frozen digest.
It was luck, not design, that the old fixture had the properties these tests
exercise — a non-page-aligned `codeLimit` and zero padding behind the load
commands — and a fixture that is rebuilt is also a fixture that can vanish.

Re-deriving any of these constants means re-extracting the reference Python from
git history — `scripts/patchers/` is gone from the working tree.

**One Python bug the port deliberately does not reproduce.** A write that
straddles a code-signature page boundary — eight bytes at `0x280FFFC..0x2810004`,
which is what `cfw_patch_camera_dsc.py` emits when its six entry points land on
both sides of the 2563/2564 line — re-attested only the page containing the
address. Page 2564 kept its original slot hash (`7ccd65fa…`) while its bytes
hashed to `dfe38096…`, and the guest dies on the first demand-page-in of it.
`DSCCodeSignature.reattestRecordedWrites` covers every dirtied page;
`DSCFoundationTests.pageStraddlingWriteAttestsEveryDirtiedPage` pins both the fix
and the reference's value, so the divergence stays on the record.

**One verb is semantically, not byte, identical.** `cfw inject-daemons` writes a
plist, and the two XML writers disagree on one thing: Python's `plistlib`
serialises an integral double as `<real>1.0</real>` where Foundation emits
`<real>1</real>`. Both parse back to the same value, and matching the Python
byte for byte would mean reimplementing `plistlib`'s writer — which is why the
plan set the bar for plists at semantic equivalence (type, order, key set,
`Data` bytes) rather than bytes. Recorded here so "byte-identical" is not read
as covering the plist verbs.

**Two behavioural differences kept on purpose**, both on the already-patched path
and neither changing a byte:

* `patch-camera-dsc` over an already-patched cache exits 0 where the Python
  raised and exited 1. `cfw_install_exp.sh:126` tests that exit status and its
  failure branch prints "likely build-version mismatch" — a *wrong* diagnosis for
  a re-install. Exit 0 with "chunks patched" is the true one.
* The three idempotence divergences in the section above stand: the Swift
  recognises its own output where the Python double-applies or exits 1.

**Final submodule removed:** `Scripts/Repos/InsertDylib` was retained only for
a byte-parity test after `CustomFirmwareInjectDylib` took over the injection.
That test is replaced with two checked-in Objective-C source fixtures: a
`hello world` executable and a swizzle dylib. The test compiles them, checks the
plain output, injects the dylib with the Swift patcher, re-signs the executable,
and checks that it prints `world hello`. This exercises the actual dyld load
and swizzle without an external test reference or an optional skip.

**P1 dropped `capstone`, `keystone-engine` and `pyimg4` from the dependency
list; P2 then deleted the list.** `requirements.txt`, `scripts/setup_venv.sh`,
`scripts/setup_venv_linux.sh`, the `make setup_venv` target and
`scripts/pymobiledevice3_bridge.py` are all gone — the restore backend was the
last program holding any of them up, and it is `Sources/VPhoneRestore` over
vendored libirecovery and idevicerestore now
(`Research/Restore/native_restore_architecture.md`). No Python is tracked in this repository
and nothing resolves a `python3` at runtime.

### Installed Components

| #   | Component                  | Description                                                                                                        | Regular | Dev | JB  |
| --- | -------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Cryptex SystemOS + AppOS   | Decrypt AEA + mount + copy to device                                                                               |    Y    |  Y  |  Y  |
| 2   | GPU driver                 | AppleParavirtGPUMetalIOGPUFamily bundle, extracted from the selected PCC OS image during `fw prepare`, or supplied from the same cloudOS build with `--gpu-driver-bundle` if Apple's AEA key is unavailable |    Y    |  Y  |  Y  |
| 3   | `iosbinpack64`             | Jailbreak tools (base set)                                                                                         |    Y    |  Y  |  Y  |
| 4   | `iosbinpack64` dev overlay | Replace `rpcserver_ios` with dev build                                                                             |    -    |  Y  |  -  |
| 5   | `vphoned`                  | vsock HID/control daemon (built + signed)                                                                          |    Y    |  Y  |  Y  |
| 6   | LaunchDaemons              | bash/dropbear/trollvnc/rpcserver_ios/vphoned plists                                                                |    Y    |  Y  |  Y  |
| 7   | Procursus bootstrap        | Bootstrap filesystem + optional Sileo deb                                                                          |    -    |  -  |  Y  |
| 8   | BaseBin hooks              | `systemhook.dylib` / `launchdhook.dylib` / `libellekit.dylib` -> `/cores/` plus `/b` alias for `launchdhook.dylib` |    -    |  -  |  Y  |
| 9   | `TweakLoader.dylib`        | Lean user-tweak loader built from source and installed to `/var/jb/usr/lib/TweakLoader.dylib`                      |    -    |  -  |  Y  |

### `kern.hv_vmm_present` user-mode patcher (EXP only)

Companion to the EXP kernel patcher (`KernelEXPPatcher.patchHvVmmRename`).
Mangles byte 5 of every `kern.hv_vmm_present` cstring inside DSC dylibs
EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness
consumers, ~15 entries). Patched dylibs query the renamed OID and get the
truthful 1 (graphics + accel passthrough); blacklisted dylibs keep the
original cstring, hit ENOENT on the renamed kernel, and defensively cache 0
("not running on a VM") for sign-in / device-attestation surfaces.
Source-of-truth research: `Research/Patches/hv_vmm_present_usermode_xrefs.md`.

JB and other variants are NOT affected by this patcher.

**Patch shape (every site)** — cstring mangle:

```
Before (cstring section bytes, 20 bytes total):
    "kern.hv_vmm_present\0"
    6B 65 72 6E 2E 68 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00

After (1 byte change at offset 5):
    "kern.Xv_vmm_present\0"
    6B 65 72 6E 2E 58 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00
                ^^
```

**Byte 5, not byte 0.** The mangle has to keep the `kern.` top-level
namespace intact or the kernel's name-to-MIB resolver routes the call to
nothing at all. Byte 0 would give `Xern.hv_vmm_present`, and `Xern` is not
a registered top-level sysctl namespace, so it could never resolve — see
the comment at `scripts/patchers/cfw_patch_hv_vmm.py:40-47`.

**Which way the lie runs.** This is the part that reads backwards if you
have the pre-blacklist-flip design in mind. The companion kernel patch
(`KernelEXPPatcher.patchHvVmmRename`) renames the OID itself, so after
both halves are installed:

* a **mangled** dylib asks for `kern.Xv_vmm_present`, which **resolves**
  to the renamed OID and returns the truthful `1` — that is what keeps
  graphics and accel passthrough working;
* a **blacklisted** dylib keeps `kern.hv_vmm_present`, which now hits
  `ENOENT`. Its post-call check (`cbnz w0, skip` or
  `cmp w0,#0 ; b.ne skip`) takes the skip-cache path, the cached "is_vmm"
  byte stays at BSS-zero, and that dylib believes it is not in a VM.

So mangling is what tells a dylib the truth, and *not* mangling is what
makes it lie. The blacklist is therefore the list of consumers that must
be deceived (sign-in, device likeness), not the list of ones to fix.

We don't modify executable code at all — only one byte of read-only
string data. The kernel call still happens, so any sysctl-tracing
infrastructure can still see activity.

Idempotent: the patcher scans for `MANGLED_NEEDLE` first
(`cfw_patch_hv_vmm_dsc.py:133`) and each site re-checks byte 5 before
writing, so a re-run does no work.

**DSC-side patches** — driven by an explicit **blacklist**
(`DONT_PATCH_INSTALL_NAMES` in `scripts/patchers/cfw_patch_hv_vmm_dsc.py`,
~15 entries) applied to chunks under
`SystemOS/System/Library/Caches/com.apple.dyld/`. Every dylib that is not
named there gets mangled. Add a line to the blacklist to stop patching
that dylib on the next install — useful for bisecting which consumer is
responsible for an observable change.

> The table below lists dylibs that ARE mangled, i.e. ones absent from the
> blacklist. It used to be introduced as a `PATCH_INSTALL_NAMES` whitelist;
> that name no longer exists in the module.

| Dylib                                                     | Component role (paraphrased)                                  |
| --------------------------------------------------------- | ------------------------------------------------------------- |
| `usr/lib/libMobileGestalt.dylib`                          | Backs `MGCopyAnswer("hv-vmm-present")` — highest fan-in       |
| `PrivateFrameworks/AAAFoundation.framework/AAAFoundation` | Apple ID anti-abuse plumbing                                  |
| `PrivateFrameworks/AuthKit.framework/AuthKit`             | Sign-in-with-Apple-ID / iCloud auth                           |
| `PrivateFrameworks/IDSFoundation.framework/IDSFoundation` | Apple Identity Service core (iMessage / FaceTime backbone)    |
| `PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity` | Device-binding / device class identity                     |
| `PrivateFrameworks/DeviceCheckInternal.framework/...`     | DeviceCheck attestation                                       |
| `PrivateFrameworks/MobileActivation.framework/...`        | Activation flow                                               |
| `PrivateFrameworks/ApplePushService.framework/...`        | APNS client (claims device characteristics on connect)        |
| `PrivateFrameworks/AppStoreUtilities.framework/...`       | Store / IAP support                                           |
| `PrivateFrameworks/CorePrescription.framework/...`        | Health prescription store sync gate                           |
| `PrivateFrameworks/CoreCDP.framework/CoreCDP`             | CDP (cloud key-vault / iCloud Drive plumbing)                 |
| `PrivateFrameworks/EmailFoundation.framework/...`         | Mail account heuristics                                       |
| `PrivateFrameworks/PhotoFoundation.framework/...`         | Photos asset visibility heuristics                            |
| `PrivateFrameworks/FindMyBase.framework/FindMyBase`       | Find My anti-spoof                                            |
| `PrivateFrameworks/AirPlaySupport.framework/...`          | AirPlay receiver gate                                         |
| `PrivateFrameworks/TrialServer.framework/TrialServer`     | A/B / trial-rollout exclude-VM gate                           |
| `PrivateFrameworks/VisionKitCore.framework/VisionKitCore` | VisionKit                                                     |
| `PrivateFrameworks/DVTInstrumentsUtilities.framework/...` | Xcode Instruments support                                     |
| `PrivateFrameworks/WatchdogServiceManagement.framework/...` | Watchdog manager                                            |
| `Frameworks/CoreVideo.framework/CoreVideo`                | CoreVideo pipeline                                            |

**Standalone-binary patches (6 files, applied to the device rootfs
over SSH)**

| Path                                                                                              | Role                                                          |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `/System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator`   | Activation migration helper                                   |
| `/Applications/CheckerBoard.app/CheckerBoard`                                                     | Apple internal accessibility test app                         |
| `/Applications/StoreKitUISceneService.app/StoreKitUISceneService`                                 | StoreKit UI host                                              |
| `/System/Library/Frameworks/StoreKit.framework/Support/storekitd`                                 | StoreKit / IAP daemon                                         |
| `/System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstored`                    | App Store daemon                                              |
| `/System/Library/PrivateFrameworks/CorePrescription.framework/XPCServices/CorePrescriptionService.xpc/CorePrescriptionService` | CorePrescription XPC service       |

**Explicitly NOT patched (compute / accel — patching here turns off
VM fast-paths that exist so the lib doesn't try to touch real silicon
ANE / AGX / hardware codecs):**

```
System/Library/Frameworks/CoreML.framework/CoreML
System/Library/PrivateFrameworks/Espresso.framework/Espresso
System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine
System/Library/PrivateFrameworks/CoreRE.framework/CoreRE
System/Library/PrivateFrameworks/RenderBox.framework/RenderBox
System/Library/PrivateFrameworks/WebGPU.framework/WebGPU
System/Library/PrivateFrameworks/caulk.framework/caulk
System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator
System/Library/ExtensionKit/Extensions/HostInferenceProviderService.appex/HostInferenceProviderService
```

**Wiring**

* `scripts/patchers/cfw_patch_hv_vmm.py` — standalone cstring patcher
  (used for the on-device files): finds the `"kern.hv_vmm_present\0"`
  cstring in the Mach-O's __cstring section and rewrites its first
  byte (`'k'` → `'X'`).
* `scripts/patchers/cfw_dsc_chunks.py` — chunked-DSC byte-level helper
  (`DSCChunks(chunks_dir)`): vmaddr↔chunk-fileoff mapping, cstring
  scan over executable mappings, byte read/write at a vmaddr, and
  Mach-O header walk-back to resolve a vmaddr to the dylib install
  name (LC_ID_DYLIB).
* `scripts/patchers/cfw_patch_hv_vmm_dsc.py` — DSC-native orchestrator.
  No external `ipsw` dependency. For every `"kern.hv_vmm_present\0"`
  occurrence in any executable mapping, walks back to the containing
  dylib's Mach-O header, reads `LC_ID_DYLIB`, and — unless the install
  name is in the `DONT_PATCH_INSTALL_NAMES` blacklist — rewrites byte 5
  of the cstring through `DSCChunks.write_at_vma`. Pure Python.
  Blacklist-based by design so an operator can add an entry to take one
  dylib out of the patch set and bisect.
* ~~`scripts/patchers/cfw.py patch-hv-vmm <binary>`~~ — **gone.** The
  standalone-Mach-O subcommand and its backing patcher
  (`cfw_patch_hv_vmm_rootfs.py`) were removed with item 8 in the
  blacklist-flip redesign; the 6 on-device files no longer need an
  SSH-time patch. `scripts/patch_hv_vmm_userland.sh:65-73` documents
  why the wrapper's standalone branch has no honest substitute.
* `scripts/patchers/cfw.py patch-hv-vmm-dsc <chunks_dir>` —
  DSC subcommand (used while the SystemOS Cryptex DMG is still
  mounted on the host, before the device copy).
* `scripts/patch_hv_vmm_userland.sh` — thin wrapper used by the
  install scripts.
* `scripts/cfw_install_exp.sh` — EXP install script. Pre-step before
  invoking `cfw_install.sh`: decrypts the SysOS Cryptex into the cache
  location `cfw_install.sh` already uses, mounts it, applies the
  DSC patch, unmounts. The unmodified `cfw_install.sh` then sees the
  cached (already-patched) DMG. Standalone watchdogd is patched later
  via SSH at step `[EXP-JB-3.5]`.
* `scripts/cfw_install_jb.sh` and `scripts/cfw_install_dev.sh` —
  unchanged from pre-experimental baseline. Neither runs the DSC
  patcher.

### `kern.hv_vmm_present` kernel patcher — Part A + Part B (EXP only)

The `KernelEXPPatchHvVmmRename` Swift patcher (in `KernelEXPPatcher.findAll()`,
chained after `KernelPatcher` and `KernelJBPatcher` for the `.exp` variant only)
renames the sysctl OID and rewrites every kernel-internal occurrence of the
old name so kexts continue to find it under the new name. Two parts. JB and
other variants do NOT run this patcher.

**Part A — OID name rename.** Finds the OID's `oid_name` cstring as
the NUL-delimited bytes `\0hv_vmm_present\0` (exactly one match
required in the kernelcache; on iPhone17,3 / iOS 26.1 this lives at
file offset `0x964e0` inside `com.apple.kernel`). Flips byte 0 of the
cstring `'h'` (0x68) → `'X'` (0x58). After the patch, the kernel's
`sysctl_register_oid` keeps the OID's MIB and value (1) intact but
the name resolver returns `ENOENT` for `kern.hv_vmm_present` and
returns 1 for `kern.Xv_vmm_present`.

**Part B — kernel-internal caller mangle.** After Part A, any
kernel-side `sysctlbyname("kern.hv_vmm_present", …)` call gets
ENOENT and falls into the caller's "not in a VM" branch — which on
the bring-up build caused AMFI to panic with `AMFI: No PMGR?
(ConfigurationSettings.cpp:388)` during ramdisk boot. Part B mangles
every kernel-internal occurrence of the `kern.hv_vmm_present` name
so callers continue to find the renamed OID. The mangle flips byte
5 of the inner cstring (`'h'` after `kern.`) → `'X'`, producing
`kern.Xv_vmm_present`.

Two byte-aligned forms are searched, both anchored at the
`kern.hv_vmm_present` substring:

| Form | Needle | Where it lives | Mangle delta within needle |
|------|--------|----------------|----------------------------|
| (i) NUL-delimited cstring | `\0kern.hv_vmm_present\0` | `__TEXT,__cstring` of any kext that calls sysctlbyname by full name | +6 (skip leading NUL + 5) |
| (ii) Sandbox-profile name token | `kern.hv_vmm_present\x0f` | Inside a compiled sandbox-profile blob within `com.apple.security.sandbox`. The `\x0f` byte is the sandbox-profile end-of-name marker; the token has no leading NUL. | +5 |

On iPhone17,3 / iOS 26.1 / 23B85 the universe is 5 occurrences
(verified by raw substring scan over the kernelcache buffer):

| File offset | Fileset entry | Form |
|-------------|---------------|------|
| `0x541d56` | `com.apple.driver.AppleMobileFileIntegrity` | (i) cstring |
| `0x81bdc3` | `com.apple.iokit.IOCryptoAcceleratorFamily` | (i) cstring |
| `0xa6618b` | `com.apple.security.sandbox` | (ii) sandbox-profile name token |
| `0xbb0d55` | `com.apple.security.sandbox` | (i) cstring |
| `0xbce1f9` | `com.apple.filesystems.apfs` | (i) cstring |

Part B emits one patch record per match (5 total, plus Part A's 1)
under patch IDs `kernelcache_exp.hv_vmm_internal_caller_mangle` and
`kernelcache_exp.hv_vmm_oid_rename`. Idempotent: a re-run detects
already-mangled bytes (`kern.Xv_vmm_present` instead of
`kern.hv_vmm_present`) and reports the patch as already applied.

**Note on the sandbox-profile occurrence.** This was missed by the
original Part B because its needle required NUL on both sides. The
sandbox-profile blob stores OID names as TLV-framed tokens where the
trailing byte is `\x0f` (sandbox EOT) rather than a NUL. Without the
second needle, sandboxed callers that interpret the profile's
`kern.hv_vmm_present`-matching rule would still match against the
OLD name, while the OID itself has been renamed — so the rule's
ALLOW/DENY/audit action would never fire. With the second needle,
the rule's name token is rewritten to `kern.Xv_vmm_present` and
sandboxed callers that hit the renamed OID match the (rewritten)
rule as intended. Covered occurrence verified on
iPhone17,3 / iOS 26.1 / 23B85 at file offset `0xa6618b`.

### `watchdogd` surgical hv_vmm_present cache patch (EXP only)

**Why a dedicated patch.** After the EXP kernel-side OID rename
(`KernelEXPPatchHvVmmRename`), `sysctlbyname("kern.hv_vmm_present", ...)`
returns `ENOENT` on this image. `/usr/libexec/watchdogd` caches that
answer at startup. On `ENOENT` the cached byte stays at its BSS-zero
default (`0`) and the downstream `cbz w0, ...` at the IOWatchdog-lookup
site (`+0x58e0`) takes a branch into a `_os_crash` wrapper that does
`brk #1`. launchd's `_PanicOnCrash → PanicOnConsecutiveCrash = true`
flag in `com.apple.watchdogd.plist` escalates the SIGTRAP to a kernel
panic. The cstring-mangle approach used elsewhere doesn't apply here
because we want this binary to behave as if the sysctl returned `1`,
not as if it returned `ENOENT`.

**Patch shape.** Two-instruction surgical edit at every site in
watchdogd that has the canonical caching shape:

```
adrp x0, <page>
add  x0, x0, #<off>          ; "kern.hv_vmm_present"
...arg setup...
bl   _sysctlbyname
cbnz w0, <skip>              ; <-- patched: NOP
ldur w8, [x29, #-4]
cmp  w8, #0
cset wN, ne                  ; <-- patched: mov wN, #1
adrp xM, <page>
strb wN, [xM, #<imm>]        ; cached "am I a VM?" byte
```

Net effect: the cached byte is forced to `1` regardless of the sysctl
result, and watchdogd's pre-existing "detected virtual machine
environment, exiting..." clean-exit branch runs instead of the trap
path. Two functions in watchdogd match this shape on
`iPhone17,3 / iOS 26.1`; both are patched.

**Code signing.** The byte edit invalidates the SHA-256 slot hashes
for the 4 KiB pages containing the modifications in watchdogd's own
`CS_CodeDirectory`. The patcher recomputes those slot hashes in place
via `cfw_macho_codesign.reattest_modified_offsets` (4 KiB page size
read from the CD, correct tail-slot length, all present CDs). The
resulting CD mutation also changes the cdHash, but the existing JB
kernel patch `patch_amfi_cdhash_in_trustcache` accepts any cdHash, so
AMFI's trust-cache check still passes at execve. The patcher does NOT
re-sign with `ldid` — preserving the original Apple-issued code-signing
identifier (`com.apple.watchdogd`) is required for launchd's boot-task
identity validation; an earlier attempt to re-sign other rootfs
binaries with `ldid_sign` tripped this check on `mobile_obliterator`.

**Wiring.**

* `scripts/patchers/cfw_macho_codesign.py` — standalone-Mach-O
  page-hash re-attestation (parallel to `cfw_dsc_codesign.py` but
  parses `LC_CODE_SIGNATURE` directly, uses page size from the CD
  header, handles short tail slot, updates every present CD).
* `scripts/patchers/cfw_patch_watchdogd.py` — capstone-anchored
  pattern matcher + Keystone-assembled 2-insn patch + slot reattest.
  Idempotent.
* `scripts/patchers/cfw.py patch-watchdogd <binary>` — CLI subcommand.
* `scripts/patch_hv_vmm_userland.sh watchdogd <binary>` — thin shim
  used by the install script.
* `scripts/cfw_install_exp.sh` — invokes the patcher at step `[EXP-JB-3.5]`
  on the live `/mnt1/usr/libexec/watchdogd` (scp-down, patch, scp-up,
  chmod 0755). JB and DEV install scripts do NOT run this step.

### DeviceTree `/product/camera` node addition at fw_patch time (EXP only)

`DeviceTreePatcher` carries an `experimentalNodeAdditions` list with one
entry — a `/device-tree/product/camera` child node. Applied only when
`includeIdentityPatches` is true (i.e. variant `.exp`); other variants
leave the product subtree unchanged.

| Property                            | Type          | Value | Purpose                                                 |
|-------------------------------------|---------------|-------|---------------------------------------------------------|
| `name`                              | cstring       | `camera` | DT node name (auto-added from `nodeName`).           |
| `aggregate-camera`                  | uint32        | `1`   | Backs MG `aggregateCameraCapability` getter.            |
| `auto-focus`                        | uint32        | `1`   | Backs MG `autoFocusCameraCapability` getter.            |
| `flash`                             | uint32        | `1`   | Backs MG `cameraFlashCapability` getter.                |
| `pearl-camera`                      | uint32        | `1`   | Backs MG `pearlCameraCapability` getter.                |
| `panorama`                          | uint32        | `1`   | Backs MG `panoramaCameraCapability` getter.             |
| `pipelined-stillimage-capability`   | uint32        | `1`   | Backs MG `pipelinedStillImageCaptureCapability`.        |
| `rear-burst`, `front-burst`         | uint32        | `1`   | Backs MG burst-capability getters.                      |
| `video-cap`                         | uint32        | `2`   | Video capture level (real D47AP value).                 |
| `camera-hdr-version`                | uint32        | `3`   | HDR version (real D47AP value).                         |
| `camera-ui-version`                 | uint32        | `2`   | UI version selector (real D47AP value).                 |

Why this is necessary: `libMobileGestalt.dylib` resolves
`MGGetBoolAnswer("still-camera")` (cstring at vmaddr `0x1b1c5fedd`) via a
chain that reads `IODeviceTree:/product/camera` (cstring at vmaddr
`0x1b1c5832a`, **65 ADRP+ADD xrefs in the same dylib's `__text`**). The
canonical iPhone17,3 D47AP DT carries this node with 64 capability
properties; the vphone600AP DT ships **zero** `camera`, `audio`,
`facetime`, or `back-camera` references under `/product`. Without
the node, SpringBoard's `SBAppTags = ["still-camera"]` filter hides
Camera.app's icon and refuses to launch the bundle.

The node alone is not enough: the SBAppTags resolver also chains
through `/product` direct properties (`assistant`, `dictation`,
`compatible-device-fallback`, `chrome-identifier`, …), most of which
ship as 12-byte `'syscfg/XXXX'` cstring placeholders on vphone600 and
read back as NO. Tier 1d (below) rewrites those.

Idempotent: re-running against an already-patched DT detects the
existing child and skips.

### Camera DSC patch (EXP only)

`apply_all_camera_patches` in `scripts/patchers/cfw_patch_camera_dsc.py`
runs two patch families. Symbols are resolved per-build via
`ipsw dyld symaddr` against the cryptex's `dyld_shared_cache_arm64e`
header.

| # | Target | Framework | Effect |
|---|---|---|---|
| 1 | `+[_NUStyleTransfer{,Apply,Thumbnail,Learn,Interpolate}Processor processWithInputs:arguments:output:error:]` (5 entry points) | NeutrinoCore | Each replaced with `mov w0, #0; ret`. Camera's CIImageProcessorKernel chain that drives the style preview thumbnails short-circuits before reaching `+[_NUStyleEngine usingSharedStyleEngineForUsage:...]` → `_NUStyleEngineMemoryResource initWithDevice:descriptor:` which would otherwise assert on a nil descriptor (root cause is an upstream ANE-detection gate in `CMIStyleEngineCommonSettings`; we workaround at the consumer instead of unblocking it). |
| 2 | `+[AVCaptureDevice authorizationStatusForMediaType:]` | AVFCapture | Replaced with `mov w0, #3; ret` (AVAuthorizationStatusAuthorized = 3). Any process probing camera/audio/etc. media-type authorization gets "Authorized" without going through TCC. Stage 0 of the vcam stack — makes apps stop bailing on the auth check. Audio capture still does not work on the VM (the virtio sound driver added 2026-10-02 is output only), so the broader scope is harmless (audio-capture consumers fail downstream regardless). Downstream pipeline (cameracaptured rewrite, vcamd daemon) still owed for actual frame delivery. |

Wired into `cfw_install_exp.sh` immediately after the hv_vmm DSC step,
inside the same `hdiutil attach` block (one mount/unmount per install).
Page-hash re-attestation keeps the cryptex's CodeDirectory slots
consistent with the modified pages so `amfid` / TXM accepts the DSC at
next boot.

### DeviceTree identity properties at fw_patch time (EXP only)

`DeviceTreePatcher` carries two property-patch lists: `basePropertyPatches`
(4 entries — `serial-number`, `home-button-type`, `artwork-device-subtype`,
`island-notch-location`) applied for every variant, and
`identityPropertyPatches` (8 entries) applied **only when `includeIdentityPatches`
is true**, which `FirmwarePipeline` sets exactly when `variant == .exp`.

The 8 EXP-only identity properties (no restore-fatal ones — those go through
EXP-JB-6 post-restore):

| # | Node path                                          | Property              | Old → New                     | Risk    |
|---|----------------------------------------------------|-----------------------|-------------------------------|---------|
| 1 | `device-tree`                                      | `target-sub-type`     | `VPHONE600AP` → `D47AP`       | HIGHER  |
| 2 | `device-tree`                                      | `compatible[1]`       | `iPhone99,11` → `iPhone17,3` (slot-preserving) | LOW |
| 3 | `device-tree/product`                              | `fdr-product-type`    | `iPhone99,11` → `iPhone17,3`  | HIGHER  |
| 4 | `device-tree/product`                              | `sub-product-type`    | `iPhone99,11` → `iPhone17,3`  | LOW     |
| 5 | `device-tree/product`                              | `unique-model`        | `VPHONE600AP` → `D47AP`       | LOW     |
| 6 | `device-tree/arm-io`                               | `device_type`         | `vresearch1-io` → `t8140-io`  | MEDIUM  |
| 7 | `device-tree/arm-io`                               | `soc-generation`      | `VResearch1` → `H17`          | MEDIUM-LOW |
| 8 | `device-tree/product/vphone600-gestalt-variants`   | `name` (node rename)  | `vphone600-gestalt-variants` → `d47-gestalt-variants` | LOW-MEDIUM |

Root `model` and root `target-type` are deliberately NOT in this list —
both have been empirically shown to break restore. Those edits run
post-restore as EXP-JB-6.

Bulk `/product` direct-property completion (rewriting the ~30
`'syscfg/XXXX'` placeholders to D47AP integer/string values) was
attempted to make `MGGetBoolAnswer("still-camera")` answer YES via the
DT path alone. It broke screen rendering on the VM (the display
pipeline / framebuffer pulls one or more `/product` capability props
during init and chooses a render path the VM can't service). Reverted.
A narrower set targeted at the Camera-icon resolver chain (Tier B + C
+ F, below) does work without breaking display.

### DeviceTree Camera-icon completion (Tier B + C + F, EXP only)

Two `PropertyPatch` entries in `identityPropertyPatches`, three
`AddChildNodePatch` entries appended to `experimentalNodeAdditions`
for `/product/*` children, and five more for `/arm-io/*` stubs.
Empirically: this is the set that makes Camera.app's icon visible on
the home screen and in Spotlight without breaking screen rendering.

**Tier B — `/product` cam-offset rewrites.** vphone600 ships these
as 12-byte `'syscfg/{fcof,rcof}'` cstring placeholders. d47ap carries
20-byte little-endian geometry blobs. Consumed by Camera.app / ARKit
/ FaceTime for image-centering math.

| Property | Old length | New length | New value (hex) |
|----------|:----------:|:----------:|------------------|
| `/product::front-cam-offset-from-center` | 12 | 20 | `61000100921c0000d8130000e803000000000000` |
| `/product::rear-cam-offset-from-center`  | 12 | 20 | `eda50000b256000059080000e803000000000000` |

**Tier C — new `/product/*` child nodes.** d47ap carries three
sibling nodes to `/product/camera`. vphone600 has none of them.

| Node | Props | Camera relevance |
|------|:-----:|------------------|
| `/product/facetime` | 9 (excl. AAPL,phandle) | Front-camera video-call config — bitrates, codec encoding/decoding, tnr-mode-back/front. |
| `/product/audio` | 31 (excl. AAPL,phandle; an iPad guest takes its board's node instead, see "Guest audio" 2026-10-02) | Carries `supports-spatial-audio-capture=1` + `supports-spatial-facetime=1` (camera-joint). Rest is audio config. |
| `/product/iopm` | 2 (excl. AAPL,phandle) | `aot-mode=13` + `aot-linger-time-ms=0`. Always-On Technology mode. |

All property values copied byte-for-byte from
`ipsws/iPhone17,3_26.5_23F77_Restore_extracted/Firmware/all_flash/DeviceTree.d47ap.im4p`.

**Tier F — `/arm-io/*` minimal camera-flag stubs.** d47ap carries
`/arm-io/isp` (65 props), `/arm-io/ispRtb` (53 props), and a deep
`/arm-io/smc/iop-smc-nub/smc-ext-charger` chain (3 levels of node).
vphone600 has none of these paths. We add minimal stub nodes carrying
ONLY the camera-* properties and the mandatory auto-`name`,
deliberately omitting `compatible`/`device_type`/`reg`/`interrupts`,
so no IOKit kext finds a matching `compatible=` and tries to probe
non-existent ISP / SMC hardware.

| Path | Property | Value |
|------|----------|-------|
| `/arm-io/smc` | (stub — parent for chain) | — |
| `/arm-io/smc/iop-smc-nub` | (stub — parent for charger) | — |
| `/arm-io/smc/iop-smc-nub/smc-ext-charger` | `camera-driver` | str `'AppleH16CamIn'` |
| `/arm-io/isp` | `camera-front`, `camera-rear` | int32:1, int32:1 |
| `/arm-io/ispRtb` | `camera-front`, `camera-rear` | int32:1, int32:1 |

Dependency order: the patcher walks `experimentalNodeAdditions` in
array order against the in-memory tree, so each entry that resolves
to a parent added by an earlier entry resolves correctly.

Idempotent: re-running the patcher against an already-modified DT
detects the existing child by name and skips. The DT IM4P that ships
on subsequent boots is signed by Apple but the existing iBSS/iBEC/LLB
`image4_validate_property_callback` bypass accepts arbitrary payloads.

### Post-restore DT identity rewrite (EXP-JB-6, EXP only)

After the restore daemon's BuildManifest identity check has passed,
`cfw_install_exp.sh` step `[EXP-JB-6]` scp's `devicetree.img4` down from the
mounted rootfs (`/mnt5/<boot-hash>/usr/standalone/firmware/`), runs
`scripts/patchers/cfw_patch_post_restore_dt.py`, and scp's the rewritten
img4 back. The Python patcher unwraps the IM4P via `pyimg4`, parses the
DT flat-binary, rewrites three restore-fatal root properties, and repacks
preserving the IMG4's original IM4M ticket. The iBSS/iBEC/LLB
`image4_validate_property_callback` bypass (existing JB patch) accepts
the modified payload at next boot.

| # | Property         | Old → New                                                              |
|---|------------------|------------------------------------------------------------------------|
| 1 | root `model`       | `iPhone99,11` → `iPhone17,3`                                          |
| 2 | root `target-type` | `VPHONE600` → `D47`                                                   |
| 3 | root `compatible`  | reorder `["VPHONE600AP", "iPhone99,11", "AVP-ARM"]` → `["D47AP", "VPHONE600AP", "AVP-ARM"]` (keeps `VPHONE600AP` in second slot so IOKit's `AppleVMApple1IO` kext binding still resolves; userland reads only the first entry for `hw.model`) |

Idempotent. Skipped if already-rewritten DT is detected.

### SystemVersion.plist `ProductBuildVersion` rewrite (EXP-JB-7, EXP only, opt-in)

Gated on the `SPOOF_BUILD` env var. When `cfw_install_exp.sh` is invoked
with e.g. `SPOOF_BUILD=23F77`, step `[EXP-JB-7]` runs
`scripts/patchers/cfw_patch_build_version.py` (plistlib-based,
format-preserving) on both the rootfs and cryptex copies of
`SystemVersion.plist` to rewrite the `ProductBuildVersion` key to the
specified id. Without `SPOOF_BUILD`, the step is skipped and the build
version stays at the original IPSW value.

| File                                                                              | Touched if `SPOOF_BUILD=<id>` |
|-----------------------------------------------------------------------------------|:------------------------------:|
| `/mnt1/System/Library/CoreServices/SystemVersion.plist` (rootfs)                  | Y                              |
| `/mnt5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist` (cryptex)    | Y                              |

`kern.osversion` is unaffected — that comes from a kernel global
initialized from boot args, not from this plist. Userland MG cache
picks up the new build identifier on first boot after the gestalt
cache rebuild.

### CFW Installer Flow Matrix (Script-Level)

| Flow Item                                     | Regular (`cfw_install.sh`)      | Dev (`cfw_install_dev.sh`) | JB (`cfw_install_jb.sh`)                      | EXP (`cfw_install_exp.sh`)                            |
| --------------------------------------------- | ------------------------------- | -------------------------- | --------------------------------------------- | ----------------------------------------------------- |
| Base CFW phases (1/7 -> 7/7)                  | Runs directly                   | Runs directly              | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh` | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh`         |
| Dev overlay (`rpcserver_ios` replacement)     | -                               | Y (`apply_dev_overlay`)    | -                                             | -                                                     |
| SSH readiness wait before install             | Y (`wait_for_device_ssh_ready`) | -                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| launchd jetsam patch (`patch-launchd-jetsam`) | -                               | Y (base-flow injection)    | Y (JB-1)                                      | Y (JB-1)                                              |
| launchd dylib injection (`inject-dylib /b`)   | -                               | -                          | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`) | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`)        |
| Procursus bootstrap deployment                | -                               | -                          | Y (JB-2)                                      | Y (JB-2)                                              |
| BaseBin hook deployment (`*.dylib` -> `/mnt1/cores`) | -                        | -                          | Y (JB-3)                                      | Y (JB-3)                                              |
| First-boot JB finalization (`vphone_jb_setup.sh`) | -                           | -                          | Y (post-boot)                                 | Y (post-boot)                                         |
| IOMobileFramebuffer SwapEnd payload-size patch (install-gated `26.0*`/`18.*` -> 0x560 / 26.1 base; **27.0 does NOT use this — it uses force-kern, next section**) | Y              | Y                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| dyld cache `maxSlide` zero (`patch-dsc-maxslide`; **install-gated `27.*`** as of 2026-07-20 — iOS 27's cache overflows the 6 GiB region; 18.x/26.x skip it; the old `FORCE_DSC_MAXSLIDE=1` / `--force-dsc-maxslide` opt-in was removed 2026-09-30) | Y | Y                     | Y (inherited from base run)                   | Y (inherited from base run)                           |
| DSC pre-patch (`kern.hv_vmm_present` byte-5 mangle + slot reattest) | -         | -                          | -                                             | Y (pre-step, before base CFW)                         |
| DSC camera patches (12 patches across CMCapture / CoreMediaIO / AVFCapture / libMobileGestalt) | - | -                  | -                                             | Y (pre-step, same cryptex mount as hv_vmm)            |
| `watchdogd` surgical 2-insn patch + slot reattest | -                           | -                          | -                                             | Y (EXP-JB-3.5)                                        |
| Post-restore DT identity rewrite (`devicetree.img4`)| -                         | -                          | -                                             | Y (EXP-JB-6)                                          |
| `SystemVersion.plist` `ProductBuildVersion` rewrite | -                         | -                          | -                                             | Y (EXP-JB-7, opt-in via `SPOOF_BUILD`)                |
| Additional input resources                    | `cfw_input`                     | `cfw_input` + `resources/cfw_dev/rpcserver_ios` | `cfw_input` + `cfw_jb_input` | `cfw_input` + `cfw_jb_input`        |
| Extra tool requirement beyond base            | -                               | -                          | `zstd`                                        | `zstd`                                                |
| Halt behavior                                 | Halts unless `CFW_SKIP_HALT=1`  | Halts unless `CFW_SKIP_HALT=1` | Always halts after JB phases              | Always halts after EXP phases                         |

## Summary

| Component                          | Regular | Dev |  JB | EXP |
| ---------------------------------- | ------: | --: | --: | --: |
| AVPBooter                          |       1 |   1 |   1 |   1 |
| iBSS                               |       2 |   2 |   3 |   3 |
| iBEC                               |       4 |   4 |   4 |   4 |
| LLB                                |       6 |   6 |   6 |   6 |
| TXM                                |       1 |  12 |  12 |  12 |
| Kernel (base)                      |      28 |  29 |  28 |  28 |
| Kernel (JB methods)                |       - |   - |  59 |  59 |
| Kernel (EXP methods, `hv_vmm`)     |       - |   - |   - |   6 |
| DeviceTree base properties         |       4 |   4 |   4 |   4 |
| DeviceTree EXP identity properties |       - |   - |   - |   8 |
| DeviceTree EXP node additions      |       - |   - |   - |   1 (`/product/camera`) |
| Boot chain total                   |      46 |  58 | 117 | 132 |
| CFW binary patches (base)          |       4 |   5 |   6 |   6 |
| CFW EXP-only steps                 |       - |   - |   - |   5 (hv_vmm DSC, camera DSC ×12, watchdogd EXP-JB-3.5, post-restore DT EXP-JB-6, build-version EXP-JB-7 opt-in) |
| CFW installed components           |       6 |   7 |   9 |   9 |
| CFW total                          |      10 |  12 |  15 |  31 |
| Grand total                        |      56 |  70 | 132 | 163 |

## Ramdisk Variant Matrix

| Variant        | Pre-step             | `Ramdisk/txm.img4`               | `Ramdisk/krnl.ramdisk.img4`                                                      | `Ramdisk/krnl.img4`                            | Effective kernel used by `ramdisk_send.sh`          |
| -------------- | -------------------- | -------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------- |
| `RAMDISK`      | `make fw_patch`      | release TXM + base TXM patch (1) | base kernel (28), legacy `*.ramdisk` preferred else derive from pristine CloudOS | restore kernel from `fw_patch` (28)            | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `DEV+RAMDISK`  | `make fw_patch_dev`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_dev` (29)        | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `JB+RAMDISK`   | `make fw_patch_jb`   | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_jb` (28+59)      | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `EXP+RAMDISK`  | `make fw_patch_exp`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_exp` (28+59+6)   | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |

## Cross-Version Dynamic Snapshot

| Case                | TXM_JB_PATCHES | KERNEL_JB_PATCHES |
| ------------------- | -------------: | ----------------: |
| PCC 26.1 (`23B85`)  |             14 |                59 |
| PCC 26.3 (`23D128`) |             14 |                59 |
| iOS 26.1 (`23B85`)  |             14 |                59 |
| iOS 26.3 (`23D127`) |             14 |                59 |

## Swift Migration Notes (2026-03-10)

- Swift `FirmwarePatcher` now matches the Python reference patch output across all checked components:
  - `avpbooter` 1/1
  - `ibss` 4/4
  - `ibec` 7/7
  - `llb` 13/13
  - `txm` 1/1
  - `txm_dev` 12/12
  - `kernelcache` 28/28
  - `ibss_jb` 1/1
  - `kernelcache_jb` 84/84
- JB parity fixes completed in Swift:
  - C23 `vnode_getattr` resolution now follows the Python backward BL scan and resolves `0x00CD44F8`.
  - C22 syscallmask cave encodings were corrected and centralized in `ARM64Constants.swift`.
  - Task-conversion matcher masks and kernel-text scan range were corrected, restoring the patch at `0x00B0C400`.
  - `jbDecodeBranchTarget()` now correctly decodes `cbz/cbnz`, restoring the real `_bsd_init` rootauth gate at `0x00F7798C`.
  - IOUC MACF matching now uses Python-equivalent disassembly semantics for the aggregator shape, restoring the deny-to-allow patch at `0x01260644`.
- C24 `kcall10` cave instruction bytes were re-verified against macOS `clang`/`as`; no Swift byte changes were needed.
- The Swift pipeline is now directly invokable from the product binary:
  - `vphone-cli patch-firmware --vm-directory <dir> --variant {regular|dev|jb}`
  - `vphone-cli patch-component --component {txm|kernel-base} --input <file> --output <raw>` is available for non-firmware tooling that still needs a single patched payload during ramdisk packaging
  - default loader now preserves IM4P containers via `IM4PHandler`
  - DeviceTree patching now uses the real Swift `DeviceTreePatcher` in the pipeline
  - project `make fw_patch`, `make fw_patch_dev`, and `make fw_patch_jb` targets now invoke this Swift pipeline via the unsigned debug `vphone-cli` build, while the signed release build remains reserved for VM boot/DFU paths
  - on 2026-03-11, the legacy Python firmware patcher entrypoints and patch modules were temporarily restored from pre-removal history for parity/debug work.
  - after byte-for-byte parity was revalidated against Python on `26.1` and `26.3` for `regular`, `dev`, and `jb`, those legacy firmware-patcher Python sources and transient comparison/export helpers were removed again so the repo keeps Swift as the single firmware-patching implementation.
- Swift pipeline follow-up fixes completed after CLI bring-up:
  - `findFile()` now supports glob patterns such as `AVPBooter*.bin` instead of treating them as literal paths.
  - JB variant sequencing now runs base iBSS/kernel patchers first, then the JB extension patchers.
  - Sequential pipeline application now merges each patcher's `PatchRecord` writes onto the shared output buffer while keeping later patcher searches anchored to the original payload, matching the standalone Swift/Python validation model.
  - `apply()` now reuses an already-populated `patches` array instead of re-running `findAll()`, so `patch-firmware` / `patch-component` no longer double-scan or double-print the same component diagnostics on a single invocation.
  - unaligned integer reads across the firmware patcher now go through a shared safe `Data.loadLE(...)` helper, fixing the JB IM4P crash (`Swift/UnsafeRawPointer.swift:449` misaligned raw pointer load).
  - `TXMPatcher` now preserves pristine Python parity by preferring the legacy trustcache binary-search site when present, and only falls back to the selector24 hash-flags call chain (`ldr x1, [x20,#0x38]` -> `add x2, sp, #4` -> `bl` -> `ldp x0, x1, [x20,#0x30]` -> `add x2, sp, #8` -> `bl`) when rerunning on a VM tree that already carries the dev/JB selector24 early-return patch.
  - `scripts/fw_prepare.sh` now deletes stale sibling `*Restore*` directories in the working VM directory before patching continues, so a fresh `make fw_prepare && make fw_patch` cannot accidentally select an older prepared firmware tree (for example `26.1`) when a newer one (for example `26.3`) was just generated.
  - 26.0 and 26.0.1 GUI bring-up now patches installed DSC `IOMobileFramebuffer` only when `ProductVersion` starts with `26.0`: `_kern_SwapEnd` passes a 0x560-byte state to the 26.1 PCC userclient instead of the 26.0/26.0.1 0x548-byte state. JB host installs were validated on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and unchanged `17,3_26.1_23B85`.
- IM4P/output parity fixes completed after synthetic full-pipeline comparison:
  - `IM4PHandler.save()` no longer forces a generic LZFSE re-encode.
  - Swift now rebuilds IM4Ps in the same effective shape as the Python patch flow and only preserves trailing `PAYP` metadata for `TXM` (`trxm`) and `kernelcache` (`krnl`).
  - `IBootPatcher` serial labels now match Python casing exactly (`Loaded iBSS`, `Loaded iBEC`, `Loaded LLB`).
  - `DeviceTreePatcher` now serializes the full patched flat tree, matching Python `dtree.py`, instead of relying on in-place property writes alone.
- Synthetic CLI dry-run status on 2026-03-10 using IM4P-backed inputs under `ipsws/patch_refactor_input`:
  - regular: 58 patch records
  - dev: 69 patch records
  - jb: 154 patch records
- Full synthetic Python-vs-Swift pipeline comparison status on 2026-03-10 using `scripts/compare_swift_python_pipeline.py`:
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Real prepared-firmware Python-vs-Swift pipeline comparison status on 2026-03-10 using `vm/` after `make fw_prepare`:
  - historical note: the now-removed `scripts/compare_swift_python_pipeline.py` cloned only the prepared `*Restore*` tree plus `AVPBooter*.bin`, `AVPSEPBooter*.bin`, and `config.plist`, avoiding `No space left on device` failures from copying `Disk.img` after `make vm_new`.
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Runtime validation blocker observed on 2026-03-10:
  - `NON_INTERACTIVE=1 SKIP_PROJECT_SETUP=1 make setup_machine JB=1` reaches the Swift patch stage and reports `[patch-firmware] applied 154 patches for jb`, then fails when the flow transitions into `make boot_dfu`.
  - `make boot_dfu` originally failed at launch-policy time with exit `137` / signal `9` because the release `vphone-cli` could not launch on this host.
  - `amfidont` was then validated on-host:
    - it can attach to `/usr/libexec/amfid`
    - the initial path allow rule failed because `AMFIPathValidator` reports URL-encoded paths (`/Volumes/My%20Shared%20Files/...`)
    - rerunning `amfidont` with the encoded project path and the release-binary CDHash allows the signed release `vphone-cli` to launch
    - this workflow was packaged as `make amfidont_allow_vphone` / `scripts/start_amfidont_for_vphone.sh`
    - ~~**superseded 2026-09-23.** `amfidont` is gone, and so is the path/CDHash allowlist it provided — on macOS 26 amfid carries `com.apple.developer.hardened-process`, which gates the debugger operations a per-validation decision needs. `vphone-letmein` replaces it with a global switch held open only for the length of one launch, and `vphone-cli` (now unentitled, so it always starts) drives that itself. The URL-encoding detail above no longer applies: nothing matches on paths any more.~~
    - **That correction was itself wrong, and is reversed (2026-09-23, later the same day).** `amfidont` is the supported route again and `vphone-letmein` is deleted. Two things were measured:
      - `vphone-letmein` opened its window by writing amfid's `__TEXT`. Where the host enforces code signing system-wide the kernel validates that page on the next fault, finds no signature, and kills amfid — `EXC_BAD_ACCESS` / `SIGKILL` (Code Signature Invalid), termination namespace `CODESIGNING`, indicator "Invalid Page" — and the guest is `SIGKILL`ed too because amfid never answered. Measured twice on macOS 27.0 (26A428) arm64e: the patch lands, the read-back verifies, and the child still dies. The gate is `sysctl vm.cs_system_enforcement`, which reads **1** there and is read-only.
      - The claim that a per-validation decision is impossible was reasoning from that tool's own position. `amfidont` drives amfid through LLDB, and `debugserver` holds the Apple-private debugger entitlements; arm64 breakpoints live in the CPU's debug registers, so no page is ever dirtied. That is why it works under enforcement *and* why it can scope to one binary. **`amfidont` is an allowlist, not a global switch** — the "global switch" wording belonged to `vphone-letmein` and must not be carried onto it.
    - The URL-encoding detail above is therefore live again for `--path`, and is sidestepped entirely by allowing the **CDHash** instead, which is what the project documents. Allow `vphone-vm`, never `vphone-cli`: the entry point carries no entitlements and amfid never objects to it.
      - install (measured on this machine, 2026-09-23): `xcrun python3 -m pip install --user amfidont` → `~/Library/Python/3.9/bin/amfidont`. Apple's `/usr/bin/python3` is 3.9 and the tool re-execs Xcode's python3, so Xcode is required; Homebrew's python refuses under PEP 668.
      - run: `sudo amfidont daemon --cdhash "$(codesign -dv --verbose=4 <path>/vphone-vm 2>&1 | sed -n 's/^CDHash=//p' | head -1)" --spoof-apple --verbose`. With it running, `vphone-vm --help` exits 0 instead of being `SIGKILL`ed, and amfid stays alive.
      - it is **not** a dependency of this repo. Nothing here installs, spawns or supervises it, no Makefile target wraps it, and no Python is added to the tree for it — `vphone-cli` only detects the refusal and prints the command.
  - With launch policy bypassed, `make boot_dfu` advances into VM setup, emits `vm/udid-prediction.txt`, and then fails with `VZErrorDomain Code=2 "Virtualization is not available on this hardware."`
  - `VPhoneAppDelegate` startup failure handling was tightened so these fatal boot/DFU startup errors now exit non-zero; `make boot_dfu` now reports `make: *** [boot_dfu] Error 1` for the nested-virtualization failure instead of incorrectly returning success.
  - The host itself is a nested Apple VM (`Model Name: Apple Virtual Machine 1`, `kern.hv_vmm_present=1`), so the remaining blocker is lack of nested Virtualization.framework availability rather than firmware patching or AMFI bypass.
  - `boot_binary_check` now uses strict host preflight and fails earlier on this class of host with `make: *** [boot_binary_check] Error 3`, avoiding a wasted VM-start attempt once the nested-virtualization condition is already known.
  - Added `make boot_host_preflight` / `scripts/boot_host_preflight.sh` to capture this state in one command:
    - model: `Apple Virtual Machine 1`
    - `kern.hv_vmm_present`: `1`
    - SIP: disabled
    - `allow-research-guests`: disabled
    - current `kern.bootargs`: empty
    - next-boot `nvram boot-args`: `amfi_get_out_of_my_way=1 -v` (staged on 2026-03-10; requires reboot before it affects launch policy)
    - `spctl --status`: assessments enabled
    - `spctl --assess` rejects the signed release binary
    - unsigned debug `vphone-cli --help`: exit `0`
    - signed release `vphone-cli --help`: exit `137`
    - freshly signed debug control binary `--help`: exit `137`

## Automation Notes (2026-03-06)

- `scripts/setup_machine.sh` non-interactive flow fix: renamed local variable `status` to `boot_state` in first-boot log wait and boot-analysis wait helpers to avoid zsh `status` read-only special parameter collision.
- `scripts/setup_machine.sh` non-interactive first-boot wait fix: replaced `(( waited++ ))` with `(( ++waited ))` in `monitor_boot_log_until` to avoid `set -e` abort when arithmetic expression evaluates to `0`.
- `scripts/jb_patch_autotest.sh` loop fix for sweep stability under `set -e`: replaced `((idx++))` with `(( ++idx ))`.
- `scripts/jb_patch_autotest.sh` zsh compatibility fix: renamed per-case result variable `status` to `case_status` to avoid `status` read-only special parameter collision.
- `scripts/jb_patch_autotest.sh` selection logic update:
  - default run now excludes methods listed in `KernelJBPatcher._DEV_SINGLE_WORKING_METHODS` (pending-only sweep).
  - set `JB_AUTOTEST_INCLUDE_WORKING=1` to include already-working methods and run the full list.
- Sweep run record:
  - `setup_logs/jb_patch_tests_20260306_114417` (2026-03-06): aborted at `[1/20]` with `read-only variable: status` in `jb_patch_autotest.sh`.
  - `setup_logs/jb_patch_tests_20260306_115027` (2026-03-06): rerun after `status` fix, pending-only mode (`Total methods: 19`).
- Final run result from `jb_patch_tests_20260306_115027` at `2026-03-06 13:17`:
  - Finished: 19/19 (`PASS=15`, `FAIL=4`, all fails `rc=2`).
  - Failing methods at that time: `patch_bsd_init_auth`, `patch_io_secure_bsd_root`, `patch_vm_fault_enter_prepare`, `patch_cred_label_update_execve`.
  - 2026-03-06 follow-up: `patch_io_secure_bsd_root` failure is now attributed to a wrong-site patch in `AppleARMPE::callPlatformFunction` (`"SecureRoot"` gate at `0xFFFFFE000836E1F0`), not the intended `"SecureRootName"` deny-return path. The code was retargeted the same day to `0xFFFFFE000836E464` and re-enabled for the next restore/boot check.
  - 2026-03-06 follow-up: `patch_bsd_init_auth` was retargeted after confirming the old matcher was hitting unrelated code; keep disabled in default schedule until a fresh clean-baseline boot test passes.
  - Final case: `[19/19] patch_syscallmask_apply_to_proc` (`PASS`).
  - 2026-03-06 re-analysis: that historical `PASS` is now treated as a false positive for functionality, because the recorded bytes landed at `0xfffffe00093ae6e4`/`0xfffffe00093ae6e8` inside `_profile_syscallmask_destroy` underflow handling, not in `_proc_apply_syscall_masks`.
  - 2026-03-06 code update: `scripts/patchers/kernel_jb_patch_syscallmask.py` was rebuilt to target the real syscallmask apply wrapper structurally and now dry-runs on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` with 3 writes: `0x02395530`, `0x023955E8`, and cave `0x00AB1720`. User-side boot validation succeeded the same day.
- 2026-03-06 follow-up: `patch_kcall10` was rebuilt from the old ABI-unsafe pseudo-10-arg design into an ABI-correct `sysent[439]` cave. Focused dry-run on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` now emits 4 writes: cave `0x00AB1720`, `sy_call` `0x0073E180`, `sy_arg_munge32` `0x0073E188`, and metadata `0x0073E190`; the method was re-enabled in `_GROUP_C_METHODS`.
  - Observed failure symptom in current failing set: first boot panic before command injection (or boot process early exit).
- Post-run schedule change (per user request):
  - commented out failing methods from default `KernelJBPatcher._PATCH_METHODS` schedule in `scripts/patchers/kernel_jb.py`:
    - `patch_bsd_init_auth`
    - `patch_io_secure_bsd_root`
    - `patch_vm_fault_enter_prepare`
    - `patch_cred_label_update_execve`
- 2026-03-06 re-research note for `patch_cred_label_update_execve`:
  - old entry-time early-return strategy was identified as boot-unsafe because it skipped AMFI exec-time `csflags` and entitlement propagation entirely.
  - implementation was reworked to a success-tail trampoline that preserves normal AMFI processing and only clears restrictive `csflags` bits on the success path.
  - default JB schedule still keeps the method disabled until the reworked strategy is boot-validated.
- Manual DEV+single (`setup_machine` + `PATCH=<method>`) working set now includes:
  - `patch_amfi_cdhash_in_trustcache`
  - `patch_amfi_execve_kill_path`
  - `patch_task_conversion_eval_internal`
  - `patch_sandbox_hooks_extended`
  - `patch_post_validation_additional`
- 2026-03-07 host-side note:
  - reviewed private Virtualization.framework display APIs against the recorder pipeline in `Sources/VPhoneVirtualMachineKit/HostDevices/VPhoneScreenRecorder.swift`.
  - replaced the old AppKit-first recorder path with a private-display-only implementation built around hidden `VZGraphicsDisplay._takeScreenshotWithCompletionHandler:` capture.
  - added still screenshot actions that can copy the captured image to the pasteboard or save a PNG to disk using the same private capture path.
  - `make build` is used as the sanity check path; live VM validation is still needed to confirm the exact screenshot object type returned on macOS 15.
- 2026-03-15 tooling source sync update:
  - removed ad-hoc `git clone` source fetching from `Scripts/setup_tools.sh` and `scripts/setup_libimobiledevice.sh`.
  - added pinned git-submodule sources under `scripts/repos/` for: `trustcache`, `insert_dylib`, `libplist`, `libimobiledevice-glue`, `libusbmuxd`, `libtatsu`, `libimobiledevice`, `libirecovery`, `idevicerestore`.
  - setup scripts now initialize required submodules via `git submodule update --init --recursive <path>` and stage build copies under local tool build directories.
- 2026-06-15 cloudOS 26.5 (23F77) JB retargeting — P0 (sudo/setuid):
  - **JB-04 `patch_hook_cred_label_update_execve` (P0, sudo/setuid) — FIXED.**
    Root cause: `findVfsContextCurrentByShape()` pinned a 5-word prologue ending
    in `ldr x1, [x0, #0x3E0]`; the uthread offset drifted to `#0x3F0` on 26.5
    (`0x3E8` on macOS 26.5.1 KDK), so the exact match returned 0 hits.
    Fix: resolve `vfs_context_current` generically — symbol first, else the stable
    4-word prologue prefix (`pacibsp; stp x29,x30,[sp,#-0x10]!; mov x29,sp;
    mrs x0,tpidr_el1`) followed by *any* `ldr x1,[x0,#imm]` (imm left unpinned);
    uniqueness still required. Reveal: on the decompressed kernelcache the prefix
    matches 5 sites, exactly one followed by an `ldr x1,[x0,#imm]` →
    `vfs_context_current` @ va `0x8D7F39C` (foff `0x1D7B39C`). Validated via
    `make test_jb_patches`: both `jb.hook_cred_label.{ops_retarget,c23_cave}` emit.
  - Symbol oracle for the above: macOS 26.5.1 KDK (`KDK_26.5.1_25F80`) —
    `kernel.release.vmapple` + `Sandbox.kext`/`AMFI.kext` (arm64e) carry full nlist
    symbol tables for the XNU/Sandbox functions stripped from the vphone600 cache.
  - Remaining 26.5 JB failures (8) still open: `task_conversion_eval` (inlined),
    `proc_security_policy` + `proc_pidinfo` (shared `_proc_info` switch refactored,
    `cmp #0x21` bound gone), `io_secure_bsd_root` (iOS-only, absent from KDK),
    `mac_mount`, `spawn_validate_persona` (iOS-only), `vm_map_protect`,
    `kcall10`/`sysent`.
- 2026-06-16 cloudOS 26.5 (23F77) JB retargeting — the 8 remaining P1 failures, all FIXED.
  Ground truth: IDA (idasql) on the decompressed `kernelcache.research.vphone600`,
  symbolicated via the macOS KDK oracle; XNU source cross-check. Validation:
  `make test_jb_patches` → every supported cloudOS kernel applies with **0** `[-]`
  failures (84 patches each). All anchors are version-independent
  (semantic/Capstone/call-graph), no pinned offsets/indices.
  - **JB-11 `proc_security_policy` + JB-12 `proc_pidinfo` (shared root cause).**
    The `sub wN,wM,#1 ; cmp wN,#0x21` switch anchor matched TWO sites on 26.5; the
    naive first-match grabbed the wrong one (`decodeWakeReason`, lower address).
    Replaced the whole `findProcInfoAnchor` with two source-backed finders in
    `KernelJBPatcherBase.swift`: `findProcSecurityPolicy()` locates the unique
    function that loads `PRIV_GLOBAL_PROC_INFO` (1002 = `0x3EA`, a stable
    `bsd/sys/priv.h` ABI value) into `w1` ahead of `priv_check_cred` →
    `_proc_security_policy` @ va `0x927E330` (stub entry `mov x0,#0; ret`);
    `findProcInfoInternal()` = its sole caller via `blIndex` → `_proc_info_internal`
    @ `0x927B38C` (proc_pidinfo is now inlined there). proc_pidinfo NOPs the unique
    `ldr x0,[x0,#0x18]; cbz x0; bl; cbz/cbnz wN; mov w0,#0x16(EINVAL); sub wN,wM,#1`
    guard pair → `0x927BDA8` / `0x927BDB0`.
  - **JB-08 `task_conversion_eval_internal`.** Inlined; recovered via the unique
    `"…pineapple on pizza…"` panic-string function (`task_get_special_port_from_user`).
    The 26.1 matcher failed only because the compare operands swapped
    (`cmp x0,x9` vs `cmp x9,x0`). Rewrote `collectTaskConversionCandidates` to accept
    the kernel_task-vs-{X0,X1} compare in EITHER operand order. Unique hit
    `cmp x0,x9 → cmp xzr,xzr` @ va `0x8D087A8`.
  - **JB-?? `io_secure_bsd_root`.** `AppleARMPE::callPlatformFunction` (refs both
    `"SecureRoot"`+`"SecureRootName"`). The match-bit compare-context moved >0xA0 back
    (sync code inserted), breaking the old lookback. Re-anchored on the unique
    `csel Wd,wzr,Wn,<cond>` whose `Wn` is built as `kIOReturnNotPrivileged`
    (`movk Wn,#0xE000,lsl#16` — IOKit error high half). `csel w22,wzr,w9,ne →
    mov w22,#0` @ va `0x7B30E10`. Dropped the pinned `[x19,#0x11A]` field offset.
  - **JB-?? `mac_mount`.** Wrapper still uniquely identified by the twin gates among
    `mount_common` callers (`__mac_mount` @ `0x8EC04F0`). Site 1 (`tbnz wFlags,#5 →
    mov w?,#1` preboot reject) unchanged → NOP @ `0x8EC06FC`. Site 2 folded on 26.5:
    `add x?,#0x70 ; ldrb w8,[x?,#1] ; tbz w8,#6` → `ldrb w8,[x16,#0x71] ; tbnz w8,#6`.
    Re-anchored `findStateGate` on the `ldrb wN,[x,#imm] ; tbz/tbnz wN,#6` pair (the
    `#6` role bit is the stable semantic) and clear the loaded reg → `mov x8,xzr`
    @ `0x8EC072C`.
  - **JB-?? `spawn_validate_persona`** @ `0x91C0D4C` (reached from the spawn
    entitlement wrapper, intact). The trailing `mov x?,#0 ; ldr x?,[x?,#0x490] ; casa`
    corroboration lowered differently on 26.5; re-anchored `matchPersonaHelper` on the
    dual sibling reject `ldr [base,#8];cbz / ldr [base,#0xc];cbz` (same base + same
    deny target + deny `mov w?,#1`), preceded by the `[_,#0x18]` sibling guard. NOP
    both cbz → `0x91C0DF8` / `0x91C0E00`.
  - **JB-25 `vm_map_protect`** @ `0x8DCA0A8`. The 26.1 `mov #6;bics;b.ne;tbnz#22;and
    #~X` block was recompiled; the per-entry apply path now narrows protection with a
    runtime W^X mask register before `pmap_protect_options`
    (`lsr wT,wFlags,#7 ; and w3,wT,wMask`, `mov wMask,#5`). Widening the mask `#5 → #7`
    makes the AND a pass-through so the requested protection (incl. the stripped bit)
    reaches the pmap — strictly permissive (`prot&7 ⊇ prot&5`). `mov w27,#5 → mov
    w27,#7` @ `0x8DCA30C`.
  - **JB-?? `kcall10` / sysent.** `findNosys()` matched an unrelated tiny
    `mov w0,#0x4e; ret` stub; the real `_nosys` is a large handler the sysent rows
    actually point to (112/558 entries). Rewrote `findSysentTable()` to find the table
    STRUCTURALLY (no `_nosys` dependency): the longest run of valid 24-byte `sysent`
    rows (chained auth-rebase `sy_call` into __TEXT_EXEC + sane
    `sy_return_type/sy_narg/sy_arg_bytes`). Base @ foff `0x7693B0` (558 rows);
    `sysent[439]` (`SYS_kas_info`) @ foff `0x76BCD8`; cave + 3 entry writes emit.

## The cryptex merge stops shelling out (2026-09-23)

Eleven subprocess call sites in `CryptexFilesystemPatcher*` were doing work this
process can do directly. Two of them changed what lands on the volume, so they are
recorded here rather than only in the commit.

**`tar` → `VPhoneArchive`.** The last three `runProcess("/usr/bin/tar", …)` calls in
the package are gone: `cfw_input.tar.zst` into the scratch directory, `iosbinpack64.tar`
and the former `AppleParavirtGPUMetalIOGPUFamily.tar` onto the mounted volume. Those three used
`VPhoneArchiveExtractor` with the `.ontoGuestVolume` preset, so `--zstd` was no longer
passed (the filter is detected, and libzstd is static in the xcframework).

- **Behaviour change:** `.ontoGuestVolume` includes `--no-overwrite-dir`, which the two
  guest-volume `tar` calls did *not* pass — they passed only `--preserve-permissions`.
  Directories that iosbinpack64 and the GPU bundle shared with the system volume kept
  their own mode, owner and mtime instead of taking the archive's. That is what
  `cfw_install.sh` had always passed GNU tar (`--preserve-permissions --no-overwrite-dir`);
  the Swift port dropped the second flag, and that restored shell parity at the time.
- Ownership and exact modes are unchanged: the step runs as root, where `/usr/bin/tar -xf`
  already implied `-p` and restored numeric owners. That is why the scratch-directory
  extraction also used `.ontoGuestVolume` despite the name — the preset is what bsdtar
  did as root, and several of those members were copied onto the volume verbatim.

## GPU bundle now comes from the selected PCC image (2026-09-24)

The application no longer ships `AppleParavirtGPUMetalIOGPUFamily.tar`. During
`fw prepare`, `vphone-cli` creates a temporary PV=3 VM, boots it in DFU, and
restores the selected cloudOS IPSW through its own `VPhoneRestoreBridge`. The
preparer copies `AppleParavirtGPUMetalIOGPUFamily.bundle` from the sealed System
volume into the VM restore tree and removes the temporary VM. This is the
default path; `--gpu-driver-bundle` reuses a validated bundle instead. Both
cloudOS 26.1 and 26.4 PCC AEA key URLs returned HTTP 403 on 2026-09-24, so
the preparer no longer requests those keys before the temporary restore.
Both the JB host-mount installer and the filesystem merge copy this staged
bundle into the iPhone guest. The 26.4 `23E5207q` restored bundle has
`DTPlatformVersion=26.4`, `CFBundleVersion=64.4.4`, and binary SHA-256
`29ba36c7bc87d82c40fa1cecdf357e7a383fa70eb46df0d75869f5ac562aedbc`.
It lacks the compiler-plugin dylib present in the 26.1 bundle. A first boot
without it connected vphoned but left the VM window black: `MTLCompilerService`
repeatedly aborted in `messageHandler`, and `backboardd` reported
`XPC_ERROR_CONNECTION_INTERRUPTED` after repeated Metal compilation attempts.
The repository now builds `Siblings/GraphicLoader/main.mm` (the 0xjohnnydev compiler
plugin reimplementation) into an arm64e iPhoneOS dylib. `build.sh` signs and
compresses it into `vphone-cli.app/Contents/Resources/gpu/compiler-plugin.tar.zst`.
`fw prepare` decompresses and merges that dylib into the firmware-sourced GPU
bundle, and both JB installation paths require it. This adds a guest payload;
it does not patch the Apple GPU driver binary.

**`find -name '._*' -delete` → `deleteAppleDoubleFiles`,** and this one was nearly a
silent regression worth writing down. On a volume with native extended attributes,
**Foundation does not show `._*` entries at all**: `FileManager.contentsOfDirectory` and
`enumerator(at:)` both omit them, because Foundation reads such a name as the partner
file's metadata rather than as a file. `fileExists(atPath:)` compounds it by answering
*true* for a `._x` that is not in the directory. Measured on APFS:

| how the file was made | in `readdir` | in `contentsOfDirectory` |
|---|---|---|
| `open(2)` (what tar and libarchive do) | yes | **no** |
| `Data.write(to:)` / `FileManager.createFile` | **no** — folded into the partner's xattrs | no |

So the first port of this sweep — a `FileManager.enumerator` walk — found nothing,
deleted nothing and reported success, on exactly the files it exists to remove. The
shipped version walks with `opendir`/`readdir` and removes with `unlink(2)`, which is
what `find` did. `chownRecursively` shares that walk for the same reason. Both are
covered by `Tests/FirmwarePatcherTests/CryptexFileOpsTests.swift`, whose fixtures are
made with `open(2)` and asserted with `readdir` — a Foundation-built fixture would make
the test pass by having nothing to find.

**The rest are like-for-like:** `chmod` → `FileManager.setAttributes`, `chown -R 0:0` →
`lchown` over that walk (BSD `chown -R` defaults to `-P`, so symlinks are not followed),
`ln -sf` → `createSymbolicLink` after removing what was there, with the one deliberate
difference that a real directory in the link's place is now an error instead of ln(1)'s
silent nested link. `diskutil image resize --plist | plutil -extract max raw` loses the
shell and `plutil`: the plist is parsed in-process, starting at `<?xml` so that a warning
on diskutil's merged stderr can no longer be handed back as the `--size` argument.

## iOS 26.4 location delivery uses an app hook (2026-09-25)

The guest's locationd accepts simulation requests but did not deliver a usable
fused fix to Maps. This change adds no Apple binary patch. SystemHook loads
`libvlocation.dylib` into app processes, where it supplies the vphoned-published
coordinate through `CLLocationManager` for authorized clients. The location
state is an atomically replaced JSON file, and removal restores the native
path. Maps showed the Tokyo and Apple Park coordinates in the running 26.4 VM;
the automatic SystemHook injection path was verified after relaunching Maps.

**Removed (2026-09-28).** The hook worked around a symptom of the former EXP
patches (issue #438), which `standard` now leaves off; see the note at the top.
SystemHook no longer loads `libvlocation.dylib`, the bundle no longer ships it,
and vphoned's `location.*` methods call IcliKit directly again. A guest that
already has `/usr/lib/libvlocation.dylib` keeps the file, but nothing loads it.

## `fw patch` re-patches the originals, not its own output (2026-09-30)

No new Apple binary patch. This changes how every boot-chain patch in this
document is applied, so it is recorded here.

**The defect.** `FirmwarePipeline` patched each component in place: load the
file, run the patchers, save over the same path. Run `fw patch` a second time on
the same VM and the patchers were handed the first run's output, found none of
the shapes they had already replaced, and the component failed —
`Patch site not found: iBSS`, taking the whole run down at the second component.
`fw prepare` refuses to re-extract over an existing restore tree
("A restore tree already exists at …. Remove it, then prepare the firmware
again."), so there was no recovery path either: a VM could be patched exactly
once, for its whole life. Editing a VM's `PatchSelection.plist` to turn a patch
off and re-running was therefore impossible, which is why the only way to test a
preset change was to build a new machine, and why hand-editing the recorded
`PatchPlan.plist` was being used to get around it.

**Not the same defect as issue #532's second failure.** That one was a single
patcher, `DyldSharedCacheMISTrustAuthPatcher`, not recognising its own post-patch
shape on 27.0 — a DSC patcher, over a cache `cfw install` handles, fixed on
2026-09-30 by teaching `locateSite` the `pacibsp ; mov x0,#0 ; retab` form (see
row 17). This one is structural and sits above every boot-chain patcher: it
would bite even if each patcher were perfectly self-recognising, because nothing
kept the bytes they were meant to match against.

**The fix.** `FirmwarePipelineOriginals.swift`. The first run copies each
boot-chain file into `<vmDirectory>/FirmwareOriginals/`, mirroring its path
under the VM bundle, before anything is written; every later run loads from that
copy. `fw patch` is idempotent by construction — same VM, same plan, same bytes
on disk however many times it runs — and the pristine container is also put back
immediately before `loader.save`, because `ContainerFirmwareLoader.save`
repackages the IM4P it finds at the destination and would otherwise wrap the
second run's payload in the first run's container.

The stash is a direct child of the VM directory and never of the restore tree,
so `findRestoreDirectory` (which matches a directory *name* containing
"Restore") and the component globs (rooted at the restore tree, or
non-recursive in the VM root) cannot resolve a component to its own copy.

**Turning a patch off now reverts it.** When the resolved plan selects nothing
for a component — either every patch blocked, or the whole patch set dropped so
no patcher is built at all — the unpatched image is copied back. A component
nobody has ever patched is not rewritten, so its modification date stays where
the restore left it.

**Two components opt out** (`restorable: false`): `Filesystem`
(`CryptexFilesystemPatcher`) and `Manifest` (`ManifestHashPatcher`). Both name
`BuildManifest.plist`, but neither is a patcher over that one file — the first
rewrites cryptex images across the restore tree, the second rewrites hashes that
describe files other steps produced. Restoring the manifest alone would describe
a tree that no longer exists. Both are `.less`-only, and `.less` is excluded from
the mechanism outright so a `.less` run over a CFW-patched VM cannot read "this
variant builds no boot-chain patchers" as "put the boot chain back".

**Existing VMs.** A machine patched by an earlier build has no stash, so the
first run under the new code would adopt its already-patched bytes as the
"original". That case is detected rather than accepted: if the component then
fails to patch, the copy is deleted — so it never becomes the baseline — and the
error says the VM was patched by a build that kept no originals and that the
restore tree must be removed and `fw prepare` re-run. Only `patchSiteNotFound` is
rewritten this way; every other failure means what it says and passes through.

Covered by `FirmwarePatcherTests/Pipeline/FirmwarePipelineOriginalsTests.swift`
(7 tests), which drives `patchComponents` over a synthetic component whose
patcher flips one byte and — like every real patcher — reports no site once that
byte is flipped. The real boot chain needs firmware fixtures that are not in the
repository. The same harness with `restorable: false` reproduces the old
failure, so the test for the fix and the test for the defect differ only in the
descriptor.

## The MIS online-authorization patch leaves `standard` (2026-09-30)

No new Apple binary patch. Row 17 (`mis_trust_auth`) is now **off by default**
and renamed `dyld-cfw-mis_trust_auth` → **`dyld-exp-mis_trust_auth`**, which the
naming rule requires: `effect` is `exp` for a patch `standard` leaves off.
Renamed with it: `DyldSharedCacheMISTrustAuthPatcher.patchID` and the
`on(...)` gate in `VPhoneCustomFirmwareInstaller`. The `cfw patch-mis-trust-auth`
verb and the patcher itself are unchanged and still work when the patch is
ticked on.

**What forced it.** On a *pristine* 24A435 cache — `iPhone17,3_27.0_24A435` +
cloudOS `26.4-23E5207q`, first `cfw install` on a fresh VM — the patcher cannot
find its site at all:

    Error: Patch site not found: checkTrustAndAuthorization: the prologue at
    0x22406F814 neither seeds 0xE8008026 nor already reads
    `pacibsp ; mov x0, #0 ; retab` — MIS has been rewritten

and `cfw install` dies there, after the lockdown-mode patch and before
everything that follows. The cache really was pristine: the same log shows a
first-time `maxSlide 0x20000000 -> 0x0` and fresh writes from the lsd, libxpc
and lockdown-mode patchers. So this is **not** the already-patched-anchor case
fixed earlier the same day for 26.x — 24A435's `checkTrustAndAuthorization`
genuinely matches neither shape `locateSite` accepts.

**And the message was wrong.** MIS has *not* been rewritten. Measured on the
pristine 24A435 SystemOS cryptex (`043-70113-702.dmg.aea`, decrypted with
`fw aea-key` + `/usr/bin/aea` and mounted read-only; `cfw patch-mis-trust-auth
--dry-run` against it reproduces the failure verbatim, same VMA):

| | 26.6.2 | 24A435 |
|---|---|---|
| function | `0x1BC6AE364` | `0x22406F814` |
| seed | `mov w21, #0x8026 ; movk w21, #0xe800, lsl #16` @ `+0x4C` | `mov w23, #0x8001 ; movk w23, #0xe800, lsl #16` @ `+0x34` |
| reaches `0xE8008026` | seeded directly, **subtracts** down (`sub w21, w21, #0x2` → `…8024`) | **adds** up, `add w26, w23, #0x25` @ `+0x124` |
| return register | `w21` (the seeded one) | `w26` (derived) |

A whole-image decode of `libmis` (94,984 instructions, `0x224060000`–`0x2240BCC23`)
finds **zero** mov-family instructions with immediate `0x8026` and **zero** raw
`0xE8008026` words: on 24A435 the constant is never written literally at all.
Everything else is as the patcher expects — the naming literal at `0x2240BCC23`
occurs once, has exactly one adrp+add reference (`0x22406FB1C`) and that
reference is inside the function; the nearest preceding `pacibsp` is the
function start itself, and the instruction before it is an unconditional `b`.
So the location routes were right and only `findSeededError` missed.

`findSeededError` now accepts both, and the two are not interchangeable. The
`0x8026` low half stands on its own. The `0x8001` low half is only the bottom of
the MIS error range and proves nothing by itself, so it is accepted only when
the same function also contains an `add w<result>, w<seed>, #imm` that
arithmetically equals `0xE8008026`; the scan stops at the next function's
`pacibsp`. That corroboration is not decoration: the function *preceding*
`checkTrustAndAuthorization` on 24A435 carries the identical
`mov w8, #0x8001 ; movk w8, #0xe800` idiom 18 instructions earlier, which is
also why the seed window stays forward-only from the function start. Matching is
on Capstone-decoded immediates and registers throughout, and nothing new is
written, so no new encoder and no keystone trip.

**A version gate went on the declaration with it.** `experimental` is
`Kind = All`, so without one it would still turn this patch on for a 27 guest
and produce an unbootable VM — and after the matcher fix it would now succeed in
doing so. `applicability` is `iOSBase: .oneOf([.major(18), .major(26)])`. That
is not a preference (a preference belongs in a preset's block list, and
`standard` blocks it too) but the statement `applicability` exists for: applying
it on 27 breaks the guest. An unreadable base satisfies only `.any`, so an
unknown release skips the patch, which is the safe direction.

**Why teaching the patcher the new shape is not, by itself, the answer.** Even
when it applies, this patch stops an iOS 27 guest booting (issue #532:
`TXM [Error]: Errno: selector: 45 | 78` → `dyld[1]: Library not loaded:
/usr/lib/libSystem.B.dylib … (no such file, no dyld cache)` → `initproc failed
to start`). Making it apply on 24A435 without also taking it out of `standard`
would have converted a failed install into a guest that installs and then does
not boot. Both were done, in that order.

**VERIFIED (2026-09-30):** with the patch out of `standard`, `cfw install
test-27.0` completes, and `iPhone17,3_27.0_24A435` + cloudOS `26.4-23E5207q`
**boots clean** — `panicked: false`, vphoned answering 6s after launch,
SpringBoard running (pid 36), `apps.list` returning 264 apps. **Issue #532 is
closed**, and its cause is confirmed to have been this patch rather than
anything else in the 27 install.

**What replaced it.** `libmisfix.dylib` already reaches the same outcome from
userspace, and by the better route — it steers the call rather than forging the
return. `vpWidenedOptions` in `VPhoneGuestComponents/MISFix/MISFixSignature.c`
sets `RespectUppTrustAndAuthorization = kCFBooleanFalse` in the options
dictionary; libmis calls `checkTrustAndAuthorization` only when that flag is
set, so `0xE8008026` is never produced, and because the ordinary success path
still runs, the `info` dictionary (`CdHash`, `Entitlements`, `SignerType`,
`TeamID`, `SigningID`, `ProfileUUID`) is filled for real. No cache page is
written and nothing is re-attested, so there is nothing for TXM to reject.

**The gap this leaves, stated plainly.** `cfw install` injects `libmisfix.dylib`
into `installd` and `misagent` only, so the hook covers *installation*. An app
signed with a **free personal-team** certificate is launched by SpringBoard,
which asks MIS itself and is not hooked, so on a 26.x base that launch can still
hit `0xE8008026` — a regression against the 2026-09-30 on-device validation of
row 17 on 26.6.2. Ad-hoc / `ldid`-signed apps are unaffected either way: they
carry no provisioning profile, so the online-authorization branch is not
reached, and `AllowAdHocSigning` is what they need. Paid-team profiles were
never affected. Closing the SpringBoard gap means injecting the same hook there,
which cannot be done with a load command (SpringBoard's load-command padding at
`0x548` is not free — inserting would overwrite 56 bytes of the first section)
and so has to go through SystemHook's `posix_spawn` interposition.

**Effect on the shipped presets.** `standard` adds `dyld-exp-mis_trust_auth` to
its block list, mirrored in `FirmwarePatchSetCatalog.manualOnlyPatches` via the
new `FirmwarePatchSetCatalog.misTrustAuthPatch`; `The shipped preset plists match
the built-in copies` checks the two agree. `experimental` is `Kind = All` and so
still turns it on, which is correct: that preset is documented as everything the
bundle declares, including patches a 26.4 guest does not survive.

## An interpose does not cross the shared cache (2026-09-30)

**This supersedes the paragraph above that says the hook "covers
*installation*".** It does not. `libmisfix.dylib` reaches misagent and nothing
else that matters, and no version of it can reach installd, because
`__DATA,__interpose` replaces **call sites** in the images dyld links and every
call site on installd's path is inside the cache:

```
MobileInstallation.framework  →  libmis.dylib        (cache to cache)
libmis.dylib                  →  libMobileGestalt    (cache to cache)
```

Measured on test-26.4, `libmisfix[726]`, with `LogQueries` on, the query log
carrying each caller's image (`MISFixCallerImage`, `dladdr` on the return
address) and the validation log made unconditional. One
`devicectl device install app` of a paid-team-signed AirBuild.app produced
exactly one line from installd:

```
libmisfix[726]: MGCopyAnswer(BuildVersion) from installd passed through
```

`from installd` is the finding: the only call the hook catches is the one the
**main executable** makes itself. misagent works for that reason and no other —
its own binary calls `MGCopyAnswer`, three times per install, each answered
`-> override`.

What installd did instead, in the same capture:

```
amfi_interface_query_bootarg_state returned error Function not implemented
cdhash: <private> is trusted
Trust evaluate failure: [leaf IssuerCommonName LeafMarkerOid SubjectCommonName]
Skipping a profile because of error 0xe8008012.
+[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]:
    80: Failed to verify code signature of …/AirBuild.app : 0xe8008015
```

Three things follow, and each corrects something previously written here:

1. **The signature was never the problem.** `cdhash … is trusted`. The failure
   is the profile: libmis walked the installed profiles and skipped every one
   with `0xE8008012` — this device is not in `ProvisionedDevices` — leaving
   `0xE8008015`, "a valid provisioning profile for this executable was not
   found".
2. **libmis resolved a UDID without going through the interpose.** No
   `MGCopyAnswer(UniqueDeviceID)` line exists from installd, yet the comparison
   plainly happened. Its other route is closed —
   `amfi_interface_query_bootarg_state` returns `ENOSYS`, so the
   `amfi_emulate_device_udid` path libmis prefers is dead on this guest and the
   MobileGestalt fallback is what ran.
3. **`AllowAdHocSigning` has never taken effect in installd.** No
   `MISValidateSignatureAndCopyInfo` line appears either, from a log that no
   longer returns early on an unconvertible path argument. `MICodeSigningVerifier`
   lives in MobileInstallation, not in installd, so that call is cache-to-cache
   too. The measured table at the top of `MISFixSignature.c` was taken by
   calling libmis directly; it is still true of libmis and was never reached
   through installd.

`DYLD_INSERT_LIBRARIES` does not change this. Commit `d44a0e9` had already
moved libmisfix from a `LC_LOAD_WEAK_DYLIB` of installd to SystemHook's insert
list, which is the strongest position an interpose can hold, and the capture
above is from that arrangement.

**What can still work.** Three routes, in the order they were judged:

- **Rewrite the callee, not the call sites.** A detour at the top of
  `MGCopyAnswer` and `MISValidateSignatureAndCopyInfo` is reached by every
  caller, cache-internal or not. It stays a guest dylib, so
  `cfw update-environment` deploys it to an existing VM and no cache page is
  written — nothing for TXM to reject, which is what makes it preferable to a
  new libmis patch after #532. It needs the process to make a cache text page
  writable (copy-on-write) and to obtain executable memory for the trampoline;
  `MISFixCacheWriteProbe.c` measures both behind `ProbeCacheWrite`, in installd
  only.
- **A shared-cache patch on libmis**, forcing the `ProvisionedDevices` check to
  pass and the ad-hoc option on. Same family as row 17, so the same risk: row 17
  is the patch that stopped a 27.0 guest booting.
- **Give the VM the right UDID instead of lying about it.** A modern UDID is
  `<chip-id>-<ECID>`; `chip-id` is fixed at `0x0000FE01` by the virtual SoC but
  the ECID is chosen at `vm create`, and the SHSH blob is personalised against
  it either way. A VM created with the ECID of a device the team has already
  registered needs no hook at all. It does not help an ad-hoc IPA, which has no
  profile to match.

**A mistake in the first probe, recorded because it is easy to repeat.** dyld
applies interposing to `dlsym` as well as to call sites, so
`dlsym(RTLD_DEFAULT, "MGCopyAnswer")` returns *libmisfix's own replacement* —
the probe measured its own text and never touched the cache. It then asked for
`VM_PROT_WRITE` in place of `VM_PROT_EXECUTE` on the page it was executing
from, which faults on the next instruction fetch and crash-looped installd
until the flag was cleared.

A handle-scoped `dlsym` is interposed too — measured, on a handle to
libMobileGestalt itself — so there is no spelling of `dlsym` that answers this.
What dyld leaves alone is the interposing image's own imports, which is why
`MISFixDetour` takes an address that libmisfix obtained with `&`, and refuses
to take a name at all.

## An Xcode install works, and what it took (2026-09-30)

Measured on test-26.4, `xcrun devicectl device install app` with
`AirBuild-Debug.ipa` — a paid team's app (`QDJ93ZUQ9B`), signed
`Apple Development`, whose embedded profile provisions eight real devices and
no VM:

```
App installed:
• bundleID: plus.yellow.AirBuild
• installationURL: file:///private/var/containers/Bundle/Application/9A626C1C-…/AirBuild.app/
```

and it launches. So does a `codesign --sign -` bundle with no certificate and
no profile at all. Four separate refusals had to go, in this order, and each
one was only visible once the one before it was gone.

1. **The interpose never ran.** Replaced by `MISFixDetour`: a four-word
   absolute jump at the top of the callee, the displaced instructions
   relocated onto an `mmap`ed trampoline, the target page taken
   copy-on-write. Installed in installd's own address space, so nothing on
   disk and no other process changes — which is the whole difference between
   this and row 17, the libmis cache patch that stopped a 27.0 guest booting.
   Measured: `detour: MISValidateSignatureAndCopyInfoWithProgress at
   0x1bf41c830 in libmis.dylib`.

   `MISValidateSignatureAndCopyInfo` itself is a thunk in front of the
   `…WithProgress` body, shorter than the jump, and `MISFixDetour` refuses it
   with `MISFixDetourTooShort` rather than write over whatever follows. Its
   callers are covered anyway, because it branches into the hooked function.

2. **`0xE8008015`, no valid profile.** Widening the options does not help a
   CMS-signed app: `AllowAdHocSigning` is about ad-hoc signatures, and this one
   is real. The profile has to actually install, and misagent refuses it
   because a VM's UDID is in no `ProvisionedDevices`. misagent asks
   `MISProfileGetValue(profile, "ProvisionsAllDevices")` *first* and only
   consults the device list when that is false — so `MISFixProfileScope.c`
   detours `MISProfileGetValue` and answers that one key `true`. The profile
   then installs for real and MIS validates the app against it:

   ```
   misagent: Installing provisioning profile: 50806e9b-…
   MISValidateSignature(…/extracted/Payload/AirBuild.app) -> 0x0
     info[SigningID] = plus.yellow.AirBuild   info[TeamID] = QDJ93ZUQ9B
     info[SignerCertificate] = <1484 bytes>   info[Entitlements] = <7 entries>
     info[ValidatedByProfile] = true          info[SignerType] = 3
   ```

   Nothing is faked: the signature, the certificate, the entitlements and the
   cdhash are the ones Apple issued. The only claim widened is which devices
   the profile covers.

3. **`0xE8008012` from `-[MIInstallableBundle _installEmbeddedProfilesWithError:]`.**
   Kept as a backstop for a profile that still cannot install, in
   `MISFixInstallPolicy.c`: the real implementation runs, and a refusal is
   logged and turned into "there is no profile" rather than a failed install.

4. **`-[MICodeSigningVerifier performValidationWithError:]`, line 424, "Failed
   to extract signer identity".** The gate behind the gate, and the one that
   stops an ad-hoc signature: MIS accepts the bundle and MobileInstallation
   then wants a CMS leaf certificate out of it, which `codesign --sign -`
   does not produce.

   The verifier already knows what to do. It carries `allowAdhocSigning` as a
   settable property — the same shape as the MIS option — and installd never
   turns it on, so `MISFixInstallPolicy.c` forces the getter. The real
   validation then succeeds and fills `signingInfo` for real.

Both Objective-C hooks are swizzles, not detours. A method list is data, so
replacing an implementation reaches every caller without making any cache text
writable; where that is available it is strictly better.

### The dead end that proved the shape of the fix

Before `allowAdhocSigning` was found, `performValidationWithError:` was forced
to return `YES` after it had failed. That got no further:

```
-[MIExecutableBundle codeSigningInfoByValidatingResources:…]: 1306:
    Code signing identifier ((null)) does not match bundle identifier (wiki.qaq.vphone.signtest)
```

The verifier had bailed before storing anything, so its caller read a nil
signing identifier. A refusal can be allowed through; an answer that was never
computed cannot be invented. The override was removed once the property made
it unnecessary, and the rule generalises to every gate above MIS.

The class's interface came from the runtime, not from a disassembly:
`class_copyMethodList` and `class_copyIvarList` printed into the note log.
`MISFixInstallPolicy.c` still does that, but only when a selector it expects
has gone, which is the one moment the list earns its few hundred lines.

### Still refused, deliberately

A bundle with no signature at all (`0xE800801C`) and an app with no
`application-identifier` entitlement (`MIInstallerErrorDomain` 63). Both are
real absences rather than policy, and everything downstream needs what they
are missing. Unsigned bundles reach the guest through vphoned's
`apps.install`, which re-signs in the container and never involves installd.

### A trap in the measurement, not in the guest

Two runs failed with `0xE8008017` on a bundle whose signature was fine. The
IPA had been repacked on the host with `zip -r`, which writes AppleDouble
`._*` files next to every resource; they break the sealed resource envelope.
`COPYFILE_DISABLE=1 zip -X` after deleting them, and the same bundle installs.
Worth remembering before reading `0xE8008017` as a guest-side gate.

## One route for libmisfix, SpringBoard included (2026-09-30)

Row 20. On test-27.0 (`iPhone17,3 27.0 (24A435)`) a paid team's IPA installed
through installd — `ValidatedByProfile = true` — and was then refused at
launch with "Unable to Verify App":

```
SpringBoard[36]: Trust evaluate failure: [leaf IssuerCommonName LeafMarkerOid SubjectCommonName]
SpringBoard[36]: validation failed because of missing trust and/or authorization (0xe8008026)
```

That is row 17's failure, raised by SpringBoard's own launch-time call into
libmis. libmisfix already declines that check — `RespectUppTrustAndAuthorization
= false` in `MISFixSignature.c` — but SpringBoard never carried it.

**Why 26.4 looked fine.** test-26.4's `PatchPlan.plist` was written before
`dyld-exp-mis_trust_auth` left `standard`, so that guest's cache still carried
row 17 and SpringBoard's check was short-circuited there. 24A435 is outside
row 17's gate, so 27.0 was the first guest where the launch depended on the
hook. SpringBoard is started the same way on both, below.

### The first fix was a load command, and it was built on a misreading

The first commit (7a41371) linked libmisfix into SpringBoard with
`LC_LOAD_WEAK_DYLIB`, as installd and misagent then were. SpringBoard's header
has 16 spare bytes on both 23E246 and 24A435 (`sizeofcmds` 1336, first section
at 1384), so that needed a `/mf` root alias and an `inject-dylib
--reclaim-source-version` that dropped `LC_SOURCE_VERSION` to leave the signer
room. It worked — AirBuild launched on test-27.0 after a cold boot — and it
was reverted the same day, because the reason given for it was wrong.

It rested on "SpringBoard does not carry SystemHook", read off
`vphone-systemhook.log`: SystemHook's constructor writes a line for any
`.app/` executable and SpringBoard's never appeared. That log cannot show it.
The first writer is always a root xpcproxy, which creates the file 0644, and
every later line from a mobile process is dropped silently. The only `.app/`
lines in it came from DeviceOMatic, which runs as root. SignTest, a sandboxed
mobile app with no line either, has `/usr/lib/SystemHook-vphone.dylib` in the
`usedImages` of its own crash report.

### What SpringBoard actually carries

A temporary probe in libmisfix read each process's `KERN_PROCARGS2` — the
environment the kernel copied at exec, which survives dyld pruning a variable
it refuses — alongside `environ`, `dlopen(RTLD_NOLOAD)` of SystemHook and
`amfi_check_dyld_policy_self`. On test-27.0:

| Process | `DYLD_INSERT_LIBRARIES` at exec | SystemHook | dyld policy |
| --- | --- | --- | --- |
| SpringBoard, boot (pid 36) and respawned | `SystemHook-vphone.dylib` | present | `0x17f` |
| installd, misagent | `SystemHook-vphone.dylib:libmisfix.dylib` | present | `0x17f` |

So the chain works in SpringBoard; what it lacked was the second entry. Which
libraries to insert is decided in the **parent**, at the spawn. installd and
misagent are started through xpcproxy, whose SystemHook asks
`vpIsMISFixTarget`. SpringBoard's job is `POSIXSpawnType` App and launchd
starts it itself — the launchd hook's spawn log has every neighbouring
xpcproxy child but not SpringBoard's pid — and the launchd hook inserted
SystemHook alone. SystemHook's list naming SpringBoard was never consulted for
it. The `_Conclave` key on SpringBoard's job turned out to be irrelevant.

### One route for libmisfix

- `vpIsMISFixTarget` and `vpMISFixFor` moved to
  `Shared/InjectionEnvironment.h`, and the launchd hook asks them as
  SystemHook does. A target gets `VP_MIS_FIX` inserted beside SystemHook
  whichever process starts it, and only when `/usr/lib/libmisfix.dylib`
  exists, so a guest without it never names a missing library.
- `vpInsertHooks` had a latent bug on that path: with SystemHook already in
  the environment and only the extra library to add, it built the new
  `DYLD_INSERT_LIBRARIES` and then discarded it, because substitution was
  keyed on `addHook` alone. xpcproxy rebuilds its child's environment, so it
  never showed. `make test-injection-environment` covers it.
- No guest binary carries a load command for libmisfix. The declarations
  `system-installd-cfw-adhoc_signature`, `system-misagent-cfw-device_identity`
  and `system-springboard-cfw-launch_authorization` are gone — rows 18–20
  below describe what they were — and `cfw install` renames each `.bak` an
  earlier install left back over the patched binary and removes `/mf`. The
  SystemHook route inserted libmisfix into installd and misagent regardless of
  those declarations, so unticking one never turned the hook off; libmisfix now
  ships with `system-launchdaemons-boot-environment` like the other hooks.
- `inject-dylib --reclaim-source-version` and its test were removed with the
  only caller that needed them.
- SystemHook's logs are opened 0666 and `fchmod`ed on each open, so the owner
  widens a file an earlier root writer created. Sandboxed processes still
  cannot reach `/var/mobile/Library/Caches`; their absence from the log means
  nothing, and a crash report's `usedImages` is the check.

Inside SpringBoard libmisfix installs the MIS detours only:
`MISFixInstallPolicy.c` returns at once outside installd, so MobileInstallation
is never loaded into SpringBoard or misagent to be swizzled. SpringBoard is
not in vphoned's `udidHookedDaemons`: it never asks for the UDID, and stopping
it restarts the home screen.

**Validated with the insertion, on fresh VMs (2026-09-30).** test-26.4
(`iPhone17,3 26.4 (23E246)`) and test-27.0 (`27.0 (24A435)`), both on cloudOS
26.4 (23E5207q), deleted and recreated from local IPSWs with `vm create` and
this `cfw install`, so no binary on either ever carried a libmisfix load
command. On both, from the first boot:

```
launchdhook: event=inserted+misfix child=36 path=/System/Library/CoreServices/SpringBoard.app/SpringBoard
libmisfix[36]:  env at exec has DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib:/usr/lib/libmisfix.dylib
libmisfix[253]: (misagent) the same; installd the same, with its MISValidate… detour in place
```

SpringBoard's lines now appear in `vphone-systemhook.log` too. No new `.ips`
from SpringBoard, installd or misagent. AirBuild installed through installd
(`ideviceinstaller`) opens on both. The one `panic-full` on each guest is the
post-restore reboot `vm create` makes before `cfw install` has put the dyld
cache in place (`initproc failed to start … libSystem.B.dylib`), not a boot of
the installed guest.

**Validated first with the load command, on test-27.0 (2026-09-30).**

```
libmisfix[36]: loaded into /System/Library/CoreServices/SpringBoard.app/SpringBoard
libmisfix[36]: detour: MISValidateSignatureAndCopyInfoWithProgress at 0x22406d13c in libmis.dylib
libmisfix[36]: MISValidateSignature(…/AirBuild.app) -> 0x0
apps.launch plus.yellow.AirBuild -> {"frontmost_verified":true,"pid":375}
```

after a cold `vm stop` / `vm start`: SpringBoard reaches the home screen,
carries libmisfix from boot, no new `.ips` from SpringBoard, installd or
misagent, and AirBuild — a paid team's dev-signed IPA installed through
installd — opens to its own sign-in screen instead of "Unable to Verify App".
trustd still logs `Trust evaluate failure: [leaf IssuerCommonName LeafMarkerOid
SubjectCommonName]`; that evaluation is what `checkTrustAndAuthorization`
consumes, and it is no longer asked.

## The host is told the configured UDID (2026-09-30)

No binary change. `vpIsMISFixTarget` (`VPhoneGuestComponents/Shared/InjectionEnvironment.h`)
adds `lockdownd` and `remoted`, so both spawn hooks insert `libmisfix.dylib`
into them. There only the MobileGestalt interpose acts:
`MISFixProcessOnlyNeedsIdentity` keeps the two MIS detours out of their copy of
libmis. lockdownd then answers `GetValue UniqueDeviceID`, and remoted puts in
the RSD handshake, the UDID set through `udid.set`. The hook now also matches
the obfuscated key remoted asks with (`re6Zb+zwFKJNlkQTUeT+/w`), and declares
`MGCopyAnswerWithError` with its real three arguments; the two-argument
prototype crashed remoted.

The third place the host reads the UDID, the USB serial string, is set by
vphoned (`VPhoneDaemon/Native/vphoned_usb.m`, entitlement
`com.apple.private.usbdevice.setdescription`), not by a patch.

Validated on test-27.0: `idevice_id`, lockdown and `remotectl show` report the
override after `udid.set` and after a reboot, and the guest's own after
`udid.clear`. Details and the measurements are in
`Research/Guest/xcode_install_signature_gate.md`, "The host sees it too".

## vphoned accessibility client entitlements (2026-09-30)

`VPhoneDaemon.entitlements` adds three true booleans:
`com.apple.private.accessibility.inspection`, `com.apple.accessibility.api`,
and `com.apple.private.accessibility.look-me-up-setup`. All 258 existing
upstream 2.2.3 keys and values are preserved, including the USB entitlement
and keychain access groups. No daemon or AX bootstrap code changes.

**Live evidence is from release 2.1.5, not 2.2.3.** Its actual daemon was
re-signed with only these three additions: all 257 original entitlement
values and all 51 file-backed Mach-O sections were unchanged. Strict code
signature verification, bundle validation, and preflight passed.

With identical fresh application lifecycles, the original daemon's tree
query and its alias failed with `-25215`. The re-signed daemon returned
12 nodes for Settings, 23 for Calculator, and 9 for Clock through both tree
routes, with non-null hit-test results. These results repeated after a
second full host-assisted VM boot.

Warm queries can work after another client initializes AX, so they alone
do not establish fresh-client readiness. The three keys were tested
together; each key's individual necessity was not isolated. Upstream
2.2.3 has passed the profile-preservation assertion but has not been
live-tested with this change.

## Opt-in native accessibility hierarchy (2026-09-30)

The opt-in native bridge behind ui.tree with nested:true follows private iOS
attribute 5001 (immediate children) and checks each edge against attribute 5002
(parent) using CFEqual identity. The existing flat interface continues to use
icli's visible-element query; this bridge does not infer ancestry from frames,
labels, identifiers, or the visible-element array. Primary attribute mappings
are in [MCPAXNodeSource.m](https://github.com/witchan/ios-mcp/blob/8f46b68/MCPAXNodeSource.m)
and [MCPAXAttributeBridge.m](https://github.com/witchan/ios-mcp/blob/8f46b68/MCPAXAttributeBridge.m).

An isolated entitled helper on an iOS 27 research VM returned 176 Settings
nodes with 173 matching parent back-references and 3 mismatches, 44 Calculator
nodes with 42 matches and 1 mismatch, and 66 Clock nodes with 65 matches and
no mismatch. Settings and Calculator are explicitly partial. Tests cover
unnamed, offscreen, zero-frame, and frameless structure; live snapshots preserve
unnamed containers and repeated objects through snapshot-local references.
Node, depth, query, and deadline limits
are explicit, and a missing or failed messaging timeout blocks the AX query.
Foreground PID stayed unchanged and accessibility switches were restored for
each helper run. Temporary services were unloaded and their directories removed.
Helper evidence is not an integrated daemon
release or cold-start readiness claim.

Installed-daemon cold-read testing subsequently exposed an initial Settings
snapshot containing only its unavailable root. The native walker now retries
only the first root label copy with error -25215 when this invocation actually
enabled accessibility, after one 400 ms readiness wait. It shares the original
deadline and query budget, preserves the initial error in readiness metadata,
and retains unresolved errors. No child error or action is retried.

After a supported bundle installation and VM restart, the first Settings
CLI read recovered and returned 220 nodes with 217 matching parent checks and
3 disagreements; subsequent reads returned 176. Fresh Calculator returned
44 partial nodes and Clock 66 complete nodes. Flat queries and the nested
alias also worked. These are diagnostic inspection results on that VM,
not full action-cycle performance acceptance or repeat cold-start reliability.

The Release build also reproduced SIGPIPE failures in bundle validation:
early-exiting grep and awk closed their file/vtool producers under pipefail.
Those probes now drain producer output while keeping matching, first-platform
selection, failure propagation, and all signature checks. The full workspace
build and strict signatures then passed.

## Guest audio: a HAL plugin, and an iPad's own audio node (2026-10-02)

The guest never produced sound, although `vphone-vm` has always attached a
virtio sound device with a host output sink. Two faults; the full reveal is
`Research/Guest/virtio_sound.md`.

| Patch | Component | Effect |
| --- | --- | --- |
| `system-virtiosound-cfw-hal_plugin` (new) | `/System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver`, `cfw install` and `cfw update-environment` | Installs the CoreAudio HAL plugin for `AppleVirtIOSound`, built from `VPhoneGuestComponents/VirtIOSound`. |
| `devicetree-cfw-ipad_audio` (new) | An iPad guest's installed DeviceTree, `fw patch` | Replaces `/product/audio` with the board tree's node (`DeviceTreePatcher.presentBoardAudio`), all properties as the board has them except its `AAPL,phandle`. |
| `preboot-cfw-devicetree_board_audio` (new) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment` | The same replacement for an iPad VM patched before it (`vphone-cli cfw patch-dt-board-audio`), from the board tree in `FirmwareOriginals`. When that has none (a VM patched before `fw patch` kept it), the tree is first recovered from the VM's IPSW in `~/.vphone/ipsws`, matched by BuildManifest version, build, product type and board, and kept in `FirmwareOriginals`; with no matching IPSW the repair is skipped with one `[!]` line naming the fix. |
| `devicetree-cfw-product_haptics_node` (new, 2026-10-03) | Every guest's DeviceTree, `fw patch`: an iPhone guest's one tree, an iPad guest's installed tree and its `RestoreDeviceTree` | Removes `/product/haptics` (`DeviceTreePatcher.removeHaptics(from:)`), whatever the variant and the board. |
| `preboot-cfw-devicetree_haptics` (new, 2026-10-03) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment`, every guest | The same removal for a VM patched before it (`vphone-cli cfw patch-dt-haptics`); it needs no board tree. A guest that booted before it keeps cached MobileGestalt answers, which vphoned drops at its next startup, see below. |

`fw patch` now reads an iPad's board tree through the `FirmwareOriginals` stash,
so `DeviceTree.<board>.im4p` stays in the VM folder after the restore tree goes.

**Why the haptics node goes.** vphone600 carries `/product/haptics`
(`closed-loop`, `supports-3rd-party-haptics`). With it MobileGestalt answers
yes to `DeviceSupportsHaptics` and `DeviceSupportsClosedLoopHaptics`,
ToneLibrary sets `playHapticTracks` on every tone, and mediaplaybackd builds a
`CHHapticEngine` whose server, `com.apple.audio.hapticd` in audiomxd, never
answers on a VM: six one-second XPC timeouts, `FigHapticEngineCreate` fails
4099, and `itemfig_rebuildRenderPipelinesAndBoss` fails the item — the
ringtone never starts although its route and audio queue are built. It was
first seen on iPad guests, whose own trees (`DeviceTree.j410ap`, `.j820ap`)
have no such node, and fixed there by making the node follow the board. An
iPhone guest (iPhone99,11, iOS 27.0) then failed the same way — the same
hapticd timeouts, the same 4099, the tone dropped — and a real iPhone's tree
does have the node, so following the board cannot fix it. What is missing is
the actuator and the haptic server, and no VM has either; every guest's tree
loses the node, and the board-following patch and its Preboot repair were
replaced by these two. The restore tree loses it as well: an iPad guest's
`RestoreDeviceTree` is patched exactly as an iPhone guest's tree is, and
restore reads nothing from the node. Without it the guest answers as a device
with no Taptic Engine does and tones play. The answers are cached in
`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`,
written at first boot, so a guest that has already booted keeps the old ones
until that file is removed and the guest restarted; a guest created with the
patch never has them. The host cannot remove it: the file is on the guest's
Data volume, a FileVault volume whose keys are in the guest's SEP, which the
host sees locked and cannot mount (the volume the installer mounts beside
System, s3, is xART). vphoned removes it at startup instead, when it is older
than the Preboot `devicetree.img4` the guest booted
(`VPhoneDaemon/Daemon/GuestMobileGestaltCache.swift`): the host rewrites that
tree only with the VM stopped and only when a repair changed it, so an older
cache was worked out from an older tree. It logs `vphoned: MobileGestalt
cache predates the device tree, removed it; …`, and `/v1/health` reports
`mobilegestalt_restart_pending` until the guest restarts, since running
processes keep the answers they read. An existing guest therefore needs `cfw
update-environment`, one boot, and one restart. This is no patch declaration
of its own: it writes nothing to the tree, and with the repairs off the tree
is not rewritten and the cache stays. Removing the file by hand (`files.remove`, then
`system.reboot`) is what vphoned does, less the reboot. Detail and the
measurements: `Research/Guest/virtio_sound.md` §7.

**Why a plugin.** The cloudOS kernel has `AppleVirtIOSound` and its user client,
but only macOS ships the HAL plugin that drives it; neither cloudOS nor any iOS
image has one. `VPhoneVirtIOSound.driver` speaks the same user-client selectors
as the macOS `AppleVirtIOSound.driver`, on AudioServerDriver as Apple's own
plugins are. It is output only. Its host checks are `make -C VPhoneGuestComponents
test-virtiosound`; `Build/ValidateBundle.sh` checks the staged bundle's signature
and factory.

**Why the audio node.** On an iPad guest VirtualAudio never initialized
(`RoutingSettings_J98.cpp:805`, then `:856`, `PRECONDITION FAILURE`), so audiomxd
had no device at all and Safari video would not start. J820's routing code builds
its stereo and webcam microphone sub-ports from the tuning directory the device
tree's `acoustic-id` names. `devicetree-cfw-product_audio_node` gives every guest
the D47 iPhone's node, `acoustic-id = 8018`; the iPhone image ships `AID8018`, the
iPad image ships `AID2028`/`AID2029` (J820's is 2029). Removing the
`stereo-sound-recording` flag was tried first and only moved the failure to the
webcam sub-port, whose flag comes from AVFCapture's per-board table; that attempt
is not in the tree. iPhone guests are unchanged.

**system-virtualaudio-cfw-speaker_route_throws.** The counterweight to the
virtio plugin's `PuffinOutput` masquerade. iOS's speaker-route walker treats
the synthetic speaker's missing protection metadata as fatal six different
ways — five C++ throws out of an AudioServerPlugIn callback (terminate) and
one direct `bl std::terminate` after a fault log — and MediaExperience's
serialization replay hits the first of them on every launch. The patcher
(`FirmwarePatcher/CustomFirmware/ExecutablePatches/VirtualAudio/`) branches
each site to the function's own epilogue: anchored on the exception strings,
shape-matched through Capstone (allocation call, x1 message load, constructor
call, `brk` or branch terminator; the terminate as the last call of the fault
logger's back-to-back `bl` run), never an offset. The installer stage re-seals
the `.plugin` bundle after `patchMachO` re-signs the binary — the outer
CodeResources still named the old bytes, and the code-signing monitor killed
audiomxd on load. Research detail: `Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's mute-set throw — the chime's last blocker (2026-10-03)

`system-virtualaudio-cfw-mute_set_throw` (new), same
`VirtualAudio.plugin` binary, verb `cfw patch-virtualaudio-mute`, applied by
`cfw install` and `cfw update-environment` riding the same `patchMachO`
staged copy as `patch-virtualaudio` — staging restarts from the pristine
`.bak`, so the two verbs must share one call.

**Fault.** Establishing the speaker route asks the HAL device itself to
unmute: `Device_HAL_Common`'s set wrapper pushes `kAudioDevicePropertyMute`
('mute'/'outp'/0) and reads it back. The HAL *server* pre-validates the
device-level set at `HALS_UCPlugIn.cpp:1190` and rejects it 'what'
(2003329396) without ever forwarding the selector to the plugin — proven by a
guest probe whose `hasProperty:` override saw 60 selectors and never 'mute',
while the control-level 'bcvl' set on the same device succeeds (so no
plugin-side fix exists on iOS). The wrapper answers the failure by throwing
`CAException("Unable to set property data.")` out of the callback;
`RoutingManager.cpp:3515` catches it and abandons the route — the aggregate's
master stays `Null_Device`, no `PVMSetCurrentState`, and the boot charge chime
is silent. Every caller ignores the wrapper's return value, so the fix is the
same shape as the walker patch: branch the throw to the wrapper's own
epilogue. The FAIL/EXCEPTION diagnostics still log; the route proceeds.

**Reveal** (all Capstone-decoded, no literal address): anchor on the cstring
containing `Set mute value of %u on HAL device`, referenced exactly once in
`__text`; the wrapper is the enclosing pacibsp-to-pacibsp function. The site
is the wrapper's CAException block — allocation call, vtable/status stores
into `[x0]`/`[x0, #8]`, throw call, `brk` terminator; a CAException carries no
message string, so the walker patch's runtime_error shape does not match, and
the block runs 17 instructions where that scan budgeted 16 (the new scan
budgets 32). Discriminated from iOS 27's second, unrelated CAException (the
deactivated-device throw) by requiring an adrp+add forming a cstring
containing `Unable to set property data.` within 0x40 bytes above the site —
the EXCEPTION log that always precedes this throw. The epilogue is the
wrapper's single `retab` walked back through the shared guarded-canary chain;
it cannot be searched forwards from the throw because the throw sits below
the epilogue, so the retab is enumerated within the wrapper's bounds.
Verified on the real iPadOS 26.6.2 and iOS 27 binaries: exactly one site and
epilogue each (0xee224 → 0xedfcc; 0x111ac8 → 0x11179c), byte-identical
re-runs, and both verbs composing on one copy. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's SpeakerProtection chain — the speaker route's last blocker (2026-10-03)

`system-virtualaudio-cfw-speaker_graph_chains` (new), *not* a binary patch:
it rewrites the tuning set's `graph_configurations.plist` on the guest system
volume (`/Library/Audio/Tunings/<acoustic ID>/VAD/`, e.g. `AID2029` for an
iPad Pro 13; the ID varies by board, so `cfw install` and
`cfw update-environment` walk the `Tunings` directory instead of naming one).
Verb `cfw patch-virtualaudio-graph-configurations` on a staged copy, format
preserved (binary in, binary out), idempotent. An image with no tuning sets —
iOS 27's VirtualAudio carries no `graph_configurations.plist` reference at
all — is skipped quietly. Patcher:
`FirmwarePatcher/CustomFirmware/CustomFirmwareVirtualAudioGraphConfigurations.swift`.

**Fault.** With the walker and mute-set throws quieted and
`ProductIDOverride=8010` (the only accepted ProductID whose VAD map covers
`'crnp'`, the RingtonePreview category), the ringtone route change runs its
full pipeline — route list built, aggregate master `PuffinOutput` — and then
dies building the route's DSP chain. `graph_configurations.plist` gives every
`speaker_*` configuration `chainType "clhs"`, and the DSP chain factory
(0x117628, iPadOS 26.6.2) switches on it: `clhs` builds the HAL
SpeakerProtection chain, whose config constructor (0x3dcccc) calls
`findDevice("Speaker")` (0x3dc460) → registry lookup →
`LockWeakPtrOrThrow` throws `Could not lock weak ptr (:60)` — a VM's device
registry has no physical Speaker. The chain is destroyed,
`RoutingManager.cpp:1774` logs `Failed to activate a route list`, the route
change fails `nort` (1852797556), and the guest stays silent with no
fallback. `dflt` — the chainType every `beam_mic_*`/`omni_mic_*`
configuration already ships — takes the generic graph chain instead: no
device lookup, the configuration's `graph` DSP file (which the tuning set
ships for every speaker configuration) is loaded directly. The patch flips
every `speaker_*` entry's `chainType` from `clhs` to `dflt` and touches
nothing else. Static analysis ruled out every null-tolerant patch of
`findDevice` itself: `buildParams` (0x3dc518) dereferences the returned
`Device*` immediately at two call sites (0x3dcda4, 0x1182a4), so a null
return would crash instead of degrade. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's speaker-protection gate — the decline after the build (2026-10-03)

`system-virtualaudio-cfw-speaker_protection_gate` (new), same
`VirtualAudio.plugin` binary, verb `cfw patch-virtualaudio-sp-gate`, riding
the same `patchMachO` staged copy as the other two VirtualAudio verbs
(`patch-virtualaudio`, `patch-virtualaudio-mute`) in both `cfw install` and
`cfw update-environment`. Patcher:
`FirmwarePatcher/CustomFirmware/ExecutablePatches/VirtualAudio/CustomFirmwareVirtualAudio.swift`.

**Fault.** With layers 1–3a quieted (walker throws, mute-set throw, plist
chains), the ringtone route change still declines at its last step:
`RoutingHandler_Playback_GenericConfig1.cpp:223` — "HAL Speaker Protection is
missing. Failing route %s" — because the route's device list calls for HAL
Speaker Protection, a capability only a physical codec reports. The route is
*finished* when the decline lands: virtual stream on `pspk` at the matched
rate, the `dflt` DSP chain built, IOProc cache warm. The capability query
never leaves VirtualAudio — the ASD plugin's file logs show 0 'caps'
selectors reaching it — so no plugin-side fix exists. The handler's failure
path puts the vdef's output stream on `Null_Device`: a StartIO "Running"
signature still appears (on `Null_Device`, `VAD [vdef] AggDev 8`), which is
how an earlier validation was fooled; the audible era's signature is StartIO
on the `PuffinOutput` aggregate (`AggDev 2`). The guest is completely silent
and the volume is dead.

**Reveal** (all Capstone-decoded, no literal address): anchored on the
cstring containing `HAL Speaker Protection is missing. Failing route` — a
format three routing handlers share — and discriminated by requiring the
enclosing pacibsp-to-pacibsp function to also reference
`RoutingHandler_Playback_GenericConfig1.cpp`. Within that one handler, the
gate is the branch whose forward target heads the log block: a target at or
above which, within 0x100, the format's adrp+add sits, and the file name's
adrp+add too (both builds hold them 0x34 apart, 0x84 above the block's
entry), and whose target opens the os_log allocation itself (`mov w0,
#<size>` followed by the allocation call). That last shape check is what
kills the near miss: iOS 27 holds a `cbz x0, 0x146360` whose target lands
0xC4 below the format ref, inside the string window but on a `sub`, not a
block head. The scan decodes each word rather than trusting Capstone's jump
group — the gate is a `tbz` (`tbz w21, #0` on 26.6.2, `tbz w19, #0` on
iOS 27), which the group tagging misses — through
`decodeConditionalBranchTarget`, which reads the 19-bit immediates of
`b.cond`/`cbz`/`cbnz` and the 14-bit one of `tbz`/`tbnz`, sign-extended.

**The write.** The gate's branch is left untouched — that is what lets the
anchor resolve the site again on an already-patched binary. What changes is
the log block's own entry: the `mov w0, #0x14` opening the os_log becomes a
`b` back to the gate's fall-through, so a taken gate lands directly on the
success continuation the handler already built. Verified on both builds
that the fall-through never re-reads the register the gate tested (w21 /
w19), so no stale verdict flows on. The block is entered only by the gate's
jump — the instruction above the head is an unconditional branch on both
builds (`b 0x136d28` at 0x136874; `b 0x1467a0` at 0x14639c), checked before
anything is written, so rewriting the head orphans no fall-through.
Idempotency is exact, not marker-based: a re-run finds the head holding an
unconditional branch, decodes it, and requires its target to be the gate
site's own successor — a shape no compiler emits — before reporting
already-patched; a foreign branch at the head is an error, never
overwritten. Verified on the real iPadOS 26.6.2 and iOS 27 binaries: the
expected sites on both (gate 0x136620 → head 0x136878, fall-through
0x136624; gate 0x1460b4 → head 0x1463a0, fall-through 0x1460b8), writes
byte-identical on re-run, and all three VirtualAudio verbs composing on one
staged copy with a clean second pass. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's volume-mode precondition — the decline after the gate (2026-10-03)

`system-virtualaudio-cfw-volume_mode_precondition` (new), same
`VirtualAudio.plugin` binary, verb `cfw patch-virtualaudio-volume-gate`,
riding the same `patchMachO` staged copy as the other three VirtualAudio
verbs in both `cfw install` and `cfw update-environment`. Patcher:
`FirmwarePatcher/CustomFirmware/ExecutablePatches/VirtualAudio/CustomFirmwareVirtualAudio.swift`
(the handler is resolved once for both gates, in `locatePlaybackHandler`).

**Fault.** With layers 1–3 quieted (walker throws, mute-set throw, plist
chains, speaker-protection gate), the same ringtone handler declines the
same finished route one step later, at
`RoutingHandler_Playback_GenericConfig1.cpp:252`: the route's
software-volume mode must be the packed pair
`(present, kHardwareOnlyReadOnly)` — present-flag in bit 32 over the
mode's low 32 bits, expected value `0x1_00000003`. The virtio plugin's
device reports `SoftwareHardwareMix`, so the precondition fails and the
handler *throws* a `std::logic_error` — unlike the SP gate's quiet
decline — which unwinds past the route's own teardown into
`RoutingManager.cpp:3520`: the route change fails `nort`, the session is
torn down onto `Null_Device`, and the guest is silent with the volume
dead. iPadOS 26.6.2 logs this as a bare "Precondition failure."; iOS 27
still carries the assert text
`softwareVolumeModeForPerDefaultScope.has_value() && softwareVolumeModeForPerDefaultScope.value() == VolumeControl::SoftwareVolumeMode::kHardwareOnlyReadOnly`,
which is what named the fault.

**Reveal** (all Capstone-decoded, no literal address). The handler is the
one `locatePlaybackHandler` already resolves for the SP gate — the
function holding both the `HAL Speaker Protection is missing. Failing
route` format and the `RoutingHandler_Playback_GenericConfig1.cpp` file
name. Within it, the guard chain reads: `bl` a wrapper (ActivationParams
check, else logs `Aspen.cpp:1428` and returns 0; on hit it calls a map
getter that logs `Aspen.cpp:1445/1451` and returns the packed 64-bit
map entry), then `and xN, xRet, #0x1ffffffff` — the 33-bit packing mask
— then `add x9, xBase, #1` building the expected pair, `cmp`, and a
`b.ne` to the decline. The decline's discriminator among the handler's
three `PRECONDITION FAILURE (std::logic_error)` blocks (`:142`, `:252`,
`:270`) plus the `Aspen.cpp:729` one is `isVolumeModeComparison`: within
six instructions below a non-call branch, a `cmp` seen, then an `and`
whose immediate operand is exactly `0x1ffffffff` and whose preceding
word is a call. The inner exception-allocation labels (`cbz x19` to a
`mov w0, #0x10` sizing) pass every block-shape check; it is the mask
window that rejects them. Block layout matches the SP gate's: the
format's adrp+add 0x58 above the head, the file name's 0x2c above, the
sole entry the guard's branch, and an unconditional branch at the
pre-head — checked before anything is written.

**The write.** The comparison and its `b.ne` are left untouched; the
decline's log-block head — the `mov w0, #0xe` sizing the os_log —
becomes a `b` back to the comparison's own fall-through, so a failed
precondition lands on the continuation the handler already built. The
fall-through reloads its inputs from memory and never re-reads the
tested value, on either build. Idempotency is the SP gate's exact scheme:
a re-run finds an unconditional branch at the head and requires it to
decode to the comparison site's own successor. Verified on the real
iPadOS 26.6.2 and iOS 27 binaries: the expected sites on both
(comparison `b.ne` 0x1369c4 → head 0x138124, fall-through 0x1369c8;
comparison 0x1464e0 → head 0x1475d0, fall-through 0x1464e4), byte-
identical re-runs, and all four VirtualAudio verbs composing on one
staged copy with a clean second pass. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's speaker-protection gate, second site — the play-and-record handler (2026-10-04)

`system-virtualaudio-cfw-speaker_protection_gate` (changed: one more site,
record `system-virtualaudio-cfw-speaker_protection_gate.playback_and_record`),
same binary, same verb `cfw patch-virtualaudio-sp-gate`, which now runs the
patch once per handler in `CustomFirmwareVirtualAudio.SPGateHandler`.

**Fault.** The guest's virtio sound plugin now publishes a microphone
(`Digital Mic`, port `pmbi`; `Research/Guest/virtio_sound_microphone.md`).
A recording app asks for a route that plays and records (`cpar`), which
`RoutingHandler_PlaybackAndRecord_GenericConfig1` builds in full —
aggregate of `Digital Mic` and `PuffinOutput`, a virtual stream on each
port — and then declines at `:368` with the same "HAL Speaker Protection is
missing. Failing route %s" the playback handler declined the ringtone route
with. Before the microphone existed the route never got that far.

**The site.** The decline's format is shared by three handlers; this one
is the handler whose function also references
`RoutingHandler_PlaybackAndRecord_GenericConfig1.cpp`
(`locatePlaybackHandler(in:file:)`, the same resolution with the other file
name; neither file name contains the other). The gate and its block have
the playback handler's shape on both builds: a `tbz w9, #0x0` into a log
block that opens `mov w0, #0x14; bl`, with an unconditional branch above
the block's head, and a fall-through that reloads what it reads from the
stack and is also the join of the handler's raw-mode log path.

**The write.** As for the first site: the log block's head becomes a `b`
to the gate's fall-through; the gate's own branch stays. Verified on the
real iPadOS 26.6.2 and iOS 27 binaries: gate 0xea274 → head 0xea588,
fall-through 0xea278; gate 0x10e468 → head 0x10e6f0, fall-through 0x10e46c;
both sites written in one run, a second run reporting both already patched.
The handler's volume-mode test (`and x28, x0, #0x1ffffffff` at 0xea3fc) is
a branch between two builds of the route, not a precondition, and is not
touched.

## Guest audio through a Mac's microphone and speakers (2026-10-04)

An iPhone guest's audio node and tuning set are the D47's. Four changes take
out what they assume about its hardware; the measurements are in
`Research/Guest/virtio_sound_microphone.md` §7 and
`Research/Guest/virtio_sound.md` §9.

| Patch | Component | Effect |
| --- | --- | --- |
| `devicetree-cfw-product_audio_microphone_array` (new) | Every guest's DeviceTree, `fw patch` | Removes `supports-spatial-audio-capture` and `supports-audio-mix` from `/product/audio` (`DeviceTreePatcher.removeMicrophoneArrayClaims(from:)`). With them iOS 27's Voice Memos records through the four-microphone spatial route and the recording is silent. |
| `preboot-cfw-devicetree_microphone_array` (new) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment`, every guest | The same removal for a VM patched before it (`vphone-cli cfw patch-dt-microphone-array`). |
| `system-virtualaudio-cfw-microphone_graph_chains` (new) | `/Library/Audio/Tunings/<AID>/VAD/graph_configurations.plist` and each `*_mic*_measurement.austrip` beside it | Every `<mic>_general` configuration with a `<mic>_measurement` sibling takes the sibling's `graph`, `austrip` and `propstrip` (`patch-virtualaudio-microphone-chains`), and every AUNBandEQ in those strips has its global gain set to 0 dB (`patch-virtualaudio-microphone-gain`; +18 dB on `bottom_mic_measurement`). A set with no such pair is left alone. |
| `system-virtualaudio-cfw-speaker_raw_chains` (new) | `/Library/Audio/Tunings/<AID>/VAD/graph_configurations.plist` | Every `speaker_*` configuration other than `speaker_raw` and `speaker_measurement` takes `speaker_raw`'s `graph`, `austrip`, `propstrip` and `volumeCommands` (`patch-virtualaudio-speaker-raw`). A set with no `speaker_raw` is left alone. |

All four are on in `standard`, need no firmware change, and are in the
installer's late list, so `cfw update-environment` brings them to a VM whose
plan predates them. The tuning files themselves are untouched except for the
one parameter word in each measurement strip; a strip whose saved state is
not whole parameter records is refused rather than rewritten.

Validation on `mictest-iphone` (iPhone99,11, iOS 27.0, cloudOS 26.4):
`vphone-cli cfw patch-virtualaudio-microphone-chains` on the guest's own
plist reported `back_mic_general`, `beamformed_mic_general`,
`bottom_mic2_general`, `bottom_mic_general` and `front_mic_general`, and a
second run none; `patch-virtualaudio-microphone-gain` on its
`bottom_mic_measurement.austrip` reported `AUNBEQ_2 global gain 18.0 dB -> 0
dB`, changing one word of the saved state; `patch-virtualaudio-speaker-raw`
reported eight speaker configurations. After `cfw update-environment` and a
boot, audiomxd built the recording route with `DSP chain
'bottom_mic_measurement'` and the guest's plist read back `speaker_general:
graph=speaker_raw austrip=speaker_measurement vol=["vugd"]`.

## The paravirtual user-client allowlist joins `standard` (2026-10-04)

No new Apple binary patch and no new bytes. JB-31
(`kernel-cfw-paravirt_user_clients`, formerly `kernel-exp-`; see "Renamed" below) leaves
`standard`'s block list and `FirmwarePatchSetCatalog.manualOnlyPatches`, so a
26.x or 18.x guest made with `standard` now gets the narrow IOUserClient
sandbox allowlist for classes beginning `ApplePar`, `AppleVid`, `AppleVir` and
`IOSurfac`. On 27 nothing changes: the declaration's `iOSBase` gate is
`.oneOf([.major(26), .major(18)])`, so the patch skips by version there, and the
boot-essential `kernel-boot-iouc_sandbox_gate` (JB-10b) already opens every user
client. The pipeline's no-plan fallback in `buildComponentList` follows the same
rule (on for an 18.x or 26.x base, off for 27 and for an unreadable base), so a
pipeline built without a preset agrees with `standard`. The patcher's own default
stays false, so `KernelcacheCustomFirmwareComparisonTests` still compares against
the records the reference was taken from.

**Why.** On an iPadOS 26.6.2 guest with the old `standard`, `cameracaptured`
crash-loops at every boot: its shader prewarm (`FigCapturePreloadShadersInternal`
→ CMCapture `PrewarmThreadSafeSBPs` → NRFV3 `-[NRFProcessorV3 prewarm]`)
dies with SIGSEGV at `0xc` inside
`AppleParavirtGPUMetalIOGPUFamily`. While it crash-loops, the first process to
touch the AVCapture defaults blocks on a synchronous XPC to it; when a guest app
starts recording that is SpringBoard's main thread (Control Center's sensor
indicator → `AVCaptureDeviceDiscoverySession` →
`AVCaptureProprietaryDefaultsSingleton` → `csr_ensureClientEstablished`), so the
UI freezes, `audiomxd`'s recording `StartIO` waits 18 s, and the first recording
after boot fails.

**Corrected the same day:** this gate was not the cause. `cameracaptured`
already has a Metal device; it dies on a bug in the paravirtual driver's heap
textures, and row 23 of the CFW table (`libvcamcaptured` skipping the
prewarm) is what stops it. The allowlist stays on for daemons and tools that
want the GPU (#22).

**What it widens, and why that is acceptable.** Every process whose sandbox
refuses one of those classes at this gate — daemons, command-line tools and
system XPC services such as `cameracaptured`, WebKit, `spotlightknowledged`,
`callservicesd` and `vphoned` — now passes it; apps gain nothing, because their
container profile already opens these devices. The prefix match admits every
class with those first eight bytes, which on this board means the paravirtual
GPU and device clients, the paravirtual VideoToolbox decoder, the VirtIO drivers
(the Neural Engine among them) and IOSurface's clients. Every other class is
still refused, which is why the narrow patch rather than the broad gate-off is
the shape on 26.x. For a research VM whose sandbox hooks are already stubbed
(JB-09) and whose IOUC MACF gate is already open (JB-10), this was the last thing
stopping a daemon reaching a device every app reaches. See
`Research/Guest/gpu_acceleration.md`, "On in `standard`".

**Renamed.** The patch was introduced the same day (37ed2e6) as
`kernel-exp-paravirt_user_clients`, opt-in. The `{component}-{effect}-{name}`
rule derives `exp` for a patch `standard` leaves off and `cfw` otherwise, so it
is renamed **`kernel-cfw-paravirt_user_clients`** (records `.redirect` and
`.cave`), as `dyld-cfw-mis_trust_auth` was renamed the other way on 2026-09-30.
`fw patch` resolves a VM's `PatchSelection.plist` against the catalogue and
throws `unknownPatch` for an identifier nothing declares, so a VM whose record
still names `kernel-exp-paravirt_user_clients` fails there until that entry is
removed. There is no migration.

**Opting out.** `vphone-cli fw set-patches <vm> --block
kernel-cfw-paravirt_user_clients`, then re-patch.

## Guest patches follow the selection, both ways (2026-10-04)

No new Apple binary patch. This changes how every guest-side patch in this
document (the dyld shared cache rows, the guest Mach-O and file patches, the
Preboot device-tree repairs) is applied after a VM exists, so it is recorded
here. Full write-up and live validation:
`Research/Firmware/post_creation_patch_changes.md`.

**Before.** `cfw install` applied the guest half from `PatchPlan.plist`, and
turning a guest patch off on an installed VM did nothing: the step was skipped
and the patched bytes stayed. The dyld cache patches were applied in place with
no record of what they replaced.

**Now.** `cfw install` and `cfw update-environment` resolve the guest half from
the VM's current `PatchSelection.plist`, apply what is on and revert what is
off. Mach-O, entitlement and guest-file patches revert from the `.bak` beside
the file; the Preboot device tree from `devicetree.img4.bak`; the dyld cache
from `.vphone-dsc-undo.json` in the cache directory, which holds the original
bytes of every content write a cache verb makes (slot hashes are re-derived by
re-attesting, not logged). Each cache verb takes `--undo-log`/`--undo-id`, and
the hidden `cfw patch-dsc-revert` verb applies the log. What is live is recorded
in the `Guest` part of `<vm>/PatchReceipt.plist`.

**Existing VMs.** A guest installed before this change has no undo log and no
backup for the files several patches share, so those patches are reported "not
revertible" when turned off and stay recorded as live; nothing is guessed. Every
dyld row above that a cache verb idempotently re-runs keeps its undo records, so
a revert works however many installs later it happens.

**Boot chain unchanged.** Boot-chain patches still reach a guest only through a
restore (AVPBooter through `fw patch`); `fw set-patches` and `fw patches <vm>`
say so per patch.

## An iPhone guest's product description from D47AP (2026-10-04)

An iPhone17,3 guest had no Siri page, no Camera Control, no Action Button and no
Model Name, whatever its identity patches. Most of vphone600's `/product` is
`syscfg/xxxx` placeholders (flag `0x8000`) that no syscfg fills on a VM, and
MobileGestalt reads a placeholder as absent. An iPad guest already takes these
from its board tree (`devicetree-cfw-ipad_*`); an iPhone guest did not, although
its IPSW carries the iPhone's own tree, `Firmware/all_flash/DeviceTree.d47ap.im4p`.

| Patch | Component | Effect |
| --- | --- | --- |
| `preboot-cfw-devicetree_iphone_product` (new) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment`, iPhone17,3 guests (a board-presenting guest already boots its own board's description) | `DeviceTreePatcher.presentPhoneProduct` (`vphone-cli cfw patch-dt-iphone-product <dt> <board>`): fills the `iPhoneProductProperties` placeholders in `/product` from D47AP, adds `iPhoneAddedProductProperties`, and fills `/buttons/function-button_ringeren`. Only a placeholder is overwritten, only with a real board value. The board tree comes from `FirmwareOriginals`, or is recovered there from the VM's IPSW in `~/.vphone/ipsws` (`VPhoneBoardDeviceTree.need` now answers for the iPhone17,3 too). |

What is copied, and why:

| Group | Properties | What it turns on |
| --- | --- | --- |
| Name | `product-name`, `product-description` | About › Model Name |
| Siri | `assistant`, `siri-gesture`, `dictation`, `offline-dictation`, `builtin-mics` | Settings › Siri, side-button Siri, dictation |
| Buttons | `side-button-location`, `volume-up-button-location`, `volume-down-button-location`; added `ringer-button-location`, `camera-button-location`, `supports-camera-button`; `/buttons/function-button_ringeren` | Settings › Action Button and Camera Control (with Accessibility pages) |
| Display, UI | `artwork-scale-factor`, `chrome-identifier`, `compatible-device-fallback`, `display-corner-radius`, `display-mirroring`, `oled-display`, `thin-bezel`, `large-format-phone`, `ui-pip`, `ui-reachability`, `ui-background-quality`, `ui-weather-quality`, `hme-in-arkit`, `carplay-2`, `location-reminders`, `watch-companion` | the rest of D47AP's description |

Deliberately left as vphone600 has them: anything that promises hardware the VM
does not have — `bluetooth-*`, `baseband-chipset`, `nfc-express`, `exclaves-enabled`,
`has-*`, `graphics-featureset-*`, `framebuffer-identifier`, `wifi-chipset`, the
display calibration placeholders — and the vphone600-only placeholders
(`gestalt-variant-id`, `variant-name`, `thinning-product-type`,
`jetsam-properties-product-type`, `vm-supports-generative-models`).
`/buttons` keeps no `compatible`, so no button driver binds to it and the
board's function reference in `function-button_ringeren` is never followed.

Measured on iOS 26.6.2 (23G90) + cloudOS 26.4 (23E5207q), preset `standard` plus
the nine identity patches, by applying the same edit to the installed tree by
hand: Settings shows Siri, Camera Control (Camera and Accessibility pages) and
the Action Button; Siri opens from a long side-button press (HID 0x0C/0x30); the
Action Button's long press (HID 0x0B/0x2D) runs Flashlight and Camera with the
Dynamic Island, with no tweak; the search field gains dictation. The guest boots
normally. Not yet measured: the change on a VM without the identity patches, on
iOS 18.x, and a Camera Control press.

## The kernelcache reaches an installed guest without a restore (2026-10-05)

No new Apple binary patch. This adds a way to deliver the existing kernelcache
patches to a VM that is already installed, so it is recorded here.

A kernel patch toggled with `fw set-patches` could only reach an installed guest
through a restore, and a restore erases it (restored in the cloudOS ramdisk
repartitions whatever the host asks — `restore --no-erase` refuses; see
`Research/Restore/native_restore_architecture.md`). But the booting kernel lives
in Preboot as an IMG4, and iBoot accepts a modified IM4P under the original
signed IM4M — the same image4 bypass that lets `cfw install` rewrite
`devicetree.img4` there. `cfw update-kernel` (`VPhoneCustomFirmwareInstaller`
mode `.kernelUpdate`) host-mounts Preboot on a clone and swaps in a re-patched
kernelcache, keeping every volume. It re-patches the pristine kernelcache kept in
`FirmwareOriginals` with the VM's current selection
(`FirmwarePipeline.patchKernelcacheFile`, in the `.jb` variant — `.regular`
omits the AMFI/JB kernel patches and CS_KILLs launchd), so it needs no restore
tree and no prior `fw patch`. The splice is
`CustomFirmwarePostRestoreDeviceTree.kernelcacheReplacingPayload`, which carries
the whole IM4P (compression and any PAYP tail) verbatim and keeps the IMG4's
manifest.

Proven on test VMs (iPhone 27.0 24A435 + cloudOS 26.4) 2026-10-05, including a VM
with no restore tree, through the Launchpad helper: a marker in
`/var/mobile/Documents`, `kernel-exp-display_refresh_120hz` toggled with
`fw set-patches`, `cfw update-kernel`, then boot — the guest booted the
re-patched kernelcache and the marker survived. Flow: `fw set-patches` →
`cfw update-kernel`. `fw set-patches`, `fw patches` and the Launchpad inspector
route a kernel patch through `cfw update-kernel` and the rest of the boot chain
(TXM, DeviceTree, LLB, iBSS, iBEC) through the erasing restore. TXM and
DeviceTree are also in Preboot and could follow the same path later.

## Optional Settings row hiding (WIP, 2026-10-07)

Two standard-blocked declarations hide Apple Account, Game Center, iCloud and Wallet in Preferences (`system-preferences-exp-root_rows`) and Software Update in GeneralSettingsUI (`dyld-exp-settings_software_update_row`). Native discovery is restricted to reviewed 24A435 inputs. The installer uses pristine executable backups and cache undo records with page re-attestation. All five rows passed guest rollback, reapplication and reboot checks. See [research report](Guest/2026-10-07_reverse-settings-rows-report.md). Broader firmware coverage and bundled deployment remain WIP; no kernel/SEP or runtime hook changes are included.

## Pinned guest device name (2026-10-07)

Row 27. `libdevicename.dylib` makes configd publish the VM's name, which `vphone-vm` hands to vphoned after every connect and vphoned keeps in `/var/db/vphone/devicename.plist`, as the device name, and makes lockdownd refuse every rename; without the file it passes everything through. NVRAM was tried first and does not reach the guest: iBoot drops variables it does not know. It is the first library a process receives beside another: lockdownd already took `libmisfix.dylib`, so `vpInsertedLibrariesFor` in `Shared/InjectionEnvironment.h` now returns every installed library for a path and `vpInsertHookLibraries` adds each one an environment lacks. Single-library targets and their spawn log lines are unchanged. `preferences.plist` is never written: the pin is applied to configd's `SCDynamicStoreSetMultiple` publication, because the `SCPreferencesGetValue(kSCPrefSystem)` it flattens is also read and written back on configd's model-change path. Verified on iOS 27.0 (24A435) on 2026-10-07; iOS 26.x not run yet. See `Research/Guest/device_name_pinning.md` for the flow, the measurements and the verification.

## CoreDevice install proxy persona lookup (2026-10-07)

`system-installcoordination_proxy-cfw-persona_lookup` is an iOS-27 guest
compatibility patch, enabled in standard. Its root-owned marker
`/usr/lib/vphone-installcoordination-persona-lookup` enables the existing
launchd hook to allow only the system `installcoordination_proxy`, verified by
executable path, signing identifier and kernel-validated audit token, to look
up `com.apple.mobile.usermanagerd.xpc`. Other requests retain their original
sandbox check. Disabling the patch removes the marker. Both CFW install and
environment update reconcile its receipt. No kernel or proxy binary patch is
needed; an experimental entitlement-only version is restored from backup.

The original failure is a Protobox mach-lookup denial before UserManager's
persona-fetch authorization. Adding a temporary exception entitlement was
verified ineffective on the running guest and has been removed. IDA analysis
of this guest's launchd confirms the bootstrap lookup gate and name filters
2, 3 and 12. See [evidence, implementation and validation](Guest/ios27_xcode_persona_lookup.md).

## Host disk-image command migration (2026-10-08)

The migration replaces `hdiutil` because macOS 27 marks it as deprecated.
The system's `hdiutil(1)` manual recommends `diskutil image`, and command help
prints deprecation warnings directing attach, detach and convert operations
to `diskutil image attach`, `diskutil eject` and `diskutil image create from`.

No guest binary patch or preset change. On macOS 15+, CFW install and kernel
update, PCC GPU recovery, seal-tool extraction and Cryptex filesystem attachment
use `diskutil image attach`. Writable conversion uses `diskutil image create
from -format RAW`, which `diskutil(8)` identifies as the former UDRW format.
There is no hdiutil fallback or new disk-image tool abstraction: calls stay in
their existing functions. The macOS 15 `diskutil(8)` system manual already
documents image attach, create and resize. Single-hyphen options
preserve compatibility with older diskutil versions; conversion supplies
`-source` on macOS 15 and a positional source on macOS 26+. Existing function
names and CLI arguments are preserved. Eject uses `diskutil eject`; a busy image is
retried after `diskutil unmountDisk force`, avoiding the newer `eject force`
syntax on older systems. Attachment parsing retains the physical APFS store's
parent disk even when a synthesized container is reported first, and keeps
mount points containing spaces intact. PCC recovery tracks successful eject
before deleting its temporary library instead of querying `hdiutil info`.

`CryptexFileOpsTests`: all 12 existing tests pass. The
`VPhone` bundle build and bundle admission pass on macOS 27.0.1 / Xcode 27.1.
Real image attachment and execution on macOS 15 still require live validation;
no VM disk is modified by the validation tests.

## Flutter AOT executable-remap compatibility

The existing guest SystemHook component has a guarded `vm_remap` fallback for
an observed Flutter AOT callback layout whose returned RX permission disagrees
with the actual read-only destination. The fallback creates a private RW copy,
then changes it to RX; other calls pass through. No kernel patch or protection
policy change is added. See `Research/Guest/flutter_aot_remap_compatibility.md`
for exact guards, failure semantics, reproduction and validation limits.

## ProMotion joins `standard` (2026-10-09)

No new Apple binary patch and no new bytes. JB-30, the 120 Hz timing element,
leaves `standard`'s block list and `FirmwarePatchSetCatalog.manualOnlyPatches`,
so every new VM's paravirtual display advertises 120 Hz. It has no version gate,
so it lands on every base. The pipeline's no-plan fallback in
`buildComponentList` is on too, so a pipeline built without a preset agrees with
`standard`; the patcher's own `applyProMotion` default stays false, so
`KernelcacheCustomFirmwareComparisonTests` still compares against the records the
reference was taken from.

**Why.** Measured since 2026-10-04 (`Research/Guest/display_refresh_rate.md`): the
host scans out every frame the guest presents up to 120, the userland renders at
the advertised rate with no change of its own, a static screen costs what it did
at 60 Hz, and a guest with the patch booted on iPadOS 26.6.2 and iOS 27.0. The cost
is unchanged: up to twice the host CPU and GPU while the guest animates.

**Depends on Lakr233/vphone-cli#643 for iOS 26.** On an iPhone17,3 26.6.2 guest
with the 2.9.0 guest components, SpringBoard deadlocked in three of three 120 Hz
boots. Its main thread held `libvphoneattitude`'s `@synchronized` lock in the
`setDeviceMotionUpdateInterval:` hook while waiting for Core Motion's MotionThread,
which was waiting for that lock in the `isDeviceMotionActive` hook (guest spindump,
symbolicated against 23G90). #643 fixes that lock order. With its fix cherry-picked,
the same guest booted at 120 Hz and scrolled Settings at 119.3 frames per second.
Details: `Research/Guest/display_refresh_rate.md`, "iPhone 26.6.2, and the attitude
hook deadlock".

**Renamed, with a migration.** The editor titles it ProMotion and the naming rule
gives `cfw` to a patch `standard` turns on, so the record is
**`kernel-cfw-display_promotion`**. The old `kernel-exp-display_refresh_120hz`
shipped from 2.4.2, unlike the same-day `kernel-exp-paravirt_user_clients`, so a
VM may have it checked. `FirmwarePatchSetCatalog.renamedPatches` maps old to new,
and `VPhonePatchPresetStore` reads `PatchSelection.plist`, `PatchPlan.plist` and
`PatchReceipt.plist` through it: such a VM resolves instead of failing `fw patch`
with `unknownPatch`, and its kernelcache counts as already carrying the patch.

**Existing `standard` VMs** now read as wanting it in the kernelcache part and
keep 60 Hz until `cfw update-kernel` or a restore writes it.

**Opting out.** `vphone-cli fw set-patches <vm> --block
kernel-cfw-display_promotion`, then `cfw update-kernel`.
