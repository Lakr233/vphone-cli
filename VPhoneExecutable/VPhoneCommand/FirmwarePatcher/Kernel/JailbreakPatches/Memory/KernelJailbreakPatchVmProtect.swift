// KernelJailbreakPatchVmProtect.swift — JB kernel patch: VM map protect W^X bypass
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
//   Shape C (26.4): the same decision, emitted with the two conditions fused. The
//   compiler drops the flag-setting `bics` and the separate `tbnz` in favour of a
//   conditional compare, leaving one branch to rewrite instead of two —
//       and  wFlags, wFlags, #(1 << 22)   ; isolate the same entry bit the tbnz tested
//       mov  wMask, #6
//       bic  wMask, wMask, wProt          ; plain bic; the compare is separate
//       cmp  wMask, #0                    ; (~prot & 6) == 0 ?
//       ccmp wFlags, #0, #0, eq           ; ... and the entry flag clear ?
//       b.ne skip                         ; <- rewrite to unconditional `b skip`
//       ... and wProt, wProt, #~VM_PROT_EXECUTE
//   Rewriting that single `b.ne` bypasses both conditions at once, which is exactly
//   what Shape A's rewrite achieves (there the `tbnz` becomes dead code). Same bit,
//   same downgrade, same patch.
//
//   Shape B (26.5): the per-entry apply path narrows the protection with a runtime
//   W^X mask register before pmap_protect_options —
//       lsr  wT, wEntryFlags, #7      ; extract the 3-bit protection field
//       and  w3, wT, wMask            ; wMask = #5  (the W^X strip)
//       ...
//       mov  wMask, #5                ; <- widen to #7 so the AND is a pass-through
//   Widening the mask keeps ALL requested permission bits; it is strictly more
//   permissive (`prot & 7` ⊇ `prot & 5`), so no working mapping regresses.

import Foundation
import VPhonePatchKit

