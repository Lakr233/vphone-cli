import Foundation
import Testing
@testable import VPhoneCore

struct PCCGPUDriverTests {
    @Test func `selects vphone 600 OS image`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-gpu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let identities: [[String: Any]] = [
            identity(device: "vresearch101ap", os: "wrong.dmg.aea"),
            identity(device: "vphone600ap", os: "PCC-OS.dmg.aea"),
        ]
        let manifest = try PropertyListSerialization.data(
            fromPropertyList: ["BuildIdentities": identities], format: .binary, options: 0,
        )
        try manifest.write(to: directory.appendingPathComponent("BuildManifest.plist"))

        #expect(try VPhonePCCGPUDriver.osImage(in: directory)
            == directory.appendingPathComponent("PCC-OS.dmg.aea"))
        #expect(VPhonePCCGPUDriver.stagedBundle(in: directory)
            == directory.appending(path: ".pcc-gpu/AppleParavirtGPUMetalIOGPUFamily.bundle"))
    }

    @Test func `refuses path outside PCC directory`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-gpu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try PropertyListSerialization.data(
            fromPropertyList: ["BuildIdentities": [identity(device: "vphone600ap", os: "../outside.dmg")]],
            format: .binary, options: 0,
        )
        try manifest.write(to: directory.appendingPathComponent("BuildManifest.plist"))

        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.osImage(in: directory)
        }
    }

    @Test func `stages a validated local bundle without an AEA key request`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-gpu-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(VPhonePCCGPUDriver.name)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true,
        )
        for file in ["AppleParavirtGPUMetalIOGPUFamily",
                     "libAppleParavirtCompilerPluginIOGPUFamily.dylib",
                     "_CodeSignature/CodeResources"]
        {
            try Data(file.utf8).write(to: source.appendingPathComponent(file))
        }
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier":
                "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily"],
            format: .binary, options: 0,
        )
        try info.write(to: source.appendingPathComponent("Info.plist"))

        let restore = root.appendingPathComponent("restore")
        try VPhonePCCGPUDriver.stage(
            from: root.appendingPathComponent("missing-cloudos"),
            into: restore,
            cachedBundle: source,
        )
        let staged = VPhonePCCGPUDriver.stagedBundle(in: restore)
        #expect(try Data(contentsOf: staged.appendingPathComponent("AppleParavirtGPUMetalIOGPUFamily"))
            == Data("AppleParavirtGPUMetalIOGPUFamily".utf8))

        try FileManager.default.removeItem(at: source.appendingPathComponent("_CodeSignature/CodeResources"))
        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.stage(from: root, into: restore, cachedBundle: source)
        }
    }

    private func identity(device: String, os: String) -> [String: Any] {
        ["Info": ["DeviceClass": device],
         "Manifest": ["OS": ["Info": ["Path": os]]]]
    }
}
