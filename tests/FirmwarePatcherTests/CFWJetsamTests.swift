// CFWJetsamTests.swift — `CFWJetsamPatcher` against the reference it replaces.
//
// The bar for this port is not "the test passes". It is that the Swift patcher
// and `scripts/patchers/cfw_patch_jetsam.py` produce the same bytes from the
// same input, on the real `/sbin/launchd` out of iOS 27.0 / 24A435 — so the
// comparison tests below run BOTH implementations, each over its own clone of
// `ipsws/ref_extract/macho_pristine/launchd`, and diff the results.
//
// `codesign -v` is the second, fully independent reference: the patcher's
// `reattest: true` mode has to leave a binary that verifies, and the slot hash
// it writes has to equal the one the Python's own `cfw_macho_codesign.py`
// computes over the same patched bytes.
//
// The reference is on its way out — plan P1.5 deletes `scripts/patchers/`, and
// `ipsws/` is not in the repo — so every test that needs one is gated on it
// still being there and skips rather than fails when it is not. The pure
// decode/encode tests below have no such dependency and always run.
//
// Set `VPHONE_JETSAM_ARTIFACTS=<dir>` to keep each run's inputs and outputs for
// inspection from a shell; without it they land in a temporary directory.

import Capstone
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixtures

enum JetsamFixture {
    /// The package root, derived from this file rather than the working
    /// directory, which `swift test` does not promise.
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // FirmwarePatcherTests
        .deletingLastPathComponent() // tests
        .deletingLastPathComponent() // <root>

    /// The real, ad-hoc signed, thin arm64e `/sbin/launchd`.
    static let pristineLaunchd = repositoryRoot
        .appending(path: "ipsws/ref_extract/macho_pristine/launchd")
    static let python = repositoryRoot.appending(path: ".venv/bin/python3")
    static let pythonCFW = repositoryRoot.appending(path: "scripts/patchers/cfw.py")
    static let pythonCodeSign = repositoryRoot.appending(path: "scripts/patchers/cfw_macho_codesign.py")
    static let scriptsDirectory = repositoryRoot.appending(path: "scripts")
    static let codesign = URL(filePath: "/usr/bin/codesign")

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static var hasLaunchd: Bool { exists(pristineLaunchd) }
    static var hasPythonReference: Bool { exists(python) && exists(pythonCFW) }
    static var hasLaunchdAndPython: Bool { hasLaunchd && hasPythonReference }
    static var hasLaunchdAndCodesign: Bool { hasLaunchd && exists(codesign) }

    /// A directory for one test's artifacts. `VPHONE_JETSAM_ARTIFACTS` pins it
    /// so a shell can look at what a run produced.
    static func workDirectory(_ name: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment["VPHONE_JETSAM_ARTIFACTS"]
            .map { URL(filePath: $0) } ?? URL(filePath: NSTemporaryDirectory())
        let directory = base.appending(path: "CFWJetsamTests-\(name)")
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
        workingDirectory: URL? = nil
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

    /// `cfw.py patch-launchd-jetsam <file>` — the reference implementation.
    @discardableResult
    static func runPythonJetsam(on file: URL) throws -> (status: Int32, output: String) {
        try run(
            python,
            ["patchers/cfw.py", "patch-launchd-jetsam", file.path],
            workingDirectory: scriptsDirectory
        )
    }

    /// The hex number the reference prints straight after `marker`, so the
    /// expected values come out of the reference's own stdout instead of being
    /// written down here and going stale with the next firmware.
    static func hexAfter(_ marker: String, in output: String) -> Int? {
        guard let range = output.range(of: marker) else { return nil }
        return Int(String(output[range.upperBound...].prefix { $0.isHexDigit }), radix: 16)
    }

    /// The first byte offset at which two files differ, or nil when equal.
    static func firstDifference(_ lhs: Data, _ rhs: Data) -> Int? {
        if lhs.count != rhs.count { return min(lhs.count, rhs.count) }
        for index in 0 ..< lhs.count where lhs[index] != rhs[index] { return index }
        return nil
    }
}

// MARK: - Against the Python reference

@Suite("launchd jetsam guard — against the Python reference")
struct CFWJetsamReferenceTests {
    /// The whole point of the port: same input, same bytes out.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndPython))
    func matchesPythonByteForByte() throws {
        let work = try JetsamFixture.workDirectory("byte-equivalence")
        let swiftTarget = try JetsamFixture.launchdCopy(named: "launchd.swift", in: work)
        let pythonTarget = try JetsamFixture.launchdCopy(named: "launchd.python", in: work)

        let outcome = try CFWJetsamPatcher.patch(fileAt: swiftTarget, log: nil)
        #expect(outcome.verdict == .patched)

        let reference = try JetsamFixture.runPythonJetsam(on: pythonTarget)
        #expect(reference.status == 0, "reference patcher failed:\n\(reference.output)")

        let swiftBytes = try Data(contentsOf: swiftTarget)
        let pythonBytes = try Data(contentsOf: pythonTarget)
        let difference = JetsamFixture.firstDifference(swiftBytes, pythonBytes)
        #expect(
            difference == nil,
            "Swift and Python diverge at offset \(difference.map { "0x" + String($0, radix: 16) } ?? "-")"
        )

