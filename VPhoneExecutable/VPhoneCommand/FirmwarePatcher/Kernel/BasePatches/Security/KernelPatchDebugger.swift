// KernelPatchDebugger.swift — Debugger enablement patch (2 patches).
//
// Stubs _PE_i_can_has_debugger with: mov x0, #1; ret
// so the kernel always reports debugger enabled.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension KernelPatcher {
    /// Patches 6-7: stub _PE_i_can_has_debugger with mov x0,#1; ret.
    ///
    /// Three strategies in priority order:
    ///   1. Symbol table lookup via LC_SYMTAB nlist64 entries.
    ///   2. BL-histogram candidate scan with ADRP-x8 + LDR-wN-from-x8 heuristics.
    ///   3. Full code-range scan (same heuristics, no BL-count pre-filter).
    @discardableResult
    func patchDebugger() -> Bool {
        log("\n[6-7] _PE_i_can_has_debugger: stub with mov x0,#1; ret")

        // Strategy 1: symbol table lookup.
        if let va = MachOParser.findSymbol(containing: "PE_i_can_has_debugger", in: buffer.data),
           let funcOff = vaToFileOffset(va),
           funcOff + 4 < buffer.count
        {
            let first = buffer.readU32(at: funcOff)
            if first != 0, first != 0xD503_201F { // not zero, not NOP
                log("  [+] symbol table match at 0x\(String(format: "%X", funcOff))")
                emitDebugger(at: funcOff)
                return true
            }
        }

        // Strategy 2: BL histogram + lightweight signature.
        log("  [*] trying code pattern search...")
        let (histOff, histCallers) = findDebuggerByBLHistogram()
        if histOff >= 0 {
            log("  [+] code pattern match at 0x\(String(format: "%X", histOff)) (\(histCallers) callers)")
            emitDebugger(at: histOff)
            return true
        }

        // Strategy 3: full code-range scan.
        log("  [*] trying full scan fallback...")
        let (scanOff, scanCallers) = findDebuggerByFullScan()
        if scanOff >= 0 {
            log("  [+] fallback match at 0x\(String(format: "%X", scanOff)) (\(scanCallers) callers)")
            emitDebugger(at: scanOff)
            return true
        }

        log("  [-] _PE_i_can_has_debugger not found")
        return false
    }

    // MARK: - Private Helpers

    /// Emit the two patch instructions at the function entry point.
    private func emitDebugger(at offset: Int) {
        let va = fileOffsetToVA(offset)
        emit(
            offset,
            ARM64.movX0_1,
            patchID: "kernel.debugger.mov_x0_1",
            virtualAddress: va,
            description: "mov x0,#1 [_PE_i_can_has_debugger]",
        )
        emit(
            offset + 4,
            ARM64.ret,
            patchID: "kernel.debugger.ret",
            virtualAddress: va.map { $0 + 4 },
            description: "ret [_PE_i_can_has_debugger]",
        )
    }

    /// Return true if the raw 32-bit instruction is ADRP x8, <page>.
    ///
    /// ADRP encoding: [31]=1, [28:24]=10000, [4:0]=Rd
    /// Rd == 8 (x8).
    private func isADRPx8(_ insn: UInt32) -> Bool {
        ARM64Inst.isADRP(insn) && (insn & 0x1F) == 8
    }

    /// Return true if the 32-bit value is a recognised function-boundary instruction.
    private func isFuncBoundary(_ insn: UInt32) -> Bool {
        ARM64.funcBoundaryU32s.contains(insn)
    }

    /// Heuristic: scan the first `maxInsns` instructions after `funcOff` for
    /// `ldr wN, [x8, ...]` — the canonical _PE_i_can_has_debugger prologue.
    private func hasWLdrFromX8(at funcOff: Int, maxInsns: Int = 8) -> Bool {
        for k in 1 ... maxInsns {
            let off = funcOff + k * 4
            guard off + 4 <= buffer.count else { break }
            let insn = buffer.readU32(at: off)
            // LDR (unsigned offset, 32-bit): [31:30]=10, [29:27]=111, [26]=0, [25:24]=01
            // Simplified: [31:22] == 0b1011_1001_01 = 0x2E5 → mask 0xFFC00000 == 0xB9400000
            // But we also need base reg == x8 (Rn field [9:5] == 8).
            // Full check for LDR Wt, [Xn, #imm12]:
            //   [31:30]=10, [29:27]=111, [26]=0, [25]=0, [24]=1  → 0xB9400000 mask 0xFFC00000
            guard insn & 0xFFC0_0000 == 0xB940_0000 else { continue }
            let rn = (insn >> 5) & 0x1F
            if rn == 8 {
                return true
            }
        }
        return false
    }

    /// Strategy 2: scan the pre-built BL index for the candidate with the most
    /// callers in the [50, 250] window that matches the ADRP-x8 + LDR heuristic.
    private func findDebuggerByBLHistogram() -> (Int, Int) {
        var bestOff = -1
        var bestCallers = 0

        for (targetOff, callers) in blIndex {
            let n = callers.count
            guard n >= 50, n <= 250 else { continue }
            guard isInCodeRange(targetOff) else { continue }
            guard targetOff + 4 < buffer.count, targetOff & 3 == 0 else { continue }

            let first = buffer.readU32(at: targetOff)
            guard isADRPx8(first) else { continue }

            // Verify preceding instruction is a function boundary (ret / retaa / retab / pacibsp).
            if targetOff >= 4 {
                let prev = buffer.readU32(at: targetOff - 4)
                guard isFuncBoundary(prev) else { continue }
            }

            guard hasWLdrFromX8(at: targetOff) else { continue }

            if n > bestCallers {
                bestCallers = n
                bestOff = targetOff
            }
        }

        return (bestOff, bestCallers)
    }

    /// Strategy 3: linear sweep of all code ranges with the same heuristics.
    private func findDebuggerByFullScan() -> (Int, Int) {
        var bestOff = -1
        var bestCallers = 0

        for (rangeStart, rangeEnd) in codeRanges {
            var off = rangeStart
            while off + 12 <= rangeEnd {
                defer { off += 4 }

                let first = buffer.readU32(at: off)
                guard isADRPx8(first) else { continue }

                if off >= 4 {
                    let prev = buffer.readU32(at: off - 4)
                    guard isFuncBoundary(prev) else { continue }
                }

                guard hasWLdrFromX8(at: off) else { continue }

                let n = blIndex[off]?.count ?? 0
                guard n >= 50, n <= 250 else { continue }

                if n > bestCallers {
                    bestCallers = n
                    bestOff = off
                }
            }
        }

        return (bestOff, bestCallers)
    }

    /// Return true if `offset` falls within any of the known code ranges.
    private func isInCodeRange(_ offset: Int) -> Bool {
        codeRanges.contains { offset >= $0.start && offset < $0.end }
    }
}
