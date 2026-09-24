// IBootPatchImage4Callback.swift — image4_validate_property_callback bypass.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.

import Capstone
import Foundation

extension IBootPatcher {
    // MARK: - 2. image4_validate_property_callback

    /// Find the b.ne + mov x0, x22 pattern with a preceding cmp.
    /// Patch: b.ne → NOP, mov x0, x22 → mov x0, #0.
    /// Python: `patch_image4_callback()`
    func patchImage4Callback() {
        var candidates: [(addr: Int, hasNeg1: Bool)] = []

        for insns in chunkedDisasm() {
            let count = insns.count
            guard count >= 2 else { continue }
            for i in 0 ..< count - 1 {
                let a = insns[i]
                let b = insns[i + 1]

                // Must be: b.ne followed immediately by mov x0, x22
                guard a.mnemonic == "b.ne" else { continue }
                guard b.mnemonic == "mov", b.operandString == "x0, x22" else { continue }

                let addr = Int(a.address)

                // There must be a cmp within the 8 preceding instructions
                let lookback = max(0, i - 8)
                let hasCmp = insns[lookback ..< i].contains { $0.mnemonic == "cmp" }
                guard hasCmp else { continue }

                // Check if a movn w22 / mov w22, #-1 appears within 64 insns before (prefer this candidate)
                let far = max(0, i - 64)
                let hasNeg1 = insns[far ..< i].contains { insn in
                    if insn.mnemonic == "movn", insn.operandString.hasPrefix("w22,") {
                        return true
                    }
                    if insn.mnemonic == "mov", insn.operandString.contains("w22"),
                       insn.operandString.contains("#-1") || insn.operandString.contains("#0xffffffff")
                    {
                        return true
                    }
                    return false
                }

                candidates.append((addr: addr, hasNeg1: hasNeg1))
            }
        }

        if candidates.isEmpty {
            if verbose {
                print("  [-] image4 callback: pattern not found")
            }
            return
        }

        // Prefer the candidate that has a movn w22 (error return path)
        let off: Int = if let preferred = candidates.first(where: { $0.hasNeg1 }) {
            preferred.addr
        } else {
            candidates.last!.addr
        }

        emit(off, ARM64.nop, id: "\(component).image4_callback_bne", description: "image4 callback: b.ne → nop")
        emit(
            off + 4,
            ARM64.movX0_0,
            id: "\(component).image4_callback_mov",
            description: "image4 callback: mov x0,x22 → mov x0,#0",
        )
    }
}
