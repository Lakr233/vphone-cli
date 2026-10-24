// FirmwarePatchSetCatalog.swift — The patch sets built into the bundle.
//
// These are the sets a preset can name as `Bundled`. They are compiled in rather
// than loaded, so `cfw install` running as root never has to open a file to learn
// what the bundle's own patches are — an external `.vphonepatchset` is the only
// thing that has to be imported and pinned first.

import Foundation
import VPhonePatchKit

public enum FirmwarePatchSetCatalog {
    /// Every bundled set, in the order the pipeline would run them.
    public static let bundled: [VPhonePatchSetManifest] = [
        FirmwareBootChainPatchSet.manifest,
        FirmwareKernelBasePatchSet.manifest,
        FirmwareKernelCustomFirmwarePatchSet.manifest,
        FirmwareKernelHypervisorPatchSet.manifest,
        FirmwareKernelFridaPatchSet.manifest,
        FirmwareResearchBoardPatchSet.manifest,
        FirmwareDeviceTreePatchSet.manifest,
        FirmwareGuestSystemPatchSet.manifest,
        FirmwareGuestDisplayPatchSet.manifest,
        FirmwareGuestIdentityPatchSet.manifest,
        FirmwareRestoreImagePatchSet.manifest,
    ]

    /// Every bundled set but the restore image, as a preset references them.
    ///
    /// Every custom-firmware preset names all of them. A preset picks patches with
    /// its selection, not by leaving a set out, so the editor always sees the whole
    /// catalogue and can turn any patch on or off.
    ///
    /// The restore image is the exception, in both directions: it customises the
    /// system before the restore, which the custom-firmware sets do after it, and
    /// only ``minimalPreset`` names it. See ``FirmwareRestoreImagePatchSet``.
    public static let bundledReferences: [VPhonePatchSetReference] =
        bundled.filter { $0.identifier != FirmwareRestoreImagePatchSet.identifier }
            .map { .bundled($0.identifier) }

    public static func manifest(identifier: String) -> VPhonePatchSetManifest? {
        bundled.first { $0.identifier == identifier }
    }

    /// Every declared patch across every bundled set.
    public static var allDeclarations: [VPhonePatchDeclaration] {
        bundled.flatMap(\.patches)
    }

    // MARK: - Built-in Presets

    /// Patches that are declared but off unless someone asks for them.
    ///
    /// The Frida relaxations widen what any process in the guest may do and
    /// nothing needs them to boot, so `standard` leaves them off. They stay in the
    /// catalogue, version-gated like everything else, and a VM can check them on.
    ///
    /// The hypervisor concealment pair is off for a harder reason: it stops a
    /// freshly restored 26.4 guest booting at all. See
    /// ``hypervisorConcealmentPatches``. The rest of the former EXP variant is
    /// off with it, bar the camera: see ``experimentalIdentityPatches``.
    ///
    /// `dyld-exp-mis_trust_auth` is off because a userspace hook now does its
    /// job: see ``misTrustAuthPatch``.
    /// `kernel-cfw-paravirt_user_clients` and `kernel-cfw-display_promotion`
    /// are not in this list: `standard` turns them on. See
    /// ``paravirtUserClientsPatch`` and ``proMotionPatch``.
    public static let manualOnlyPatches: Set<String> =
        Set(FirmwareKernelFridaPatchSet.manifest.patches.map(\.identifier))
            .union(hypervisorConcealmentPatches)
            .union(experimentalIdentityPatches)
            .union([FirmwareGuestSystemPatchSet.otaUserland, FirmwareGuestSystemPatchSet.homePodTopCap, FirmwareGuestSystemPatchSet.homePodSetupBypass, FirmwareGuestSystemPatchSet.homePodAudioProduct, FirmwareGuestSystemPatchSet.homePodWelcome, FirmwareGuestSystemPatchSet.homePodSiriSpeech, FirmwareGuestSystemPatchSet.homePodOTAUserland, FirmwareGuestSystemPatchSet.homePodSoundGlow, FirmwareGuestSystemPatchSet.homePodCryptexStaging, FirmwareGuestSystemPatchSet.homePodCryptexClass, FirmwareGuestSystemPatchSet.homePodAdHocInstall])
            .union([FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers, misTrustAuthPatch, FirmwareGuestSystemPatchSet.settingsRootRows, FirmwareGuestSystemPatchSet.settingsSoftwareUpdate, FirmwareGuestSystemPatchSet.tvTPRO, FirmwareGuestSystemPatchSet.tvOTAUserland, FirmwareGuestSystemPatchSet.tvSetupDisplayLookup, FirmwareGuestSystemPatchSet.tvLegacySetup])

