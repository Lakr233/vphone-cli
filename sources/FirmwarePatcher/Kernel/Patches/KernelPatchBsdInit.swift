// KernelPatchBsdInit.swift — BSD init rootvp patch.
//
// Patch 3: NOP the conditional branch guarding the "rootvp not authenticated" panic.
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Allowed reveal flow (per CLAUDE.md guardrails):
//   recover bsd_init → locate rootvp panic block → find the unique in-function BL
//   → cbnz w0/x0 panic → bl imageboot_needed site → patch the branch gate only.

import Capstone
import Foundation

// MARK: - Conditional branch mnemonics (ARM64)

private let condBranchMnemonics: Set<String> = [
    "b.eq", "b.ne", "b.cs", "b.hs", "b.cc", "b.lo",
    "b.mi", "b.pl", "b.vs", "b.vc", "b.hi", "b.ls",
    "b.ge", "b.lt", "b.gt", "b.le", "b.al",
    "cbz", "cbnz", "tbz", "tbnz",
]

extension KernelPatcher {
    // MARK: - Panic Offset Resolution

    /// Find the file offset of _panic by locating the most-called BL target.
    ///
    /// _panic is by far the most-called function in the kernel; the BL index
    /// built by buildBLIndex() maps target file-offsets to caller lists.
    func findPanicOffsetIfNeeded() {
        guard panicOffset == nil else { return }

        // Pick the target with the most callers — that is _panic.
        guard let (target, callers) = blIndex.max(by: { $0.value.count < $1.value.count }),
              callers.count >= 100
        else {
            log("  [!] _panic not found in BL index")
            return
        }
        panicOffset = target
        log("  [*] _panic at foff 0x\(String(format: "%X", target)) (\(callers.count) callers)")
    }

    // MARK: - Patch 3: rootvp not authenticated

    /// NOP the conditional branch guarding the "rootvp not authenticated after mounting" panic.
    ///
    /// Flow:
    ///   1. Find the string "rootvp not authenticated after mounting".
    ///   2. Find ADRP+ADD code references to that string.
    ///   3. Forward-scan from the ADD for a BL _panic (within 0x40 bytes).
    ///   4. Backward-scan from the ADRP for a conditional branch into the panic block.
    ///   5. NOP that conditional branch.
    @discardableResult
    func patchBsdInitRootvp() -> Bool {
        log("\n[3] _bsd_init: rootvp not authenticated panic")

        findPanicOffsetIfNeeded()
        guard let panicOff = panicOffset else {
            log("  [-] _panic offset unknown, cannot patch")
            return false
        }

        // Step 1: locate the anchor string.
        guard let strOff = buffer.findString("rootvp not authenticated after mounting") else {
            log("  [-] string not found")
            return false
        }

        // Step 2: find ADRP+ADD references in code.
        let refs = findStringRefs(strOff)
        if refs.isEmpty {
            log("  [-] no code refs in kernel __text")
            return false
        }

        for (adrpOff, addOff) in refs {
            // Step 3: scan forward from the ADD for BL _panic (up to 0x40 bytes).
            let fwdLimit = min(addOff + 0x40, buffer.count - 4)
            var blPanicOff: Int? = nil

            var scan = addOff
            while scan <= fwdLimit {
                if decodeBL(at: scan) == panicOff {
                    blPanicOff = scan
                    break
                }
                scan += 4
            }

            guard let blPanic = blPanicOff else { continue }

            // Step 4: search backward from adrpOff for a conditional branch whose
            // target lands in the error block [blPanic - 0x40, blPanic + 4).
            let errLo = blPanic - 0x40
            let errHi = blPanic + 4
            let backLimit = max(adrpOff - 0x400, 0)

            var back = adrpOff - 4
            while back >= backLimit {
                defer { back -= 4 }
                guard back + 4 <= buffer.count else { continue }

                // Use Capstone to decode and check for conditional branch.
                // Addresses in Capstone match file offsets (address param == offset).
                guard let insn = disasm.disassembleOne(in: buffer.original, at: back) else {
                    continue
                }

                guard condBranchMnemonics.contains(insn.mnemonic) else { continue }

                // Extract the branch target from operand string.
                // Capstone renders CBZ/CBNZ as "cbz x0, #0x1234" and
                // B.cond as "b.eq #0x1234". The immediate is the last token.
                guard let branchTarget = decodeBranchTargetFromInsn(insn) else { continue }

                // Target must fall within the error path block.
                guard branchTarget >= errLo, branchTarget < errHi else { continue }

                // Found the gate branch — NOP it.
                let va = fileOffsetToVA(back)
                emit(
                    back,
                    ARM64.nop,
                    patchID: "kernel.bsd_init_rootvp",
                    virtualAddress: va,
                    description: "NOP \(insn.mnemonic) (rootvp auth) [_bsd_init]",
                )
                return true
            }
        }

        log("  [-] conditional branch into panic path not found")
        return false
    }

    // MARK: - Helpers

    /// Extract the branch target (file offset) from a Capstone instruction's operand string.
    ///
    /// Capstone renders the target as a hex literal (e.g., `#0x1abc`).
    /// We parse the last whitespace-separated token and strip the leading `#`.
    private func decodeBranchTargetFromInsn(_ insn: Instruction) -> Int? {
        // operandString examples:
        //   "w0, #0xf7798c"   (cbz / cbnz)
        //   "#0xf7798c"       (b.eq / b.ne / etc.)
        //   "w0, #4, #0xf7798c"  (tbz / tbnz)
        let tokens = insn.operandString
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = tokens.last else { return nil }

        let hex = last.hasPrefix("#") ? String(last.dropFirst()) : last
        // Capstone may emit "0x…" or a plain decimal.
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            return Int(hex.dropFirst(2), radix: 16)
        }
        return Int(hex)
    }
}
