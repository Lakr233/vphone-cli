import Foundation
import Testing
@testable import VPhoneArchive

/// `--no-overwrite-dir`, which libarchive does not have.
///
/// This is the first thing in VPhoneArchive that needed a test, because
/// neither of the two behaviours libarchive does offer is the one GNU tar
/// gives us today, and the difference only shows up on a guest volume that
/// will not boot:
///
/// - libarchive's default updates the permissions of directories that already
///   exist. `iosbinpack64.tar` carries entries for `usr/`, `usr/local/` and
///   `System/`, so unpacking it onto an installed iOS volume would stamp the
///   archive's modes over the real ones.
/// - `ARCHIVE_EXTRACT_NO_OVERWRITE` skips *any* existing object, so a regular
///   file that should be replaced silently is not.
@Suite("Extraction: --no-overwrite-dir", .serialized)
struct NoOverwriteDirTests {
    // MARK: - Fixtures

    /// A tar containing `dir/` with a distinctive mode, plus a file inside it
    /// and one beside it.
    static func makeFixture(directoryMode: mode_t = 0o777) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-arc-src-\(UUID().uuidString)")
        let dir = staging.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("from archive\n".utf8).write(to: dir.appendingPathComponent("inside.txt"))
        try Data("beside\n".utf8).write(to: staging.appendingPathComponent("beside.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: directoryMode)], ofItemAtPath: dir.path
        )

        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-arc-\(UUID().uuidString).tar")
        try VPhoneArchiveWriter.create(archive: archive, from: staging)
        try? FileManager.default.removeItem(at: staging)
        return archive
    }

    static func makeDestination() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-arc-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func mode(of url: URL) throws -> mode_t {
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        return info.st_mode & 0o7777
    }

    /// The options `cfw_install` unpacks with, minus the one part that needs
    /// root.
    ///
    /// `--no-overwrite-dir` exists for exactly one caller — unpacking onto a
    /// mounted guest volume — so `ontoGuestVolume` is the preset these vary
    /// `noOverwriteDir` against. It is also the preset that carries
    /// `exactPermissions`, and the modes below are what that means: the host
    /// preset masks them through the umask instead, which is its whole point
    /// (see `ExtractPermissionsTests`) and would make "the archive's mode
    /// won" unobservable here.
    ///
    /// `.currentUser` only because `ARCHIVE_EXTRACT_OWNER` would need root to
    /// chown, and these run as whoever is testing.
    static func installOptions(noOverwriteDir: Bool) -> VPhoneArchiveExtractOptions {
        var options = VPhoneArchiveExtractOptions.ontoGuestVolume
        options.ownership = .currentUser
        options.noOverwriteDir = noOverwriteDir
        return options
    }

    // MARK: - The behaviour that matters

    @Test("an existing directory keeps its own permissions")
    func existingDirectoryKeepsItsMode() throws {
        let archive = try Self.makeFixture(directoryMode: 0o777)
        let destination = try Self.makeDestination()
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: destination)
        }

        // Stand in for a real directory on the guest volume: it exists, and
        // its mode is not the archive's.
        let existing = destination.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: existing.path
        )

        try VPhoneArchiveExtractor.extract(
            archive, into: destination, options: Self.installOptions(noOverwriteDir: true))

        #expect(try Self.mode(of: existing) == 0o700)
    }

    @Test("without the flag, the archive's permissions win — the behaviour we must not have")
    func defaultOverwritesTheMode() throws {
        let archive = try Self.makeFixture(directoryMode: 0o777)
        let destination = try Self.makeDestination()
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: destination)
        }

        let existing = destination.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: existing.path
        )

        try VPhoneArchiveExtractor.extract(
            archive, into: destination, options: Self.installOptions(noOverwriteDir: false))

        // `man 3 archive_write_disk`: "existing directories will have their
        // permissions updated". Confirmed — 0700 in, 0777 out. This is
        // precisely what must not happen to `usr/`, `usr/local/` and
        // `System/` on an installed iOS volume, and it is why noOverwriteDir
        // exists rather than being a courtesy.
        //
        // Pinned so a libarchive change shows up here rather than as a guest
        // that will not boot.
        #expect(try Self.mode(of: existing) == 0o777)
    }

    @Test("skipping a directory header still writes the files under it")
    func filesUnderASkippedDirectoryAreStillWritten() throws {
        let archive = try Self.makeFixture()
        let destination = try Self.makeDestination()
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: destination)
        }

        let existing = destination.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        try VPhoneArchiveExtractor.extract(
            archive, into: destination, options: Self.installOptions(noOverwriteDir: true))

        // This is the difference from ARCHIVE_EXTRACT_NO_OVERWRITE, which
        // would have skipped the whole subtree.
        let inside = existing.appendingPathComponent("inside.txt")
        #expect(FileManager.default.fileExists(atPath: inside.path))
        #expect(try String(contentsOf: inside, encoding: .utf8) == "from archive\n")
    }

    @Test("an existing regular file is still replaced")
    func existingFilesAreStillOverwritten() throws {
        let archive = try Self.makeFixture()
        let destination = try Self.makeDestination()
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: destination)
        }

        let beside = destination.appendingPathComponent("beside.txt")
        try Data("stale\n".utf8).write(to: beside)

        try VPhoneArchiveExtractor.extract(
            archive, into: destination, options: Self.installOptions(noOverwriteDir: true))

        // The other half of why ARCHIVE_EXTRACT_NO_OVERWRITE is not a
        // substitute: it would have left "stale" in place.
        #expect(try String(contentsOf: beside, encoding: .utf8) == "beside\n")
    }

    @Test("a directory that does not exist yet is created normally")
    func newDirectoriesAreUnaffected() throws {
        let archive = try Self.makeFixture(directoryMode: 0o755)
        let destination = try Self.makeDestination()
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: destination)
        }

        try VPhoneArchiveExtractor.extract(
            archive, into: destination, options: Self.installOptions(noOverwriteDir: true))

        let dir = destination.appendingPathComponent("dir")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(try Self.mode(of: dir) == 0o755)
    }

    @Test("a symlink standing where a directory would go is replaced, not followed")
    func symlinkIsNotFollowed() throws {
        let archive = try Self.makeFixture()
        let destination = try Self.makeDestination()
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: destination)
        }

        // A planted symlink is the classic way to get an unpacker to write
        // somewhere it was not asked to.
        let elsewhere = destination.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("dir"), withDestinationURL: elsewhere
        )

        try VPhoneArchiveExtractor.extract(
            archive, into: destination, options: Self.installOptions(noOverwriteDir: true))

        // Two things have to hold, and both do.
        //
        // The skip check uses lstat, so the symlink is not mistaken for an
        // existing directory and quietly left in place — which is what would
        // have made the write go through it.
        //
        // ARCHIVE_EXTRACT_SECURE_SYMLINKS then removes it and creates a real
        // directory, so nothing lands in `elsewhere`.
        var info = stat()
        #expect(lstat(destination.appendingPathComponent("dir").path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
        #expect(!FileManager.default.fileExists(
            atPath: elsewhere.appendingPathComponent("inside.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("dir/inside.txt").path
        ))
    }
}
