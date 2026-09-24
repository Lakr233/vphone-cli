// CFWDiskimagesiodTests.swift — parity for the diskimagesiod DDI mount gate.
//
// The patch is eight bytes over an ObjC method prologue, and a wrong eight
// bytes is a daemon that crashes on first call rather than a failing
// assertion — so the reference these tests grade against is not this port's
// own opinion. It is, in order of authority:
//
//   1. `cfw.py patch-diskimagesiod`, the Python that shipped before this port,
//      run under the project venv over a clone of the same pristine binary;
//   2. `cfw_macho_codesign.reattest_modified_offsets`, the Python's own
//      independent re-signing implementation, for the `reattest: true` path;
//   3. `/usr/bin/codesign -v`, which is neither implementation.
//
// The Python is gone. What it and its re-signer wrote is frozen digest by
// digest in ``DiskImagesGolden`` below, with the command that produced each.
//
// The fixture is the real `usr/libexec/diskimagesiod` from iOS 27.0 / 24A435 /
// iPhone17,3: 2.8 MB, arm64e, ad-hoc signed, CodeDirectory v=20400, 710+7
// hashes, and a codeLimit of 0x2C5840 that is NOT page-aligned — the short tail
// slot that the last independent-Mach-O re-signing regression came from.
//
// Point `VPHONE_MACHO_PRISTINE` at a directory of those binaries, or leave the
// default `ipsws/ref_extract/macho_pristine` in place. Without it these tests
// FAIL — the suite never opens with a bare `return`, which Swift Testing
// reports as a pass, so a green run cannot mean the fixture was absent. A
// machine that genuinely cannot carry it sets `VPHONE_MACHO_FIXTURE_OPTIONAL=1`,
// which turns the failure into a visible skip.
//
// Nothing here writes into the pristine tree. Clones are made with `cp -c`
// (`clonefile`: instant, and free on APFS) under the system temporary
// directory, or under `VPHONE_MACHO_SCRATCH` when the caller names one.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum DiskImagesFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The read-only reference tree of standalone Mach-O binaries.
    static var pristineDirectory: URL? {
        let url = ProcessInfo.processInfo.environment["VPHONE_MACHO_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/macho_pristine")
        let main = url.appendingPathComponent("diskimagesiod")
        return FileManager.default.fileExists(atPath: main.path) ? url : nil
    }

    static var pristine: URL? { pristineDirectory?.appendingPathComponent("diskimagesiod") }

    /// A second real binary from the same firmware, used as the negative case:
    /// it has no `DIDiskArb`, so locating must fail rather than find something.
    static var unrelated: URL? { pristineDirectory?.appendingPathComponent("watchdogd") }

    /// Opt-out for a machine that cannot carry the fixture.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_MACHO_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suite runs unless the fixture is absent *and* the caller opted out.
    static var runs: Bool { pristine != nil || !isOptional }

    static let missing: Comment = """
    the real 24A435 arm64e diskimagesiod is required — put it at \
    ipsws/ref_extract/macho_pristine/diskimagesiod, point VPHONE_MACHO_PRISTINE \
    at its directory, or set VPHONE_MACHO_FIXTURE_OPTIONAL=1 to skip these \
    tests instead of failing
    """

    /// Where clones go. Deliberately *not* inside `ipsws/ref_extract`: that tree
    /// is the pristine reference every parity test compares against, and a
    /// scratch directory next to it is one `rm -rf` typo away from destroying an
    /// extraction that costs a 12 GB IPSW to regenerate.
    static var scratchRoot: URL {
        ProcessInfo.processInfo.environment["VPHONE_MACHO_SCRATCH"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-macho-diskimagesiod")
    }

    /// SHA-256 as `shasum -a 256` prints it, so a digest asserted here can be
    /// taken again from a shell over the same file.
    static func digest(of url: URL) throws -> String {
        Data(SHA256.hash(data: try Data(contentsOf: url))).hex
    }

    /// Clone the pristine binary into a fresh file the caller may write to.
    ///
    /// `cp -c` asks for a `clonefile`, which costs no space and no time when the
    /// scratch root shares the fixture's APFS volume. When it does not — a
    /// caller who pointed `VPHONE_MACHO_SCRATCH` at another disk — the clone is
    /// refused and the fallback is an ordinary copy rather than a failed test.
    static func clone(named name: String) throws -> URL {
        let pristine = try #require(self.pristine, missing)
        try FileManager.default.createDirectory(
            at: scratchRoot,
            withIntermediateDirectories: true
        )
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)

        for flags in [["-c"], []] {
            let result = try DiskImagesShell.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: flags + [pristine.path, destination.path]
            )
            if result.status == 0 { return destination }
        }
        Issue.record("could not clone \(pristine.path) to \(destination.path)")
        throw CocoaError(.fileWriteUnknown)
    }

    /// Discard clones.
    ///
    /// The scratch *root* is deliberately left behind. Suites run in parallel
    /// even when each one is `.serialized`, so a suite that removed the shared
    /// root on its way out would be deleting a directory another suite is
    /// mid-clone into. The root is an empty directory under the system
    /// temporary directory, which the OS reaps on its own schedule.
    static func discard(_ clones: URL...) {
        for clone in clones {
            try? FileManager.default.removeItem(at: clone)
        }
    }

    /// `codesign -v` on a file, which is a reference neither implementation wrote.
    static func codesignVerify(_ binary: URL) throws -> DiskImagesShell.Result {
        try DiskImagesShell.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-v", "--verbose=2", binary.path]
        )
    }
}

