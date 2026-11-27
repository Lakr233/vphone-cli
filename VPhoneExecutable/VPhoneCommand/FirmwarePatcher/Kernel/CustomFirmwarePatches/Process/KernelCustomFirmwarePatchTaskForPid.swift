// KernelCustomFirmwarePatchTaskForPid.swift — CFW kernel patch: task_for_pid bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
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
        log("\n[CFW]_task_for_pid: upstream pid==0 gate NOP")

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
        emit(
            patchOff,
            ARM64.nop,
            patchID: "kernel-cfw-task_for_pid",
            virtualAddress: va,
            description: "NOP [_task_for_pid pid==0 gate]",
        )
        return true
    }

    /// NOP the `tbz` on bit 0 of `proc+0x15` that sits right before the MACF call in `task_for_pid`.
    ///
    /// Live read of launchd's `proc` (27.2): the byte is 0x7e, bit 0 clear, so this gate rejects root
    /// with KERN_FAILURE before `mac_proc_check_get_task` is ever reached. Every reject in the function
    /// returns the same 5, so the gate cannot be told apart from the return value.
    /// Shape (anchor function = the one `proc_ro_ref_task` is referenced from):
    ///   ldrb wN, [xM, #0x15]
    ///   tbz   wN, #0, fail
    ///   ldr   xK, [xJ, #8]
    ///   mov   x1, sp
    ///   mov   x0, xK
    ///   mov   w2, #0
    ///   bl    mac_proc_check_get_task
    @discardableResult
    func patchTaskForPidRootGate() -> Bool {
        log("\n[CFW]_task_for_pid: proc+0x15 bit0 gate NOP")

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
        while off + 0x20 < searchEnd {
            if matchUpstreamTaskForPidRootGate(at: off) {
                hits.append(off + 4)
            }
            off += 4
        }

        guard hits.count == 1 else {
            log("  [-] expected 1 upstream task_for_pid root-gate candidate, found \(hits.count)")
            return false
        }

        let patchOff = hits[0]
        let va = fileOffsetToVA(patchOff)
        emit(
            patchOff,
            ARM64.nop,
            patchID: "kernel-cfw-task_for_pid-root",
            virtualAddress: va,
            description: "NOP [_task_for_pid proc+0x15 bit0 gate]",
        )
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
              let cbzPidOps = cbzPid.detail?.operands, cbzPidOps.count == 2,
              cbzPidOps[0].type == .register,
              cbzPidOps[1].type == .immediate
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
              let cbzRetOps = cbzRet.detail?.operands, cbzRetOps.count == 2,
              cbzRetOps[0].type == .register,
              cbzRetOps[1].type == .immediate,
              cbzRetOps[1].imm == failTarget
        else { return nil }
        // x0
        guard disasm.firstRegisterName(cbzRet) == "x0" else { return nil }

        // Look backward for ldr wPid, [x?, #8] and ldr xTaskPtr, [x?, #0x10]
        let scanStart = max(funcStart, off - 0x18)
        var pidLoad: ARM64Instruction? = nil
        var taskptrLoad: ARM64Instruction? = nil
        var prevOff = scanStart
        while prevOff < off {
            let prevInsns = disasm.disassemble(in: buffer.data, at: prevOff, count: 1)
            guard let prev = prevInsns.first else { prevOff += 4; continue }
            if pidLoad == nil, isWLdrFromXImm(prev, imm: 8) {
                pidLoad = prev
            }
            if taskptrLoad == nil, isXLdrFromXImm(prev, imm: 0x10) {
                taskptrLoad = prev
            }
            prevOff += 4
        }
        guard let pid = pidLoad, taskptrLoad != nil else { return nil }
        // pid register must match cbz operand
        guard let pidOps = pid.detail?.operands, !pidOps.isEmpty,
              pidOps[0].reg == cbzPidOps[0].reg
        else { return nil }

        return off
    }

    private func matchUpstreamTaskForPidRootGate(at off: Int) -> Bool {
        let insns = disasm.disassemble(in: buffer.data, at: off, count: 7)
        guard insns.count >= 7 else { return false }
        let ldrb = insns[0], tbz = insns[1], ldr = insns[2], mov1 = insns[3]
        let mov0 = insns[4], mov2 = insns[5], blInsn = insns[6]

        // ldrb wN, [xM, #0x15]
        guard ldrb.mnemonic == "ldrb",
              let ldrbOps = ldrb.detail?.operands, ldrbOps.count == 2,
              ldrbOps[0].type == .register,
              ldrbOps[1].type == .memory,
              ldrbOps[1].mem.disp == 0x15
        else { return false }
        let reg = ldrbOps[0].reg

        // tbz wN, #0, fail
        guard tbz.mnemonic == "tbz",
              let tbzOps = tbz.detail?.operands, tbzOps.count == 3,
              tbzOps[0].type == .register, tbzOps[0].reg == reg,
              tbzOps[1].type == .immediate, tbzOps[1].imm == 0,
              tbzOps[2].type == .immediate
        else { return false }

        // ldr xK, [xJ, #8] / mov x1, sp / mov x0, xK / mov w2, #0 / bl
        guard ldr.mnemonic == "ldr",
              let ldrOps = ldr.detail?.operands, ldrOps.count == 2,
              ldrOps[1].type == .memory, ldrOps[1].mem.disp == 8,
              mov1.mnemonic == "mov",
              mov0.mnemonic == "mov", disasm.firstRegisterName(mov0) == "x0",
              blInsn.mnemonic == "bl",
              isMovImmZero(mov2, dstName: "w2")
        else { return false }

        return true
    }

    private func isMovImmZero(_ insn: ARM64Instruction, dstName: String) -> Bool {
        guard insn.mnemonic == "mov",
              let ops = insn.detail?.operands, ops.count == 2,
              ops[0].type == .register,
              ops[1].type == .immediate, ops[1].imm == 0
        else { return false }
        return disasm.firstRegisterName(insn) == dstName
    }

    private func isWLdrFromXImm(_ insn: ARM64Instruction, imm: Int32) -> Bool {
        guard insn.mnemonic == "ldr",
              let ops = insn.detail?.operands, ops.count >= 2,
              ops[0].type == .register,
              ops[1].type == .memory,
              ops[1].mem.disp == imm
        else { return false }
        return disasm.firstRegisterName(insn)?.hasPrefix("w") ?? false
    }

    private func isXLdrFromXImm(_ insn: ARM64Instruction, imm: Int32) -> Bool {
        guard insn.mnemonic == "ldr",
              let ops = insn.detail?.operands, ops.count >= 2,
              ops[0].type == .register,
              ops[1].type == .memory,
              ops[1].mem.disp == imm
        else { return false }
        return disasm.firstRegisterName(insn)?.hasPrefix("x") ?? false
    }
}
