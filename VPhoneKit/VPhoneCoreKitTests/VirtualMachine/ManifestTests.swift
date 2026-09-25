import Foundation
import Testing
@testable import VPhoneCoreKit

struct ManifestTests {
    private func sampleManifest() -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            cpuCount: 8,
            memorySize: 8 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "AVPBooter.vresearch1.bin", avpSEPBooter: "AVPSEPBooter.vresearch1.bin"),
        )
    }

    @Test func `round trips through plist`() throws {
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

    @Test func `updating replaces only given fields`() {
        let updated = sampleManifest().updating(cpuCount: 4, memorySize: nil)
        #expect(updated.cpuCount == 4)
        #expect(updated.memorySize == 8 * 1024 * 1024 * 1024)
        // networkConfig is preserved when not passed.
        #expect(updated.networkConfig.mode == .nat)
    }

    @Test func `network config round trips through plist`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let net = VPhoneVirtualMachineManifest.NetworkConfig(mode: .bridged, macAddress: "", bridgeInterface: "en0")
        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().updating(networkConfig: net).write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(loaded.networkConfig.mode == .bridged)
        #expect(loaded.networkConfig.bridgeInterface == "en0")
    }

    /// Manifests written before bridgeInterface existed omit that key; they must
    /// still decode, with bridgeInterface defaulting to nil.
    @Test func `decodes manifest without bridge interface key`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url) // default network → bridgeInterface nil
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("bridgeInterface")) // nil optional is omitted from the plist

        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.networkConfig.bridgeInterface == nil)
    }

    // MARK: - File names

    /// Writes the sample manifest, then sets one file-name field (a top-level
    /// key, or `romImages.<key>`) to `value` in the raw plist.
    private func writeManifest(setting field: String, to value: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url)
        var plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil,
        ) as? [String: Any])
        if field.hasPrefix("romImages.") {
            var roms = try #require(plist["romImages"] as? [String: Any])
            roms[String(field.dropFirst("romImages.".count))] = value
            plist["romImages"] = roms
        } else {
            plist[field] = value
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    /// An imported config.plist is untrusted: vphone-vm overwrites the NVRAM
    /// file and attaches the disk read-write, so every file name must stay
    /// directly inside the VM folder.
    @Test(arguments: ["diskImage", "nvramStorage", "sepStorage", "romImages.avpBooter", "romImages.avpSEPBooter"])
    func `file names that leave the bundle fail to load`(field: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for value in ["../x", "/abs", "a/b", "..", ".", ""] {
            let url = try writeManifest(setting: field, to: value, in: dir)
            do {
                _ = try VPhoneVirtualMachineManifest.load(from: url)
                Issue.record("\(field) = \"\(value)\" was accepted")
            } catch let error as VPhoneManifestError {
                guard case let .invalidPath(_, reported) = error else {
                    Issue.record("Expected an invalid path error for \(field), got \(error)")
                    continue
                }
                #expect(reported == field)
            }
        }
    }

    @Test func `default file names load`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try VPhoneVirtualMachineManifest.newVM().write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.diskImage == "Disk.img")
        #expect(try loaded.resolve(path: loaded.nvramStorage, in: dir) == dir.appendingPathComponent("nvram.bin"))
        #expect(throws: VPhoneManifestError.self) {
            _ = try loaded.resolve(path: "../nvram.bin", in: dir)
        }
    }

    @Test func `plain file name rule`() {
        #expect(VPhoneVirtualMachineManifest.isPlainFileName("Disk.img"))
        #expect(VPhoneVirtualMachineManifest.isPlainFileName("..hidden"))
        #expect(!VPhoneVirtualMachineManifest.isPlainFileName("a\u{0}b"))
        #expect(!VPhoneVirtualMachineManifest.isPlainFileName(String(repeating: "x", count: 256)))
    }

    /// write(to:) is atomic, so a config.plist that is a symbolic link is
    /// replaced rather than written through.
    @Test func `write replaces a symbolic link`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = dir.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        let url = dir.appendingPathComponent("config.plist")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)

        try sampleManifest().write(to: url)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        #expect(VPhoneVirtualMachineManifest.fileKind(at: url) == .regularFile)
    }
}