// MARK: - Subprocess helper

private enum DiskImagesShell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run `executable` to completion and collect both streams.
    ///
    /// The two pipes are drained on separate queues rather than one after the
    /// other. A pipe holds about 64 KiB; draining stdout to EOF first would
    /// wedge any child that fills stderr in the meantime.
    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let collected = Drain()
        let group = DispatchGroup()
        for (handle, isStandardOutput) in [
            (out.fileHandleForReading, true),
            (err.fileHandleForReading, false),
        ] {
            DispatchQueue.global().async(group: group) {
                let data = handle.readDataToEndOfFile()
                collected.store(data, isStandardOutput: isStandardOutput)
            }
        }
        group.wait()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: collected.standardOutput, as: UTF8.self),
            stderr: String(decoding: collected.standardError, as: UTF8.self)
        )
    }

    /// Somewhere for the two reader queues to put what they read.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func store(_ data: Data, isStandardOutput: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isStandardOutput { out = data } else { err = data }
        }

        var standardOutput: Data { lock.withLock { out } }
        var standardError: Data { lock.withLock { err } }
    }
}

// MARK: - The frozen reference

/// What `scripts/patchers/` produced on this fixture, recorded before it was
/// deleted.
///
/// Every value below was taken at repo commit `78cbeea`, with
/// `.venv/bin/python3` driving `scripts/patchers/`, over the real iOS 27.0 /
/// 24A435 / iPhone17,3 `usr/libexec/diskimagesiod` whose own digest is
/// ``pristine``.
private enum DiskImagesGolden {
    /// `shasum -a 256 ipsws/ref_extract/macho_pristine/diskimagesiod`
    static let pristine = "77e472b74d518beedb2533c409fd66ec964c90264ad35d8fa9f10f82a448af15"

    /// `.venv/bin/python3 scripts/patchers/cfw.py patch-diskimagesiod <clone>`
    /// — the ObjC prologue at 0x320C0 replaced with `mov x0, #1 ; ret`,
    /// signature left stale. Its stdout reported
    /// `Found via relative method list: IMP va:0x1000320C0 foff:0x320C0`.
    static let patched = "41daf01d25fc98317516c1aa4c3a095a0e449715907e9e71f1cff6310bcd9cbd"

    /// The IMP that run resolved, from that stdout line.
    static let impFileOffset = 0x3_20C0
    static let impVirtualAddress: UInt64 = 0x1_0003_20C0

