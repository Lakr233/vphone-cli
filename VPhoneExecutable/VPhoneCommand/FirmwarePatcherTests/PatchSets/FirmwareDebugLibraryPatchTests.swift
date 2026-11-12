import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Standalone debug-library patch selection")
struct FirmwareDebugLibraryPatchTests {
    @Test func `debug libraries follow selection independently of the OS version`() throws {
        let images = FirmwareGuestSystemPatchSet.arm64eX1DebugImages
        #expect(images.count == 12)
        #expect(Set(images.map(\.path)).count == images.count)
        #expect(Set(images.map { ($0.path as NSString).lastPathComponent }).count == images.count)
        for version in [nil, "18.6.2", "26.1", "26.6.2", "27.1", "27.2", "28.0"] as [String?] {
            for image in images {
                let declaration = try #require(FirmwareGuestSystemPatchSet.manifest.patches.first { $0.identifier == image.identifier })
                #expect(declaration.target == .guestFile(path: "/" + image.path))
                for blocked in [false, true] {
                    var preset = FirmwarePatchSetCatalog.standardPreset
                    if blocked { preset.selection = preset.selection.blocking([image.identifier]) }
                    let plan = try VPhonePatchPlan.resolve(
                        preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                        iOSBase: version.flatMap(VPhoneVersion.init), cloudOS: VPhoneVersion("26.4"),
                    )
                    #expect(plan.isEnabled(image.identifier) == !blocked)
                    for other in images where other.identifier != image.identifier {
                        #expect(plan.isEnabled(other.identifier))
                    }
                }
            }
        }
    }

    @Test func `unvalidated OS presets do not opt into the new debug libraries`() throws {
        let identifiers: Set<String> = ["tvos", "tvos-4k", "homepod-mini", "homeview", "watchos", "visionos"]
        for preset in FirmwarePatchSetCatalog.builtInPresets where identifiers.contains(preset.identifier) {
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("27.1"), cloudOS: VPhoneVersion("26.4"),
            )
            for image in FirmwareGuestSystemPatchSet.arm64eX1DebugImages {
                #expect(!plan.isEnabled(image.identifier))
            }
        }
    }
}