    /// ProMotion: the 120 Hz timing for the paravirtual display.
    ///
    /// On in `standard`. The host's mode is 60 Hz and Virtualization has no
    /// setting for it; the guest renders at whatever rate the timing element
    /// advertises, and the host scans out every frame it presents. A guest
    /// rendering twice as often costs up to twice the host CPU and GPU while it
    /// animates, and nothing while it is static. Blocking it per VM keeps 60 Hz.
    ///
    /// Introduced opt-in as `kernel-exp-display_refresh_120hz`, which shipped from
    /// 2.4.2; renamed `kernel-cfw-display_promotion` when `standard` turned it on,
    /// as the naming rule requires. ``renamedPatches`` maps a VM's record of the
    /// old name. See
    /// `Research/Guest/display_refresh_rate.md`.
    public static let proMotionPatch = "kernel-cfw-display_promotion"

    /// Paravirtual GPU Task3: keep the guest's features and supply each owning
    /// executable's cdhash so the host retains separate shader caches across
    /// boots. On in `standard`; tvOS presets leave it off. Introduced as
    /// `kernel-exp-paravirt_gpu_task3` in development bundles; existing VM
    /// records migrate through ``renamedPatches``. See
    /// `Research/Guest/gpu_acceleration.md`.
    public static let paravirtTask3Patch = "kernel-cfw-paravirt_gpu_task3"

    /// Identifiers an installed bundle declared that a later one renamed, old to new.
    ///
    /// A VM's `PatchSelection.plist` and `PatchReceipt.plist` outlive the bundle
    /// that wrote them, and `fw patch` throws `unknownPatch` for an identifier
    /// nothing declares. Include development bundles used on real VMs as well
    /// as releases: their records need the same migration.
    public static let renamedPatches: [String: String] = [
        "kernel-exp-display_refresh_120hz": proMotionPatch,
        "kernel-exp-paravirt_gpu_task3": paravirtTask3Patch,
    ]

