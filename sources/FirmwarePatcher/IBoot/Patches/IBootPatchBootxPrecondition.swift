// IBootPatchBootxPrecondition.swift — modern iBoot bootx-handoff precondition bypass.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.

import Capstone
import Foundation

extension IBootPatcher {
    // MARK: - 6. Bootx-handoff precondition (modern iBoot, all stages)

    /// NOP the conditional branch gating the modern iBoot bootx-handoff
    /// panic.
    ///
    /// Gate signature (Capstone-decoded):
    ///
    ///     BL  <bit_getter>            ; tiny 4-insn `return bit_N([global])` fn
    ///     TBZ w0, #0, <panic_block>   ; patch target — NOP'd
    ///     ...
    ///     <panic_block>:
    ///         BL  <hash_getter>       ; 5-insn 4×MOV/MOVK+RET source-hash fn
    ///         MOV w?, #<lineno>       ; source line (any value)
    ///         BL  <log_func>          ; panic/log dispatcher
    ///
    /// `<bit_getter>` is `ADRP; LDRB; UBFX Wd, Wn, #?, #1; RET` — a
    /// "return one bit of one byte at a global address" function (rare in
    /// iBoot). The combination of "TBZ w0, #0 → panic" where the preceding
    /// instruction is BL to such a function, and the TBZ target is a
    /// hash-getter/MOVZ-line/BL-log triple, is the distinctive shape.
    ///
    /// Refuses to patch on ambiguity (multiple matches).
    func patchBootxPrecondition() {
        let hashGetters = enumerateHashGetters()
        let bitGetters = enumerateBitGetters()

        guard !hashGetters.isEmpty, !bitGetters.isEmpty else {
            if verbose {
                print("  [-] bootx precondition: hash-getter or bit-getter pattern absent")
            }
            return
        }

        let panicBlocks = enumeratePanicBlocks(hashGetters: hashGetters)
        if panicBlocks.isEmpty {
            if verbose {
                print("  [-] bootx precondition: no panic-shaped call blocks")
            }
            return
        }

        var gates = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 2 else { continue }
            for i in 1 ..< insns.count {
                let tbz = insns[i]
                let prev = insns[i - 1]
                guard tbz.mnemonic == "tbz" else { continue }
                guard
                    let tbzDet = tbz.aarch64,
                    tbzDet.operands.count >= 3,
                    tbzDet.operands[0].type == AARCH64_OP_REG,
                    tbzDet.operands[0].reg.rawValue == AARCH64_REG_W0.rawValue,
                    tbzDet.operands[1].type == AARCH64_OP_IMM,
                    tbzDet.operands[1].imm == 0,
                    tbzDet.operands[2].type == AARCH64_OP_IMM
                else { continue }
                let target = Int(tbzDet.operands[2].imm)
                guard panicBlocks.contains(target) else { continue }

                guard prev.mnemonic == "bl" else { continue }
                guard
                    let prevDet = prev.aarch64,
                    prevDet.operands.count >= 1,
                    prevDet.operands[0].type == AARCH64_OP_IMM
                else { continue }
                let blTarget = Int(prevDet.operands[0].imm)
                guard bitGetters.contains(blTarget) else { continue }

                gates.insert(Int(tbz.address))
            }
        }

        if gates.isEmpty {
            // 26.4+ construct; genuinely absent on previous iBoot versions.
            if verbose {
                print("  [.] bootx precondition: construct not present (pre-26.4 iBoot) — skipping")
            }
            return
        }
        if gates.count > 1 {
            if verbose {
                print("  [-] bootx precondition: ambiguous (\(gates.count) candidates)")
                for g in gates.sorted() {
                    print(String(format: "      0x%X", g))
                }
            }
            return
        }
        let gate = gates.first!
        emit(
            gate,
            ARM64.nop,
            id: "\(component).bootx_precondition",
            description: "bootx precondition: NOP gate TBZ",
        )
    }

    /// Enumerate 5-insn `MOVZ + 3×MOVK + RET` functions assembling a 64-bit
    /// constant into a single X register (used by iBoot's panic/log calls
    /// to load the source-file hash). Returns the file offsets at which
    /// each such function starts.
    private func enumerateHashGetters() -> Set<Int> {
        var out = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 5 else { continue }
            for i in 0 ..< (insns.count - 4) {
                guard insns[i].mnemonic == "mov" || insns[i].mnemonic == "movz" else { continue }
                guard insns[i + 1].mnemonic == "movk" else { continue }
                guard insns[i + 2].mnemonic == "movk" else { continue }
                guard insns[i + 3].mnemonic == "movk" else { continue }
                guard insns[i + 4].mnemonic == "ret" else { continue }
                // All four MOV/MOVK destinations must be the same register.
                var regs = Set<UInt32>()
                var ok = true
                for k in 0 ..< 4 {
                    guard
                        let det = insns[i + k].aarch64,
                        det.operands.count >= 1,
                        det.operands[0].type == AARCH64_OP_REG
                    else { ok = false; break }
                    regs.insert(det.operands[0].reg.rawValue)
                }
                guard ok, regs.count == 1 else { continue }
                out.insert(Int(insns[i].address))
            }
        }
        return out
    }

    /// Enumerate 4-insn `ADRP + LDRB + UBFX (width=1) + RET` functions —
    /// the "return one bit of one byte global" shape used as the
    /// precondition feature-check. Any bit position is accepted; only the
    /// width-1 extract is enforced.
    private func enumerateBitGetters() -> Set<Int> {
        var out = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 4 else { continue }
            for i in 0 ..< (insns.count - 3) {
                let mnems = [
                    insns[i].mnemonic, insns[i + 1].mnemonic,
                    insns[i + 2].mnemonic, insns[i + 3].mnemonic,
                ]
                guard mnems == ["adrp", "ldrb", "ubfx", "ret"] else { continue }
                guard
                    let det = insns[i + 2].aarch64,
                    det.operands.count >= 4,
                    det.operands[3].type == AARCH64_OP_IMM,
                    det.operands[3].imm == 1
                else { continue }
                out.insert(Int(insns[i].address))
            }
        }
        return out
    }

    /// Enumerate "panic block" call sites: 3-insn sequence of
    /// `BL <hash_getter>; MOV W?, #<imm>; BL <anything>`. Returns the file
    /// offset of the first BL in each such triple.
    private func enumeratePanicBlocks(hashGetters: Set<Int>) -> Set<Int> {
        var out = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 3 else { continue }
            for i in 0 ..< (insns.count - 2) {
                guard
                    insns[i].mnemonic == "bl",
                    insns[i + 1].mnemonic == "mov" || insns[i + 1].mnemonic == "movz",
                    insns[i + 2].mnemonic == "bl"
                else { continue }
                guard
                    let det = insns[i].aarch64,
                    det.operands.count >= 1,
                    det.operands[0].type == AARCH64_OP_IMM
                else { continue }
                let blTarget = Int(det.operands[0].imm)
                guard hashGetters.contains(blTarget) else { continue }
                out.insert(Int(insns[i].address))
            }
        }
        return out
    }
}
