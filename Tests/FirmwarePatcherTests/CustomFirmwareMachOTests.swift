// CustomFirmwareMachOTests.swift — Mach-O load-command insertion and code-signature re-attestation.
//
// The modules are checked against independent effects:
//
//   * `CustomFirmwareInjectDylib` loads a real Objective-C swizzle dylib into
//     a small executable, changing its observed output.
//   * `CustomFirmwareMachOCodeSignature` against `scripts/patchers/cfw_macho_codesign.py`,
//     byte for byte. That Python is gone, so what it wrote is frozen in
//     ``MachOCodeSignGolden`` below — over the real 24A435 `seputil` rather
//     than a local build product, because a golden is only worth what its
//     input is reproducible.
//
// Everything that can be asserted without a reference is asserted, first
// among them the short tail slot, which is the known regression in independent
// re-signing.
//
// Every test that needs a signed Mach-O now operates on that same `seputil`.
// It used to be `.build/release/vphone-letmein` — a convenient small binary
// that has since been removed from the project — and the shapes those tests
// want are properties of the *input*, not of anything a local link guarantees:
// a SHA-256 code directory, a codeLimit that is not page aligned, and enough
// zero padding behind the load commands to insert a command into. A frozen
// fixture has them on purpose; a build product had them by luck.
//
// The fixture is therefore required, the way the sibling CFW parity suites
// require it: point `VPHONE_MACHO_PRISTINE` at a directory of pristine Mach-Os
// or leave the default `ipsws/ref_extract/macho_pristine` in place. Without it
// these tests FAIL rather than skip, because a skipped test reads like a
// passing one. A machine that genuinely cannot carry the extracted IPSW sets
// `VPHONE_MACHO_FIXTURE_OPTIONAL=1`, which turns the failure back into a skip.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixtures

enum MachOFixture {
    /// The package root, derived from this file rather than the working
    /// directory, which `swift test` does not promise.
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // FirmwarePatcherTests
        .deletingLastPathComponent() // tests
        .deletingLastPathComponent() // <root>

    /// The tree of untouched Mach-Os, overridable the way every other CFW
    /// parity suite in this directory overrides it. Not in the repo — `ipsws/`
    /// never is.
    static var pristineDirectory: URL {
        ProcessInfo.processInfo.environment["VPHONE_MACHO_PRISTINE"]
            .map { URL(filePath: $0) }
            ?? repositoryRoot.appending(path: "ipsws/ref_extract/macho_pristine")
    }

    /// The real 24A435 `seputil`: ad-hoc signed, thin arm64e, one SHA-256 code
    /// directory, 4 KiB pages, and a codeLimit of 183888 — not page aligned, so
    /// the last slot is a 3664-byte short tail. Thirty-two zero bytes sit
    /// between its load commands and its first section, which is exactly what a
    /// `/b` load command needs. It does not change between builds, which is
    /// what makes both a frozen digest and a stated shape mean anything.
    static var pristineSeputil: URL? {
        let url = pristineDirectory.appending(path: "seputil")
        return exists(url) ? url : nil
    }

    /// The fixture every signed-Mach-O test below operates on, or a failure
    /// that names what is missing instead of a silent skip.
    static func signedBinary() throws -> URL {
        try #require(pristineSeputil, missing)
    }

