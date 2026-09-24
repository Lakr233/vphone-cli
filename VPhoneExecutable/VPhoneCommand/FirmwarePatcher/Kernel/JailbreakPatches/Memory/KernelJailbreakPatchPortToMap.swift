// KernelJailbreakPatchPortToMap.swift — JB: skip kernel-map panic in _convert_port_to_map_with_flavor.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal: string-anchor "userspace has control access to a kernel map" →
//   walk backward from ADRP to find CMP + B.cond (conditional branch forward past panic) →
//   replace B.cond with unconditional B to same target.

import Foundation

extension KernelJailbreakPatcher {
    /// Skip kernel-map panic in _convert_port_to_map_with_flavor.
    @discardableResult
    func patchConvertPortToMap() -> Bool {
        log("\n[JB] _convert_port_to_map_with_flavor: skip panic")

        guard let strOff = buffer.findString("userspace has control access to a kernel map") else {
            log("  [-] panic string not found")
            return false
        }

        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else {
            log("  [-] no code refs")
            return false
        }

        for (adrpOff, _) in refs {
            // Walk backward from the ADRP to find CMP + B.cond
            var back = adrpOff - 4
            let scanLimit = max(adrpOff - 0x60, 0)
            while back >= scanLimit {
                defer { back -= 4 }
                guard back >= 0, back + 8 <= buffer.count else { continue }

                let insns = disasm.disassemble(in: buffer.data, at: back, count: 2)
                guard insns.count >= 2 else { continue }
                let i0 = insns[0], i1 = insns[1]

                guard i0.mnemonic == "cmp" else { continue }
                guard i1.mnemonic.hasPrefix("b.") else { continue }

                // Decode branch target — must be forward, past the ADRP (panic path).
                guard let (branchTarget, _) = jbDecodeBranchTarget(at: back + 4),
                      branchTarget > adrpOff else { continue }

                // Found the conditional branch guarding the panic fall-through.
                // Replace with unconditional B to the same forward target.
                guard let bBytes = ARM64Encoder.encodeB(from: back + 4, to: branchTarget) else {
                    continue
                }

                emit(
                    back + 4,
                    bBytes,
                    patchID: "jb.port_to_map.skip_panic",
                    virtualAddress: fileOffsetToVA(back + 4),
                    description: "b 0x\(String(format: "%X", branchTarget)) [_convert_port_to_map skip panic]",
                )
                return true
            }
        }

        log("  [-] branch site not found")
        return false
    }
}
