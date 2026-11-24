@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Internal release type for offline app authorization")
struct CustomFirmwareInternalReleaseTypeTests {
    /// iOS 27.2's SystemVersion.plist, read from a guest.
    static let stock: [String: String] = [
        "BuildID": "79DC7400-CE82-11F1-B523-97A425208D9D",
        "ProductBuildVersion": "24B119",
        "ProductCopyright": "1983-2026 Apple Inc.",
        "ProductName": "iPhone OS",
        "ProductVersion": "27.2",
        "SystemImageID": "38F6830C-09C0-4E12-BFCE-5D9F0358A3A7",
    ]

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func `adds ReleaseType and keeps the rest`(format: PropertyListSerialization.PropertyListFormat) throws {
        let input = try PropertyListSerialization.data(fromPropertyList: Self.stock, format: format, options: 0)
        let output = try #require(try CustomFirmwareInternalReleaseType.patched(systemVersion: input))
        var outputFormat = PropertyListSerialization.PropertyListFormat.xml
        let root = try #require(PropertyListSerialization.propertyList(from: output, format: &outputFormat) as? [String: Any])
        #expect(outputFormat == format)
        #expect(root["ReleaseType"] as? String == "Internal")
        var rest = root
        rest["ReleaseType"] = nil
        #expect(NSDictionary(dictionary: rest) == NSDictionary(dictionary: Self.stock))
        // Already Internal: nothing to write.
        #expect(try CustomFirmwareInternalReleaseType.patched(systemVersion: output) == nil)
    }

    @Test
    func `refuses a plist that is not SystemVersion`() throws {
        let other = try PropertyListSerialization.data(fromPropertyList: ["Enabled": true], format: .xml, options: 0)
        #expect(throws: (any Error).self) { try CustomFirmwareInternalReleaseType.patched(systemVersion: other) }
    }

    @Test
    func `the override turns off every os_variant internal check`() {
        // libsystem_darwin's default when /var/db/disableAppleInternal names none.
        #expect(String(decoding: CustomFirmwareInternalReleaseType.osVariantOverride, as: UTF8.self) == "content,diagnostics,ui,security\n")
        #expect(CustomFirmwareInternalReleaseType.osVariantOverridePath == "usr/share/misc/os_variant_override")
    }
}
