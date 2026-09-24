// ARM64Encoder.swift — instruction encoding for ARM64.
//
// Replaces keystone-engine's `asm()` / `asm_at()` for the CFW patchers. The set
// of encoders here is closed deliberately: it is exactly the instruction set the
// 19 Python patchers assemble, recovered by grepping every `asm(...)` call site.
// This is not a general assembler and must not grow into one — add an encoder
// when a patcher needs the instruction, not before.
//
// Every field layout below is written out from the ARM64 ISA encoding rather
// than copied from a keystone dump, and every one is asserted against keystone
// in ARM64EncoderTests.swift.
//
// Each encoder produces a 4-byte little-endian Data value.

import Foundation

// MARK: - Condition Codes

/// ARM64 condition codes, `cond` in bits [15:12] of the conditional-select family.
///
/// Only the 14 invertible conditions exist here. `AL` (0b1110) and `NV` (0b1111)
/// are each other's inverse and are rejected by CSET, which is the only consumer.
public enum ARM64Condition: UInt32, Sendable, CaseIterable {
    case eq = 0b0000 // equal — Z == 1
    case ne = 0b0001 // not equal
    case hs = 0b0010 // unsigned >= — C == 1
    case lo = 0b0011 // unsigned <
    case mi = 0b0100 // negative — N == 1
    case pl = 0b0101 // positive or zero
    case vs = 0b0110 // overflow — V == 1
    case vc = 0b0111 // no overflow
    case hi = 0b1000 // unsigned >
    case ls = 0b1001 // unsigned <=
    case ge = 0b1010 // signed >=
    case lt = 0b1011 // signed <
    case gt = 0b1100 // signed >
    case le = 0b1101 // signed <=

    /// The condition true exactly when this one is false.
    ///
    /// AArch64 orders the condition codes in complementary pairs, so inverting
    /// bit 0 inverts the test. This is why CSET can be a CSINC alias at all.
    public var inverted: ARM64Condition {
        // Safe: flipping bit 0 stays inside 0b0000...0b1101 for every case here.
        ARM64Condition(rawValue: rawValue ^ 1)!
    }
}

public enum ARM64Encoder {
    // MARK: - Branch Encoding

    /// Encode unconditional B (branch) instruction.
    ///
    /// Format: `[31:26] = 0b000101`, `[25:0] = signed offset / 4`
    /// Range: +/-128 MB
    public static func encodeB(from pc: Int, to target: Int) -> Data? {
        let delta = (target - pc)
        guard delta & 0x3 == 0 else { return nil }
        let imm26 = delta >> 2
        guard imm26 >= -(1 << 25), imm26 < (1 << 25) else { return nil }
        let insn: UInt32 = 0x1400_0000 | (UInt32(bitPattern: Int32(imm26)) & 0x03FF_FFFF)
        return ARM64.encodeU32(insn)
    }

    /// Encode BL (branch with link) instruction.
    ///
    /// Format: `[31:26] = 0b100101`, `[25:0] = signed offset / 4`
    /// Range: +/-128 MB
    public static func encodeBL(from pc: Int, to target: Int) -> Data? {
        let delta = (target - pc)
        guard delta & 0x3 == 0 else { return nil }
        let imm26 = delta >> 2
        guard imm26 >= -(1 << 25), imm26 < (1 << 25) else { return nil }
        let insn: UInt32 = 0x9400_0000 | (UInt32(bitPattern: Int32(imm26)) & 0x03FF_FFFF)
        return ARM64.encodeU32(insn)
    }

    /// Encode TBZ/TBNZ (test bit and branch). Target must be 4-byte aligned and
    /// within the signed 14-bit range (+/-32 KB).
    ///
    /// Format: `[31] = b5`, `[30:24] = 0110110 (TBZ) / 0110111 (TBNZ)`,
    ///         `[23:19] = b40`, `[18:5] = imm14`, `[4:0] = Rt`
    public static func encodeTestBitBranch(
        nonzero: Bool,
        register: UInt32,
        bit: UInt32,
        from pc: Int,
        to target: Int,
    ) -> Data? {
        guard register < 32, bit < 64 else { return nil }
        let delta = target - pc
        guard delta & 0x3 == 0 else { return nil }
        let imm14 = delta >> 2
        guard imm14 >= -(1 << 13), imm14 < (1 << 13) else { return nil }

        var insn: UInt32 = nonzero ? 0x3700_0000 : 0x3600_0000
        insn |= (bit & 0x20) << 26
        insn |= (bit & 0x1F) << 19
        insn |= (UInt32(bitPattern: Int32(imm14)) & 0x3FFF) << 5
        insn |= register & 0x1F
        return ARM64.encodeU32(insn)
    }

    // MARK: - ADRP / ADD Encoding

    /// Encode ADRP instruction.
    ///
    /// ADRP loads a 4KB-aligned page address relative to PC.
    /// Format: `[31] = 1 (op)`, `[30:29] = immlo`, `[28:24] = 0b10000`,
    ///         `[23:5] = immhi`, `[4:0] = Rd`
    public static func encodeADRP(rd: UInt32, pc: UInt64, target: UInt64) -> Data? {
        let pcPage = pc & ~0xFFF
        let targetPage = target & ~0xFFF
        let pageDelta = Int64(targetPage) - Int64(pcPage)
        let immVal = pageDelta >> 12
        guard immVal >= -(1 << 20), immVal < (1 << 20) else { return nil }
        let imm21 = UInt32(bitPattern: Int32(immVal)) & 0x1FFFFF
        let immlo = imm21 & 0x3
        let immhi = (imm21 >> 2) & 0x7FFFF
        let insn: UInt32 = (1 << 31) | (immlo << 29) | (0b10000 << 24) | (immhi << 5) | (rd & 0x1F)
        return ARM64.encodeU32(insn)
    }

