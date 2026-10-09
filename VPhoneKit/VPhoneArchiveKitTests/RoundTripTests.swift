import ArchiveKit
import Foundation
import Testing
@testable import VPhoneArchiveKit

/// `.serialized` because these do real filesystem work and libarchive leaves
/// `tar.XXXXXXXX` temp files in the process's working directory when several
/// run at once. Serialised, it does not.
@Suite("Archive round trips and path safety", .serialized)
struct RoundTripTests {
    static func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-rt-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("top.txt"))
        try Data(repeating: 0x5A, count: 300_000).write(to: nested.appendingPathComponent("big.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path,
            withDestinationPath: "top.txt",
        )
        try Data("skip me\n".utf8).write(to: root.appendingPathComponent("excluded.log"))
        return root
    }

    static func scratch(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-rt-\(suffix)-\(UUID().uuidString)")
    }

    @Test(
        arguments: [
            VPhoneArchiveCompression.none,
            .zstd(level: 3),
            .xz(level: 1),
            .gzip(level: 1),
        ],
    )
    func `tar round trip preserves contents, nesting and symlinks`(compression: VPhoneArchiveCompression) throws {
        let source = try Self.makeTree()
        let archive = Self.scratch("arc").appendingPathExtension(compression.tarExtension)
        let destination = Self.scratch("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [source, archive, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try VPhoneArchiveWriter.create(archive: archive, from: source, compression: compression)
        try VPhoneArchiveExtractor.extract(
            archive,
            into: destination,
            options: .intoHostDirectory,
        )

        #expect(try String(
            contentsOf: destination.appendingPathComponent("top.txt"), encoding: .utf8,
        ) == "hello\n")
        #expect(try Data(
            contentsOf: destination.appendingPathComponent("a/b/big.bin"),
        ).count == 300_000)

        // The symlink has to come back as a symlink, not as a copy of its
        // target: a bootstrap tar is mostly symlinks, and flattening them
        // silently doubles the volume and breaks relative paths.
        let link = destination.appendingPathComponent("link")
        var info = stat()
        #expect(lstat(link.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "top.txt")
    }

    @Test
    func `the compressor actually ran`() throws {
        let source = try Self.makeTree()
        let plain = Self.scratch("plain").appendingPathExtension("tar")
        let compressed = Self.scratch("zstd").appendingPathExtension("tzst")
        defer {
            for url in [source, plain, compressed] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try VPhoneArchiveWriter.create(archive: plain, from: source)
        try VPhoneArchiveWriter.create(archive: compressed, from: source, compression: .zstd(level: 3))

        // 300 KB of one repeated byte: if it did not shrink, no compressor ran.
        let plainSize = try FileManager.default.attributesOfItem(atPath: plain.path)[.size] as? Int ?? 0
        let smallSize = try FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? Int ?? 0
        #expect(smallSize < plainSize / 10)

        let described = try VPhoneArchiveReader.describe(compressed)
        #expect(described.filter == "zstd")
    }

    @Test
    func `member paths are relative, even when the source is reached through a symlink`() throws {
        let source = try Self.makeTree()
        let archive = Self.scratch("rel").appendingPathExtension("tar")
        defer {
            for url in [source, archive] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try VPhoneArchiveWriter.create(archive: archive, from: source)
        let paths = try VPhoneArchiveReader.entries(of: archive).map(\.path)
        #expect(paths.allSatisfy { !$0.hasPrefix("/") })
        #expect(paths.contains("top.txt"))
        #expect(paths.contains("a/b/big.bin"))

        // The case the suite missed for a while. Foundation's path
        // standardisation strips a /private prefix, so a source under
        // /private/tmp compared against its own standardised form never
        // matched its root, and every member was stored absolute. The tests
        // did not catch it because FileManager's temporaryDirectory is
        // /var/folders/..., which has no /private to strip.
        let viaPrivate = URL(fileURLWithPath: "/private" + source.path)
        if FileManager.default.fileExists(atPath: viaPrivate.path) {
            let second = Self.scratch("rel2").appendingPathExtension("tar")
            defer { try? FileManager.default.removeItem(at: second) }
            try VPhoneArchiveWriter.create(archive: second, from: viaPrivate)
            let viaPrivatePaths = try VPhoneArchiveReader.entries(of: second).map(\.path)
            // Only that they are relative. Comparing the two member lists
            // outright would be asserting that nothing else in TMPDIR changed
            // between the two packs, which is not this test's business and is
            // not true while other tests are running.
            #expect(viaPrivatePaths.allSatisfy { !$0.hasPrefix("/") })
            #expect(viaPrivatePaths.contains("top.txt"))
        }
    }

    @Test
    func `hardlinks survive as hardlinks`() throws {
        let source = try Self.makeTree()
        let archive = Self.scratch("hl").appendingPathExtension("tar")
        let destination = Self.scratch("hlout")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [source, archive, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try FileManager.default.linkItem(
            at: source.appendingPathComponent("top.txt"),
            to: source.appendingPathComponent("same.txt"),
        )

        try VPhoneArchiveWriter.create(archive: archive, from: source)
        try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)

        // Without archive_entry_linkresolver each name is packed as a separate
        // full copy, and unpacking gives back two unrelated files. That is not
        // cosmetic: iosbinpack64 and the procursus bootstrap are full of
        // hardlinks, so flattening them silently doubles what lands on the
        // guest volume. GNU tar preserves them, and `vphone-archive
        // fingerprint` is what caught the difference.
        var first = stat(), second = stat()
        #expect(lstat(destination.appendingPathComponent("top.txt").path, &first) == 0)
        #expect(lstat(destination.appendingPathComponent("same.txt").path, &second) == 0)
        #expect(first.st_ino == second.st_ino)
        #expect(first.st_nlink == 2)
    }

    @Test
    func `a tree fingerprint notices what diff -r would miss`() throws {
        let a = Self.scratch("fpa")
        let b = Self.scratch("fpb")
        // The same mtime on both, because two files written a moment apart
        // genuinely differ and the fingerprint is right to say so — mtime is
        // one of the things ARCHIVE_EXTRACT_TIME is supposed to restore.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [a, b] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("same\n".utf8).write(to: url.appendingPathComponent("f.txt"))
            try FileManager.default.setAttributes(
                [.modificationDate: when],
                ofItemAtPath: url.appendingPathComponent("f.txt").path,
            )
            try FileManager.default.setAttributes(
                [.modificationDate: when],
                ofItemAtPath: url.path,
            )
        }
        defer {
            for url in [a, b] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        #expect(try VPhoneTreeFingerprint.capture(a)
            .differences(from: VPhoneTreeFingerprint.capture(b)).isEmpty)

        // Identical contents, different mode — `diff -r` says nothing.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: b.appendingPathComponent("f.txt").path,
        )
        let differences = try VPhoneTreeFingerprint.capture(a)
            .differences(from: VPhoneTreeFingerprint.capture(b))
        #expect(differences.count == 1)
        #expect(differences[0].contains("mode"))
    }

    @Test
    func `exclusions are applied`() throws {
        let source = try Self.makeTree()
        let archive = Self.scratch("exc").appendingPathExtension("tar")
        defer {
            for url in [source, archive] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try VPhoneArchiveWriter.create(archive: archive, from: source, excluding: ["*.log"])
        let paths = try VPhoneArchiveReader.entries(of: archive).map(\.path)
        #expect(!paths.contains("excluded.log"))
        #expect(paths.contains("top.txt"))
    }

    @Test
    func `packing does not modify the tree it reads`() throws {
        // libarchive's read_disk defaults to ARCHIVE_READDISK_MAC_COPYFILE,
        // which packs each file's AppleDouble form through a temp file made
        // from a *relative* mkstemp template — and the tree walker chdir's
        // into each directory as it descends, so the temp file appears and
        // vanishes inside the directory being read and leaves its mtime at
        // now. `vm export` was rewriting the mtime of every directory in the
        // VM bundle it had only been asked to read. `/usr/bin/tar -cf` does
        // not do this, and neither should this.
        let source = try Self.makeTree()
        let archive = Self.scratch("untouched").appendingPathExtension("tar")
        defer {
            for url in [source, archive] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let nested = source.appendingPathComponent("a/b")
        for url in [source, source.appendingPathComponent("a"), nested] {
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        }

        try VPhoneArchiveWriter.create(archive: archive, from: source)

        for url in [source, source.appendingPathComponent("a"), nested] {
            var info = stat()
            #expect(lstat(url.path, &info) == 0)
            #expect(info.st_mtimespec.tv_sec == Int(when.timeIntervalSince1970))
        }
    }

    @Test
    func `a single member can be read without unpacking`() throws {
        let source = try Self.makeTree()
        let archive = Self.scratch("member").appendingPathExtension("tar")
        defer {
            for url in [source, archive] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try VPhoneArchiveWriter.create(archive: archive, from: source)
        let data = try VPhoneArchiveReader.readMember("top.txt", from: archive)
        #expect(String(decoding: data, as: UTF8.self) == "hello\n")

        #expect(throws: VPhoneArchiveError.self) {
            try VPhoneArchiveReader.readMember("nope.txt", from: archive)
        }
    }

    @Test
    func `decompress unwraps a single stream without unpacking it`() throws {
        // What `zstd -d -f bootstrap.tar.zst -o bootstrap.tar` does: the input
        // is one compressed file and the output is the tar, still packed.
        let source = try Self.makeTree()
        let tar = Self.scratch("inner").appendingPathExtension("tar")
        let compressed = Self.scratch("inner").appendingPathExtension("tar.zst")
        let restored = Self.scratch("restored").appendingPathExtension("tar")
        defer {
            for url in [source, tar, compressed, restored] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Compress an existing tar, rather than packing the tree twice: two
        // independent packs of the same tree are not expected to be
        // byte-identical (traversal order is not promised), so comparing them
        // would assert something that is not true.
        try VPhoneArchiveWriter.create(archive: tar, from: source)
        let staging = Self.scratch("stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: tar, to: staging.appendingPathComponent("inner.tar"))
        try VPhoneArchiveWriter.create(
            archive: compressed,
            from: staging,
            compression: .zstd(level: 3),
        )

        // What decompress gives back is the tar.zst's single stream, which
        // here is the outer tar containing inner.tar.
        try VPhoneArchiveWriter.decompress(compressed, to: restored)
        let members = try VPhoneArchiveReader.entries(of: restored).map(\.path)
        #expect(members == ["inner.tar"])

        // And it is still an archive, not a decompressed blob: the inner tar
        // comes out byte-identical to the one that went in.
        #expect(try VPhoneArchiveReader.readMember("inner.tar", from: restored)
            == Data(contentsOf: tar))
    }

    @Test
    func `a member that escapes the destination is refused`() throws {
        // Hand-built, because the writer will not produce one.
        let staging = Self.scratch("evil")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let archive = Self.scratch("evil").appendingPathExtension("tar")
        let destination = Self.scratch("victim")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [staging, archive, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try Data("pwned\n".utf8).write(to: staging.appendingPathComponent("payload"))
        try VPhoneArchiveWriter.create(archive: archive, from: staging)
        try rewriteFirstMemberName(of: archive, to: "../escaped")

        #expect(throws: VPhoneArchiveError.self) {
            try VPhoneArchiveExtractor.extract(
                archive,
                into: destination,
                options: .intoHostDirectory,
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: destination.deletingLastPathComponent().appendingPathComponent("escaped").path,
        ))
    }

    // MARK: - Non-ASCII names

    /// libarchive converts member names through the calling thread's LC_CTYPE.
    /// A process that never calls setlocale(3) — every launchd job, the
    /// Launchpad helper, and vphone-cli itself — runs in "C", where UTF-8 names
    /// cannot be converted: the reader returned a NULL pathname and the pax
    /// writer refused the header. Pinned to "C" here so the test does not
    /// depend on how the test runner set up its locale.
    private func inLocale<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let locale = try #require(newlocale(LC_CTYPE_MASK, name, nil))
        let previous = uselocale(locale)
        defer {
            uselocale(previous)
            freelocale(locale)
        }
        return try body()
    }

    private static let unicodeName = "café-中文.txt"

    private static func makeUnicodeTree() throws -> URL {
        let root = scratch("unicode")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("目录"),
            withIntermediateDirectories: true,
        )
        try Data("bonjour\n".utf8).write(to: root.appendingPathComponent("目录/\(unicodeName)"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("lien-é").path,
            withDestinationPath: "目录/\(unicodeName)",
        )
        return root
    }

    @Test(arguments: [VPhoneArchiveFormat.gnutar, .pax])
    func `non-ASCII names round trip in the C locale`(format: VPhoneArchiveFormat) throws {
        let source = try Self.makeUnicodeTree()
        let archive = Self.scratch("unicode").appendingPathExtension("tar")
        let destination = Self.scratch("unicode-out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [source, archive, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let member = "目录/\(Self.unicodeName)"
        let (entries, data) = try inLocale("C") {
            try VPhoneArchiveWriter.create(archive: archive, from: source, format: format)
            try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)
            return try (
                VPhoneArchiveReader.entries(of: archive),
                VPhoneArchiveReader.readMember(member, from: archive),
            )
        }

        #expect(Set(entries.map(\.path)) == ["目录/", member, "lien-é"])
        #expect(entries.first { $0.path == "lien-é" }?.linkTarget == member)
        #expect(String(decoding: data, as: UTF8.self) == "bonjour\n")
        #expect(try String(contentsOf: destination.appendingPathComponent(member), encoding: .utf8) == "bonjour\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("lien-é").path,
        ) == member)
    }

    /// A zip entry with the UTF-8 flag (0x800) is the case libarchive converts
    /// rather than passing the bytes through. Neither ditto nor /usr/bin/zip
    /// sets that flag, so the fixture is written here, in a UTF-8 locale.
    @Test
    func `a UTF-8 flagged zip is listed and unpacked in the C locale`() throws {
        let zip = Self.scratch("unicode").appendingPathExtension("zip")
        let destination = Self.scratch("unicode-zip-out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [zip, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let member = "目录/\(Self.unicodeName)"
        try inLocale("UTF-8") {
            let writer = archive_write_new()
            defer { archive_write_free(writer) }
            archive_write_set_format_zip(writer)
            try #require(archive_write_set_options(writer, "zip:hdrcharset=UTF-8") == ARCHIVE_OK)
            try #require(archive_write_open_filename(writer, zip.path) == ARCHIVE_OK)
            let entry = archive_entry_new()
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, member)
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o644)
            archive_entry_set_size(entry, 8)
            try #require(archive_write_header(writer, entry) == ARCHIVE_OK)
            #expect(archive_write_data(writer, "bonjour\n", 8) == 8)
            try #require(archive_write_close(writer) == ARCHIVE_OK)
        }
        // General purpose flags are at +6 of the first local header.
        let header = try [UInt8](Data(contentsOf: zip).prefix(8))
        try #require(header[0 ..< 4] == [0x50, 0x4B, 0x03, 0x04])
        try #require(header[7] & 0x08 != 0)

        let (entries, data) = try inLocale("C") {
            try VPhoneArchiveExtractor.extract(zip, into: destination, options: .intoHostDirectory)
            return try (
                VPhoneArchiveReader.entries(of: zip),
                VPhoneArchiveReader.readMember(member, from: zip),
            )
        }

        #expect(entries.map(\.path).contains(member))
        #expect(!entries.contains { $0.path.isEmpty })
        #expect(String(decoding: data, as: UTF8.self) == "bonjour\n")
        #expect(try String(contentsOf: destination.appendingPathComponent(member), encoding: .utf8) == "bonjour\n")
    }

    /// Overwrite the name in a ustar/gnutar header in place. The name field is
    /// 100 bytes at offset 0 of the header block, and the header checksum has
    /// to be recomputed or libarchive rejects the entry before we see it.
    private func rewriteFirstMemberName(of archive: URL, to name: String) throws {
        var bytes = try [UInt8](Data(contentsOf: archive))
        for i in 0 ..< 100 {
            bytes[i] = 0
        }
        for (i, byte) in Array(name.utf8).enumerated() {
            bytes[i] = byte
        }

        for i in 148 ..< 156 {
            bytes[i] = UInt8(ascii: " ")
        } // checksum field reads as spaces
        let sum = (0 ..< 512).reduce(0) { $0 + Int(bytes[$1]) }
        let octal = String(format: "%06o", sum)
        for (i, byte) in Array(octal.utf8).enumerated() {
            bytes[148 + i] = byte
        }
        bytes[154] = 0
        bytes[155] = UInt8(ascii: " ")

        try Data(bytes).write(to: archive)
    }

    /// A stopped machine keeps the `vphone.sock` its last run bound, and
    /// gnutar refused the whole export on it. The socket is left out; the
    /// rest of the tree goes in.
    @Test
    func `a socket in the tree is left out of the archive`() throws {
        // Short: sun_path holds 104 bytes, more than the temporary
        // directory leaves for a UUID-named tree.
        let source = URL(fileURLWithPath: "/tmp/vrt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let archive = Self.scratch("sock").appendingPathExtension("tar")
        let destination = Self.scratch("sock-out")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [source, archive, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try Data("config\n".utf8).write(to: source.appendingPathComponent("config.plist"))

        let socketPath = source.appendingPathComponent("vphone.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)

        try VPhoneArchiveWriter.create(archive: archive, from: source, topLevel: "Mulberry", format: .gnutar)
        try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)

        let unpacked = destination.appendingPathComponent("Mulberry")
        #expect(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("config.plist").path))
        #expect(!FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("vphone.sock").path))
    }
}
