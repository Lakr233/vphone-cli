// IBootPatchRootfsBypass.swift — LLB rootfs signature/size verification bypass.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.

import Foundation
import VPhonePatchKit

extension IBootPatcher {
    // MARK: - 4. Rootfs Bypass (LLB only)

    /// Apply all five rootfs bypass patches.
    /// Python: `patch_rootfs_bypass()`
    func patchRootfssBypass() {
        // 4a: cbz/cbnz before error code 0x3B7 → unconditional b
        let sigCheck = patchCbzBeforeError(errorCode: 0x3B7, description: "rootfs: skip sig check (0x3B7)")
        // 4b: NOP b.hs after cmp x8, #0x400
        patchBhsAfterCmp0x400()
        // 4c: cbz/cbnz before error code 0x3C2 → unconditional b
        let sigVerify = patchCbzBeforeError(errorCode: 0x3C2, description: "rootfs: skip sig verify (0x3C2)")
        // 4d: NOP cbz x8 null check (ldr x8, [xN, #0x78])
        let nullCheck = patchNullCheck0x78()
        // 4e: cbz/cbnz before error code 0x110 → unconditional b
        let sizeVerify = patchCbzBeforeError(errorCode: 0x110, description: "rootfs: skip size verify (0x110)")

        // The error codes are iBoot's __LINE__ numbers, so another release
        // moves them (iOS 18.6: 0x3AB, 0x3B6 and 0x10D). Whatever the literals
        // missed is found again by the shape of the two functions.
        if !sigCheck || !sigVerify {
            patchRootfsGatesByShape(sigCheck: !sigCheck, sigVerify: !sigVerify)
        }
        if !nullCheck || !sizeVerify {
            patchSizeVerifyByShape(nullCheck: !nullCheck, sizeVerify: !sizeVerify)
        }
    }

    // MARK: - Shape fallback

    /// The function holding the unique `cmp x8, #0x400 ; b.hs` size gate, as a
    /// file-offset range from its `pacibsp` to the next one.
    private func rootfsFunction() -> (start: Int, end: Int)? {
        let sites = bhsAfterCmp0x400Sites()
        guard sites.count == 1 else { return nil }
        return functionRange(containing: sites[0])
    }

    /// From `pacibsp` back from `offset` to the next `pacibsp` after it.
    private func functionRange(containing offset: Int) -> (start: Int, end: Int)? {
        let raw = buffer.original
        var start = offset & ~3
        while start >= 0, raw.loadLE(UInt32.self, at: start) != ARM64.pacibspU32 {
            start -= 4
        }
        guard start >= 0 else { return nil }
        var end = start + 4
        while end + 4 <= raw.count, raw.loadLE(UInt32.self, at: end) != ARM64.pacibspU32 {
            end += 4
        }
        return (start, end)
    }

    /// `cbz w0, <ok> ; mov w8, #<line>` gates in a range: a verification
    /// call's result tested, and the line number of its failure set.
    private func verificationGates(in range: (start: Int, end: Int), thenBranch: Bool = false) -> [(off: Int, target: Int)] {
        let insns = disasm.disassemble(in: buffer.original, at: range.start, count: (range.end - range.start) / 4)
        var gates: [(off: Int, target: Int)] = []
        for (index, insn) in insns.enumerated() where index + 2 < insns.count {
            let next = insns[index + 1]
            guard insn.mnemonic == "cbz",
                  let ops = insn.detail?.operands, ops.count == 2,
                  ops[0].type == .register, ops[0].reg == .w(0),
                  ops[1].type == .immediate,
                  next.mnemonic == "mov",
                  let movOps = next.detail?.operands, movOps.count == 2,
                  movOps[0].type == .register, movOps[0].reg == .w(8),
                  movOps[1].type == .immediate
            else { continue }
            if thenBranch, insns[index + 2].mnemonic != "b" { continue }
            gates.append((Int(insn.address), Int(ops[1].imm)))
        }
        return gates
    }

    private func emitGateBranch(_ gate: (off: Int, target: Int), id: String, description: String) {
        guard let bInsn = ARM64Encoder.encodeB(from: gate.off, to: gate.target) else {
            if verbose { print("  [-] \(description): B encoding out of range") }
            return
        }
        emit(gate.off, bInsn, id: id, description: description)
    }

