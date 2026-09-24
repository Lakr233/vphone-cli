// CFWSeputilTests.swift — Parity cross-checks for `CFWSeputil`.
//
// Two independent references, and every claim below is measured against one of
// them rather than against a number written down by hand:
//
//   * `scripts/patchers/cfw_patch_seputil.py`, driven through the exact CLI
//     `scripts/cfw_install.sh` called — `cfw.py patch-seputil <binary>`. That
//     Python is gone; what it produced on this fixture is frozen in
//     ``SeputilGolden`` below, digest by digest, so the comparison survives it.
//     The Swift patcher run with `reattest: false` must reproduce the digest of
//     the file the Python wrote, and run with re-attestation on it must
//     reproduce the digest of that same file put through the Python's own
//     re-attester (`cfw_macho_codesign.reattest_modified_offsets`). The second
//     digest is what proves the slot hashes agree: it covers the hashes where
//     they live, in the file, not values this module reported about itself.
//   * `/usr/bin/codesign -v`, which for a standalone Mach-O is a real second
//     opinion on whether the signature still covers the file. The test asserts
//     both directions — the re-attested binary verifies and the one that
//     matches the frozen Python digest does not — so a `codesign` that passed
//     everything would fail this suite instead of quietly blessing it.
//
// The fixture is the real 24A435 / iPhone17,3 `seputil`. Point
// `VPHONE_MACHO_PRISTINE` at a directory of pristine Mach-O binaries or leave
// the default `ipsws/ref_extract/macho_pristine` in place.
//
// Without it these FAIL, following `DSCFoundationTests`: a `guard … else
// { return }` is reported by Swift Testing as a pass, so a green run on a
// machine with no fixture would be indistinguishable from a green run that
// proved something. Set `VPHONE_MACHO_FIXTURE_OPTIONAL=1` to turn that failure
// into a visible skip.
//
// Nothing here writes anywhere under `ipsws/ref_extract/`: that tree is the
// pristine reference the whole suite compares against. Clones land in
// `ipsws/scratch_cfwseputil/`, on the same filesystem, so `cp -c` is a
// `clonefile(2)`.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum SeputilFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let binaryName = "seputil"

    /// The read-only reference binary.
    static var pristine: URL? {
        let directory = ProcessInfo.processInfo.environment["VPHONE_MACHO_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/macho_pristine")
        let binary = directory.appendingPathComponent(binaryName)
        return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
    }

    /// Opt-out for a machine that does not carry the extracted IPSW.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_MACHO_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suite runs unless the binary is absent *and* the caller opted out.
    static var runs: Bool {
        pristine != nil || !isOptional
    }

    static let missing: Comment = """
    the real 24A435 iPhone17,3 seputil is required — put it at \
    ipsws/ref_extract/macho_pristine/seputil, point VPHONE_MACHO_PRISTINE at \
    the directory holding it, or set VPHONE_MACHO_FIXTURE_OPTIONAL=1 to skip \
    these tests instead of failing
    """

    static let skipReason: Comment =
        "VPHONE_MACHO_FIXTURE_OPTIONAL=1 and no macho_pristine/seputil fixture present"

    /// Where clones are made. Same filesystem as the repo, and deliberately
    /// *not* under `ipsws/ref_extract/`.
    static var scratchRoot: URL {
        repoRoot.appendingPathComponent("ipsws/scratch_cfwseputil")
    }

    /// SHA-256 as `shasum -a 256` prints it, so a digest asserted here can be
    /// taken again from a shell over the same file.
    static func digest(of url: URL) throws -> String {
        try Data(SHA256.hash(data: Data(contentsOf: url))).hex
    }

    static var codesign: URL? {
        let url = URL(fileURLWithPath: "/usr/bin/codesign")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A private clone of the pristine binary the caller may write to.
    static func clone(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: scratchRoot,
            withIntermediateDirectories: true,
        )
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)

        var result = try Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", pristine.path, destination.path],
        )
        if result.status != 0 {
            // A fixture on another volume cannot be cloned. Copying is slower
            // but correct, and a refusal here would look like a patch bug.
            result = try Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: [pristine.path, destination.path],
            )
        }
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }

    /// Discard clones, and the scratch root with them once the last one is
    /// gone, so a test run leaves the working tree as it found it.
    static func discard(_ clones: URL...) {
        for clone in clones {
            try? FileManager.default.removeItem(at: clone)
        }
        let remaining = (try? FileManager.default
            .contentsOfDirectory(atPath: scratchRoot.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
    }
}

// MARK: - Subprocess helper

private enum Subprocess {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(executable: URL, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting, or a full pipe buffer deadlocks the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
        )
    }
}

