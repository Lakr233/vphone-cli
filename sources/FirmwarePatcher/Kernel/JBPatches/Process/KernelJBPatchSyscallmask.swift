// KernelJBPatchSyscallmask.swift — JB kernel patch: syscallmask C22 apply-to-proc
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy (retargeted C22): Hijack the low-level syscallmask apply wrapper.
//   1. Replace the pre-setter helper BL with `mov x17, x0` (save RO selector).
//   2. Replace the final tail `B setter` with `B cave`.
//   3. The cave:
//      a. 0x100 bytes of 0xFF (all-allow mask blob).
//      b. Code that calls zalloc_ro_mut (the mutation helper) to overwrite
//         the process's syscall mask with the all-0xFF blob.
//      c. Restores args and branches through to the normal setter.
//
// This preserves the normal setter path so all three mask types
// (unix syscall, mach trap, kernel MIG) go through their regular
// validation, but with an all-0xFF effective mask.

import Foundation

extension KernelJBPatcher {
    // MARK: - Constants

    private static let syscallmaskFFBlobSize = 0x100

    // MARK: - Entry Point

    /// Retargeted C22 patch: syscallmask apply to proc.
    @discardableResult
    func patchSyscallmaskApplyToProc() -> Bool {
        log("\n[JB] _syscallmask_apply_to_proc: retargeted upstream C22")

        // 1. Find the low-level apply wrapper.
        guard let funcOff = findSyscallmaskApplyFunc() else {
            log("  [-] syscallmask apply wrapper not found (fail-closed)")
            return false
        }

        // 2. Find the pre-setter helper BL site.
        guard let callOff = findSyscallmaskInjectBL(funcOff: funcOff) else {
            log("  [-] helper BL site not found in syscallmask wrapper")
            return false
        }

        // 3. Find the final tail branch into the setter core.
        guard let (branchOff, setterOff) = findSyscallmaskTailBranch(funcOff: funcOff) else {
            log("  [-] setter tail branch not found in syscallmask wrapper")
            return false
        }

        // 4. Resolve the mutation helper (structural: next function after helper's containing func).
        let helperTarget = decodeBL(at: callOff) ?? -1
        guard let mutatorOff = resolveSyscallmaskMutator(funcOff: funcOff, helperTarget: helperTarget) else {
            log("  [-] syscallmask mutation helper not resolved structurally")
            return false
        }

        // 5. Allocate cave: 0x100 blob + code.
        let caveSize = Self.syscallmaskFFBlobSize + 0x80
        guard let caveOff = findCodeCave(size: caveSize) else {
            log("  [-] no executable code cave found for C22 (\(caveSize) bytes)")
            return false
        }

        // 6. Build cave.
        guard let (caveBytes, codeOff) = buildSyscallmaskCave(
            caveOff: caveOff,
            zallocOff: mutatorOff,
            setterOff: setterOff,
        ) else {
            log("  [-] failed to encode C22 cave branches")
            return false
        }

        // 7. Patch: redirect tail branch to cave entry (code section, not blob).
        guard let branchToCave = ARM64Encoder.encodeB(from: branchOff, to: codeOff) else {
            log("  [-] tail branch cannot reach C22 cave")
            return false
        }

        // mov x17, x0  (save RO selector that was in x0 before the pre-setter BL)
        let movX17X0: UInt32 = 0xAA00_03F1 // ORR X17, XZR, X0
        emit(
            callOff,
            ARM64.encodeU32(movX17X0),
            patchID: "jb.syscallmask.save_selector",
            description: "mov x17,x0 [syscallmask C22 save RO selector]",
        )

        emit(
            branchOff,
            branchToCave,
            patchID: "jb.syscallmask.tail_redirect",
            description: "b cave [syscallmask C22 mutate mask then setter]",
        )

        emit(
            caveOff,
            caveBytes,
            patchID: "jb.syscallmask.c22_cave",
            description: "syscallmask C22 cave (ff blob 0x\(String(format: "%X", Self.syscallmaskFFBlobSize)) + structural mutator + setter tail)",
        )

        return true
    }

    // MARK: - Function Finders

