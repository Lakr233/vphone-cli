// CustomFirmwareJetsamTests.swift — `CustomFirmwareJetsamPatcher` against the reference it replaces.
//
// The bar for this port is not "the test passes". It is that the Swift patcher
// and `scripts/patchers/cfw_patch_jetsam.py` produce the same bytes from the
// same input, on the real `/sbin/launchd` out of iOS 27.0 / 24A435. That Python
// is gone: what it wrote, and the two anchors it printed on its way there, are
// frozen in ``JetsamGolden`` below, and the comparison tests grade the Swift
// against those.
//
// `codesign -v` is the second, fully independent reference: the patcher's
// `reattest: true` mode has to leave a binary that verifies, and the slot hash
// it writes has to equal the one the Python's own `cfw_macho_codesign.py`
// computed over the same patched bytes — also frozen.
//
// `ipsws/` is not in the repo, so every test that needs the pristine `launchd`
// is gated on it being there and skips rather than fails when it is not. The
// pure decode/encode tests below have no such dependency and always run.
//
// Set `VPHONE_JETSAM_ARTIFACTS=<dir>` to keep each run's inputs and outputs for
// inspection from a shell; without it they land in a temporary directory.

import Capstone
import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixtures

enum JetsamFixture {
    /// The package root, derived from this file rather than the working
    /// directory, which `swift test` does not promise.
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // CustomFirmware
        .deletingLastPathComponent() // FirmwarePatcherTests
        .deletingLastPathComponent() // VPhoneCommand
        .deletingLastPathComponent() // VPhoneExecutable
        .deletingLastPathComponent() // <root>

    /// The real, ad-hoc signed, thin arm64e `/sbin/launchd`.
    static let pristineLaunchd = repositoryRoot
        .appending(path: "ipsws/ref_extract/macho_pristine/launchd")
    static let codesign = URL(filePath: "/usr/bin/codesign")

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static var hasLaunchd: Bool {
        exists(pristineLaunchd)
    }

    static var hasLaunchdAndCodesign: Bool {
        hasLaunchd && exists(codesign)
    }

    /// SHA-256 as `shasum -a 256` prints it, so a digest asserted here can be
    /// taken again from a shell over the same file.
    static func digest(of url: URL) throws -> String {
        try Data(SHA256.hash(data: Data(contentsOf: url))).hex
    }

    /// A directory for one test's artifacts. `VPHONE_JETSAM_ARTIFACTS` pins it
    /// so a shell can look at what a run produced.
    static func workDirectory(_ name: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment["VPHONE_JETSAM_ARTIFACTS"]
            .map { URL(filePath: $0) } ?? URL(filePath: NSTemporaryDirectory())
        let directory = base.appending(path: "CustomFirmwareJetsamTests-\(name)")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A private, writable clone of the pristine `launchd`.
    static func launchdCopy(named name: String, in directory: URL) throws -> URL {
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: pristineLaunchd, to: destination)
        return destination
    }

    @discardableResult
    static func run(
        _ tool: URL,
        _ arguments: [String],
        workingDirectory: URL? = nil,
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// The first byte offset at which two files differ, or nil when equal.
    static func firstDifference(_ lhs: Data, _ rhs: Data) -> Int? {
        if lhs.count != rhs.count {
            return min(lhs.count, rhs.count)
        }
        for index in 0 ..< lhs.count where lhs[index] != rhs[index] {
            return index
        }
        return nil
    }
}

// MARK: - The frozen reference

/// What `scripts/patchers/` produced on this fixture, recorded before it was
/// deleted.
///
/// Every value below was taken at repo commit `78cbeea`, with
/// `.venv/bin/python3` driving `scripts/patchers/`, over the real iOS 27.0 /
/// 24A435 / iPhone17,3 `/sbin/launchd` whose own digest is ``pristine``.
enum JetsamGolden {
    /// `shasum -a 256 ipsws/ref_extract/macho_pristine/launchd`
    static let pristine = "c640246d38aaeb2d2372aff1e5aa0de59dec267f53c0dfc155f7837e717af68b"

