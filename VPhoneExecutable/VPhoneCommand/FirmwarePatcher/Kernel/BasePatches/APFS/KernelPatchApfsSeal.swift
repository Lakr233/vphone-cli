// KernelPatchApfsSeal.swift — APFS seal broken patch.
//
// Patch 2: NOP the conditional branch that leads into the
// "root volume seal is broken" panic path in _authapfs_seal_is_broken.
//
// Strategy (mirrors kernel_patch_apfs_seal.py):
//   1. Find string "root volume seal is broken" in the APFS kext text range.
//   2. For every ADRP+ADD xref, scan forward ≤ 0x40 bytes to find a
//      BL to _panic (panicOffset).
//   3. From the ADRP offset, scan backward ≤ 0x200 bytes for a conditional
//      branch whose target lands in [adrp_off - 0x40, bl_off + 4].
//   4. NOP that conditional branch.

import Capstone
import Foundation

extension KernelPatcher {
    @discardableResult
    func patchApfsSealBroken() -> Bool {
        log("\n[2] _authapfs_seal_is_broken: seal broken panic")

        guard let strOff = buffer.findString("root volume seal is broken") else {
            log("  [-] string 'root volume seal is broken' not found")
            return false
        }

        let apfsRange = apfsTextRange()
        let refs = findStringRefs(strOff, in: apfsRange)
        if refs.isEmpty {
            log("  [-] no ADRP+ADD refs to 'root volume seal is broken'")
            return false
        }

        guard let panicOff = panicOffset else {
            log("  [-] _panic offset not resolved")
            return false
        }

        for (adrpOff, addOff) in refs {
            // Find BL to _panic within 0x40 bytes after the ADD.
            var blOff: Int? = nil
            let blScanEnd = min(addOff + 0x40, buffer.count - 4)
            var scan = addOff
            while scan <= blScanEnd {
                if isBL(at: scan, target: panicOff) {
                    blOff = scan
                    break
                }
                scan += 4
            }

            guard let confirmedBlOff = blOff else { continue }

            // Search backward from just before ADRP for a conditional branch
            // whose target falls in [adrp_off - 0x40, bl_off + 4].
            let errLo = adrpOff - 0x40
            let errHi = confirmedBlOff + 4
            let backLimit = max(adrpOff - 0x200, 0)

            var back = adrpOff - 4
            while back >= backLimit {
                guard let insn = disasm.disassembleOne(in: buffer.data, at: back) else {
                    back -= 4
                    continue
                }

                if let branchTarget = conditionalBranchTarget(insn: insn) {
                    if branchTarget >= errLo, branchTarget <= errHi {
                        let desc = "NOP \(insn.mnemonic) (seal broken) [_authapfs_seal_is_broken]"
                        emit(back, ARM64.nop, patchID: "kernel.apfs_seal_broken", description: desc)
                        return true
                    }
                }

                back -= 4
            }
        }

        log("  [-] conditional branch to seal-broken panic not found")
        return false
    }
}