    /// Find the high-level apply manager via its three error strings,
    /// then find the low-level wrapper it calls three times.
    private func findSyscallmaskApplyFunc() -> Int? {
        // Try symbol lookup first
        for name in ["_syscallmask_apply_to_proc", "_proc_apply_syscall_masks"] {
            if let off = resolveSymbol(name) {
                return off
            }
        }

        // Find manager via error strings
        guard let managerOff = findSyscallmaskManagerFunc() else { return nil }

        // Find the callee that appears 3+ times in the manager with w1 = 0, 1, 2
        return findSyscallmaskWrapperInManager(managerOff: managerOff)
    }

    /// Locate the high-level apply manager by its three error log strings.
    private func findSyscallmaskManagerFunc() -> Int? {
        let errorStrings = [
            "failed to apply unix syscall mask",
            "failed to apply mach trap mask",
            "failed to apply kernel MIG routine mask",
        ]
        var candidates: Set<Int>? = nil
        for str in errorStrings {
            guard let strOff = buffer.findString(str) else { return nil }
            let refs = findStringRefs(strOff)
            let funcStarts = Set(refs.compactMap { findFunctionStart($0.adrpOff) })
            guard !funcStarts.isEmpty else { return nil }
            if let c = candidates {
                candidates = c.intersection(funcStarts)
            } else {
                candidates = funcStarts
            }
            guard let c = candidates, !c.isEmpty else { return nil }
        }
        return candidates?.min()
    }

    /// Find the wrapper callee that appears 3+ times and is called with w1=0,1,2.
    private func findSyscallmaskWrapperInManager(managerOff: Int) -> Int? {
        let funcEnd = findFuncEnd(managerOff, maxSize: 0x300)
        var targetCalls: [Int: [Int]] = [:]
        var off = managerOff
        while off < funcEnd {
            if let target = decodeBL(at: off) {
                targetCalls[target, default: []].append(off)
            }
            off += 4
        }
        // Find callee appearing 3+ times, called with distinct w1 immediates 0,1,2
        for (target, calls) in targetCalls.sorted(by: { $0.value.count > $1.value.count }) {
            guard calls.count >= 3 else { continue }
            let whiches = Set(calls.compactMap { callOff in
                extractW1ImmNearCall(funcOff: managerOff, callOff: callOff)
            })
            if whiches.isSuperset(of: [0, 1, 2]) {
                return target
            }
        }
        return nil
    }

    /// Best-effort: look back up to 0x20 bytes from a BL for the last `mov w1, #imm`.
    private func extractW1ImmNearCall(funcOff: Int, callOff: Int) -> Int? {
        let scanStart = max(funcOff, callOff - 0x20)
        var off = callOff - 4
        while off >= scanStart {
            guard let insn = disasAt(off) else { off -= 4; continue }
            let op = insn.operandString.replacingOccurrences(of: " ", with: "")
            if insn.mnemonic == "mov", op.hasPrefix("w1,#") {
                let imm = String(op.dropFirst(4))
                if imm.hasPrefix("0x") || imm.hasPrefix("0X") {
                    if let v = Int(imm.dropFirst(2), radix: 16) {
                        return v
                    }
                } else {
                    if let v = Int(imm) {
                        return v
                    }
                }
            }
            off -= 4
        }
        return nil
    }

    /// Find the pre-setter helper BL site in the apply wrapper.
    /// Python: scan forward from func start, after the first `cbz x2`, return the next BL.
    private func findSyscallmaskInjectBL(funcOff: Int) -> Int? {
        let funcEnd = findFuncEnd(funcOff, maxSize: 0x280)
        let scanEnd = min(funcOff + 0x80, funcEnd)
        var seenCbzX2 = false
        var off = funcOff
        while off < scanEnd {
            guard let insn = disasAt(off) else { off += 4; continue }
            let op = insn.operandString.replacingOccurrences(of: " ", with: "")
            if insn.mnemonic == "cbz", op.hasPrefix("x2,") {
                seenCbzX2 = true
            } else if seenCbzX2, decodeBL(at: off) != nil {
                return off
            }
            off += 4
        }
        return nil
    }