    /// ``patched``, then
    /// `.venv/bin/python3 -c 'import sys; sys.path.insert(0, "scripts/patchers");
    /// import cfw_macho_codesign as r;
    /// r.reattest_modified_offsets(sys.argv[1], [204992, 204999], verbose=True)'`
    /// — which reported `wrote cd_index=0 slot 50 (6e2cd215.. -> b7814241..)`.
    static let patchedAndReattested =
        "eea1a205c3b3d14ab41acf262b67f34fcdbb14ec96e7deb5a86adb5e807cec44"

    /// The one code slot that re-attestation rewrote.
    static let reattestedSlot = 50

    /// The short-tail case, which the real patch site is nowhere near. On a
    /// *pristine* clone, byte 2905120 (0x2C5420, the middle of the last slot)
    /// XORed with 0xFF, then the same re-attester over `[2905120]` — which
    /// reported `wrote cd_index=0 slot 709 [tail, 2112B] (2197132a.. -> 8106b4a9..)`.
    static let tailVictimOffset = 2_905_120
    static let tailFlippedAndReattested =
        "bc979503698fcb92e3db6ae46650ea3cad6c66fd119765370c1f0cd5eb7281e9"
    static let tailSlot = 709
    static let tailSlotLength = 2112

    /// `cfw.py patch-diskimagesiod` run a SECOND time over ``patched``: it
    /// rewrote the same eight bytes and the file did not move, so the digest is
    /// ``patched`` again.
    static let patchedTwice = patched
}

// MARK: - Byte comparison

private enum DiskImagesComparison {
    /// Every offset at which two files differ, capped so a wholly wrong result
    /// reports a count instead of megabytes of noise.
    static func differences(between lhs: URL, and rhs: URL, limit: Int = 16) throws -> [Int] {
        let left = try Data(contentsOf: lhs)
        let right = try Data(contentsOf: rhs)
        guard left.count == right.count else { return [-1] }
        var offsets: [Int] = []
        for index in 0 ..< left.count where left[index] != right[index] {
            offsets.append(index)
            if offsets.count >= limit { break }
        }
        return offsets
    }

    static func identical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        try differences(between: lhs, and: rhs, limit: 1).isEmpty
    }
}

// MARK: - The replacement bytes

@Suite("diskimagesiod replacement encoding")
struct CFWDiskimagesiodEncodingTests {
    @Test("`mov x0, #1` built from ISA fields is the keystone-verified constant")
    func movzAgreesWithKeystone() throws {
        let encoded = try #require(ARM64Encoder.encodeMovzX(rd: 0, imm16: 1))
        #expect(encoded == ARM64.movX0_1)
        // 0xD2800020, little-endian on disk.
        #expect(encoded.hex == "200080d2")
    }

    @Test("the patch writes exactly `mov x0, #1 ; ret`")
    func replacementDisassembles() {
        #expect(CFWDiskimagesiod.replacement.count == 8)
        #expect(CFWDiskimagesiod.replacement == ARM64.movX0_1 + ARM64.ret)
        #expect(
            CFWDiskimagesiod.disassemblyText(of: CFWDiskimagesiod.replacement, at: nil)
                == "mov x0, #1; ret"
        )
    }
}

// MARK: - Anchoring

@Suite(
    "diskimagesiod anchoring",
    .enabled(if: DiskImagesFixture.runs, DiskImagesFixture.missing),
    .serialized
)
struct CFWDiskimagesiodAnchorTests {
    @Test("the IMP resolves through the relative method list, into __TEXT,__text")
    func locatesImplementation() throws {
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)
        let data = try Data(contentsOf: pristine)
        let site = try CFWDiskimagesiod.locate(in: data)

        // Shipped diskimagesiod is stripped, so the symbol-table anchor misses
        // and the ObjC metadata walk is what answers.
        #expect(site.anchor == .relativeMethodList)
        #expect(MachOParser.findSymbol(containing: CFWDiskimagesiod.symbolFragment, in: data) == nil)

