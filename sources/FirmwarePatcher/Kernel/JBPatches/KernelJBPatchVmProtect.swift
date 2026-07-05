// KernelJBPatchVmProtect.swift — JB kernel patch: VM map protect W^X bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Goal: let vm_map_protect apply write+execute (RWX). The downgrade that blocks this
// is compiled two different ways across releases, so we try both shapes and apply
// whichever uniquely matches (same patch either way):
//
//   Shape A (26.1 / 26.3): an explicit skip-branch around the strip block —
//       mov  wMask, #6
//       bics wzr, wMask, wProt        ; (~prot & 6) == 0 ?  (both bits requested)
//       b.ne skip                     ; <- rewrite to unconditional `b skip`
//       tbnz wEntryFlags, #22, skip
//       ... and wProt, wProt, #~bit   ; the downgrade we want to skip
//
//   Shape B (26.5): the per-entry apply path narrows the protection with a runtime
//   W^X mask register before pmap_protect_options —
//       lsr  wT, wEntryFlags, #7      ; extract the 3-bit protection field
//       and  w3, wT, wMask            ; wMask = #5  (the W^X strip)
//       ...
//       mov  wMask, #5                ; <- widen to #7 so the AND is a pass-through
//   Widening the mask keeps ALL requested permission bits; it is strictly more
//   permissive (`prot & 7` ⊇ `prot & 5`), so no working mapping regresses.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Bypass the vm_map_protect W^X downgrade so write+execute protections are honored.
    @discardableResult
    func patchVmMapProtect() -> Bool {
        log("\n[JB] _vm_map_protect: bypass W^X downgrade")

        // Recover the function from the in-kernel "vm_map_protect(" panic string.
        guard let strOff = buffer.findString("vm_map_protect(") else {
            log("  [-] kernel-text 'vm_map_protect(' anchor not found")
            return false
        }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty, let funcStart = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] kernel-text 'vm_map_protect(' anchor not found")
            return false
        }
        let funcEnd = findFuncEnd(funcStart, maxSize: 0x2000)

        // Shape A: explicit skip branch (26.1 / 26.3). Rewrite `b.ne skip` -> `b skip`.
        if let (brOff, target) = findWriteDowngradeGate(start: funcStart, end: funcEnd) {
            guard let bBytes = encodeB(from: brOff, to: target) else {
                log("  [-] branch rewrite out of range")
                return false
            }
            let delta = target - brOff
            emit(brOff, bBytes,
                 patchID: "kernelcache_jb.vm_map_protect",
                 virtualAddress: fileOffsetToVA(brOff),
                 description: "b #0x\(String(format: "%X", delta)) [_vm_map_protect skip W^X downgrade]")
            return true
        }

        // Shape B (26.5 mask-widen) disabled: findWxMaskMov hit vm_map.c:6202
        // `prot &= ~VM_PROT_WRITE` (the COW strip), not the RWX gate at vm_map.c:5997.
        // Widening it broke COW, so debugger/tweak writes crashed SPTM on 26.4+
        // (VIOLATION_ILLEGAL_MAP). Not retargeted: on SPTM, code modification uses
        // write-then-flip via vm_protect(VM_PROT_COPY) -> XNU_USER_DEBUG, which needs no
        // RWX (debugger, Substrate tweaks, and the JB's own plugins all use this path).
        // Shape A stays for 26.1-26.4; this W^X patch is retired on 26.5+.

        log("  [-] vm_map_protect write-downgrade gate not found")
        return false
    }

    // MARK: - Shape A (26.1 / 26.3): explicit skip-branch gate

    /// Find the `b.ne` that skips the write-downgrade block, and its target.
    private func findWriteDowngradeGate(start: Int, end: Int) -> (brOff: Int, target: Int)? {
        let wZrReg: aarch64_reg = AARCH64_REG_WZR

        var hits: [(Int, Int)] = []
        var off = start
        while off + 0x10 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 4)
            guard insns.count >= 4 else { off += 4; continue }
            let movMask = insns[0], bicsInsn = insns[1], bneInsn = insns[2], tbnzInsn = insns[3]

            // mov wMask, #6
            guard movMask.mnemonic == "mov",
                  let movOps = movMask.aarch64?.operands, movOps.count == 2,
                  movOps[0].type == AARCH64_OP_REG,
                  movOps[1].type == AARCH64_OP_IMM, movOps[1].imm == 6
            else { off += 4; continue }
            let maskReg = movOps[0].reg

            // bics wzr, wMask, wProt
            guard bicsInsn.mnemonic == "bics",
                  let bicsOps = bicsInsn.aarch64?.operands, bicsOps.count == 3,
                  bicsOps[0].type == AARCH64_OP_REG, bicsOps[0].reg == wZrReg,
                  bicsOps[1].type == AARCH64_OP_REG, bicsOps[1].reg == maskReg,
                  bicsOps[2].type == AARCH64_OP_REG
            else { off += 4; continue }
            let protReg = bicsOps[2].reg

            // b.ne <skip>
            guard bneInsn.mnemonic == "b.ne",
                  let bneOps = bneInsn.aarch64?.operands, bneOps.count == 1,
                  bneOps[0].type == AARCH64_OP_IMM
            else { off += 4; continue }
            let skipTarget = Int(bneOps[0].imm)
            guard skipTarget > Int(bneInsn.address) else { off += 4; continue }

            // tbnz wEntryFlags, #22, <skip>
            guard tbnzInsn.mnemonic == "tbnz",
                  let tbnzOps = tbnzInsn.aarch64?.operands, tbnzOps.count == 3,
                  tbnzOps[0].type == AARCH64_OP_REG,
                  tbnzOps[1].type == AARCH64_OP_IMM, tbnzOps[1].imm == 22,
                  tbnzOps[2].type == AARCH64_OP_IMM, Int(tbnzOps[2].imm) == skipTarget
            else { off += 4; continue }

            // Verify there's an `and wProt, wProt, #~bit` between tbnz+4 and target.
            let searchStart = Int(tbnzInsn.address) + 4
            let searchEnd = min(skipTarget, end)
            guard findWriteClearBetween(start: searchStart, end: searchEnd, protReg: protReg) != nil
            else { off += 4; continue }

            hits.append((Int(bneInsn.address), skipTarget))
            off += 4
        }

        return hits.count == 1 ? hits[0] : nil
    }

    /// Scan [start, end) for `and wProt, wProt, #imm` that strips one of the low protection bits.
    private func findWriteClearBetween(start: Int, end: Int, protReg: aarch64_reg) -> Int? {
        var off = start
        while off < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first else { off += 4; continue }
            if insn.mnemonic == "and",
               let ops = insn.aarch64?.operands, ops.count == 3,
               ops[0].type == AARCH64_OP_REG, ops[0].reg == protReg,
               ops[1].type == AARCH64_OP_REG, ops[1].reg == protReg,
               ops[2].type == AARCH64_OP_IMM
            {
                let imm = UInt32(bitPattern: Int32(truncatingIfNeeded: ops[2].imm)) & 0xFFFF_FFFF
                // Keeps two of the three low protection bits, clears the middle one.
                if (imm & 0x7) == 0x3 {
                    return off
                }
            }
            off += 4
        }
        return nil
    }

    // MARK: - Shape B (26.5): runtime W^X mask register

    /// Locate the `mov wMask, #5` that defines the W^X protection mask, identified by
    /// the unique `lsr wT, _, #7 ; and wD, wT, wMask` pair that narrows the protection
    /// before pmap_protect_options. Returns (movFileOffset, maskRegIndex).
    private func findWxMaskMov(start: Int, end: Int) -> (Int, UInt32)? {
        var candidates: [(Int, UInt32)] = []
        var off = start
        while off + 8 <= end {
            defer { off += 4 }
            let lsr = buffer.readU32(at: off)
            guard ARM64Inst.isLSRImm7W(lsr) else { continue }
            let wt = ARM64Inst.rd(lsr)
            let and = buffer.readU32(at: off + 4)
            guard ARM64Inst.isANDRegW(and), ARM64Inst.rn(and) == wt else { continue }
            let maskReg = ARM64Inst.rm(and)

            // Find the (unique) `movz wMask, #5` writer in this function.
            var movOff = -1
            var p = start
            while p + 4 <= end {
                let insn = buffer.readU32(at: p)
                if ARM64Inst.isMOVZW(insn), ARM64Inst.rd(insn) == maskReg, ARM64Inst.movImm16(insn) == 5 {
                    if movOff >= 0 { movOff = -2; break } // ambiguous writer
                    movOff = p
                }
                p += 4
            }
            // Dedup by writer offset: several `lsr;and` pairs may reference the same
            // `mov wMask,#5` writer — that is still a single mask, not an ambiguous one.
            if movOff >= 0, !candidates.contains(where: { $0.0 == movOff }) {
                candidates.append((movOff, maskReg))
            }
        }

        return candidates.count == 1 ? candidates[0] : nil
    }
}