        // And the only thing that moved is inside the instruction the record
        // names. Not every one of the four bytes has to differ: on this image
        // `cbz w0, #0xfaec` is A0 02 00 34 and `b #0xfaec` is 15 00 00 14, so
        // byte 2 is 0x00 either way. Containment is the real claim — the whole
        // instruction was rewritten and nothing outside it was.
        let pristine = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let site = outcome.gateOffset ..< outcome.gateOffset + 4
        let changed = (0 ..< pristine.count).filter { pristine[$0] != swiftBytes[$0] }
        #expect(!changed.isEmpty)
        #expect(changed.allSatisfy(site.contains), "bytes changed outside the gate: \(changed)")
        #expect(Data(swiftBytes[site]) == outcome.record?.patchedBytes)
        #expect(Data(pristine[site]) == outcome.record?.originalBytes)
    }

    /// The gate the reference reports is the gate this finds. Checked against
    /// its stdout rather than a hard-coded offset, so the day the firmware
    /// moves, this moves with it.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndPython))
    func agreesWithPythonOnTheSite() throws {
        let work = try JetsamFixture.workDirectory("site-agreement")
        let pythonTarget = try JetsamFixture.launchdCopy(named: "launchd.python", in: work)
        let reference = try JetsamFixture.runPythonJetsam(on: pythonTarget)
        #expect(reference.status == 0)

        // Both intermediate anchors the reference prints, not just its answer,
        // so a port that agreed on the gate by luck would still be caught:
        //   "    xref at foff:0xFB0C"
        //   "  [+] Patched at 0xFA98: jetsam panic guard bypass"
        let referenceXref = try #require(JetsamFixture.hexAfter("xref at foff:0x", in: reference.output))
        let referenceGate = try #require(JetsamFixture.hexAfter("[+] Patched at 0x", in: reference.output))

        let data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let image = try CFWJetsamPatcher.Image(data: data)
        let site = try #require(try CFWJetsamPatcher.locate(in: image))
        #expect(site.xrefOffset == referenceXref)
        #expect(site.gateOffset == referenceGate)

        var patchable = data
        let outcome = try CFWJetsamPatcher.patch(&patchable, dryRun: true, log: nil)
        #expect(outcome.gateOffset == referenceGate)
        #expect(outcome.verdict == .wouldPatch)
    }
}

// MARK: - Idempotence

@Suite("launchd jetsam guard — idempotence")
struct CFWJetsamIdempotenceTests {
    /// The bug this patcher must not have. The reference re-patches a second,
    /// different branch on an already-patched binary; this one recognises its
    /// own work and stops.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func secondRunChangesNothing() throws {
        let work = try JetsamFixture.workDirectory("idempotence")
        let target = try JetsamFixture.launchdCopy(named: "launchd", in: work)

        let first = try CFWJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(first.verdict == .patched)
        let afterFirst = try Data(contentsOf: target)

