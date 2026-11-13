import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Standalone accessibility patch selection")
struct FirmwareAccessibilityPatchTests {
    @Test func `the in-process plug-in inventory covers UIKit and SwiftUI without duplicate targets`() throws {
        let images = FirmwareGuestSystemPatchSet.arm64eX1AccessibilityImages
        #expect(images.count == 35)
        for name in ["UIKitPopAccessibility", "SwiftUIPopAccessibility", "AccessibilityUtilitiesPopAccessibility"] {
            let image = try #require(images.first { ($0.path as NSString).lastPathComponent == name })
            let bundle = "System/Library/AccessibilityBundles/\(name).axbundle"
            #expect(image.bundle == bundle)
            #expect(image.path == bundle + "/" + name)
            #expect(image.identifier == "system-\(name.lowercased())-cfw-arm64e_x1")
        }
        let all = FirmwareGuestSystemPatchSet.arm64eX1OptionalImages
        #expect(all.count == images.count + FirmwareGuestSystemPatchSet.arm64eX1DebugImages.count)
        #expect(Set(all.map(\.identifier)).count == all.count)
        #expect(Set(all.map(\.path)).count == all.count)
        #expect(Set(all.map { ($0.path as NSString).lastPathComponent }).count == all.count)
        #expect(!all.contains { $0.path == FirmwareGuestSystemPatchSet.homePopAccessibilityExecutablePath })
    }

    @Test func `each plug-in can be disabled independently and uses image-based applicability`() throws {
        let images = FirmwareGuestSystemPatchSet.arm64eX1AccessibilityImages
        for version in [nil, "18.6.2", "26.1", "27.1", "27.2", "28.0"] as [String?] {
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
                    for other in FirmwareGuestSystemPatchSet.arm64eX1OptionalImages where other.identifier != image.identifier {
                        #expect(plan.isEnabled(other.identifier))
                    }
                }
            }
        }
    }

    @Test func `unvalidated OS presets retain their accessibility opt-out`() throws {
        let identifiers: Set<String> = ["tvos", "tvos-4k", "homepod-mini", "homeview", "watchos", "visionos"]
        for preset in FirmwarePatchSetCatalog.builtInPresets where identifiers.contains(preset.identifier) {
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("27.1"), cloudOS: VPhoneVersion("26.4"),
            )
            for image in FirmwareGuestSystemPatchSet.arm64eX1AccessibilityImages {
                #expect(!plan.isEnabled(image.identifier))
            }
        }
    }
}
