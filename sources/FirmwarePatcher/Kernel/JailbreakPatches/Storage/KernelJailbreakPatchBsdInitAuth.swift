// KernelJailbreakPatchBsdInitAuth.swift — JB: bypass FSIOC_KERNEL_ROOTAUTH failure in _bsd_init.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// GUARDRAIL (CLAUDE.md): recover _bsd_init → locate rootvp panic block →
//   find unique in-function call → cbnz w0/x0, panic → bl imageboot_needed → patch gate.
//
// Reveal procedure:
//   1. Recover _bsd_init via symbol table, else via rootvp panic string anchor.
//   2. Inside _bsd_init, find "rootvp not authenticated after mounting" string ref.
//   3. Follow ADRP → find the BL to _panic immediately after the ADD.
//   4. Scan backward from the panic ref for `cbnz w0/x0, <panic_region>` preceded by a BL,
//      with a BL to _imageboot_needed (or any BL) in the next 3 instructions.
//   5. NOP that cbnz.

import Capstone
import Foundation

extension KernelJailbreakPatcher {
    private static let rootvpAuthNeedle = "rootvp not authenticated after mounting"
    private static let rootvpAltNeedle = "rootvp not authenticated after mounting @%s:%d"

    /// Bypass the real rootvp auth failure branch inside _bsd_init.
    @discardableResult
    func patchBsdInitAuth() -> Bool {
        log("\n[JB] _bsd_init: ignore FSIOC_KERNEL_ROOTAUTH failure")

        // Step 1: Recover _bsd_init function start.
        guard let funcStart = resolveBsdInit() else {
            log("  [-] _bsd_init not found")
            return false
        }

        // Step 2: Find the panic string ref inside this function.
        guard let (adrpOff, addOff) = rootvpPanicRefInFunc(funcStart) else {
            log("  [-] rootvp panic string ref not found in _bsd_init")
            return false
        }

        // Step 3: Find the BL to _panic near the ADD instruction.
        guard let blPanicOff = findPanicCallNear(addOff) else {
            log("  [-] BL _panic not found near rootvp panic string")
            return false
        }

        // Step 4: Scan backward from the ADRP for a valid cbnz gate site.
        let errLo = blPanicOff - 0x40
        let errHi = blPanicOff + 4
        let imagebootNeeded = resolveSymbol("_imageboot_needed")
        let scanStart = max(funcStart, adrpOff - 0x400)

        var candidates: [(off: Int, state: String)] = []
        for off in stride(from: scanStart, to: adrpOff, by: 4) {
            guard let state = matchRootauthBranchSite(off, errLo: errLo, errHi: errHi, imagebootNeeded: imagebootNeeded) else { continue }
            candidates.append((off, state))
        }

        guard !candidates.isEmpty else {
            log("  [-] rootauth branch site not found")
            return false
        }

        let (branchOff, state): (Int, String)
        if candidates.count == 1 {
            (branchOff, state) = (candidates[0].off, candidates[0].state)
        } else {
            // If multiple, prefer the "live" (not already patched) one.
            let live = candidates.filter { $0.state == "live" }
            guard live.count == 1 else {
                log("  [-] ambiguous rootauth branch sites: \(candidates.count) found")
                return false
            }
            (branchOff, state) = (live[0].off, live[0].state)
        }

        if state == "patched" {
            log("  [=] rootauth branch already bypassed at 0x\(String(format: "%X", branchOff))")
            return true
        }

        emit(
            branchOff,
            ARM64.nop,
            patchID: "jb.bsd_init_auth.nop_cbnz",
            virtualAddress: fileOffsetToVA(branchOff),
            description: "NOP cbnz (rootvp auth) [_bsd_init]",
        )
        return true
    }

    // MARK: - Private helpers

    /// Resolve _bsd_init via symbol table, else via rootvp anchor string.
    private func resolveBsdInit() -> Int? {
        if let off = resolveSymbol("_bsd_init"), off >= 0 {
            return off
        }
        // Fallback: find function that contains the verbose rootvp panic string.
        for needle in [Self.rootvpAltNeedle, Self.rootvpAuthNeedle] {
            if let strOff = buffer.findString(needle) {
                let refs = findStringRefs(strOff)
                if let firstRef = refs.first,
                   let fn = findFunctionStart(firstRef.adrpOff)
                {
                    return fn
                }
            }
        }
        return nil
    }

    /// Find the ADRP+ADD pair for the rootvp panic string inside `funcStart`.
    private func rootvpPanicRefInFunc(_ funcStart: Int) -> (adrpOff: Int, addOff: Int)? {
        guard let strOff = buffer.findString(Self.rootvpAuthNeedle) else { return nil }
        let refs = findStringRefs(strOff)
        for (adrpOff, addOff) in refs {
            if let fn = findFunctionStart(adrpOff), fn == funcStart {
                return (adrpOff, addOff)
            }
        }
        return nil
    }

    /// Find the BL to _panic within 0x40 bytes after `addOff`.
    private func findPanicCallNear(_ addOff: Int) -> Int? {
        let limit = min(addOff + 0x40, buffer.count)
        for scan in stride(from: addOff, to: limit, by: 4) {
            if let target = decodeBL(at: scan),
               let panicOff = panicOffset,
               target == panicOff
            {
                return scan
            }
        }
        return nil
    }

    /// Check if instruction at `off` is the rootauth CBNZ gate site.
    /// Returns "live", "patched", or nil.
    private func matchRootauthBranchSite(_ off: Int, errLo: Int, errHi: Int, imagebootNeeded: Int?) -> String? {
        let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
        guard let insn = insns.first else { return nil }

        // Must be preceded by a BL or BLR
        guard isBLorBLR(at: off - 4) else { return nil }

        // Must have a BL to _imageboot_needed (or any BL if symbol not resolved) within 3 insns after
        guard hasImagebootCallNear(off, imagebootNeeded: imagebootNeeded) else { return nil }

        // Check if already patched (NOP)
        if insn.mnemonic == "nop" {
            return "patched"
        }

        // Must be CBNZ on w0 or x0
        guard insn.mnemonic == "cbnz" else { return nil }
        guard let detail = insn.aarch64, !detail.operands.isEmpty else { return nil }
        let regOp = detail.operands[0]
        guard regOp.type == AARCH64_OP_REG,
              regOp.reg == AARCH64_REG_W0 || regOp.reg == AARCH64_REG_X0 else { return nil }

        // Branch target must point into the panic block region
        guard let (branchTarget, _) = jbDecodeBranchTarget(at: off),
              branchTarget >= errLo, branchTarget <= errHi else { return nil }

        return "live"
    }

    /// Return true if there is a BL/BLR/BLRAA/BLRAB/etc. at `off`.
    private func isBLorBLR(at off: Int) -> Bool {
        guard off >= 0, off + 4 <= buffer.count else { return false }
        let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
        guard let insn = insns.first else { return false }
        return insn.mnemonic.hasPrefix("bl")
    }

    /// Return true if there is a BL to _imageboot_needed (or any BL if unknown)
    /// within 3 instructions after `off`.
    private func hasImagebootCallNear(_ off: Int, imagebootNeeded: Int?) -> Bool {
        let limit = min(off + 0x18, buffer.count)
        for scan in stride(from: off + 4, to: limit, by: 4) {
            guard let target = decodeBL(at: scan) else { continue }
            // If we know _imageboot_needed, require an exact match;
            // otherwise any BL counts (stripped kernel).
            if let ib = imagebootNeeded {
                if target == ib {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }
}
