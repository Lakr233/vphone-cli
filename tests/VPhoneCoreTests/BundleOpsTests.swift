import Foundation
import Testing
@testable import VPhoneCore

/// Creating, editing, renaming and cloning a bundle. Export and import moved to
/// `VPhoneArchiveTests/BundleTransferTests` with the implementation, which needs
/// libarchive; this half does not.
struct BundleOpsTests {
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fakeROM() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data([0xAA, 0xBB, 0xCC]).write(to: f)
        return f
    }

    @Test func `creates bundle with sparse disk and manifest`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }

        let spec = VPhoneBundleOps.NewBundleSpec(
            name: "newvm",
            cpuCount: 8,
            memoryMB: 8192,
            diskSizeGB: 64,
            romSource: rom,
            sepromSource: seprom,
        )
        let bundle = try VPhoneBundleOps.create(spec, in: VPhoneLibrary(root: root))

        #expect(bundle.manifest.cpuCount == 8)
        #expect(bundle.manifest.memorySize == 8192 * 1024 * 1024)
        let disk = bundle.url.appendingPathComponent("Disk.img")
        let size = try (FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? NSNumber)?.int64Value
        #expect(size == Int64(64 * 1024 * 1024 * 1024))
        #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("SEPStorage").path))
        #expect(
            FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("AVPBooter.vresearch1.bin").path),
        )
    }

    @Test func `rejects duplicate name`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let spec = VPhoneBundleOps.NewBundleSpec(
            name: "dup",
            cpuCount: 2,
            memoryMB: 2048,
            diskSizeGB: 1,
            romSource: rom,
            sepromSource: seprom,
        )
        _ = try VPhoneBundleOps.create(spec, in: VPhoneLibrary(root: root))
        #expect(throws: VPhoneLibraryError.self) {
            _ = try VPhoneBundleOps.create(spec, in: VPhoneLibrary(root: root))
        }
    }

    @Test func `rejects invalid names`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for bad in ["", "a/b", ".hidden"] {
            #expect(throws: VPhoneLibraryError.self) {
                _ = try VPhoneBundleOps.create(
                    .init(
                        name: bad,
                        cpuCount: 2,
                        memoryMB: 2048,
                        diskSizeGB: 1,
                        romSource: rom,
                        sepromSource: seprom,
                    ),
                    in: lib,
                )
            }
        }
    }

    @Test func `rolls back partial bundle on failure`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        // A non-existent ROM source makes copyItem fail AFTER the dir is created.
        let missingRom = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        #expect(throws: (any Error).self) {
            _ = try VPhoneBundleOps.create(
                .init(
                    name: "partial",
                    cpuCount: 2,
                    memoryMB: 2048,
                    diskSizeGB: 1,
                    romSource: missingRom,
                    sepromSource: missingRom,
                ),
                in: lib,
            )
        }
        // The half-built directory must be removed so the name is reusable.
        #expect(!FileManager.default.fileExists(atPath: lib.url(forName: "partial").path))
    }

    @Test func `update config persists fields`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(
                name: "cfg",
                cpuCount: 8,
                memoryMB: 8192,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        let updated = try VPhoneBundleOps.updateConfig(bundleNamed: "cfg", in: lib, cpuCount: 4, memoryMB: nil)
        #expect(updated.manifest.cpuCount == 4)
        #expect(updated.manifest.memorySize == 8192 * 1024 * 1024)

        // Persisted: a fresh load sees the change.
        #expect(try lib.bundle(named: "cfg").manifest.cpuCount == 4)
        // Untouched network stays at the default.
        #expect(updated.manifest.networkConfig.mode == .nat)
    }

    @Test func `update config persists network`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(
                name: "net",
                cpuCount: 8,
                memoryMB: 8192,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        let updated = try VPhoneBundleOps.updateConfig(
            bundleNamed: "net",
            in: lib,
            cpuCount: nil,
            memoryMB: nil,
            networkMode: .off,
        )
        #expect(updated.manifest.networkConfig.mode == .off)
        // Persisted across a fresh load, and cpu/memory untouched.
        let reloaded = try lib.bundle(named: "net").manifest
        #expect(reloaded.networkConfig.mode == .off)
        #expect(reloaded.cpuCount == 8)
    }

    @Test func `update config rejects bad network`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(
                name: "bad",
                cpuCount: 2,
                memoryMB: 2048,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        #expect(throws: VPhoneNetworkingError.hostOnlyUnsupported) {
            _ = try VPhoneBundleOps.updateConfig(
                bundleNamed: "bad",
                in: lib,
                cpuCount: nil,
                memoryMB: nil,
                networkMode: .hostOnly,
            )
        }
        // A rejected edit must not have mutated the on-disk manifest.
        #expect(try lib.bundle(named: "bad").manifest.networkConfig.mode == .nat)
    }

    @Test func `rename then delete`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(
                name: "old",
                cpuCount: 2,
                memoryMB: 2048,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        let renamed = try VPhoneBundleOps.rename(bundleNamed: "old", to: "shiny", in: lib)
        #expect(renamed.name == "shiny")
        #expect(throws: VPhoneLibraryError.self) { _ = try lib.bundle(named: "old") }

        try VPhoneBundleOps.delete(bundleNamed: "shiny", in: lib)
        #expect(try lib.bundles().isEmpty)
    }

    @Test func `rename rejects existing target`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for n in ["a", "b"] {
            _ = try VPhoneBundleOps.create(
                .init(
                    name: n,
                    cpuCount: 2,
                    memoryMB: 2048,
                    diskSizeGB: 1,
                    romSource: rom,
                    sepromSource: seprom,
                ),
                in: lib,
            )
        }
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "b")) {
            _ = try VPhoneBundleOps.rename(bundleNamed: "a", to: "b", in: lib)
        }
    }

    @Test func `clone copies bundle and resets identity`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        let src = try VPhoneBundleOps.create(
            .init(
                name: "src",
                cpuCount: 8,
                memoryMB: 4096,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )
        // Simulate a booted/restored VM: identity artifacts present + non-empty machineIdentifier.
        let fm = FileManager.default
        try Data([1, 2, 3]).write(to: src.url.appendingPathComponent("nvram.bin"))
        try Data([4]).write(to: src.url.appendingPathComponent("udid-prediction.txt"))
        try Data([5]).write(to: src.url.appendingPathComponent("ABC123.shsh"))
        let withID = src.manifest.updating(machineIdentifier: Data([9, 9]))
        try withID.write(to: src.configURL)

        let clone = try VPhoneBundleOps.clone(bundleNamed: "src", to: "dst", in: lib)

        // Copy happened (disk + ROMs present in the clone).
        #expect(fm.fileExists(atPath: clone.url.appendingPathComponent("Disk.img").path))
        #expect(fm.fileExists(atPath: clone.url.appendingPathComponent("AVPBooter.vresearch1.bin").path))
        // Identity artifacts cleared in the clone.
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("nvram.bin").path))
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("udid-prediction.txt").path))
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("ABC123.shsh").path))
        #expect(clone.manifest.machineIdentifier.isEmpty)
        // Original untouched.
        #expect(fm.fileExists(atPath: src.url.appendingPathComponent("nvram.bin").path))
        #expect(try lib.bundle(named: "src").manifest.machineIdentifier == Data([9, 9]))
    }

    @Test func `clone rejects existing target`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for n in ["a", "b"] {
            _ = try VPhoneBundleOps.create(
                .init(
                    name: n,
                    cpuCount: 2,
                    memoryMB: 2048,
                    diskSizeGB: 1,
                    romSource: rom,
                    sepromSource: seprom,
                ),
                in: lib,
            )
        }
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "b")) {
            _ = try VPhoneBundleOps.clone(bundleNamed: "a", to: "b", in: lib)
        }
    }
}