    /// Encode ADD Xd, Xn, #imm12 (64-bit, no shift).
    ///
    /// Format: `[31] = 1 (sf)`, `[30:29] = 00`, `[28:24] = 0b10001`,
    ///         `[23:22] = 00 (shift)`, `[21:10] = imm12`, `[9:5] = Rn`, `[4:0] = Rd`
    public static func encodeAddImm12(rd: UInt32, rn: UInt32, imm12: UInt32) -> Data? {
        guard imm12 < 4096 else { return nil }
        let insn: UInt32 = (1 << 31) | (0b0010001 << 24) | (imm12 << 10) | ((rn & 0x1F) << 5) | (rd & 0x1F)
        return ARM64.encodeU32(insn)
    }

    /// Encode MOVZ Wd, #imm16 (32-bit).
    ///
    /// Format: `[31] = 0 (sf)`, `[30:29] = 10`, `[28:23] = 100101`,
    ///         `[22:21] = hw`, `[20:5] = imm16`, `[4:0] = Rd`
    public static func encodeMovzW(rd: UInt32, imm16: UInt16, shift: UInt32 = 0) -> Data? {
        let hw = shift / 16
        guard hw <= 1 else { return nil }
        let insn: UInt32 = (0b0_1010_0101 << 23) | (hw << 21) | (UInt32(imm16) << 5) | (rd & 0x1F)
        return ARM64.encodeU32(insn)
    }

    /// Encode MOVZ Xd, #imm16 (64-bit).
    public static func encodeMovzX(rd: UInt32, imm16: UInt16, shift: UInt32 = 0) -> Data? {
        let hw = shift / 16
        guard hw <= 3 else { return nil }
        let insn: UInt32 = (0b1_1010_0101 << 23) | (hw << 21) | (UInt32(imm16) << 5) | (rd & 0x1F)
        return ARM64.encodeU32(insn)
    }

    /// Encode `MOV Xd, Xm` (the ORR Xd, XZR, Xm alias). With `rm == 31` (XZR) this
    /// is the canonical "zero a 64-bit register" (`mov xd, xzr`).
    ///
    /// Format: `[31] = 1 (sf)`, `[30:24] = 0101010`, `[23:22] = 00 (shift)`,
    ///         `[20:16] = Rm`, `[15:10] = 0 (imm6)`, `[9:5] = 11111 (XZR)`, `[4:0] = Rd`
    public static func encodeMovX(rd: UInt32, rm: UInt32) -> Data {
        let insn: UInt32 = 0xAA00_03E0 | ((rm & 0x1F) << 16) | (rd & 0x1F)
        return ARM64.encodeU32(insn)
    }

    // MARK: - Conditional Set

    /// Encode `CSET Wd, <cond>` — set Wd to 1 when `condition` holds, else 0.
    ///
    /// CSET is an alias of `CSINC Wd, WZR, WZR, invert(cond)`: the increment path
    /// (WZR + 1 = 1) runs when the *encoded* condition is false, so the encoded
    /// condition is the inverse of the one written in the assembly.
    ///
    /// CSINC format: `[31] = 0 (sf, 32-bit)`, `[30] = 0 (op)`, `[29] = 0 (S)`,
    ///               `[28:21] = 11010100`, `[20:16] = Rm`, `[15:12] = cond`,
    ///               `[11:10] = 01 (o2:o1, selects CSINC)`, `[9:5] = Rn`, `[4:0] = Rd`
    public static func encodeCsetW(rd: UInt32, condition: ARM64Condition) -> Data? {
        guard rd < 32 else { return nil }
        var insn: UInt32 = 0b000_1101_0100 << 21
        insn |= 31 << 16 // Rm = WZR
        insn |= condition.inverted.rawValue << 12
        insn |= 0b01 << 10 // CSINC
        insn |= 31 << 5 // Rn = WZR
        insn |= rd
        return ARM64.encodeU32(insn)
    }

    // MARK: - Loads

    /// Encode `LDR Wt, [Xn, #offset]` — 32-bit load, unsigned scaled offset.
    ///
    /// Format: `[31:30] = 10 (size = 32-bit)`, `[29:27] = 111`, `[26] = 0 (V, non-SIMD)`,
    ///         `[25:24] = 01 (unsigned offset)`, `[23:22] = 01 (opc = load)`,
    ///         `[21:10] = imm12`, `[9:5] = Rn`, `[4:0] = Rt`
    ///
    /// `imm12` is scaled by the access size, so `offset` must be a multiple of 4
    /// in `0...16380`. `rn == 31` means SP, which is what the base encoding says.
    public static func encodeLdrWUnsignedOffset(rt: UInt32, rn: UInt32, offset: UInt32) -> Data? {
        guard rt < 32, rn < 32 else { return nil }
        guard offset % 4 == 0 else { return nil }
        let imm12 = offset / 4
        guard imm12 < 4096 else { return nil }

        var insn: UInt32 = 0b10 << 30 // size
        insn |= 0b111 << 27
        insn |= 0b01 << 24
        insn |= 0b01 << 22 // opc = LDR
        insn |= imm12 << 10
        insn |= rn << 5
        insn |= rt
        return ARM64.encodeU32(insn)
    }

    // MARK: - Decode Helpers

    /// Decode a B or BL target address from an instruction at `pc`.
    public static func decodeBranchTarget(insn: UInt32, pc: UInt64) -> UInt64? {
        let op = insn >> 26
        guard op == 0b000101 || op == 0b100101 else { return nil }
        let imm26 = insn & 0x03FF_FFFF
        // Sign-extend 26-bit to 32-bit
        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
        let offset = Int64(signedImm) * 4
        return UInt64(Int64(pc) + offset)
    }
}
