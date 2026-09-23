// CFWMachOTests.swift — Mach-O load-command insertion and code-signature re-attestation.
//
// Both modules replace something outside this code, so both are tested against
// it rather than against expectations written down by hand:
//
//   * `CFWInjectDylib` against `.tools/bin/insert_dylib`, byte for byte, while
//     that submodule build is still in the tree.
//   * `CFWMachOCodeSignature` against `scripts/patchers/cfw_macho_codesign.py`,
//     byte for byte. That Python is gone, so what it wrote is frozen in
//     ``MachOCodeSignGolden`` below — over the real 24A435 `seputil` rather
//     than a local build product, because a golden is only worth what its
//     input is reproducible.
//
// Those two comparisons are the migration plan's stated gate (P1.1). Everything
// that can be asserted without a reference is asserted unconditionally, first
// among them the short tail slot, which is the known regression in independent
// re-signing.

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

    /// A real, adhoc-signed, thin arm64 Mach-O with a non-page-aligned
    /// codeLimit — the shape that produces a short tail slot.
    static let signedBinary = repositoryRoot.appending(path: ".build/release/vphone-letmein")
    static let insertDylib = repositoryRoot.appending(path: ".tools/bin/insert_dylib")

    /// The real 24A435 `seputil`: ad-hoc signed, arm64e, SHA-256 CD, and a
    /// codeLimit that is not page aligned. Unlike ``signedBinary`` it does not
    /// change between builds, which is what makes a frozen digest mean
    /// anything. Not in the repo — `ipsws/` never is.
    static let pristineSeputil = repositoryRoot
        .appending(path: "ipsws/ref_extract/macho_pristine/seputil")

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static var hasSignedBinary: Bool { exists(signedBinary) }
    static var hasInsertDylib: Bool { exists(insertDylib) }
    static var hasPristineSeputil: Bool { exists(pristineSeputil) }
    static var hasCodesign: Bool { exists(URL(filePath: "/usr/bin/codesign")) }

    /// SHA-256 as `shasum -a 256` prints it.
    static func digest(of url: URL) throws -> String {
        Data(SHA256.hash(data: try Data(contentsOf: url))).hex
    }

    /// A private copy of `source` that the caller may modify freely.
    static func scratchCopy(_ name: String, of source: URL? = nil) throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "CFWMachOTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: source ?? signedBinary, to: destination)
        // Both sources are 0755 already; this is only so a reference tree
        // someone made read-only does not turn into a failing patch test.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: destination.path
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
struct CFWMachOCodeSignatureTests {
    // MARK: Tail slot