    /// Opt-out for a machine that cannot carry the extracted IPSW.
    static var fixtureIsOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_MACHO_FIXTURE_OPTIONAL"] == "1"
    }

    /// A fixture-backed test runs unless the binary is absent *and* the caller
    /// opted out, so a green run cannot mean the fixture quietly went away.
    static var runs: Bool {
        pristineSeputil != nil || !fixtureIsOptional
    }

    static let missing: Comment = """
    the real 24A435 seputil is required — put it at \
    ipsws/ref_extract/macho_pristine/, point VPHONE_MACHO_PRISTINE at that \
    directory, or set VPHONE_MACHO_FIXTURE_OPTIONAL=1 to skip these tests \
    instead of failing
    """

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static var hasCodesign: Bool {
        exists(URL(filePath: "/usr/bin/codesign"))
    }

    /// SHA-256 as `shasum -a 256` prints it.
    static func digest(of url: URL) throws -> String {
        try Data(SHA256.hash(data: Data(contentsOf: url))).hex
    }

    /// A private copy of `source` — the fixture by default — that the caller
    /// may modify freely. Nothing here ever writes to the pristine tree.
    static func scratchCopy(_ name: String, of source: URL? = nil) throws -> URL {
        let origin = try source ?? signedBinary()
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "CustomFirmwareMachOTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: origin, to: destination)
        // The fixture is 0755 already; this is only so a reference tree
        // someone made read-only does not turn into a failing patch test.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path,
        )
        return destination
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// Flip one byte, the way a patcher would.
    static func flipByte(at offset: Int, in url: URL) throws {
        var data = try Data(contentsOf: url)
        data[offset] ^= 0xFF
        try data.write(to: url)
    }

    /// Independent load-command walk, so the tests do not check the injector
    /// against the injector's own parser.
    static func dylibLoadCommands(in data: Data) -> [(command: UInt32, path: String)] {
        var results: [(UInt32, String)] = []
        let ncmds = data.loadLE(UInt32.self, at: 16)
        var offset = 32
        for _ in 0 ..< ncmds {
            let cmd = data.loadLE(UInt32.self, at: offset)
            let cmdsize = Int(data.loadLE(UInt32.self, at: offset + 4))
            if cmd == 0x0C || cmd == 0x8000_0018 { // LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB
                let nameOffset = offset + Int(data.loadLE(UInt32.self, at: offset + 8))
                let bytes = data[nameOffset ..< offset + cmdsize].prefix { $0 != 0 }
                results.append((cmd, String(decoding: bytes, as: UTF8.self)))
            }
            offset += cmdsize
        }
        return results
    }
}

// MARK: - Code Signature

@Suite("Standalone Mach-O code-signature re-attestation")
struct CustomFirmwareMachOCodeSignatureTests {
    // MARK: Tail slot

