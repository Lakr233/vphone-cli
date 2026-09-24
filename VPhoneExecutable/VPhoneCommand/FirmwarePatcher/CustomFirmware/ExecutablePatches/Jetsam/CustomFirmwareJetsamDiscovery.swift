// CustomFirmwareJetsamDiscovery.swift — Locate the jetsam guard in launchd.

import Capstone
import Foundation

extension CustomFirmwareJetsamPatcher {
    /// `ARM64Disassembler` is stateless across calls and `Sendable`.
    private static let disassembler = ARM64Disassembler()

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
