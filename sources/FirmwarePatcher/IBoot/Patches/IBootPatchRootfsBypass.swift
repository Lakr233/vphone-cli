// IBootPatchRootfsBypass.swift — LLB rootfs signature/size verification bypass.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.

import Capstone
import Foundation

extension IBootPatcher {
    // MARK: - 4. Rootfs Bypass (LLB only)

    /// Apply all five rootfs bypass patches.
    /// Python: `patch_rootfs_bypass()`
    func patchRootfssBypass() {
        // 4a: cbz/cbnz before error code 0x3B7 → unconditional b
        patchCbzBeforeError(errorCode: 0x3B7, description: "rootfs: skip sig check (0x3B7)")
        // 4b: NOP b.hs after cmp x8, #0x400
        patchBhsAfterCmp0x400()
        // 4c: cbz/cbnz before error code 0x3C2 → unconditional b
        patchCbzBeforeError(errorCode: 0x3C2, description: "rootfs: skip sig verify (0x3C2)")
        // 4d: NOP cbz x8 null check (ldr x8, [xN, #0x78])
        patchNullCheck0x78()
        // 4e: cbz/cbnz before error code 0x110 → unconditional b
        patchCbzBeforeError(errorCode: 0x110, description: "rootfs: skip size verify (0x110)")
    }

    /// Find unique `mov w8, #<errorCode>` and convert the cbz/cbnz 4 bytes before
    /// it into an unconditional branch to the same target.
    /// Python: `_patch_cbz_before_error()`
    private func patchCbzBeforeError(errorCode: UInt32, description: String) {
        let pattern = encodedMovW8(errorCode)
        let locs = buffer.findAll(pattern)

        guard locs.count == 1 else {
            if verbose {
                print("  [-] \(description): expected 1 'mov w8, #0x\(String(errorCode, radix: 16))', found \(locs.count)")
            }
            return
        }

        let errOff = locs[0]
        let cbzOff = errOff - 4

        guard let insn = disasm.disassembleOne(in: buffer.original, at: cbzOff) else {
            if verbose {
                print("  [-] \(description): no instruction at 0x\(String(format: "%X", cbzOff))")
            }
            return
        }
        guard insn.mnemonic == "cbz" || insn.mnemonic == "cbnz" else {
            if verbose {
                print("  [-] \(description): expected cbz/cbnz at 0x\(String(format: "%X", cbzOff)), got \(insn.mnemonic)")
            }
            return
        }

        // Extract branch target from the operand string (last operand is the immediate)
        guard let detail = insn.aarch64, detail.operands.count >= 2 else { return }
        let target = Int(detail.operands[1].imm)

        guard let bInsn = ARM64Encoder.encodeB(from: cbzOff, to: target) else {
            if verbose {
                print("  [-] \(description): B encoding out of range")
            }
            return
        }

        emit(cbzOff, bInsn, id: "\(component).rootfs_cbz_0x\(String(errorCode, radix: 16))", description: description)
    }

    /// NOP the `b.hs` of the unique `cmp x8,#0x400 ; b.hs` rootfs size gate.
    /// Anchoring on the cmp+b.hs pair disambiguates 26.4's three `cmp x8,#0x400`
    /// (the other two are followed by `b.hi`); 26.1/26.3 have just the one.
    /// Python: `_patch_bhs_after_cmp_0x400()`
    private func patchBhsAfterCmp0x400() {
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

        guard bhsSites.count == 1 else {
            if verbose {
                print("  [-] rootfs b.hs: expected 1 'cmp x8,#0x400 ; b.hs' pair, found \(bhsSites.count)")
            }
            return
        }

        emit(
            bhsSites[0],
            ARM64.nop,
            id: "\(component).rootfs_bhs_0x400",
            description: "rootfs: NOP b.hs size check (0x400)",
        )
    }

    /// Find `ldr xR, [xN, #0x78]; cbz xR` preceding the unique `mov w8, #0x110`
    /// and NOP the cbz.
    /// Python: `_patch_null_check_0x78()`
    private func patchNullCheck0x78() {
        let pattern = encodedMovW8(0x110)
        let locs = buffer.findAll(pattern)

        guard locs.count == 1 else {
            if verbose {
                print("  [-] rootfs null check: expected 1 'mov w8, #0x110', found \(locs.count)")
            }
            return
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
                    id: "\(component).rootfs_null_check_0x78",
                    description: "rootfs: NOP cbz x8 null check (#0x78)",
                )
                return
            }
            scan -= 4
        }

        if verbose {
            print("  [-] rootfs null check: ldr+cbz #0x78 pattern not found")
        }
    }
}