    /// The regression this module exists to not repeat.
    ///
    /// The last code slot covers `codeLimit - slotStart` bytes, not a whole
    /// page. Hashing a full page there — or anything else — produces a binary
    /// that TXM kills the first time that page is faulted in, and nothing about
    /// the file looks wrong until then.
    @Test(.enabled(if: MachOFixture.hasSignedBinary))
    func tailSlotHashesOnlyUpToCodeLimit() throws {
        let data = try Data(contentsOf: MachOFixture.signedBinary)
        let directory = try #require(CFWMachOCodeSignature.codeDirectories(in: data)?.first)

        let lastSlot = directory.codeSlotCount - 1
        let range = try #require(directory.slotRange(lastSlot))
        #expect(range.upperBound == directory.codeLimit)
        #expect(range.count == directory.codeLimit - lastSlot * directory.pageSize)
        #expect(range.count < directory.pageSize, "fixture must have a non-page-aligned codeLimit")

        // Re-attest a change inside the tail page and check the hash that lands
        // in the slot against one computed here from the short range.
        let file = try MachOFixture.scratchCopy("tail")
        try MachOFixture.flipByte(at: directory.codeLimit - 1, in: file)
        let records = try CFWMachOCodeSignature.reattest(
            fileAt: file,
            modifiedOffsets: [directory.codeLimit - 1]
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
            "the slot on disk must hold the hash of the short range"
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
    @Test func slotRangesFollowCodeLimitAlignment() {
        let aligned = CFWCodeDirectory(
            slotType: 0, offset: 0, length: 0, hashOffset: 0, hashSize: 32,
            hashType: 2, pageSize: 4096, pageSizeLog2: 12,
            codeSlotCount: 2, codeLimit: 8192
        )
        #expect(aligned.slotRange(0) == 0 ..< 4096)
        #expect(aligned.slotRange(1) == 4096 ..< 8192)
        #expect(aligned.slotRange(2) == nil)

        let short = CFWCodeDirectory(
            slotType: 0, offset: 0, length: 0, hashOffset: 0, hashSize: 32,
            hashType: 2, pageSize: 4096, pageSizeLog2: 12,
            codeSlotCount: 2, codeLimit: 5000
        )
        #expect(short.slotRange(0) == 0 ..< 4096)
        #expect(short.slotRange(1) == 4096 ..< 5000)
    }

    @Test func offsetsPastCodeLimitBelongToNoSlot() {
        #expect(CFWMachOCodeSignature.pageBounds(fileOffset: 4095, pageSize: 4096, codeLimit: 5000)?.index == 0)
        #expect(CFWMachOCodeSignature.pageBounds(fileOffset: 4999, pageSize: 4096, codeLimit: 5000)?.end == 5000)
        #expect(CFWMachOCodeSignature.pageBounds(fileOffset: 5000, pageSize: 4096, codeLimit: 5000) == nil)
    }

    // MARK: Page size

    /// The page size comes from the CD, never from a constant. The plan records
    /// 4 KiB for the iOS binaries this pipeline patches, but arm64e binaries on
    /// the build host use 16 KiB, and a hard-coded 4096 silently hashes the
    /// wrong ranges on those.
    @Test(.enabled(if: MachOFixture.hasSignedBinary))
    func pageSizeComesFromTheCodeDirectory() throws {
        let data = try Data(contentsOf: MachOFixture.signedBinary)
        let directory = try #require(CFWMachOCodeSignature.codeDirectories(in: data)?.first)
        #expect(directory.pageSize == 1 << Int(directory.pageSizeLog2))
        #expect(directory.hashType == CFWMachOCodeSignature.hashTypeSHA256)
        #expect(directory.hashSize == SHA256.byteCount)
    }

    @Test func unsignedDataIsRejected() {
        var data = Data(repeating: 0, count: 4096)
        #expect(throws: PatcherError.self) {
            try CFWMachOCodeSignature.reattest(&data, modifiedOffsets: [0])
        }
    }

    @Test func noOffsetsIsANoOp() throws {
        var data = Data(repeating: 0, count: 16)
        #expect(try CFWMachOCodeSignature.reattest(&data, modifiedOffsets: []).isEmpty)
    }

    @Test(.enabled(if: MachOFixture.hasSignedBinary))
    func unchangedPagesAreNotRewritten() throws {
        let file = try MachOFixture.scratchCopy("untouched")
        // Nothing was modified, so every slot already matches and no write happens.
        let records = try CFWMachOCodeSignature.reattest(fileAt: file, modifiedOffsets: [0, 4096, 8192])
        #expect(records.isEmpty)
        #expect(try Data(contentsOf: file) == (try Data(contentsOf: MachOFixture.signedBinary)))
    }

    // MARK: Multiple code directories

    /// A binary with a legacy SHA-1 alt-CD alongside the SHA-256 one. Only the
    /// SHA-256 CD is recomputed; the SHA-1 CD is left byte-for-byte alone and
    /// reported, which is what `unsupportedCodeDirectories(in:)` is for.
    @Test(.enabled(if: MachOFixture.hasSignedBinary && MachOFixture.hasCodesign))
    func onlySHA256CodeDirectoriesAreUpdated() throws {
        let file = try MachOFixture.scratchCopy("dual")
        let signing = try MachOFixture.run(
            URL(filePath: "/usr/bin/codesign"),
            ["-f", "-s", "-", "--digest-algorithm=sha1,sha256", file.path]
        )
        try #require(signing.status == 0, "could not build a dual-CD fixture: \(signing.output)")

        let before = try Data(contentsOf: file)
        let directories = try #require(CFWMachOCodeSignature.codeDirectories(in: before))
        try #require(directories.count == 2)
        let legacy = try #require(directories.first { $0.hashType == CFWMachOCodeSignature.hashTypeSHA1 })
        let modern = try #require(directories.first { $0.hashType == CFWMachOCodeSignature.hashTypeSHA256 })
        #expect(CFWMachOCodeSignature.unsupportedCodeDirectories(in: before).map(\.offset) == [legacy.offset])

        try MachOFixture.flipByte(at: 16, in: file)
        let records = try CFWMachOCodeSignature.reattest(fileAt: file, modifiedOffsets: [16])
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
    @Test(.enabled(if: MachOFixture.hasPristineSeputil))
    func matchesTheFrozenPythonReattester() throws {
        try #require(
            try MachOFixture.digest(of: MachOFixture.pristineSeputil)
                == MachOCodeSignGolden.pristine,
            """
            this is not the 24A435 seputil MachOCodeSignGolden was recorded \
            from — re-derive the golden before reading a failure here as a bug
            """
        )

        let data = try Data(contentsOf: MachOFixture.pristineSeputil)
        let directory = try #require(CFWMachOCodeSignature.codeDirectories(in: data)?.first)
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

        let swiftFile = try MachOFixture.scratchCopy("swift", of: MachOFixture.pristineSeputil)
        defer { try? FileManager.default.removeItem(at: swiftFile.deletingLastPathComponent()) }
        // Only the covered offsets are actually modified — the one past
        // codeLimit lands in the signature blob itself, and corrupting that
        // would be testing the parser's behaviour on garbage rather than the
        // agreement between the two implementations.
        for offset in offsets where offset < directory.codeLimit {
            try MachOFixture.flipByte(at: offset, in: swiftFile)
        }

        let records = try CFWMachOCodeSignature.reattest(fileAt: swiftFile, modifiedOffsets: offsets)
        #expect(records.contains { $0.isTailSlot }, "the offset set must exercise the tail slot")
        #expect(records.map(\.pageIndex).sorted() == MachOCodeSignGolden.rewrittenSlots)

        #expect(
            try MachOFixture.digest(of: swiftFile) == MachOCodeSignGolden.reattested,
            "Swift and the frozen Python re-attestation must agree byte for byte"
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
    static let offsets = [16, 90_119, 183_887, 183_896]
    static let codeLimit = 183_888

    /// The three slots the reference rewrote; the fourth offset was skipped.
    static let rewrittenSlots = [0, 22, 44]

    /// `shasum -a 256` of the file that run left behind.
    static let reattested = "554de26a946547253a04c844e28acdc271b92c701322187e51d0b1d900fa4b1b"
}

// MARK: - Dylib Injection

@Suite("LC_LOAD_DYLIB injection")
struct CFWInjectDylibTests {
    /// What `cfw_install_jb.sh` does to launchd, minus ldid: the weak load of
    /// `/b` has to appear and the header has to grow to match.
    @Test(.enabled(if: MachOFixture.hasSignedBinary))
    func insertsAWeakLoadCommand() throws {
        let file = try MachOFixture.scratchCopy("weak")
        let before = try Data(contentsOf: file)
        let injections = try CFWInjectDylib.inject(dylibPath: "/b", into: file)
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
    @Test(.enabled(if: MachOFixture.hasSignedBinary))
    func keepingTheSignatureRehashesTheHeaderPage() throws {
        let file = try MachOFixture.scratchCopy("keep")
        let before = try Data(contentsOf: file)
        let injection = try #require(try CFWInjectDylib.inject(
            dylibPath: "/b",
            into: file,
            policy: .keepAndReattest
        ).first)
        #expect(!injection.removedCodeSignature)
        #expect(injection.rehashedSlots.map(\.pageIndex) == [0])

        let after = try Data(contentsOf: file)
        #expect(after.count == before.count, "keeping the signature must not resize the file")
        #expect(MachOFixture.dylibLoadCommands(in: after).contains { $0.path == "/b" })

        let directory = try #require(CFWMachOCodeSignature.codeDirectories(in: after)?.first)
        let range = try #require(directory.slotRange(0))
        let slot = directory.slotHashOffset(0)
        #expect(after[slot ..< slot + directory.hashSize] == Data(SHA256.hash(data: after[range])))
    }

    /// `insert_dylib --all-yes` answers "yes" to "there is not enough empty
    /// space" and writes the command over the first section. Refusing is the
    /// deliberate difference; this pins it.
    @Test(.enabled(if: MachOFixture.hasSignedBinary))
    func refusesToOverwriteOccupiedPadding() throws {
        let file = try MachOFixture.scratchCopy("occupied")
        var data = try Data(contentsOf: file)
        let sizeofcmds = Int(data.loadLE(UInt32.self, at: 20))
        data[32 + sizeofcmds] = 0xFF // first byte past the load commands
        try data.write(to: file)

        #expect(throws: PatcherError.self) {
            try CFWInjectDylib.inject(dylibPath: "/b", into: file)
        }
        // …and the opt-out still works, for a caller that knows better.
        #expect(throws: Never.self) {
            try CFWInjectDylib.inject(dylibPath: "/b", into: file, allowNonEmptyPadding: true)
        }
    }

    @Test func rejectsWhatItCannotHandle() {
        var empty = Data([0xCA, 0xFE, 0xBA, 0xBF, 0, 0, 0, 1])
        #expect(throws: PatcherError.self) {
            try CFWInjectDylib.inject(dylibPath: "/b", into: &empty)
        }
        var garbage = Data(repeating: 0xAB, count: 512)
        #expect(throws: PatcherError.self) {
            try CFWInjectDylib.inject(dylibPath: "/b", into: &garbage)
        }
    }

    /// The migration gate for this half: identical output to the C tool it
    /// replaces, on the exact command line the CFW scripts use.
    @Test(.enabled(if: MachOFixture.hasSignedBinary && MachOFixture.hasInsertDylib))
    func matchesInsertDylib() throws {
        let swiftFile = try MachOFixture.scratchCopy("swift")
        let referenceFile = swiftFile.deletingLastPathComponent().appending(path: "reference")
        try FileManager.default.copyItem(at: MachOFixture.signedBinary, to: referenceFile)

        try CFWInjectDylib.inject(dylibPath: "/b", into: swiftFile)
        let reference = try MachOFixture.run(
            MachOFixture.insertDylib,
            ["--weak", "--inplace", "--all-yes", "/b", referenceFile.path]
        )
        try #require(reference.status == 0, "insert_dylib failed: \(reference.output)")

        #expect(
            try Data(contentsOf: swiftFile) == (try Data(contentsOf: referenceFile)),
            "Swift injection must match insert_dylib byte for byte"
        )
    }
}
