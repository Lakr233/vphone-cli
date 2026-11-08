@testable import FirmwarePatcher
import Foundation
import Img4tool
import Testing

@Suite("Virtual USB DriverKit repair")
struct CustomFirmwareDriverKitTests {
    private typealias Node = FlatDeviceTreeNode

    private static func tree(value: Data? = nil, flags: UInt16 = 0) -> Data {
        Node("device-tree", [
            ("model", Data("iPad16,1\0".utf8)),
            ("compatible", Data("VPHONE600AP\0iPad16,1\0AppleVirtualPlatformARM\0".utf8)),
        ], children: [Node("product", value.map { [("supports-driverkit", $0)] } ?? [],
                          flags: ["supports-driverkit": flags])]).serialized
    }

    @Test func `canonicalizes a disabled or placeholder capability`() throws {
        for (value, flags) in [(Data([0, 0, 0, 0]), UInt16(0)), (Data("syscfg/driverkit\0".utf8), UInt16(0x8000))] {
            let input = Self.tree(value: value, flags: flags)
            let (output, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withVirtualUSBDriverKit(input)
            #expect(output == Self.tree(value: Data([1, 0, 0, 0])))
            #expect(output.count == input.count + delta)
            #expect(changes.map(\.property) == ["product/supports-driverkit"])
        }
    }

    @Test func `preserves IMG4 personalization and dry run leaves the file untouched`() throws {
        let manifest = DERTestEncoder.sequence([DERTestEncoder.ia5String("IM4M")])
        let restoreInfo = DERTestEncoder.sequence([DERTestEncoder.ia5String("IM4R")])
        let original = try DERTestEncoder.sequence([
            DERTestEncoder.ia5String("IMG4"),
            IM4P(fourcc: "dtre", description: "DriverKit fixture", payload: Self.tree()).data,
            DERTestEncoder.element(tag: 0xA0, value: manifest),
            DERTestEncoder.element(tag: 0xA1, value: restoreInfo),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let dryRun = try CustomFirmwarePostRestoreDeviceTree.enableVirtualUSBDriverKit(at: url, dryRun: true, verbose: false)
        #expect(!dryRun.wrote)
        #expect(!dryRun.changes.isEmpty)
        #expect(try Data(contentsOf: url) == original)

        let result = try CustomFirmwarePostRestoreDeviceTree.enableVirtualUSBDriverKit(at: url, verbose: false)
        #expect(result.wrote)
        let updated = try Data(contentsOf: url)
        let children = try DERTestEncoder.children(of: updated)
        #expect(children[2] == DERTestEncoder.element(tag: 0xA0, value: manifest))
        #expect(children[3] == DERTestEncoder.element(tag: 0xA1, value: restoreInfo))
        let im4p = try IM4P(children[1])
        #expect(im4p.fourcc == "dtre")
        #expect(im4p.description == "DriverKit fixture")
        #expect(try im4p.payload() == Self.tree(value: Data([1, 0, 0, 0])))
        #expect(!(try CustomFirmwarePostRestoreDeviceTree.enableVirtualUSBDriverKit(at: url, verbose: false)).wrote)
        #expect(try Data(contentsOf: url) == updated)
    }
}