    /// The regression this module exists to not repeat.
    ///
    /// The last code slot covers `codeLimit - slotStart` bytes, not a whole
    /// page. Hashing a full page there — or anything else — produces a binary
    /// that TXM kills the first time that page is faulted in, and nothing about
    /// the file looks wrong until then.
    @Test(.enabled(if: MachOFixture.runs, MachOFixture.missing))
    func `tail slot hashes only up to code limit`() throws {
        let data = try Data(contentsOf: MachOFixture.signedBinary())
        let directory = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: data)?.first)

        let lastSlot = directory.codeSlotCount - 1
        let range = try #require(directory.slotRange(lastSlot))
        #expect(range.upperBound == directory.codeLimit)
        #expect(range.count == directory.codeLimit - lastSlot * directory.pageSize)
        #expect(range.count < directory.pageSize, "fixture must have a non-page-aligned codeLimit")

        // Re-attest a change inside the tail page and check the hash that lands
        // in the slot against one computed here from the short range.
        let file = try MachOFixture.scratchCopy("tail")
        try MachOFixture.flipByte(at: directory.codeLimit - 1, in: file)
        let records = try CustomFirmwareMachOCodeSignature.reattest(
            fileAt: file,
            modifiedOffsets: [directory.codeLimit - 1],
        )
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.pageIndex == lastSlot)
        #expect(record.isTailSlot)
        #expect(record.hashedLength == range.count)

        let patched = try Data(contentsOf: file)
        let shortHash = Data(SHA256.hash(data: patched[range]))
        #expect(record.after == shortHash)
        #expect(
            patched[record.hashFileOffset ..< record.hashFileOffset + directory.hashSize] == shortHash,
            "the slot on disk must hold the hash of the short range",
        )

        // And state the failure mode directly: a full-page hash is a different
        // value, so this is not an assertion that happens to pass either way.
        let fullPage = record.pageStart ..< record.pageStart + directory.pageSize
        if patched.count >= fullPage.upperBound {
            #expect(Data(SHA256.hash(data: patched[fullPage])) != shortHash)
        }
    }

    /// The contrast case: when `codeLimit` is page-aligned there is no short
    /// tail, and the last slot must cover a whole page. No binary on a build
    /// machine reliably has a page-aligned codeLimit, so the boundary maths is
    /// pinned directly.
    @Test func `slot ranges follow code limit alignment`() {
        let aligned = CustomFirmwareCodeDirectory(
            slotType: 0,
            offset: 0,
            length: 0,
            hashOffset: 0,
            hashSize: 32,
            hashType: 2,
            pageSize: 4096,
            pageSizeLog2: 12,
            codeSlotCount: 2,
            codeLimit: 8192,
        )
        #expect(aligned.slotRange(0) == 0 ..< 4096)
        #expect(aligned.slotRange(1) == 4096 ..< 8192)
        #expect(aligned.slotRange(2) == nil)

        let short = CustomFirmwareCodeDirectory(
            slotType: 0,
            offset: 0,
            length: 0,
            hashOffset: 0,
            hashSize: 32,
            hashType: 2,
            pageSize: 4096,
            pageSizeLog2: 12,
            codeSlotCount: 2,
            codeLimit: 5000,
        )
        #expect(short.slotRange(0) == 0 ..< 4096)
        #expect(short.slotRange(1) == 4096 ..< 5000)
    }

    @Test func `offsets past code limit belong to no slot`() {
        #expect(CustomFirmwareMachOCodeSignature.pageBounds(fileOffset: 4095, pageSize: 4096, codeLimit: 5000)?.index == 0)
        #expect(CustomFirmwareMachOCodeSignature.pageBounds(fileOffset: 4999, pageSize: 4096, codeLimit: 5000)?.end == 5000)
        #expect(CustomFirmwareMachOCodeSignature.pageBounds(fileOffset: 5000, pageSize: 4096, codeLimit: 5000) == nil)
    }

    // MARK: Page size

    /// The page size comes from the CD, never from a constant. The plan records
    /// 4 KiB for the iOS binaries this pipeline patches, but the host's own
    /// signer writes 16 KiB, and a hard-coded 4096 silently hashes the wrong
    /// ranges on anything signed that way.
    ///
    /// Both cases are read off the *same bytes*: the fixture as Apple shipped
    /// it, and a copy re-signed here. Nothing but the signature differs between
    /// the two, so a reader that took the page size from the architecture, the
    /// file size or a constant would have to get one of them wrong.
    @Test(.enabled(if: MachOFixture.runs, MachOFixture.missing))
    func `page size comes from the code directory`() throws {
        let shipped = try Data(contentsOf: MachOFixture.signedBinary())
        let directory = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: shipped)?.first)
        #expect(directory.pageSize == 1 << Int(directory.pageSizeLog2))
        #expect(directory.pageSize == 4096, "the shipped iOS signature uses 4 KiB pages")
        #expect(directory.hashType == CustomFirmwareMachOCodeSignature.hashTypeSHA256)
        #expect(directory.hashSize == SHA256.byteCount)
    }

    /// The other half of the same claim, and the one a constant gets wrong: the
    /// host signer covers the very same file with 16 KiB pages.
    @Test(.enabled(if: MachOFixture.runs && MachOFixture.hasCodesign, MachOFixture.missing))
    func `page size follows whoever signed the file`() throws {
        let shipped = try Data(contentsOf: MachOFixture.signedBinary())
        let iOSDirectory = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: shipped)?.first)

        let file = try MachOFixture.scratchCopy("pagesize")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let signing = try MachOFixture.run(
            URL(filePath: "/usr/bin/codesign"),
            ["-f", "-s", "-", "--digest-algorithm=sha256", file.path],
        )
        try #require(signing.status == 0, "could not re-sign the fixture: \(signing.output)")

        let hostDirectory = try #require(
            try CustomFirmwareMachOCodeSignature.codeDirectories(in: Data(contentsOf: file))?.first,
        )
        #expect(hostDirectory.pageSize == 1 << Int(hostDirectory.pageSizeLog2))
        #expect(hostDirectory.pageSize == 16384, "the host signer uses 16 KiB pages")
        #expect(
            hostDirectory.pageSize != iOSDirectory.pageSize,
            "one file, two page sizes — the whole point of reading it from the CD",
        )
        // Same code, so the same codeLimit, covered by a quarter as many slots.
        #expect(hostDirectory.codeLimit == iOSDirectory.codeLimit)
        #expect(hostDirectory.codeSlotCount < iOSDirectory.codeSlotCount)
    }

    @Test func `unsigned data is rejected`() {
        var data = Data(repeating: 0, count: 4096)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: [0])
        }
    }

    @Test func `no offsets is A no op`() throws {
        var data = Data(repeating: 0, count: 16)
        #expect(try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: []).isEmpty)
    }

    @Test(.enabled(if: MachOFixture.runs, MachOFixture.missing))
    func `unchanged pages are not rewritten`() throws {
        let file = try MachOFixture.scratchCopy("untouched")
        // Nothing was modified, so every slot already matches and no write happens.
        let records = try CustomFirmwareMachOCodeSignature.reattest(fileAt: file, modifiedOffsets: [0, 4096, 8192])
        #expect(records.isEmpty)
        #expect(try Data(contentsOf: file) == Data(contentsOf: MachOFixture.signedBinary()))
    }

    // MARK: Multiple code directories

    /// A binary with a legacy SHA-1 alt-CD alongside the SHA-256 one. Only the
    /// SHA-256 CD is recomputed; the SHA-1 CD is left byte-for-byte alone and
    /// reported, which is what `unsupportedCodeDirectories(in:)` is for.
    @Test(.enabled(if: MachOFixture.runs && MachOFixture.hasCodesign, MachOFixture.missing))
    func `only SHA 256 code directories are updated`() throws {
        let file = try MachOFixture.scratchCopy("dual")
        let signing = try MachOFixture.run(
            URL(filePath: "/usr/bin/codesign"),
            ["-f", "-s", "-", "--digest-algorithm=sha1,sha256", file.path],
        )
        try #require(signing.status == 0, "could not build a dual-CD fixture: \(signing.output)")

        let before = try Data(contentsOf: file)
        let directories = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: before))
        try #require(directories.count == 2)
        let legacy = try #require(directories.first { $0.hashType == CustomFirmwareMachOCodeSignature.hashTypeSHA1 })
        let modern = try #require(directories.first { $0.hashType == CustomFirmwareMachOCodeSignature.hashTypeSHA256 })
        #expect(CustomFirmwareMachOCodeSignature.unsupportedCodeDirectories(in: before).map(\.offset) == [legacy.offset])

        try MachOFixture.flipByte(at: 16, in: file)
        let records = try CustomFirmwareMachOCodeSignature.reattest(fileAt: file, modifiedOffsets: [16])
        #expect(records.allSatisfy { $0.codeDirectoryOffset == modern.offset })

        let after = try Data(contentsOf: file)
        let legacyRange = legacy.offset ..< legacy.offset + legacy.length
        #expect(after[legacyRange] == before[legacyRange], "the SHA-1 CD must be untouched")
    }

    // MARK: Cross-check against the frozen Python

    /// The plan's P1.1 gate: the Swift and the Python must produce the same
    /// file, byte for byte, from the same input and the same offsets.
    ///
    /// The whole experiment is derived from the code directory, not typed in,
    /// and then each derived value is checked against what the frozen run used
    /// — so a fixture that drifted fails on the offsets rather than silently
    /// comparing a different experiment's digest.
    @Test(.enabled(if: MachOFixture.runs, MachOFixture.missing))
    func `matches the frozen python reattester`() throws {
        let pristine = try MachOFixture.signedBinary()
        try #require(
            try MachOFixture.digest(of: pristine) == MachOCodeSignGolden.pristine,
            """
            this is not the 24A435 seputil MachOCodeSignGolden was recorded \
            from — re-derive the golden before reading a failure here as a bug
            """,
        )

        let data = try Data(contentsOf: pristine)
        let directory = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: data)?.first)
        // First page, a middle page, the short tail page, and one offset past
        // codeLimit that both implementations must ignore.
        let offsets = [
            16,
            (directory.codeSlotCount / 2) * directory.pageSize + 7,
            directory.codeLimit - 1,
            directory.codeLimit + 8,
        ]
        #expect(offsets == MachOCodeSignGolden.offsets)
        #expect(directory.codeLimit == MachOCodeSignGolden.codeLimit)

        let swiftFile = try MachOFixture.scratchCopy("swift", of: pristine)
        defer { try? FileManager.default.removeItem(at: swiftFile.deletingLastPathComponent()) }
        // Only the covered offsets are actually modified — the one past
        // codeLimit lands in the signature blob itself, and corrupting that
        // would be testing the parser's behaviour on garbage rather than the
        // agreement between the two implementations.
        for offset in offsets where offset < directory.codeLimit {
            try MachOFixture.flipByte(at: offset, in: swiftFile)
        }

        let records = try CustomFirmwareMachOCodeSignature.reattest(fileAt: swiftFile, modifiedOffsets: offsets)
        #expect(records.contains { $0.isTailSlot }, "the offset set must exercise the tail slot")
        #expect(records.map(\.pageIndex).sorted() == MachOCodeSignGolden.rewrittenSlots)

        #expect(
            try MachOFixture.digest(of: swiftFile) == MachOCodeSignGolden.reattested,
            "Swift and the frozen Python re-attestation must agree byte for byte",
        )
    }
}

