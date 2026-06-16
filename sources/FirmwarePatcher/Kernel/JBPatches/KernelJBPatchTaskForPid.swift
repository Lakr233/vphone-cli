// KernelJBPatchTaskForPid.swift — JB kernel patch: task_for_pid bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// NOP the upstream early `pid == 0` reject gate in `task_for_pid`.
    ///
    /// Anchor: `proc_ro_ref_task` string → enclosing function.
    /// Shape:
    ///   ldr wPid, [xArgs, #8]
    ///   ldr xTaskPtr, [xArgs, #0x10]
    ///   ...
    ///   cbz wPid, fail
    ///   mov w1, #0
    ///   mov w2, #0
    ///   mov w3, #0
    ///   mov x4, #0
    ///   bl  port_name_to_task-like helper
    ///   cbz x0, fail       (same fail target)
    @discardableResult
    func patchTaskForPid() -> Bool {
        log("\n[JB] _task_for_pid: upstream pid==0 gate NOP")

        guard let strOff = buffer.findString("proc_ro_ref_task") else {
            log("  [-] task_for_pid anchor function not found")
            return false
        }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty, let funcStart = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] task_for_pid anchor function not found")
            return false
        }
        let searchEnd = min(buffer.count, funcStart + 0x800)

        var hits: [Int] = []
        var off = funcStart
        while off + 0x18 < searchEnd {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let first = insns.first, first.mnemonic == "cbz" else { off += 4; continue }
            if let site = matchUpstreamTaskForPidGate(at: off, funcStart: funcStart) {
                hits.append(site)
            }
            off += 4
        }

        guard hits.count == 1 else {
            log("  [-] expected 1 upstream task_for_pid candidate, found \(hits.count)")
            return false
        }

        let patchOff = hits[0]
        let va = fileOffsetToVA(patchOff)
        emit(patchOff, ARM64.nop,
             patchID: "kernelcache_jb.task_for_pid",
             virtualAddress: va,
             description: "NOP [_task_for_pid pid==0 gate]")
        return true
    }

    // MARK: - Private helpers

    private func matchUpstreamTaskForPidGate(at off: Int, funcStart: Int) -> Int? {
        let insns = disasm.disassemble(in: buffer.data, at: off, count: 7)
        guard insns.count >= 7 else { return nil }
        let cbzPid = insns[0], mov1 = insns[1], mov2 = insns[2]
        let mov3 = insns[3], mov4 = insns[4], blInsn = insns[5], cbzRet = insns[6]

        // cbz wPid, fail
        guard cbzPid.mnemonic == "cbz",
              let cbzPidOps = cbzPid.aarch64?.operands, cbzPidOps.count == 2,
              cbzPidOps[0].type == AARCH64_OP_REG,
              cbzPidOps[1].type == AARCH64_OP_IMM
        else { return nil }
        let failTarget = cbzPidOps[1].imm

        // mov w1, #0 / mov w2, #0 / mov w3, #0 / mov x4, #0
        guard isMovImmZero(mov1, dstName: "w1"),
              isMovImmZero(mov2, dstName: "w2"),
              isMovImmZero(mov3, dstName: "w3"),
              isMovImmZero(mov4, dstName: "x4")
        else { return nil }

        // bl helper
        guard blInsn.mnemonic == "bl" else { return nil }

        // cbz x0, fail (same target)
        guard cbzRet.mnemonic == "cbz",
              let cbzRetOps = cbzRet.aarch64?.operands, cbzRetOps.count == 2,
              cbzRetOps[0].type == AARCH64_OP_REG,
              cbzRetOps[1].type == AARCH64_OP_IMM,
              cbzRetOps[1].imm == failTarget
        else { return nil }
        // x0
        guard disasm.firstRegisterName(cbzRet) == "x0" else { return nil }

        // Look backward for ldr wPid, [x?, #8] and ldr xTaskPtr, [x?, #0x10]
        let scanStart = max(funcStart, off - 0x18)
        var pidLoad: Instruction? = nil
        var taskptrLoad: Instruction? = nil
        var prevOff = scanStart
        while prevOff < off {
            let prevInsns = disasm.disassemble(in: buffer.data, at: prevOff, count: 1)
            guard let prev = prevInsns.first else { prevOff += 4; continue }
            if pidLoad == nil, isWLdrFromXImm(prev, imm: 8) { pidLoad = prev }
            if taskptrLoad == nil, isXLdrFromXImm(prev, imm: 0x10) { taskptrLoad = prev }
            prevOff += 4
        }
        guard let pid = pidLoad, taskptrLoad != nil else { return nil }
        // pid register must match cbz operand
        guard let pidOps = pid.aarch64?.operands, !pidOps.isEmpty,
              pidOps[0].reg == cbzPidOps[0].reg
        else { return nil }

        return off
    }

    private func isMovImmZero(_ insn: Instruction, dstName: String) -> Bool {
        guard insn.mnemonic == "mov",
              let ops = insn.aarch64?.operands, ops.count == 2,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_IMM, ops[1].imm == 0
        else { return false }
        return disasm.firstRegisterName(insn) == dstName
    }

    private func isWLdrFromXImm(_ insn: Instruction, imm: Int32) -> Bool {
        guard insn.mnemonic == "ldr",
              let ops = insn.aarch64?.operands, ops.count >= 2,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_MEM,
              ops[1].mem.disp == imm
        else { return false }
        return disasm.firstRegisterName(insn)?.hasPrefix("w") ?? false
    }

    private func isXLdrFromXImm(_ insn: Instruction, imm: Int32) -> Bool {
        guard insn.mnemonic == "ldr",
              let ops = insn.aarch64?.operands, ops.count >= 2,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_MEM,
              ops[1].mem.disp == imm
        else { return false }
        return disasm.firstRegisterName(insn)?.hasPrefix("x") ?? false
    }
}