// MARK: - The frozen reference

/// What `scripts/patchers/` produced on this fixture, recorded before it was
/// deleted.
///
/// Every digest below was taken at repo commit `78cbeea`, with
/// `.venv/bin/python3` driving `scripts/patchers/`, over the real iOS 27.0 /
/// 24A435 / iPhone17,3 `seputil` whose own digest is ``pristine``. The exact
/// command that produced each one is on the constant.
private enum SeputilGolden {
    /// `shasum -a 256 ipsws/ref_extract/macho_pristine/seputil`
    static let pristine = "13e40e74d92928cf9e36fae75970dfcf4c0a4c1040eeac39d1c335407e841474"

    /// `.venv/bin/python3 scripts/patchers/cfw.py patch-seputil <clone of seputil>`
    /// — the patch alone, signature left stale, which is what `cfw_install.sh`
    /// ran before handing the file to `ldid_sign`.
    static let patched = "75dc86f8d0668e5d06ce90111f416c058a0e57f21fa55e5f6330f67ec8d0e8b2"

    /// The bytes the Python changed, from a byte diff of ``patched`` against
    /// ``pristine``: `%s` -> `AA` at 0x1BDD2, and nothing else in the file.
    static let modifiedOffsets = [0x1BDD2, 0x1BDD3]

    /// ``patched``, then
    /// `.venv/bin/python3 -c 'import sys; sys.path.insert(0, "scripts/patchers");
    /// import cfw_macho_codesign as r;
    /// r.reattest_modified_offsets(sys.argv[1], [114130, 114131], verbose=True)'`
    /// — which reported `wrote cd_index=0 slot 27 (345f649b.. -> a6df3073..)`.
    static let patchedAndReattested =
        "01b4dd86b44c867dc9d94339eea34dcf64de37e7dbd85997f040831dca6afd0b"

    /// The one code slot that re-attestation rewrote.
    static let reattestedSlot = 27
}

// MARK: - Parity against the reference implementations

