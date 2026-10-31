// FirmwarePatchSetCatalogTests.swift — The bundled catalogue, checked against itself.
//
// The manifests are hand-written and the patch identifiers in them have to match
// the record identifiers the patchers emit. Nothing in the type system enforces
// that, so these tests do: every shipped preset resolves, every declaration is
// reachable, and the standard preset still says what the golden corpus was recorded
// against.
//
// The one thing they cannot check without firmware is that each declaration
// actually covers a record. That is what the `[!] declared by no patch set` warning
// is for: it fires during a real `fw patch`, and the golden runs are checked for it.

import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Bundled patch set catalogue")
struct FirmwarePatchSetCatalogTests {
    @Test func `CIBarcode lowering is scoped to the measured base and can be disabled`() throws {
        let identifier = FirmwareGuestSystemPatchSet.arm64eX1CIBarcode
        for base in ["26.4", "27.0.1", "27.1", "27.1.1", "27.2", "28.0"] {
            for blocked in [false, true] {
                var preset = FirmwarePatchSetCatalog.standardPreset
                if blocked {
                    preset.selection = preset.selection.blocking([identifier])
                }
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset,
                    patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base),
                    cloudOS: VPhoneVersion("26.4"),
                )
                let supported = base == "27.1" || base.hasPrefix("27.1.")
                #expect(plan.isEnabled(identifier) == (supported && !blocked))
            }
        }
    }

    @Test(arguments: [FirmwareGuestSystemPatchSet.gyroscope, FirmwareGuestSystemPatchSet.accelerometer, FirmwareGuestSystemPatchSet.attitude])
    func `Motion sensors follow selection and their deployment target`(identifier: String) throws {
        for base in ["18.6.2", "26.4", "27.0.1"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(identifier))
            var blocked = FirmwarePatchSetCatalog.standardPreset
            blocked.selection = blocked.selection.blocking([identifier])
            let disabled = try VPhonePatchPlan.resolve(
                preset: blocked, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(!disabled.isEnabled(identifier))
        }
        let unsupportedBases: [VPhoneVersion?] = [nil, VPhoneVersion("17.0")]
        for base in unsupportedBases {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: base, cloudOS: VPhoneVersion("26.4"),
            )
            #expect(!plan.isEnabled(identifier))
        }
    }

    @Test func `CoreDevice persona lookup is selected only for iOS 27`() throws {
        for base in ["26.4", "27.0.1", "28.0"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(FirmwareGuestSystemPatchSet.installCoordinationPersona) == base.hasPrefix("27."))
        }
    }

    @Test
    func `Every bundled set has a unique identifier and no duplicate patches`() {
        let setIdentifiers = FirmwarePatchSetCatalog.bundled.map(\.identifier)
        #expect(Set(setIdentifiers).count == setIdentifiers.count)

        let patchIdentifiers = FirmwarePatchSetCatalog.allDeclarations.map(\.identifier)
        #expect(Set(patchIdentifiers).count == patchIdentifiers.count)
    }

    @Test
    func `No patch identifier is a record-site prefix of another`() {
        // Two declarations where one is a site of the other would make record
        // attribution depend on the order they happen to be checked in. The
        // resolver picks the longest, but a catalogue that needs that rule to
        // disambiguate its own patches is a catalogue with a naming mistake. Only
        // a dot starts a site: an underscore continues a snake_case name.
        let identifiers = FirmwarePatchSetCatalog.allDeclarations.map(\.identifier)
        for outer in identifiers {
            for inner in identifiers where inner != outer {
                #expect(!inner.hasPrefix(outer + "."), "\(inner) reads as a site of \(outer)")
            }
        }
    }

    @Test
    func `Every patch identifier names its component, effect and patch`() throws {
        // `{component}-{effect}-{name}`. The effect is derived, not chosen:
        // `boot` for a boot-essential patch, `exp` for one standard leaves off,
        // `cfw` for the rest. A patch that changes either property has to be
        // renamed with it, so the identifier never lies about what it is.
        let shape = try Regex("^[a-z0-9_]+(-[a-z0-9_]+)*-(boot|cfw|exp)-[a-z0-9_]+$")
        let standard = FirmwarePatchSetCatalog.standardPreset
        let standardSets = Set(standard.patchSets.map(\.identifier))
        var seen: Set<String> = []
        for set in FirmwarePatchSetCatalog.bundled {
            // The same rule `fw patches --json` reports as `inPreset`.
            let setInStandard = standardSets.contains(set.identifier)
            for patch in set.patches {
                let identifier = patch.identifier
                #expect(seen.insert(identifier).inserted, "\(identifier) is declared twice")
                #expect(identifier.wholeMatch(of: shape) != nil, "\(identifier) does not match the naming scheme")

                let segments = identifier.split(separator: "-", omittingEmptySubsequences: false)
                guard segments.count >= 3 else { continue }
                let effect = segments[segments.count - 2]
                let inStandard = setInStandard && standard.selection.includes(identifier)
                let expected = patch.bootEssential ? "boot" : (inStandard ? "cfw" : "exp")
                #expect(effect == expected, "\(identifier) should use effect \(expected)")
            }
        }
    }

    @Test
    func `Every patch has a title, and a summary if it is boot-essential`() {
        for patch in FirmwarePatchSetCatalog.allDeclarations {
            #expect(!patch.title.isEmpty, "\(patch.identifier) has no title")
            // The editor shows these beside a checkbox someone may untick. A
            // boot-essential patch without an explanation is a trap.
            if patch.bootEssential {
                #expect(!patch.summary.isEmpty, "\(patch.identifier) is boot-essential with no summary")
            }
        }
    }

    @Test
    func `Every shipped preset resolves on each supported base`() throws {
        for preset in FirmwarePatchSetCatalog.builtInPresets {
            for base in ["18.6.2", "26.0", "26.4", "27.0"] {
                for cloud in ["26.1", "26.4"] {
                    let plan = try VPhonePatchPlan.resolve(
                        preset: preset,
                        patchSets: FirmwarePatchSetCatalog.bundled,
                        iOSBase: VPhoneVersion(base),
                        cloudOS: VPhoneVersion(cloud),
                    )
                    #expect(!plan.enabled.isEmpty)
                    // Nothing a shipped iOS preset does should drop a boot-essential
                    // patch: these are the combinations we claim boot. The tvOS
                    // presets drop exactly the iOS ones an Apple TV has no port of.
                    let tvPresets = [VPhonePatchPreset.homeViewIdentifier, VPhonePatchPreset.tvOSIdentifier, VPhonePatchPreset.tvOS4KIdentifier, VPhonePatchPreset.homePodMiniIdentifier]
                    // `minimal` drops every boot chain patch but iBEC's and LLB's:
                    // its system is customised before the restore instead.
                    let restoreImagePresets = [VPhonePatchPreset.minimalIdentifier, VPhonePatchPreset.watchOSIdentifier]
                    let expected = if tvPresets.contains(preset.identifier) {
                        Set(plan.droppedBootEssentials).isSubset(of: FirmwarePatchSetCatalog.tvOSBlockedPatches)
                    } else if restoreImagePresets.contains(preset.identifier) {
                        Set(plan.droppedBootEssentials).isDisjoint(with: FirmwarePatchSetCatalog.minimalBootChainPatches)
                            && plan.droppedBootEssentials.allSatisfy {
                                FirmwareBootChainPatchSet.manifest.patches.map(\.identifier).contains($0)
                            }
                    } else {
                        plan.droppedBootEssentials.isEmpty
                    }
                    #expect(
                        expected,
                        "\(preset.identifier) on \(base)/\(cloud) drops \(plan.droppedBootEssentials)",
                    )
                }
            }
        }
    }

    @Test
    func `A preset resolves even when no version could be read`() throws {
        // `fw patch` can run against a tree whose manifests it could not parse.
        // Resolution must still succeed; the version-gated patches simply skip.
        let plan = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: nil,
            cloudOS: nil,
        )
        #expect(!plan.enabled.isEmpty)
        #expect(!plan.skippedByVersion.isEmpty)
    }

    @Test
    func `Only minimal and its watch form name the restore image, and patch only iBEC, LLB, the device tree and the research board besides`() throws {
        for preset in FirmwarePatchSetCatalog.builtInPresets {
            let namesRestoreImage = preset.patchSets.map(\.identifier).contains(FirmwareRestoreImagePatchSet.identifier)
            let restoreImagePresets = [VPhonePatchPreset.minimalIdentifier, VPhonePatchPreset.watchOSIdentifier]
            #expect(namesRestoreImage == restoreImagePresets.contains(preset.identifier), "\(preset.identifier)")
        }
        let plan = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.minimalPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        let restoreImage = Set(FirmwareRestoreImagePatchSet.manifest.patches.map(\.identifier))
        let bootChain = FirmwarePatchSetCatalog.minimalBootChainPatches
        let researchBoard = Set(FirmwareResearchBoardPatchSet.manifest.patches.map(\.identifier))
        #expect(plan.enabled == restoreImage.union(FirmwarePatchSetCatalog.minimalDeviceTreePatches).union(bootChain).union(researchBoard))
        #expect(plan.droppedBootEssentials.allSatisfy { !$0.hasPrefix("ibec-") && !$0.hasPrefix("llb-") })

        let watch = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.watchOSPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(watch.enabled == restoreImage
            .union(FirmwarePatchSetCatalog.watchOSDeviceTreePatches).union(bootChain).union(researchBoard))
    }

    @Test
    func `The presets naming the restore image set include the audio payload`() throws {
        func enabled(_ preset: VPhonePatchPreset) throws -> Set<String> {
            try VPhonePatchPlan.resolve(
                preset: preset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("26.4"),
                cloudOS: VPhoneVersion("26.4"),
            ).enabled
        }

        let namesRestoreImage: Set<String> = [
            VPhonePatchPreset.minimalIdentifier,
            VPhonePatchPreset.watchOSIdentifier,
        ]
        
        for preset in FirmwarePatchSetCatalog.builtInPresets {
            let resolved = try enabled(preset)
            #expect(
                resolved.contains(FirmwareRestoreImagePatchSet.watchAudio)
                    == namesRestoreImage.contains(preset.identifier),
                "\(preset.identifier)",
            )
        }
    }

    @Test
    func `The watch audio payload stays selected across supported bases`() throws {
        for base in ["26.4", "26.5", "27.0"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.watchOSPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.enabled.contains(FirmwareRestoreImagePatchSet.watchAudio))
        }
    }

    @Test
    func `Standard leaves every manual-only patch off, on every base`() throws {
        for base in ["18.6.2", "26.4", "27.0"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base),
                cloudOS: VPhoneVersion("26.4"),
            )
            for identifier in FirmwarePatchSetCatalog.manualOnlyPatches {
                #expect(!plan.isEnabled(identifier), "standard enabled \(identifier) on \(base)")
            }
        }
    }

    @Test
    func `Extended adds the applicable manual patches except device-specific repairs`() throws {
        for base in ["18.6.2", "26.4", "27.0", "27.1", "27.2"] {
            let version = VPhoneVersion(base)
            let cloud = VPhoneVersion("26.4")
            let standard = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: version,
                cloudOS: cloud,
            )
            let experimental = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.experimentalPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: version,
                cloudOS: cloud,
            )
            let applicableManual = Set(FirmwarePatchSetCatalog.allDeclarations.filter {
                FirmwarePatchSetCatalog.manualOnlyPatches.contains($0.identifier)
                    && $0.identifier != FirmwareGuestSystemPatchSet.homeViewProfileLookup
                    && $0.identifier != FirmwareGuestSystemPatchSet.homeViewDisplayLookups
                    && $0.identifier != FirmwareGuestSystemPatchSet.homeViewSetupBypass
                    && $0.identifier != FirmwareGuestSystemPatchSet.homeViewEnvironmentService
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodTopCap
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodSetupBypass
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodWelcome
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodSiriSpeech
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodAudioProduct
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodOTAUserland
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodSoundGlow
                    && $0.identifier != FirmwareGuestSystemPatchSet.tvSetupDisplayLookup
                    && $0.identifier != FirmwareGuestSystemPatchSet.tvSetupFocus
                    && $0.identifier != FirmwareGuestSystemPatchSet.tvLocalActivation
                    && $0.identifier != FirmwareGuestSystemPatchSet.tvLegacySetup
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodCryptexStaging
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodCryptexClass
                    && $0.identifier != FirmwareGuestSystemPatchSet.homePodAdHocInstall
                    && $0.applicability.matches(iOSBase: version, cloudOS: cloud)
            }.map(\.identifier))
            #expect(experimental.enabled.subtracting(standard.enabled) == applicableManual)
            #expect(standard.enabled.subtracting(experimental.enabled).isEmpty)
            #expect(experimental.isEnabled(FirmwareGuestSystemPatchSet.settingsRootRows) == (base == "27.0"))
            #expect(experimental.isEnabled(FirmwareGuestSystemPatchSet.settingsSoftwareUpdate) == (base == "27.0"))
        }
    }

    @Test
    func `The two patches pinned by release are off everywhere else`() throws {
        // These two were flags once (`--force-exc-guard`, `--force-dsc-maxslide`).
        // They are now pinned to the release that needs them, so a base that does
        // not need them never gets them from a preset.
        let pinned = ["kernel-boot-thread_guard_violation": 18, "dyld-boot-maxslide": 27]
        for (identifier, requiredMajor) in pinned {
            for base in [18, 26, 27] {
                let plan = try VPhonePatchPlan.resolve(
                    preset: FirmwarePatchSetCatalog.experimentalPreset,
                    patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion("\(base).0"),
                    cloudOS: VPhoneVersion("26.4"),
                )
                #expect(
                    plan.isEnabled(identifier) == (base == requiredMajor),
                    "\(identifier) on iOS \(base) should be \(base == requiredMajor)",
                )
            }
        }
    }

    @Test
    func `Standard opens the paravirtual user clients on every base`() throws {
        // A daemon has to reach the paravirtual GPU: cameracaptured prewarms its
        // shaders at boot and crash-loops without it. Before 27 that is the narrow
        // allowlist; on 27 the broad gate is boot-essential and opens everything, so
        // the narrow patch skips by version there rather than being blocked.
        let narrow = FirmwarePatchSetCatalog.paravirtUserClientsPatch
        let broad = "kernel-boot-iouc_sandbox_gate"
        #expect(!FirmwarePatchSetCatalog.manualOnlyPatches.contains(narrow))
        #expect(FirmwarePatchSetCatalog.standardPreset.selection.includes(narrow))
        for base in ["18.6.2", "26.0", "26.4", "26.6.2", "27.0"] {
            for cloud in ["26.1", "26.4"] {
                let plan = try VPhonePatchPlan.resolve(
                    preset: FirmwarePatchSetCatalog.standardPreset,
                    patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base),
                    cloudOS: VPhoneVersion(cloud),
                )
                let is27 = base.hasPrefix("27.")
                #expect(plan.isEnabled(narrow) == !is27, "\(narrow) on \(base)/\(cloud)")
                #expect(plan.skippedByVersion.contains(narrow) == is27, "\(narrow) on \(base)/\(cloud)")
                #expect(plan.isEnabled(broad) == is27, "\(broad) on \(base)/\(cloud)")
            }
        }
    }

    @Test
    func `Standard turns ProMotion on, on every base`() throws {
        let patch = FirmwarePatchSetCatalog.proMotionPatch
        #expect(!FirmwarePatchSetCatalog.manualOnlyPatches.contains(patch))
        #expect(FirmwarePatchSetCatalog.standardPreset.selection.includes(patch))
        for base in ["18.6.2", "26.0", "26.4", "26.6.2", "27.0"] {
            for cloud in ["26.1", "26.4"] {
                let plan = try VPhonePatchPlan.resolve(
                    preset: FirmwarePatchSetCatalog.standardPreset,
                    patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base),
                    cloudOS: VPhoneVersion(cloud),
                )
                #expect(plan.isEnabled(patch), "\(patch) on \(base)/\(cloud)")
            }
        }
        // A VM that blocks it keeps the host's 60 Hz.
        let blocked = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0"),
            cloudOS: VPhoneVersion("26.4"),
            blocked: [patch],
        )
        #expect(!blocked.isEnabled(patch))
    }

    @Test
    func `Standard enables persistent GPU caches while explicit blocks and tvOS stay off`() throws {
        let patch = FirmwarePatchSetCatalog.paravirtTask3Patch
        let guest = FirmwareGuestSystemPatchSet.metalCacheReuse
        let standard = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0.1"), cloudOS: VPhoneVersion("26.4"),
        )
        #expect(standard.isEnabled(patch))
        #expect(standard.isEnabled(guest))
        // Existing records use the experimental identifier. A saved opt-out
        // must still win when the preset now turns the renamed patch on.
        let blocked = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0.1"), cloudOS: VPhoneVersion("26.4"),
            blocked: Set(FirmwarePatchSetCatalog.currentIdentifiers(["kernel-exp-paravirt_gpu_task3"])),
        )
        #expect(!blocked.isEnabled(patch))
        // The kernel anchors exist only in cloudOS 26.4; earlier kernels must
        // not select a patch whose discovery would abort the kernel install.
        for (iOS, cloudOS) in [("18.6.2", "26.1"), ("26.2", "26.2"), ("26.3.1", "26.3")] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(iOS), cloudOS: VPhoneVersion(cloudOS),
            )
            #expect(!plan.isEnabled(patch))
        }
        for preset in [FirmwarePatchSetCatalog.tvOSPreset, FirmwarePatchSetCatalog.tvOS4KPreset, FirmwarePatchSetCatalog.homePodMiniPreset] {
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(!plan.isEnabled(patch))
            #expect(!plan.isEnabled(guest))
        }
    }

    @Test
    func `A renamed patch maps to one the catalogue declares`() {
        let declared = Set(FirmwarePatchSetCatalog.allDeclarations.map(\.identifier))
        for (old, new) in FirmwarePatchSetCatalog.renamedPatches {
            #expect(!declared.contains(old), "\(old) is still declared")
            #expect(declared.contains(new), "\(old) maps to \(new), which nothing declares")
        }
        // Records using an old identifier, possibly beside its replacement,
        // read as the new one, once, in place.
        #expect(
            FirmwarePatchSetCatalog.currentIdentifiers([
                "kernel-exp-hv_vmm",
                "kernel-exp-display_refresh_120hz",
                FirmwarePatchSetCatalog.proMotionPatch,
                "kernel-exp-paravirt_gpu_task3",
                FirmwarePatchSetCatalog.paravirtTask3Patch,
            ]) == ["kernel-exp-hv_vmm", FirmwarePatchSetCatalog.proMotionPatch, FirmwarePatchSetCatalog.paravirtTask3Patch],
        )
    }

    @Test
    func `The Frida relaxations need cloudOS 26.4`() throws {
        for cloud in ["26.1", "26.4"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.experimentalPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("26.4"),
                cloudOS: VPhoneVersion(cloud),
            )
            let on = FirmwareKernelFridaPatchSet.manifest.patches.allSatisfy {
                plan.isEnabled($0.identifier)
            }
            #expect(on == (cloud == "26.4"))
        }
    }

    @Test
    func `The hv_vmm_present patches move together, and only experimental has them`() throws {
        // Three patches, one behaviour: the kernel OID rename, the shared-cache
        // mangle and the watchdogd cache patch. A plan holding some without the
        // rest is broken — the rename alone breaks the graphics and ML paths and
        // panics watchdogd, the others alone do nothing — and all together brick a
        // freshly restored 26.4 guest, which is why standard has none. See
        // FirmwareKernelHypervisorPatchSet.
        let pair = FirmwarePatchSetCatalog.hypervisorConcealmentPatches
        #expect(pair.count == 3)
        for identifier in pair {
            let declaration = try #require(
                FirmwarePatchSetCatalog.allDeclarations.first { $0.identifier == identifier },
                "\(identifier) is not declared by any bundled set",
            )
            // Not boot-essential: standard drops both, and a shipped preset that
            // drops a boot-essential patch warns on every run.
            #expect(!declaration.bootEssential)
        }
        for base in ["18.6.2", "26.4", "27.0"] {
            for cloud in ["26.1", "26.4"] {
                for preset in FirmwarePatchSetCatalog.builtInPresets {
                    let plan = try VPhonePatchPlan.resolve(
                        preset: preset,
                        patchSets: FirmwarePatchSetCatalog.bundled,
                        iOSBase: VPhoneVersion(base),
                        cloudOS: VPhoneVersion(cloud),
                    )
                    let on = pair.filter { plan.isEnabled($0) }
                    #expect(
                        on.isEmpty || on == pair,
                        "\(preset.identifier) on \(base)/\(cloud) enabled only \(on)",
                    )
                    #expect(on.isEmpty == (preset.identifier != "experimental"))
                }
            }
        }
    }

    @Test
    func `Every set's manifest survives a plist round trip`() throws {
        for manifest in FirmwarePatchSetCatalog.bundled {
            let decoded = try VPhonePatchSetManifest.decode(manifest.encodedPlist())
            #expect(decoded == manifest, "\(manifest.identifier) did not round trip")
        }
    }

    @Test
    func `Every built-in preset survives a plist round trip`() throws {
        for preset in FirmwarePatchSetCatalog.builtInPresets {
            #expect(try VPhonePatchPreset.decode(preset.encodedPlist()) == preset)
        }
    }

    @Test
    func `The shipped preset plists match the built-in copies`() throws {
        // The bundle reads the plists; a dev build falls back to the Swift copies.
        // They have to agree, or a VM built from an Xcode build and a VM built from
        // a staged bundle would get different patches.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PatchSets
            .deletingLastPathComponent() // FirmwarePatcherTests
            .deletingLastPathComponent() // VPhoneCommand
            .deletingLastPathComponent() // VPhoneExecutable/VPhoneCommand
            .appendingPathComponent("VPhoneVirtualization/Resources/patches_presets", isDirectory: true)
        let shipped = try VPhonePatchPreset.readAll(fromDirectory: directory)
        #expect(shipped.count == FirmwarePatchSetCatalog.builtInPresets.count)
        for builtIn in FirmwarePatchSetCatalog.builtInPresets {
            let match = shipped.first { $0.identifier == builtIn.identifier }
            if match != builtIn, let match,
               case let .block(shippedBlocked) = match.selection,
               case let .block(builtInBlocked) = builtIn.selection {
                let missing = builtInBlocked.subtracting(shippedBlocked).sorted()
                let extra = shippedBlocked.subtracting(builtInBlocked).sorted()
                #expect(match == builtIn, "\(builtIn.identifier).plist differs from the built-in copy — plist missing: \(missing), plist extra: \(extra)")
            } else {
                #expect(match == builtIn, "\(builtIn.identifier).plist differs from the built-in copy")
            }
        }
    }

    @Test
    func `Standard comes first in a picker`() {
        #expect(FirmwarePatchSetCatalog.builtInPresets.first?.isStandard == true)
    }

    @Test
    func `No bundled set is external, so root cfw install never loads a file`() {
        for preset in FirmwarePatchSetCatalog.builtInPresets {
            #expect(!preset.usesExternalPatchSets)
        }
    }
}
