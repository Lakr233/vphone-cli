import Foundation
import Testing
@testable import VPhoneCoreKit

struct PCCGPUDriverTests {
    @Test func `stages a validated GPU bundle`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-gpu-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(VPhonePCCGPUDriver.name)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("_CodeSignature"),
            withIntermediateDirectories: true,
        )
        for file in ["AppleParavirtGPUMetalIOGPUFamily",
                     "_CodeSignature/CodeResources"]
        {
            try Data(file.utf8).write(to: source.appendingPathComponent(file))
        }
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier":
                "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily",
                "DTPlatformVersion": "26.4"],
            format: .binary, options: 0,
        )
        try info.write(to: source.appendingPathComponent("Info.plist"))

        let restore = root.appendingPathComponent("restore")
        try VPhonePCCGPUDriver.stage(
            from: source,
            into: restore,
            expectedPlatformVersion: "26.4",
        )
        let staged = VPhonePCCGPUDriver.stagedBundle(in: restore)
        #expect(staged == restore.appending(path: ".pcc-gpu/AppleParavirtGPUMetalIOGPUFamily.bundle"))
        #expect(try Data(contentsOf: staged.appendingPathComponent("AppleParavirtGPUMetalIOGPUFamily"))
            == Data("AppleParavirtGPUMetalIOGPUFamily".utf8))

        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.stage(
                from: source,
                into: restore,
                expectedPlatformVersion: "26.1",
            )
        }

        try FileManager.default.removeItem(at: source.appendingPathComponent("_CodeSignature/CodeResources"))
        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.stage(
                from: source,
                into: restore,
                expectedPlatformVersion: "26.4",
            )
        }
    }
}
