@testable import VPhoneCore
import Foundation
import Testing

struct PCCGPUDriverTests {
    @Test func selectsVphone600OSImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-gpu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let identities: [[String: Any]] = [
            identity(device: "vresearch101ap", os: "wrong.dmg.aea"),
            identity(device: "vphone600ap", os: "PCC-OS.dmg.aea"),
        ]
        let manifest = try PropertyListSerialization.data(
            fromPropertyList: ["BuildIdentities": identities], format: .binary, options: 0
        )
        try manifest.write(to: directory.appendingPathComponent("BuildManifest.plist"))

        #expect(try VPhonePCCGPUDriver.osImage(in: directory)
            == directory.appendingPathComponent("PCC-OS.dmg.aea"))
        #expect(VPhonePCCGPUDriver.stagedBundle(in: directory)
            == directory.appending(path: ".pcc-gpu/AppleParavirtGPUMetalIOGPUFamily.bundle"))
    }

    @Test func refusesPathOutsidePCCDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-gpu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try PropertyListSerialization.data(
            fromPropertyList: ["BuildIdentities": [identity(device: "vphone600ap", os: "../outside.dmg")]],
            format: .binary, options: 0
        )
        try manifest.write(to: directory.appendingPathComponent("BuildManifest.plist"))

        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.osImage(in: directory)
        }
    }

    private func identity(device: String, os: String) -> [String: Any] {
        ["Info": ["DeviceClass": device],
         "Manifest": ["OS": ["Info": ["Path": os]]]]
    }
}
