// KernelPatchApfsSnapshot.swift — APFS root snapshot patch.
//
// Patch 1: NOP the tbnz/tbz w<reg>, #5 instruction that gates the
// sealed-volume root snapshot panic in _apfs_vfsop_mount.
//
// Strategy (mirrors kernel_patch_apfs_snapshot.py):
//   1. Find string "Rooting from snapshot with xid" (fallback: "Failed to find
//      the root snapshot") in the APFS kext text range.
//   2. For every ADRP+ADD xref, scan forward ≤ 0x200 bytes for a
//      tbz/tbnz <reg>, #5, <target> instruction.
//   3. NOP it.

import Capstone
import Foundation

extension KernelPatcher {
    @discardableResult
    func patchApfsRootSnapshot() -> Bool {
        log("\n[1] _apfs_vfsop_mount: root snapshot sealed volume check")

        let apfsRange = apfsTextRange()

        // Try primary string anchor, fall back to secondary.
        var refs = findStringRefs(in: apfsRange, string: "Rooting from snapshot with xid")
        if refs.isEmpty {
            refs = findStringRefs(in: apfsRange, string: "Failed to find the root snapshot")
            if refs.isEmpty {
                log("  [-] anchor strings not found in APFS text range")
                return false
            }
        }

        for (_, addOff) in refs {
            let scanEnd = min(addOff + 0x200, buffer.count - 4)
            var scan = addOff
            while scan <= scanEnd {
                guard let insn = disasm.disassembleOne(in: buffer.data, at: scan) else {
                    scan += 4
                    continue
                }

                guard insn.mnemonic == "tbnz" || insn.mnemonic == "tbz" else {
                    scan += 4
                    continue
                }

                // Check: tbz/tbnz <reg>, #5, <target>
                // Operands: [0] = register, [1] = bit number (IMM), [2] = branch target (IMM)
                guard
                    let detail = insn.aarch64,
                    detail.operands.count >= 2,
                    detail.operands[0].type == AARCH64_OP_REG,
                    detail.operands[1].type == AARCH64_OP_IMM,
                    detail.operands[1].imm == 5
                else {
                    scan += 4
                    continue
                }

                let desc = "NOP \(insn.mnemonic) \(insn.operandString) (sealed vol check) [_apfs_vfsop_mount]"
                emit(scan, ARM64.nop, patchID: "kernel.apfs_root_snapshot", description: desc)
                return true
            }
        }

        log("  [-] tbz/tbnz <reg>, #5 not found near xref")
        return false
    }
}
