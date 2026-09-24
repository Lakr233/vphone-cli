// CFWJetsam.swift — Defuse the launchd jetsam panic guard in /sbin/launchd.
//
// WHY
// ---
// `/sbin/launchd` is pid 1. Under the vphone kernel the jetsam property
// category for a Daemon job is never initialized, so the guard that checks it
// takes its failure path, logs "jetsam property category (%s) is not
// initialized" and tears the process down. initproc dying is a panic, and the
// panic is a loop: the guest never reaches userspace. Forcing the guard's
// success return is what lets the boot continue.
//
// The blast radius here is the largest of the six standalone Mach-O patchers:
// a wrong four bytes in pid 1 is a guest that never boots, with no shell to
// debug it from. Everything below is therefore anchored on what the compiler
// had to emit, never on where it happened to land.
//
// REVEAL PROCEDURE (no file offset, virtual address or instruction byte in
// this file is written down — all four steps derive their address):
//
//   1. String anchor — find the jetsam-not-initialized format string in the
//      image, then walk back to the start of the enclosing NUL-terminated C
//      string, because code references a string's start, never a substring.
//   2. Cross-reference — find the ADRP+ADD pair in `__TEXT,__text` that
//      computes that string's VA. That is the guard's failure path: the
//      instruction that loads the message it is about to log.
//   3. Enclosing function — walk back from the xref to the function's
//      `PACIBSP` prologue. This is the one place this port deliberately
//      diverges from `scripts/patchers/cfw_patch_jetsam.py`, which instead
//      scans a blind 0x300-byte window that can start inside the *previous*
//      function. Both pick the same instruction on iOS 27.0 / 24A435 (proven
//      byte for byte in `CFWJetsamTests`); the function bound is what keeps
//      that true when the code around it moves. The blind window survives as
//      the fallback for a function with no PAC prologue.
//   4. Gate — inside that function, take the earliest conditional branch whose
//      target is a *return block*: a basic block reaching `ret`/`retab`/`retaa`
//      without leaving through a branch first. Earliest, because that one skips
//      the most of the jetsam path. Rewrite it to an unconditional `b` to the
//      same target, so every path that reaches the gate returns through its
//      success path. Not every path reaches it: on 24A435 a `cbz x1` four
//      instructions earlier branches past the gate, as it did before the patch.
//
// The replacement comes from `ARM64Encoder.encodeB(from:to:)`, and the branch
// classification from Capstone's typed operands — never from operand text.
// Capstone 6 prints a branch target as `0x237ef22bc` where the Capstone 5 the
// Python links prints `#0x237ef22bc`; that string reaches a log line and a
// `PatchRecord` description, never a patched byte.
//
// IDEMPOTENCE
// -----------
// Running twice is a clean no-op. That is not free here, and getting it wrong
// is a live bug in the reference: rewriting the gate drops it out of the
// conditional-branch set, so the Python's backward scan walks past it and
// patches the *next* branch into the same return block — a second, wrong site
// on a binary that was already correct (`research/patches/patch_reference_capture.md`,
// "The non-idempotency itself is a separate, pre-existing bug"). The fix has to
// live inside the scan, because on a re-run neither implementation picks the
// site it patched before. So the scan collects unconditional `b`s into a return
// block as well, and an earlier one of those means a previous run already did
// the work. See `Verdict.alreadyPatched`.
//
// SIGNING
// -------
// `reattest` defaults to false, matching the reference: every call site
// (`scripts/cfw_install_{dev,jb,exp}.sh`, `cfw-kit/jb/install.sh`) runs `ldid`
// over the result immediately afterwards, which rebuilds the signature whole.
// Pass `reattest: true` when nothing downstream re-signs — it recomputes the
// slot hash of the one page this patch dirties through
// `CFWMachOCodeSignature`, short tail slot included, and the result passes
// `codesign -v`.

import Capstone
import Foundation

public enum CFWJetsamPatcher {
    // MARK: - Anchors

    /// The jetsam guard's failure message, most specific first, exactly as the
    /// reference orders them. The first anchor that resolves all the way to a
    /// patch site wins; one that resolves partway is abandoned for the next.
    ///
    /// The middle entry is the substring that actually matches on iOS 27.0 —
    /// the full sentence is a format string (`(%s)`) in the image, not the
    /// rendered text.
    public static let panicStringAnchors = [
        "jetsam property category (Daemon) is not initialized",
        "jetsam property category",
        "initproc exited -- exit reason namespace 7 subcode 0x1",
    ]