    /// `.venv/bin/python3 scripts/patchers/cfw.py patch-launchd-jetsam <clone>`
    /// — `cbz w0, #0xfaec` at 0xFA98 rewritten to `b #0xfaec`, signature left
    /// stale.
    static let patched = "cae806f55aadc0109c6b8e737b0ee4e648ce7ec1fbcce0ac9215f45b736d0fcb"

    /// The two anchors that run printed on its way to the gate, not just its
    /// answer — so a port that agreed on the gate by luck is still caught:
    ///   "    xref at foff:0xFB0C"
    ///   "  [+] Patched at 0xFA98: jetsam panic guard bypass"
    static let xrefOffset = 0xFB0C
    static let gateOffset = 0xFA98

    /// ``patched``, then
    /// `.venv/bin/python3 -c 'import sys; sys.path.insert(0, "scripts/patchers");
    /// import cfw_macho_codesign as r;
    /// r.reattest_modified_offsets(sys.argv[1], [64152], verbose=True)'`
    /// — which reported `wrote cd_index=0 slot 15 (ff0c126a.. -> 361aa09d..)`.
    static let patchedAndReattested =
        "689236aad3bb8fe360412195ff626269ee7403be322628a5bb66517a65ad2ea2"

    /// The one code slot that re-attestation rewrote.
    static let reattestedSlot = 15

    /// `cfw.py patch-launchd-jetsam` run a SECOND time over ``patched``.
    ///
    /// Not what the reference should have done — what it did. It landed a
    /// second site the pristine image never had patched, printing
    /// `[+] Patched at 0xFAB0`, so the file moved again. This port recognises
    /// its own work and stops; the digest keeps that divergence visible.
    static let patchedTwice = "2c979d9dbeb0de9cd4877c843f1910ccff43a5ebfdf50c1e0f6bdc5d53370979"

    /// The second gate the reference took, from that stdout line.
    static let secondRunGateOffset = 0xFAB0
}

// MARK: - Against the frozen reference

@Suite("launchd jetsam guard — against the frozen reference")
struct CustomFirmwareJetsamReferenceTests {
    /// The fixture the frozen digests were taken over. Without this a digest
    /// mismatch below would read as a patcher bug when the real cause is a
    /// different firmware's `launchd`.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `fixture matches the goldens`() throws {
        #expect(
            try JetsamFixture.digest(of: JetsamFixture.pristineLaunchd) == JetsamGolden.pristine,
            """
            this is not the 24A435 launchd JetsamGolden was recorded from — \
            re-derive the goldens before reading a failure below as a patcher bug
            """,
        )
    }

    /// The whole point of the port: same input, same bytes out.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `matches the frozen reference byte for byte`() throws {
        let work = try JetsamFixture.workDirectory("byte-equivalence")
        let swiftTarget = try JetsamFixture.launchdCopy(named: "launchd.swift", in: work)

        let outcome = try CustomFirmwareJetsamPatcher.patch(fileAt: swiftTarget, log: nil)
        #expect(outcome.verdict == .patched)
        #expect(
            try JetsamFixture.digest(of: swiftTarget) == JetsamGolden.patched,
            "Swift and the frozen reference diverge",
        )

        // And the only thing that moved is inside the instruction the record
        // names. Not every one of the four bytes has to differ: on this image
        // `cbz w0, #0xfaec` is A0 02 00 34 and `b #0xfaec` is 15 00 00 14, so
        // byte 2 is 0x00 either way. Containment is the real claim — the whole
        // instruction was rewritten and nothing outside it was.
        let swiftBytes = try Data(contentsOf: swiftTarget)
        let pristine = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let site = outcome.gateOffset ..< outcome.gateOffset + 4
        let changed = (0 ..< pristine.count).filter { pristine[$0] != swiftBytes[$0] }
        #expect(!changed.isEmpty)
        #expect(changed.allSatisfy(site.contains), "bytes changed outside the gate: \(changed)")
        #expect(Data(swiftBytes[site]) == outcome.record?.patchedBytes)
        #expect(Data(pristine[site]) == outcome.record?.originalBytes)
    }

    /// The gate the reference reported is the gate this finds — and the xref it
    /// reached it through too, so a port that agreed on the gate by luck is
    /// still caught.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `agrees with the frozen reference on the site`() throws {
        let data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let image = try CustomFirmwareJetsamPatcher.Image(data: data)
        let site = try #require(try CustomFirmwareJetsamPatcher.locate(in: image))
        #expect(site.xrefOffset == JetsamGolden.xrefOffset)
        #expect(site.gateOffset == JetsamGolden.gateOffset)

        var patchable = data
        let outcome = try CustomFirmwareJetsamPatcher.patch(&patchable, dryRun: true, log: nil)
        #expect(outcome.gateOffset == JetsamGolden.gateOffset)
        #expect(outcome.verdict == .wouldPatch)
    }
}

