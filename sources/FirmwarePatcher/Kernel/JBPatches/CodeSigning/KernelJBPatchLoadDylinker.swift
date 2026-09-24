// KernelJBPatchLoadDylinker.swift — JB: bypass load_dylinker policy gate in the dyld path.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal: string-anchor "/usr/lib/dyld" → kernel-text function containing the ref →
//   inside that function: BL <check>; CBZ W0, <allow>; MOV W0, #2 (deny path).
// Patch: replace BL with unconditional B to <allow>, skipping the policy check.

import Foundation

extension KernelJBPatcher {
    /// Bypass the load_dylinker policy gate in the dyld path.
    @discardableResult
    func patchLoadDylinker() -> Bool {
        log("\n[JB] _load_dylinker: skip dyld policy check")

        guard let strOff = buffer.findString("/usr/lib/dyld") else {
            log("  [-] '/usr/lib/dyld' string not found")
            return false
        }

        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else {
            log("  [-] no kernel-text code refs to '/usr/lib/dyld'")
            return false
        }

        for (adrpOff, _) in refs {
            guard jbIsInCodeRange(adrpOff) else { continue }
            guard let funcStart = findFunctionStart(adrpOff) else { continue }
            let funcEnd = findFuncEnd(funcStart, maxSize: 0x1200)

            guard let (blOff, allowTarget) = findBlCbzGate(funcStart: funcStart, funcEnd: funcEnd) else {
                continue
            }

            guard let bBytes = ARM64Encoder.encodeB(from: blOff, to: allowTarget) else { continue }

            log("  [+] dyld anchor func at 0x\(String(format: "%X", funcStart)), patch BL at 0x\(String(format: "%X", blOff))")
            emit(
                blOff,
                bBytes,
                patchID: "jb.load_dylinker.policy_bypass",
                virtualAddress: fileOffsetToVA(blOff),
                description: "b #0x\(String(format: "%X", allowTarget - blOff)) [_load_dylinker policy bypass]",
            )
            return true
        }

        log("  [-] dyld policy gate not found in dyld-anchored function")
        return false
    }

    // MARK: - Private helpers

    /// Scan [funcStart, funcEnd) for `BL <check> ; CBZ W0, <allow> ; MOV W0, #2`.
    /// Returns (blOff, allowTarget) on success.
    private func findBlCbzGate(funcStart: Int, funcEnd: Int) -> (blOff: Int, allowTarget: Int)? {
        var off = funcStart
        while off + 12 <= funcEnd {
            defer { off += 4 }

            let insns0 = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let i0 = insns0.first, i0.mnemonic == "bl" else { continue }

            let insns1 = disasm.disassemble(in: buffer.data, at: off + 4, count: 1)
            guard let i1 = insns1.first, i1.mnemonic == "cbz" else { continue }
            guard i1.operandString.hasPrefix("w0, ") else { continue }

            guard let detail1 = i1.aarch64, detail1.operands.count >= 2 else { continue }
            let allowTarget = Int(detail1.operands.last!.imm)

            // Selector: deny path sets w0 = 2 immediately after CBZ.
            let insns2 = disasm.disassemble(in: buffer.data, at: off + 8, count: 1)
            if let i2 = insns2.first,
               i2.mnemonic == "mov",
               i2.operandString.hasPrefix("w0, #2")
            {
                return (off, allowTarget)
            }
        }
        return nil
    }
}
