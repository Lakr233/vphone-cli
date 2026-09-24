// KernelJailbreakPatchIoucMacf.swift — JB kernel patch: IOUC MACF gate bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy:
//   1. Locate the "IOUC %s failed MACF in process %s" format string.
//   2. For each ADRP+ADD xref, find the enclosing function.
//   3. Within a window before the format-string ADRP, search for the pattern:
//        BL  <mac_aggregator>   ; calls MACF dispatch
//        CBZ W0, <allow>        ; skips deny path if MACF allowed
//      where <mac_aggregator> has the characteristic shape:
//        LDR X10, [X10, #0x9e8]  ; slot load from mac_policy_list
//        BLRAA/BLRAB/BLR X10     ; indirect call
//   4. Confirm that an ADRP referencing the fail-log string appears in
//      the deny block (between CBZ and the end of the function).
//   5. Replace CBZ W0, <allow> with unconditional B <allow>.

import Foundation

extension KernelJailbreakPatcher {
    /// IOUC MACF gate bypass: replace CBZ W0, <allow> with B <allow>.
    @discardableResult
    func patchIoucFailedMacf() -> Bool {
        log("\n[JB] IOUC MACF gate: branch-level deny bypass")

        guard let failStrOff = buffer.findString("IOUC %s failed MACF in process %s") else {
            log("  [-] IOUC failed-MACF format string not found")
            return false
        }

        let refs = findStringRefs(failStrOff)
        guard !refs.isEmpty else {
            log("  [-] no xrefs for IOUC failed-MACF format string")
            return false
        }

        guard let codeRange = codeRanges.first else { return false }
        let _ = codeRange // used implicitly via findFunctionStart / findFuncEnd

        for (adrpOff, _) in refs {
            guard let funcStart = findFunctionStart(adrpOff) else { continue }
            let funcEnd = findFuncEnd(funcStart, maxSize: 0x2000)

            // Search for BL + CBZ W0 pair in the window before the ADRP.
            let searchStart = max(funcStart, adrpOff - 0x120)
            let searchEnd = min(funcEnd, adrpOff + 4)

            var off = searchStart
            while off < searchEnd - 4 {
                defer { off += 4 }

                // Require BL at [off].
                guard let blTarget = decodeBL(at: off) else { continue }

                // Require CBZ W0, <target> at [off + 4].
                let cbzInsn = buffer.readU32(at: off + 4)
                guard isCbzW0(cbzInsn) else { continue }

                // Check that the BL target looks like a MACF aggregator.
                guard hasMacfAggregatorShape(at: blTarget) else { continue }

                // Decode the CBZ allow-target.
                guard let allowTarget = decodeCBZTarget(insn: cbzInsn, at: off + 4) else { continue }
                // Allow target must be forward and within the function.
                guard allowTarget > off, allowTarget < funcEnd else { continue }

                // Verify that the fail-log ADRP is in the deny block (after CBZ).
                let failAdrpExpected = adrpOff
                guard failAdrpExpected > off + 4, failAdrpExpected < min(funcEnd, off + 0x80) else { continue }

                // Encode unconditional B to allowTarget.
                guard let patchBytes = ARM64Encoder.encodeB(from: off + 4, to: allowTarget) else { continue }

                log("  [+] IOUC MACF gate fn=0x\(String(format: "%X", funcStart)), bl=0x\(String(format: "%X", off)), cbz=0x\(String(format: "%X", off + 4)), allow=0x\(String(format: "%X", allowTarget))")

                let delta = allowTarget - (off + 4)
                let va = fileOffsetToVA(off + 4)
                emit(
                    off + 4,
                    patchBytes,
                    patchID: "iouc_macf_gate",
                    virtualAddress: va,
                    description: "b #0x\(String(format: "%X", delta)) [IOUC MACF deny → allow]",
                )
                return true
            }
        }

        log("  [-] narrow IOUC MACF deny branch not found")
        return false
    }

    // MARK: - Private helpers

    /// Return true if `insn` is CBZ W0, <any>.
    private func isCbzW0(_ insn: UInt32) -> Bool {
        // CBZ 32-bit: bits[31]=0, bits[30:25]=011010, bits[4:0]=Rt
        // Encoding: 0_011_0100_imm19_Rt  →  high byte = 0x34
        let op = (insn >> 24) & 0xFF
        guard op == 0x34 else { return false } // CBZ W (not X, not CBNZ)
        return (insn & 0x1F) == 0 // Rt == W0
    }

    /// Decode a CBZ/CBNZ target from an instruction at `pc`.
    private func decodeCBZTarget(insn: UInt32, at pc: Int) -> Int? {
        // CBZ/CBNZ: bits[23:5] = imm19, sign-extended, scaled by 4
        let imm19 = (insn >> 5) & 0x7FFFF
        let signedImm = Int32(bitPattern: imm19 << 13) >> 13
        return pc + Int(signedImm) * 4
    }

    /// Heuristic: does the function at `calleeOff` look like a MACF aggregator?
    ///
    /// The aggregator loads from the mac_policy_list slot at offset 0x9E8 and
    /// makes an indirect call through that pointer.  We look for:
    ///   LDR X10, [X10, #0x9e8]   (slot load)
    ///   BLRAA/BLRAB/BLR X10      (indirect dispatch)
    private func hasMacfAggregatorShape(at calleeOff: Int) -> Bool {
        guard calleeOff >= 0, calleeOff < buffer.count else { return false }

        let funcEnd = findFuncEnd(calleeOff, maxSize: 0x400)

        var sawSlotLoad = false
        var sawIndirectCall = false

        var off = calleeOff
        while off < funcEnd {
            guard let insn = disasAt(off) else {
                off += 4
                continue
            }
            let op = insn.operandString.replacingOccurrences(of: " ", with: "").lowercased()
            if insn.mnemonic == "ldr", op.hasPrefix("x10,[x10"), op.contains(",#0x9e8]") {
                sawSlotLoad = true
            }
            if insn.mnemonic == "blraa" || insn.mnemonic == "blrab" || insn.mnemonic == "blr",
               op.hasPrefix("x10")
            {
                sawIndirectCall = true
            }
            if sawSlotLoad, sawIndirectCall {
                return true
            }
            off += 4
        }
        return false
    }
}