    /// Conditional branches that can gate the jetsam failure path. Matched
    /// against Capstone's mnemonic, which is the instruction's identity; the
    /// target comes from its typed immediate operand.
    static let conditionalBranchMnemonics: Set<String> = [
        "b.eq", "b.ne", "b.cs", "b.hs", "b.cc", "b.lo", "b.mi", "b.pl",
        "b.vs", "b.vc", "b.hi", "b.ls", "b.ge", "b.lt", "b.gt", "b.le",
        "cbz", "cbnz", "tbz", "tbnz",
    ]

    /// How far back to look for the enclosing function's `PACIBSP` prologue.
    /// A quarter of a page of instructions is well past any launchd function
    /// that references a log string.
    static let maxFunctionPrologueScan = 0x400

    /// The reference's blind backward window, kept as the fallback for a
    /// function whose prologue does not sign the link register.
    static let fallbackScanWindow = 0x300

    /// Instructions to decode from a branch target while deciding whether it is
    /// a return block.
    static let returnBlockProbeInstructions = 8

    /// `ARM64Disassembler` is stateless across calls and `Sendable`.
    private static let disassembler = ARM64Disassembler()

    // MARK: - Outcome

    /// What one run did.
    public struct Outcome: Sendable {
        public enum Verdict: Sendable, Equatable, CustomStringConvertible {
            /// The gate was live and has been rewritten.
            case patched
            /// An unconditional branch into the function's return block already
            /// sits ahead of every conditional one. A previous run wrote it;
            /// nothing was written and nothing needed re-attesting.
            case alreadyPatched
            /// A dry run that located a live gate and stopped short of writing.
            case wouldPatch

            public var description: String {
                switch self {
                case .patched: "patched"
                case .alreadyPatched: "already patched"
                case .wouldPatch: "would patch"
                }
            }
        }

        public let verdict: Verdict
        /// Which of `panicStringAnchors` resolved.
        public let anchor: String
        /// File offset of the branch that was (or would be) rewritten.
        public let gateOffset: Int
        /// Virtual address of the same.
        public let gateVMA: UInt64
        /// File offset the gate branches to — the function's return block.
        public let returnBlockOffset: Int
        /// File offset of the enclosing function's first instruction.
        public let functionOffset: Int
        /// The record of the single write, on a run that wrote or would write.
        public let record: PatchRecord?
        /// Slot hashes re-attestation replaced, on a run that wrote with
        /// `reattest: true`.
        public let rehashes: [CFWSlotRehash]

        public init(
            verdict: Verdict,
            anchor: String,
            gateOffset: Int,
            gateVMA: UInt64,
            returnBlockOffset: Int,
            functionOffset: Int,
            record: PatchRecord? = nil,
            rehashes: [CFWSlotRehash] = [],
        ) {
            self.verdict = verdict
            self.anchor = anchor
            self.gateOffset = gateOffset
            self.gateVMA = gateVMA
            self.returnBlockOffset = returnBlockOffset
            self.functionOffset = functionOffset
            self.record = record
            self.rehashes = rehashes
        }

        /// Sites this run put on disk — 1 on a live patch, 0 otherwise.
        public var sitesWritten: Int {
            verdict == .patched ? 1 : 0
        }
    }

    // MARK: - Entry points