        let second = try CFWJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(second.verdict == .alreadyPatched)
        #expect(second.gateOffset == first.gateOffset)
        #expect(second.returnBlockOffset == first.returnBlockOffset)
        #expect(second.record == nil)

        let afterSecond = try Data(contentsOf: target)
        #expect(JetsamFixture.firstDifference(afterFirst, afterSecond) == nil)

        // A third pass must not drift either.
        let third = try CFWJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(third.verdict == .alreadyPatched)
        let afterThird = try Data(contentsOf: target)
        #expect(JetsamFixture.firstDifference(afterFirst, afterThird) == nil)
    }

    /// Where the reference goes wrong, and proof that it does: run the Python
    /// twice and it lands a *second* site the pristine image never had patched.
    /// Recorded here so the divergence is a measurement, not a claim.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndPython))
    func referenceIsNotIdempotentAndThisIs() throws {
        let work = try JetsamFixture.workDirectory("reference-double-apply")
        let pythonTarget = try JetsamFixture.launchdCopy(named: "launchd.python", in: work)
        let swiftTarget = try JetsamFixture.launchdCopy(named: "launchd.swift", in: work)

        try JetsamFixture.runPythonJetsam(on: pythonTarget)
        let pythonOnce = try Data(contentsOf: pythonTarget)
        try JetsamFixture.runPythonJetsam(on: pythonTarget)
        let pythonTwice = try Data(contentsOf: pythonTarget)

        try CFWJetsamPatcher.patch(fileAt: swiftTarget, log: nil)
        let swiftOnce = try Data(contentsOf: swiftTarget)
        try CFWJetsamPatcher.patch(fileAt: swiftTarget, log: nil)
        let swiftTwice = try Data(contentsOf: swiftTarget)

        #expect(JetsamFixture.firstDifference(pythonOnce, swiftOnce) == nil)
        #expect(
            JetsamFixture.firstDifference(pythonOnce, pythonTwice) != nil,
            "the reference became idempotent — re-check what this port has to preserve"
        )
        #expect(JetsamFixture.firstDifference(swiftOnce, swiftTwice) == nil)
    }
}

// MARK: - Re-attestation

@Suite("launchd jetsam guard — signature re-attestation")
struct CFWJetsamSignatureTests {
    /// Default is the reference's behaviour: the four bytes and nothing else,
    /// because every call site re-signs with `ldid` straight afterwards.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndCodesign))
    func defaultLeavesTheSignatureStale() throws {
        let work = try JetsamFixture.workDirectory("stale-signature")
        let target = try JetsamFixture.launchdCopy(named: "launchd", in: work)

        let outcome = try CFWJetsamPatcher.patch(fileAt: target, log: nil)
        #expect(outcome.rehashes.isEmpty)

        let verify = try JetsamFixture.run(JetsamFixture.codesign, ["-v", target.path])
        #expect(verify.status != 0, "a patch with no re-attestation must not still verify")
    }

    /// `reattest: true` has to leave a binary `codesign` accepts — one page's
    /// slot hash, recomputed, tail slot included.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndCodesign))
    func reattestedBinaryVerifies() throws {
        let work = try JetsamFixture.workDirectory("reattested")
        let target = try JetsamFixture.launchdCopy(named: "launchd", in: work)

        let outcome = try CFWJetsamPatcher.patch(fileAt: target, reattest: true, log: nil)
        #expect(outcome.verdict == .patched)
        #expect(outcome.rehashes.count == 1)

        let rehash = try #require(outcome.rehashes.first)
        let patched = try Data(contentsOf: target)
        let directory = try #require(
            CFWMachOCodeSignature.codeDirectories(in: patched)?
                .first { $0.hashType == CFWMachOCodeSignature.hashTypeSHA256 }
        )
        #expect(rehash.pageIndex == outcome.gateOffset / directory.pageSize)

