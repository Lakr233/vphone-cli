// KernelJailbreakPatchPostValidation.swift — JB: additional post-validation cmp w0,w0 bypass.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal: string-anchor "AMFI: code signature validation failed" → caller function →
//   BL targets in AMFI text → callee with `cmp w0,#imm ; b.ne` preceded by a BL.
// Patch: replace `cmp w0,#imm` with `cmp w0,w0` so the compare always sets Z=1.

import Capstone
import Foundation

extension KernelJailbreakPatcher {
    /// Patch: rewrite the SHA256-only reject compare in AMFI's post-validation path.
    @discardableResult
    func patchPostValidationAdditional() -> Bool {
        log("\n[JB] postValidation additional: cmp w0,w0")

        guard let strOff = buffer.findString("AMFI: code signature validation failed") else {
            log("  [-] string not found")
            return false
        }

        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else {
            log("  [-] no code refs")
            return false
        }

        // Collect unique caller function starts.
        var seenFuncs = Set<Int>()
        var hits: [Int] = []
        var alreadyPatched: [Int] = []

        for (adrpOff, _) in refs {
            guard let callerStart = findFunctionStart(adrpOff),
                  !seenFuncs.contains(callerStart) else { continue }
            seenFuncs.insert(callerStart)

            let callerEnd = findFuncEnd(callerStart, maxSize: 0x2000)

            // Collect BL targets within the caller.
            var blTargets = Set<Int>()
            for scan in stride(from: callerStart, to: callerEnd, by: 4) {
                if let target = decodeBL(at: scan) {
                    blTargets.insert(target)
                }
            }

            // For each BL target within code, look for cmp w0,#imm ; b.ne preceded by a BL.
            for target in blTargets.sorted() {
                guard jbIsInCodeRange(target) else { continue }
                let calleeEnd = findFuncEnd(target, maxSize: 0x200)

                for off in stride(from: target, to: calleeEnd - 4, by: 4) {
                    let insns = disasm.disassemble(in: buffer.data, at: off, count: 2)
                    guard insns.count >= 2 else { continue }
                    let i0 = insns[0], i1 = insns[1]

                    // Must be: cmp w0, #imm  followed by  b.ne
                    guard i0.mnemonic == "cmp", i1.mnemonic == "b.ne" else { continue }
                    guard let detail0 = i0.aarch64, detail0.operands.count >= 2 else { continue }
                    let op0 = detail0.operands[0]
                    let op1 = detail0.operands[1]
                    guard op0.type == AARCH64_OP_REG, op0.reg == AARCH64_REG_W0 else { continue }

                    let isImmediate = op1.type == AARCH64_OP_IMM
                    // `cmp w0, w0` in this slot is this patch's own result. The
                    // base layer's postValidation patch reveals the same site
                    // the same way — same string anchor, same `cmp w0,#imm ;
                    // b.ne` shape, a narrower BL window — and rewrites it
                    // before this runs, so the immediate is already gone by
                    // then and searching only for one finds nothing at all.
                    let isAlreadyPatched = op1.type == AARCH64_OP_REG && op1.reg == AARCH64_REG_W0
                    guard isImmediate || isAlreadyPatched else { continue }

                    // Must be preceded by a BL within 3 instructions.
                    var hasBlBefore = false
                    for back in stride(from: off - 4, through: max(off - 12, target), by: -4) {
                        if decodeBL(at: back) != nil {
                            hasBlBefore = true
                            break
                        }
                    }
                    guard hasBlBefore else { continue }
                    if isAlreadyPatched {
                        alreadyPatched.append(off)
                    } else {
                        hits.append(off)
                    }
                }
            }
        }

        let uniqueHits = Array(Set(hits)).sorted()
        let uniqueAlready = Array(Set(alreadyPatched)).sorted()

        if uniqueHits.isEmpty, uniqueAlready.count == 1 {
            let off = uniqueAlready[0]
            log("  [=] already cmp w0,w0 at \(String(format: "0x%X", off)) (base postValidation "
                + "patch owns this site); nothing to patch")
            return true
        }

        guard uniqueHits.count == 1 else {
            log("  [-] expected 1 postValidation compare site, found \(uniqueHits.count)"
                + " (already-patched sites: \(uniqueAlready.count))")
            return false
        }

        let patchOff = uniqueHits[0]
        emit(
            patchOff,
            ARM64.cmpW0W0,
            patchID: "jb.post_validation.cmp_w0_w0",
            virtualAddress: fileOffsetToVA(patchOff),
            description: "cmp w0,w0 [postValidation additional]",
        )
        return true
    }
}