@Suite("seputil gigalocker name", .enabled(if: SeputilFixture.runs, SeputilFixture.skipReason))
struct CFWSeputilParityTests {
    /// The fixture the frozen digests were taken over. Without this the two
    /// tests below would report a digest mismatch when the real cause is a
    /// different firmware's `seputil`.
    @Test func `fixture is the one the goldens were taken from`() throws {
        let pristine = try #require(SeputilFixture.pristine, SeputilFixture.missing)
        #expect(
            try SeputilFixture.digest(of: pristine) == SeputilGolden.pristine,
            """
            this is not the 24A435 iPhone17,3 seputil the goldens in \
            SeputilGolden were recorded from — re-derive them before reading a \
            failure below as a patcher bug
            """,
        )
    }

    /// The plan's P1.2 gate: same input, same bytes out.
    ///
    /// Run with `reattest: false`, which was the reference's own behaviour —
    /// `cfw_install.sh` re-signs with `ldid` right after, so the Python left
    /// the signature stale.
    @Test func `matches the frozen reference patch`() throws {
        let pristine = try #require(SeputilFixture.pristine, SeputilFixture.missing)
        let swiftFile = try SeputilFixture.clone(named: "swift-plain")
        defer { SeputilFixture.discard(swiftFile) }

        let outcome = try CFWSeputil.patch(fileAt: swiftFile, reattest: false, log: nil)

        #expect(outcome.verdict == .patched)
        #expect(
            try SeputilFixture.digest(of: swiftFile) == SeputilGolden.patched,
            "Swift must reproduce the seputil the reference wrote, byte for byte",
        )
        // The same two bytes, at the same two offsets, that the reference moved.
        #expect(outcome.site.modifiedOffsets == SeputilGolden.modifiedOffsets)

        // And the comparison is not two copies of the input: the file moved.
        #expect(try SeputilFixture.digest(of: swiftFile) != SeputilGolden.pristine)
        #expect(try Data(contentsOf: swiftFile) != Data(contentsOf: pristine))
    }

    /// The same for the whole pipeline, re-attestation included. The Python
    /// had no re-attesting seputil patcher, so the frozen digest is of the two
    /// Python modules composed the way the install script composed them.
    ///
    /// This is the slot-hash comparison: the hashes are covered where they
    /// live, in the file, by a digest of what the reference implementation
    /// computed.
    @Test func `matches the frozen reference plus its own reattester`() throws {
        let swiftFile = try SeputilFixture.clone(named: "swift-full")
        defer { SeputilFixture.discard(swiftFile) }

        let outcome = try CFWSeputil.patch(fileAt: swiftFile, log: nil)

        #expect(outcome.rehashes.count == 1, "one page was dirtied, so one slot is rewritten")
        #expect(outcome.rehashes.first?.pageIndex == SeputilGolden.reattestedSlot)
        #expect(
            try SeputilFixture.digest(of: swiftFile) == SeputilGolden.patchedAndReattested,
            "the re-attested slot hash must be the one the reference computed",
        )
    }

    /// `codesign -v`, in both directions. The re-attested binary verifies; the
    /// one that reproduces the frozen Python bytes does not, which is why
    /// `cfw_install.sh` had to run `ldid_sign` after the Python.
    @Test func `reattestation is what makes the binary verify`() throws {
        let codesign = try #require(SeputilFixture.codesign)
        let pristine = try #require(SeputilFixture.pristine, SeputilFixture.missing)
        let reattested = try SeputilFixture.clone(named: "swift-verify")
        let stale = try SeputilFixture.clone(named: "swift-stale")
        defer { SeputilFixture.discard(reattested, stale) }

        // The fixture itself has to verify, or the check below measures nothing.
        let before = try Subprocess.run(executable: codesign, arguments: ["-v", pristine.path])
        try #require(before.status == 0, "the pristine fixture must verify: \(before.stderr)")

        try CFWSeputil.patch(fileAt: reattested, log: nil)
        try CFWSeputil.patch(fileAt: stale, reattest: false, log: nil)

        let good = try Subprocess.run(executable: codesign, arguments: ["-v", reattested.path])
        let bad = try Subprocess.run(executable: codesign, arguments: ["-v", stale.path])
        #expect(good.status == 0, "re-attested binary must verify: \(good.stderr)")
        #expect(bad.status != 0, "a stale slot hash must be caught, or codesign proves nothing")
    }

    // MARK: Idempotence

    /// Running twice is a clean no-op — not an error, not a second rewrite.
    ///
    /// The shape the second run has to recognise is the one the first run
    /// wrote: the literal no longer reads `%s/%s.gl`, so a patcher that only
    /// knows the pristine spelling fails here instead of reporting "already
    /// patched". That is the bug `8eb6c8b` fixed for two DSC gates.
    @Test func `a second run changes nothing`() throws {
        let file = try SeputilFixture.clone(named: "twice")
        defer { SeputilFixture.discard(file) }

        let first = try CFWSeputil.patch(fileAt: file, log: nil)
        let afterFirst = try Data(contentsOf: file)

        let second = try CFWSeputil.patch(fileAt: file, log: nil)
        let afterSecond = try Data(contentsOf: file)

        #expect(first.verdict == .patched)
        #expect(second.verdict == .alreadyPatched)
        #expect(second.record == nil)
        #expect(second.rehashes.isEmpty)
        #expect(second.sitesWritten == 0)
        #expect(afterSecond == afterFirst, "the second run must not touch a byte")

        // The second run still found the same site, by its patched spelling.
        #expect(second.site.fieldOffset == first.site.fieldOffset)
        #expect(second.site.isPristine == false)
        #expect(second.references == first.references)
    }

    /// A dry run reports the site and leaves the file alone.
    @Test func `a dry run writes nothing`() throws {
        let file = try SeputilFixture.clone(named: "dry")
        defer { SeputilFixture.discard(file) }
        let before = try Data(contentsOf: file)

        let outcome = try CFWSeputil.patch(fileAt: file, dryRun: true, log: nil)
        #expect(outcome.verdict == .wouldPatch)
        #expect(outcome.record != nil)
        #expect(outcome.rehashes.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    // MARK: The anchor

    /// What the patcher anchored on, stated in full: the literal, the field
    /// inside it, and the instruction that materialises its address.
    @Test func `anchors on the referenced gigalocker literal`() throws {
        let file = try SeputilFixture.clone(named: "anchor")
        defer { SeputilFixture.discard(file) }
        let data = try Data(contentsOf: file)

        let (cstring, text) = try CFWSeputil.sections(in: data)
        let site = try CFWSeputil.findSite(in: data, cstring: cstring)

        #expect(site.literal == "%s/%s.gl")
        #expect(site.isPristine)
        // The field is the one after the literal's last separator, so it lands
        // on the *uuid*, not the mountpoint: patching the mountpoint would send
        // every gigalocker lookup to a path that does not exist.
        #expect(site.fieldOffset == site.literalOffset + 3)
        #expect(data[site.fieldOffset ..< site.fieldOffset + 2] == Data("%s".utf8))

        // VA and file offset describe the same byte.
        let segments = MachOParser.parseSegments(from: data)
        #expect(MachOParser.vaToFileOffset(site.fieldVMA, segments: segments) == site.fieldOffset)
        #expect(site.literalVMA == cstring.address + UInt64(site.literalOffset - Int(cstring.fileOffset)))

        // And something in __text actually forms that address.
        let references = CFWSeputil.references(to: site.literalVMA, in: data, text: text)
        #expect(!references.isEmpty)
        for reference in references {
            #expect(reference >= text.address && reference < text.address + text.size)
        }
    }

    /// The record carries the reference's own `patchID`, `component` and
    /// wording, so a captured reference JSON compares field for field.
    @Test func `records the site the way the reference does`() throws {
        let file = try SeputilFixture.clone(named: "record")
        defer { SeputilFixture.discard(file) }

        let outcome = try CFWSeputil.patch(fileAt: file, dryRun: true, log: nil)
        let record = try #require(outcome.record)
        #expect(record.patchID == "seputil.gigalocker_uuid")
        #expect(record.component == "seputil")
        #expect(record.fileOffset == outcome.site.fieldOffset)
        #expect(record.virtualAddress == outcome.site.fieldVMA)
        #expect(record.originalBytes == Data("%s".utf8))
        #expect(record.patchedBytes == Data("AA".utf8))
        #expect(record.patchedBytes.count == 2)
        #expect(record.patchDescription == "gigalocker path format '/%s.gl' -> '/AA.gl'")
    }

    // MARK: Re-attestation reach

    /// Exactly the dirtied page is re-hashed, and the short tail slot — which
    /// this fixture has, and which is the known regression in independent
    /// Mach-O re-signing — is left alone because nothing was written in it.
    @Test func `reattestation touches only the dirtied page`() throws {
        let file = try SeputilFixture.clone(named: "pages")
        defer { SeputilFixture.discard(file) }
        let before = try Data(contentsOf: file)

        let directory = try #require(CFWMachOCodeSignature.codeDirectories(in: before)?.first)
        try #require(
            directory.codeLimit % directory.pageSize != 0,
            "this fixture is supposed to have a short tail slot",
        )

        let outcome = try CFWSeputil.patch(fileAt: file, log: nil)
        let rehash = try #require(outcome.rehashes.first)
        #expect(outcome.rehashes.count == 1)
        #expect(rehash.pageIndex == outcome.site.fieldOffset / directory.pageSize)
        #expect(!rehash.isTailSlot)
        #expect(rehash.hashedLength == directory.pageSize)

        // The slot on disk holds the SHA-256 of the page as it now reads —
        // computed here from the file, not taken from what the patcher said.
        let after = try Data(contentsOf: file)
        let range = try #require(directory.slotRange(rehash.pageIndex))
        let expected = Data(SHA256.hash(data: after[range]))
        #expect(after[rehash.hashFileOffset ..< rehash.hashFileOffset + directory.hashSize] == expected)

        // Every other slot is byte-identical to the pristine binary.
        let table = directory.offset + directory.hashOffset
        let tableEnd = table + directory.codeSlotCount * directory.hashSize
        let slot = rehash.hashFileOffset ..< rehash.hashFileOffset + directory.hashSize
        #expect(after[table ..< slot.lowerBound] == before[table ..< slot.lowerBound])
        #expect(after[slot.upperBound ..< tableEnd] == before[slot.upperBound ..< tableEnd])
    }

    // MARK: Refusals

    /// A literal nothing refers to is not the gigalocker path.
    ///
    /// The reference takes the first `"/%s.gl"` it finds anywhere in the file
    /// and patches it. Here the `adrp`/`add` that materialises the literal is
    /// erased first, and the patcher has to stop rather than rewrite bytes no
    /// code reads.
    @Test func `refuses A literal nothing references`() throws {
        let file = try SeputilFixture.clone(named: "unreferenced")
        defer { SeputilFixture.discard(file) }
        var data = try Data(contentsOf: file)

        let (cstring, text) = try CFWSeputil.sections(in: data)
        let site = try CFWSeputil.findSite(in: data, cstring: cstring)
        let references = CFWSeputil.references(to: site.literalVMA, in: data, text: text)
        try #require(!references.isEmpty)

        let segments = MachOParser.parseSegments(from: data)
        for reference in references {
            let offset = try #require(MachOParser.vaToFileOffset(reference, segments: segments))
            data.replaceSubrange(offset ..< offset + ARM64.nop.count, with: ARM64.nop)
        }
        #expect(CFWSeputil.references(to: site.literalVMA, in: data, text: text).isEmpty)

        #expect(throws: PatcherError.self) {
            try CFWSeputil.patch(&data, log: nil)
        }
    }
}