        let sections = MachOParser.parseSections(from: data)
        let text = try #require(sections["__TEXT,__text"])
        #expect(site.fileOffset >= Int(text.fileOffset))
        #expect(site.fileOffset + 8 <= Int(text.fileOffset) + Int(text.size))

        // The VA and the file offset have to agree through the segment table.
        let va = try #require(site.virtualAddress)
        let segments = MachOParser.parseSegments(from: data)
        #expect(MachOParser.vaToFileOffset(va, segments: segments) == site.fileOffset)

        // A real ObjC method prologue, not yet patched.
        #expect(!site.isAlreadyPatched)
        #expect(CFWDiskimagesiod.disassemblyText(of: site.original, at: va)
            .hasPrefix("pacibsp; stp"))
    }

    @Test("the fixture is the one the goldens were recorded from")
    func fixtureMatchesTheGoldens() throws {
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)
        #expect(
            try DiskImagesFixture.digest(of: pristine) == DiskImagesGolden.pristine,
            """
            this is not the 24A435 diskimagesiod DiskImagesGolden was recorded \
            from — re-derive the goldens before reading a failure elsewhere in \
            this file as a patcher bug
            """
        )
    }

    @Test("the reference's own anchor walk agreed on the same offset")
    func agreesWithTheFrozenAnchor() throws {
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)
        let site = try CFWDiskimagesiod.locate(in: try Data(contentsOf: pristine))

        // The offset the Python printed; both walks must land on it.
        #expect(site.fileOffset == DiskImagesGolden.impFileOffset)
        #expect(site.virtualAddress == DiskImagesGolden.impVirtualAddress)
    }

    @Test("the selector names exactly one implementation in the image")
    func selectorIsUnique() throws {
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)
        let data = try Data(contentsOf: pristine)
        let sections = MachOParser.parseSections(from: data)

        let selectorVA = try #require(
            CFWDiskimagesiod.selectorStringVA(in: data, sections: sections)
        )
        let selrefs = try #require(sections["__DATA,__objc_selrefs"])
        let selrefVA = try #require(CFWDiskimagesiod.selectorReferenceVA(
            in: data,
            selrefs: selrefs,
            selectorVA: selectorVA,
            imageBase: CFWDiskimagesiod.imageBase(sections)
        ))

        let methlist = try #require(sections["__TEXT,__objc_methlist"])
        let imps = CFWDiskimagesiod.relativeMethodListIMPs(
            in: data,
            section: methlist,
            naming: [selectorVA, selrefVA]
        )
        #expect(imps.count == 1)
        #expect(imps.first == (try CFWDiskimagesiod.locate(in: data)).virtualAddress)
    }

    @Test("the strided fallback scan lands on the same IMP as the structural walk")
    func scanFallbackAgreesWithStructuralWalk() throws {
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)
        let data = try Data(contentsOf: pristine)
        let sections = MachOParser.parseSections(from: data)

        let selectorVA = try #require(
            CFWDiskimagesiod.selectorStringVA(in: data, sections: sections)
        )
        let selrefs = try #require(sections["__DATA,__objc_selrefs"])
        let selrefVA = try #require(CFWDiskimagesiod.selectorReferenceVA(
            in: data,
            selrefs: selrefs,
            selectorVA: selectorVA,
            imageBase: CFWDiskimagesiod.imageBase(sections)
        ))
        let methlist = try #require(sections["__TEXT,__objc_methlist"])
        let targets: Set<UInt64> = [selectorVA, selrefVA]

        // The Python only ever did the strided scan. Both walks over the same
        // section have to name the same single implementation, or the two
        // implementations would have diverged on some other firmware even
        // though they agreed on this one.
        let structural = CFWDiskimagesiod.relativeMethodListIMPs(
            in: data,
            section: methlist,
            naming: targets
        )
        let strided = CFWDiskimagesiod.scanRelativeMethodEntryIMPs(
            in: data,
            section: methlist,
            naming: targets
        )
        #expect(structural == strided)
        #expect(strided.count == 1)
    }

    @Test("a binary without DIDiskArb is refused, not guessed at")
    func unrelatedBinaryIsRefused() throws {
        let unrelated = try #require(DiskImagesFixture.unrelated, DiskImagesFixture.missing)
        let data = try Data(contentsOf: unrelated)
        #expect(throws: PatcherError.self) {
            try CFWDiskimagesiod.locate(in: data)
        }
    }
}