    /// The identifiers this bundle declares for ones a VM recorded, in order, each
    /// once.
    public static func currentIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers
            .map { renamedPatches[$0] ?? $0 }
            .filter { seen.insert($0).inserted }
    }

    /// A narrow IOUserClient sandbox allowlist for the paravirtual devices, on a
    /// base older than 27.
    ///
    /// A 26.x sandbox knows nothing of the research board's paravirtual devices,
    /// so only an app's container profile lets a process open them. A daemon or a
    /// command-line tool gets no Metal device, WebKit no hardware video decoder,
    /// and Core ML no Neural Engine. The edit allows only the four paravirt device
    /// classes, by name, and leaves every other denial in place.
    ///
    /// On in `standard`. `cameracaptured` prewarms its capture shaders on the GPU at
    /// every boot; refused the device, it crashes inside the paravirtual Metal
    /// driver and crash-loops, and the first process to touch AVCapture blocks on a
    /// synchronous XPC to it — SpringBoard's main thread when a guest app starts
    /// recording. What it widens is four class-name prefixes of devices apps already
    /// open, to processes outside an app sandbox, on a research VM.
    ///
    /// Introduced opt-in as `kernel-exp-paravirt_user_clients`; renamed `cfw` when
    /// `standard` turned it on, as the naming rule requires.
    /// On 27 the broad `kernel-boot-iouc_sandbox_gate` is boot-essential instead. See
    /// `Research/Guest/gpu_acceleration.md`.
    public static let paravirtUserClientsPatch = "kernel-cfw-paravirt_user_clients"

    /// The shared-cache short-circuit of `libmis`'s `checkTrustAndAuthorization`.
    ///
    /// Off in `standard` because `libmisfix.dylib` reaches the same outcome from
    /// userspace without editing the cache. The hook passes
    /// `RespectUppTrustAndAuthorization = false` in the options dictionary, and
    /// libmis only calls `checkTrustAndAuthorization` when that flag is set, so
    /// `0xE8008026` — "missing trust and/or authorization", which a hacktivated
    /// guest with no activation record can never satisfy — is never produced.
    /// The spawn hooks insert it into `installd`, `misagent` and `SpringBoard`.
    ///
    /// Leaving the patch on costs more than it buys. On iOS 27 it stops the guest
    /// booting: TXM rejects the re-attested page, dyld cannot map
    /// `libSystem.B.dylib`, and `initproc failed to start` (issue #532). On 24A435
    /// it cannot even be applied — `checkTrustAndAuthorization` there carries
    /// neither the seeding prologue the patcher matches nor the patcher's own
    /// output, so `cfw install` fails outright before it writes anything.
    ///
    /// Why it stays declared rather than being deleted: on a 26.x guest whose
    /// environment predates SpringBoard getting the hook, an installed app is
    /// refused at launch, and this box is an alternative to updating the
    /// environment. On 27 it is not offered.
    public static let misTrustAuthPatch = "dyld-exp-mis_trust_auth"

    /// The former EXP patches that make the guest claim to be an iPhone17,3.
    ///
    /// `standard` is the JB baseline plus the camera. The camera needs the device
    /// tree's `/product/camera`, ISP and SMC nodes and `dyld-cfw-camera`, which stay on;
    /// it does not need the identity rewrites. They shipped on with the hypervisor
    /// concealment when EXP joined the JB flow, and guests from that build lost
    /// location (issue #438), so they go back to opt-in with it. `extended` or a
    /// per-VM checkmark turns them back on.
    public static let experimentalIdentityPatches: Set<String> = [
        "devicetree-exp-target_sub_type",
        "devicetree-exp-compatible_secondary",
        "devicetree-exp-product_fdr_product_type",
        "devicetree-exp-product_sub_product_type",
        "devicetree-exp-product_unique_model",
        "devicetree-exp-product_gestalt_variants_rename",
        "devicetree-exp-arm_io_device_type",
        "devicetree-exp-arm_io_soc_generation",
        FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity,
    ]

    /// The `hv_vmm_present` concealment, which is one patch in everything but name
    /// and has to be selected as a whole.
    ///
    /// Renaming the OID without mangling the shared cache breaks the graphics and
    /// ML paths; mangling the cache without the rename does nothing. watchdogd
    /// caches the sysctl at startup and, when the renamed OID returns ENOENT,
    /// reaches a `brk` that launchd turns into a panic, so its patch goes with the
    /// rename and is pointless without it. All three are off
    /// in `standard` because on a freshly restored 26.4 guest the rename makes
    /// `bluetoothd`'s cached `kern.hv_vmm_present` lookup fail, which sends it down
    /// the `MGIsDeviceOneOfType` path, leaves its transport singleton NULL and
    /// crash-loops it until launchd throttles it; `locationd` then blocks on the
    /// throttled Bluetooth XPC service, the data migrator hangs, and SpringBoard
    /// waits on migration forever — a black screen with no panic. See
    /// `Research/Patches/hv_vmm_present_usermode_xrefs.md`.
    public static let hypervisorConcealmentPatches: Set<String> = [
        "kernel-exp-hv_vmm",
        "dyld-exp-hv_vmm",
        "system-watchdogd-exp-hv_vmm_cache",
    ]

    /// The preset a VM gets when nothing else is named.
    ///
    /// The shipped `standard.plist` must match this; `FirmwarePatchSetTests`
    /// checks that it does. This copy is what a dev build with no staged
    /// `patches_presets` directory falls back to, so `fw patch` works straight out
    /// of an Xcode build.
    public static let standardPreset = VPhonePatchPreset(
        identifier: VPhonePatchPreset.standardIdentifier,
        title: "Standard",
        summary: "The patches every vphone VM needs to boot custom firmware, with a working display and camera.",
        patchSets: bundledReferences,
        selection: .block(manualOnlyPatches),
    )

    /// The general-purpose experimental patches, including the Frida relaxations, the
    /// hypervisor concealment and the iPhone17,3 identity. Each patch's own version
    /// gate still decides whether it lands.
    public static let experimentalPreset = VPhonePatchPreset(
        identifier: "experimental",
        title: "Experimental",
        summary: """
        The experimental patches, including the Frida Stalker relaxations, \
        the iPhone17,3 identity rewrites, and the hv_vmm_present concealment that a \
        freshly restored 26.4 guest does not survive. The HomePod-only top cap is off.
        """,
        patchSets: bundledReferences,
        selection: .block([FirmwareGuestSystemPatchSet.tvLegacySetup, FirmwareGuestSystemPatchSet.tvSetupDisplayLookup, FirmwareGuestSystemPatchSet.homePodTopCap, FirmwareGuestSystemPatchSet.homePodSetupBypass, FirmwareGuestSystemPatchSet.homePodAudioProduct, FirmwareGuestSystemPatchSet.homePodWelcome, FirmwareGuestSystemPatchSet.homePodSiriSpeech, FirmwareGuestSystemPatchSet.homePodOTAUserland, FirmwareGuestSystemPatchSet.homePodSoundGlow, FirmwareGuestSystemPatchSet.homePodCryptexStaging, FirmwareGuestSystemPatchSet.homePodCryptexClass, FirmwareGuestSystemPatchSet.homePodAdHocInstall]),
    )

    /// The iOS payloads, hooks and shared-cache patches an Apple TV guest has no
    /// validated port of: display, camera, audio, sensors, the GPU driver (a
    /// plain-arm64 HD cannot load it), debugserver, the environment hooks, and
    /// the iPhone 19 ARM64E_X1 boot path.
    public static let tvOSBlockedPatches: Set<String> = [
        paravirtTask3Patch,
        FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap,
        FirmwareGuestSystemPatchSet.arm64eX1CacheRemaining,
        FirmwareGuestSystemPatchSet.virtualBluetooth,
        "dyld-boot-iomfb_force_kern",
        "dyld-boot-iomfb_swapend",
        "dyld-boot-lockdown_mode",
        "dyld-boot-lsd_embedded_reg",
        "dyld-boot-maxslide",
        "dyld-boot-xpc_lwcr",
        "dyld-cfw-camera",
        "kernel-boot-arm64e_x1",
        "preboot-cfw-devicetree_board_audio",
        "preboot-cfw-devicetree_haptics",
        "preboot-cfw-devicetree_iphone_product",
        "preboot-cfw-devicetree_foldable_vm_subtype",
        "preboot-cfw-devicetree_microphone_array",
        RestoreRamDiskSealPatcher.patchIdentifier,
        "system-apps-cfw-attitude",
        "system-backboardd-cfw-gyroscope",
        "system-backboardd-cfw-accelerometer",
        "system-campo-cfw-entitlements",
        "system-debugserver-cfw-install",
        FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap,
        "system-diskimagesiod-cfw-is_mount_complete",
        "system-extensions-boot-gpu_bundle",
        FirmwareGuestSystemPatchSet.arm64eX1FsckBootstrap,
        "system-installcoordination_proxy-cfw-persona_lookup",
        "system-jetsamproperties-cfw-disable_allowed",
        FirmwareGuestSystemPatchSet.arm64eX1LaunchdBootstrap,
        "system-launchd-boot-jetsam_panic_guard_bypass",
        "system-launchdaemons-boot-environment",
        "system-locationd-cfw-disable_auto_cohort",
        "system-mobileactivationd-boot-should_hactivate",
        FirmwareGuestSystemPatchSet.arm64eX1MountBootstrap,
        "system-paravirt_gpu-cfw-heap_index_offset",
        "system-systemhook-cfw-metal_cache_reuse",
        "system-systemversion-cfw-build_version",
        "system-virtiosound-cfw-hal_plugin",
        "system-virtualaudio-cfw-device_state_null_gate",
        "system-virtualaudio-cfw-microphone_graph_chains",
        "system-virtualaudio-cfw-mute_set_throw",
        "system-virtualaudio-cfw-speaker_graph_chains",
        "system-virtualaudio-cfw-speaker_protection_gate",
        "system-virtualaudio-cfw-speaker_raw_chains",
        "system-virtualaudio-cfw-speaker_route_throws",
        "system-virtualaudio-cfw-volume_mode_precondition",
    ]

    /// The iOS 27 shared-cache patches a 27 userland needs on the 26.4 kernel,
    /// the display swap through the kernel among them. The Apple TV 4K keeps
    /// them on for its tvOS 27 OTA; each is gated on 27, so a 26 userland
    /// never meets them.
    public static let tvOS27UserlandPatches: Set<String> = [
        "dyld-boot-iomfb_force_kern",
        "dyld-boot-lockdown_mode",
        "dyld-boot-lsd_embedded_reg",
        "dyld-boot-maxslide",
        "dyld-boot-xpc_lwcr",
    ]

    /// Standard for an Apple TV guest: the TV TPRO compatibility on, and
    /// ``tvOSBlockedPatches`` off. The shipped `tvos.plist` must match this.
    public static let tvOSPreset = VPhonePatchPreset(
        identifier: VPhonePatchPreset.tvOSIdentifier,
        title: "Apple TV",
        summary: "Standard for an Apple TV HD guest: plain-arm64 TPRO compatibility and vphoned, without the iOS display, camera, audio, sensor and shared-cache patches tvOS has no validated port of.",
        patchSets: bundledReferences,
        selection: .block(
            manualOnlyPatches
                .subtracting([FirmwareGuestSystemPatchSet.tvTPRO, FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers])
                .union(tvOSBlockedPatches),
        ),
    )

    /// The Apple TV preset for an arm64e Apple TV 4K whose userland comes from
    /// its OTA: the paravirtual GPU driver, which the HD cannot load, and the
    /// userland swap and ``tvOS27UserlandPatches`` on; the TV TPRO patches,
    /// which only plain-arm64 dyld needs, off. The shipped `tvos-4k.plist`
    /// must match this.
    public static let tvOS4KPreset = VPhonePatchPreset(
        identifier: VPhonePatchPreset.tvOS4KIdentifier,
        title: "Apple TV 4K",
        summary: "Research: the Apple TV preset for an Apple TV 4K restored over the Apple TV HD, with its arm64e userland from the OTA and the paravirtual GPU driver, without the plain-arm64 TPRO patches.",
        patchSets: bundledReferences,
        selection: .block(
            manualOnlyPatches
                .subtracting([FirmwareGuestSystemPatchSet.tvOTAUserland, FirmwareGuestSystemPatchSet.tvLegacySetup])
                .union(tvOSBlockedPatches.subtracting(["system-extensions-boot-gpu_bundle"]).subtracting(tvOS27UserlandPatches)),
        ),
    )

    /// HomePod mini uses its own monolithic arm64e TVOS IPSW. Keep the 27
    /// kernel compatibility patches, but never swap in an Apple TV OTA or
    /// install the iPhone GPU/routing environment. The shared virtio audio
    /// driver selects native B520 routing through an audio-only preference,
    /// retaining the original VM product token for other services.
    public static let homePodMiniPreset = VPhonePatchPreset(
        identifier: VPhonePatchPreset.homePodMiniIdentifier,
        title: "HomePod mini",
        summary: "Research: HomePod mini's own arm64e TVOS IPSW with vphoned, its donor-driven top cap, local setup completion and virtio audio using an audio-only B520 route, without changing the VM product token or adding Apple TV OTA replacement or iPhone display, camera and routing hooks.",
        patchSets: bundledReferences,
        selection: .block(
            manualOnlyPatches.subtracting([FirmwareGuestSystemPatchSet.homePodTopCap, FirmwareGuestSystemPatchSet.homePodSetupBypass, FirmwareGuestSystemPatchSet.homePodWelcome, FirmwareGuestSystemPatchSet.homePodSiriSpeech, FirmwareGuestSystemPatchSet.homePodOTAUserland, FirmwareGuestSystemPatchSet.homePodSoundGlow, FirmwareGuestSystemPatchSet.homePodCryptexStaging, FirmwareGuestSystemPatchSet.homePodCryptexClass, FirmwareGuestSystemPatchSet.homePodAdHocInstall])
                .union(tvOSBlockedPatches.subtracting(tvOS27UserlandPatches).subtracting([FirmwareGuestSystemPatchSet.virtioSoundDriver, FirmwareGuestSystemPatchSet.installCoordinationPersona])),
        ),
    )

    /// The device tree patches ``minimalPreset`` keeps: the board presentation the
    /// guest UI lays out against, and the haptics and microphone array no VM
    /// has. They change no code, so they are no system modification.
    public static let minimalDeviceTreePatches: Set<String> = [
        "devicetree-cfw-serial_number",
        "devicetree-cfw-home_button_type",
        "devicetree-cfw-artwork_device_subtype",
        "devicetree-cfw-island_notch_location",
        "devicetree-cfw-product_haptics_node",
        "devicetree-cfw-product_audio_microphone_array",
        "devicetree-cfw-watch_companion",
    ]

    /// The boot chain patches ``minimalPreset`` keeps: iBEC's and LLB's, which the
    /// old `.less` variant applied too. A stock LLB does not get the restored
    /// guest to its kernel (it restarts after its banner, with Apple's ROMs as
    /// with OpenAVB and OpenSEP). AVPBooter, iBSS, TXM and the restore ramdisk
    /// stay stock.
    public static let minimalBootChainPatches: Set<String> = [
        "ibec-cfw-serial_label",
        "ibec-boot-image4_callback",
        "ibec-boot-boot_args",
        "ibec-boot-bootx_precondition",
        "llb-cfw-serial_label",
        "llb-boot-image4_callback",
        "llb-boot-boot_args",
        "llb-boot-rootfs",
        "llb-boot-panic_bypass",
        "llb-cfw-display_scale",
    ]

    /// A guest on a stock kernel and TXM, with only iBEC and LLB patched: the
    /// system is customised before the restore instead
    /// (``FirmwareRestoreImagePatchSet``), and nothing after it. Names only the
    /// sets it draws on, so no kernel or guest patcher is built.
    /// The shipped `minimal.plist` must match this.
    public static let minimalPreset = VPhonePatchPreset(
        identifier: VPhonePatchPreset.minimalIdentifier,
        title: "Minimal",
        summary: "No kernel or TXM patches and only iBEC and LLB in the boot chain: the restore installs a resealed system with vphoned, the GPU driver and activation, and nothing writes it afterwards.",
        patchSets: [
            .bundled(FirmwareBootChainPatchSet.identifier),
            .bundled(FirmwareResearchBoardPatchSet.identifier),
            .bundled(FirmwareDeviceTreePatchSet.identifier),
            .bundled(FirmwareRestoreImagePatchSet.identifier),
        ],
        selection: .allow(
            minimalBootChainPatches
                .union(minimalDeviceTreePatches)
                .union(FirmwareResearchBoardPatchSet.manifest.patches.map(\.identifier))
                .union(FirmwareRestoreImagePatchSet.manifest.patches.map(\.identifier)),
        ),
    )

    /// The device tree patches ``watchOSPreset`` keeps: the board presentation
    /// of its own tree, the watch display and DriverKit, and what no VM has.
    public static let watchOSDeviceTreePatches: Set<String> = [
        "devicetree-cfw-serial_number",
        "devicetree-cfw-ipad_artwork",
        "devicetree-cfw-ipad_product",
        "devicetree-cfw-ipad_buttons",
        "devicetree-cfw-ipad_identity",
        "devicetree-cfw-ipad_audio",
        "devicetree-cfw-watch_presentation",
        "devicetree-cfw-watch_driverkit",
        "devicetree-cfw-product_haptics_node",
        "devicetree-cfw-product_audio_microphone_array",
    ]

    /// ``minimalPreset`` for an Apple Watch: its device tree presents the watch
    /// board. The shipped `watchos.plist` must match this.
    public static let watchOSPreset = VPhonePatchPreset(
        identifier: VPhonePatchPreset.watchOSIdentifier,
        title: "Apple Watch",
        summary: "Minimal for an Apple Watch guest: the watch board's device tree, and a resealed system with vphoned, the GPU driver and activation restored onto a stock kernel and TXM.",
        patchSets: minimalPreset.patchSets,
        selection: .allow(
            minimalBootChainPatches
                .union(watchOSDeviceTreePatches)
                .union(FirmwareResearchBoardPatchSet.manifest.patches.map(\.identifier))
                .union(FirmwareRestoreImagePatchSet.manifest.patches.map(\.identifier)),
        ),
    )

    /// The presets the bundle ships.
    public static let builtInPresets: [VPhonePatchPreset] = [standardPreset, experimentalPreset, tvOSPreset, tvOS4KPreset, homePodMiniPreset, minimalPreset, watchOSPreset]
}
