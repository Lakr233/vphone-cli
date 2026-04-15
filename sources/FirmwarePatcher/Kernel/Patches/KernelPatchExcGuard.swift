// KernelPatchExcGuard.swift — Disable EXC_GUARD for Mach port guard violations.
//
// Research kernels enforce Mach port guard violations as fatal EXC_GUARD exceptions.
// Any app calling task_swap_exception_ports() on a guarded port is killed with
// EXC_GUARD. This commonly affects apps that install custom exception handlers.
// Production iOS kernels do not enforce these fatally.
//
// The enforcement path is: guard check → thread_guard_violation() → AST delivery.
// thread_guard_violation stores violation info in the thread struct and triggers an
// AST that delivers the fatal EXC_GUARD exception when the thread returns to userspace.
//
// Patch strategy: find thread_guard_violation via anchor chain and replace its first
// instruction with RET so it returns immediately without recording or delivering
// the violation. This disables ALL Mach port guard violations (acceptable for
// research VMs where guard enforcement is not needed).
//
// Anchor chain:
//   1. "com.apple.security.only-one-exception-port" string
//   2. → ADRP+ADD code ref in set_exception_behavior_allowed() [may be dead code]
//   3. → scan function body for BL to set_exception_behavior_violation()
//   4. → in that target, find BL to thread_guard_violation()
//   5. → patch thread_guard_violation prologue to RET

import Capstone
import Foundation

extension KernelPatcher {
    /// Disable Mach port guard violation enforcement (EXC_GUARD).
    ///
    /// Patches `thread_guard_violation` to return immediately, preventing
    /// all guard violations from being delivered as fatal exceptions.
    @discardableResult
    func patchExcGuardBehavior() -> Bool {
        log("\n[26] exc_guard: disable thread_guard_violation")

        // Step 1: locate the anchor string.
        guard let strOff = buffer.findString("com.apple.security.only-one-exception-port") else {
            log("  [-] anchor string not found")
            return false
        }

        // Step 2: find ADRP+ADD code reference (inside set_exception_behavior_allowed).
        let refs = findStringRefs(strOff)
        guard let (_, addOff) = refs.first else {
            log("  [-] no code ref to anchor string")
            return false
        }

        // Step 3: scan the surrounding function for BL instructions to find
        // set_exception_behavior_violation. It's the BL whose target starts with
        // PACIBSP and contains a TBZ/TBNZ within the first ~10 instructions
        // (the thid_should_crash check), followed by a BL (to thread_guard_violation).
        // Scan a wide window around the string ref (the function may be ~600 bytes)
        let scanStart = max(0, addOff - 200)
        let scanEnd = min(buffer.count - 4, addOff + 400)
        for off in stride(from: scanStart, to: scanEnd, by: 4) {
            let insn = buffer.readU32(at: off)
            guard insn >> 26 == 0b100101 else { continue } // BL
            let imm26 = insn & 0x03FF_FFFF
            let signedImm = Int32(bitPattern: imm26 << 6) >> 6
            let target = off + Int(signedImm) * 4
            guard target > 0, target + 40 <= buffer.count else { continue }
            // Check if target starts with PACIBSP
            guard buffer.readU32(at: target) == ARM64.pacibspU32 else { continue }
            // Check if target contains TBZ/TBNZ within first 20 instructions
            // followed by a BL (pattern of set_exception_behavior_violation)
            var hasTbCheck = false
            var innerBLTarget: Int? = nil
            for delta in stride(from: 4, through: 20 * 4, by: 4) {
                let ioff = target + delta
                guard ioff + 4 <= buffer.count else { break }
                let iraw = buffer.readU32(at: ioff)
                // TBZ/TBNZ: [30:25] = 01101x
                if (iraw & 0x7E000000) == 0x36000000 {
                    hasTbCheck = true
                }
                // After TBZ, look for BL
                if hasTbCheck, iraw >> 26 == 0b100101 {
                    let iimm26 = iraw & 0x03FF_FFFF
                    let isigned = Int32(bitPattern: iimm26 << 6) >> 6
                    let bt = ioff + Int(isigned) * 4
                    if bt > 0, bt + 4 <= buffer.count,
                       buffer.readU32(at: bt) == ARM64.pacibspU32
                    {
                        innerBLTarget = bt
                    }
                    break
                }
            }
            if let inner = innerBLTarget {
                log("  [*] set_exception_behavior_violation at foff 0x\(String(format: "%X", target))")
                log("  [*] thread_guard_violation at foff 0x\(String(format: "%X", inner))")
                // Step 4: patch thread_guard_violation → RET
                let va = fileOffsetToVA(inner)
                emit(
                    inner,
                    ARM64.ret,
                    patchID: "kernel.thread_guard_violation",
                    virtualAddress: va,
                    description: "PACIBSP→RET (disable guard violation delivery)"
                )
                return true
            }
        }

        log("  [-] thread_guard_violation not found via anchor chain")
        return false
    }
}