// MARK: - Parity against the frozen reference

@Suite(
    "diskimagesiod parity",
    .enabled(if: DiskImagesFixture.runs, DiskImagesFixture.missing),
    .serialized
)
struct CFWDiskimagesiodParityTests {
    @Test("Swift reproduces the reference's bytes, one site each")
    func byteForByteParity() throws {
        let swiftClone = try DiskImagesFixture.clone(named: "swift")
        defer { DiskImagesFixture.discard(swiftClone) }

        let report = try CFWDiskimagesiod.patch(fileAt: swiftClone, log: nil)
        #expect(report.outcome == .patched)
        #expect(report.sitesWritten == 1)
        // Off by default: `cfw_install.sh` re-signs with ldid straight after,
        // and the Python did not re-attest either.
        #expect(report.rehashes.isEmpty)
        #expect(report.site.fileOffset == DiskImagesGolden.impFileOffset)

        #expect(
            try DiskImagesFixture.digest(of: swiftClone) == DiskImagesGolden.patched,
            "Swift and the frozen reference disagree"
        )
    }

    @Test("the recorded write names the site, the bytes and both disassemblies")
    func recordDescribesTheSite() throws {
        let clone = try DiskImagesFixture.clone(named: "record")
        defer { DiskImagesFixture.discard(clone) }

        let report = try CFWDiskimagesiod.patch(fileAt: clone, log: nil)
        let record = try #require(report.record)

        #expect(record.patchID == "diskimagesiod.is_mount_complete")
        #expect(record.component == "diskimagesiod")
        #expect(record.fileOffset == report.site.fileOffset)
        #expect(record.virtualAddress == report.site.virtualAddress)
        #expect(record.originalBytes == report.site.original)
        #expect(record.patchedBytes == CFWDiskimagesiod.replacement)
        #expect(record.afterDisasm == "mov x0, #1; ret")
        #expect(record.beforeDisasm.hasPrefix("pacibsp"))
        #expect(record.patchDescription.contains("isMountCompleteWithExpectedCount:diskTracker:"))

        // What landed on disk is what the record claims.
        let patched = try Data(contentsOf: clone)
        let range = record.fileOffset ..< record.fileOffset + record.patchedBytes.count
        #expect(patched[range] == record.patchedBytes)
    }

    @Test("only the eight patched bytes differ from the pristine binary")
    func onlyTheSiteChanges() throws {
        let clone = try DiskImagesFixture.clone(named: "minimal")
        defer { DiskImagesFixture.discard(clone) }
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)

        let report = try CFWDiskimagesiod.patch(fileAt: clone, log: nil)
        let differences = try DiskImagesComparison.differences(
            between: pristine,
            and: clone,
            limit: 64
        )
        #expect(differences.allSatisfy {
            (report.site.fileOffset ..< report.site.fileOffset + 8).contains($0)
        })
        #expect(!differences.isEmpty)
    }
}

// MARK: - Re-signing

@Suite(
    "diskimagesiod re-attestation",
    .enabled(if: DiskImagesFixture.runs, DiskImagesFixture.missing),
    .serialized
)
struct CFWDiskimagesiodReattestTests {
    @Test("the fixture really does have the short tail slot this path regressed on")
    func fixtureHasShortTail() throws {
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)
        let data = try Data(contentsOf: pristine)
        let directories = try #require(CFWMachOCodeSignature.codeDirectories(in: data))
        let directory = try #require(directories.first)