        let verify = try JetsamFixture.run(JetsamFixture.codesign, ["-v", target.path])
        #expect(verify.status == 0, "codesign -v rejected the re-attested binary:\n\(verify.output)")
    }

    /// The slot hash itself, against the Python's independent re-signer run
    /// over the Python's own patched bytes. Two implementations, one number.
    @Test(.enabled(if: JetsamFixture.hasLaunchdAndPython))
    func slotHashMatchesThePythonResigner() throws {
        guard JetsamFixture.exists(JetsamFixture.pythonCodeSign) else { return }
        let work = try JetsamFixture.workDirectory("slot-hash")
        let swiftTarget = try JetsamFixture.launchdCopy(named: "launchd.swift", in: work)
        let pythonTarget = try JetsamFixture.launchdCopy(named: "launchd.python", in: work)

        let outcome = try CFWJetsamPatcher.patch(fileAt: swiftTarget, reattest: true, log: nil)
        #expect(outcome.verdict == .patched)

        try JetsamFixture.runPythonJetsam(on: pythonTarget)
        let resign = try JetsamFixture.run(JetsamFixture.python, [
            "-c",
            """
            import sys
            sys.path.insert(0, \(quoted(JetsamFixture.scriptsDirectory.path)))
            from patchers.cfw_macho_codesign import reattest_modified_offsets
            reattest_modified_offsets(
                \(quoted(pythonTarget.path)), [\(outcome.gateOffset)], verbose=False
            )
            """,
        ])
        #expect(resign.status == 0, "reference re-signer failed:\n\(resign.output)")

        let swiftBytes = try Data(contentsOf: swiftTarget)
        let pythonBytes = try Data(contentsOf: pythonTarget)
        #expect(JetsamFixture.firstDifference(swiftBytes, pythonBytes) == nil)
    }

    private func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Anchoring, without a reference

@Suite("launchd jetsam guard — anchoring")
struct CFWJetsamAnchoringTests {
    /// Every step of the reveal lands where the disassembly says it should:
    /// the xref is inside the function, the gate is inside the function and
    /// before the xref, and the gate's target really does return.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func revealStepsAreSelfConsistent() throws {
        let data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let image = try CFWJetsamPatcher.Image(data: data)
        let site = try #require(try CFWJetsamPatcher.locate(in: image))

        #expect(CFWJetsamPatcher.panicStringAnchors.contains(site.anchor))
        #expect(!site.isAlreadyPatched)
        #expect(site.functionOffset <= site.gateOffset)
        #expect(site.gateOffset < site.xrefOffset)
        #expect(image.isInText(site.xrefOffset))
        #expect(image.isInText(site.returnBlockOffset))
        #expect(CFWJetsamPatcher.isReturnBlock(site.returnBlockOffset, in: image))

        // The function bound is a real prologue, not the blind fallback.
        #expect(data.loadLE(UInt32.self, at: site.functionOffset) == ARM64.pacibspU32)

        // The anchor string starts where the xref computes it to start.
        let page = CFWJetsamPatcher.adrpPage(
            data.loadLE(UInt32.self, at: site.xrefOffset),
            at: image.virtualAddress(ofTextOffset: site.xrefOffset)
        )
        #expect(site.stringVMA & ~0xFFF == page)