// MARK: - Idempotence

@Suite("launchd jetsam guard — idempotence")
struct CustomFirmwareJetsamIdempotenceTests {
    /// The bug this patcher must not have. The reference re-patches a second,
    /// different branch on an already-patched binary; this one recognises its
    /// own work and stops.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `second run changes nothing`() throws {
        let work = try JetsamFixture.workDirectory("idempotence")
        let target = try JetsamFixture.launchdCopy(named: "launchd", in: work)

        let first = try CustomFirmwareJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(first.verdict == .patched)
        let afterFirst = try Data(contentsOf: target)

        let second = try CustomFirmwareJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(second.verdict == .alreadyPatched)
        #expect(second.gateOffset == first.gateOffset)
        #expect(second.returnBlockOffset == first.returnBlockOffset)
        #expect(second.record == nil)

        let afterSecond = try Data(contentsOf: target)
        #expect(JetsamFixture.firstDifference(afterFirst, afterSecond) == nil)

        // A third pass must not drift either.
        let third = try CustomFirmwareJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(third.verdict == .alreadyPatched)
        let afterThird = try Data(contentsOf: target)
        #expect(JetsamFixture.firstDifference(afterFirst, afterThird) == nil)
    }

    /// Where the reference went wrong, and the measurement that showed it: run
    /// twice, and it landed a *second* site the pristine image never had
    /// patched. Frozen, so the divergence stays a measurement, not a claim.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `reference was not idempotent and this is`() throws {
        let work = try JetsamFixture.workDirectory("reference-double-apply")
        let swiftTarget = try JetsamFixture.launchdCopy(named: "launchd.swift", in: work)

        // The frozen half: the reference's second run moved the file, and to a
        // different instruction than the gate it had already rewritten.
        #expect(
            JetsamGolden.patchedTwice != JetsamGolden.patched,
            "the reference was recorded as non-idempotent — re-check what this port has to preserve",
        )
        #expect(JetsamGolden.secondRunGateOffset != JetsamGolden.gateOffset)

        // The Swift half, measured: run once, land on the reference's one-run
        // bytes; run again, and nothing moves.
        try CustomFirmwareJetsamPatcher.patch(fileAt: swiftTarget, log: nil)
        let swiftOnce = try Data(contentsOf: swiftTarget)
        #expect(Data(SHA256.hash(data: swiftOnce)).hex == JetsamGolden.patched)

        try CustomFirmwareJetsamPatcher.patch(fileAt: swiftTarget, log: nil)
        let swiftTwice = try Data(contentsOf: swiftTarget)
        #expect(JetsamFixture.firstDifference(swiftOnce, swiftTwice) == nil)
        #expect(Data(SHA256.hash(data: swiftTwice)).hex != JetsamGolden.patchedTwice)

        // And the instruction the reference's second run would have taken is
        // still the one the pristine image carries there.
        let pristine = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let second = JetsamGolden.secondRunGateOffset ..< JetsamGolden.secondRunGateOffset + 4
        #expect(Data(swiftTwice[second]) == Data(pristine[second]))
    }
}

