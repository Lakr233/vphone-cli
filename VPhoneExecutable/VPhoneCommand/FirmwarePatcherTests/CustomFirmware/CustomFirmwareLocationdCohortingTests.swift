@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Locationd cohort configuration")
struct CustomFirmwareLocationdCohortingTests {
    @Test
    func `selected only for IOS 27`() throws {
        for base in [nil, "18.6", "26.6.2", "27.0", "27.0.1", "28.0"] as [String?] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: base.flatMap { VPhoneVersion($0) }, cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(FirmwareGuestSystemPatchSet.locationdCohorting) == (base?.hasPrefix("27.") == true))
        }
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary], [nil, false, true] as [Bool?])
    func `preserves other features and encoding`(format: PropertyListSerialization.PropertyListFormat, enabled: Bool?) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var feature: [String: Any] = ["DevelopmentPhase": "FeatureComplete", "Metadata": "retained"]
        if let enabled { feature["Enabled"] = enabled }
        let original: [String: Any] = [
            "CLAutoCohort": feature,
            "OtherFeature": ["Enabled": true],
        ]
        let input = try PropertyListSerialization.data(fromPropertyList: original, format: format, options: 0)
        try input.write(to: url)
        #expect(try CustomFirmwareLocationdCohorting.patch(at: url, dryRun: true))
        #expect(try Data(contentsOf: url) == input)
        #expect(try CustomFirmwareLocationdCohorting.patch(at: url))
        let output = try Data(contentsOf: url)
        var outputFormat = PropertyListSerialization.PropertyListFormat.xml
        let root = try #require(PropertyListSerialization.propertyList(from: output, format: &outputFormat) as? [String: Any])
        #expect(outputFormat == format)
        #expect((root["OtherFeature"] as? NSDictionary) == (original["OtherFeature"] as? NSDictionary))
        let cohort = try #require(root["CLAutoCohort"] as? [String: Any])
        #expect(cohort["Enabled"] as? Bool == false)
        #expect(cohort["DevelopmentPhase"] == nil)
        #expect(cohort["Metadata"] as? String == "retained")
        #expect(try !CustomFirmwareLocationdCohorting.patch(at: url, dryRun: true))
        #expect(try !CustomFirmwareLocationdCohorting.patch(at: url))
        #expect(try Data(contentsOf: url) == output)
    }

    @Test
    func `rejects unexpected schema without writing`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for root: [String: Any] in [[:], ["CLAutoCohort": "invalid"], ["CLAutoCohort": ["Enabled": 0]]] {
            let input = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            try input.write(to: url)
            #expect(throws: (any Error).self) { try CustomFirmwareLocationdCohorting.patch(at: url) }
            #expect(try Data(contentsOf: url) == input)
        }
    }
}
