import Foundation
import LibArchive
import Testing
@testable import VPhoneArchive
import VPhoneCore

/// What an extraction is allowed to decide about the modes of the files it
/// writes.
///
/// There are two answers and they are opposites, which is the whole reason
/// these exist. `ontoGuestVolume` restores the archive's modes verbatim,
/// setuid included, because an iOS system volume's modes are the payload.
/// `intoHostDirectory` does not, because the archive came from somewhere else
/// and the files land in the user's home directory.
///
/// `vm import` shelled out to `/usr/bin/tar -xf` — no `-p` — for its whole
/// life, so it always had the second behaviour. When the shell-out became a
/// libarchive call, `ARCHIVE_EXTRACT_PERM` was set unconditionally and the
/// behaviour silently became the first. That is what these pin.
///
/// `.serialized` for the same reason as the other suites here: libarchive
/// leaves `tar.XXXXXXXX` temp files in the working directory when several
/// extractions run at once.
@Suite("Extraction permissions", .serialized)
struct ExtractPermissionsTests {
    // MARK: - Fixture

    /// The three shapes that tell the two presets apart: a setuid binary, a
    /// world-writable directory and a world-writable file.
    private struct Fixture {
        let source: URL
        let archive: URL

        static let setuidFile = "setuid_file"
        static let wideDirectory = "wide_dir"
        static let worldWritableFile = "world_writable.txt"

        /// What is stored in the archive, which is also what `-p` restores.
        static let archivedModes: [String: mode_t] = [
            setuidFile: 0o4755,
            wideDirectory: 0o777,
            worldWritableFile: 0o666,
        ]