// MARK: - Re-attestation

@Suite("launchd jetsam guard — signature re-attestation")
struct CustomFirmwareJetsamSignatureTests {
    /// Default is the reference's behaviour: the four bytes and nothing else,
    /// because every call site re-signs with `ldid` straight afterwards.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndCodesign))
    func `default leaves the signature stale`() throws {
        let work = try JetsamFixture.workDirectory("stale-signature")
        let target = try JetsamFixture.launchdCopy(named: "launchd", in: work)

        let outcome = try CustomFirmwareJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(outcome.rehashes.isEmpty)

        let verify = try JetsamFixture.run(JetsamFixture.codesign, ["-v", target.path])
        #expect(verify.status != 0, "a patch with no re-attestation must not still verify")
    }

    /// `reattest: true` has to leave a binary `codesign` accepts — one page's
    /// slot hash, recomputed, tail slot included.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndCodesign))
    func `reattested binary verifies`() throws {
        let work = try JetsamFixture.workDirectory("reattested")
        let target = try JetsamFixture.launchdCopy(named: "launchd", in: work)

        let outcome = try CustomFirmwareJetsamPatcher.patch(fileAt: target, reattest: true, log: nil)
        #expect(outcome.verdict == .patched)
        #expect(outcome.rehashes.count == 1)

        let rehash = try #require(outcome.rehashes.first)
        let patched = try Data(contentsOf: target)
        let directory = try #require(
            CustomFirmwareMachOCodeSignature.codeDirectories(in: patched)?
                .first { $0.hashType == CustomFirmwareMachOCodeSignature.hashTypeSHA256 },
        )
        #expect(rehash.pageIndex == outcome.gateOffset / directory.pageSize)

        let verify = try JetsamFixture.run(JetsamFixture.codesign, ["-v", target.path])
        #expect(verify.status == 0, "codesign -v rejected the re-attested binary:\n\(verify.output)")
    }

    /// The slot hash itself, against the frozen output of the Python's
    /// independent re-signer run over the Python's own patched bytes. Two
    /// implementations, one number.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `slot hash matches the frozen resigner`() throws {
        let work = try JetsamFixture.workDirectory("slot-hash")
        let swiftTarget = try JetsamFixture.launchdCopy(named: "launchd.swift", in: work)

        let outcome = try CustomFirmwareJetsamPatcher.patch(fileAt: swiftTarget, reattest: true, log: nil)
        #expect(outcome.verdict == .patched)
        #expect(outcome.gateOffset == JetsamGolden.gateOffset)
        #expect(outcome.rehashes.first?.pageIndex == JetsamGolden.reattestedSlot)
        #expect(
            try JetsamFixture.digest(of: swiftTarget) == JetsamGolden.patchedAndReattested,
            "the re-attested slot hash must be the one the reference computed",
        )
    }
}

// MARK: - Anchoring, without a reference

@Suite("launchd jetsam guard — anchoring")
struct CustomFirmwareJetsamAnchoringTests {
    /// Every step of the reveal lands where the disassembly says it should:
    /// the xref is inside the function, the gate is inside the function and
    /// before the xref, and the gate's target really does return.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `reveal steps are self consistent`() throws {
        let data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let image = try CustomFirmwareJetsamPatcher.Image(data: data)
        let site = try #require(try CustomFirmwareJetsamPatcher.locate(in: image))

        #expect(CustomFirmwareJetsamPatcher.panicStringAnchors.contains(site.anchor))
        #expect(!site.isAlreadyPatched)
        #expect(site.functionOffset <= site.gateOffset)
        #expect(site.gateOffset < site.xrefOffset)
        #expect(image.isInText(site.xrefOffset))
        #expect(image.isInText(site.returnBlockOffset))
        #expect(CustomFirmwareJetsamPatcher.isReturnBlock(site.returnBlockOffset, in: image))

