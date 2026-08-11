// KernelJBPatchThreadSetState.swift — optional Frida Stalker support (--frida).
//
// Frida follows an existing thread via thread_set_state_from_user, whose flags
// carry TSSF_CHECK_ENTITLEMENT and trip GUARD_TYPE_MACH_PORT. Clear that bit in the
// user setters (`mov w6,#0x201` → `mov w6,#0x1`) rather than the check itself.
// Reveal + validation: research/kernel_patch_jb/patch_thread_set_state.md.

import Capstone
import Foundation

extension KernelJBPatcher {
    private static let tssEntitlement = "com.apple.private.thread-set-state"
    // TSSF_TRANSLATE_TO_USER (0x1) | TSSF_CHECK_ENTITLEMENT (0x200).
    private static let tssFlagsFromUser: Int64 = 0x201
    private static let tssFlagsCleared: UInt16 = 0x1

    /// Clear TSSF_CHECK_ENTITLEMENT in the flags passed by the thread_set_state
    /// user setters so Frida Stalker can update an existing thread's registers.
    @discardableResult
    func patchThreadSetStateEntitlementFlag() -> Bool {
        log("\n[FRIDA] thread_set_state: clear TSSF_CHECK_ENTITLEMENT in user setters")

        guard let strOff = buffer.findString(Self.tssEntitlement) else {
            log("  [~] thread-set-state entitlement string absent; skipping")
            return true
        }

        // All entitlement-string refs land in one function (thread_set_state_internal).
        let refs = findStringRefs(strOff)
        let starts = Set(refs.compactMap { findFunctionStart($0.adrpOff) })
        guard starts.count == 1, let fnStart = starts.first else {
            log("  [~] entitlement checks not in a single recovered function (\(starts.count)); skipping")
            return true
        }
        let fnEnd = findFuncEnd(fnStart, maxSize: 0x1000)

        // `mov w6,#0x201` (w6 = 7th arg = flags) feeding a direct branch into it.
        var setterOffsets: [Int] = []
        for range in codeRanges {
            var off = range.start
            while off + 4 <= min(range.end, buffer.count) {
                defer { off += 4 }
                guard let branch = disasAt(off),
                      branch.mnemonic == "b" || branch.mnemonic == "bl",
                      let target = branchTargetFileOffset(branch),
                      target >= fnStart - 0x10, target < fnEnd
                else { continue }
                if let setter = findFlagSetterBefore(off, funcFloor: range.start) {
                    setterOffsets.append(setter)
                }
            }
        }

        let unique = Array(Set(setterOffsets)).sorted()
        guard !unique.isEmpty else {
            log("  [~] no TSSF_CHECK_ENTITLEMENT setter reaches thread_set_state; skipping")
            return true
        }

        for setterOff in unique {
            guard let orig = disasAt(setterOff),
                  let rd = wRegisterNumber(orig),
                  let bytes = ARM64Encoder.encodeMovzW(rd: rd, imm16: Self.tssFlagsCleared),
                  let check = disasm.disassembleOne(bytes, at: UInt64(setterOff)),
                  (check.mnemonic == "mov" || check.mnemonic == "movz"),
                  let ops = check.aarch64?.operands, ops.count == 2,
                  ops[1].type == AARCH64_OP_IMM, ops[1].imm == Int64(Self.tssFlagsCleared)
            else {
                log("  [-] failed to assemble/verify cleared flags at 0x\(String(format: "%X", setterOff))")
                return false
            }
            emit(setterOff, bytes,
                 patchID: "kernelcache_frida.thread_set_state_entitlement_flag",
                 virtualAddress: fileOffsetToVA(setterOff),
                 description: "clear TSSF_CHECK_ENTITLEMENT (0x201 -> 0x1) [thread_set_state user setter, --frida]")
        }
        return true
    }

    // MARK: - Helpers

    /// Direct B/BL target (disassembly runs in file-offset space).
    private func branchTargetFileOffset(_ insn: Instruction) -> Int? {
        guard let ops = insn.aarch64?.operands, ops.count == 1,
              ops[0].type == AARCH64_OP_IMM
        else { return nil }
        return Int(ops[0].imm)
    }

    /// Scan back up to 8 instructions for `mov w6, #0x201`, abandoning if w6 is
    /// otherwise written first. Returns the setter's file offset.
    private func findFlagSetterBefore(_ branchOff: Int, funcFloor: Int) -> Int? {
        var off = branchOff - 4
        var steps = 0
        while off >= funcFloor, steps < 8 {
            defer { off -= 4; steps += 1 }
            guard let insn = disasAt(off) else { continue }
            guard insn.mnemonic == "mov" || insn.mnemonic == "movz" else { continue }
            guard let ops = insn.aarch64?.operands, ops.count == 2,
                  ops[0].type == AARCH64_OP_REG, ops[1].type == AARCH64_OP_IMM,
                  disasm.firstRegisterName(insn) == "w6"
            else { continue }
            return ops[1].imm == Self.tssFlagsFromUser ? off : nil
        }
        return nil
    }

    private func wRegisterNumber(_ insn: Instruction) -> UInt32? {
        guard let name = disasm.firstRegisterName(insn), name.hasPrefix("w"),
              let value = UInt32(name.dropFirst()), value < 32
        else { return nil }
        return value
    }
}
