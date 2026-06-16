// ARM64Encoder.swift — PC-relative instruction encoding for ARM64.
//
// Replaces keystone-engine _asm_at() for branch/ADRP/ADD encoding.
// Each encoder produces a 4-byte little-endian Data value.

import Foundation

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
