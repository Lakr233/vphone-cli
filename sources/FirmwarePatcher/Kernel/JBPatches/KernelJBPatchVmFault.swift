// KernelJBPatchVmFault.swift — JB kernel patch: VM fault enter prepare bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Force the upstream cs_bypass fast-path in `_vm_fault_enter_prepare`.
    ///
    /// Expected semantic shape:
    ///   ... early in prologue: LDR Wflags, [fault_info_reg, #0x28]
    ///   ... later:             TBZ Wflags, #3, validation_path
    ///                          MOV Wtainted, #0
    ///                          B   post_validation_success
    ///
    /// NOPing the TBZ forces the fast-path unconditionally.
    @discardableResult
    func patchVmFaultEnterPrepare() -> Bool {
        log("\n[JB] _vm_fault_enter_prepare: NOP")

        var candidateFuncs: [Int] = []

        // Strategy 1: symbol table lookup
        if let funcOff = resolveSymbol("_vm_fault_enter_prepare") {
            candidateFuncs.append(funcOff)
        }

        // Strategy 2: string anchor
        if let strOff = buffer.findString("vm_fault_enter_prepare") {
            let refs = findStringRefs(strOff)
            for (adrpOff, _) in refs {
                if let funcOff = findFunctionStart(adrpOff) {
                    candidateFuncs.append(funcOff)
                }
            }
        }

        var candidateSites = Set<Int>()
        for funcStart in Set(candidateFuncs) {
            let funcEnd = findFuncEnd(funcStart, maxSize: 0x4000)
            if let site = findCsBypassGate(start: funcStart, end: funcEnd) {
                candidateSites.insert(site)
            }
        }

        if candidateSites.count == 1 {
            let patchOff = candidateSites.first!
            let va = fileOffsetToVA(patchOff)
            emit(patchOff, ARM64.nop,
                 patchID: "kernelcache_jb.vm_fault_enter_prepare",
                 virtualAddress: va,
                 description: "NOP [_vm_fault_enter_prepare]")
            return true
        } else if candidateSites.count > 1 {
            let list = candidateSites.sorted().map { String(format: "0x%X", $0) }.joined(separator: ", ")
            log("  [-] ambiguous vm_fault_enter_prepare candidates: \(list)")
            return false
        }

        log("  [-] patch site not found")
        return false
    }

    // MARK: - Private helpers

    /// Find the unique `tbz Wflags, #3 / mov Wt, #0 / b ...` gate inside
    /// a function, where Wflags is the register loaded from [base, #0x28]
    /// in the function prologue.
    private func findCsBypassGate(start: Int, end: Int) -> Int? {
        // Pass 1: collect registers loaded from [*, #0x28] in first 0x120 bytes
        var flagRegs = Set<UInt32>()
        let prologueEnd = min(end, start + 0x120)
        var off = start
        while off < prologueEnd {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first else { off += 4; continue }
            if insn.mnemonic == "ldr",
               let ops = insn.aarch64?.operands, ops.count >= 2,
               ops[0].type == AARCH64_OP_REG,
               ops[1].type == AARCH64_OP_MEM,
               ops[1].mem.base != AARCH64_REG_INVALID,
               ops[1].mem.disp == 0x28
            {
                if disasm.firstRegisterName(insn)?.hasPrefix("w") ?? false {
                    flagRegs.insert(ops[0].reg.rawValue)
                }
            }
            off += 4
        }

        guard !flagRegs.isEmpty else { return nil }

        // Pass 2: scan for TBZ Wflags, #3, target / MOV Wt, #0 / B target2
        var hits: [Int] = []
        let scanStart = max(start + 0x80, start)
        off = scanStart
        while off + 8 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let gate = insns.first else { off += 4; continue }
            guard gate.mnemonic == "tbz",
                  let gateOps = gate.aarch64?.operands, gateOps.count == 3,
                  gateOps[0].type == AARCH64_OP_REG,
                  flagRegs.contains(gateOps[0].reg.rawValue),
                  gateOps[1].type == AARCH64_OP_IMM, gateOps[1].imm == 3,
                  gateOps[2].type == AARCH64_OP_IMM
            else { off += 4; continue }

            // Check mov Wt, #0
            let movInsns = disasm.disassemble(in: buffer.data, at: off + 4, count: 1)
            guard let movInsn = movInsns.first,
                  movInsn.mnemonic == "mov",
                  let movOps = movInsn.aarch64?.operands, movOps.count == 2,
                  movOps[0].type == AARCH64_OP_REG,
                  movOps[1].type == AARCH64_OP_IMM, movOps[1].imm == 0
            else { off += 4; continue }
            guard disasm.firstRegisterName(movInsn)?.hasPrefix("w") ?? false else { off += 4; continue }

            // Check unconditional B
            let bInsns = disasm.disassemble(in: buffer.data, at: off + 8, count: 1)
            guard let bInsn = bInsns.first,
                  bInsn.mnemonic == "b",
                  let bOps = bInsn.aarch64?.operands, bOps.count == 1,
                  bOps[0].type == AARCH64_OP_IMM
            else { off += 4; continue }

            hits.append(off)
            off += 4
        }

        return hits.count == 1 ? hits[0] : nil
    }
}
