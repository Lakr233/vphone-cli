import Foundation
import Testing
@testable import VPhoneCoreKit

struct RestoreOperationsTests {
    private func bundle(in root: URL) throws -> VPhoneBundle {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        return VPhoneBundle(url: root, manifest: manifest)
    }

    @Test func `resolve ECID prefers explicit`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        #expect(VPhoneRestoreOperations.resolveECID(explicit: "0xABCD", bundle: b) == "0xABCD")
    }

    @Test func `resolve ECID from prediction file`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        try "UDID=AAAA-1122334455667788\nECID=1122334455667788\n"
            .write(to: root.appendingPathComponent("udid-prediction.txt"), atomically: true, encoding: .utf8)
        #expect(VPhoneRestoreOperations.resolveECID(explicit: nil, bundle: b) == "1122334455667788")
    }

    @Test func `resolve ECID nil when missing`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        #expect(VPhoneRestoreOperations.resolveECID(explicit: nil, bundle: b) == nil)
    }

    @Test func `resolve UDID from prediction file`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        try "UDID=AAAABBBB-1122334455667788\nECID=1122334455667788\n"
            .write(to: root.appendingPathComponent("udid-prediction.txt"), atomically: true, encoding: .utf8)
        #expect(VPhoneRestoreOperations.resolveUDID(bundle: b) == "AAAABBBB-1122334455667788")
    }

    @Test func `resolve UDID nil when missing`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try bundle(in: root)
        #expect(VPhoneRestoreOperations.resolveUDID(bundle: b) == nil)
    }

    @Test func `is AEA encrypted detects magic`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let enc = dir.appendingPathComponent("a.aea")
        try (Data([0x41, 0x45, 0x41, 0x31]) + Data([0, 1, 2])).write(to: enc)
        let plain = dir.appendingPathComponent("b.dmg")
        try Data([0, 0, 0, 0, 9]).write(to: plain)
        #expect(try VPhoneRestoreOperations.isAEAEncrypted(enc) == true)
        #expect(try VPhoneRestoreOperations.isAEAEncrypted(plain) == false)
    }
}