        // The gate is a conditional branch, and it branches to the return block.
        let disassembler = ARM64Disassembler()
        let gate = try #require(disassembler.disassembleOne(in: data, at: site.gateOffset))
        #expect(CFWJetsamPatcher.conditionalBranchMnemonics.contains(gate.mnemonic))
        #expect(CFWJetsamPatcher.branchTarget(gate) == site.returnBlockOffset)
    }

    /// The gate is the *earliest* qualifying branch in the function — any later
    /// one leaves more of the jetsam path running.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func gateIsTheEarliestQualifyingBranch() throws {
        let data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let image = try CFWJetsamPatcher.Image(data: data)
        let site = try #require(try CFWJetsamPatcher.locate(in: image))

        let disassembler = ARM64Disassembler()
        for offset in stride(from: site.functionOffset, to: site.gateOffset, by: 4) {
            guard let insn = disassembler.disassembleOne(in: data, at: offset),
                  CFWJetsamPatcher.conditionalBranchMnemonics.contains(insn.mnemonic)
                  || insn.mnemonic == "b",
                  let target = CFWJetsamPatcher.branchTarget(insn),
                  image.isInText(target)
            else { continue }
            #expect(
                !CFWJetsamPatcher.isReturnBlock(target, in: image),
                "0x\(String(offset, radix: 16)) qualifies and is earlier than the chosen gate"
            )
        }
    }

    /// Rewriting the gate is what makes the second pass a no-op, and the scan
    /// has to see that on its own — the site it would pick on a re-run is a
    /// different, later branch, so checking the picked site afterwards would
    /// not catch it.
    @Test(.enabled(if: JetsamFixture.hasLaunchd))
    func patchedShapeIsRecognisedInPlace() throws {
        var data = try Data(contentsOf: JetsamFixture.pristineLaunchd)
        let outcome = try CFWJetsamPatcher.patch(&data, log: nil)
        #expect(outcome.verdict == .patched)

        let image = try CFWJetsamPatcher.Image(data: data)
        let site = try #require(try CFWJetsamPatcher.locate(in: image))
        #expect(site.isAlreadyPatched)
        #expect(site.gateOffset == outcome.gateOffset)
        #expect(site.returnBlockOffset == outcome.returnBlockOffset)

        // And the later branch the reference would fall back to really is
        // there, live, into the same return block — which is why the check has
        // to live inside the scan.
        let gate = try #require(CFWJetsamPatcher.findReturnGate(
            from: site.gateOffset + 4,
            to: site.xrefOffset,
            in: image
        ))
        #expect(!gate.isUnconditional)
        #expect(gate.offset > outcome.gateOffset)
        #expect(gate.target == outcome.returnBlockOffset)
    }
}

// MARK: - Decoders and encoders

@Suite("launchd jetsam guard — instruction decoding")
struct CFWJetsamDecodeTests {
    /// `ADD Xd, Xn, #imm12, LSL #0` only — an `LSL #12` form or a
    /// shifted-register add would make the xref land on the wrong string.
    @Test
    func addImmediatePredicateRejectsTheNeighbours() throws {
        let disassembler = ARM64Disassembler()
        // The real thing: the ADD half of the string xref, straight out of the
        // project encoder rather than typed in.
        let addImm = try #require(ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0xA09))
        let decoded = try #require(disassembler.disassembleOne(addImm, at: 0))
        #expect(decoded.mnemonic == "add")
        #expect(CFWJetsamPatcher.isAddImm64(addImm.loadLE(UInt32.self, at: 0)))

        // And the neighbours it must not accept.
        #expect(!CFWJetsamPatcher.isAddImm64(0x9140_0000)) // add x0, x0, #0, lsl #12
        #expect(!CFWJetsamPatcher.isAddImm64(0x1100_0000)) // add w0, w0, #0 (32-bit)
        #expect(!CFWJetsamPatcher.isAddImm64(0x8B08_1534)) // add x20, x9, x8, lsl #5
        #expect(!CFWJetsamPatcher.isAddImm64(0xD100_0000)) // sub x0, x0, #0
    }