// MARK: - Shape rules, with no fixture

@Suite("seputil anchor shape")
struct CFWSeputilShapeTests {
    /// A synthetic `__cstring` is enough to pin the field rule, and it is the
    /// only way to present cases the real binary does not contain.
    private func section(at offset: UInt32, size: Int, address: UInt64) -> MachOSectionInfo {
        MachOSectionInfo(
            segmentName: "__TEXT",
            sectionName: "__cstring",
            address: address,
            size: UInt64(size),
            fileOffset: offset,
        )
    }

    private func cstrings(_ literals: [String], padding: Int = 16) -> Data {
        var data = Data(repeating: 0, count: padding)
        for literal in literals {
            data.append(Data(literal.utf8))
            data.append(0)
        }
        data.append(Data(repeating: 0, count: padding))
        return data
    }

    @Test func `reads the field after the last separator`() {
        // The mountpoint field is left alone; the one after the last "/" moves.
        let field = try? #require(CFWSeputil.fileField(of: Array("%s/%s.gl".utf8)))
        #expect(field == 3 ..< 5)
        #expect(CFWSeputil.fileField(of: Array("/mnt7/%s.gl".utf8)) == 6 ..< 8)
        // No separator, wrong suffix, or a field that is not two bytes wide:
        // none of these is the site this patch knows how to rewrite.
        #expect(CFWSeputil.fileField(of: Array("%s.gl".utf8)) == nil)
        #expect(CFWSeputil.fileField(of: Array("%s/%s.plist".utf8)) == nil)
        #expect(CFWSeputil.fileField(of: Array("%s/%llu.gl".utf8)) == nil)
        #expect(CFWSeputil.fileField(of: Array(".gl".utf8)) == nil)
    }

