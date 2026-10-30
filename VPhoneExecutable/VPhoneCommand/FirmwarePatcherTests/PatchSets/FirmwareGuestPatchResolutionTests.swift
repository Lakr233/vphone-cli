// FirmwareGuestPatchResolutionTests.swift — The guest-half selection resolver.
//
// `FirmwareGuestPatchResolution` decides which patches the guest half of an
// install applies now: the boot chain as the plan recorded it, the guest half
// as the current selection resolves it. These tests pin that split and the
// membership of the guest-target set against the real bundled catalogue.

import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Guest patch resolution")
struct FirmwareGuestPatchResolutionTests {
    @Test func `HomeView keeps native setup and its bypass is an explicit reversible selection`() throws {
        let plan = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.homeViewPreset, patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.2"), cloudOS: VPhoneVersion("26.4")
        )
        #expect(plan.isEnabled(FirmwareGuestSystemPatchSet.tvOTAUserland))
        #expect(plan.isEnabled("system-extensions-boot-gpu_bundle"))
        #expect(!plan.isEnabled(FirmwareGuestSystemPatchSet.homeViewSetupBypass))
        #expect(FirmwareGuestPatchResolution.unvalidatedHomeViewGuestPatches(enabled: plan.enabled).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedHomeViewGuestPatches(enabled: [FirmwareGuestSystemPatchSet.homeViewSetupBypass]).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [FirmwareGuestSystemPatchSet.homeViewSetupBypass], arm64eUserland: true) == [FirmwareGuestSystemPatchSet.homeViewSetupBypass])
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [FirmwareGuestSystemPatchSet.homeViewSetupBypass]) == [FirmwareGuestSystemPatchSet.homeViewSetupBypass])
        #expect(!plan.isEnabled(FirmwareGuestSystemPatchSet.tvSetupFocus))
        #expect(!plan.isEnabled(FirmwareGuestSystemPatchSet.tvLocalActivation))
    }

    @Test func `native TV setup adapters are limited to the 27 point 2 4K preset`() throws {
        for identifier in [FirmwareGuestSystemPatchSet.tvSetupDisplayLookup, FirmwareGuestSystemPatchSet.tvSetupFocus, FirmwareGuestSystemPatchSet.tvLocalActivation] {
            for version in ["26.6", "27.0", "27.1", "27.2", "27.3"] {
                for preset in FirmwarePatchSetCatalog.builtInPresets {
                    let plan = try VPhonePatchPlan.resolve(
                        preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                        iOSBase: VPhoneVersion(version), cloudOS: VPhoneVersion("26.4"),
                    )
                    #expect(plan.isEnabled(identifier) == (version == "27.2" && preset.identifier == VPhonePatchPreset.tvOS4KIdentifier))
                }
            }
            #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier], arm64eUserland: true).isEmpty)
            #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [identifier]) == [identifier])
            #expect(FirmwareGuestPatchResolution.guestPatchesOff(selectionEnabled: []).contains(identifier))
            #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier]) == [identifier])
        }
    }

    @Test func `legacy TV setup is not selected by any preset`() throws {
        let identifier = FirmwareGuestSystemPatchSet.tvLegacySetup
        for preset in FirmwarePatchSetCatalog.builtInPresets {
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("27.2"), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(!plan.isEnabled(identifier))
        }
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier], arm64eUserland: true).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [identifier]) == [identifier])
    }

    @Test func `HomePod persona lookup uses isolated tvOS deployment and follows selection`() throws {
        let identifier = FirmwareGuestSystemPatchSet.installCoordinationPersona
        for base in ["26.4", "27.0", "27.2", "28.0"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.homePodMiniPreset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(identifier) == base.hasPrefix("27."))
            #expect(!plan.isEnabled("system-launchdaemons-boot-environment"))
            #expect(!plan.isEnabled(FirmwareGuestSystemPatchSet.arm64eX1LaunchdBootstrap))
            #expect(!plan.isEnabled("system-launchd-boot-jetsam_panic_guard_bypass"))
        }
        let disabled = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.homePodMiniPreset, patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.2"), cloudOS: VPhoneVersion("26.4"), blocked: [identifier],
        )
        #expect(!disabled.isEnabled(identifier))
        #expect(FirmwareGuestPatchResolution.guestPatchesOff(selectionEnabled: disabled.enabled).contains(identifier))
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [identifier]).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier], arm64eUserland: true) == [identifier])
    }

    @Test(arguments: [FirmwareGuestSystemPatchSet.homePodCryptexStaging, FirmwareGuestSystemPatchSet.homePodCryptexClass, FirmwareGuestSystemPatchSet.homePodAdHocInstall])
    func `HomePod developer compatibility is independent of the iPhone environment and reversible in selection`(identifier: String) throws {
        for base in ["26.4", "27.0", "27.2", "28.0"] {
            for preset in FirmwarePatchSetCatalog.builtInPresets {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
                )
                #expect(plan.isEnabled(identifier) == (base.hasPrefix("27.")
                    && preset.identifier == VPhonePatchPreset.homePodMiniIdentifier))
                if plan.isEnabled(identifier) {
                    #expect(!plan.isEnabled("system-launchdaemons-boot-environment"))
                    let disabled = try VPhonePatchPlan.resolve(
                        preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                        iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
                        blocked: [identifier],
                    )
                    #expect(!disabled.isEnabled(identifier))
                    #expect(FirmwareGuestPatchResolution.guestPatchesOff(selectionEnabled: disabled.enabled).contains(identifier))
                }
            }
        }
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [identifier]).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier], arm64eUserland: true) == [identifier])
        let declaration = try #require(FirmwarePatchSetCatalog.allDeclarations.first { $0.identifier == identifier })
        let expectedTarget: VPhonePatchTarget = switch identifier {
        case FirmwareGuestSystemPatchSet.homePodCryptexStaging: .guestExecutable(path: "/usr/libexec/cryptexd")
        case FirmwareGuestSystemPatchSet.homePodAdHocInstall: .guestExecutable(path: "/usr/libexec/installd")
        default: .prebootDeviceTree
        }
        #expect(declaration.target == expectedTarget)
        #expect(!declaration.bootEssential)
    }

    @Test(arguments: [FirmwareGuestSystemPatchSet.homePodOTAUserland, FirmwareGuestSystemPatchSet.homePodSoundGlow])
    func `HomePod OTA and Sound Glow require 27 point 2 and stay out of other presets`(identifier: String) throws {
        for version in ["26.6", "27.0", "27.1", "27.2", "27.3"] {
            for preset in FirmwarePatchSetCatalog.builtInPresets {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(version), cloudOS: VPhoneVersion("26.4"),
                )
                #expect(plan.isEnabled(identifier) == (VPhoneVersion(version)! >= VPhoneVersion(major: 27, minor: 2)
                    && preset.identifier == VPhonePatchPreset.homePodMiniIdentifier))
            }
        }
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [identifier]).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier], arm64eUserland: true) == [identifier])
        #expect(FirmwareGuestPatchResolution.guestPatchesOff(selectionEnabled: []).contains(identifier))
    }

    @Test func `Sound Glow requires native cap delivery but not speech or welcome`() throws {
        let glow = FirmwareGuestSystemPatchSet.homePodSoundGlow
        let dependencies = FirmwareGuestPatchResolution.homePodSoundGlowDependencies
        #expect(dependencies == ["system-vphoned-boot-install", FirmwareGuestSystemPatchSet.homePodTopCap])
        let enabled = dependencies.union([glow])
        #expect(FirmwareGuestPatchResolution.missingHomePodSoundGlowDependencies(enabled: enabled).isEmpty)
        for dependency in dependencies {
            #expect(FirmwareGuestPatchResolution.missingHomePodSoundGlowDependencies(enabled: enabled.subtracting([dependency])) == [dependency])
        }
        #expect(FirmwareGuestPatchResolution.missingHomePodSoundGlowDependencies(enabled: []).isEmpty)
        let declaration = try #require(FirmwarePatchSetCatalog.allDeclarations.first { $0.identifier == glow })
        #expect(declaration.target == .guestFile(path: FirmwareGuestSystemPatchSet.homePodSoundGlowPath))
        #expect(!declaration.bootEssential)
    }

    @Test func `only the HomePod preset selects the top cap and TV rejects explicit selection`() throws {
        let identifier = FirmwareGuestSystemPatchSet.homePodTopCap
        for preset in FirmwarePatchSetCatalog.builtInPresets {
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(identifier) == (preset.identifier == VPhonePatchPreset.homePodMiniIdentifier))
        }
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [identifier]).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier]) == [identifier])
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier], arm64eUserland: true) == [identifier])
    }

    @Test(arguments: [FirmwareGuestSystemPatchSet.homePodSetupBypass, FirmwareGuestSystemPatchSet.homePodAudioProduct,
                      FirmwareGuestSystemPatchSet.homePodWelcome, FirmwareGuestSystemPatchSet.homePodSiriSpeech])
    func `HomePod optional guest repairs are version gated and never selected for other devices`(identifier: String) throws {
        for base in ["26.4", "27.0", "27.1"] {
            for preset in FirmwarePatchSetCatalog.builtInPresets {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
                )
                #expect(plan.isEnabled(identifier) == (base.hasPrefix("27.")
                    && identifier != FirmwareGuestSystemPatchSet.homePodAudioProduct
                    && preset.identifier == VPhonePatchPreset.homePodMiniIdentifier))
            }
        }
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [identifier]).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier]) == [identifier])
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [identifier], arm64eUserland: true) == [identifier])
        #expect(FirmwareGuestPatchResolution.guestPatchesOff(selectionEnabled: []).contains(identifier))
    }

    @Test func `HomePod welcome requires every selected runtime prerequisite but opt out is independent`() throws {
        let welcome = FirmwareGuestSystemPatchSet.homePodWelcome
        let dependencies = FirmwareGuestPatchResolution.homePodWelcomeDependencies
        #expect(dependencies == ["system-vphoned-boot-install", FirmwareGuestSystemPatchSet.homePodTopCap,
                                 FirmwareGuestSystemPatchSet.homePodSetupBypass, FirmwareGuestSystemPatchSet.virtioSoundDriver,
                                 FirmwareGuestSystemPatchSet.homePodSiriSpeech])
        let complete = dependencies.union([welcome])
        #expect(FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: complete).isEmpty)
        for dependency in dependencies {
            #expect(FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: complete.subtracting([dependency])) == [dependency])
        }
        #expect(FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: [welcome]) == dependencies.sorted())
        #expect(FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: []).isEmpty)
        #expect(FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: dependencies).isEmpty)
        let plan = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.homePodMiniPreset, patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"),
        )
        #expect(plan.isEnabled(welcome))
        #expect(FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: plan.enabled).isEmpty)
        let declaration = try #require(FirmwarePatchSetCatalog.allDeclarations.first { $0.identifier == welcome })
        #expect(declaration.target == .guestFile(path: "/usr/share/vphone/HomePodWelcome.plist"))
        #expect(!declaration.bootEssential)
    }

    @Test func `HomePod Siri speech requires its native output dependencies and can be disabled independently`() throws {
        let speech = FirmwareGuestSystemPatchSet.homePodSiriSpeech
        let dependencies = FirmwareGuestPatchResolution.homePodSiriSpeechDependencies
        #expect(dependencies == ["system-vphoned-boot-install", FirmwareGuestSystemPatchSet.homePodTopCap,
                                 FirmwareGuestSystemPatchSet.virtioSoundDriver])
        let complete = dependencies.union([speech])
        #expect(FirmwareGuestPatchResolution.missingHomePodSiriSpeechDependencies(enabled: complete).isEmpty)
        for dependency in dependencies {
            #expect(FirmwareGuestPatchResolution.missingHomePodSiriSpeechDependencies(enabled: complete.subtracting([dependency])) == [dependency])
        }
        #expect(FirmwareGuestPatchResolution.missingHomePodSiriSpeechDependencies(enabled: [speech]) == dependencies.sorted())
        #expect(FirmwareGuestPatchResolution.missingHomePodSiriSpeechDependencies(enabled: []).isEmpty)
        #expect(FirmwareGuestPatchResolution.missingHomePodSiriSpeechDependencies(enabled: dependencies).isEmpty)
        #expect(!dependencies.contains(FirmwareGuestSystemPatchSet.homePodSetupBypass))
        #expect(!dependencies.contains(FirmwareGuestSystemPatchSet.homePodWelcome))
        let plan = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.homePodMiniPreset, patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"),
        )
        #expect(plan.isEnabled(speech))
        #expect(FirmwareGuestPatchResolution.missingHomePodSiriSpeechDependencies(enabled: plan.enabled).isEmpty)
        let declaration = try #require(FirmwarePatchSetCatalog.allDeclarations.first { $0.identifier == speech })
        #expect(declaration.target == .guestFile(path: "/usr/share/vphone/HomePodSiriSpeech.plist"))
        #expect(!declaration.bootEssential)
        // Welcome cannot remain enabled after opting out of its speech repair.
        #expect(FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: plan.enabled.subtracting([speech])) == [speech])
    }

    @Test
    func `TV selection keeps vphoned and excludes iOS payloads and cache patches`() throws {
        let standard = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        let unvalidated = FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: standard.enabled)
        #expect(!unvalidated.contains("system-vphoned-boot-install"))
        #expect(!unvalidated.contains("system-launchd_cache_loader-boot-unsecure_cache_gate"))
        #expect(unvalidated.contains("system-launchdaemons-boot-environment"))
        #expect(unvalidated.contains("system-extensions-boot-gpu_bundle"))
        #expect(unvalidated.contains(FirmwareGuestSystemPatchSet.paravirtGPUIndexOffset))
        #expect(unvalidated.contains("dyld-cfw-camera"))
        #expect(!unvalidated.contains("system-seputil-boot-gigalocker_uuid"))
        #expect(!unvalidated.contains("system-gigalocker-boot-rename"))
        let serial = standard.enabled.subtracting(unvalidated)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: serial).isEmpty)
        #expect(serial.intersection(FirmwareGuestPatchResolution.guestTargetIdentifiers)
            == FirmwareGuestPatchResolution.tvSupportedGuestPatches.subtracting([FirmwareGuestSystemPatchSet.tvTPRO]))
        #expect(serial.subtracting(FirmwareGuestPatchResolution.guestTargetIdentifiers)
            == standard.enabled.subtracting(FirmwareGuestPatchResolution.guestTargetIdentifiers))
    }

    @Test
    func `TV TPRO is opt in and retains the TV guest guard`() throws {
        let identifier = FirmwareGuestSystemPatchSet.tvTPRO
        let standard = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"), cloudOS: VPhoneVersion("26.4"),
        )
        #expect(!standard.enabled.contains(identifier))
        let serial = standard.enabled.subtracting(
            FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: standard.enabled),
        ).union([identifier])
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: serial).isEmpty)
        #expect(serial.contains("system-vphoned-boot-install"))
        #expect(!serial.contains("system-extensions-boot-gpu_bundle"))
    }

    @Test
    func `only an arm64e TV admits the GPU driver and the OTA userland`() {
        let gpu = "system-extensions-boot-gpu_bundle"
        let ota = FirmwareGuestSystemPatchSet.tvOTAUserland
        let selection: Set<String> = [gpu, ota, "system-vphoned-boot-install"]
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection) == [gpu, ota].sorted())
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection, arm64eUserland: true).isEmpty)
        // The iOS payloads stay out for both.
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: ["dyld-cfw-camera"], arm64eUserland: true) == ["dyld-cfw-camera"])
    }

    @Test
    func `only an arm64e TV admits the environment hooks and the launchd patch that loads them`() {
        let hooks: Set = ["system-launchdaemons-boot-environment", "system-launchd-boot-jetsam_panic_guard_bypass"]
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: hooks, arm64eUserland: true).isEmpty)
        // Both libraries are arm64e: a plain-arm64 launchd cannot load them.
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: hooks) == hooks.sorted())
        // The X1 launchd bootstrap shares the load command but stays out.
        let x1 = FirmwareGuestSystemPatchSet.arm64eX1LaunchdBootstrap
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [x1], arm64eUserland: true) == [x1])
        // HomePod keeps its own launchd library and no environment.
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: hooks) == hooks.sorted())
    }

    @Test(arguments: ["27.0", "27.2"])
    func `the Apple TV 4K preset swaps in the OTA userland with the GPU driver and no TPRO patches`(version: String) throws {
        let gpu = "system-extensions-boot-gpu_bundle"
        let ota = FirmwareGuestSystemPatchSet.tvOTAUserland
        let tpro: Set = [FirmwareGuestSystemPatchSet.tvTPRO, FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers]
        func plan(_ preset: VPhonePatchPreset) throws -> VPhonePatchPlan {
            try VPhonePatchPlan.resolve(
                preset: preset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("26.6"),
                cloudOS: VPhoneVersion("26.4"),
            )
        }
        let tv4K = try plan(FirmwarePatchSetCatalog.tvOS4KPreset)
        #expect(tv4K.isEnabled(gpu) && tv4K.isEnabled(ota))
        #expect(tv4K.enabled.isDisjoint(with: tpro))
        #expect(tv4K.isEnabled("system-vphoned-boot-install"))
        // The upstream GPU heap index patch stays out, as for every TV guest.
        #expect(!tv4K.isEnabled(FirmwareGuestSystemPatchSet.paravirtGPUIndexOffset))
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: tv4K.enabled, arm64eUserland: true).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: tv4K.enabled) == [gpu, ota].sorted())
        // The 27 shared-cache patches are on but meet only a 27 userland.
        #expect(tv4K.enabled.isDisjoint(with: FirmwarePatchSetCatalog.tvOS27UserlandPatches))
        let tv4K27 = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.tvOS4KPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion(version),
            cloudOS: VPhoneVersion("26.4"),
        )
        // The userland swap and the GPU driver carry on to the 27 OTA.
        #expect(tv4K27.isEnabled(gpu) && tv4K27.isEnabled(ota))
        #expect(tv4K27.enabled.isSuperset(of: FirmwarePatchSetCatalog.tvOS27UserlandPatches))
        #expect(tv4K27.isEnabled("kernel-boot-iomfb_swapend"))
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: tv4K27.enabled, arm64eUserland: true).isEmpty)
        let x1Patches: Set<String> = [
            FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1CacheRemaining,
            FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1FsckBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1LaunchdBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1MountBootstrap,
            "kernel-boot-arm64e_x1",
            "restoreramdisk-boot-apfs_sha3_hash",
        ]
        #expect(tv4K27.enabled.isDisjoint(with: x1Patches))

        // The HD's preset is the mirror image.
        let tvHD = try plan(FirmwarePatchSetCatalog.tvOSPreset)
        #expect(!tvHD.isEnabled(gpu) && !tvHD.isEnabled(ota))
        #expect(tvHD.enabled.isSuperset(of: tpro))
        // Otherwise the two agree.
        #expect(tv4K.enabled.symmetricDifference(tvHD.enabled) == tpro.union([gpu, ota]))
    }

    @Test
    func `HomePod audio uses its shared driver without global identity or iPhone routing patches`() throws {
        let driver = FirmwareGuestSystemPatchSet.virtioSoundDriver
        let product = FirmwareGuestSystemPatchSet.homePodAudioProduct
        let plan = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.homePodMiniPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"),
        )
        #expect(plan.isEnabled(driver))
        #expect(!plan.isEnabled(product))
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: [driver, product]).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [driver]) == [driver])
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: [driver], arm64eUserland: true) == [driver])
        let iPhoneRouting: Set<String> = [
            FirmwareGuestSystemPatchSet.virtualAudioSpeakerRouteThrows,
            FirmwareGuestSystemPatchSet.virtualAudioMuteSetThrow,
            FirmwareGuestSystemPatchSet.virtualAudioSpeakerProtectionGate,
            FirmwareGuestSystemPatchSet.virtualAudioVolumeModePrecondition,
            FirmwareGuestSystemPatchSet.virtualAudioGraphConfigurations,
            FirmwareGuestSystemPatchSet.virtualAudioSpeakerRawChains,
            FirmwareGuestSystemPatchSet.virtualAudioMicrophoneChains,
        ]
        #expect(plan.enabled.isDisjoint(with: iPhoneRouting))
    }

    @Test
    func `HomePod rejects explicit TV payloads while admitting its daemon and 27 compatibility patches`() {
        let supported: Set<String> = [
            "system-vphoned-boot-install",
            "system-launchd_cache_loader-boot-unsecure_cache_gate",
            "system-seputil-boot-gigalocker_uuid",
            "system-gigalocker-boot-rename",
        ]
        let rejected: Set<String> = [
            "system-extensions-boot-gpu_bundle",
            FirmwareGuestSystemPatchSet.tvOTAUserland,
            FirmwareGuestSystemPatchSet.tvTPRO,
            "system-launchdaemons-boot-environment",
            "dyld-cfw-camera",
        ]
        let admitted = supported.union(FirmwarePatchSetCatalog.tvOS27UserlandPatches)
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: admitted).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: admitted.union(rejected)) == rejected.sorted())
        // The TV arm64e guard admits GPU/OTA selection; HomePod's own guard
        // must keep rejecting those even though its userland is also arm64e.
        let tvPayloads: Set<String> = ["system-extensions-boot-gpu_bundle", FirmwareGuestSystemPatchSet.tvOTAUserland]
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: tvPayloads, arm64eUserland: true).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: tvPayloads) == tvPayloads.sorted())
        #expect(FirmwareGuestPatchResolution.homePodSupportedGuestPatches.isDisjoint(with: rejected))
    }

    @Test
    func `HomePod mini uses its own arm64e image with 27 compatibility and no TV OTA or display payload`() throws {
        let excluded: Set<String> = [
            "system-extensions-boot-gpu_bundle",
            FirmwareGuestSystemPatchSet.tvOTAUserland,
            FirmwareGuestSystemPatchSet.tvTPRO,
            FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers,
            FirmwareGuestSystemPatchSet.paravirtGPUIndexOffset,
            "system-launchdaemons-boot-environment",
            "dyld-cfw-camera",
        ]
        #expect(FirmwarePatchSetCatalog.homePodMiniPreset.identifier == VPhonePatchPreset.homePodMiniIdentifier)
        for base in ["26.4", "27.0"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.homePodMiniPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.enabled.isDisjoint(with: excluded))
            #expect(plan.isEnabled("system-vphoned-boot-install"))
            #expect(plan.isEnabled("system-launchd_cache_loader-boot-unsecure_cache_gate"))
            #expect(plan.isEnabled("devicetree-cfw-homepod_product"))
            #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: plan.enabled).isEmpty)
            if base == "27.0" {
                #expect(plan.enabled.isSuperset(of: FirmwarePatchSetCatalog.tvOS27UserlandPatches))
            } else {
                #expect(plan.enabled.isDisjoint(with: FirmwarePatchSetCatalog.tvOS27UserlandPatches))
            }
        }
    }

    @Test
    func `TV TPRO patches apply to every tvOS 26 userland on the 26.4 kernel`() throws {
        let tv: Set = [FirmwareGuestSystemPatchSet.tvTPRO, FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers]
        for build in ["26.4", "26.6"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(build),
                cloudOS: VPhoneVersion("26.4"),
                allowed: tv,
            )
            #expect(plan.enabled.isSuperset(of: tv), "\(build)")
            #expect(plan.skippedByVersion.isDisjoint(with: tv), "\(build)")
        }
    }

    @Test
    func `Guest target identifiers include the guest patches and exclude the boot chain`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers

        // A dyld-cache patch, a guest Mach-O, a guest file, and a Preboot
        // device-tree patch are all guest-half.
        #expect(guest.contains("dyld-boot-lockdown_mode"))
        #expect(guest.contains("system-seputil-boot-gigalocker_uuid"))
        #expect(guest.contains("system-vphoned-boot-install"))
        #expect(guest.contains(FirmwareGuestSystemPatchSet.prebootHaptics))
        #expect(guest.contains(FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity))

        // Every boot-chain patch is excluded: those are `fw patch`'s, not the
        // guest half's.
        for declaration in FirmwarePatchSetCatalog.allDeclarations where declaration.target.isBootChain {
            #expect(!guest.contains(declaration.identifier), "\(declaration.identifier) is boot-chain")
        }

        // And the set is exactly the non-boot-chain declarations.
        let expected = Set(
            FirmwarePatchSetCatalog.allDeclarations
                .filter { !$0.target.isBootChain }
                .map(\.identifier),
        )
        #expect(guest == expected)
    }

    @Test
    func `Effective enabled keeps boot chain from the plan and guest half from the selection`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers
        let bootChain = Set(
            FirmwarePatchSetCatalog.allDeclarations
                .filter(\.target.isBootChain)
                .map(\.identifier),
        )
        guard
            let boot = bootChain.first,
            let guestOn = guest.first,
            let guestOff = guest.dropFirst().first
        else {
            Issue.record("the bundled catalogue has too few patches to exercise the split")
            return
        }

        // The plan had a boot patch and one guest patch on; the selection now
        // has a *different* guest patch on and the old one off.
        let planEnabled: Set<String> = [boot, guestOn]
        let selectionEnabled: Set<String> = [guestOff]

        let effective = FirmwareGuestPatchResolution.effectiveEnabled(
            planEnabled: planEnabled,
            selectionEnabled: selectionEnabled,
        )

        #expect(effective.contains(boot), "the boot patch stays from the plan")
        #expect(effective.contains(guestOff), "a guest patch the selection turned on comes in")
        #expect(!effective.contains(guestOn), "a guest patch the selection turned off drops out")
    }

    @Test
    func `A boot-chain selection cannot add or drop guest patches`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers
        guard let guestID = guest.first else {
            Issue.record("no guest patches in the catalogue")
            return
        }
        // The selection resolves the guest patch off but names a boot patch the
        // plan never had: the boot side is the plan's alone, so nothing from the
        // selection's boot choices leaks in.
        let planEnabled: Set<String> = [guestID]
        let selectionEnabled: Set<String> = []
        let effective = FirmwareGuestPatchResolution.effectiveEnabled(
            planEnabled: planEnabled,
            selectionEnabled: selectionEnabled,
        )
        #expect(effective.isEmpty, "the guest patch drops and no boot patch is invented")
    }

    @Test
    func `Guest patches off is the guest set minus the selection`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers
        guard let on = guest.first else {
            Issue.record("no guest patches in the catalogue")
            return
        }
        let off = FirmwareGuestPatchResolution.guestPatchesOff(selectionEnabled: [on])
        #expect(!off.contains(on))
        #expect(off == guest.subtracting([on]))
    }
}