    /// Patch `/sbin/launchd` in place.
    ///
    /// `reattest: true` recomputes the slot hash of the page the patch dirties
    /// so the binary still verifies on its own; leave it false when the caller
    /// re-signs (every current one does).
    @discardableResult
    public static func patch(
        fileAt url: URL,
        dryRun: Bool = false,
        reattest: Bool = false,
        log: ((String) -> Void)? = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    ) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let outcome = try patch(&data, dryRun: dryRun, reattest: reattest, log: log)
        if !dryRun, outcome.verdict == .patched {
            try data.write(to: url)
        }
        return outcome
    }

    /// Patch a `/sbin/launchd` image held in memory.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        dryRun: Bool = false,
        reattest: Bool = false,
        log: ((String) -> Void)? = nil,
    ) throws -> Outcome {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let image = try Image(data: data)
        guard let site = try locate(in: image, log: log) else {
            throw PatcherError.patchSiteNotFound(
                "launchd jetsam: no anchor string resolved to a conditional branch "
                    + "into its function's return block",
            )
        }

        let gateVMA = image.virtualAddress(ofTextOffset: site.gateOffset)
        log?("  Found jetsam anchor '\(site.anchor)'")
        log?(String(format: "    string start: va:0x%llX", site.stringVMA))
        log?(String(format: "    xref at foff:0x%X", site.xrefOffset))
        log?(String(format: "    function at foff:0x%X", site.functionOffset))

        if site.isAlreadyPatched {
            log?(String(
                format: "  [=] already patched at 0x%X: b 0x%X (jetsam panic guard bypass)",
                site.gateOffset,
                site.returnBlockOffset,
            ))
            return Outcome(
                verdict: .alreadyPatched,
                anchor: site.anchor,
                gateOffset: site.gateOffset,
                gateVMA: gateVMA,
                returnBlockOffset: site.returnBlockOffset,
                functionOffset: site.functionOffset,
            )
        }

        guard let branch = ARM64Encoder.encodeB(from: site.gateOffset, to: site.returnBlockOffset) else {
            throw PatcherError.invalidFormat(
                String(
                    format: "launchd jetsam: b 0x%X is out of range from 0x%X",
                    site.returnBlockOffset,
                    site.gateOffset,
                ),
            )
        }

        let original = Data(data[site.gateOffset ..< site.gateOffset + 4])
        let record = PatchRecord(
            patchID: "launchd_jetsam.panic_guard_bypass",
            component: "launchd_jetsam",
            fileOffset: site.gateOffset,
            virtualAddress: gateVMA,
            originalBytes: original,
            patchedBytes: branch,
            beforeDisasm: describe(original, at: site.gateOffset),
            afterDisasm: describe(branch, at: site.gateOffset),
            description: String(
                format: "conditional branch -> unconditional b 0x%X (jetsam panic guard bypass)",
                site.returnBlockOffset,
            ),
        )

        log?(String(
            format: "  %@ at 0x%X: %@ -> %@",
            dryRun ? "[.] would patch" : "[+] patching",
            site.gateOffset,
            record.beforeDisasm,
            record.afterDisasm,
        ))

        guard !dryRun else {
            return Outcome(
                verdict: .wouldPatch,
                anchor: site.anchor,
                gateOffset: site.gateOffset,
                gateVMA: gateVMA,
                returnBlockOffset: site.returnBlockOffset,
                functionOffset: site.functionOffset,
                record: record,
            )
        }

        data.replaceSubrange(site.gateOffset ..< site.gateOffset + 4, with: branch)
        guard Data(data[site.gateOffset ..< site.gateOffset + 4]) == branch else {
            throw PatcherError.patchVerificationFailed(
                String(format: "launchd jetsam: post-write verify failed at 0x%X", site.gateOffset),
            )
        }

        var rehashes: [CFWSlotRehash] = []
        if reattest {
            rehashes = try CFWMachOCodeSignature.reattest(&data, modifiedOffsets: [site.gateOffset])
            for rehash in rehashes {
                log?("  [.] re-attest \(rehash)")
            }
        }

        log?(String(format: "  [+] Patched at 0x%X: jetsam panic guard bypass", site.gateOffset))
        return Outcome(
            verdict: .patched,
            anchor: site.anchor,
            gateOffset: site.gateOffset,
            gateVMA: gateVMA,
            returnBlockOffset: site.returnBlockOffset,
            functionOffset: site.functionOffset,
            record: record,
            rehashes: rehashes,
        )
    }

    // MARK: - Image

    /// The parts of the Mach-O this patch reads: `__TEXT,__text`, and every
    /// file-backed section, so a string hit can be turned into a VA.
    struct Image {
        let data: Data
        let textOffset: Int
        let textSize: Int
        let textVMA: UInt64
        /// File-backed sections, in file order. Zero-fill sections (`__bss`,
        /// `__common`) are dropped: their `fileOffset` is 0, so leaving them in
        /// lets one claim the range `[0, size)` and mislocate a hit in the
        /// Mach-O header.
        let sections: [MachOSectionInfo]

        init(data rawData: Data) throws {
            // Zero-base so the integer subscripts used throughout are valid.
            let data = rawData.startIndex == 0 ? rawData : Data(rawData)
            guard data.count > 32, data.loadLE(UInt32.self, at: 0) == 0xFEED_FACF else {
                throw PatcherError.invalidFormat("launchd jetsam: not a 64-bit Mach-O")
            }
            let parsed = MachOParser.parseSections(from: data)
            guard let text = parsed["__TEXT,__text"] else {
                throw PatcherError.invalidFormat("launchd jetsam: __TEXT,__text not found")
            }
            guard Int(text.fileOffset) + Int(text.size) <= data.count else {
                throw PatcherError.invalidFormat("launchd jetsam: __TEXT,__text runs past the file")
            }
            self.data = data
            textOffset = Int(text.fileOffset)
            textSize = Int(text.size)
            textVMA = text.address
            sections = parsed.values
                .filter { $0.fileOffset != 0 && $0.size != 0 }
                .sorted { $0.fileOffset < $1.fileOffset }
        }

        var textEnd: Int {
            textOffset + textSize
        }

        func isInText(_ offset: Int) -> Bool {
            offset >= textOffset && offset < textEnd
        }

        /// VA of a `__TEXT,__text` file offset. `__text` is one contiguous
        /// mapping, so the two differ by a constant.
        func virtualAddress(ofTextOffset offset: Int) -> UInt64 {
            textVMA &+ UInt64(offset - textOffset)
        }

        /// The file-backed section containing `offset`, if any.
        func section(containing offset: Int) -> MachOSectionInfo? {
            sections.first {
                offset >= Int($0.fileOffset) && offset < Int($0.fileOffset) + Int($0.size)
            }
        }
    }

    // MARK: - Reveal

    /// Everything step 4 needs, plus what the log prints about how it got there.
    struct Site {
        let anchor: String
        let stringVMA: UInt64
        let xrefOffset: Int
        let functionOffset: Int
        let gateOffset: Int
        let returnBlockOffset: Int
        /// True when `gateOffset` already holds the unconditional branch.
        let isAlreadyPatched: Bool
    }

    /// Walk the anchors in order, taking the first that resolves all the way to
    /// a gate. An anchor that resolves partway — present but with no xref, or
    /// an xref with no qualifying branch — is abandoned for the next one, which
    /// is what the reference does.
    static func locate(in image: Image, log: ((String) -> Void)? = nil) throws -> Site? {
        for anchor in panicStringAnchors {
            guard let hit = image.data.range(of: Data(anchor.utf8))?.lowerBound else { continue }
            guard let section = image.section(containing: hit) else { continue }

            let stringOffset = cStringStart(in: image.data, containing: hit, sectionStart: Int(section.fileOffset))
            let stringVMA = section.address &+ UInt64(stringOffset - Int(section.fileOffset))

            guard let xrefOffset = findADRPADDReference(to: stringVMA, in: image) else {
                log?("  [.] anchor '\(anchor)' has no ADRP+ADD xref in __TEXT,__text")
                continue
            }

            let functionOffset = functionStart(before: xrefOffset, in: image)
            guard let gate = findReturnGate(from: functionOffset, to: xrefOffset, in: image) else {
                log?(String(format: "  [.] anchor '%@' has no return-block gate in [0x%X, 0x%X)",
                            anchor, functionOffset, xrefOffset))
                continue
            }

            return Site(
                anchor: anchor,
                stringVMA: stringVMA,
                xrefOffset: xrefOffset,
                functionOffset: functionOffset,
                gateOffset: gate.offset,
                returnBlockOffset: gate.target,
                isAlreadyPatched: gate.isUnconditional,
            )
        }
        return nil
    }

    /// Start of the NUL-terminated C string containing `offset`.
    ///
    /// Code references a string's first byte, so a substring anchor has to be
    /// widened to the whole string before its address means anything.
    static func cStringStart(in data: Data, containing offset: Int, sectionStart: Int) -> Int {
        var position = offset - 1
        while position >= sectionStart, data[position] != 0 {
            position -= 1
        }
        return position + 1
    }

    /// File offset of the ADRP in the first `ADRP Rd, page` / `ADD Rd, Rd, #off`
    /// pair in `__TEXT,__text` that computes `targetVMA`.
    ///
    /// The pair need not be adjacent — the compiler interleaves other setup
    /// between them — so the most recent ADRP per destination register is kept
    /// and matched against a later ADD that reads it, within eight instructions.
    ///
    /// Decoded from the instruction words rather than through Capstone: this is
    /// the one scan that covers all of `__text` (93k instructions in launchd),
    /// and the two opcode predicates below are exact. `ARM64Inst` documents the
    /// same split — raw predicates for the hot loops, Capstone once a specific
    /// instruction is in hand, which is what every semantic test in this file
    /// uses.
    static func findADRPADDReference(to targetVMA: UInt64, in image: Image) -> Int? {
        let targetPage = targetVMA & ~0xFFF
        let targetPageOffset = UInt32(targetVMA & 0xFFF)

        // Rd -> (instruction index, page the ADRP produced)
        var pending: [UInt32: (index: Int, page: UInt64)] = [:]

        var offset = image.textOffset
        var index = 0
        while offset + 4 <= image.textEnd {
            let word = image.data.loadLE(UInt32.self, at: offset)

            if ARM64Inst.isADRP(word) {
                pending[ARM64Inst.rd(word)] = (index, adrpPage(word, at: image.virtualAddress(ofTextOffset: offset)))
            } else if isAddImm64(word) {
                let rn = ARM64Inst.rn(word)
                if let adrp = pending[rn],
                   adrp.page == targetPage,
                   ARM64Inst.addSubImm12(word) == targetPageOffset,
                   index - adrp.index <= 8
                {
                    return image.textOffset + (adrp.index * 4)
                }
            }

            offset += 4
            index += 1
        }
        return nil
    }

    /// Page address an ADRP at `pc` produces.
    static func adrpPage(_ word: UInt32, at pc: UInt64) -> UInt64 {
        let immhi = (word >> 5) & 0x7FFFF
        let immlo = (word >> 29) & 0x3
        let imm21 = (immhi << 2) | immlo
        // Sign-extend the 21-bit immediate, then scale by the 4 KiB page.
        let signed = Int64(Int32(bitPattern: imm21 << 11) >> 11)
        return (pc & ~0xFFF) &+ UInt64(bitPattern: signed << 12)
    }

    /// `ADD Xd, Xn, #imm12` with `LSL #0` — `[31:22] = 1001000100`.
    ///
    /// Requiring `sh == 0` is what keeps `add xd, xn, #imm, lsl #12` out; a
    /// shifted-register `add` has a different `[28:24]` and never reaches here.
    static func isAddImm64(_ word: UInt32) -> Bool {
        (word & 0xFFC0_0000) == 0x9100_0000
    }

    /// First instruction of the function containing `offset`.
    ///
    /// `PACIBSP` is the prologue of every non-leaf arm64e function, and it is
    /// the only instruction that can only appear at a function's entry, which
    /// makes it the one reliable boundary here. A `ret` is not: this function's
    /// own success epilogue returns *before* the failure path the xref sits in,
    /// so a backward scan for `ret` stops inside the function it is trying to
    /// delimit.
    ///
    /// With no prologue in range this falls back to the reference's blind
    /// window, so a function that does not sign its link register still gets
    /// the reference's behaviour rather than none.
    static func functionStart(before offset: Int, in image: Image) -> Int {
        let floor = max(image.textOffset, offset - maxFunctionPrologueScan)
        var scan = offset - 4
        while scan >= floor {
            if image.data.loadLE(UInt32.self, at: scan) == ARM64.pacibspU32 {
                return scan
            }
            scan -= 4
        }
        return max(image.textOffset, offset - fallbackScanWindow)
    }

    /// The gate: the earliest branch in `[start, end)` whose target is a return
    /// block of the same function.
    ///
    /// Unconditional `b`s are collected alongside the conditional ones so that
    /// the shape this patch *writes* is recognised on a second run. An
    /// unconditional one earlier than every conditional candidate is a previous
    /// run's work — there is nothing left to do, and rewriting the next
    /// conditional branch instead (which is what the reference does) would put
    /// a second, unasked-for patch into pid 1.
    ///
    /// The limit of that signal, stated so nobody has to rediscover it: a
    /// compiler-emitted `b` to the epilogue, earlier in this window than any
    /// conditional gate, would read as already-patched on a *pristine* image and
    /// the patch would never be applied. There is none on iOS 27.0 / 24A435 —
    /// `gateIsTheEarliestQualifyingBranch` walks the window and proves it — and
    /// `revealStepsAreSelfConsistent` asserts `!isAlreadyPatched` on the pristine
    /// binary, so a firmware that grows one fails the suite rather than quietly
    /// shipping an unpatched pid 1.
    static func findReturnGate(
        from start: Int,
        to end: Int,
        in image: Image,
    ) -> (offset: Int, target: Int, isUnconditional: Bool)? {
        var liveGate: (offset: Int, target: Int)?
        var patchedGate: (offset: Int, target: Int)?

        var offset = start
        while offset + 4 <= end {
            defer { offset += 4 }
            guard let insn = disassembler.disassembleOne(in: image.data, at: offset) else { continue }

            let unconditional = insn.mnemonic == "b"
            guard unconditional || conditionalBranchMnemonics.contains(insn.mnemonic) else { continue }
            guard let target = branchTarget(insn), image.isInText(target) else { continue }
            guard isReturnBlock(target, in: image) else { continue }

            if unconditional {
                if patchedGate == nil {
                    patchedGate = (offset, target)
                }
            } else if liveGate == nil {
                liveGate = (offset, target)
            }
            if liveGate != nil, patchedGate != nil {
                break
            }
        }

        switch (liveGate, patchedGate) {
        case let (live?, patched?):
            return patched.offset < live.offset
                ? (patched.offset, patched.target, true)
                : (live.offset, live.target, false)
        case let (live?, nil):
            return (live.offset, live.target, false)
        case let (nil, patched?):
            return (patched.offset, patched.target, true)
        case (nil, nil):
            return nil
        }
    }

    /// Branch destination as a file offset, from Capstone's typed operands.
    ///
    /// Every branch form here carries its destination as its last immediate:
    /// `b`/`b.<cond>` have only one operand, `cbz`/`cbnz` a register then the
    /// target, `tbz`/`tbnz` a register, a bit number, then the target. Reading
    /// the last immediate covers all three without parsing operand text. The
    /// instruction was decoded at its own file offset, so the immediate is a
    /// file offset too.
    static func branchTarget(_ insn: Instruction) -> Int? {
        guard let detail = insn.aarch64 else { return nil }
        for operand in detail.operands.reversed() where operand.type == AARCH64_OP_IMM {
            return Int(operand.imm)
        }
        return nil
    }

    /// True when the instruction returns from the function — `ret`, `retaa`,
    /// `retab`, by Capstone's own classification rather than a mnemonic prefix.
    ///
    /// The prefix test this replaces (`hasPrefix("ret")`) is close enough on
    /// this image and wrong in principle; the group is what Capstone decoded
    /// the instruction to mean.
    static func isReturn(_ insn: Instruction) -> Bool {
        insn.groups.contains(UInt8(CS_GRP_RET.rawValue))
    }

    /// True when control leaves the block here without falling through: an
    /// unconditional jump (`b`, `br`, `braa`, …) or a call (`bl`, `blr`,
    /// `blraa`, …).
    ///
    /// A conditional branch is deliberately not one of these. It falls through,
    /// so the return can still be the instruction after it, which is what makes
    /// a compare-and-return epilogue a return block.
    ///
    /// Groups again, not prefixes: `hasPrefix("br")` also swallows `brk`, which
    /// is a breakpoint (`CS_GRP_INT`) and ends nothing, and `hasPrefix("bl")`
    /// would only reach the authenticated calls by accident.
    static func leavesBlock(_ insn: Instruction) -> Bool {
        if insn.groups.contains(UInt8(CS_GRP_CALL.rawValue)) {
            return true
        }
        return insn.groups.contains(UInt8(CS_GRP_JUMP.rawValue))
            && !conditionalBranchMnemonics.contains(insn.mnemonic)
    }

    /// True when the block at `offset` returns from the function.
    ///
    /// Decodes forward until the block returns, until control leaves it some
    /// other way (so it is not a return block), or until the end of `__text` or
    /// the probe limit.
    static func isReturnBlock(_ offset: Int, in image: Image) -> Bool {
        for step in 0 ..< returnBlockProbeInstructions {
            let probe = offset + step * 4
            guard probe + 4 <= image.textEnd else { return false }
            guard let insn = disassembler.disassembleOne(in: image.data, at: probe) else { continue }
            if isReturn(insn) {
                return true
            }
            if leavesBlock(insn) {
                return false
            }
        }
        return false
    }

    // MARK: - Logging

    /// `mnemonic operands` for a single instruction, for the record's
    /// before/after fields. Text only — nothing matches on it.
    static func describe(_ bytes: Data, at offset: Int) -> String {
        guard let insn = disassembler.disassembleOne(bytes, at: UInt64(offset)) else { return bytes.hex }
        return insn.operandString.isEmpty ? insn.mnemonic : "\(insn.mnemonic) \(insn.operandString)"
    }
}
