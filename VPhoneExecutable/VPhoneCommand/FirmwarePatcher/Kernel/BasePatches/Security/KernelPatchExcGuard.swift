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

import Foundation
import VPhonePatchKit

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

        // Precise shape first: set_exception_behavior_violation raises the
        // guard on the current thread, `thread_guard_violation(current_thread(),
        // code, subcode, fatal)`, so its callee is the BL that follows
        // `mrs x0, tpidr_el1`. The iOS 18 kernels test thid_should_crash with
        // `ldrb ; cmp #1 ; b.ne`, not a TBZ, and the shape below then settles on
        // a zone allocator called from the same window; turning that into RET
        // made vm_map_enter fail in kmem_init.
        //
        // An iOS 18 base can also run on a cloudOS 26.x kernel (18.6.2 on
        // 26.1). There set_exception_behavior_violation keeps both calls apart:
        // the guard call, whose code is built between the MRS and the BL
        // (seven instructions), and send_set_exception_telemetry's
        // get_threadtask(current_thread()), whose BL directly follows its own
        // MRS. Only the second fits the six-instruction window, and turning
        // get_threadtask into RET makes the first page fault of boot recurse in
        // vm_fault until the kernel stack overflows. The guard call is the one
        // whose arguments carry the EXC_GUARD type, so that call wins.
        var currentThreadCallees = Set<Int>()
        var guardCodeCallees = Set<Int>()
        for off in stride(from: scanStart, to: scanEnd, by: 4) {
            guard let target = decodeBL(at: off), target > 0, target + 0x80 <= buffer.count,
                  buffer.readU32(at: target) == ARM64.pacibspU32
            else { continue }
            let insns = disasm.disassemble(in: buffer.data, at: target, count: 0x20)
            for (index, insn) in insns.enumerated() where insn.mnemonic == "mrs" {
                // A system register has no register-operand identity to compare.
                guard insn.operandString.lowercased() == "x0, tpidr_el1" else { continue }
                let following = insns.dropFirst(index + 1).prefix(10)
                guard let call = following.first(where: { $0.mnemonic == "bl" }),
                      let callee = decodeBL(at: Int(call.address)),
                      callee > 0, callee + 4 <= buffer.count,
                      buffer.readU32(at: callee) == ARM64.pacibspU32
                else { continue }
                let argumentSetup = following.prefix(while: { $0.address < call.address })
                if argumentSetup.contains(where: Self.setsMachPortGuardType) {
                    guardCodeCallees.insert(callee)
                }
                if argumentSetup.count < 6 {
                    currentThreadCallees.insert(callee)
                }
            }
        }
        let guardCallees = guardCodeCallees.isEmpty ? currentThreadCallees : guardCodeCallees
        if guardCallees.count == 1, let inner = guardCallees.first {
            log("  [*] thread_guard_violation at foff 0x\(String(format: "%X", inner)) (called on the current thread)")
            emit(
                inner,
                ARM64.ret,
                patchID: "kernel-boot-thread_guard_violation",
                virtualAddress: fileOffsetToVA(inner),
                description: "PACIBSP→RET (disable guard violation delivery)",
            )
            return true
        }

        for off in stride(from: scanStart, to: scanEnd, by: 4) {
            guard let target = decodeBL(at: off) else { continue }
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
                if (iraw & 0x7E00_0000) == 0x3600_0000 {
                    hasTbCheck = true
                }
                // After TBZ, look for BL
                if hasTbCheck, ARM64Inst.isBL(iraw) {
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
                    patchID: "kernel-boot-thread_guard_violation",
                    virtualAddress: va,
                    description: "PACIBSP→RET (disable guard violation delivery)",
                )
                return true
            }
        }

        log("  [-] thread_guard_violation not found via anchor chain")
        return false
    }

    /// `movk xN, #imm, lsl #48` whose top bits are GUARD_TYPE_MACH_PORT.
    ///
    /// EXC_GUARD_ENCODE_TYPE puts the guard type in bits 61-63 of the code,
    /// bits 13-15 of the top halfword. Matching the type exactly keeps the
    /// pointer-authentication discriminators blended in with the same
    /// `movk ..., lsl #48` (0xd507 and the like) out.
    static func setsMachPortGuardType(_ insn: ARM64Instruction) -> Bool {
        guard insn.mnemonic == "movk", let ops = insn.detail?.operands, ops.count == 2,
              ops[0].type == .register, ops[1].type == .immediate,
              ops[1].shift.type == .lsl, ops[1].shift.amount == 48
        else { return false }
        return ops[1].imm >> 13 == 0x1 // GUARD_TYPE_MACH_PORT
    }
}