extension KernelJailbreakPatcher {
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
            return emitSkipBranch(brOff: brOff, target: target, shape: "A")
        }

        // Shape C: the same gate with the two conditions fused into a ccmp (26.4).
        // Tried only after Shape A, so a kernel that still emits the explicit
        // `bics`/`tbnz` pair keeps taking exactly the path it always took.
        //
        // Deliberately NOT scoped to [funcStart, funcEnd]: on 26.4 the panic string
        // sits in a cold block that ends at its own `pacibsp` 0x6B8 bytes before the
        // gate, so the window findFuncEnd derives from the string stops short of it.
        // Widening that window by a byte count would be an offset-shaped anchor.
        // Instead the signature carries its own anchor — on this kernel even the
        // `mov wMask,#6 ; bic wMask,wMask,wProt` prefix occurs exactly once in 8.4 MB
        // of kernel text — and uniqueness across the whole code range is required.
        if let (brOff, target) = findFusedWriteDowngradeGate() {
            return emitSkipBranch(brOff: brOff, target: target, shape: "C")
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

    /// Rewrite the gate's conditional branch to an unconditional one to its own target.
    private func emitSkipBranch(brOff: Int, target: Int, shape: String) -> Bool {
        guard let bBytes = ARM64Encoder.encodeB(from: brOff, to: target) else {
            log("  [-] branch rewrite out of range")
            return false
        }
        let delta = target - brOff
        emit(
            brOff,
            bBytes,
            patchID: "kernel-boot-vm_map_protect",
            virtualAddress: fileOffsetToVA(brOff),
            description: "b #0x\(String(format: "%X", delta)) "
                + "[_vm_map_protect skip W^X downgrade, shape \(shape)]",
        )
        return true
    }

    // MARK: - Shape C (26.4): conditions fused into a conditional compare

    /// Find the single `b.ne` that skips the downgrade when the compiler folded the
    /// entry-flag test into a `ccmp`, and its target. Scans every known code range
    /// and returns a result only when the signature occurs exactly once.
    private func findFusedWriteDowngradeGate() -> (brOff: Int, target: Int)? {
        // The entry bit the explicit shape tested with `tbnz wFlags, #22`.
        let entryFlagBit: Int64 = 1 << 22

        var hits: [(Int, Int)] = []
        for range in codeRanges {
            scanRange(range.start, range.end, entryFlagBit, &hits)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    private func scanRange(
        _ start: Int, _ end: Int, _ entryFlagBit: Int64, _ hits: inout [(Int, Int)],
    ) {
        var off = start
        while off + 0x18 < end {
            defer { off += 4 }

            // Rejection-only gate, ahead of Capstone. Nothing is decided here: a
            // word that survives goes through exactly the decode and the checks it
            // always did, and every positive determination below is still
            // Capstone's. It exists because this scan is deliberately unscoped
            // (see findFusedWriteDowngradeGate), so it walks all 8.4 MB of kernel
            // text — and decoding five instructions at every one of the ~2.1M
            // offsets to reject almost all of them on the first one cost ~29 s of
            // a ~49 s `fw patch`, nearly all of it inside Capstone's printer.
            //
            // The window has to open with `mov wMask, #6`, which an assembler can
            // spell two ways: MOVZ, or `orr wMask, wzr, #6`. Both are let through.
            // In practice the ORR form disassembles as `orr`, not `mov` — the
            // MOV-bitmask alias applies only when the immediate is *not*
            // MOVZ-encodable, and #6 is — so the check below would reject it
            // anyway. Accepting it here regardless keeps this gate from depending
            // on that aliasing rule, which is the one way a cheap prefilter could
            // silently narrow the match.
            let word = buffer.readU32(at: off)
            guard (ARM64Inst.isMOVZW(word) && ARM64Inst.movImm16(word) == 6)
                || (ARM64Inst.isORRImmW(word) && ARM64Inst.rn(word) == 31)
            else { continue }

            let insns = disasm.disassemble(in: buffer.data, at: off, count: 5)
            guard insns.count >= 5 else { continue }
            let movMask = insns[0], bicInsn = insns[1]
            let cmpInsn = insns[2], ccmpInsn = insns[3], bneInsn = insns[4]

            // mov wMask, #6
            guard movMask.mnemonic == "mov",
                  let movOps = movMask.detail?.operands, movOps.count == 2,
                  movOps[0].type == .register,
                  movOps[1].type == .immediate, movOps[1].imm == 6
            else { continue }
            let maskReg = movOps[0].reg

            // bic wMask, wMask, wProt — the non-flag-setting form.
            guard bicInsn.mnemonic == "bic",
                  let bicOps = bicInsn.detail?.operands, bicOps.count == 3,
                  bicOps[0].type == .register, bicOps[0].reg == maskReg,
                  bicOps[1].type == .register, bicOps[1].reg == maskReg,
                  bicOps[2].type == .register
            else { continue }
            let protReg = bicOps[2].reg

            // cmp wMask, #0
            guard cmpInsn.mnemonic == "cmp",
                  let cmpOps = cmpInsn.detail?.operands, cmpOps.count == 2,
                  cmpOps[0].type == .register, cmpOps[0].reg == maskReg,
                  cmpOps[1].type == .immediate, cmpOps[1].imm == 0
            else { continue }

            // ccmp wFlags, #0, #nzcv, eq — the `eq` is what makes this the second
            // half of the same decision rather than an unrelated fused compare.
            guard ccmpInsn.mnemonic == "ccmp",
                  let ccmpDetail = ccmpInsn.detail,
                  ccmpDetail.conditionCode == .eq,
                  ccmpDetail.operands.count >= 2,
                  ccmpDetail.operands[0].type == .register,
                  ccmpDetail.operands[1].type == .immediate,
                  ccmpDetail.operands[1].imm == 0
            else { continue }
            let flagsReg = ccmpDetail.operands[0].reg

            // b.ne <skip>, forward.
            guard bneInsn.mnemonic == "b.ne",
                  let bneOps = bneInsn.detail?.operands, bneOps.count == 1,
                  bneOps[0].type == .immediate
            else { continue }
            let skipTarget = Int(bneOps[0].imm)
            guard skipTarget > Int(bneInsn.address) else { continue }

            // The flags register must have been masked down to the same entry bit the
            // explicit shape tested, so this stays anchored on that flag and cannot
            // drift onto an unrelated fused compare.
            guard findEntryFlagMask(
                before: off,
                limit: start,
                reg: flagsReg,
                bit: entryFlagBit,
            ) != nil else { continue }

            // And the block it guards must be the downgrade.
            let searchStart = Int(bneInsn.address) + 4
            let searchEnd = min(skipTarget, end)
            guard findWriteClearBetween(start: searchStart, end: searchEnd, protReg: protReg) != nil
            else { continue }

            hits.append((Int(bneInsn.address), skipTarget))
        }
    }

    /// Scan backwards for `and wFlags, wFlags, #bit` that isolates the entry flag.
    private func findEntryFlagMask(before: Int, limit: Int, reg: ARM64Register, bit: Int64) -> Int? {
        var off = before - 4
        let floor = max(limit, before - 0x20)
        while off >= floor {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            if let insn = insns.first, insn.mnemonic == "and",
               let ops = insn.detail?.operands, ops.count == 3,
               ops[0].type == .register, ops[0].reg == reg,
               ops[1].type == .register, ops[1].reg == reg,
               ops[2].type == .immediate, ops[2].imm == bit
            {
                return off
            }
            off -= 4
        }
        return nil
    }

    // MARK: - Shape A (26.1 / 26.3): explicit skip-branch gate

    /// Find the `b.ne` that skips the write-downgrade block, and its target.
    private func findWriteDowngradeGate(start: Int, end: Int) -> (brOff: Int, target: Int)? {
        let wZrReg: ARM64Register = .wzr

        var hits: [(Int, Int)] = []
        var off = start
        while off + 0x10 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 4)
            guard insns.count >= 4 else { off += 4; continue }
            let movMask = insns[0], bicsInsn = insns[1], bneInsn = insns[2], tbnzInsn = insns[3]

            // mov wMask, #6
            guard movMask.mnemonic == "mov",
                  let movOps = movMask.detail?.operands, movOps.count == 2,
                  movOps[0].type == .register,
                  movOps[1].type == .immediate, movOps[1].imm == 6
            else { off += 4; continue }
            let maskReg = movOps[0].reg

            // bics wzr, wMask, wProt
            guard bicsInsn.mnemonic == "bics",
                  let bicsOps = bicsInsn.detail?.operands, bicsOps.count == 3,
                  bicsOps[0].type == .register, bicsOps[0].reg == wZrReg,
                  bicsOps[1].type == .register, bicsOps[1].reg == maskReg,
                  bicsOps[2].type == .register
            else { off += 4; continue }
            let protReg = bicsOps[2].reg

            // b.ne <skip>
            guard bneInsn.mnemonic == "b.ne",
                  let bneOps = bneInsn.detail?.operands, bneOps.count == 1,
                  bneOps[0].type == .immediate
            else { off += 4; continue }
            let skipTarget = Int(bneOps[0].imm)
            guard skipTarget > Int(bneInsn.address) else { off += 4; continue }

            // tbnz wEntryFlags, #22, <skip>
            guard tbnzInsn.mnemonic == "tbnz",
                  let tbnzOps = tbnzInsn.detail?.operands, tbnzOps.count == 3,
                  tbnzOps[0].type == .register,
                  tbnzOps[1].type == .immediate, tbnzOps[1].imm == 22,
                  tbnzOps[2].type == .immediate, Int(tbnzOps[2].imm) == skipTarget
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
    private func findWriteClearBetween(start: Int, end: Int, protReg: ARM64Register) -> Int? {
        var off = start
        while off < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first else { off += 4; continue }
            if insn.mnemonic == "and",
               let ops = insn.detail?.operands, ops.count == 3,
               ops[0].type == .register, ops[0].reg == protReg,
               ops[1].type == .register, ops[1].reg == protReg,
               ops[2].type == .immediate
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
                    if movOff >= 0 {
                        movOff = -2; break
                    } // ambiguous writer
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