        // The function bound is a real prologue, not the blind fallback.
        #expect(data.loadLE(UInt32.self, at: site.functionOffset) == ARM64.pacibspU32)

        // The anchor string starts where the xref computes it to start.
        let page = CustomFirmwareJetsamPatcher.adrpPage(
            data.loadLE(UInt32.self, at: site.xrefOffset),
            at: image.virtualAddress(ofTextOffset: site.xrefOffset),
        )
        #expect(site.stringVMA & ~0xFFF == page)

        // The gate is a conditional branch, and it branches to the return block.
        let disassembler = ARM64Disassembler()
        let gate = try #require(disassembler.disassembleOne(in: data, at: site.gateOffset))
        #expect(CustomFirmwareJetsamPatcher.conditionalBranchMnemonics.contains(gate.mnemonic))
        #expect(CustomFirmwareJetsamPatcher.branchTarget(gate) == site.returnBlockOffset)
    }

    /// The gate is the *earliest* qualifying branch in the function — any later
    /// one leaves more of the jetsam path running.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `gate is the earliest qualifying branch`() throws {
        let data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let image = try CustomFirmwareJetsamPatcher.Image(data: data)
        let site = try #require(try CustomFirmwareJetsamPatcher.locate(in: image))

        let disassembler = ARM64Disassembler()
        for offset in stride(from: site.functionOffset, to: site.gateOffset, by: 4) {
            guard let insn = disassembler.disassembleOne(in: data, at: offset),
                  CustomFirmwareJetsamPatcher.conditionalBranchMnemonics.contains(insn.mnemonic)
                  || insn.mnemonic == "b",
                  let target = CustomFirmwareJetsamPatcher.branchTarget(insn),
                  image.isInText(target)
            else { continue }
            #expect(
                !CustomFirmwareJetsamPatcher.isReturnBlock(target, in: image),
                "0x\(String(offset, radix: 16)) qualifies and is earlier than the chosen gate",
            )
        }
    }

    /// Rewriting the gate is what makes the second pass a no-op, and the scan
    /// has to see that on its own — the site it would pick on a re-run is a
    /// different, later branch, so checking the picked site afterwards would
    /// not catch it.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func `patched shape is recognised in place`() throws {
        var data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let outcome = try CustomFirmwareJetsamPatcher.patch(&data, log: nil)
        #expect(outcome.verdict == .patched)

        let image = try CustomFirmwareJetsamPatcher.Image(data: data)
        let site = try #require(try CustomFirmwareJetsamPatcher.locate(in: image))
        #expect(site.isAlreadyPatched)
        #expect(site.gateOffset == outcome.gateOffset)
        #expect(site.returnBlockOffset == outcome.returnBlockOffset)

        // And the later branch the reference would fall back to really is
        // there, live, into the same return block — which is why the check has
        // to live inside the scan.
        let gate = try #require(CustomFirmwareJetsamPatcher.findReturnGate(
            from: site.gateOffset + 4,
            to: site.xrefOffset,
            in: image,
        ))
        #expect(!gate.isUnconditional)
        #expect(gate.offset > outcome.gateOffset)
        #expect(gate.target == outcome.returnBlockOffset)
    }
}

// MARK: - Decoders and encoders

@Suite("launchd jetsam guard — instruction decoding")
struct CustomFirmwareJetsamDecodeTests {
    /// `ADD Xd, Xn, #imm12, LSL #0` only — an `LSL #12` form or a
    /// shifted-register add would make the xref land on the wrong string.
    @Test
    func `add immediate predicate rejects the neighbours`() throws {
        let disassembler = ARM64Disassembler()
        // The real thing: the ADD half of the string xref, straight out of the
        // project encoder rather than typed in.
        let addImm = try #require(ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0xA09))
        let decoded = try #require(disassembler.disassembleOne(addImm, at: 0))
        #expect(decoded.mnemonic == "add")
        #expect(CustomFirmwareJetsamPatcher.isAddImm64(addImm.loadLE(UInt32.self, at: 0)))

        // And the neighbours it must not accept.
        #expect(!CustomFirmwareJetsamPatcher.isAddImm64(0x9140_0000)) // add x0, x0, #0, lsl #12
        #expect(!CustomFirmwareJetsamPatcher.isAddImm64(0x1100_0000)) // add w0, w0, #0 (32-bit)
        #expect(!CustomFirmwareJetsamPatcher.isAddImm64(0x8B08_1534)) // add x20, x9, x8, lsl #5
        #expect(!CustomFirmwareJetsamPatcher.isAddImm64(0xD100_0000)) // sub x0, x0, #0
    }

