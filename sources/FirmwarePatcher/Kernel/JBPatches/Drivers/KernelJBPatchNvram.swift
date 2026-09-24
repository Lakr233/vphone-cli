// KernelJBPatchNvram.swift — JB kernel patch: NVRAM permission bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension KernelJBPatcher {
    /// NOP the verifyPermission gate in the `krn.` key-prefix path.
    ///
    /// Runtime reveal is string-anchored only: enumerate code refs to `"krn."`,
    /// recover the containing function for each ref, then pick the unique
    /// `tbz/tbnz` guard immediately before that key-prefix load sequence.
    @discardableResult
    func patchNvramVerifyPermission() -> Bool {
        log("\n[JB] verifyPermission (NVRAM): NOP")

        guard let strOff = buffer.findString("krn.") else {
            log("  [-] 'krn.' string not found")
            return false
        }

        let refs = findStringRefs(strOff)
        if refs.isEmpty {
            log("  [-] no code refs to 'krn.'")
            return false
        }

        var hits: [Int] = []
        var seen = Set<Int>()

        for (refAdrp, _) in refs {
            guard let funcOff = findFunctionStart(refAdrp), !seen.contains(funcOff) else { continue }
            seen.insert(funcOff)

            // Scan backward from the ADRP ref up to 8 instructions looking for tbz/tbnz
            let scanStart = max(funcOff, refAdrp - 0x20)
            var off = refAdrp - 4
            while off >= scanStart {
                let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
                if let insn = insns.first,
                   insn.mnemonic == "tbz" || insn.mnemonic == "tbnz"
                {
                    hits.append(off)
                    break
                }
                off -= 4
            }
        }

        // Deduplicate and require exactly one
        let unique = Array(Set(hits)).sorted()
        guard unique.count == 1 else {
            log("  [-] expected 1 NVRAM verifyPermission gate, found \(unique.count)")
            return false
        }

        let patchOff = unique[0]
        let va = fileOffsetToVA(patchOff)
        emit(
            patchOff,
            ARM64.nop,
            patchID: "kernelcache_jb.nvram_verify_permission",
            virtualAddress: va,
            description: "NOP [verifyPermission NVRAM]",
        )
        return true
    }
}
