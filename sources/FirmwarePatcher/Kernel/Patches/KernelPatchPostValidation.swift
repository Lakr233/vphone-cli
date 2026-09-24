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

import Capstone
import Foundation

extension KernelPatcher {
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

        for (_, addOff) in refs {
            // Scan forward up to 0x40 bytes past the ADD for a TBNZ instruction.
            let scanEnd = min(addOff + 0x40, buffer.count - 4)
            for scan in stride(from: addOff, through: scanEnd, by: 4) {
                let insns = disasm.disassemble(in: buffer.data, at: scan, count: 1)
                guard let insn = insns.first else { continue }
                guard insn.mnemonic == "tbnz" else { continue }

                let va = fileOffsetToVA(scan)
                emit(
                    scan,
                    ARM64.nop,
                    patchID: "kernel.post_validation.nop_tbnz",
                    virtualAddress: va,
                    description: "NOP \(insn.mnemonic) \(insn.operandString) [txm post-validation]",
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
            for target in blTargets.sorted() {
                guard isWithinCodeRange(target) else { continue }
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
                    guard let detail0 = i0.aarch64, detail0.operands.count >= 2 else { continue }
                    let op0 = detail0.operands[0]
                    let op1 = detail0.operands[1]
                    guard op0.type == AARCH64_OP_REG, op0.reg == AARCH64_REG_W0 else { continue }
                    guard op1.type == AARCH64_OP_IMM else { continue }

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
            patchID: "kernel.post_validation.cmp_w0_w0",
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
