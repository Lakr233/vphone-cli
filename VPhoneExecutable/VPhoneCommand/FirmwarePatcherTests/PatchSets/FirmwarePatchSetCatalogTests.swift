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
                    // Nothing a shipped preset does should drop a boot-essential
                    // patch: these are the combinations we claim boot.
                    #expect(
                        plan.droppedBootEssentials.isEmpty,
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
    func `Extended is standard plus the manual-only patches, and nothing else`() throws {
        let standard = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        let extended = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.extendedPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(extended.enabled.subtracting(standard.enabled) == FirmwarePatchSetCatalog.manualOnlyPatches)
        #expect(standard.enabled.subtracting(extended.enabled).isEmpty)
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
                    preset: FirmwarePatchSetCatalog.extendedPreset,
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
    func `The Frida relaxations need cloudOS 26.4`() throws {
        for cloud in ["26.1", "26.4"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.extendedPreset,
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
    func `The hv_vmm_present patches move together, and only extended has them`() throws {
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
                    #expect(on.isEmpty == preset.isStandard)
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
            #expect(match == builtIn, "\(builtIn.identifier).plist differs from the built-in copy")
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