    /// `adrpPage` against Capstone, which resolves the page for us. The inputs
    /// come from `ARM64Encoder.encodeADRP`, so nothing here is a typed-in word.
    @Test
    func adrpPageAgreesWithCapstone() throws {
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
            #expect(CFWJetsamPatcher.adrpPage(word, at: pc) == UInt64(operands[1].imm))
            #expect(CFWJetsamPatcher.adrpPage(word, at: pc) == target & ~0xFFF)
        }
    }

    /// The replacement is `ARM64Encoder`'s, and it decodes back to a `b` at the
    /// intended target — never a hand-written instruction word.
    @Test
    func replacementBranchRoundTrips() throws {
        let disassembler = ARM64Disassembler()
        for (site, target) in [(0xFA98, 0xFAEC), (0x1000, 0x800), (0x40, 0x40)] {
            let encoded = try #require(ARM64Encoder.encodeB(from: site, to: target))
            let insn = try #require(disassembler.disassembleOne(encoded, at: UInt64(site)))
            #expect(insn.mnemonic == "b")
            #expect(CFWJetsamPatcher.branchTarget(insn) == target)
        }
    }

    /// The return-block probe rests entirely on two questions — "does this
    /// return?" and "does control leave here?" — and both are answered from
    /// Capstone's instruction groups. Pinned against real decodes, because a
    /// mnemonic prefix gets each of the last three rows below wrong: `brk` is
    /// not a branch, and a conditional branch falls through.
    @Test
    func blockBoundariesComeFromCapstoneGroups() throws {
        let disassembler = ARM64Disassembler()
        func decode(_ bytes: Data) throws -> Instruction {
            try #require(disassembler.disassembleOne(bytes, at: 0))
        }

        // Returns, from the project's own pre-encoded constants.
        for bytes in [ARM64.ret, ARM64.retaa, ARM64.retab] {
            let insn = try decode(bytes)
            #expect(CFWJetsamPatcher.isReturn(insn))
        }

        // Control leaves: an unconditional relative jump and a relative call,
        // both straight out of `ARM64Encoder`.
        for bytes in [
            try #require(ARM64Encoder.encodeB(from: 0, to: 8)),
            try #require(ARM64Encoder.encodeBL(from: 0, to: 8)),
        ] {
            let insn = try decode(bytes)
            #expect(CFWJetsamPatcher.leavesBlock(insn))
            #expect(!CFWJetsamPatcher.isReturn(insn))
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
            #expect(CFWJetsamPatcher.leavesBlock(insn) == ends)
            #expect(!CFWJetsamPatcher.isReturn(insn))
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
            #expect(CFWJetsamPatcher.conditionalBranchMnemonics.contains(insn.mnemonic))
            #expect(!CFWJetsamPatcher.leavesBlock(insn))
            #expect(!CFWJetsamPatcher.isReturn(insn))
        }
    }

    /// `cbz`/`tbz` put the target last; reading the last immediate is what
    /// keeps one code path covering all of them.
    @Test
    func branchTargetReadsTheLastImmediate() throws {
        let disassembler = ARM64Disassembler()

        // tbz w8, #1, #8 — three operands, target last, from the encoder.
        let tbz = try #require(ARM64Encoder.encodeTestBitBranch(
            nonzero: false, register: 8, bit: 1, from: 0, to: 8
        ))
        let tbzInsn = try #require(disassembler.disassembleOne(tbz, at: 0))
        #expect(tbzInsn.mnemonic == "tbz")
        #expect(CFWJetsamPatcher.branchTarget(tbzInsn) == 8)

        // cbz w0, #8 and b.eq #8 — two and one operand. Neither has an encoder
        // in `ARM64Encoder` (no patch writes one), so the words are built here
        // from the ISA field layout and checked against Capstone's decode.
        let cbz: UInt32 = 0x3400_0000 | (2 << 5) // imm19 = 8 / 4
        let beq: UInt32 = 0x5400_0000 | (2 << 5) // imm19 = 8 / 4, cond = EQ
        for word in [cbz, beq] {
            let insn = try #require(disassembler.disassembleOne(ARM64.encodeU32(word), at: 0))
            #expect(CFWJetsamPatcher.conditionalBranchMnemonics.contains(insn.mnemonic))
            #expect(CFWJetsamPatcher.branchTarget(insn) == 8)
        }
    }

    /// A substring anchor has to widen to the whole C string, because that is
    /// what an ADRP+ADD points at.
    @Test
    func cStringStartWidensToTheWholeString() throws {
        var bytes = Data("first\u{0}jetsam property category (%s) is not initialized\u{0}".utf8)
        var hit = try #require(bytes.range(of: Data("property".utf8))?.lowerBound)
        #expect(CFWJetsamPatcher.cStringStart(in: bytes, containing: hit, sectionStart: 0) == 6)

        // A string that starts at the section's first byte has no NUL in front.
        bytes = Data("jetsam property category\u{0}".utf8)
        hit = try #require(bytes.range(of: Data("property".utf8))?.lowerBound)
        #expect(CFWJetsamPatcher.cStringStart(in: bytes, containing: hit, sectionStart: 0) == 0)
    }
}
