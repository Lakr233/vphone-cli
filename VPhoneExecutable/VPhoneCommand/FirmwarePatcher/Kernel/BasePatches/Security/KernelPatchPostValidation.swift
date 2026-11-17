// KernelPatchPostValidation.swift — Post-validation patches (NOP + CMP).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Patch 8 — patchPostValidationNOP:
//   Anchor: "TXM [Error]: CodeSignature" string → ADRP+ADD ref → scan forward
//   for TBNZ → NOP it.
//
// Patch 9 — patchPostValidationCMP:
//   Anchor: "AMFI: code signature validation failed" → caller function →
//   BL targets in code range → callee with `cmp w0,#imm ; b.ne` preceded by BL →
//   replace CMP with `cmp w0,w0`.

import Foundation
import VPhonePatchKit

extension KernelPatcher {
    /// Whether a `cmp w0, #imm` can be the "reject unless SHA-256" gate.
    ///
    /// The site this patch neutralises asks "is the hash type SHA-256?" and
    /// rejects when it is not, so the immediate is `CS_HASHTYPE_SHA256`.
    /// iOS 27 asks the opposite question a few instructions later — `cmp w0, #1`
    /// against `CS_HASHTYPE_SHA1`, branching away when it is *not* SHA-1 — and
    /// that shape is otherwise identical: `w0` from a `BL`, then a `b.ne`.
    /// Forcing equality there would reject every signature instead of admitting
    /// them, which panics init before launchd can run, so the SHA-1 constant is
    /// never a candidate.
    static func isSHA256RejectCompare(_ immediate: Int64) -> Bool {
        immediate != 1
    }

    // MARK: - Patch 8: NOP TBNZ after TXM CodeSignature error log

    /// NOP the TBNZ that follows the TXM CodeSignature error log call.
    ///
    /// The 'TXM [Error]: CodeSignature: selector: ...' string is followed by a BL
    /// (printf/log), then a TBNZ that branches to an additional validation path.
    /// NOPping the TBNZ skips that extra check.
    @discardableResult
    func patchPostValidationNOP() -> Bool {
        log("\n[8] post-validation NOP (txm-related)")

        guard let strOff = buffer.findString("TXM [Error]: CodeSignature") else {
            log("  [-] 'TXM [Error]: CodeSignature' string not found")
            return false
        }

        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else {
            log("  [-] no code refs")
            return false
        }

        // The log call is followed by the flag test that gates the extra validation:
        //
        //     bl   <log>
        //     mov  w0, #5
        //     ldr  xN, [sp, #imm]
        //     ldrb wM, [xN, #imm]
        //     tbnz wM, #0, <extra validation>   <- NOP this
        //
        // Matching that `ldrb` + `tbnz wM, #0` pair rather than "the first TBNZ"
        // is what makes the site the same one on both kernels: 27 reaches the
        // sequence through a branch, so the pair sits ~0x64 past the ADD instead
        // of ~0x14, while the shape itself is unchanged.
        for (_, addOff) in refs {
            let scanEnd = min(addOff + 0x100, buffer.count - 8)
            for scan in stride(from: addOff, through: scanEnd, by: 4) {
                let insns = disasm.disassemble(in: buffer.data, at: scan, count: 2)
                guard insns.count == 2 else { continue }
                let load = insns[0], branch = insns[1]
                guard load.mnemonic == "ldrb",
                      let loadOps = load.detail?.operands, loadOps.count == 2,
                      loadOps[0].type == .register, loadOps[1].type == .memory,
                      branch.mnemonic == "tbnz",
                      let bits = branch.detail?.operands, bits.count == 3,
                      bits[0].type == .register, bits[0].reg == loadOps[0].reg,
                      bits[1].type == .immediate, bits[1].imm == 0
                else { continue }

                let site = scan + 4
                emit(
                    site,
                    ARM64.nop,
                    patchID: "kernel-boot-post_validation.nop_tbnz",
                    virtualAddress: fileOffsetToVA(site),
                    description: "NOP \(branch.mnemonic) \(branch.operandString) [txm post-validation]",
                )
                return true
            }
        }

        // iOS 18 tests the same byte flag with `cmp wN, #1 ; b.eq` instead of
        // `tbnz wN, #0`. Tried only when no TBNZ follows, so a kernel with the
        // TBNZ keeps its site.
        for (_, addOff) in refs {
            let scanEnd = min(addOff + 0x40, buffer.count - 8)
            for scan in stride(from: addOff, through: scanEnd, by: 4) {
                let insns = disasm.disassemble(in: buffer.data, at: scan, count: 2)
                guard insns.count == 2 else { continue }
                let cmp = insns[0], branch = insns[1]
                guard cmp.mnemonic == "cmp",
                      let ops = cmp.detail?.operands, ops.count == 2,
                      ops[0].type == .register, ops[1].type == .immediate, ops[1].imm == 1,
                      branch.mnemonic == "b.eq"
                else { continue }

                let site = scan + 4
                emit(
                    site,
                    ARM64.nop,
                    patchID: "kernel-boot-post_validation.nop_tbnz",
                    virtualAddress: fileOffsetToVA(site),
                    description: "NOP \(branch.mnemonic) \(branch.operandString) [txm post-validation]",
                )
                return true
            }
        }

        log("  [-] TBNZ not found after TXM error string ref")
        return false
    }