// MARK: - The frozen re-attestation reference

/// What `scripts/patchers/cfw_macho_codesign.py` produced, recorded before it
/// was deleted.
///
/// Taken at repo commit `78cbeea` with `.venv/bin/python3`, over the real iOS
/// 27.0 / 24A435 / iPhone17,3 `seputil` whose digest is ``pristine``:
///
/// ```
/// .venv/bin/python3 - <<'PY'
/// import sys; sys.path.insert(0, "scripts/patchers")
/// import cfw_macho_codesign as r
/// p = "<clone of ipsws/ref_extract/macho_pristine/seputil>"
/// offsets = [16, 90119, 183887, 183896]        # codeLimit is 183888
/// d = bytearray(open(p, "rb").read())
/// for o in offsets:
///     if o < 183888: d[o] ^= 0xFF
/// open(p, "wb").write(bytes(d))
/// r.reattest_modified_offsets(p, offsets, verbose=True)
/// PY
/// ```
///
/// which printed `file off 0x2CE58 past codeLimit 0x2CE50 — skipping` and then
/// `wrote cd_index=0 slot 0`, `slot 22`, `slot 44 [tail, 3664B]`.
private enum MachOCodeSignGolden {
    /// `shasum -a 256 ipsws/ref_extract/macho_pristine/seputil`
    static let pristine = "13e40e74d92928cf9e36fae75970dfcf4c0a4c1040eeac39d1c335407e841474"