    /// The signature check and verification are the last two gates of the
    /// rootfs function: 26.x `0x3B7` and `0x3C2`, 18.6 `0x3AB` and `0x3B6`.
    private func patchRootfsGatesByShape(sigCheck: Bool, sigVerify: Bool) {
        guard let range = rootfsFunction() else {
            if verbose { print("  [-] rootfs gates by shape: rootfs function not found") }
            return
        }
        let gates = verificationGates(in: range)
        guard gates.count >= 2 else {
            if verbose { print("  [-] rootfs gates by shape: \(gates.count) cbz w0 ; mov w8 gates in the rootfs function") }
            return
        }
        if sigCheck {
            emitGateBranch(gates[gates.count - 2], id: "\(component)-boot-rootfs.cbz_0x3b7",
                           description: "rootfs: skip sig check (by shape)")
        }
        if sigVerify {
            emitGateBranch(gates[gates.count - 1], id: "\(component)-boot-rootfs.cbz_0x3c2",
                           description: "rootfs: skip sig verify (by shape)")
        }
    }

    /// The size verification is in the caller of the function laid out right
    /// after the rootfs function that also loads `[xN, #0x78]` and tests it
    /// for null: the null check is the first such pair, the size check the
    /// last `cbz w0 ; mov w8, #<line> ; b` gate (26.x `0x110`, 18.6 `0x10D`).
    private func patchSizeVerifyByShape(nullCheck: Bool, sizeVerify: Bool) {
        guard let rootfs = rootfsFunction() else {
            if verbose { print("  [-] size verify by shape: rootfs function not found") }
            return
        }
        let raw = buffer.original
        var callers = Set<Int>()
        var off = 0
        while off + 4 <= raw.count {
            let word = raw.loadLE(UInt32.self, at: off)
            if word >> 26 == 0x25 {
                let imm26 = Int32(bitPattern: (word & 0x03FF_FFFF) << 6) >> 6
                if off + Int(imm26) * 4 == rootfs.end, let range = functionRange(containing: off) {
                    callers.insert(range.start)
                }
            }
            off += 4
        }

        var found: [(nullCheck: Int, gate: (off: Int, target: Int))] = []
        for start in callers.sorted() {
            guard let range = functionRange(containing: start) else { continue }
            let insns = disasm.disassemble(in: raw, at: range.start, count: (range.end - range.start) / 4)
            var nullSite: Int?
            for (index, insn) in insns.enumerated() where index + 1 < insns.count {
                let next = insns[index + 1]
                guard insn.mnemonic == "ldr",
                      let ops = insn.detail?.operands, ops.count == 2,
                      ops[0].type == .register, ops[1].type == .memory, ops[1].mem.disp == 0x78,
                      next.mnemonic == "cbz",
                      let nextOps = next.detail?.operands, nextOps.count == 2,
                      nextOps[0].type == .register, nextOps[0].reg == ops[0].reg
                else { continue }
                nullSite = Int(next.address)
                break
            }
            if let nullSite, let gate = verificationGates(in: range, thenBranch: true).last {
                found.append((nullSite, gate))
            }
        }
        guard found.count == 1 else {
            if verbose { print("  [-] size verify by shape: \(found.count) candidate functions") }
            return
        }
        if nullCheck {
            emit(found[0].nullCheck, ARM64.nop, id: "\(component)-boot-rootfs.null_check_0x78",
                 description: "rootfs: NOP cbz null check (#0x78, by shape)")
        }
        if sizeVerify {
            emitGateBranch(found[0].gate, id: "\(component)-boot-rootfs.cbz_0x110",
                           description: "rootfs: skip size verify (by shape)")
        }
    }

