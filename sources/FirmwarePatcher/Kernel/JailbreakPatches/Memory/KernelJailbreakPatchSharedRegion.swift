// KernelJailbreakPatchSharedRegion.swift — JB kernel patch: Shared region map bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

extension KernelJailbreakPatcher {
    /// Force `cmp x0, x0` in the root-vs-preboot gate of
    /// `_shared_region_map_and_slide_setup`.
    ///
    /// Anchor: `/private/preboot/Cryptexes` string → find the function that
    /// contains it, then locate the unique `cmp Xm, Xn; b.eq; str xzr,...`
    /// sequence just before the string reference.
    @discardableResult
    func patchSharedRegionMap() -> Bool {
        log("\n[JB] _shared_region_map_and_slide_setup: upstream cmp x0,x0")

        guard let strOff = buffer.findString("/private/preboot/Cryptexes") else {
            log("  [-] Cryptexes string not found")
            return false
        }

        // Find the function that contains this string reference
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else {
            log("  [-] no code refs to Cryptexes string")
            return false
        }

        guard let funcStart = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] function not found via Cryptexes anchor")
            return false
        }
        let funcEnd = findFuncEnd(funcStart, maxSize: 0x2000)

        // For each ADRP ref inside the function, search backward for
        // cmp Xm, Xn / b.eq  / str xzr,...
        var hits: [Int] = []
        for (adrpOff, _) in refs {
            guard adrpOff >= funcStart, adrpOff < funcEnd else { continue }
            if let patchOff = findUpstreamRootMountCmp(funcStart: funcStart, strRefOff: adrpOff) {
                hits.append(patchOff)
            }
        }

        guard hits.count == 1 else {
            log("  [-] upstream root-vs-preboot cmp gate not found uniquely (found \(hits.count))")
            return false
        }

        let patchOff = hits[0]
        let va = fileOffsetToVA(patchOff)
        emit(
            patchOff,
            ARM64.cmpX0X0,
            patchID: "kernelcache_jb.shared_region_map",
            virtualAddress: va,
            description: "cmp x0,x0 [_shared_region_map_and_slide_setup]",
        )
        return true
    }

    // MARK: - Private helpers

    /// Scan at most 9 instructions ending at `strRefOff` for the pattern:
    ///   cmp Xm, Xn
    ///   b.eq #forward
    ///   str xzr, [...]
    private func findUpstreamRootMountCmp(funcStart: Int, strRefOff: Int) -> Int? {
        let scanStart = max(funcStart, strRefOff - 0x24)
        let scanEnd = min(strRefOff, scanStart + 0x24)
        guard scanStart < scanEnd else { return nil }

        var off = scanStart
        while off < scanEnd {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 3)
            guard insns.count >= 3 else { off += 4; continue }
            let cmpInsn = insns[0], beqInsn = insns[1], nextInsn = insns[2]

            guard cmpInsn.mnemonic == "cmp", beqInsn.mnemonic == "b.eq" else { off += 4; continue }

            guard let cmpOps = cmpInsn.aarch64?.operands, cmpOps.count == 2,
                  cmpOps[0].type == AARCH64_OP_REG, cmpOps[1].type == AARCH64_OP_REG
            else { off += 4; continue }

            guard let beqOps = beqInsn.aarch64?.operands, beqOps.count == 1,
                  beqOps[0].type == AARCH64_OP_IMM,
                  Int(beqOps[0].imm) > Int(beqInsn.address)
            else { off += 4; continue }

            // Next instruction must be `str xzr, [...]`
            guard nextInsn.mnemonic == "str",
                  nextInsn.operandString.contains("xzr")
            else { off += 4; continue }

            return off
        }
        return nil
    }
}