        static func make() throws -> Fixture {
            let fm = FileManager.default
            let source = scratch("perm-src")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: source.appendingPathComponent(setuidFile))
            try fm.createDirectory(
                at: source.appendingPathComponent(wideDirectory),
                withIntermediateDirectories: true,
            )
            try Data("owo\n".utf8).write(to: source.appendingPathComponent(worldWritableFile))
            // chmod after the writes: creating a file resets its mode.
            for (name, mode) in archivedModes {
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)],
                    ofItemAtPath: source.appendingPathComponent(name).path,
                )
            }
            // A setuid bit that the filesystem refused would make every
            // assertion below vacuously true.
            try #require(
                mode(of: source.appendingPathComponent(setuidFile)) == 0o4755,
                "the test filesystem would not keep a setuid bit",
            )

            // Uncompressed, so /usr/bin/tar can read it without a filter
            // helper on PATH.
            let archive = scratch("perm-arc").appendingPathExtension("tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source)
            return Fixture(source: source, archive: archive)
        }

        static func scratch(_ suffix: String) -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("vphone-\(suffix)-\(UUID().uuidString)")
        }

        /// The permission bits, setuid/setgid/sticky included.
        static func mode(of url: URL) -> mode_t? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return info.st_mode & 0o7777
        }

        func cleanUp() {
            for url in [source, archive] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - The flag itself

    /// The regression test, at the level the regression happened: a flag.
    ///
    /// `ARCHIVE_EXTRACT_PERM` is `tar -p`. Without it, `archive_write_disk`
    /// clears setuid, setgid and sticky and masks what is left through the
    /// umask; with it, the archive's mode is written exactly. Anything that
    /// sets it on the host preset — including "tidying up" the conditional —
    /// fails here.
    @Test func `host preset never restores setuid`() {
        let host = VPhoneArchiveExtractOptions.intoHostDirectory
        #expect(!host.exactPermissions)
        #expect(host.extractFlags & Int32(ARCHIVE_EXTRACT_PERM) == 0)

        // And the other half of the contract: cfw_install genuinely needs the
        // exact modes, so the guest preset must keep the flag.
        let guest = VPhoneArchiveExtractOptions.ontoGuestVolume
        #expect(guest.exactPermissions)
        #expect(guest.extractFlags & Int32(ARCHIVE_EXTRACT_PERM) != 0)
    }

    /// The default is the safe one, so an option set built by hand — or a
    /// preset someone copies — does not acquire `-p` by omission.
    @Test func `exact permissions is opt in`() {
        #expect(!VPhoneArchiveExtractOptions(ownership: .currentUser).exactPermissions)
        #expect(!VPhoneArchiveExtractOptions(ownership: .preserveNumeric).exactPermissions)
    }

    // MARK: - What lands on disk

    /// The observable half: unpack the same archive with the host preset and
    /// with `/usr/bin/tar -xf`, and require the modes to agree.
    ///
    /// Comparing against `tar` rather than against literals keeps this true
    /// whatever umask the test runs under — and `tar -xf` is precisely what
    /// `vm import` used to run, so agreement with it *is* the contract.
    @Test func `host extraction matches plain system tar`() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let fm = FileManager.default

        let ours = Fixture.scratch("perm-ours")
        let theirs = Fixture.scratch("perm-tar")
        try fm.createDirectory(at: ours, withIntermediateDirectories: true)
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        defer { for url in [ours, theirs] {
            try? fm.removeItem(at: url)
        } }

        try VPhoneArchiveExtractor.extract(
            fixture.archive,
            into: ours,
            options: .intoHostDirectory,
        )
        let untarred = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xf", fixture.archive.path, "-C", theirs.path],
        )
        try #require(untarred.succeeded, "system tar could not unpack the fixture: \(untarred.stderr)")

        for name in Fixture.archivedModes.keys.sorted() {
            let mine = Fixture.mode(of: ours.appendingPathComponent(name))
            let tars = Fixture.mode(of: theirs.appendingPathComponent(name))
            #expect(mine != nil, "\(name) was not extracted")
            #expect(mine == tars, "\(name): extractor gave \(mine ?? 0), tar -xf gave \(tars ?? 0)")
        }
    }

    /// And the part that holds under any umask: nothing arriving from an
    /// archive may be setuid, setgid or sticky. Run as root — `vm import`
    /// under sudo — restoring the archive's mode would give a setuid-root
    /// binary out of an untrusted file.
    @Test func `host extraction strips setuid setgid and sticky`() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let fm = FileManager.default
        let destination = Fixture.scratch("perm-strip")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: destination) }

        try VPhoneArchiveExtractor.extract(
            fixture.archive,
            into: destination,
            options: .intoHostDirectory,
        )

        for name in Fixture.archivedModes.keys.sorted() {
            let mode = try #require(Fixture.mode(of: destination.appendingPathComponent(name)))
            #expect(mode & mode_t(S_ISUID) == 0, "\(name) came back setuid")
            #expect(mode & mode_t(S_ISGID) == 0, "\(name) came back setgid")
            #expect(mode & mode_t(S_ISVTX) == 0, "\(name) came back sticky")
        }
    }

    /// The opposite preset, on the one thing that can be checked without
    /// being root: with `-p` the setuid bit survives. (Ownership cannot —
    /// `ARCHIVE_EXTRACT_OWNER` needs root — but the mode does, because the
    /// file already belongs to whoever is running.)
    @Test func `guest preset keeps exact modes`() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let fm = FileManager.default
        let destination = Fixture.scratch("perm-guest")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: destination) }

        var options = VPhoneArchiveExtractOptions.ontoGuestVolume
        // The one thing dialled back for a non-root run: chown would fail and
        // take the setuid bit down with it. Everything under test here is the
        // mode.
        options.ownership = .currentUser
        try VPhoneArchiveExtractor.extract(fixture.archive, into: destination, options: options)

        for (name, archived) in Fixture.archivedModes.sorted(by: { $0.key < $1.key }) {
            #expect(
                Fixture.mode(of: destination.appendingPathComponent(name)) == archived,
                "\(name) did not come back with the mode the archive stores",
            )
        }
    }
}
