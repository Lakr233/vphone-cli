// KernelJBPatchAmfiExecve.swift — JB kernel patch: AMFI execve kill path bypass (disabled)
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy: All kill paths in the AMFI execve hook converge on a shared
// epilogue that does `MOV W0, #1` (kill) then returns. Changing that single
// instruction to `MOV W0, #0` (allow) converts every kill path to a success
// return without touching the rest of the function.
//
// NOTE: This patch is disabled in the Python reference (not called from the
// main dispatcher). It is implemented here for completeness but is NOT called
// from patchAmfiExecveKillPath() in the orchestrator.

import Foundation

extension KernelJBPatcher {
    // MARK: - AMFI execve kill-path bypass (disabled)

    /// Bypass AMFI execve kill by patching the shared MOV W0,#1 → MOV W0,#0.
    ///
    /// All kill paths in the AMFI execve hook function converge on a shared
    /// epilogue: `MOV W0, #1; LDP X29, X30, [SP, #imm]; ...`. Patching the
    /// single MOV converts all kill paths to allow-returns.
    ///
    /// This function is implemented but intentionally NOT called from the
    /// main Group C dispatcher (matches Python behaviour where it is disabled).
    @discardableResult
    func patchAmfiExecveKillPath() -> Bool {
        log("\n[JB] AMFI execve kill path: shared MOV W0,#1 → MOV W0,#0")

        // Find "AMFI: hook..execve() killing" or fallback string.
        let killStr: String
        if buffer.findString("AMFI: hook..execve() killing") != nil {
            killStr = "AMFI: hook..execve() killing"
        } else if buffer.findString("execve() killing") != nil {
            killStr = "execve() killing"
        } else {
            log("  [-] execve kill log string not found")
            return false
        }

        guard let strOff = buffer.findString(killStr) else {
            log("  [-] execve kill log string not found")
            return false
        }

        // Collect refs in kern_text, fall back to all refs.
        var refs: [(adrpOff: Int, addOff: Int)] = []
        if let (ks, ke) = kernTextRange {
            refs = findStringRefs(strOff, in: (start: ks, end: ke))
        }
        if refs.isEmpty {
            refs = findStringRefs(strOff)
        }
        guard !refs.isEmpty else {
            log("  [-] no refs to execve kill log string")
            return false
        }

        let movW0_1_enc: UInt32 = 0x5280_0020 // MOV W0, #1 (MOVZ W0, #1)

        var patched = false
        var seenFuncs: Set<Int> = []

        for (adrpOff, _) in refs {
            guard let funcStart = findFunctionStart(adrpOff) else { continue }
            guard !seenFuncs.contains(funcStart) else { continue }
            seenFuncs.insert(funcStart)

            // Function end = next PACIBSP (capped at 0x800 bytes).
            var funcEnd = findFuncEnd(funcStart, maxSize: 0x800)
            if let (_, ke) = kernTextRange {
                funcEnd = min(funcEnd, ke)
            }

            // Scan backward from funcEnd for MOV W0, #1 followed by LDP X29, X30, [SP, #imm].
            var targetOff = -1
            var off = funcEnd - 8
            while off >= funcStart {
                if buffer.readU32(at: off) == movW0_1_enc {
                    // Verify next instruction is LDP X29, X30 (epilogue start)
                    if let nextInsn = disasAt(off + 4),
                       nextInsn.mnemonic == "ldp",
                       nextInsn.operandString.contains("x29"), nextInsn.operandString.contains("x30")
                    {
                        targetOff = off
                        break
                    }
                }
                off -= 4
            }

            guard targetOff >= 0 else {
                log("  [-] MOV W0,#1 + epilogue not found in func 0x\(String(format: "%X", funcStart))")
                continue
            }

            emit(
                targetOff,
                ARM64.movW0_0,
                patchID: "jb.amfi_execve.kill_return",
                description: "mov w0,#0 [AMFI kill return → allow]",
            )

            log("  [+] Patched kill return at 0x\(String(format: "%X", targetOff)) (func 0x\(String(format: "%X", funcStart)))")
            patched = true
            break // One function is sufficient
        }

        if !patched {
            log("  [-] AMFI execve kill return not found")
        }
        return patched
    }
}