    @Test func `classifies only the two spellings it writes`() {
        #expect(CFWSeputil.pristineness(of: ArraySlice("%s".utf8)) == true)
        #expect(CFWSeputil.pristineness(of: ArraySlice("AA".utf8)) == false)
        #expect(CFWSeputil.pristineness(of: ArraySlice("BB".utf8)) == nil)
    }

    @Test func `matches whole literals only`() throws {
        // "%s.gl" is the next literal after "%s/%s.gl" on the real binary, and
        // also its tail; a substring search sees both, a literal search one.
        let data = cstrings(["%s/%s.gl", "%s.gl", "/mnt7"])
        let site = try CFWSeputil.findSite(
            in: data,
            cstring: section(at: 0, size: data.count, address: 0x1_0000_0000),
        )
        #expect(site.literalOffset == 16)
        #expect(site.literal == "%s/%s.gl")
        #expect(site.fieldOffset == 19)
        #expect(site.fieldVMA == 0x1_0000_0013)
    }

    @Test func `finds the already patched spelling`() throws {
        let data = cstrings(["%s/AA.gl"])
        let site = try CFWSeputil.findSite(
            in: data,
            cstring: section(at: 0, size: data.count, address: 0x1_0000_0000),
        )
        #expect(site.isPristine == false)
        #expect(site.fieldOffset == 19)
    }