        #expect(directory.hashType == CFWMachOCodeSignature.hashTypeSHA256)
        #expect(directory.pageSize == 4096)
        #expect(directory.codeLimit % directory.pageSize != 0, "expected a non-page-aligned codeLimit")

        let tail = try #require(directory.slotRange(directory.codeSlotCount - 1))
        #expect(tail.count < directory.pageSize)
        #expect(tail.upperBound == directory.codeLimit)
    }

    @Test("`codesign -v` rejects the un-attested patch and accepts the attested one")
    func codesignAgrees() throws {
        let bare = try DiskImagesFixture.clone(named: "bare")
        let attested = try DiskImagesFixture.clone(named: "attested")
        defer { DiskImagesFixture.discard(bare, attested) }

        try CFWDiskimagesiod.patch(fileAt: bare, log: nil)
        #expect(try DiskImagesFixture.codesignVerify(bare).status != 0)

        let report = try CFWDiskimagesiod.patch(fileAt: attested, reattest: true, log: nil)
        #expect(report.outcome == .patched)
        #expect(report.rehashes.count == 1)

        let slot = try #require(report.rehashes.first)
        #expect(slot.pageIndex == report.site.fileOffset / slot.pageSize)
        #expect(!slot.isTailSlot)
        #expect(slot.before != slot.after)

        let verification = try DiskImagesFixture.codesignVerify(attested)
        #expect(verification.status == 0, "codesign said: \(verification.stderr)")
    }

    @Test("the re-attested bytes are the reference re-attest's bytes")
    func reattestMatchesTheFrozenReference() throws {
        let swiftClone = try DiskImagesFixture.clone(named: "swift-attested")
        defer { DiskImagesFixture.discard(swiftClone) }

        let report = try CFWDiskimagesiod.patch(fileAt: swiftClone, reattest: true, log: nil)
        #expect(report.rehashes.first?.pageIndex == DiskImagesGolden.reattestedSlot)
        #expect(
            try DiskImagesFixture.digest(of: swiftClone) == DiskImagesGolden.patchedAndReattested,
            "the re-attested slot hash must be the one the reference computed"
        )
    }

    @Test("a short-tail slot is hashed to codeLimit, not to the end of its page")
    func tailSlotStopsAtCodeLimit() throws {
        let swiftClone = try DiskImagesFixture.clone(named: "swift-tail")
        defer { DiskImagesFixture.discard(swiftClone) }

        // Land a byte inside the last, short slot. This is synthetic — the real
        // patch site is nowhere near — and it is the only way to make the
        // re-attester recompute the slot whose length is not a page. The victim
        // is derived, not typed in, and then checked against the offset the
        // frozen run used so both sides really are the same experiment.
        var data = try Data(contentsOf: swiftClone)
        let directory = try #require(CFWMachOCodeSignature.codeDirectories(in: data)?.first)
        let tail = try #require(directory.slotRange(directory.codeSlotCount - 1))
        let victim = tail.lowerBound + tail.count / 2
        #expect(victim == DiskImagesGolden.tailVictimOffset)
        #expect(tail.count == DiskImagesGolden.tailSlotLength)
        #expect(directory.codeSlotCount - 1 == DiskImagesGolden.tailSlot)
        data[victim] = data[victim] ^ 0xFF
        try data.write(to: swiftClone)

        let rehashes = try CFWMachOCodeSignature.reattest(fileAt: swiftClone, modifiedOffsets: [victim])
        let slot = try #require(rehashes.first)
        #expect(slot.isTailSlot)
        #expect(slot.hashedLength == tail.count)
        #expect(slot.pageEnd == directory.codeLimit)

        #expect(
            try DiskImagesFixture.digest(of: swiftClone)
                == DiskImagesGolden.tailFlippedAndReattested,
            "the tail slot hash must be the one the reference re-attester computed"
        )
    }
}

// MARK: - Idempotence

