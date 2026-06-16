// KernelJBPatchTaskConversion.swift — JB kernel patch: Task conversion eval bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy (fast raw scanner):
//   Locate the unique guard site in task_conversion_eval_internal
//   (osfmk/kern/ipc_tt.c) that resolves caller/victim against kernel_task:
//     ADRP Xk, <kernel_task>   ; [off - 8]  load the kernel_task global
//     LDR  Xk, [Xk, #imm]      ; [off - 4]  deref it
//     CMP  X0, Xk / Xk, X0     ; [off + 0]  caller == kernel_task   (patch site)
//     B.EQ <allow>             ; [off + 4]
//     CMP  X1, Xk / Xk, X1     ; [off + 8]  victim == kernel_task
//     B.EQ <skip>              ; [off + 12]
//     MOV  X19, X0             ; [off + 16]  save caller
//     MOV  X0, X1              ; [off + 20]  victim ->
//     BL   task_get_platform_binary
//     CBZ/CBNZ W0, ...         ; [off + 28]
//   Patch: replace the caller==kernel_task CMP with CMP XZR, XZR so the equality
//   always holds and the routine returns KERN_SUCCESS (allow). The compare-operand
//   order drifts across versions (26.1: `cmp Xk, X0`; 26.5: `cmp X0, Xk`), so both
//   orderings are accepted — only the kernel_task register and the X0/X1 roles are
//   pinned, never the operand position.

import Foundation

extension KernelJBPatcher {
    /// Task conversion eval bypass: patch the guard CMP to always be equal.
    @discardableResult
    func patchTaskConversionEvalInternal() -> Bool {
        log("\n[JB] task_conversion_eval_internal: cmp xzr,xzr")

        guard let range = kernTextRange ?? codeRanges.first.map({ ($0.start, $0.end) }) else {
            return false
        }
        let (ks, ke) = range

        let candidates = collectTaskConversionCandidates(start: ks, end: ke)

        guard candidates.count == 1 else {
            log("  [-] expected 1 task-conversion guard site, found \(candidates.count)")
            return false
        }

        let site = candidates[0]
        let va = fileOffsetToVA(site)
        emit(site, ARM64.cmpXzrXzr,
             patchID: "task_conversion_eval",
             virtualAddress: va,
             description: "cmp xzr,xzr [_task_conversion_eval_internal]")
        return true
    }

    // MARK: - Private scanner

    private func collectTaskConversionCandidates(start: Int, end: Int) -> [Int] {
        // True iff `cmp` compares register `reg` against the kernel_task register `k`
        // (in either operand position — the order drifts across versions).
        func comparesRegAgainst(_ cmp: UInt32, reg: UInt32, k: UInt32) -> Bool {
            (ARM64Inst.rn(cmp) == reg && ARM64Inst.rm(cmp) == k) ||
                (ARM64Inst.rn(cmp) == k && ARM64Inst.rm(cmp) == reg)
        }

        let movX19X0: UInt32 = 0xAA00_03F3 // mov x19, x0
        let movX0X1: UInt32 = 0xAA01_03E0 // mov x0, x1

        var out: [Int] = []
        var off = start + 8
        while off + 32 <= end {
            defer { off += 4 }

            // [off-8] ADRP Xk ; [off-4] LDR Xk, [Xk, #imm]  — kernel_task load.
            let adrp = buffer.readU32(at: off - 8)
            let ldr = buffer.readU32(at: off - 4)
            guard ARM64Inst.isADRP(adrp), ARM64Inst.isLDRImm64(ldr) else { continue }
            let k = ARM64Inst.rd(ldr)
            guard ARM64Inst.rn(ldr) == k, ARM64Inst.rd(adrp) == k else { continue }

            // [off] caller(X0) == kernel_task(Xk)  — the patch site.
            let c0 = buffer.readU32(at: off)
            guard ARM64Inst.isCMPReg64(c0), comparesRegAgainst(c0, reg: 0, k: k) else { continue }
            // [off+4] B.EQ allow
            let b0 = buffer.readU32(at: off + 4)
            guard ARM64Inst.isBEQ(b0) else { continue }
            // [off+8] victim(X1) == kernel_task(Xk)
            let c1 = buffer.readU32(at: off + 8)
            guard ARM64Inst.isCMPReg64(c1), comparesRegAgainst(c1, reg: 1, k: k) else { continue }
            // [off+12] B.EQ
            let b1 = buffer.readU32(at: off + 12)
            guard ARM64Inst.isBEQ(b1) else { continue }
            // [off+16] MOV X19,X0 ; [off+20] MOV X0,X1 ; [off+24] BL ; [off+28] CBZ/CBNZ W0
            guard buffer.readU32(at: off + 16) == movX19X0 else { continue }
            guard buffer.readU32(at: off + 20) == movX0X1 else { continue }
            guard ARM64Inst.isBL(buffer.readU32(at: off + 24)) else { continue }
            let cb = buffer.readU32(at: off + 28)
            guard ARM64Inst.isCBZorCBNZW(cb), ARM64Inst.rd(cb) == 0 else { continue } // result reg must be W0

            // Both B.EQ branches must be forward and nearby (same function body).
            guard let t0 = jbDecodeBranchTarget(at: off + 4)?.target,
                  let t1 = jbDecodeBranchTarget(at: off + 12)?.target else { continue }
            guard t0 > off, t1 > off, (t0 - off) <= 0x200, (t1 - off) <= 0x200 else { continue }

            out.append(off)
        }
        return out
    }
}
