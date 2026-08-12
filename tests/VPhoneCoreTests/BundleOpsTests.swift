@testable import VPhoneCore
import Foundation
import Testing

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

    @Test func createsBundleWithSparseDiskAndManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }

        let spec = VPhoneBundleOps.NewBundleSpec(
            name: "newvm", cpuCount: 8, memoryMB: 8192, diskSizeGB: 64,
            romSource: rom, sepromSource: seprom)
        let bundle = try VPhoneBundleOps.create(spec, in: VPhoneLibrary(root: root))

        #expect(bundle.manifest.cpuCount == 8)
        #expect(bundle.manifest.memorySize == 8192 * 1024 * 1024)
        let disk = bundle.url.appendingPathComponent("Disk.img")
        let size = (try FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? NSNumber)?.int64Value
        #expect(size == Int64(64 * 1024 * 1024 * 1024))
        #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("SEPStorage").path))
        #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("AVPBooter.vresearch1.bin").path))
    }

    @Test func rejectsDuplicateName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let spec = VPhoneBundleOps.NewBundleSpec(
            name: "dup", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
            romSource: rom, sepromSource: seprom)
        _ = try VPhoneBundleOps.create(spec, in: VPhoneLibrary(root: root))
        #expect(throws: VPhoneLibraryError.self) {
            _ = try VPhoneBundleOps.create(spec, in: VPhoneLibrary(root: root))
        }
    }

    @Test func rejectsInvalidNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for bad in ["", "a/b", ".hidden"] {
            #expect(throws: VPhoneLibraryError.self) {
                _ = try VPhoneBundleOps.create(
                    .init(name: bad, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                          romSource: rom, sepromSource: seprom), in: lib)
            }
        }
    }

    @Test func rollsBackPartialBundleOnFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        // A non-existent ROM source makes copyItem fail AFTER the dir is created.
        let missingRom = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        #expect(throws: (any Error).self) {
            _ = try VPhoneBundleOps.create(
                .init(name: "partial", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                      romSource: missingRom, sepromSource: missingRom), in: lib)
        }
        // The half-built directory must be removed so the name is reusable.
        #expect(!FileManager.default.fileExists(atPath: lib.url(forName: "partial").path))
    }

    @Test func updateConfigPersistsFields() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "cfg", cpuCount: 8, memoryMB: 8192, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)

        let updated = try VPhoneBundleOps.updateConfig(
            bundleNamed: "cfg", in: lib, cpuCount: 4, memoryMB: nil)
        #expect(updated.manifest.cpuCount == 4)
        #expect(updated.manifest.memorySize == 8192 * 1024 * 1024)

        // Persisted: a fresh load sees the change.
        #expect(try lib.bundle(named: "cfg").manifest.cpuCount == 4)
        // Untouched network stays at the default.
        #expect(updated.manifest.networkConfig.mode == .nat)
    }

    @Test func updateConfigPersistsNetwork() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "net", cpuCount: 8, memoryMB: 8192, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)

        let updated = try VPhoneBundleOps.updateConfig(
            bundleNamed: "net", in: lib, cpuCount: nil, memoryMB: nil, networkMode: .off)
        #expect(updated.manifest.networkConfig.mode == .off)
        // Persisted across a fresh load, and cpu/memory untouched.
        let reloaded = try lib.bundle(named: "net").manifest
        #expect(reloaded.networkConfig.mode == .off)
        #expect(reloaded.cpuCount == 8)
    }

    @Test func updateConfigRejectsBadNetwork() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "bad", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)

        #expect(throws: VPhoneNetworkingError.hostOnlyUnsupported) {
            _ = try VPhoneBundleOps.updateConfig(
                bundleNamed: "bad", in: lib, cpuCount: nil, memoryMB: nil, networkMode: .hostOnly)
        }
        // A rejected edit must not have mutated the on-disk manifest.
        #expect(try lib.bundle(named: "bad").manifest.networkConfig.mode == .nat)
    }

    @Test func renameThenDelete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "old", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)

        let renamed = try VPhoneBundleOps.rename(bundleNamed: "old", to: "shiny", in: lib)
        #expect(renamed.name == "shiny")
        #expect(throws: VPhoneLibraryError.self) { _ = try lib.bundle(named: "old") }

        try VPhoneBundleOps.delete(bundleNamed: "shiny", in: lib)
        #expect(try lib.bundles().isEmpty)
    }

    @Test func renameRejectsExistingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for n in ["a", "b"] {
            _ = try VPhoneBundleOps.create(
                .init(name: n, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                      romSource: rom, sepromSource: seprom), in: lib)
        }
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "b")) {
            _ = try VPhoneBundleOps.rename(bundleNamed: "a", to: "b", in: lib)
        }
    }

    @Test func cloneCopiesBundleAndResetsIdentity() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        let src = try VPhoneBundleOps.create(
            .init(name: "src", cpuCount: 8, memoryMB: 4096, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)
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

    @Test func cloneRejectsExistingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for n in ["a", "b"] {
            _ = try VPhoneBundleOps.create(
                .init(name: n, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                      romSource: rom, sepromSource: seprom), in: lib)
        }
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "b")) {
            _ = try VPhoneBundleOps.clone(bundleNamed: "a", to: "b", in: lib)
        }
    }

    @Test func exportThenImportRoundTrips() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 8, memoryMB: 4096, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleOps.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        #expect(FileManager.default.fileExists(atPath: archive.path))

        // Import into a fresh library, renaming.
        let root2 = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root2) }
        let lib2 = VPhoneLibrary(root: root2)
        let imported = try VPhoneBundleOps.importArchive(from: archive, name: "copy", in: lib2)
        #expect(imported.name == "copy")
        #expect(imported.manifest.cpuCount == 8)
        #expect(imported.manifest.memorySize == 4096 * 1024 * 1024)
        #expect(try lib2.bundle(named: "copy").manifest.cpuCount == 8)
    }

    @Test func importRejectsExistingName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)
        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleOps.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        // Importing back under the same existing name must fail.
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "orig")) {
            _ = try VPhoneBundleOps.importArchive(from: archive, name: nil, in: lib)
        }
    }

    @Test func importWithRenameDoesNotClobberArchivedNameCollision() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        // Existing "orig" (cpu 16) that must NOT be touched by the import.
        _ = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 16, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)
        // Archive of a DIFFERENT "orig" (cpu 4) from a separate library.
        let root2 = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root2) }
        let lib2 = VPhoneLibrary(root: root2)
        _ = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 4, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib2)
        let archive = root2.appendingPathComponent("orig.tgz")
        try VPhoneBundleOps.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib2)

        let imported = try VPhoneBundleOps.importArchive(from: archive, name: "renamed", in: lib)
        #expect(imported.name == "renamed")
        #expect(imported.manifest.cpuCount == 4)
        #expect(try lib.bundle(named: "orig").manifest.cpuCount == 16)  // untouched
    }

    @Test func exportExcludesRestoreDirByDefault() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        let b = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)
        let restoreDir = b.url.appendingPathComponent("iPhone_Restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        try Data([0]).write(to: restoreDir.appendingPathComponent("marker"))

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleOps.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        let listing = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path])
        #expect(listing.succeeded)
        #expect(!listing.stdout.contains("iPhone_Restore"))
    }

    @Test func exportExcludesRegenerableStagingFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        let b = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)
        let fm = FileManager.default
        try Data([0]).write(to: b.url.appendingPathComponent(".vphoned.signed"))
        try fm.createDirectory(at: b.url.appendingPathComponent("cfw_input/jb"), withIntermediateDirectories: true)
        try Data([0]).write(to: b.url.appendingPathComponent("cfw_input/jb/f"))
        try fm.createDirectory(at: b.url.appendingPathComponent("cfw_jb_input"), withIntermediateDirectories: true)
        try Data([0]).write(to: b.url.appendingPathComponent("cfw_jb_input/f"))
        try fm.createDirectory(at: b.url.appendingPathComponent(".cfw_temp"), withIntermediateDirectories: true)
        try Data([0]).write(to: b.url.appendingPathComponent(".cfw_temp/f"))

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleOps.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        let listing = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path])
        #expect(listing.succeeded)
        #expect(!listing.stdout.contains(".vphoned.signed"))
        #expect(!listing.stdout.contains("cfw_input"))
        #expect(!listing.stdout.contains("cfw_jb_input"))
        #expect(!listing.stdout.contains(".cfw_temp"))
        // The real payload still travels.
        #expect(listing.stdout.contains("Disk.img"))
        #expect(listing.stdout.contains("config.plist"))
    }

    @Test func importRejectsMultiTopLevelArchive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // An archive with TWO top-level dirs is not a single bundle → badArchive.
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data([0]).write(to: src.appendingPathComponent("a/x"))
        try Data([0]).write(to: src.appendingPathComponent("b/y"))
        let archive = root.appendingPathComponent("multi.tgz")
        let made = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-czf", archive.path, "-C", src.path, "a", "b"])
        #expect(made.succeeded)

        #expect(throws: VPhoneBundleOpsError.self) {
            _ = try VPhoneBundleOps.importArchive(from: archive, name: nil, in: VPhoneLibrary(root: root))
        }
    }

    // MARK: - Compression presets

    private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    private static let xzMagic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]

    private func magic(_ url: URL, _ n: Int) throws -> [UInt8] {
        Array(try Data(contentsOf: url).prefix(n))
    }

    private func exportAndImport(
        _ compression: VPhoneBundleOps.ExportCompression?
    ) throws -> (archive: URL, imported: VPhoneBundle) {
        let root = try makeRoot()
        let rom = try fakeROM(); let seprom = try fakeROM()
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 6, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)
        let archive = root.appendingPathComponent("orig.archive")
        if let compression {
            try VPhoneBundleOps.export(
                bundleNamed: "orig", to: archive, includeIPSW: false, compression: compression, in: lib)
        } else {
            try VPhoneBundleOps.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        }
        let dstRoot = try makeRoot()
        let imported = try VPhoneBundleOps.importArchive(
            from: archive, name: "copy", in: VPhoneLibrary(root: dstRoot))
        return (archive, imported)
    }

    @Test func exportDefaultsToFastZstd() throws {
        let (archive, imported) = try exportAndImport(nil)
        #expect(try magic(archive, 4) == Self.zstdMagic)
        #expect(imported.manifest.cpuCount == 6)
    }

    @Test func exportFastProducesZstdAndRoundTrips() throws {
        let (archive, imported) = try exportAndImport(.fast)
        #expect(try magic(archive, 4) == Self.zstdMagic)
        #expect(imported.manifest.cpuCount == 6)
    }

    @Test func exportMaxProducesXzAndRoundTrips() throws {
        let (archive, imported) = try exportAndImport(.max)
        #expect(try magic(archive, 6) == Self.xzMagic)
        #expect(imported.manifest.cpuCount == 6)
    }

    @Test func exportToDirectoryAutoNamesWithExtension() throws {
        let root = try makeRoot()
        let rom = try fakeROM(); let seprom = try fakeROM()
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 6, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)
        let outDir = try makeRoot()
        let zstdOut = try VPhoneBundleOps.export(
            bundleNamed: "orig", to: outDir, includeIPSW: false, in: lib)
        #expect(zstdOut == outDir.appendingPathComponent("orig.tzst"))
        #expect(FileManager.default.fileExists(atPath: zstdOut.path))
        let xzOut = try VPhoneBundleOps.export(
            bundleNamed: "orig", to: outDir, includeIPSW: false, compression: .max, in: lib)
        #expect(xzOut == outDir.appendingPathComponent("orig.txz"))
        #expect(FileManager.default.fileExists(atPath: xzOut.path))
    }

    @Test func exportAndImportReportProgress() throws {
        final class Collector {
            private(set) var dones: [Int64] = []
            private(set) var total: Int64 = 0
            func add(_ done: Int64, _ total: Int64) { dones.append(done); self.total = total }
        }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(
            .init(name: "orig", cpuCount: 6, memoryMB: 2048, diskSizeGB: 1,
                  romSource: rom, sepromSource: seprom), in: lib)

        let exp = Collector()
        let archive = root.appendingPathComponent("orig.tzst")
        try VPhoneBundleOps.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib) {
            exp.add($0, $1)
        }
        #expect(!exp.dones.isEmpty)
        #expect(exp.total > 0)                                   // bundle logical size
        #expect(exp.dones.last! > 0)
        #expect(exp.dones == exp.dones.sorted())                 // monotonically non-decreasing

        let imp = Collector()
        let dstRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dstRoot) }
        _ = try VPhoneBundleOps.importArchive(from: archive, name: "copy", in: VPhoneLibrary(root: dstRoot)) {
            imp.add($0, $1)
        }
        let archiveSize = try Data(contentsOf: archive).count
        #expect(!imp.dones.isEmpty)
        #expect(imp.total == Int64(archiveSize))                 // total == compressed file size
        #expect(imp.dones.last! == Int64(archiveSize))           // whole archive fed
        #expect(imp.dones == imp.dones.sorted())
    }

    @Test func compressionPresetTarArgs() {
        #expect(VPhoneBundleOps.ExportCompression.fast.tarArgs
            == ["--zstd", "--options", "zstd:compression-level=3,zstd:threads=0"])
        #expect(VPhoneBundleOps.ExportCompression.max.tarArgs
            == ["-J", "--options", "xz:compression-level=9,xz:threads=0"])
    }
}
