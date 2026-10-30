// FirmwareGuestSystemPatchSet.swift — Manifest for the mounted guest volume.
//
// What `cfw install` does after the restore: the shared-cache policy gates a 27
// userland needs, the handful of system daemons that must be patched to start on
// a research board, and the vphone payload itself.
//
// Unlike the boot chain, several of these are Mach-O or shared-cache edits that
// emit no patch record — a string mangled in place, a file installed. Their
// identifiers name the operation instead of mirroring a record, and they are
// still the names a preset selects and the UI lists.

import Foundation
import VPhonePatchKit

public enum FirmwareGuestSystemPatchSet {
    public static let identifier = "com.vphone.patchset.guest.system"

    public static let settingsRootRows = "system-preferences-exp-root_rows"
    public static let settingsSoftwareUpdate = "dyld-exp-settings_software_update_row"
    public static let settingsRowPatches: Set<String> = [settingsRootRows, settingsSoftwareUpdate]

    public static let installCoordinationPersona = "system-installcoordination_proxy-cfw-persona_lookup"
    public static let installCoordinationPersonaMarker = "/usr/lib/vphone-installcoordination-persona-lookup"
    public static let homePodInstallPersonaLibrary = "/usr/lib/libvphoneinstallpersona.dylib"
    public static let homePodAdHocInstall = "system-installd-exp-homepod_adhoc"
    public static let homePodMISFixLibrary = "/usr/lib/libvphonehomepodmisfix.dylib"
    public static let metalCacheReuse = "system-systemhook-cfw-metal_cache_reuse"
    public static let metalCacheReuseMarker = "/usr/lib/vphone-metal-cache-reuse"
    public static let gyroscope = "system-backboardd-cfw-gyroscope"
    public static let accelerometer = "system-backboardd-cfw-accelerometer"
    public static let hinge = "system-backboardd-cfw-hinge"
    public static let foldGuard = "system-springboard-cfw-fold_guard"
    public static let foldDisplay = "system-springboard-cfw-fold_display"
    public static let attitude = "system-apps-cfw-attitude"
    public static let followUpGroups = "system-preferences-cfw-followup_groups"
    public static let signInSheets = "system-apps-cfw-signin_sheets"
    public static let arm64eX1DyldBootstrap = "system-dyld-boot-arm64e_x1_bootstrap"
    public static let arm64eX1CacheBootstrap = "dyld-boot-arm64e_x1_bootstrap"
    public static let arm64eX1CacheRemaining = "dyld-cfw-arm64e_x1_cache"
    public static let arm64eX1LaunchdBootstrap = "system-launchd-boot-arm64e_x1_bootstrap"
    public static let arm64eX1FsckBootstrap = "system-fsck-boot-arm64e_x1_bootstrap"
    public static let arm64eX1MountBootstrap = "system-mount-boot-arm64e_x1_bootstrap"
    public static let arm64eX1CIBarcode = "system-cibarcode-cfw-arm64e_x1"
    public static let ciBarcodeBundlePath = "System/Library/CoreImage/CIBarcode.cifilter"
    public static let ciBarcodeExecutablePath = ciBarcodeBundlePath + "/CIBarcode"

    public static let paravirtGPUIndexOffset = "system-paravirt_gpu-cfw-heap_index_offset"
    public static let paravirtGPUDriverPath =
        "System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/AppleParavirtGPUMetalIOGPUFamily"

    public static let locationdCohorting = "system-locationd-cfw-disable_auto_cohort"
    public static let virtualBluetooth = "system-bluetoothd-cfw-btvc_le_connection"
    public static let jetsamDisableAllowed = "system-jetsamproperties-cfw-disable_allowed"
    public static let homeViewProfileLookup = "system-userprofilesd-exp-keybag_lookup"
    public static let homeViewDisplayLookups = "system-breadboard-exp-mach_lookup"
    public static let homeViewSetupBypass = "system-homeview-exp-setup_bypass"
    public static let homeViewEnvironmentService = "dyld-exp-homeview_environment_service"
    public static let homeViewSetupPath = "/usr/share/vphone/HomeViewSetup.plist"
    public static let tvTPRO = "system-dyld-exp-tv_tpro"
    public static let tvSetupDisplayLookup = "system-setupbackground-exp-pineboard_lookup"
    public static let tvLegacySetup = "system-tv-exp-legacy_setup"
    public static let tvSetupFocus = "system-setup-exp-deferred_focus"
    public static let tvSetupFocusLibrary = "/usr/lib/libvphonetvsetupfocus.dylib"
    public static let tvLocalActivation = "system-mobileactivationd-exp-tv_activation"
    /// Replaces the restored System volume with an Apple TV 4K userland
    /// staged from its OTA. Research only: no IPSW exists for that device.
    public static let tvOTAUserland = "system-tv-exp-ota_userland"
    public static let homePodOTAUserland = "system-homepod-exp-ota_userland"
    public static let homePodCryptexClass = "preboot-homepod-exp-cryptex_class"
    public static let homePodCryptexStaging = "system-cryptexd-exp-homepod_staging"
    public static let homePodCryptexStagingLibrary = "/usr/lib/libvphonecryptexstaging.dylib"
    public static let homePodSoundGlow = "system-homepod-exp-sound_glow"
    public static let homePodSoundGlowPath = "/usr/share/vphone/HomePodSoundGlow.plist"
    public static let otaUserland = "system-exp-ota_userland"

    private static let ios27 = VPhonePatchApplicability(iOSBase: .major(27))

