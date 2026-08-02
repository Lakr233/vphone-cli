@testable import VPhoneCore
import Foundation
import Testing

struct ManifestTests {
    private func sampleManifest() -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            cpuCount: 8,
            memorySize: 8 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "AVPBooter.vresearch1.bin",
                             avpSEPBooter: "AVPSEPBooter.vresearch1.bin")
        )
    }

    @Test func roundTripsThroughPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(loaded.cpuCount == 8)
        #expect(loaded.memorySize == 8 * 1024 * 1024 * 1024)
        #expect(loaded.romImages?.avpBooter == "AVPBooter.vresearch1.bin")
    }

    @Test func updatingReplacesOnlyGivenFields() {
        let updated = sampleManifest().updating(cpuCount: 4, memorySize: nil, screenConfig: nil)
        #expect(updated.cpuCount == 4)
        #expect(updated.memorySize == 8 * 1024 * 1024 * 1024)
        // networkConfig is preserved when not passed.
        #expect(updated.networkConfig.mode == .nat)
    }

    @Test func networkConfigRoundTripsThroughPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let net = VPhoneVirtualMachineManifest.NetworkConfig(
            mode: .bridged, macAddress: "", bridgeInterface: "en0")
        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().updating(networkConfig: net).write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(loaded.networkConfig.mode == .bridged)
        #expect(loaded.networkConfig.bridgeInterface == "en0")
    }

    // Manifests written before bridgeInterface existed omit that key; they must
    // still decode, with bridgeInterface defaulting to nil.
    @Test func decodesManifestWithoutBridgeInterfaceKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url)  // default network → bridgeInterface nil
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("bridgeInterface"))  // nil optional is omitted from the plist

        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.networkConfig.bridgeInterface == nil)
    }
}