    @Test func `refuses when there is no candidate`() {
        let data = cstrings(["%s.gl", "/mnt7", "/private/xarts"])
        #expect(throws: PatcherError.self) {
            try CFWSeputil.findSite(
                in: data,
                cstring: section(at: 0, size: data.count, address: 0x1_0000_0000),
            )
        }
    }

    /// Two candidates is not a coin flip to be taken; it is a binary this
    /// patcher does not recognise.
    @Test func `refuses when there are two candidates`() {
        let data = cstrings(["%s/%s.gl", "/mnt7", "%s/%s.gl"])
        #expect(throws: PatcherError.self) {
            try CFWSeputil.findSite(
                in: data,
                cstring: section(at: 0, size: data.count, address: 0x1_0000_0000),
            )
        }
    }

    // MARK: adrp/add pairing

    private func text(size: Int, address: UInt64) -> MachOSectionInfo {
        MachOSectionInfo(
            segmentName: "__TEXT",
            sectionName: "__text",
            address: address,
            size: UInt64(size),
            fileOffset: 0,
        )
    }

    @Test func `pairs an adrp with its add`() throws {
        let pc: UInt64 = 0x1_0000_0000
        let target: UInt64 = 0x1_0001_BDCF
        var code = try #require(ARM64Encoder.encodeADRP(rd: 2, pc: pc, target: target))
        try code.append(#require(ARM64Encoder.encodeAddImm12(rd: 2, rn: 2, imm12: 0xDCF)))

        #expect(CFWSeputil.references(to: target, in: code, text: text(size: 8, address: pc)) == [pc + 4])
        // A different literal on the same page is a different address.
        #expect(CFWSeputil.references(to: target + 1, in: code, text: text(size: 8, address: pc)).isEmpty)
    }

    @Test func `rejects an add into another register`() throws {
        let pc: UInt64 = 0x1_0000_0000
        let target: UInt64 = 0x1_0001_BDCF
        var code = try #require(ARM64Encoder.encodeADRP(rd: 2, pc: pc, target: target))
        try code.append(#require(ARM64Encoder.encodeAddImm12(rd: 3, rn: 3, imm12: 0xDCF)))
        #expect(CFWSeputil.references(to: target, in: code, text: text(size: 8, address: pc)).isEmpty)
    }

    /// `add xD, xN, #imm, lsl #12` forms `page + (imm << 12)`, not `page + imm`.
    /// Treating it as the latter would pair it with an `adrp` it has nothing to
    /// do with, so the `sh` bit is read off the encoding — the Swift Capstone
    /// wrapper does not expose an operand's shift.
    @Test func `rejects A shifted add immediate`() throws {
        let pc: UInt64 = 0x1_0000_0000
        let target: UInt64 = 0x1_0001_BDCF
        let adrp = try #require(ARM64Encoder.encodeADRP(rd: 2, pc: pc, target: target))
        let add = try #require(ARM64Encoder.encodeAddImm12(rd: 2, rn: 2, imm12: 0xDCF))

        // Set bit 22 (`sh`) on the encoder's unshifted ADD — there is no
        // shifted encoder, and hand-writing the whole word would be a second
        // encoder to get wrong.
        var shifted = add
        shifted[shifted.startIndex + 2] |= 0x40

        let disassembler = ARM64Disassembler()
        let plain = try #require(disassembler.disassembleOne(add))
        let lsl = try #require(disassembler.disassembleOne(shifted))
        #expect(plain.mnemonic == "add")
        #expect(lsl.mnemonic == "add")
        #expect(CFWSeputil.isShiftedAddImmediate(plain) == false)
        #expect(CFWSeputil.isShiftedAddImmediate(lsl) == true)

        #expect(CFWSeputil.references(to: target, in: adrp + shifted, text: text(size: 8, address: pc)).isEmpty)
        #expect(CFWSeputil.references(to: target, in: adrp + add, text: text(size: 8, address: pc)) == [pc + 4])
    }
}
