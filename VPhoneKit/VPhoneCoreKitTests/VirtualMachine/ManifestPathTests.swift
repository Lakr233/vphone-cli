import Foundation
import Testing
@testable import VPhoneCoreKit

struct ManifestPathTests {
    private func makeBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifest(disk: String = "Disk.img") -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(cpuCount: 1, memorySize: 1, diskImage: disk, romImages: .default)
    }

    @Test func `plain relative paths resolve inside the bundle`() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try manifest().resolve(path: "sub/Disk.img", in: dir)
        #expect(url.lastPathComponent == "Disk.img")
        #expect(url.path.hasSuffix("/sub/Disk.img"))
    }

    @Test(arguments: ["", "/etc/passwd", "../Disk.img", "a/../../b", "./Disk.img", "/"])
    func `lexically unsafe paths are rejected`(path: String) throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: VPhoneManifestError.self) { try manifest().resolve(path: path, in: dir) }
    }

    @Test func `symlinked components are rejected, broken links included`() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("out").path, withDestinationPath: "/tmp")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("dead").path, withDestinationPath: "/nonexistent/x")
        #expect(throws: VPhoneManifestError.self) { try manifest().resolve(path: "out/Disk.img", in: dir) }
        #expect(throws: VPhoneManifestError.self) { try manifest().resolve(path: "dead", in: dir) }
    }

    @Test func `write and load reject an unsafe path field`() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.plist")
        #expect(throws: VPhoneManifestError.self) { try manifest(disk: "../Disk.img").write(to: url) }

        let data = try PropertyListEncoder().encode(manifest(disk: "/etc/passwd"))
        try data.write(to: url)
        #expect(throws: VPhoneManifestError.self) { try VPhoneVirtualMachineManifest.load(from: url) }
    }
}
