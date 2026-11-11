import Foundation
import VPhonePatchKit

extension TXMDevPatcher {
    /// Research compatibility for AMFI's fabricated cache hits: those skip
    /// profile association even when native TXM CMS classification yields type 4.
    /// This waives profile authorization when absent; it does not restore it.
    /// Keep the type, all earlier validation, and every non-null profile check.
    /// Only locates the site; the owning remap patch emits it after every
    /// required compatibility site has been found.
    func remapMissingProfileCompatibility(_ code: [ARM64Instruction], categoryOffset: Int64) throws -> (site: Int, bytes: Data) {
        var sites: [Int] = []
        for i in code.indices.dropFirst(4).dropLast(5) {
            // Unique error 1 / error 0x12 / component A6, followed directly by
            // the shared epilogue. Error constants are semantic anchors, not VAs.
            guard profileImmediate(code[i], "mov", .w(0), 0x12a6),
                  profileImmediate(code[i + 1], "movk", .w(0), 1),
                  code[i + 1].detail?.operands.last?.shift.type == .lsl,
                  code[i + 1].detail?.operands.last?.shift.amount == 16,
                  profileRegisters(code[i + 2], "ldp", [.x(29), .x(30)]),
                  profileRegisters(code[i + 3], "ldp", [.x(20), .x(19)]),
                  profileRegisters(code[i + 4], "add", [.sp, .sp]),
                  code[i + 5].mnemonic == "retab",
                  let start = code[..<i].lastIndex(where: { $0.mnemonic == "pacibsp" })
            else { continue }

            let error = Int(code[i].address)
            let epilogue = Int(code[i + 2].address)
            let function = start ..< i + 6
            // Non-null validation converges on the A6 success result, and
            // branches around the error block. Leave this entire path intact.
            guard profileImmediate(code[i - 4], "tst", .w(0), 0xff00),
                  profileImmediate(code[i - 3], "mov", .w(8), 0xa6),
                  profileRegisters(code[i - 2], "csel", [.w(0), .w(8), .w(0)]),
                  code[i - 2].detail?.conditionCode == .eq,
                  profileBranch(code[i - 1], "b") == epilogue
            else { continue }

            let guards = function.dropLast().filter { j in
                profileMemory(code[j], "ldr", .x(8), .x(0), categoryOffset + 7)
                    && profileRegisters(code[j + 1], "cbz", [.x(8)])
                    && profileTarget(code[j + 1]) == error
            }
            guard guards.count == 1, let nullGuard = guards.first,
                  // No other direct branch may share either replaced instruction.
                  code.indices.filter({ profileTarget(code[$0]) == error }) == [nullGuard + 1],
                  !code.contains(where: { profileTarget($0) == error + 4 }),
                  code[start ..< i].filter({ profileBranch($0, "b.ne") == epilogue }).count == 2
            else { continue }

            // Prove the only caller is the native finalizer's type-4 arm.
            // The classifier recovers the category field from the pre-check's
            // arguments: +0xa1 on 26.1–26.3, +0x101 on 26.4. In both inspected
            // layouts, the finalized byte follows it, then the aligned profile
            // pointer. Require the finalizer and validator to agree with it.
            let calls = code.indices.filter { profileTarget(code[$0]) == Int(code[start].address) }
            guard calls.count == 1, let call = calls.first, call >= 2, call + 5 < code.count,
                  code[call].mnemonic == "bl",
                  profileRegisters(code[call - 1], "mov", [.x(0), .x(19)]),
                  profileImmediate(code[call + 1], "tst", .w(0), 0xff00),
                  profileBranch(code[call + 2], "b.ne") == Int(code[call + 5].address),
                  profileMemory(code[call + 3], "strb", .w(20), .x(19), categoryOffset + 1),
                  profileImmediate(code[call + 4], "mov", .w(0), 3),
                  profileBranch(code[call - 2], "b") == Int(code[call + 1].address),
                  let finalizer = code[..<call].lastIndex(where: { $0.mnemonic == "pacibsp" })
            else { continue }
            let dispatch = (finalizer ..< call - 1).filter { j in
                profileImmediate(code[j], "cmp", .w(20), 4)
                    && profileBranch(code[j + 1], "b.eq") == Int(code[call - 1].address)
            }
            guard dispatch.count == 1, let type4 = dispatch.first,
                  code[finalizer ..< type4].contains(where: {
                      profileMemory($0, "ldrb", .w(20), .x(0), categoryOffset)
                  }),
                  code.indices.filter({ profileTarget(code[$0]) == Int(code[call - 1].address) }) == [type4 + 1]
            else { continue }
            sites.append(error)
        }

        guard sites.count == 1, let site = sites.first,
              let success = ARM64Encoder.encodeMovzW(rd: 0, imm16: 0xa6) else {
            throw PatcherError.patchSiteNotFound("TXM missing-profile compatibility: expected one type-4 null-profile error exit")
        }
        return (site, success + ARM64.nop)
    }

    private func profileImmediate(_ instruction: ARM64Instruction, _ mnemonic: String,
                                  _ register: ARM64Register, _ value: Int64) -> Bool
    {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 2 else { return false }
        return operands[0].type == .register && operands[0].reg == register
            && operands[1].type == .immediate && operands[1].imm == value
    }

    private func profileRegisters(_ instruction: ARM64Instruction, _ mnemonic: String, _ registers: [ARM64Register]) -> Bool {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count >= registers.count else { return false }
        return zip(operands, registers).allSatisfy { $0.type == .register && $0.reg == $1 }
    }

    private func profileMemory(_ instruction: ARM64Instruction, _ mnemonic: String,
                               _ register: ARM64Register, _ base: ARM64Register, _ offset: Int64) -> Bool
    {
        guard profileRegisters(instruction, mnemonic, [register]),
              let operands = instruction.detail?.operands, operands.count == 2 else { return false }
        return operands[1].type == .memory && operands[1].mem.base == base
            && operands[1].mem.index == .invalid && Int64(operands[1].mem.disp) == offset
            && instruction.detail?.writeback == false
    }

    private func profileTarget(_ instruction: ARM64Instruction) -> Int? {
        guard instruction.isJump || instruction.isCall,
              let operand = instruction.detail?.operands.last,
              operand.type == .immediate, operand.imm >= 0 else { return nil }
        return Int(operand.imm)
    }

    private func profileBranch(_ instruction: ARM64Instruction, _ mnemonic: String) -> Int? {
        instruction.mnemonic == mnemonic ? profileTarget(instruction) : nil
    }
}
