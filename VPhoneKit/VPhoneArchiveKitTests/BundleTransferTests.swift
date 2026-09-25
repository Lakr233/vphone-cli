import Foundation
import Testing
@testable import VPhoneArchiveKit
import VPhoneCoreKit

/// `vm export` / `vm import`, moved here with the implementation when they came
/// off the two-stage `tar` pipe. The format contract they pin — gnutar, one
/// top-level directory, `.tzst` at zstd 3, `.txz` at xz 9, the extension chosen
/// from the preset — is the reason these tests came along unchanged: archives
/// in those shapes are already on people's disks.
///
/// `.serialized` for the same reason as `RoundTripTests`: libarchive leaves
/// `tar.XXXXXXXX` temp files in the process's working directory when several
/// extractions run at once.
@Suite("VM bundle export and import", .serialized)
struct BundleTransferTests {
    // MARK: - Fixtures

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

    @discardableResult
    private func makeBundle(
        _ name: String,
        cpuCount: UInt = 2,
        in library: VPhoneLibrary,
    ) throws -> VPhoneBundle {
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer {
            try? FileManager.default.removeItem(at: rom)
            try? FileManager.default.removeItem(at: seprom)
        }
        return try VPhoneBundleOperations.create(
            .init(
                name: name,
                cpuCount: cpuCount,
                memoryMB: 2048,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: library,
        )
    }

    private func systemTar(_ args: [String]) throws -> VPhoneProcessResult {
        try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/tar"), args)
    }

    // MARK: - Round trip

    @Test func `export then import round trips`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("orig", cpuCount: 8, in: lib)

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        #expect(FileManager.default.fileExists(atPath: archive.path))

        // Import into a fresh library, renaming.
        let root2 = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root2) }
        let lib2 = VPhoneLibrary(root: root2)
        let imported = try VPhoneBundleTransfer.importArchive(from: archive, name: "copy", in: lib2)
        #expect(imported.name == "copy")
        #expect(imported.manifest.cpuCount == 8)
        #expect(imported.manifest.memorySize == 2048 * 1024 * 1024)
        #expect(try lib2.bundle(named: "copy").manifest.cpuCount == 8)
    }

    @Test func `import rejects existing name`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("orig", in: lib)
        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        // Importing back under the same existing name must fail.
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "orig")) {
            _ = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib)
        }
    }

    @Test func `import with rename does not clobber archived name collision`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        // Existing "orig" (cpu 16) that must NOT be touched by the import.
        try makeBundle("orig", cpuCount: 16, in: lib)

        // Archive of a DIFFERENT "orig" (cpu 4) from a separate library.
        let root2 = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root2) }
        let lib2 = VPhoneLibrary(root: root2)
        try makeBundle("orig", cpuCount: 4, in: lib2)
        let archive = root2.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib2)

        let imported = try VPhoneBundleTransfer.importArchive(from: archive, name: "renamed", in: lib)
        #expect(imported.name == "renamed")
        #expect(imported.manifest.cpuCount == 4)
        #expect(try lib.bundle(named: "orig").manifest.cpuCount == 16) // untouched
    }

    // MARK: - Exclusions

    @Test func `export excludes restore dir by default`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let b = try makeBundle("orig", in: lib)
        let restoreDir = b.url.appendingPathComponent("iPhone_Restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        try Data([0]).write(to: restoreDir.appendingPathComponent("marker"))

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        let members = try VPhoneArchiveReader.entries(of: archive).map(\.path)
        #expect(!members.contains { $0.contains("iPhone_Restore") })
    }

    @Test func `export includes restore dir when asked`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let b = try makeBundle("orig", in: lib)
        let restoreDir = b.url.appendingPathComponent("iPhone_Restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        try Data([0]).write(to: restoreDir.appendingPathComponent("marker"))

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: true, in: lib)
        let members = try VPhoneArchiveReader.entries(of: archive).map(\.path)
        #expect(members.contains("orig/iPhone_Restore/marker"))
    }

    @Test func `export excludes regenerable staging files`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let b = try makeBundle("orig", in: lib)
        try Data([0]).write(to: b.url.appendingPathComponent(".vphoned.signed"))

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        let members = try VPhoneArchiveReader.entries(of: archive).map(\.path)
        #expect(!members.contains { $0.contains(".vphoned.signed") })
        // The real payload still travels.
        #expect(members.contains("orig/Disk.img"))
        #expect(members.contains("orig/config.plist"))
    }

    // MARK: - Malformed input

    @Test func `import rejects multi top level archive`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // An archive with TWO top-level dirs is not a single bundle → badArchive.
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data([0]).write(to: src.appendingPathComponent("a/x"))
        try Data([0]).write(to: src.appendingPathComponent("b/y"))
        let archive = root.appendingPathComponent("multi.tgz")
        try VPhoneArchiveWriter.create(archive: archive, from: src, compression: .gzip(level: 1))

        #expect(throws: VPhoneBundleTransferError.self) {
            _ = try VPhoneBundleTransfer.importArchive(
                from: archive,
                name: nil,
                in: VPhoneLibrary(root: root.appendingPathComponent("library")),
            )
        }
    }

    @Test func `import rejects invalid manifest without reserving name`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let bundleDir = root.appendingPathComponent("original")
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let config = bundleDir.appendingPathComponent("config.plist")
        try "not a plist".write(to: config, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("vm.tgz")
        let lib = VPhoneLibrary(root: root.appendingPathComponent("library"))

        func pack() throws {
            try? fm.removeItem(at: archive)
            try VPhoneArchiveWriter.create(
                archive: archive,
                from: bundleDir,
                topLevel: "original",
                compression: .gzip(level: 1),
            )
        }
        try pack()
        #expect(throws: VPhoneManifestError.self) {
            _ = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib)
        }
        // Neither a destination bundle nor a hidden staging directory may remain.
        #expect(try fm.contentsOfDirectory(atPath: lib.root.path).isEmpty)

        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 2048 * 1024 * 1024,
            romImages: nil,
        )
        try manifest.write(to: config)
        try pack()
        let imported = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib)
        #expect(imported.url == lib.url(forName: "original"))
        #expect(try lib.bundle(named: "original").manifest.cpuCount == 2)
    }

    // MARK: - Links and file names from someone else's export

    /// vphone-vm overwrites nvram.bin, attaches Disk.img read-write and
    /// rewrites config.plist, so a link from any of them to a host file would
    /// let an archive write outside its bundle.
    @Test(arguments: ["nvram.bin", "config.plist", "Disk.img"])
    func `import rejects a bundle file linked to an absolute path`(member: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let lib = VPhoneLibrary(root: root.appendingPathComponent("source"))
        let bundle = try makeBundle("orig", in: lib)
        let file = bundle.url.appendingPathComponent(member)
        let outside = root.appendingPathComponent("outside-\(member)")
        if fm.fileExists(atPath: file.path) {
            try fm.moveItem(at: file, to: outside)
        } else {
            try Data("host file".utf8).write(to: outside)
        }
        try fm.createSymbolicLink(atPath: file.path, withDestinationPath: outside.path)

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)

        let lib2 = VPhoneLibrary(root: root.appendingPathComponent("library"))
        #expect(throws: VPhoneBundleTransferError.self) {
            _ = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib2)
        }
        #expect(try fm.contentsOfDirectory(atPath: lib2.root.path).isEmpty)
    }

    @Test func `import rejects a top level symbolic link`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // A real bundle elsewhere on this Mac that the archive's only entry
        // points at; following the link would make the import look valid.
        let elsewhere = VPhoneLibrary(root: root.appendingPathComponent("elsewhere"))
        let target = try makeBundle("target", in: elsewhere)
        let src = root.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: src.appendingPathComponent("vm").path,
            withDestinationPath: target.url.path,
        )
        let archive = root.appendingPathComponent("link.tgz")
        try VPhoneArchiveWriter.create(archive: archive, from: src, compression: .gzip(level: 1))
        let members = try VPhoneArchiveReader.entries(of: archive)
        #expect(members.map(\.path) == ["vm"])
        #expect(members.first?.isSymlink == true)

        let lib = VPhoneLibrary(root: root.appendingPathComponent("library"))
        #expect(throws: VPhoneBundleTransferError.self) {
            _ = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib)
        }
        #expect(try fm.contentsOfDirectory(atPath: lib.root.path).isEmpty)
    }

    @Test func `import keeps relative links inside the bundle and rejects escaping ones`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let lib = VPhoneLibrary(root: root.appendingPathComponent("source"))
        let bundle = try makeBundle("orig", in: lib)
        let restoreDir = bundle.url.appendingPathComponent("iPhone_Restore")
        try fm.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        try Data([0]).write(to: restoreDir.appendingPathComponent("marker"))
        try fm.createSymbolicLink(
            atPath: restoreDir.appendingPathComponent("sibling").path,
            withDestinationPath: "marker",
        )
        try fm.createSymbolicLink(
            atPath: restoreDir.appendingPathComponent("parent").path,
            withDestinationPath: "../config.plist",
        )

        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: true, in: lib)
        let lib2 = VPhoneLibrary(root: root.appendingPathComponent("library"))
        let imported = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib2)
        let importedRestore = imported.url.appendingPathComponent("iPhone_Restore")
        #expect(try fm.destinationOfSymbolicLink(atPath: importedRestore.appendingPathComponent("sibling").path)
            == "marker")

        for escaping in ["../../outside", "/etc/hosts", "marker/../../../outside"] {
            let link = restoreDir.appendingPathComponent("escape")
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: escaping)
            try? fm.removeItem(at: archive)
            try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: true, in: lib)
            let lib3 = VPhoneLibrary(root: root.appendingPathComponent("library-\(UUID().uuidString)"))
            #expect(throws: VPhoneBundleTransferError.self) {
                _ = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib3)
            }
        }
    }

    @Test func `import rejects a manifest file name outside the bundle`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let lib = VPhoneLibrary(root: root.appendingPathComponent("source"))
        let bundle = try makeBundle("orig", in: lib)
        var plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundle.configURL),
            format: nil,
        ) as? [String: Any])
        plist["nvramStorage"] = "../x"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.configURL)

        // Packed directly: `vm export` itself loads the manifest and would refuse it.
        let archive = root.appendingPathComponent("orig.tgz")
        try VPhoneArchiveWriter.create(
            archive: archive,
            from: bundle.url,
            topLevel: "orig",
            compression: .gzip(level: 1),
        )
        let lib2 = VPhoneLibrary(root: root.appendingPathComponent("library"))
        #expect(throws: VPhoneManifestError.self) {
            _ = try VPhoneBundleTransfer.importArchive(from: archive, name: nil, in: lib2)
        }
        #expect(try fm.contentsOfDirectory(atPath: lib2.root.path).isEmpty)
    }

    // MARK: - Compression presets

    private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    private static let xzMagic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]

    private func magic(_ url: URL, _ n: Int) throws -> [UInt8] {
        try Array(Data(contentsOf: url).prefix(n))
    }

    /// Takes a body rather than returning the pair, because it makes two
    /// temporary libraries and has to outlive neither.
    ///
    /// It used to `return (archive, imported)`, which meant neither root could
    /// be removed here — and none of the three callers removed them either. Each
    /// holds a 1 GiB `Disk.img`, so every `swift test` left six of them in
    /// `FileManager.temporaryDirectory` for good: the directory had reached
    /// 383 GB and filled the volume. Every other test in this file and in
    /// `BundleOpsTests` already paired `makeRoot()` with a `defer`; this helper
    /// was the one place that could not.
    private func withExportAndImport(
        _ compression: VPhoneBundleTransfer.ExportCompression?,
        _ body: (_ archive: URL, _ imported: VPhoneBundle) throws -> Void,
    ) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("orig", cpuCount: 6, in: lib)
        let archive = root.appendingPathComponent("orig.archive")
        if let compression {
            try VPhoneBundleTransfer.export(
                bundleNamed: "orig",
                to: archive,
                includeIPSW: false,
                compression: compression,
                in: lib,
            )
        } else {
            try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        }
        let dstRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dstRoot) }
        let imported = try VPhoneBundleTransfer.importArchive(
            from: archive,
            name: "copy",
            in: VPhoneLibrary(root: dstRoot),
        )
        try body(archive, imported)
    }

    /// The `try` is hoisted out of `#expect` in these three: inside a throwing
    /// closure the macro's expansion does not carry the throw out, so
    /// `#expect(try magic(...))` is "errors thrown from here are not handled".
    @Test func `export defaults to fast zstd`() throws {
        try withExportAndImport(nil) { archive, imported in
            let magic = try magic(archive, 4)
            #expect(magic == Self.zstdMagic)
            #expect(imported.manifest.cpuCount == 6)
        }
    }

    @Test func `export fast produces zstd and round trips`() throws {
        try withExportAndImport(.fast) { archive, imported in
            let magic = try magic(archive, 4)
            #expect(magic == Self.zstdMagic)
            #expect(imported.manifest.cpuCount == 6)
        }
    }

    @Test func `export max produces xz and round trips`() throws {
        try withExportAndImport(.max) { archive, imported in
            let magic = try magic(archive, 6)
            #expect(magic == Self.xzMagic)
            #expect(imported.manifest.cpuCount == 6)
        }
    }

    /// Replaces the old `compressionPresetTarArgs`, which pinned the same
    /// contract as `tar` flag strings. The levels are not tuning: `.tzst` and
    /// `.txz` files produced at these settings are already in circulation.
    @Test func `compression presets pin levels and extensions`() {
        #expect(VPhoneBundleTransfer.ExportCompression.fast.archiveCompression == .zstd(level: 3))
        #expect(VPhoneBundleTransfer.ExportCompression.max.archiveCompression == .xz(level: 9))
        #expect(VPhoneBundleTransfer.ExportCompression.fast.fileExtension == "tzst")
        #expect(VPhoneBundleTransfer.ExportCompression.max.fileExtension == "txz")
    }

    @Test func `export to directory auto names with extension`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("orig", cpuCount: 6, in: lib)

        let outDir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: outDir) }
        let zstdOut = try VPhoneBundleTransfer.export(
            bundleNamed: "orig",
            to: outDir,
            includeIPSW: false,
            in: lib,
        )
        #expect(zstdOut == outDir.appendingPathComponent("orig.tzst"))
        #expect(FileManager.default.fileExists(atPath: zstdOut.path))
        let xzOut = try VPhoneBundleTransfer.export(
            bundleNamed: "orig",
            to: outDir,
            includeIPSW: false,
            compression: .max,
            in: lib,
        )
        #expect(xzOut == outDir.appendingPathComponent("orig.txz"))
        #expect(FileManager.default.fileExists(atPath: xzOut.path))
    }

    // MARK: - Progress

    @Test func `export and import report progress`() throws {
        final class Collector {
            private(set) var dones: [Int64] = []
            private(set) var total: Int64 = 0
            func add(_ done: Int64, _ total: Int64) {
                dones.append(done); self.total = total
            }
        }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("orig", cpuCount: 6, in: lib)

        let exp = Collector()
        let archive = root.appendingPathComponent("orig.tzst")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib) {
            exp.add($0, $1)
        }
        #expect(!exp.dones.isEmpty)
        #expect(exp.total > 0) // bundle logical size
        #expect(try #require(exp.dones.last) > 0)
        #expect(exp.dones == exp.dones.sorted()) // monotonically non-decreasing
        // A bar that only moved once per member would sit at zero for the whole
        // export: Disk.img is one entry and everything else is tiny.
        #expect(exp.dones.count > 1)

        let imp = Collector()
        let dstRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dstRoot) }
        _ = try VPhoneBundleTransfer.importArchive(
            from: archive,
            name: "copy",
            in: VPhoneLibrary(root: dstRoot),
        ) {
            imp.add($0, $1)
        }
        let archiveSize = try Data(contentsOf: archive).count
        #expect(!imp.dones.isEmpty)
        #expect(imp.total == Int64(archiveSize)) // total == compressed file size
        #expect(imp.dones == imp.dones.sorted())
        #expect(imp.dones.last == Int64(archiveSize)) // whole archive accounted for

        // That last one cannot fail on its own: `importArchive` reports
        // `(total, total)` unconditionally once extraction returns, precisely
        // so a tar end-of-archive marker short of the last byte does not leave
        // the bar at 99%. So it would stay green with the per-block callback
        // ripped out entirely. What proves the callback fires is the positions
        // BEFORE that final report — a bar that only learned where it was at
        // the end is not a progress bar.
        let intermediate = Set(imp.dones.dropLast())
        #expect(intermediate.count > 1, "import reported \(intermediate.count) position(s) before the final one")
        #expect(intermediate.contains { $0 < Int64(archiveSize) })
    }

    /// The progress total has to be reachable. `archivedLogicalSize` counts the
    /// bytes that will be packed, and a hardlinked file is packed once however
    /// many names it has — the writer's link resolver turns the later names
    /// into size-0 references. Counting each name's size instead put the total
    /// permanently above the packed bytes, so the bar could not reach 100%.
    @Test func `export progress total counts A hardlinked file once`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let bundle = try makeBundle("orig", in: lib)

        // One 100 KiB payload under three names, the shape a procursus
        // bootstrap has all over it.
        let payload = bundle.url.appendingPathComponent("linked.bin")
        try Data(repeating: 0x7A, count: 100 * 1024).write(to: payload)
        for alias in ["linked_b.bin", "linked_c.bin"] {
            try FileManager.default.linkItem(
                at: payload,
                to: bundle.url.appendingPathComponent(alias),
            )
        }

        final class Collector {
            private(set) var done: Int64 = 0
            private(set) var total: Int64 = 0
            func add(_ done: Int64, _ total: Int64) {
                self.done = done; self.total = total
            }
        }
        let progress = Collector()
        let archive = root.appendingPathComponent("orig.tzst")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib) {
            progress.add($0, $1)
        }

        #expect(progress.total > 0)
        #expect(progress.done == progress.total, "packed \(progress.done) of a claimed \(progress.total)")
        // All three names travel; only the bytes do not travel three times.
        let members = try VPhoneArchiveReader.entries(of: archive).map(\.path)
        for alias in ["linked.bin", "linked_b.bin", "linked_c.bin"] {
            #expect(members.contains("orig/\(alias)"))
        }
    }

    // MARK: - Compatibility, both directions

    /// An export holds exactly one top-level directory named after the VM, and
    /// an entry for that directory itself — what `tar -C <library> <name>`
    /// produced. `importArchive` requires it, and so does every archive already
    /// written by an older copy of this program.
    @Test func `export carries one top level bundle directory`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("orig", in: lib)
        let archive = root.appendingPathComponent("orig.tar")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)

        // "orig/", with the slash a tar header gives a directory — the same
        // spelling the old pipeline's `tar -C <library> orig` produced.
        let members = try VPhoneArchiveReader.entries(of: archive).map(\.path)
        #expect(members.first == "orig/")
        #expect(members.allSatisfy { $0.hasPrefix("orig/") })
    }

    /// The old code path spawned `/usr/bin/tar --format gnutar -cf - -C <root>
    /// <name>` into a compressing consumer. Reproducing that shape here checks
    /// the direction that cannot be checked any other way once the pipe is
    /// gone: an archive produced before this change still imports.
    ///
    /// gzip rather than zstd only so the check does not need a `zstd(1)` on
    /// PATH — which is the whole point of the migration. The compressor is
    /// detected either way; `Research/Host/archive_extraction_contracts.md` records
    /// the .tzst and .txz runs.
    @Test func `import reads archive written by the old tar pipeline`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("legacy", cpuCount: 6, in: lib)

        let archive = root.appendingPathComponent("legacy.tgz")
        let packed = try systemTar([
            "--format", "gnutar", "-czf", archive.path,
            "--exclude", "*_Restore*",
            "-C", lib.root.path, "legacy",
        ])
        try #require(packed.succeeded, "system tar could not pack the legacy-shaped archive")

        let dstRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dstRoot) }
        let imported = try VPhoneBundleTransfer.importArchive(
            from: archive,
            name: "fromlegacy",
            in: VPhoneLibrary(root: dstRoot),
        )
        #expect(imported.name == "fromlegacy")
        #expect(imported.manifest.cpuCount == 6)
        #expect(FileManager.default.fileExists(atPath: imported.url.appendingPathComponent("Disk.img").path))
    }

    /// And the other direction: what this writes is an ordinary tar. Checked
    /// after `decompress`, so the check does not need a `zstd(1)` either; the
    /// zstd stream itself is pinned by the magic-byte tests above.
    @Test func `system tar reads what export writes`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        try makeBundle("orig", cpuCount: 6, in: lib)

        let archive = root.appendingPathComponent("orig.tzst")
        try VPhoneBundleTransfer.export(bundleNamed: "orig", to: archive, includeIPSW: false, in: lib)
        let plain = root.appendingPathComponent("orig.tar")
        try VPhoneArchiveWriter.decompress(archive, to: plain)

        let listed = try systemTar(["-tf", plain.path])
        #expect(listed.succeeded)
        #expect(listed.stdout.contains("orig/Disk.img"))
        #expect(listed.stdout.contains("orig/config.plist"))

        let out = try makeRoot()
        defer { try? FileManager.default.removeItem(at: out) }
        let extracted = try systemTar(["-xf", plain.path, "-C", out.path])
        #expect(extracted.succeeded)
        let config = out.appendingPathComponent("orig/config.plist")
        #expect(try VPhoneVirtualMachineManifest.load(from: config).cpuCount == 6)
    }
}
