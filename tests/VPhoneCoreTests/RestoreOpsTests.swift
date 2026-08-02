@testable import VPhoneCore
import Foundation
import Testing

struct RestoreOpsTests {
    private func bundle(in root: URL) throws -> VPhoneBundle {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 1024 * 1024, romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        return VPhoneBundle(url: root, manifest: manifest)
    }

    @Test func resolveECIDPrefersExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        #expect(VPhoneRestoreOps.resolveECID(explicit: "0xABCD", bundle: b) == "0xABCD")
    }

    @Test func resolveECIDFromPredictionFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        try "UDID=AAAA-1122334455667788\nECID=1122334455667788\n"
            .write(to: root.appendingPathComponent("udid-prediction.txt"), atomically: true, encoding: .utf8)
        #expect(VPhoneRestoreOps.resolveECID(explicit: nil, bundle: b) == "1122334455667788")
    }

    @Test func resolveECIDNilWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        #expect(VPhoneRestoreOps.resolveECID(explicit: nil, bundle: b) == nil)
    }

    @Test func resolveUDIDFromPredictionFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        try "UDID=AAAABBBB-1122334455667788\nECID=1122334455667788\n"
            .write(to: root.appendingPathComponent("udid-prediction.txt"), atomically: true, encoding: .utf8)
        #expect(VPhoneRestoreOps.resolveUDID(bundle: b) == "AAAABBBB-1122334455667788")
    }

    @Test func resolveUDIDNilWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        #expect(VPhoneRestoreOps.resolveUDID(bundle: b) == nil)
    }

    @Test func isAEAEncryptedDetectsMagic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let enc = dir.appendingPathComponent("a.aea")
        try (Data([0x41, 0x45, 0x41, 0x31]) + Data([0, 1, 2])).write(to: enc)
        let plain = dir.appendingPathComponent("b.dmg")
        try Data([0, 0, 0, 0, 9]).write(to: plain)
        #expect(try VPhoneRestoreOps.isAEAEncrypted(enc) == true)
        #expect(try VPhoneRestoreOps.isAEAEncrypted(plain) == false)
    }
}