    /// Find the final tail B into the setter core (last unconditional branch in the func).
    private func findSyscallmaskTailBranch(funcOff: Int) -> (Int, Int)? {
        let funcEnd = findFuncEnd(funcOff, maxSize: 0x280)
        var off = funcEnd - 4
        while off >= funcOff {
            // Check for unconditional B
            let val = buffer.readU32(at: off)
            if (val & 0xFC00_0000) == 0x1400_0000 {
                let imm26 = val & 0x3FFFFFF
                let signedImm = Int32(bitPattern: imm26 << 6) >> 6
                let target = off + Int(signedImm) * 4
                let inText = kernTextRange.map { target >= $0.0 && target < $0.1 } ?? false
                if inText, decodeBL(at: off) == nil {
                    return (off, target)
                }
            }
            off -= 4
        }
        return nil
    }

    /// Resolve the mutation helper: the function immediately following the helper's
    /// containing function in text. It must start with PACIBSP or BTI.
    private func resolveSyscallmaskMutator(funcOff _: Int, helperTarget: Int) -> Int? {
        guard helperTarget >= 0 else { return nil }
        guard let helperFunc = findFunctionStart(helperTarget) else { return nil }
        let mutatorOff = findFuncEnd(helperFunc, maxSize: 0x200)
        guard mutatorOff > helperTarget, mutatorOff < helperFunc + 0x200 else { return nil }
        guard mutatorOff + 4 <= buffer.count else { return nil }
        let headInsn = buffer.readU32(at: mutatorOff)
        guard headInsn == ARM64.pacibspU32 || headInsn == 0xD503_241F /* bti */ else { return nil }
        return mutatorOff
    }

    // MARK: - C22 Cave Builder

