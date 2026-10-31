// FirmwareGuestPatchResolution.swift — Which guest patches an installed VM should run now.
//
// A VM carries two patch records the guest half of an install reads: the plan
// `fw patch` resolved, and the selection its owner has since edited. They can
// disagree, and which one wins depends on where a patch lands.
//
// A boot-chain patch was built into the restore tree or `FirmwareOriginals` the
// moment `fw patch` ran; the bytes are already in those files, so the plan is
// the truth for them and the current selection cannot change them without
// another `fw patch`. A guest patch is different: nothing writes it until the
// guest half of an install runs, and that half runs every `cfw install` and
// `cfw update-environment`. So a guest patch should follow the current
// selection, which is both what lets `fw set-patches` then `cfw
// update-environment` turn one on and what lets it turn one off.
//
// `VPhoneCustomFirmwareInstaller.withLateGuestPatches` used to do a narrow
// version of this — it merged in a short list of guest patches newer than most
// VMs' plans, and only ever added. This resolves the whole guest half from the
// selection, both directions, and the installer's late-patch list is gone.

import Foundation
import VPhonePatchKit

public enum FirmwareGuestPatchResolution {
    /// TV admits the gigalocker repair, opt-in dyld TPRO compatibility, virtual
    /// Bluetooth, and vphoned with the launchd cache gate its launchd.plist entry needs.
    /// Other payloads, cache patches and shell integration need a TV port and
    /// validation before the installer can select them.
    public static let tvSupportedGuestPatches: Set<String> = [
        FirmwareGuestSystemPatchSet.virtualBluetooth,
        "system-seputil-boot-gigalocker_uuid",
        "system-gigalocker-boot-rename",
        FirmwareGuestSystemPatchSet.tvTPRO,
        "system-vphoned-boot-install",
        "system-launchd_cache_loader-boot-unsecure_cache_gate",
    ]

    /// An arm64e Apple TV (the 4K, from its OTA) also admits the paravirtual
    /// GPU driver, which a plain-arm64 userland cannot load, the OTA userland
    /// swap itself, and the iOS 27 shared-cache patches its tvOS 27 OTA meets.
    /// It admits the environment's launchd hook and SystemHook too, marked
    /// tvOS at install, with the launchd patch that loads the hook: both are
    /// arm64e, so a plain-arm64 launchd could not load them.
    public static let tvArm64eGuestPatches: Set<String> = Set([
        "system-extensions-boot-gpu_bundle",
        FirmwareGuestSystemPatchSet.tvOTAUserland,
        FirmwareGuestSystemPatchSet.tvSetupDisplayLookup,
        FirmwareGuestSystemPatchSet.tvSetupFocus,
        FirmwareGuestSystemPatchSet.tvLocalActivation,
        FirmwareGuestSystemPatchSet.tvLegacySetup,
        "system-launchdaemons-boot-environment",
        "system-launchd-boot-jetsam_panic_guard_bypass",
    ]).union(FirmwarePatchSetCatalog.tvOS27UserlandPatches)

    public static func unvalidatedTVGuestPatches(enabled: Set<String>, arm64eUserland: Bool = false) -> [String] {
        let admitted = arm64eUserland ? tvSupportedGuestPatches.union(tvArm64eGuestPatches) : tvSupportedGuestPatches
        return enabled.intersection(guestTargetIdentifiers).subtracting(admitted).sorted()
    }

    /// HomePod has its own arm64e IPSW. Sharing TVOS does not admit the
    /// Apple TV OTA swap, GPU injection, or plain-arm64 dyld workarounds.
    public static let homePodSupportedGuestPatches = tvSupportedGuestPatches
        .subtracting([FirmwareGuestSystemPatchSet.tvTPRO])
        .union([FirmwareGuestSystemPatchSet.homePodTopCap, FirmwareGuestSystemPatchSet.homePodSetupBypass, FirmwareGuestSystemPatchSet.homePodAirPlayVM,
                FirmwareGuestSystemPatchSet.homePodAudioProduct, FirmwareGuestSystemPatchSet.homePodWelcome,
                FirmwareGuestSystemPatchSet.homePodSiriSpeech,
                FirmwareGuestSystemPatchSet.homePodOTAUserland, FirmwareGuestSystemPatchSet.homePodSoundGlow,
                FirmwareGuestSystemPatchSet.homePodCryptexStaging, FirmwareGuestSystemPatchSet.homePodCryptexClass,
                FirmwareGuestSystemPatchSet.installCoordinationPersona,
                FirmwareGuestSystemPatchSet.homePodAdHocInstall,
                FirmwareGuestSystemPatchSet.virtioSoundDriver])
        .union(FirmwarePatchSetCatalog.tvOS27UserlandPatches)