    /// Find unique `mov w8, #<errorCode>` and convert the cbz/cbnz 4 bytes before
    /// it into an unconditional branch to the same target.
    /// Python: `_patch_cbz_before_error()`
    @discardableResult
    private func patchCbzBeforeError(errorCode: UInt32, description: String) -> Bool {
        let pattern = encodedMovW8(errorCode)
        let locs = buffer.findAll(pattern)

        guard locs.count == 1 else {
            if verbose {
                print("  [-] \(description): expected 1 'mov w8, #0x\(String(errorCode, radix: 16))', found \(locs.count)")
            }
            return false
        }

        let errOff = locs[0]
        let cbzOff = errOff - 4

        guard let insn = disasm.disassembleOne(in: buffer.original, at: cbzOff) else {
            if verbose {
                print("  [-] \(description): no instruction at 0x\(String(format: "%X", cbzOff))")
            }
            return false
        }
        guard insn.mnemonic == "cbz" || insn.mnemonic == "cbnz" else {
            if verbose {
                print("  [-] \(description): expected cbz/cbnz at 0x\(String(format: "%X", cbzOff)), got \(insn.mnemonic)")
            }
            return false
        }

        // Extract branch target from the operand string (last operand is the immediate)
        guard let detail = insn.detail, detail.operands.count >= 2 else { return false }
        let target = Int(detail.operands[1].imm)

        guard let bInsn = ARM64Encoder.encodeB(from: cbzOff, to: target) else {
            if verbose {
                print("  [-] \(description): B encoding out of range")
            }
            return false
        }

        emit(cbzOff, bInsn, id: "\(component)-boot-rootfs.cbz_0x\(String(errorCode, radix: 16))", description: description)
        return true
    }

    /// NOP the `b.hs` of the unique `cmp x8,#0x400 ; b.hs` rootfs size gate.
    /// Anchoring on the cmp+b.hs pair disambiguates 26.4's three `cmp x8,#0x400`
    /// (the other two are followed by `b.hi`); 26.1/26.3 have just the one.
    /// Python: `_patch_bhs_after_cmp_0x400()`
    private func patchBhsAfterCmp0x400() {
        let bhsSites = bhsAfterCmp0x400Sites()

        guard bhsSites.count == 1 else {
            if verbose {
                print("  [-] rootfs b.hs: expected 1 'cmp x8,#0x400 ; b.hs' pair, found \(bhsSites.count)")
            }
            return
        }

        emit(
            bhsSites[0],
            ARM64.nop,
            id: "\(component)-boot-rootfs.bhs_0x400",
            description: "rootfs: NOP b.hs size check (0x400)",
        )
    }

    /// Every `b.hs` that follows a `cmp x8, #0x400`.
    private func bhsAfterCmp0x400Sites() -> [Int] {
        var bhsSites: [Int] = []
        for insns in chunkedDisasm() {
            for insn in insns where insn.mnemonic == "cmp" && insn.operandString == "x8, #0x400" {
                let bhsOff = Int(insn.address) + 4
                guard let next = disasm.disassembleOne(in: buffer.original, at: bhsOff),
                      next.mnemonic == "b.hs" else { continue }
                if !bhsSites.contains(bhsOff) {
                    bhsSites.append(bhsOff)
                }
            }
        }

        return bhsSites
    }

    /// Find `ldr xR, [xN, #0x78]; cbz xR` preceding the unique `mov w8, #0x110`
    /// and NOP the cbz.
    /// Python: `_patch_null_check_0x78()`
    @discardableResult
    private func patchNullCheck0x78() -> Bool {
        let pattern = encodedMovW8(0x110)
        let locs = buffer.findAll(pattern)

        guard locs.count == 1 else {
            if verbose {
                print("  [-] rootfs null check: expected 1 'mov w8, #0x110', found \(locs.count)")
            }
            return false
        }

        let errOff = locs[0]

        // Walk backwards from errOff to find ldr x?, [xN, #0x78]; cbz x?
        let scanStart = max(errOff - 0x300, 0)
        var scan = errOff - 4
        while scan >= scanStart {
            guard let i1 = disasm.disassembleOne(in: buffer.original, at: scan),
                  let i2 = disasm.disassembleOne(in: buffer.original, at: scan + 4)
            else {
                scan -= 4
                continue
            }

            if i1.mnemonic == "ldr",
               i1.operandString.contains("#0x78"),
               i2.mnemonic == "cbz",
               i2.operandString.hasPrefix("x")
            {
                emit(
                    scan + 4,
                    ARM64.nop,
                    id: "\(component)-boot-rootfs.null_check_0x78",
                    description: "rootfs: NOP cbz x8 null check (#0x78)",
                )
                return true
            }
            scan -= 4
        }

        if verbose {
            print("  [-] rootfs null check: ldr+cbz #0x78 pattern not found")
        }
        return false
    }
}
