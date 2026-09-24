// IBootPatchPanicBypass.swift — LLB panic-path bypass.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.

import Capstone
import Foundation

extension IBootPatcher {
    // MARK: - 5. Panic Bypass (LLB only)

    /// Find `mov w8, #0x328; movk w8, #0x40, lsl #16; ...; bl X; cbnz w0`
    /// and NOP the cbnz.
    /// Python: `patch_panic_bypass()`
    func patchPanicBypass() {
        let mov328 = encodedMovW8(0x328)
        let locs = buffer.findAll(mov328)

        for loc in locs {
            // Verify movk w8, #0x40, lsl #16 follows
            guard let nextInsn = disasm.disassembleOne(in: buffer.original, at: loc + 4) else { continue }
            guard nextInsn.mnemonic == "movk",
                  nextInsn.operandString.contains("w8"),
                  nextInsn.operandString.contains("#0x40"),
                  nextInsn.operandString.contains("lsl #16") else { continue }

            // Walk forward (up to 7 instructions past the movk) to find bl; cbnz w0
            var step = loc + 8
            while step < loc + 32 {
                guard let i = disasm.disassembleOne(in: buffer.original, at: step) else {
                    step += 4
                    continue
                }
                if i.mnemonic == "bl" {
                    if let ni = disasm.disassembleOne(in: buffer.original, at: step + 4),
                       ni.mnemonic == "cbnz"
                    {
                        emit(
                            step + 4,
                            ARM64.nop,
                            id: "\(component).panic_bypass",
                            description: "panic bypass: NOP cbnz w0",
                        )
                        return
                    }
                    break // bl found but no cbnz — keep scanning other mov candidates
                }
                step += 4
            }
        }

        if verbose {
            print("  [-] panic bypass: pattern not found")
        }
    }
}
