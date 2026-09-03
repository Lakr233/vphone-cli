// TXMPatcher.swift — TXM (Trusted Execution Monitor) patcher.
//
// Implements the trustcache bypass patch.
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

/// Patcher for TXM trustcache bypass.
///
/// Patches:
///   1. Trustcache binary-search BL → mov x0, #0
///      (in the AMFI cert verification function identified by the
///       unique constant 0x2446 loaded into w19)
public class TXMPatcher: Patcher {
    public let component = "txm"
    public let verbose: Bool

    let buffer: BinaryBuffer
    let disasm = ARM64Disassembler()
    var patches: [PatchRecord] = []

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    public func findAll() throws -> [PatchRecord] {
        patches = []
        try patchTrustcacheBypass()
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty {
            let _ = try findAll()
        }
        for record in patches {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) TXM patches applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        buffer.data
    }

    // MARK: - Emit

    func emit(
        _ offset: Int,
        _ patchBytes: Data,
        patchID: String,
        virtualAddress: UInt64? = nil,
        description: String
    ) {
        let originalBytes = buffer.readBytes(at: offset, count: patchBytes.count)

        let beforeInsn = disasm.disassembleOne(in: buffer.original, at: offset)
        let afterInsn = disasm.disassembleOne(patchBytes, at: UInt64(offset))

        let beforeStr = beforeInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"
        let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"

        let record = PatchRecord(
            patchID: patchID,
            component: component,
            fileOffset: offset,
            virtualAddress: virtualAddress,
            originalBytes: originalBytes,
            patchedBytes: patchBytes,
            beforeDisasm: beforeStr,
            afterDisasm: afterStr,
            description: description
        )

        patches.append(record)

        if verbose {
            print("  0x\(String(format: "%06X", offset)): \(beforeStr) → \(afterStr)  [\(description)]")
        }
    }
}

// MARK: - Trustcache Bypass

extension TXMPatcher {
    // ═══════════════════════════════════════════════════════════
    //  Trustcache bypass
    //
    //  Current 26.1 TXM images no longer carry the legacy
    //  `mov w19, #0x2446` / binary-search shape from the old Python patcher.
    //
    //  Instead, the stable site is in selector24 hash-flags validation:
    //    ldr x1, [x20, #0x38]
    //    add x2, sp, #4
    //    bl  hash_flags_extract
    //    ldp x0, x1, [x20, #0x30]
    //    add x2, sp, #8
    //    bl  hash_data_extract
    //
    //  Patching the first BL to `mov x0, #0` leaves the stack-local flags
    //  at their initialized zero value, bypassing the selector24 hash-flags
    //  consistency gate. This still works if the TXM image already carries
    //  the dev/JB selector24 early-return patch, because the call sequence
    //  remains present later in the function.
    // ═══════════════════════════════════════════════════════════

    func patchTrustcacheBypass() throws {
        if let legacyBL = findLegacyTrustcacheBypassCall() {
            emit(
                legacyBL,
                ARM64.movX0_0,
                patchID: "txm.trustcache_bypass",
                description: "trustcache bypass: legacy binary-search call → mov x0, #0"
            )
            return
        }

        if let selector24BL = findSelector24HashFlagsCall() {
            emit(
                selector24BL,
                ARM64.movX0_0,
                patchID: "txm.trustcache_bypass",
                description: "trustcache bypass: selector24 hash-flags call → mov x0, #0"
            )
            return
        }

        if verbose {
            print("  [-] TXM: selector24 hash-flags site and legacy binary-search site not found")
        }
        throw PatcherError.patchSiteNotFound(
            "selector24 hash-flags call / legacy binary-search trustcache site not found"
        )
    }

    private func findSelector24HashFlagsCall() -> Int? {
        let insns = disasm.disassemble(buffer.original, at: 0)
        var matches: [Int] = []

        for i in 0 ..< max(0, insns.count - 5) {
            let i0 = insns[i]
            let i1 = insns[i + 1]
            let i2 = insns[i + 2]
            let i3 = insns[i + 3]
            let i4 = insns[i + 4]
            let i5 = insns[i + 5]

            guard isLdrRegFromBaseImm(i0, dest: AARCH64_REG_X1, base: AARCH64_REG_X20, disp: 0x38) else { continue }
            guard isAddImmediate(i1, dest: AARCH64_REG_X2, base: AARCH64_REG_SP, imm: 4) else { continue }
            guard isBLOrPatchedMovX0Zero(i2) else { continue }
            guard isLdpX0X1FromX20_0x30(i3) else { continue }
            guard isAddImmediate(i4, dest: AARCH64_REG_X2, base: AARCH64_REG_SP, imm: 8) else { continue }
            guard i5.mnemonic == "bl" else { continue }

            matches.append(Int(i2.address))
        }

        guard matches.count == 1 else {
            if verbose {
                print("  [-] TXM: expected 1 selector24 hash-flags call site, found \(matches.count)")
            }
            return nil
        }
        return matches[0]
    }