    public static func unvalidatedHomePodGuestPatches(enabled: Set<String>) -> [String] {
        enabled.intersection(guestTargetIdentifiers).subtracting(homePodSupportedGuestPatches).sorted()
    }

    /// HomeView uses its own shell and setup. Sharing the tvOS ABI does not
    /// admit Apple TV setup/focus/activation adapters or HomePod capabilities.
    public static let homeViewSupportedGuestPatches = tvSupportedGuestPatches
        .union(tvArm64eGuestPatches)
        .subtracting([FirmwareGuestSystemPatchSet.tvTPRO, FirmwareGuestSystemPatchSet.tvLegacySetup,
                     FirmwareGuestSystemPatchSet.tvSetupDisplayLookup, FirmwareGuestSystemPatchSet.tvSetupFocus,
                     FirmwareGuestSystemPatchSet.tvLocalActivation])
        .union([FirmwareGuestSystemPatchSet.homeViewProfileLookup, FirmwareGuestSystemPatchSet.homeViewDisplayLookups, FirmwareGuestSystemPatchSet.homeViewSetupBypass, FirmwareGuestSystemPatchSet.homeViewEnvironmentService])

    public static func unvalidatedHomeViewGuestPatches(enabled: Set<String>) -> [String] {
        enabled.intersection(guestTargetIdentifiers).subtracting(homeViewSupportedGuestPatches).sorted()
    }

    public static let homePodWelcomeDependencies: Set<String> = [
        "system-vphoned-boot-install",
        FirmwareGuestSystemPatchSet.homePodTopCap,
        FirmwareGuestSystemPatchSet.homePodSetupBypass,
        FirmwareGuestSystemPatchSet.virtioSoundDriver,
        FirmwareGuestSystemPatchSet.homePodSiriSpeech,
    ]

    /// A welcome opt-out remains installable when any prerequisite is also off.
    /// This checks the current guest selection before any filesystem writes;
    /// the guest runtime must still verify readiness before consuming its claim.
    public static func missingHomePodWelcomeDependencies(enabled: Set<String>) -> [String] {
        guard enabled.contains(FirmwareGuestSystemPatchSet.homePodWelcome) else { return [] }
        return homePodWelcomeDependencies.subtracting(enabled).sorted()
    }

    public static let homePodSiriSpeechDependencies: Set<String> = [
        "system-vphoned-boot-install",
        FirmwareGuestSystemPatchSet.homePodTopCap,
        FirmwareGuestSystemPatchSet.virtioSoundDriver,
    ]

    public static func missingHomePodSiriSpeechDependencies(enabled: Set<String>) -> [String] {
        guard enabled.contains(FirmwareGuestSystemPatchSet.homePodSiriSpeech) else { return [] }
        return homePodSiriSpeechDependencies.subtracting(enabled).sorted()
    }

    public static let homePodSoundGlowDependencies: Set<String> = [
        "system-vphoned-boot-install",
        FirmwareGuestSystemPatchSet.homePodTopCap,
    ]

    public static func missingHomePodSoundGlowDependencies(enabled: Set<String>) -> [String] {
        guard enabled.contains(FirmwareGuestSystemPatchSet.homePodSoundGlow) else { return [] }
        return homePodSoundGlowDependencies.subtracting(enabled).sorted()
    }

    /// Every bundled-set patch whose bytes the guest half of an install writes —
    /// the dyld shared cache, a guest Mach-O, its entitlements, a guest file, or
    /// the Preboot device tree. The complement is the boot chain, which `fw
    /// patch` owns.
    public static var guestTargetIdentifiers: Set<String> {
        Set(
            FirmwarePatchSetCatalog.allDeclarations
                .filter { !$0.target.isBootChain }
                .map(\.identifier),
        )
    }

    /// The identifiers the guest half should apply now: boot-chain patches as
    /// the plan resolved them, guest patches as the current selection resolves
    /// them. A guest patch the plan had on but the selection now blocks drops
    /// out; one the plan never had but the selection now allows comes in.
    public static func effectiveEnabled(
        planEnabled: Set<String>,
        selectionEnabled: Set<String>,
    ) -> Set<String> {
        let guest = guestTargetIdentifiers
        return planEnabled.subtracting(guest).union(selectionEnabled.intersection(guest))
    }

    /// The guest patches a selection leaves off — the ones a run should try to
    /// revert. Boot-chain patches are never here: this is only about the guest
    /// half.
    public static func guestPatchesOff(selectionEnabled: Set<String>) -> Set<String> {
        guestTargetIdentifiers.subtracting(selectionEnabled)
    }
}
