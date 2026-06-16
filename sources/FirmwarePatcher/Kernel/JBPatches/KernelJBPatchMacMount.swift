// KernelJBPatchMacMount.swift — JB kernel patch: MAC mount bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Apply the upstream twin bypasses in the mount-role wrapper.
    ///
    /// Patches two sites in the wrapper that decides whether execution can
    /// continue into `mount_common()`:
    ///   - `tbnz wFlags, #5, deny` → NOP
    ///   - `ldrb w8, [xTmp, #1]`   → `mov x8, xzr`
    ///
    /// Runtime design:
    ///   1. Recover `mount_common` from the `"mount_common()"` string.
    ///   2. Scan a bounded neighborhood for local callers.
    ///   3. Select the unique caller containing both upstream gates.
    @discardableResult
    func patchMacMount() -> Bool {
        log("\n[JB] ___mac_mount: upstream twin bypass")

        guard let strOff = buffer.findString("mount_common()") else {
            log("  [-] mount_common anchor function not found")
            return false
        }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty, let mountCommon = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] mount_common anchor function not found")
            return false
        }

        // Scan +/-0x5000 of mount_common for callers in code ranges
        let searchStart = max(codeRanges.first?.start ?? 0, mountCommon - 0x5000)
        let searchEnd = min(codeRanges.first?.end ?? buffer.count, mountCommon + 0x5000)

        var candidates: [Int: (Int, Int)] = [:] // caller → (flagGate, stateGate)
        var off = searchStart
        while off < searchEnd {
            guard let blTarget = jbDecodeBL(at: off), blTarget == mountCommon else { off += 4; continue }
            guard let caller = findFunctionStart(off), caller != mountCommon,
                  candidates[caller] == nil
            else { off += 4; continue }
            let callerEnd = findFuncEnd(caller, maxSize: 0x1200)
            if let sites = matchUpstreamMountWrapper(start: caller, end: callerEnd, mountCommon: mountCommon) {
                candidates[caller] = sites
            }
            off += 4
        }

        guard candidates.count == 1 else {
            log("  [-] expected 1 upstream mac_mount candidate, found \(candidates.count)")
            return false
        }

        let (branchOff, movOff) = candidates.values.first!
        let va1 = fileOffsetToVA(branchOff)
        let va2 = fileOffsetToVA(movOff)

        // Clear the actual register the role-state byte was loaded into (W8 on every
        // build seen, but derived from the LDRB so the patch follows the encoding).
        guard let clearBytes = encodeMovXZeroForLdrbDest(at: movOff) else {
            log("  [-] mac_mount state gate: could not encode register clear")
            return false
        }

        emit(branchOff, ARM64.nop,
             patchID: "kernelcache_jb.mac_mount.flag_gate",
             virtualAddress: va1,
             description: "NOP [___mac_mount upstream flag gate]")
        emit(movOff, clearBytes,
             patchID: "kernelcache_jb.mac_mount.state_clear",
             virtualAddress: va2,
             description: "mov x,xzr [___mac_mount upstream state clear]")
        return true
    }

    // MARK: - Private helpers

    private func matchUpstreamMountWrapper(start: Int, end: Int, mountCommon: Int) -> (Int, Int)? {
        // Require the wrapper to actually call mount_common.
        var callsMountCommon = false
        for off in stride(from: start, to: end, by: 4) {
            if jbDecodeBL(at: off) == mountCommon { callsMountCommon = true; break }
        }
        guard callsMountCommon else { return nil }

        guard let flagGate = findFlagGate(start: start, end: end) else { return nil }
        guard let stateGate = findStateGate(start: start, end: end) else { return nil }
        return (flagGate, stateGate)
    }

    /// Find a unique `tbnz wN, #5, <deny>` where deny-block starts with `mov w?, #1`.
    private func findFlagGate(start: Int, end: Int) -> Int? {
        var hits: [Int] = []
        var off = start
        while off + 4 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first else { off += 4; continue }
            guard insn.mnemonic == "tbnz",
                  let ops = insn.aarch64?.operands, ops.count == 3,
                  ops[0].type == AARCH64_OP_REG,
                  ops[1].type == AARCH64_OP_IMM, ops[1].imm == 5,
                  ops[2].type == AARCH64_OP_IMM
            else { off += 4; continue }

            // Check register is a w-register
            guard let regName = disasm.firstRegisterName(insn), regName.hasPrefix("w") else { off += 4; continue }

            let target = Int(ops[2].imm)
            guard target >= start, target < end else { off += 4; continue }

            // Target must start with `mov w?, #1`
            let targetInsns = disasm.disassemble(in: buffer.data, at: target, count: 1)
            guard let tInsn = targetInsns.first,
                  tInsn.mnemonic == "mov",
                  let tOps = tInsn.aarch64?.operands, tOps.count == 2,
                  tOps[0].type == AARCH64_OP_REG,
                  tOps[1].type == AARCH64_OP_IMM, tOps[1].imm == 1
            else { off += 4; continue }
            guard let tRegName = disasm.firstRegisterName(tInsn), tRegName.hasPrefix("w") else { off += 4; continue }

            hits.append(off)
            off += 4
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Find the unique role-state byte gate: `ldrb wN, [xBase, #imm] ; tbz/tbnz wN, #6, <target>`.
    ///
    /// On 26.1 this read as `add x8,x16,#0x70 ; ldrb w8,[x8,#1] ; tbz w8,#6,continue`;
    /// 26.5 folds the `add #0x70` into the load (`ldrb w8,[x16,#0x71]`) and inverts the
    /// branch sense (`tbnz w8,#6,reject`). Both expose the same role-state bit-6 test on
    /// the path into mount_common, so anchor on the load+`#6` bit-test pair (the `#6`
    /// role bit is the stable semantic), not the folded `add` or the branch direction.
    /// Returns the LDRB file offset (the byte we clear to neutralize the gate).
    private func findStateGate(start: Int, end: Int) -> Int? {
        var hits: [Int] = []
        var off = start
        while off + 8 <= end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 2)
            guard insns.count >= 2 else { off += 4; continue }
            let ldrInsn = insns[0], brInsn = insns[1]

            // ldrb wN, [xBase, #imm]
            guard ldrInsn.mnemonic == "ldrb",
                  let ldrOps = ldrInsn.aarch64?.operands, ldrOps.count >= 2,
                  ldrOps[0].type == AARCH64_OP_REG,
                  ldrOps[1].type == AARCH64_OP_MEM
            else { off += 4; continue }
            let ldrDstReg = ldrOps[0].reg
            guard let ldrDstName = disasm.firstRegisterName(ldrInsn), ldrDstName.hasPrefix("w") else { off += 4; continue }

            // tbz/tbnz wN, #6, <target>   (same register the byte was loaded into)
            guard brInsn.mnemonic == "tbz" || brInsn.mnemonic == "tbnz",
                  let brOps = brInsn.aarch64?.operands, brOps.count == 3,
                  brOps[0].type == AARCH64_OP_REG, brOps[0].reg == ldrDstReg,
                  brOps[1].type == AARCH64_OP_IMM, brOps[1].imm == 6
            else { off += 4; continue }

            hits.append(Int(ldrInsn.address))
            off += 4
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Encode `mov x<rd>, xzr` where `rd` is the destination register of the LDRB at
    /// `off` (the role-state byte load). Zeroing the loaded register neutralizes the
    /// downstream bit-6 test. Returns nil if the instruction isn't a register LDRB.
    private func encodeMovXZeroForLdrbDest(at off: Int) -> Data? {
        let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
        guard let ins = insns.first, ins.mnemonic == "ldrb",
              let name = disasm.firstRegisterName(ins),
              name.hasPrefix("w"), let rd = UInt32(name.dropFirst()), rd < 31
        else { return nil }
        // `mov xd, xzr` zeroes the loaded register, neutralizing the bit-6 test.
        return ARM64Encoder.encodeMovX(rd: rd, rm: 31)
    }
}
