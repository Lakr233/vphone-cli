// IBootPatchBootArgs.swift — custom boot-args redirection (iBEC / LLB).
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.

import Capstone
import Foundation

extension IBootPatcher {
    // MARK: - 3. Boot-Args (iBEC / LLB)

    /// Effective boot-args string, with any `extraBootArgs` inserted before `%s`.
    private var effectiveBootArgs: String {
        extraBootArgs.isEmpty
            ? IBootPatcher.bootArgs
            : "serial=3 -v debug=0x2014e \(extraBootArgs) %s"
    }

    /// Redirect ADRP+ADD x2 to a custom boot-args string.
    /// Python: `patch_boot_args()`
    func patchBootArgs(newArgs: String? = nil) {
        let newArgs = newArgs ?? effectiveBootArgs
        guard let newArgsData = newArgs.data(using: .ascii) else { return }

        guard let fmtOff = findBootArgsFmt() else {
            if verbose {
                print("  [-] boot-args: format string not found")
            }
            return
        }

        guard let (adrpOff, addOff) = findBootArgsAdrp(fmtOff: fmtOff) else {
            if verbose {
                print("  [-] boot-args: ADRP+ADD x2 not found")
            }
            return
        }

        guard let newOff = findStringSlot(length: newArgsData.count) else {
            if verbose {
                print("  [-] boot-args: no NUL slot")
            }
            return
        }

        // Write the string itself
        emitString(newOff, newArgsData, id: "\(component).boot_args_string", description: "boot-args string")

        // Re-encode ADRP x2 → new page
        guard let newAdrp = ARM64Encoder.encodeADRP(rd: 2, pc: UInt64(adrpOff), target: UInt64(newOff)) else {
            if verbose {
                print("  [-] boot-args: ADRP encoding out of range")
            }
            return
        }
        emit(adrpOff, newAdrp, id: "\(component).boot_args_adrp", description: "boot-args: adrp x2 → new string page")

        // Re-encode ADD x2, x2, #offset
        let imm12 = UInt32(newOff & 0xFFF)
        guard let newAdd = ARM64Encoder.encodeAddImm12(rd: 2, rn: 2, imm12: imm12) else {
            if verbose {
                print("  [-] boot-args: ADD encoding out of range")
            }
            return
        }
        emit(addOff, newAdd, id: "\(component).boot_args_add", description: "boot-args: add x2 → new string offset")
    }

    /// Find the standalone "%s" format string near "rd=md0" or "BootArgs".
    /// Python: `_find_boot_args_fmt()`
    private func findBootArgsFmt() -> Int? {
        let raw = buffer.original

        // Find the anchor string
        var anchor: Int? = raw.range(of: Data("rd=md0".utf8))
            .map { raw.distance(from: raw.startIndex, to: $0.lowerBound) }
        if anchor == nil {
            anchor = raw.range(of: Data("BootArgs".utf8)).map { raw.distance(from: raw.startIndex, to: $0.lowerBound) }
        }
        guard let anchorOff = anchor else { return nil }

        // Search for "%s" within 0x40 bytes of the anchor
        let searchEnd = anchorOff + 0x40
        let pctS = Data([UInt8(ascii: "%"), UInt8(ascii: "s")])

        var off = anchorOff
        while off < searchEnd {
            guard let range = raw.range(of: pctS, in: off ..< min(searchEnd, raw.count)) else { return nil }
            let found = raw.distance(from: raw.startIndex, to: range.lowerBound)
            if found >= off + raw.count {
                return nil
            }

            // Must have NUL before and NUL after (isolated "%s\0")
            if found > 0, raw[found - 1] == 0, found + 2 < raw.count, raw[found + 2] == 0 {
                return found
            }
            off = found + 1
        }
        return nil
    }

    /// Find ADRP+ADD x2 pointing to the format string at fmtOff.
    /// Python: `_find_boot_args_adrp()`
    private func findBootArgsAdrp(fmtOff: Int) -> (Int, Int)? {
        for insns in chunkedDisasm() {
            let count = insns.count
            guard count >= 2 else { continue }
            for i in 0 ..< count - 1 {
                let a = insns[i]
                let b = insns[i + 1]

                guard a.mnemonic == "adrp", b.mnemonic == "add" else { continue }

                // First operand of ADRP must be x2
                guard a.operandString.hasPrefix("x2,") else { continue }

                guard let aDetail = a.aarch64, let bDetail = b.aarch64 else { continue }
                guard aDetail.operands.count >= 2, bDetail.operands.count >= 3 else { continue }

                // ADRP Rd must equal ADD Rn (same register)
                guard aDetail.operands[0].reg == bDetail.operands[1].reg else { continue }

                // ADRP page imm + ADD imm12 must equal fmt_off
                let pageImm = aDetail.operands[1].imm // already page-aligned VA
                let addImm = bDetail.operands[2].imm
                if Int(pageImm + addImm) == fmtOff {
                    return (Int(a.address), Int(b.address))
                }
            }
        }
        return nil
    }

    /// Find a run of NUL bytes ≥ 64 bytes long to write the new string into.
    /// Python: `_find_string_slot()`
    private func findStringSlot(length: Int, searchStart: Int = 0x14000) -> Int? {
        let raw = buffer.original
        var off = searchStart
        while off < raw.count {
            if raw[off] == 0 {
                let runStart = off
                while off < raw.count, raw[off] == 0 {
                    off += 1
                }
                let runLen = off - runStart
                if runLen >= 64 {
                    // Align write pointer to 16 bytes (Python: (run_start + 8 + 15) & ~15)
                    let writeOff = (runStart + 8 + 15) & ~15
                    if writeOff + length <= off {
                        return writeOff
                    }
                }
            } else {
                off += 1
            }
        }
        return nil
    }
}