    /// The four offsets above, and the codeLimit the last two straddle.
    static let offsets = [16, 90119, 183_887, 183_896]
    static let codeLimit = 183_888

    /// The three slots the reference rewrote; the fourth offset was skipped.
    static let rewrittenSlots = [0, 22, 44]

    /// `shasum -a 256` of the file that run left behind.
    static let reattested = "554de26a946547253a04c844e28acdc271b92c701322187e51d0b1d900fa4b1b"
}

// MARK: - Dylib Injection

@Suite("LC_LOAD_DYLIB injection")
struct CustomFirmwareInjectDylibTests {
    /// What `cfw_install_jb.sh` does to launchd, minus ldid: the weak load of
    /// `/b` has to appear and the header has to grow to match.
    @Test(.enabled(if: MachOFixture.runs, MachOFixture.missing))
    func `inserts A weak load command`() throws {
        let file = try MachOFixture.scratchCopy("weak")
        let before = try Data(contentsOf: file)
        let injections = try CustomFirmwareInjectDylib.inject(dylibPath: "/b", into: file)
        let injection = try #require(injections.first)
        #expect(injections.count == 1)
        #expect(injection.isWeak)
        #expect(injection.removedCodeSignature)
        // "/b" is 2 bytes, padded to 8, after the 24-byte dylib_command.
        #expect(injection.loadCommandSize == 32)

        let after = try Data(contentsOf: file)
        let loads = MachOFixture.dylibLoadCommands(in: after)
        #expect(loads.contains { $0.path == "/b" && $0.command == 0x8000_0018 })
        #expect(!MachOFixture.dylibLoadCommands(in: before).contains { $0.path == "/b" })

        #expect(after.loadLE(UInt32.self, at: 16) == before.loadLE(UInt32.self, at: 16))
        // One LC_CODE_SIGNATURE out, one LC_LOAD_WEAK_DYLIB in: ncmds is
        // unchanged and sizeofcmds moves by the difference of the two sizes.
        let sizeBefore = before.loadLE(UInt32.self, at: 20)
        let sizeAfter = after.loadLE(UInt32.self, at: 20)
        #expect(sizeAfter == sizeBefore + 32 - 16)
        #expect(after.count < before.count, "stripping the signature must shorten the file")
    }