    private func findLegacyTrustcacheBypassCall() -> Int? {
        let markerBytes = ARM64.encodeU32(0x5284_88D3)
        let markerLocs = buffer.findAll(markerBytes)
        guard markerLocs.count == 1 else { return nil }

        guard let funcStart = findFunctionStart(from: markerLocs[0]) else { return nil }

        let funcEnd = min(funcStart + 0x2000, buffer.count)
        let funcData = buffer.readBytes(at: funcStart, count: funcEnd - funcStart)
        let insns = disasm.disassemble(funcData, at: UInt64(funcStart))

        for i in 0 ..< max(0, insns.count - 3) {
            let i0 = insns[i]
            let i1 = insns[i + 1]
            let i2 = insns[i + 2]
            let i3 = insns[i + 3]

            guard isMovImm(i0, dest: AARCH64_REG_W2, imm: 0x14) else { continue }
            guard isBLOrPatchedMovX0Zero(i1) else { continue }
            guard isCBZW0(i2) else { continue }
            guard isTBZFamilyBit31(i3) else { continue }

            return Int(i1.address)
        }
        return nil
    }

    // MARK: - Helpers

    /// Scan backward from `offset` (aligned to 4 bytes) for a PACIBSP instruction.
    /// Searches up to 0x200 bytes back, matching the Python implementation.
    private func findFunctionStart(from offset: Int) -> Int? {
        let pacibspU32 = ARM64.pacibspU32
        var scan = offset & ~3
        let limit = max(0, offset - 0x200)
        while scan >= limit {
            let insn = buffer.readU32(at: scan)
            if insn == pacibspU32 {
                return scan
            }
            if scan == 0 { break }
            scan -= 4
        }
        return nil
    }

    private func isMovImm(_ insn: Instruction, dest: aarch64_reg, imm: Int64) -> Bool {
        guard insn.mnemonic == "mov",
              let ops = insn.aarch64?.operands, ops.count == 2,
              ops[0].type == AARCH64_OP_REG, ops[0].reg == dest,
              ops[1].type == AARCH64_OP_IMM, ops[1].imm == imm
        else { return false }
        return true
    }

    private func isAddImmediate(_ insn: Instruction, dest: aarch64_reg, base: aarch64_reg, imm: Int64) -> Bool {
        guard insn.mnemonic == "add",
              let ops = insn.aarch64?.operands, ops.count == 3,
              ops[0].type == AARCH64_OP_REG, ops[0].reg == dest,
              ops[1].type == AARCH64_OP_REG, ops[1].reg == base,
              ops[2].type == AARCH64_OP_IMM, ops[2].imm == imm
        else { return false }
        return true
    }

    private func isLdrRegFromBaseImm(_ insn: Instruction, dest: aarch64_reg, base: aarch64_reg, disp: Int32) -> Bool {
        guard insn.mnemonic == "ldr",
              let ops = insn.aarch64?.operands, ops.count >= 2,
              ops[0].type == AARCH64_OP_REG, ops[0].reg == dest,
              ops[1].type == AARCH64_OP_MEM,
              ops[1].mem.base == base,
              ops[1].mem.disp == disp
        else { return false }
        return true
    }

    private func isLdpX0X1FromX20_0x30(_ insn: Instruction) -> Bool {
        guard insn.mnemonic == "ldp",
              let ops = insn.aarch64?.operands, ops.count >= 3,
              ops[0].type == AARCH64_OP_REG, ops[0].reg == AARCH64_REG_X0,
              ops[1].type == AARCH64_OP_REG, ops[1].reg == AARCH64_REG_X1,
              ops[2].type == AARCH64_OP_MEM,
              ops[2].mem.base == AARCH64_REG_X20,
              ops[2].mem.disp == 0x30
        else { return false }
        return true
    }

    private func isBLOrPatchedMovX0Zero(_ insn: Instruction) -> Bool {
        insn.mnemonic == "bl" || buffer.readU32(at: Int(insn.address)) == ARM64.movX0_0_U32
    }

    private func isCBZW0(_ insn: Instruction) -> Bool {
        guard insn.mnemonic == "cbz",
              let ops = insn.aarch64?.operands, ops.count == 2,
              ops[0].type == AARCH64_OP_REG, ops[0].reg == AARCH64_REG_W0
        else { return false }
        return true
    }

    private func isTBZFamilyBit31(_ insn: Instruction) -> Bool {
        guard insn.mnemonic == "tbnz" || insn.mnemonic == "tbz",
              let ops = insn.aarch64?.operands, ops.count == 3,
              ops[1].type == AARCH64_OP_IMM, ops[1].imm == 0x1F
        else { return false }
        return true
    }
}