    /// `adrpPage` against Capstone, which resolves the page for us. The inputs
    /// come from `ARM64Encoder.encodeADRP`, so nothing here is a typed-in word.
    @Test
    func `adrp page agrees with capstone`() throws {
        let disassembler = ARM64Disassembler()
        for (pc, target) in [
            (UInt64(0x1_0000_FB0C), UInt64(0x1_0006_5A09)), // forward
            (UInt64(0x1_0000_0000), UInt64(0x1_0000_0FFF)), // same page
            (UInt64(0x1_0005_0000), UInt64(0x1_0000_1234)), // backward
        ] {
            let encoded = try #require(ARM64Encoder.encodeADRP(rd: 0, pc: pc, target: target))
            let insn = try #require(disassembler.disassembleOne(encoded, at: pc))
            let operands = try #require(insn.aarch64?.operands)
            #expect(insn.mnemonic == "adrp")
            #expect(operands.count >= 2 && operands[1].type == AARCH64_OP_IMM)
            let word = encoded.loadLE(UInt32.self, at: 0)
            #expect(CustomFirmwareJetsamPatcher.adrpPage(word, at: pc) == UInt64(operands[1].imm))
            #expect(CustomFirmwareJetsamPatcher.adrpPage(word, at: pc) == target & ~0xFFF)
        }
    }

    /// The replacement is `ARM64Encoder`'s, and it decodes back to a `b` at the
    /// intended target — never a hand-written instruction word.
    @Test
    func `replacement branch round trips`() throws {
        let disassembler = ARM64Disassembler()
        for (site, target) in [(0xFA98, 0xFAEC), (0x1000, 0x800), (0x40, 0x40)] {
            let encoded = try #require(ARM64Encoder.encodeB(from: site, to: target))
            let insn = try #require(disassembler.disassembleOne(encoded, at: UInt64(site)))
            #expect(insn.mnemonic == "b")
            #expect(CustomFirmwareJetsamPatcher.branchTarget(insn) == target)
        }
    }