    /// The other policy: keep the signature and re-hash what the insertion
    /// touched, so the binary stays verifiable with no external signer. This is
    /// the one path that exercises both halves of this work together.
    ///
    /// Keeping the signature means the command cannot reclaim the 16 bytes a
    /// stripped LC_CODE_SIGNATURE would free, so it has to fit in the padding
    /// as shipped — 32 bytes in this fixture, for a 32-byte command.
    @Test(.enabled(if: MachOFixture.runs, MachOFixture.missing))
    func `keeping the signature rehashes the header page`() throws {
        let file = try MachOFixture.scratchCopy("keep")
        let before = try Data(contentsOf: file)
        let injection = try #require(try CustomFirmwareInjectDylib.inject(
            dylibPath: "/b",
            into: file,
            policy: .keepAndReattest,
        ).first)
        #expect(!injection.removedCodeSignature)
        #expect(injection.rehashedSlots.map(\.pageIndex) == [0])

        let after = try Data(contentsOf: file)
        #expect(after.count == before.count, "keeping the signature must not resize the file")
        #expect(MachOFixture.dylibLoadCommands(in: after).contains { $0.path == "/b" })

        let directory = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: after)?.first)
        let range = try #require(directory.slotRange(0))
        let slot = directory.slotHashOffset(0)
        #expect(after[slot ..< slot + directory.hashSize] == Data(SHA256.hash(data: after[range])))
    }

    /// `insert_dylib --all-yes` answers "yes" to "there is not enough empty
    /// space" and writes the command over the first section. Refusing is the
    /// deliberate difference; this pins it.
    @Test(.enabled(if: MachOFixture.runs, MachOFixture.missing))
    func `refuses to overwrite occupied padding`() throws {
        let file = try MachOFixture.scratchCopy("occupied")
        var data = try Data(contentsOf: file)
        let sizeofcmds = Int(data.loadLE(UInt32.self, at: 20))
        data[32 + sizeofcmds] = 0xFF // first byte past the load commands
        try data.write(to: file)

        #expect(throws: PatcherError.self) {
            try CustomFirmwareInjectDylib.inject(dylibPath: "/b", into: file)
        }
        // …and the opt-out still works, for a caller that knows better.
        #expect(throws: Never.self) {
            try CustomFirmwareInjectDylib.inject(dylibPath: "/b", into: file, allowNonEmptyPadding: true)
        }
    }

    @Test func `rejects what it cannot handle`() {
        var empty = Data([0xCA, 0xFE, 0xBA, 0xBF, 0, 0, 0, 1])
        #expect(throws: PatcherError.self) {
            try CustomFirmwareInjectDylib.inject(dylibPath: "/b", into: &empty)
        }
        var garbage = Data(repeating: 0xAB, count: 512)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareInjectDylib.inject(dylibPath: "/b", into: &garbage)
        }
    }

    /// Compile both checked-in sources, then prove that the inserted load
    /// command actually makes dyld run the swizzle before main().
    @Test func `injected Objective-C swizzle changes hello world output`() throws {
        let fixtures = MachOFixture.repositoryRoot
            .appending(path: "Tests/FirmwarePatcherTests/Fixtures/DylibInjection")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DylibInjection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appending(path: "hello")
        let dylib = directory.appending(path: "swizzle.dylib")
        let clang = URL(filePath: "/usr/bin/clang")

        let buildExecutable = try MachOFixture.run(clang, [
            "-fobjc-arc", "-framework", "Foundation", "-Wl,-headerpad,0x4000",
            fixtures.appending(path: "hello.m").path, "-o", executable.path,
        ])
        try #require(buildExecutable.status == 0, "hello fixture: \(buildExecutable.output)")
        let buildDylib = try MachOFixture.run(clang, [
            "-dynamiclib", "-fobjc-arc", "-framework", "Foundation",
            fixtures.appending(path: "swizzle.m").path, "-o", dylib.path,
        ])
        try #require(buildDylib.status == 0, "swizzle fixture: \(buildDylib.output)")

        let before = try MachOFixture.run(executable, [])
        try #require(before.status == 0, "plain hello failed: \(before.output)")
        #expect(before.output == "hello world\n")

        let injections = try CustomFirmwareInjectDylib.inject(
            dylibPath: dylib.path,
            into: executable,
            weak: true,
            policy: .strip,
        )
        let injection = try #require(injections.first)
        #expect(injections.count == 1)
        #expect(injection.isWeak)
        #expect(MachOFixture.dylibLoadCommands(in: try Data(contentsOf: executable)).contains {
            $0.command == 0x8000_0018 && $0.path == dylib.path
        })

        let sign = try MachOFixture.run(URL(filePath: "/usr/bin/codesign"), [
            "--force", "--sign", "-", "--timestamp=none", executable.path,
        ])
        try #require(sign.status == 0, "signing injected hello: \(sign.output)")
        let after = try MachOFixture.run(executable, [])
        try #require(after.status == 0, "injected hello failed: \(after.output)")
        #expect(after.output == "world hello\n")
    }
}