    /// The bases where short-circuiting `checkTrustAndAuthorization` in the
    /// shared cache is survivable.
    ///
    /// Not a preference — a preference belongs in a preset's block list, and
    /// `standard` blocks this one too. This is the harder statement: on iOS 27 the
    /// patch stops the guest booting. TXM rejects the re-attested page, dyld
    /// cannot map `libSystem.B.dylib`, and `initproc failed to start`
    /// (issue #532). Without the gate, `experimental` — which is `Kind = All` —
    /// would hand a 27 user an unbootable VM.
    ///
    /// An unreadable base satisfies only `.any`, so an unknown release skips the
    /// patch. That is the safe direction here.
    private static let misTrustAuthBases = VPhonePatchApplicability(
        iOSBase: .oneOf([.major(18), .major(26)]),
    )

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Guest System",
        summary: "Shared-cache policy gates, patched system daemons and the vphone guest payload",
        patches: [
            VPhonePatchDeclaration(
                identifier: homeViewEnvironmentService,
                title: "HomeView distance simulation service",
                summary: "Enables BreadBoard's native environment simulation service on retail HomeView 27.2 by opening only its internal-install gate. Preserves the service's client entitlement check and global build identity. Experimental, off by default; native near/far runtime validation is pending.",
                target: .dyldSharedCache,
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: homePodCryptexClass,
                title: "HomePod Cryptex product class",
                summary: "Sets the research kernel's Cryptex product class to the native tvOS/HomePod value so signed tvOS developer images pass Image4 equality validation. Changes only /product/cryptex1-product-class; preserves the global product token.",
                target: .prebootDeviceTree,
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: homeViewProfileLookup,
                title: "HomeView guest profile keybag access",
                summary: "Adds only the native Keybag/UserManager Mach service lookup to userprofilesd's temporary sandbox so its guest-profile request can reach the service on the older research kernel. Preserves authorization checks and original entitlements; reversible from backup.",
                target: .guestExecutable(path: "/System/Library/PrivateFrameworks/UserProfilesDaemon.framework/Support/userprofilesd"),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: homeViewDisplayLookups,
                title: "HomeView shell display access",
                summary: "Adds backboard/frontboard Mach service lookup exceptions to BreadBoard's temporary sandbox for the older research kernel, preserving its existing entitlements. Keeps an executable backup for deselection.",
                target: .guestExecutable(path: "/System/Library/CoreServices/BreadBoard.app/BreadBoard"),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: homeViewSetupBypass,
                title: "HomeView setup bypass",
                summary: "Sets the native SetupAssistant ForceNoBuddy preference as mobile, with a key-level journal restored when disabled. Account, activation and HomeKit state remain native. Off by default; takes effect at boot.",
                target: .guestFile(path: homeViewSetupPath),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: homePodAdHocInstall,
                title: "HomePod local app signatures",
                summary: "Ports the existing MIS signature-option adapter to HomePod installd so locally signed research apps install without the provisioning service HomePod does not ship. Keeps MIS's native signature validation and returned metadata; no device identity or profile scope hooks.",
                target: .guestExecutable(path: "/usr/libexec/installd"),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: homePodCryptexStaging,
                title: "HomePod developer image staging",
                summary: "Lets HomePod 27 cryptexd stage and activate developer images on the research guest: accepts unsupported protection classes, uses until-reboot DDI lifetime, and tolerates the research SEP's unavailable digest storage only for the verified DDI. Retains Apple personalization, signature, root-hash and trust-cache checks.",
                target: .guestExecutable(path: "/usr/libexec/cryptexd"),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: homePodOTAUserland,
                title: "HomePod userland from OTA",
                summary: "Research: replaces the restored HomePod mini System volume with its full 27.2 or later OTA, retaining the HomePod restore identity and cloudOS boot chain. The staged payload is verified before installation.",
                target: .guestFile(path: "/"),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: homePodSoundGlow,
                title: "HomePod Sound Glow",
                summary: "Enables the native HomePod 27.2 media display through a process-local accessory setting adapter. Requires vphoned and the donor-driven HomePod top cap; keeps the original product token.",
                target: .guestFile(path: "/usr/share/vphone/HomePodSoundGlow.plist"),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: otaUserland,
                title: "Full OTA system update",
                summary: "Experimental: replaces the System volume from a staged full OTA, retaining Data, xART, NVRAM and SEPStorage. Requires a stopped disk/SEP/NVRAM snapshot and a prepared target; installs the target kernelcache and TXM in the same transaction. Use fw ota to verify migration and roll back.",
                target: .guestFile(path: "/"),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: tvTPRO,
                title: "TV TPRO feature detection",
                summary: "Plain-arm64 TVOS compatibility: stops standalone and cached dyld enabling cloudOS-advertised hardware TPRO and pager modes, preserving page-in linking and all fixups.",
                target: .guestExecutable(path: "/usr/lib/dyld"),
                applicability: VPhonePatchApplicability(iOSBase: .major(26)),
            ),
            VPhonePatchDeclaration(
                identifier: tvLegacySetup,
                title: "Legacy TV setup (research)",
                summary: "Research fallback: selects the legacy TVSetup app in tvOS 27.2 by disabling TVSetupV2 and TVSetupV2HW. Off in every preset; disabling restores the original flags and the new Setup flow.",
                target: .guestFile(path: "/" + CustomFirmwareTVSetup.relativePath),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: tvLocalActivation,
                title: "TV local activation",
                summary: "Uses mobileactivationd’s existing local activation path for the tvOS 27.2 research guest, allowing the native Setup assistant to proceed without an Apple activation record.",
                target: .guestExecutable(path: "/usr/libexec/mobileactivationd"),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: tvSetupFocus,
                title: "TV setup button focus",
                summary: "Uses native TV button-focus policy in the new tvOS 27.2 Setup window, so Consumer Select works without indirect-touch activity, including after idle. Preserves explicit focus overrides, eligibility and all Setup readiness checks.",
                target: .guestExecutable(path: "/Applications/Setup.app/Setup"),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: tvSetupDisplayLookup,
                title: "TV setup display connection",
                summary: "Lets tvOS 27.2 SetupBackground look up PineBoardServices on the cloudOS kernel. Without this one sandbox exception, its display-state request times out and setup stays black.",
                target: .guestEntitlements(path: "/Applications/SetupBackground.app/SetupBackground"),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 2)),
            ),
            VPhonePatchDeclaration(
                identifier: tvOTAUserland,
                title: "Apple TV 4K userland from OTA",
                summary: "Research: replaces the System volume with the arm64e tvOS userland staged in the VM's OTAUserland folder, extracted with aa so ownership, modes, flags and compression survive.",
                target: .guestFile(path: "/"),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 26, minor: 0)),
            ),
            VPhonePatchDeclaration(
                identifier: virtualBluetooth,
                title: "Virtual Bluetooth",
                summary: "Turns on the feature flag that lets bluetoothd establish LE connections between guests over its Bonjour virtual controller.",
                target: .guestFile(path: "/" + CustomFirmwareBluetoothVirtualController.relativePath),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 26, minor: 0)),
            ),
            VPhonePatchDeclaration(
                identifier: locationdCohorting,
                title: "locationd startup stability",
                summary: "Uses independent location silos to avoid iOS 27 startup crashes and queue hangs on the research guest.",
                target: .guestFile(path: "/" + CustomFirmwareLocationdCohorting.relativePath),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: jetsamDisableAllowed,
                title: "Disabled services stay off",
                summary: """
                Removes the iOS 27 jetsam property that makes launchd load some daemons whatever \
                its disabled list says. Without it the trimmed service profile and the OTA block \
                do not hold on a guest that presents its board.
                """,
                target: .guestFile(path: "/" + CustomFirmwareJetsamDisableAllowed.directory),
                applicability: ios27,
            ),

            // MARK: Shared Cache Policy

            VPhonePatchDeclaration(
                identifier: "dyld-boot-maxslide",
                title: "Shared cache max slide",
                summary: """
                Zeroes the shared cache's maximum slide. A 27 userland otherwise computes a slide \
                the patched cache cannot satisfy.
                """,
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-boot-lsd_embedded_reg",
                title: "lsd registration entitlement",
                summary: "Lets lsd register the guest's embedded app bundles.",
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-boot-xpc_lwcr",
                title: "XPC lightweight code requirements",
                summary: "Stops XPC refusing a peer whose lightweight code requirement no longer matches.",
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-boot-lockdown_mode",
                title: "Lockdown mode sysctl gate",
                summary: "Stops a failed lockdown-mode sysctl read being treated as an error.",
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-exp-mis_trust_auth",
                title: "MIS online authorization",
                summary: """
                Accepts a provisioning profile that wants online authorization, by short-circuiting \
                the check in the shared cache. Off by default: libmisfix.dylib already declines the \
                same check from userspace in installd, misagent and SpringBoard, and editing the \
                cache for it stops an iOS 27 guest booting. Not offered on iOS 27.
                """,
                target: .dyldSharedCache,
                applicability: misTrustAuthBases,
            ),

            VPhonePatchDeclaration(
                identifier: settingsRootRows,
                title: "Hide selected Settings root rows",
                summary: "Hides Apple Account, Game Center, iCloud and Wallet on reviewed 24A435 Preferences. Does not hide Indexing or Software Update. Other binary revisions are refused.",
                target: .guestExecutable(path: "/Applications/Preferences.app/Preferences"),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 0)),
            ),

            VPhonePatchDeclaration(
                identifier: settingsSoftwareUpdate,
                title: "Hide Software Update in Settings",
                summary: "Hides the General Software Update row in reviewed 24A435 GeneralSettingsUI. Uses cache-page re-attestation and the normal undo log; other image UUIDs are refused.",
                target: .dyldSharedCache,
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 0)),
            ),

            // MARK: System Daemons

            VPhonePatchDeclaration(
                identifier: arm64eX1DyldBootstrap,
                title: "ARM64E_X1 dyld bootstrap",
                summary: "Lowers X1 instructions in dyld so launchd can install the host exception handler that translates later faults on demand.",
                target: .guestExecutable(path: "/usr/lib/dyld"),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: arm64eX1CacheBootstrap,
                title: "ARM64E_X1 cache bootstrap",
                summary: "Lowers only libSystem's pre-constructor X1 code so launchd can install the global on-demand instruction handler.",
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: arm64eX1CacheRemaining,
                title: "ARM64E_X1 cache lowering",
                summary: "Lowers X1 instructions in every other shared-cache image ahead of time, so apps and extensions do not queue on launchd's on-demand handler until FrontBoard's watchdog kills them.",
                target: .dyldSharedCache,
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: arm64eX1LaunchdBootstrap,
                title: "ARM64E_X1 launchd bootstrap",
                summary: "Lowers PID 1 itself so its injected on-demand instruction handler can become active for the rest of userland.",
                target: .guestExecutable(path: "/sbin/launchd"),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: arm64eX1FsckBootstrap,
                title: "ARM64E_X1 fsck bootstrap",
                summary: "Lowers the boot fsck wrapper so its forked checker does not inherit runtime-modified signed pages.",
                target: .guestExecutable(path: "/sbin/fsck"),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: arm64eX1MountBootstrap,
                title: "ARM64E_X1 mount bootstrap",
                summary: "Lowers the boot mount wrapper so its forked mount helpers do not inherit runtime-modified signed pages.",
                target: .guestExecutable(path: "/sbin/mount"),
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: arm64eX1CIBarcode,
                title: "ARM64E_X1 barcode filters",
                summary: """
                Lowers the standalone CIBarcode plug-in before apps load its barcode filters. \
                This image is outside the shared cache, so whole-cache lowering cannot prevent \
                its remaining X1 instruction faults.
                """,
                target: .guestExecutable(path: "/" + ciBarcodeExecutablePath),
                applicability: VPhonePatchApplicability(iOSBase: .release(major: 27, minor: 1)),
            ),

            VPhonePatchDeclaration(
                identifier: "system-seputil-boot-gigalocker_uuid",
                title: "seputil Gigalocker UUID",
                summary: "Points seputil at the renamed Gigalocker so key material resolves.",
                target: .guestExecutable(path: "/usr/libexec/seputil"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-diskimagesiod-cfw-is_mount_complete",
                title: "diskimagesiod mount completion",
                summary: "Reports the personalised developer image as mounted on a 27 userland.",
                target: .guestExecutable(path: "/usr/libexec/diskimagesiod"),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: "system-launchd_cache_loader-boot-unsecure_cache_gate",
                title: "launchd cache loader gate",
                summary: "Lets the launchd cache loader accept the patched, unsealed cache.",
                target: .guestExecutable(path: "/usr/libexec/launchd_cache_loader"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-mobileactivationd-boot-should_hactivate",
                title: "mobileactivationd activation",
                summary: "Reports the device activated, so the guest reaches the home screen.",
                target: .guestExecutable(path: "/usr/libexec/mobileactivationd"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-launchd-boot-jetsam_panic_guard_bypass",
                title: "launchd jetsam panic guard",
                summary: "Stops launchd panicking when jetsam reaps a process the VM needs.",
                target: .guestExecutable(path: "/sbin/launchd"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-debugserver-cfw-install",
                title: "debugserver",
                summary: "Installs a debugserver that can attach in the guest.",
                target: .guestFile(path: "/usr/bin/debugserver"),
            ),
            VPhonePatchDeclaration(
                identifier: "system-campo-cfw-entitlements",
                title: "Campo entitlements",
                summary: "Widens Campo's entitlements so the 27 setup assistant completes.",
                target: .guestEntitlements(path: "/System/Library/PrivateFrameworks/Campo.framework/Campo"),
                applicability: ios27,
            ),

            VPhonePatchDeclaration(
                identifier: installCoordinationPersona,
                title: "Xcode installation persona lookup",
                summary: "Allows only the CoreDevice installation proxy to look up UserManager through launchd on the hybrid guest. HomePod uses a dedicated tvOS adapter with the same audit-token checks, independently of the iPhone environment.",
                target: .guestFile(path: installCoordinationPersonaMarker),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: metalCacheReuse,
                title: "Keep Metal shader caches",
                summary: """
                Has SystemHook request FS_CACHE_REUSE_ON_REBOOT=1 at process startup, \
                allowing Metal's guest shader caches to survive a reboot and reducing \
                repeated shader compilation. An explicit environment setting takes precedence.
                """,
                target: .guestFile(path: metalCacheReuseMarker),
            ),

            // MARK: Guest Payload

            VPhonePatchDeclaration(
                identifier: "system-gigalocker-boot-rename",
                title: "Gigalocker rename",
                summary: "Renames the data volume's Gigalocker so the guest recreates it.",
                target: .guestFile(path: "/private/var/Gigalocker"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-extensions-boot-gpu_bundle",
                title: "GPU driver bundle",
                summary: "Installs the GPU bundle the virtual display needs.",
                target: .guestFile(path: "/System/Library/Extensions"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: paravirtGPUIndexOffset,
                title: "GPU heap index buffers",
                summary: """
                Makes the paravirtual GPU driver send every indexed draw with 64-bit offsets. Its \
                compact command keeps an index buffer's heap offset in 16 bits, so meshes whose \
                indices sit 64 KiB or more into an MTLHeap (Unity games) draw with another \
                mesh's indices.
                """,
                target: .guestExecutable(path: "/\(paravirtGPUDriverPath)"),
                applicability: VPhonePatchApplicability(cloudOS: .release(major: 26, minor: 4)),
            ),
            VPhonePatchDeclaration(
                identifier: "system-vphoned-boot-install",
                title: "vphoned",
                summary: "Installs the guest daemon the host talks to over VSOCK.",
                target: .guestFile(path: "/usr/local/bin/vphoned"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: homePodTopCap,
                title: "HomePod top cap",
                summary: "Stages the donor MiniDisplay geometry for vphoned's virtual HomePod LED display and volume buttons, with a SoundBoard-only shim for its reserved HID class identity.",
                target: .guestFile(path: homePodDisplayPath),
            ),
            VPhonePatchDeclaration(
                identifier: homePodSetupBypass,
                title: "HomePod setup completion",
                summary: "Completes the donor's local AudioAccessory setup state as mobile, prepares SetupAssistant's native launch sentinel and lets SoundBoard initialize its post-setup services. Turning it off restores the prior completion flags at the next boot. Does not provision accounts, activation or a HomeKit home.",
                target: .guestFile(path: homePodSetupPath),
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),
            VPhonePatchDeclaration(
                identifier: homePodSiriSpeech,
                title: "HomePod native Siri speech",
                summary: "Enables the HomePod guest's output-only auxiliary audio session on native Siri speech events, using the existing SoundBoard adapter. Requires vphoned, the HomePod top cap and virtio sound. Turning it off removes only this policy. The native branch is verified; repair playback remains pending runtime validation.",
                target: .guestFile(path: homePodSiriSpeechPath),
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),
            VPhonePatchDeclaration(
                identifier: homePodWelcome,
                title: "HomePod first-boot welcome",
                summary: "Enables a guest-owned, one-time welcome after HomePod setup, display and audio services become ready. Requires vphoned, the HomePod top cap, local setup completion, virtio sound and native Siri speech. Turning it off removes the policy and preserves the guest's once-only state. Native welcome playback remains pending runtime validation.",
                target: .guestFile(path: homePodWelcomePath),
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),
            VPhonePatchDeclaration(
                identifier: "system-launchdaemons-boot-environment",
                title: "Guest environment",
                summary: """
                Installs the launchd environment and plists the guest tools read, and the hooks \
                launchd and SystemHook insert at spawn. Among them is libmisfix.dylib, inserted \
                into installd, misagent and SpringBoard, which lets Xcode install and launch an \
                app signed for someone else's team, or ad hoc, without writing the shared cache, \
                and into lockdownd and remoted, which tell the host a configured UDID. It also \
                ships libhapticsfix.dylib, which SystemHook loads into SpringBoard so UIKit's \
                feedback engine takes the no-haptics path instead of crashing on the VM's absent \
                haptic hardware, libbatteryhealthfix.dylib, inserted into Settings, which gives \
                the virtual battery the health record Battery Health waits for, and \
                libdevicehubfix.dylib, inserted into cryptexd, which then stages the iOS 27 \
                developer disk image, into the image's dtremotedisplayd and dtdeviceinfod, \
                which then report the media stream features and the screen mask Xcode's \
                DeviceHub needs to show the screen, and into avconferenced, where a stream \
                split into bands would otherwise deadlock the host GPU. \
                libdevicename.dylib, inserted into configd and lockdownd, does nothing until \
                vphoned stores a device name (the host sends the VM's name); then configd \
                publishes that name and lockdownd refuses to rename the device.
                """,
                target: .guestFile(path: "/Library/LaunchDaemons"),
                bootEssential: true,
            ),

            // MARK: Account prompts

            VPhonePatchDeclaration(
                identifier: followUpGroups,
                title: "Hide Settings follow-up groups",
                summary: "Installs libprefsfix.dylib, loaded by SystemHook into Settings. Hides the CoreFollowUp groups: Apple Account suggestions, services included with purchase, AppleCare, More for Your iPhone and Screen Time updates. Removing the library shows them again on the next Settings launch.",
                target: .guestFile(path: "/usr/lib/libprefsfix.dylib"),
            ),

            VPhonePatchDeclaration(
                identifier: signInSheets,
                title: "Suppress sign-in sheets",
                summary: "Installs libsigninfix.dylib, loaded by SystemHook into every app. Drops Apple Account, iCloud, Game Center and Media & Purchases sign-in sheets; account daemons are untouched. Removing the library restores the sheets on the next app launch.",
                target: .guestFile(path: "/usr/lib/libsigninfix.dylib"),
            ),

            // MARK: Motion

            VPhonePatchDeclaration(
                identifier: accelerometer,
                title: "Virtual gravity accelerometer",
                summary: "Installs libvphoneaccelerometer.dylib. Publishes a built-in HID gravity sensor and bridges its classified pose into backboardd's native device-orientation sink. In SpringBoard, recomputes orientation delivery and deferral after the real backlight seed. Follows display.rotation across relaunches; removing the library disables both after a reboot.",
                target: .guestFile(path: "/usr/lib/libvphoneaccelerometer.dylib"),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 18, minor: 0)),
            ),

            VPhonePatchDeclaration(
                identifier: gyroscope,
                title: "Virtual 3D gyroscope",
                summary: "Installs libvphonegyro.dylib, loaded by SystemHook into backboardd. Publishes a virtual HID gyro service using the three-axis rotation rate configured through vphoned. Removing the library disables the provider after a reboot.",
                target: .guestFile(path: "/usr/lib/libvphonegyro.dylib"),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 18, minor: 0)),
            ),

            VPhonePatchDeclaration(
                identifier: hinge,
                title: "Virtual hinge angle sensor",
                summary: """
                Installs libvphonehinge.dylib, loaded by SystemHook into backboardd. Publishes the \
                foldable's virtual hinge HID service (usage page 0xFF0C, usage 0x21) and reports \
                the hinge angle chosen by display.posture, so CoreMotion's angle manager — and \
                through it CoreDevice's hingeAngle stream — reads the fold state instead of \
                finding no sensor. With the foldable product identity patch, which is what makes \
                CoreMotion look for the service. Foldable guests only.
                """,
                target: .guestFile(path: "/usr/lib/libvphonehinge.dylib"),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 18, minor: 0)),
            ),

            VPhonePatchDeclaration(
                identifier: foldGuard,
                title: "Foldable secure-indicator guard",
                summary: """
                Installs libvphonefoldguard.dylib, loaded by SystemHook into SpringBoard. With \
                the foldable product identity, SpringBoard's first CA transaction reaches \
                CASecureIndicatorLayer, which raises about indicator geometry a single-display \
                guest cannot supply — the raise crash-loops SpringBoard into device-recovery \
                (SIGABRT, measured twice on 27.1 24A94425). The guard catches that one exception \
                and answers no layer copy, so the system app boots with the Duo identity and its \
                fold layouts; the secure indicator is the casualty. Inert on any guest without \
                the identity. Foldable guests only.
                """,
                target: .guestFile(path: "/usr/lib/libvphonefoldguard.dylib"),
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),

            VPhonePatchDeclaration(
                identifier: foldDisplay,
                title: "Foldable inner display",
                summary: """
                Installs libvphonefolddisplay.dylib, loaded by SystemHook into backboardd and \
                SpringBoard. A real iPhone Duo drives two panels: the cover is Main and the \
                inner panel a second built-in, always-connected landscape display. backboardd \
                publishes the inner panel as a software render display with the device tree's \
                surface types and routes the one digitizer to whichever panel is lit; SpringBoard \
                classifies it as built-in, resolves the fold postures for both displays natively \
                and composites the inner display onto the guest's single panel while open. \
                Experimental. Acts only on iPhone19,4.
                """,
                target: .guestFile(path: "/usr/lib/libvphonefolddisplay.dylib"),
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),

            VPhonePatchDeclaration(
                identifier: attitude,
                title: "Device attitude simulation",
                summary: "Installs libvphoneattitude.dylib, loaded by SystemHook into apps outside system UI services such as SpringBoard. Supplies a stationary Core Motion pose configured through vphoned, with polling and callback updates in the arbitrary vertical reference frame. Disabling simulation restores native motion; removing the library reverts the hook on app relaunch.",
                target: .guestFile(path: "/usr/lib/libvphoneattitude.dylib"),
                applicability: VPhonePatchApplicability(iOSBase: .atLeast(major: 18, minor: 0)),
            ),

            // MARK: Audio

            VPhonePatchDeclaration(
                identifier: virtioSoundDriver,
                title: "Virtual sound driver",
                summary: """
                Installs the CoreAudio HAL plugin that plays the guest's audio through the VM's \
                virtio sound device. iOS ships the kernel driver but not this half, so without \
                it nothing reaches the Mac's speakers.
                """,
                target: .guestFile(path: "/System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioSpeakerRouteThrows,
                title: "VirtualAudio speaker-route throws",
                summary: """
                Turns VirtualAudio's \"No default VAD present\" exception into a quiet return. \
                Applying a speaker route with no default VAD throws through an AudioServerPlugIn \
                callback, which cannot propagate it: audiomxd aborts, and the saved route state \
                replays the same throw into every launch. The speaker route the virtio plugin \
                publishes is what makes the walk reach that throw, so the two patches go together.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioMuteSetThrow,
                title: "VirtualAudio mute-set throw",
                summary: """
                Turns the CAException VirtualAudio throws when the HAL server refuses its \
                device-level mute set into a quiet return. iOS's HAL never forwards that \
                selector to a plugin device, and RoutingManager catches the throw by \
                abandoning the route — the aggregate is left on Null_Device and the guest \
                is silent. With the throw quieted, the route survives on the virtio device.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioSpeakerProtectionGate,
                title: "VirtualAudio speaker-protection gate",
                summary: """
                Stops the ringtone route handler from declining its own finished route for lack \
                of HAL Speaker Protection — a capability only a physical codec reports, whose \
                query never leaves VirtualAudio. The decline leaves the vdef playing into \
                Null_Device, silent with the volume dead; with the gate opened, the route keeps \
                the virtio device it already built. The handler for routes that play and record \
                has the same gate, and declines every recording app's route; it is opened too.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioVolumeModePrecondition,
                title: "VirtualAudio volume-mode precondition",
                summary: """
                One step after the speaker-protection gate, the same handler declines the \
                finished route because its software-volume mode is not the kHardwareOnlyReadOnly \
                the routing database demands — a mismatch every virtio-plugin device carries, \
                since the mode a VM's device reports is SoftwareHardwareMix. The decline throws \
                past the route's own teardown, leaving the session on Null_Device: silent, \
                volume dead. With the precondition opened, the route keeps the virtio aggregate \
                it already built.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioDeviceStateNullGate,
                title: "VirtualAudio device-state null gate",
                summary: """
                Makes VirtualAudio_Device's two device-state updates wait for the
                DeviceStateManager singleton instead of dereferencing it when it does
                not exist. On a guest with no haptic hardware deferred initialization
                never constructs the manager, and a route push that arrives while the
                gates answer true reads the null singleton and crash-loops audiomxd.
                Each update's gate-check call is redirected to TheInstance, so the
                branch that already skips the update on a failed check now tests the
                singleton itself: no manager, the update is skipped through the
                function's own path; manager present, the update runs exactly as
                designed. Applies only to the arm64e.x1 plugin (iOS 27.1's
                iPhone19,4); earlier builds are left byte-identical.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioGraphConfigurations,
                title: "VirtualAudio speaker graph chains",
                summary: """
                Moves every speaker_* entry in the tuning set's graph_configurations.plist from the \
                `clhs` HAL SpeakerProtection chain to the `dflt` generic graph chain the mic \
                configurations use. The HAL chain's construction looks a physical "Speaker" device \
                up in the device registry and throws when a VM has none, which is what still kills \
                every speaker route once the route walk itself survives.
                """,
                target: .guestFile(path: "/Library/Audio/Tunings"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioSpeakerRawChains,
                title: "VirtualAudio raw speaker chain",
                summary: """
                Gives every speaker_* entry in the tuning set's graph_configurations.plist the chain \
                of speaker_raw: the volume and a limiter. The general chain's loudness normalizer, \
                virtual bass, equalizers and compressor are tuned to the board's own speaker; \
                through the Mac's they turn the quiet low end of what plays into noise.
                """,
                target: .guestFile(path: "/Library/Audio/Tunings"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioMicrophoneChains,
                title: "VirtualAudio microphone chains",
                summary: """
                Gives every <mic>_general entry in the tuning set's graph_configurations.plist the \
                tunings of its <mic>_measurement sibling. The general chain's loudness normalizer, \
                compressor and limiter are tuned to the board's own microphone; on the Mac's they \
                raise the noise floor about 10 dB and a recording sounds like wind.
                """,
                target: .guestFile(path: "/Library/Audio/Tunings"),
            ),
            VPhonePatchDeclaration(
                identifier: prebootBoardAudio,
                title: "iPad audio configuration",
                summary: """
                Gives an iPad guest's restored Preboot device tree the iPad's own audio node, as \
                fw patch now does. Earlier trees kept the iPhone's, whose acoustic ID names tunings \
                an iPad image does not ship, so iOS's audio routing failed to start. Takes the \
                iPad's device tree from the VM's FirmwareOriginals, and recovers it there from the \
                VM's IPSW in ~/.vphone/ipsws when it is missing.
                """,
                target: .prebootDeviceTree,
            ),
            VPhonePatchDeclaration(
                identifier: homePodAudioProduct,
                title: "HomePod donor product identity (experimental)",
                summary: "Copies the donor's product-id into Preboot, changing MobileGestalt identity system-wide. Off in every preset: audio uses VirtualAudio's local product override instead. Retained for explicit research and to restore the shared Preboot backup when disabled after an earlier install.",
                target: .prebootDeviceTree,
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),
            VPhonePatchDeclaration(
                identifier: prebootIPhoneProduct,
                title: "iPhone product description",
                summary: """
                Gives an iPhone guest's restored Preboot device tree the product description of the \
                iPhone's own tree: model name, Siri and dictation, button and display geometry, \
                Camera Control and the Action Button. vphone600 leaves them as syscfg placeholders, \
                which MobileGestalt reads as absent, so Settings has no Siri, Camera Control or Action \
                Button and About no Model Name. Hardware the VM does not have is left out. Takes the \
                iPhone's device tree from the VM's FirmwareOriginals, and recovers it there from the \
                VM's IPSW in ~/.vphone/ipsws when it is missing.
                """,
                target: .prebootDeviceTree,
            ),
            VPhonePatchDeclaration(
                identifier: prebootFoldableVMSubtype,
                title: "Foldable VM sub-type",
                summary: """
                Reports Apple's own VM sub-type for a foldable board in the restored Preboot device \
                tree (iPhone Duo's V68AP becomes V68VM2025). SpringBoard then treats the device as a \
                VM and restores its fold pose from settings, instead of waiting for hinge hardware \
                the VM does not have. Restore keeps the board's own sub-type.
                """,
                target: .prebootDeviceTree,
            ),
            VPhonePatchDeclaration(
                identifier: prebootFoldableProductId,
                title: "Foldable product identity",
                summary: """
                Research only, off in every preset. Replaces /product/product-id in a foldable \
                guest's restored Preboot device tree with the board's own token, taken from the \
                Duo's DeviceTree.v68ap. Measured on duotest-m5 (27.1, 24A94425): with the Duo \
                token and one display, SpringBoard crash-loops and launchd reboots the guest into \
                device-recovery — the Duo branches the token opens expect the second panel. \
                CoreMotion's hinge capability therefore needs a narrower route than the device-tree \
                token; Apple's Duo simulator satisfies it by registering two displays in its device \
                type, not by the token alone.
                """,
                target: .prebootDeviceTree,
            ),
            VPhonePatchDeclaration(
                identifier: prebootHaptics,
                title: "Haptics node",
                summary: """
                Removes the haptics node from a guest's restored Preboot device tree, iPhone or \
                iPad, as fw patch now does. With it iOS believes the guest has a Taptic Engine, \
                plays every tone with its haptic track, and drops the tone when the haptic engine \
                a VM does not have fails to start.
                """,
                target: .prebootDeviceTree,
            ),
            VPhonePatchDeclaration(
                identifier: prebootMicrophoneArray,
                title: "Microphone array claims",
                summary: """
                Removes spatial audio capture and Audio Mix from the audio node of a guest's \
                restored Preboot device tree, as fw patch now does. Both stand for a \
                four-microphone array; with them iOS 27's Voice Memos records through the spatial \
                capture route, which gives silence for the Mac's one or two channels.
                """,
                target: .prebootDeviceTree,
            ),

            VPhonePatchDeclaration(
                identifier: "system-systemversion-cfw-build_version",
                title: "Reported build version",
                summary: """
                Rewrites the guest's SystemVersion build string. Needs a build to write: the \
                preset's BuildVersion parameter, or the SPOOF_BUILD environment variable. With \
                neither, this patch has nothing to do even when it is on.
                """,
                target: .guestFile(path: "/System/Library/CoreServices/SystemVersion.plist"),
            ),
        ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.guest.system"],
    )

    /// The virtio sound HAL plugin, installed by `cfw install` and by the
    /// environment update.
    public static let virtioSoundDriver = "system-virtiosound-cfw-hal_plugin"

    /// The no-default-VAD throw VirtualAudio must survive when the virtio
    /// plugin publishes the guest's speaker route.
    public static let virtualAudioSpeakerRouteThrows = "system-virtualaudio-cfw-speaker_route_throws"

    /// The mute-set CAException that makes VirtualAudio abandon the speaker
    /// route when the HAL server refuses the device-level unmute.
    public static let virtualAudioMuteSetThrow = "system-virtualaudio-cfw-mute_set_throw"

    /// The branch that declines a finished route for lack of HAL Speaker
    /// Protection, opened so the ringtone route keeps the virtio device it
    /// already built instead of falling back to Null_Device, and so a route
    /// that also records is not refused.
    public static let virtualAudioSpeakerProtectionGate = "system-virtualaudio-cfw-speaker_protection_gate"

    /// The precondition that declines a finished route whose software-volume
    /// mode is not the kHardwareOnlyReadOnly the routing database demands,
    /// opened one step after the speaker-protection gate so the route keeps
    /// the virtio aggregate it already built.
    public static let virtualAudioVolumeModePrecondition = "system-virtualaudio-cfw-volume_mode_precondition"

    /// The two device-state updates made to wait for the DeviceStateManager
    /// singleton instead of dereferencing it when no manager was ever
    /// constructed — the null gate audiomxd crash-loops without.
    public static let virtualAudioDeviceStateNullGate = "system-virtualaudio-cfw-device_state_null_gate"

    /// The speaker chains in graph_configurations.plist, moved onto the
    /// generic graph path so the DSP chain factory never needs the physical
    /// Speaker device a VM does not have.
    public static let virtualAudioGraphConfigurations = "system-virtualaudio-cfw-speaker_graph_chains"

    /// Every speaker chain in graph_configurations.plist, pointed at the raw
    /// one so playback is not shaped for a speaker the VM does not have.
    public static let virtualAudioSpeakerRawChains = "system-virtualaudio-cfw-speaker_raw_chains"

    /// The general microphone chains in graph_configurations.plist, pointed at
    /// their measurement siblings so a recording is not pushed through
    /// dynamics tuned to a microphone the VM does not have.
    public static let virtualAudioMicrophoneChains = "system-virtualaudio-cfw-microphone_graph_chains"

    /// The iPad audio node repair in the restored Preboot device tree, for an
    /// iPad VM patched before `fw patch` copied the board's node.
    public static let homePodTopCap = "system-homepod-exp-top_cap"
    public static let homePodDisplayPath = "/usr/share/vphone/HomePodDisplay.plist"
    public static let homePodSetupBypass = "system-homepod-exp-setup_bypass"
    public static let homePodSetupPath = "/usr/share/vphone/HomePodSetup.plist"
    public static let homePodWelcome = "system-homepod-exp-welcome"
    public static let homePodWelcomePath = "/usr/share/vphone/HomePodWelcome.plist"
    public static let homePodSiriSpeech = "system-homepod-exp-siri_speech"
    public static let homePodSiriSpeechPath = "/usr/share/vphone/HomePodSiriSpeech.plist"

    public static let prebootBoardAudio = "preboot-cfw-devicetree_board_audio"
    public static let homePodAudioProduct = "preboot-homepod-exp-audio_product"

    /// The iPhone product description in the restored Preboot device tree,
    /// taken from the iPhone's own tree: see `DeviceTreePatcher.presentPhoneProduct`.
    public static let prebootIPhoneProduct = "preboot-cfw-devicetree_iphone_product"

    /// Apple's VM sub-type for a foldable board in the restored Preboot
    /// device tree.
    public static let prebootFoldableVMSubtype = "preboot-cfw-devicetree_foldable_vm_subtype"
    public static let prebootFoldableProductId = "preboot-exp-devicetree_foldable_product_id"

    /// The haptics node removal in the restored Preboot device tree, for any
    /// VM patched before `fw patch` removed it from every guest's tree.
    public static let prebootHaptics = "preboot-cfw-devicetree_haptics"

    /// The microphone array claims removed from the restored Preboot device
    /// tree, for any VM patched before `fw patch` removed them from every
    /// guest's tree.
    public static let prebootMicrophoneArray = "preboot-cfw-devicetree_microphone_array"

    /// The boot-chain DeviceTree patch each Preboot repair stands in for.
    /// `fw patch` writes the first into the tree a restore installs; the
    /// repair writes the same change into the tree a VM restored before that
    /// patch existed already has. Either one puts the change in the guest, so
    /// the drift report counts the pair as one.
    public static let prebootRepairs: [String: String] = [
        "devicetree-cfw-ipad_audio": prebootBoardAudio,
        "devicetree-cfw-product_haptics_node": prebootHaptics,
        "devicetree-cfw-product_audio_microphone_array": prebootMicrophoneArray,
    ]

    /// The preset parameter `system-systemversion-cfw-build_version` reads.
    public static let buildVersionParameter = "BuildVersion"
}