    // MARK: - Patch 9: cmp w0,w0 in postValidation (AMFI code signing)

    /// Replace `cmp w0, #imm` with `cmp w0, w0` in AMFI's postValidation path.
    ///
    /// The 'AMFI: code signature validation failed' string is in a caller function,
    /// not in postValidation itself. We find the caller, collect its BL targets,
    /// then look inside each target for `cmp w0, #imm ; b.ne` preceded by a BL.
    @discardableResult
    func patchPostValidationCMP() -> Bool {
        log("\n[9] postValidation: cmp w0,w0 (AMFI code signing)")

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

        for (adrpOff, _) in refs {
            guard let callerStart = findFunctionStart(adrpOff),
                  !seenFuncs.contains(callerStart) else { continue }
            seenFuncs.insert(callerStart)

            // Find caller end: scan forward for next PACIBSP (= next function boundary).
            let callerEnd = nextFunctionBoundary(after: callerStart, maxSize: 0x2000)

            // Collect BL targets by direct instruction decode across the caller body.
            var blTargets = Set<Int>()
            for scan in stride(from: callerStart, to: callerEnd, by: 4) {
                if scan > callerStart, buffer.readU32(at: scan) == ARM64.pacibspU32 {
                    break
                }
                if let target = decodeBL(at: scan) {
                    blTargets.insert(target)
                }
            }

            // For each BL target within our code range, look for cmp w0,#imm ; b.ne
            // preceded by a BL within 2 instructions.
            for blTarget in blTargets.sorted() {
                guard isWithinCodeRange(blTarget) else { continue }
                let target = functionBody(at: blTarget)
                let calleeEnd = nextFunctionBoundary(after: target, maxSize: 0x200)

                for off in stride(from: target, to: calleeEnd - 4, by: 4) {
                    // Stop at next function boundary.
                    if off > target, buffer.readU32(at: off) == ARM64.pacibspU32 {
                        break
                    }

                    let insns = disasm.disassemble(in: buffer.data, at: off, count: 2)
                    guard insns.count >= 2 else { continue }
                    let i0 = insns[0], i1 = insns[1]

                    guard i0.mnemonic == "cmp", i1.mnemonic == "b.ne" else { continue }
                    guard let detail0 = i0.detail, detail0.operands.count >= 2 else { continue }
                    let op0 = detail0.operands[0]
                    let op1 = detail0.operands[1]
                    guard op0.type == .register, op0.reg == .w(0) else { continue }
                    guard op1.type == .immediate, Self.isSHA256RejectCompare(op1.imm) else { continue }

                    // Must be preceded by a BL within 2 instructions (4 or 8 bytes back).
                    var hasBlBefore = false
                    for back in stride(from: off - 4, through: max(off - 8, target), by: -4) {
                        if decodeBL(at: back) != nil {
                            hasBlBefore = true
                            break
                        }
                    }
                    guard hasBlBefore else { continue }
                    hits.append(off)
                }
            }
        }

        let uniqueHits = Array(Set(hits)).sorted()
        guard uniqueHits.count == 1 else {
            log("  [-] expected 1 postValidation compare site, found \(uniqueHits.count)")
            return false
        }

        let patchOff = uniqueHits[0]
        emit(
            patchOff,
            ARM64.cmpW0W0,
            patchID: "kernel-boot-post_validation.cmp_w0_w0",
            virtualAddress: fileOffsetToVA(patchOff),
            description: "cmp w0,w0 (was cmp w0,#imm) [postValidation]",
        )
        return true
    }

    // MARK: - Private helpers

    /// Find the start offset of the next function after `start` (exclusive),
    /// up to `maxSize` bytes ahead. Returns `start + maxSize` if none found.
    private func nextFunctionBoundary(after start: Int, maxSize: Int) -> Int {
        let limit = min(start + maxSize, buffer.count)
        for off in stride(from: start + 4, to: limit, by: 4) {
            if buffer.readU32(at: off) == ARM64.pacibspU32 {
                return off
            }
        }
        return limit
    }

    /// Return true if `offset` falls within any known code range.
    private func isWithinCodeRange(_ offset: Int) -> Bool {
        codeRanges.contains { offset >= $0.start && offset < $0.end }
    }
}
