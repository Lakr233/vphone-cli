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
    }
}