    /// The return-block probe rests entirely on two questions — "does this
    /// return?" and "does control leave here?" — and both are answered from
    /// Capstone's instruction groups. Pinned against real decodes, because a
    /// mnemonic prefix gets each of the last three rows below wrong: `brk` is
    /// not a branch, and a conditional branch falls through.
    @Test
    func `block boundaries come from capstone groups`() throws {
        let disassembler = ARM64Disassembler()
        func decode(_ bytes: Data) throws -> Instruction {
            try #require(disassembler.disassembleOne(bytes, at: 0))
        }

        // Returns, from the project's own pre-encoded constants.
        for bytes in [ARM64.ret, ARM64.retaa, ARM64.retab] {
            let insn = try decode(bytes)
            #expect(CustomFirmwareJetsamPatcher.isReturn(insn))
        }

        // Control leaves: an unconditional relative jump and a relative call,
        // both straight out of `ARM64Encoder`.
        for bytes in try [
            #require(ARM64Encoder.encodeB(from: 0, to: 8)),
            #require(ARM64Encoder.encodeBL(from: 0, to: 8)),
        ] {
            let insn = try decode(bytes)
            #expect(CustomFirmwareJetsamPatcher.leavesBlock(insn))
            #expect(!CustomFirmwareJetsamPatcher.isReturn(insn))
        }

        // The register-indirect forms, and the breakpoint that a `hasPrefix("br")`
        // test would have mistaken for one. No encoder writes these — no patch
        // emits them — so the words come from the ISA field layout and every
        // claim about them is checked against Capstone's decode.
        let indirect: [(UInt32, String, Bool)] = [
            (0xD61F_0000, "br", true), // br x0
            (0xD63F_0000, "blr", true), // blr x0
            (0xD420_0000, "brk", false), // brk #0 — an exception, not a branch
        ]
        for (word, mnemonic, ends) in indirect {
            let insn = try decode(ARM64.encodeU32(word))
            #expect(insn.mnemonic == mnemonic)
            #expect(CustomFirmwareJetsamPatcher.leavesBlock(insn) == ends)
            #expect(!CustomFirmwareJetsamPatcher.isReturn(insn))
        }

        // Conditional branches fall through, so they end nothing — this is what
        // lets a `b.cond` sit inside the return block being probed.
        let conditional: [UInt32] = [
            0x5400_0000 | (2 << 5), // b.eq #8
            0x3400_0000 | (2 << 5), // cbz w0, #8
            0x3600_0000 | (2 << 5), // tbz w0, #0, #8
        ]
        for word in conditional {
            let insn = try decode(ARM64.encodeU32(word))
            #expect(CustomFirmwareJetsamPatcher.conditionalBranchMnemonics.contains(insn.mnemonic))
            #expect(!CustomFirmwareJetsamPatcher.leavesBlock(insn))
            #expect(!CustomFirmwareJetsamPatcher.isReturn(insn))
        }
    }

    /// `cbz`/`tbz` put the target last; reading the last immediate is what
    /// keeps one code path covering all of them.
    @Test
    func `branch target reads the last immediate`() throws {
        let disassembler = ARM64Disassembler()

        // tbz w8, #1, #8 — three operands, target last, from the encoder.
        let tbz = try #require(ARM64Encoder.encodeTestBitBranch(
            nonzero: false,
            register: 8,
            bit: 1,
            from: 0,
            to: 8,
        ))
        let tbzInsn = try #require(disassembler.disassembleOne(tbz, at: 0))
        #expect(tbzInsn.mnemonic == "tbz")
        #expect(CustomFirmwareJetsamPatcher.branchTarget(tbzInsn) == 8)

        // cbz w0, #8 and b.eq #8 — two and one operand. Neither has an encoder
        // in `ARM64Encoder` (no patch writes one), so the words are built here
        // from the ISA field layout and checked against Capstone's decode.
        let cbz: UInt32 = 0x3400_0000 | (2 << 5) // imm19 = 8 / 4
        let beq: UInt32 = 0x5400_0000 | (2 << 5) // imm19 = 8 / 4, cond = EQ
        for word in [cbz, beq] {
            let insn = try #require(disassembler.disassembleOne(ARM64.encodeU32(word), at: 0))
            #expect(CustomFirmwareJetsamPatcher.conditionalBranchMnemonics.contains(insn.mnemonic))
            #expect(CustomFirmwareJetsamPatcher.branchTarget(insn) == 8)
        }
    }

    /// A substring anchor has to widen to the whole C string, because that is
    /// what an ADRP+ADD points at.
    @Test
    func `c string start widens to the whole string`() throws {
        var bytes = Data("first\u{0}jetsam property category (%s) is not initialized\u{0}".utf8)
        var hit = try #require(bytes.range(of: Data("property".utf8))?.lowerBound)
        #expect(CustomFirmwareJetsamPatcher.cStringStart(in: bytes, containing: hit, sectionStart: 0) == 6)

        // A string that starts at the section's first byte has no NUL in front.
        bytes = Data("jetsam property category\u{0}".utf8)
        hit = try #require(bytes.range(of: Data("property".utf8))?.lowerBound)
        #expect(CustomFirmwareJetsamPatcher.cStringStart(in: bytes, containing: hit, sectionStart: 0) == 0)
    }
}
