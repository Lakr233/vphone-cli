// KernelJBPatchDounmount.swift — JB: NOP the upstream cleanup call in dounmount.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal: string-anchor "dounmount:" → find the unique near-tail 4-arg zeroed cleanup
//   call: mov x0,xN ; mov w1,#0 ; mov w2,#0 ; mov w3,#0 ; bl ; mov x0,xN ; bl ; cbz x19,...
// Patch: NOP the first BL in that sequence.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// NOP the upstream cleanup call in _dounmount.
    @discardableResult
    func patchDounmount() -> Bool {
        log("\n[JB] _dounmount: upstream cleanup-call NOP")

        guard let foff = findFuncByString("dounmount:") else {
            log("  [-] 'dounmount:' anchor not found")
            return false
        }

        let funcEnd = findFuncEnd(foff, maxSize: 0x4000)
        guard let patchOff = findUpstreamCleanupCall(foff, end: funcEnd) else {
            log("  [-] upstream dounmount cleanup call not found")
            return false
        }

        emit(
            patchOff,
            ARM64.nop,
            patchID: "jb.dounmount.nop_cleanup_bl",
            virtualAddress: fileOffsetToVA(patchOff),
            description: "NOP [_dounmount upstream cleanup call]",
        )
        return true
    }

    // MARK: - Private helpers

    /// Scan for the 8-instruction upstream cleanup call pattern and return
    /// the file offset of the first BL, or nil if not uniquely found.
    private func findUpstreamCleanupCall(_ start: Int, end: Int) -> Int? {
        var hits: [Int] = []
        let limit = end - 0x1C
        guard start < limit else { return nil }

        for off in stride(from: start, to: limit, by: 4) {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 8)
            guard insns.count >= 8 else { continue }
            let i0 = insns[0], i1 = insns[1], i2 = insns[2], i3 = insns[3]
            let i4 = insns[4], i5 = insns[5], i6 = insns[6], i7 = insns[7]

            // mov x0, <xreg> ; mov w1,#0 ; mov w2,#0 ; mov w3,#0 ; bl ; mov x0,<same> ; bl ; cbz x..
            guard i0.mnemonic == "mov", i1.mnemonic == "mov",
                  i2.mnemonic == "mov", i3.mnemonic == "mov" else { continue }
            guard i4.mnemonic == "bl", i5.mnemonic == "mov",
                  i6.mnemonic == "bl", i7.mnemonic == "cbz" else { continue }

            // i0: mov x0, <src_reg>
            guard let srcReg = movRegRegDst(i0, dst: "x0") else { continue }
            // i1: mov w1, #0
            guard movImmZero(i1, dst: "w1") else { continue }
            // i2: mov w2, #0
            guard movImmZero(i2, dst: "w2") else { continue }
            // i3: mov w3, #0
            guard movImmZero(i3, dst: "w3") else { continue }
            // i5: mov x0, <same src_reg>
            guard let src5 = movRegRegDst(i5, dst: "x0"), src5 == srcReg else { continue }
            // i7: cbz x<reg>, ...
            guard cbzUsesXreg(i7) else { continue }

            hits.append(Int(i4.address))
        }

        if hits.count == 1 {
            return hits[0]
        }
        return nil
    }

    /// Return the source register name if instruction is `mov <dst>, <src_reg>`.
    private func movRegRegDst(_ insn: Instruction, dst: String) -> String? {
        guard insn.mnemonic == "mov" else { return nil }
        guard let detail = insn.aarch64, detail.operands.count == 2 else { return nil }
        let dstOp = detail.operands[0], srcOp = detail.operands[1]
        guard dstOp.type == AARCH64_OP_REG, srcOp.type == AARCH64_OP_REG else { return nil }
        guard regName(dstOp.reg) == dst else { return nil }
        return regName(srcOp.reg)
    }

    /// Return true if instruction is `mov <dst>, #0`.
    private func movImmZero(_ insn: Instruction, dst: String) -> Bool {
        guard insn.mnemonic == "mov" else { return false }
        guard let detail = insn.aarch64, detail.operands.count == 2 else { return false }
        let dstOp = detail.operands[0], srcOp = detail.operands[1]
        guard dstOp.type == AARCH64_OP_REG, regName(dstOp.reg) == dst else { return false }
        guard srcOp.type == AARCH64_OP_IMM, srcOp.imm == 0 else { return false }
        return true
    }

    /// Return true if instruction is `cbz x<N>, <label>` (64-bit register).
    private func cbzUsesXreg(_ insn: Instruction) -> Bool {
        guard insn.mnemonic == "cbz" else { return false }
        guard let detail = insn.aarch64, detail.operands.count >= 2 else { return false }
        let regOp = detail.operands[0]
        guard regOp.type == AARCH64_OP_REG else { return false }
        return regName(regOp.reg).hasPrefix("x")
    }

    /// Get the register name string for an aarch64_reg value.
    private func regName(_ reg: aarch64_reg) -> String {
        disasm.registerName(reg.rawValue) ?? "??"
    }
}