    /// Build the C22 cave: 0x100 0xFF-blob + code section.
    ///
    /// Returns (caveBytes, codeStartFoff) or nil on branch encoding failure.
    ///
    /// The code section contract:
    ///   x0 = struct proc* (RO object, from original arg)
    ///   x1 = mask_type    (original arg 1)
    ///   x2 = mask_ptr     (original arg 2, the kernel mask buffer to overwrite)
    ///   x3 = mask_len     (original arg 3)
    ///   x17 = original x0 (RO zalloc selector, saved by the injected `mov x17, x0`)
    ///
    /// Cave code layout (27 instructions):
    ///   0: cbz x2, #exit         (skip if mask_ptr null)
    ///   1: sub sp, sp, #0x40
    ///   2: stp x19, x20, [sp, #0x10]
    ///   3: stp x21, x22, [sp, #0x20]
    ///   4: stp x29, x30, [sp, #0x30]
    ///   5: mov x19, x0
    ///   6: mov x20, x1
    ///   7: mov x21, x2
    ///   8: mov x22, x3
    ///   9: mov x8, #8           (word size)
    ///  10: mov x0, x17          (RO zalloc selector)
    ///  11: mov x1, x21          (dst = mask_ptr)
    ///  12: mov x2, #0           (src offset = 0)
    ///  13: adr x3, #blobDelta   (src = cave blob start)
    ///  14: udiv x4, x22, x8     (x4 = mask_len / 8)
    ///  15: msub x10, x4, x8, x22 (x10 = mask_len % 8)
    ///  16: cbz x10, #8          (if exact multiple, skip +1)
    ///  17: add x4, x4, #1       (round up)
    ///  18: bl mutatorOff
    ///  19: mov x0, x19
    ///  20: mov x1, x20
    ///  21: mov x2, x21
    ///  22: mov x3, x22
    ///  23: ldp x19, x20, [sp, #0x10]
    ///  24: ldp x21, x22, [sp, #0x20]
    ///  25: ldp x29, x30, [sp, #0x30]
    ///  26: add sp, sp, #0x40
    ///  27: b setterOff   (tail-call into setter)
    private func buildSyscallmaskCave(
        caveOff: Int,
        zallocOff: Int,
        setterOff: Int,
    ) -> (Data, Int)? {
        let blobSize = Self.syscallmaskFFBlobSize
        let codeOff = caveOff + blobSize

        var code: [Data] = []

        // 0: cbz x2, #exit (28 instrs * 4 = 0x70 — jump to after add sp)
        code.append(ARM64.encodeU32(ARM64.syscallmask_cbzX2_0x6c))
        // 1: sub sp, sp, #0x40
        code.append(ARM64.encodeU32(ARM64.syscallmask_subSP_0x40))
        // 2: stp x19, x20, [sp, #0x10]
        code.append(ARM64.encodeU32(ARM64.syscallmask_stpX19X20_0x10))
        // 3: stp x21, x22, [sp, #0x20]
        code.append(ARM64.encodeU32(ARM64.syscallmask_stpX21X22_0x20))
        // 4: stp x29, x30, [sp, #0x30]
        code.append(ARM64.encodeU32(ARM64.syscallmask_stpFP_LR_0x30))
        // 5: mov x19, x0
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX19_X0))
        // 6: mov x20, x1
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX20_X1))
        // 7: mov x21, x2
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX21_X2))
        // 8: mov x22, x3
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX22_X3))
        // 9: mov x8, #8
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX8_8))
        // 10: mov x0, x17
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX0_X17))
        // 11: mov x1, x21
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX1_X21))
        // 12: mov x2, #0
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX2_0))

        // 13: adr x3, #blobDelta (blob is at caveOff, code is at codeOff)
        let adrOff = codeOff + code.count * 4
        let blobDelta = caveOff - adrOff
        // ADR x3, #delta: sf=0, op=1, immlo = delta & 3, immhi = (delta >> 2) & 0x7FFFF
        // Encode: [31]=0, [30:29]=immlo, [28:24]=10000, [23:5]=immhi, [4:0]=Rd(3)
        let adrImm = blobDelta
        let immlo = UInt32(bitPattern: Int32(adrImm)) & 0x3
        let immhi = (UInt32(bitPattern: Int32(adrImm)) >> 2) & 0x7FFFF
        let adrInsn: UInt32 = (immlo << 29) | (0b10000 << 24) | (immhi << 5) | 3
        code.append(ARM64.encodeU32(adrInsn))

        // 14: udiv x4, x22, x8
        code.append(ARM64.encodeU32(ARM64.syscallmask_udivX4_X22_X8))
        // 15: msub x10, x4, x8, x22
        code.append(ARM64.encodeU32(ARM64.syscallmask_msubX10_X4_X8_X22))
        // 16: cbz x10, #8  (skip 2 instrs)
        code.append(ARM64.encodeU32(ARM64.syscallmask_cbzX10_8))
        // 17: add x4, x4, #1
        code.append(ARM64.encodeU32(ARM64.syscallmask_addX4_X4_1))

        // 18: bl mutatorOff
        let blOff = codeOff + code.count * 4
        guard let blMutator = ARM64Encoder.encodeBL(from: blOff, to: zallocOff) else { return nil }
        code.append(blMutator)

        // 19: mov x0, x19
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX0_X19))
        // 20: mov x1, x20
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX1_X20))
        // 21: mov x2, x21
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX2_X21))
        // 22: mov x3, x22
        code.append(ARM64.encodeU32(ARM64.syscallmask_movX3_X22))
        // 23: ldp x19, x20, [sp, #0x10]
        code.append(ARM64.encodeU32(ARM64.syscallmask_ldpX19X20_0x10))
        // 24: ldp x21, x22, [sp, #0x20]
        code.append(ARM64.encodeU32(ARM64.syscallmask_ldpX21X22_0x20))
        // 25: ldp x29, x30, [sp, #0x30]
        code.append(ARM64.encodeU32(ARM64.syscallmask_ldpFP_LR_0x30))
        // 26: add sp, sp, #0x40
        code.append(ARM64.encodeU32(ARM64.syscallmask_addSP_0x40))

        // 27: b setterOff (tail-call)
        let branchBackOff = codeOff + code.count * 4
        guard let branchBack = ARM64Encoder.encodeB(from: branchBackOff, to: setterOff) else { return nil }
        code.append(branchBack)

        let codeBytes = code.reduce(Data(), +)
        let blobBytes = Data(repeating: 0xFF, count: blobSize)
        return (blobBytes + codeBytes, codeOff)
    }
}