@Suite(
    "diskimagesiod idempotence",
    .enabled(if: DiskImagesFixture.runs, DiskImagesFixture.missing),
    .serialized
)
struct CFWDiskimagesiodIdempotenceTests {
    @Test("a second Swift run recognises its own output and writes nothing")
    func secondRunIsANoOp() throws {
        let clone = try DiskImagesFixture.clone(named: "twice")
        defer { DiskImagesFixture.discard(clone) }

        try CFWDiskimagesiod.patch(fileAt: clone, log: nil)
        let afterFirst = try Data(contentsOf: clone)
        let attributes = try FileManager.default.attributesOfItem(atPath: clone.path)

        let second = try CFWDiskimagesiod.patch(fileAt: clone, log: nil)
        #expect(second.outcome == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.record == nil)
        #expect(second.site.isAlreadyPatched)
        #expect(try Data(contentsOf: clone) == afterFirst)

        // Nothing was written at all, so even the modification time stands.
        let after = try FileManager.default.attributesOfItem(atPath: clone.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
    }

    @Test("a second run with re-attestation leaves the slot hashes alone")
    func secondAttestedRunIsANoOp() throws {
        let clone = try DiskImagesFixture.clone(named: "twice-attested")
        defer { DiskImagesFixture.discard(clone) }

        try CFWDiskimagesiod.patch(fileAt: clone, reattest: true, log: nil)
        let afterFirst = try Data(contentsOf: clone)

        let second = try CFWDiskimagesiod.patch(fileAt: clone, reattest: true, log: nil)
        #expect(second.outcome == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.rehashes.isEmpty, "the stored slot hashes were already current")
        #expect(try Data(contentsOf: clone) == afterFirst)
        #expect(try DiskImagesFixture.codesignVerify(clone).status == 0)
    }

    /// Running the two implementations in either order lands on one file.
    ///
    /// The reference half is frozen: `cfw.py patch-diskimagesiod` over its own
    /// output rewrote the same eight bytes and the digest did not move
    /// (``DiskImagesGolden/patchedTwice`` is ``DiskImagesGolden/patched``). So
    /// "the reference over a Swift-patched binary" is the same experiment as
    /// "the reference over its own output" — the two files are byte-identical
    /// by `byteForByteParity` — and what is left to measure is this side:
    /// Swift over the bytes the reference left behind must change nothing.
    @Test("the reference's output is what this port reports as already patched")
    func crossImplementationRerunsAgree() throws {
        let referenceOutput = try DiskImagesFixture.clone(named: "reference-then-swift")
        defer { DiskImagesFixture.discard(referenceOutput) }

        // Reproduce the reference's output, and prove it is that, by digest.
        try CFWDiskimagesiod.patch(fileAt: referenceOutput, log: nil)
        try #require(
            try DiskImagesFixture.digest(of: referenceOutput) == DiskImagesGolden.patched
        )
        #expect(DiskImagesGolden.patchedTwice == DiskImagesGolden.patched)

        let report = try CFWDiskimagesiod.patch(fileAt: referenceOutput, log: nil)
        #expect(report.outcome == .alreadyPatched)
        #expect(try DiskImagesFixture.digest(of: referenceOutput) == DiskImagesGolden.patched)
    }

    @Test("a dry run locates the site and writes nothing")
    func dryRunWritesNothing() throws {
        let clone = try DiskImagesFixture.clone(named: "dry")
        defer { DiskImagesFixture.discard(clone) }
        let pristine = try #require(DiskImagesFixture.pristine, DiskImagesFixture.missing)

        let report = try CFWDiskimagesiod.patch(fileAt: clone, reattest: true, dryRun: true, log: nil)
        #expect(report.outcome == .wouldPatch)
        #expect(report.sitesWritten == 0)
        #expect(report.rehashes.isEmpty)
        #expect(report.site.fileOffset > 0)
        #expect(try DiskImagesComparison.identical(pristine, clone))
    }
}
