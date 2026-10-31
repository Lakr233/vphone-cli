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
/// are each other's inverse and are rejected by CSET.
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
    // MARK: - Register arithmetic

    /// MADD/MSUB X-register form; register 31 is XZR.
    public static func encodeMaddSubX(subtract: Bool, rd: UInt32, rn: UInt32, rm: UInt32, ra: UInt32) -> Data? {
        guard rd < 32, rn < 32, rm < 32, ra < 32 else { return nil }
        return ARM64.encodeU32((subtract ? 0x9B00_8000 : 0x9B00_0000) | (rm << 16) | (ra << 10) | (rn << 5) | rd)
    }

    /// Shifted ADD/SUB X-register form; register 31 is XZR.
    public static func encodeAddSubXShifted(subtract: Bool, rd: UInt32, rn: UInt32, rm: UInt32, shift: UInt32 = 0) -> Data? {
        guard rd < 32, rn < 32, rm < 32, shift < 64 else { return nil }
        return ARM64.encodeU32((subtract ? 0xCB00_0000 : 0x8B00_0000) | (rm << 16) | (shift << 10) | (rn << 5) | rd)
    }

    /// UXTX ADD/SUB form; Rd/Rn 31 are SP and Rm 31 is XZR.
    public static func encodeAddSubXExtended(subtract: Bool, rd: UInt32, rn: UInt32, rm: UInt32, shift: UInt32 = 0) -> Data? {
        guard rd < 32, rn < 32, rm < 32, shift <= 4 else { return nil }
        return ARM64.encodeU32((subtract ? 0xCB20_6000 : 0x8B20_6000) | (rm << 16) | (shift << 10) | (rn << 5) | rd)
    }

    // MARK: - Comparisons

    /// CMP Xn, Xm (SUBS XZR, Xn, Xm); register 31 is XZR.
    public static func encodeCmpX(rn: UInt32, rm: UInt32) -> Data? {
        guard rn < 32, rm < 32 else { return nil }
        let insn: UInt32 = 0xEB00_001F | (rm << 16) | (rn << 5)
        return ARM64.encodeU32(insn)
    }

    /// CMP Wn,#imm12; register 31 is WSP.
    public static func encodeCmpWImmediate(rn: UInt32, imm12: UInt32) -> Data? {
        guard rn < 32, imm12 < 4096 else { return nil }
        return ARM64.encodeU32(0x7100_001F | (imm12 << 10) | (rn << 5))
    }

    /// CCMP Wn,#imm5,#nzcv,cond; register 31 is WZR.
    public static func encodeCcmpWImmediate(rn: UInt32, imm5: UInt32, nzcv: UInt32, condition: ARM64Condition) -> Data? {
        guard rn < 32, imm5 < 32, nzcv < 16 else { return nil }
        return ARM64.encodeU32(0x7A40_0800 | (imm5 << 16) | (condition.rawValue << 12) | (rn << 5) | nzcv)
    }

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

    /// Encode `B.cond`. The immediate is a signed 19-bit instruction offset (±1 MiB).
    public static func encodeBCond(from pc: Int, to target: Int, condition: ARM64Condition) -> Data? {
        let delta = target - pc
        guard delta & 0x3 == 0 else { return nil }
        let imm19 = delta >> 2
        guard imm19 >= -(1 << 18), imm19 < (1 << 18) else { return nil }
        let insn: UInt32 = 0x5400_0000 | ((UInt32(bitPattern: Int32(imm19)) & 0x7FFFF) << 5) | condition.rawValue
        return ARM64.encodeU32(insn)
    }

    /// Encode `CBZ`/`CBNZ` for a general-purpose register.
    ///
    /// The 32-bit form is used by the IOMFB display dispatcher so the loaded
    /// mach port does not overwrite the upper half of the scratch register.
    /// The immediate is a signed 19-bit instruction offset (±1 MiB).
    public static func encodeCompareBranch(
        nonzero: Bool,
        register: UInt32,
        from pc: Int,
        to target: Int,
        width64: Bool = false,
    ) -> Data? {
        guard register < 32 else { return nil }
        let delta = target - pc
        guard delta & 0x3 == 0 else { return nil }
        let imm19 = delta >> 2
        guard imm19 >= -(1 << 18), imm19 < (1 << 18) else { return nil }
        var insn: UInt32 = (width64 ? 0xB400_0000 : 0x3400_0000)
        if nonzero {
            insn |= 1 << 24
        }
        insn |= (UInt32(bitPattern: Int32(imm19)) & 0x7FFFF) << 5
        insn |= register
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

    /// BRAA Xn, Xm (Xm == 31 means SP). Apple clang -arch arm64e checked;
    /// Keystone 0.9.2 does not support pointer-authentication mnemonics.
    public static func encodeBRAA(rn: UInt32, rm: UInt32) -> Data? {
        guard rn < 31, rm < 32 else { return nil }
        return ARM64.encodeU32(0xD71F_0800 | (rn << 5) | rm)
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
        let pageDelta = Int64(bitPattern: targetPage &- pcPage)
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

    /// SUB Xd, Xn, #imm12; register 31 denotes SP, without changing flags.
    public static func encodeSubImm12(rd: UInt32, rn: UInt32, imm12: UInt32) -> Data? {
        guard rd < 32, rn < 32, imm12 < 4096 else { return nil }
        return ARM64.encodeU32(0xD100_0000 | (imm12 << 10) | (rn << 5) | rd)
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

    /// MOVK Wd, #imm16, LSL #shift; replace one 16-bit lane.
    public static func encodeMovkW(rd: UInt32, imm16: UInt16, shift: UInt32 = 0) -> Data? {
        guard rd < 32, shift == 0 || shift == 16 else { return nil }
        let insn: UInt32 = 0x7280_0000 | ((shift / 16) << 21) | (UInt32(imm16) << 5) | rd
        return ARM64.encodeU32(insn)
    }

    /// Encode MOVZ Xd, #imm16 (64-bit).
    public static func encodeMovzX(rd: UInt32, imm16: UInt16, shift: UInt32 = 0) -> Data? {
        let hw = shift / 16
        guard hw <= 3 else { return nil }
        let insn: UInt32 = (0b1_1010_0101 << 23) | (hw << 21) | (UInt32(imm16) << 5) | (rd & 0x1F)
        return ARM64.encodeU32(insn)
    }

    /// Encode MOVK Xd, #imm16, LSL #shift (64-bit) — replace one 16-bit lane of
    /// Xd and keep the others.
    ///
    /// Format: `[31] = 1 (sf)`, `[30:29] = 11`, `[28:23] = 100101`,
    ///         `[22:21] = hw`, `[20:5] = imm16`, `[4:0] = Rd`
    public static func encodeMovkX(rd: UInt32, imm16: UInt16, shift: UInt32 = 0) -> Data? {
        guard shift % 16 == 0 else { return nil }
        let hw = shift / 16
        guard hw <= 3 else { return nil }
        let insn: UInt32 = (0b1_1110_0101 << 23) | (hw << 21) | (UInt32(imm16) << 5) | (rd & 0x1F)
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

    /// LDRB Wt, [Xn|SP, #offset], with an unsigned byte offset.
    public static func encodeLdrBUnsignedOffset(rt: UInt32, rn: UInt32, offset: UInt32) -> Data? {
        guard rt < 32, rn < 32, offset < 4096 else { return nil }
        let insn: UInt32 = 0x3940_0000 | (offset << 10) | (rn << 5) | rt
        return ARM64.encodeU32(insn)
    }

    /// STRB Wt, [Xn|SP, #offset], with an unsigned byte offset.
    public static func encodeStrBUnsignedOffset(rt: UInt32, rn: UInt32, offset: UInt32) -> Data? {
        guard rt < 32, rn < 32, offset < 4096 else { return nil }
        let insn: UInt32 = 0x3900_0000 | (offset << 10) | (rn << 5) | rt
        return ARM64.encodeU32(insn)
    }

    /// LDR Xt, [Xn, #offset]; rn 31 is SP, scaled by eight.
    public static func encodeLdrXUnsignedOffset(rt: UInt32, rn: UInt32, offset: UInt32) -> Data? {
        guard rt < 32, rn < 32, offset % 8 == 0, offset / 8 < 4096 else { return nil }
        return ARM64.encodeU32(0xF940_0000 | ((offset / 8) << 10) | (rn << 5) | rt)
    }

    // MARK: - Stores

    /// STR Wt, [Xn, #offset]; rn 31 is SP, scaled by four.
    public static func encodeStrWUnsignedOffset(rt: UInt32, rn: UInt32, offset: UInt32) -> Data? {
        guard rt < 32, rn < 32, offset % 4 == 0, offset / 4 < 4096 else { return nil }
        return ARM64.encodeU32(0xB900_0000 | ((offset / 4) << 10) | (rn << 5) | rt)
    }

    /// Encode `STR Xt, [Xn, #offset]` — 64-bit store, unsigned scaled offset.
    ///
    /// The unsigned immediate uses `opc = 00`; `imm12` is
    /// scaled by 8, so `offset` must be a multiple of 8 in `0...32760`.
    /// `rn == 31` means SP.
    public static func encodeStrXUnsignedOffset(rt: UInt32, rn: UInt32, offset: UInt32) -> Data? {
        guard rt < 32, rn < 32 else { return nil }
        guard offset % 8 == 0 else { return nil }
        let imm12 = offset / 8
        guard imm12 < 4096 else { return nil }

        var insn: UInt32 = 0b11 << 30 // size
        insn |= 0b111 << 27
        insn |= 0b01 << 24
        insn |= 0b00 << 22 // opc = STR
        insn |= imm12 << 10
        insn |= rn << 5
        insn |= rt
        return ARM64.encodeU32(insn)
    }

    /// Encode `STP Xt1, Xt2, [Xn, #offset]` — 64-bit store pair, signed scaled
    /// offset, no writeback.
    ///
    /// Format: `[31:30] = 10 (opc = 64-bit)`, `[29:27] = 101`, `[26] = 0 (V)`,
    ///         `[25:23] = 010 (signed offset)`, `[22] = 0 (L = store)`,
    ///         `[21:15] = imm7`, `[14:10] = Rt2`, `[9:5] = Rn`, `[4:0] = Rt1`
    ///
    /// `imm7` is scaled by 8, so `offset` must be a multiple of 8 in
    /// `-512...504`. `rn == 31` means SP.
    public static func encodeStpX(rt1: UInt32, rt2: UInt32, rn: UInt32, offset: Int32) -> Data? {
        guard rt1 < 32, rt2 < 32, rn < 32 else { return nil }
        guard offset % 8 == 0 else { return nil }
        let imm7 = offset / 8
        guard imm7 >= -64, imm7 <= 63 else { return nil }

        var insn: UInt32 = 0b10 << 30
        insn |= 0b101 << 27
        insn |= 0b010 << 23
        insn |= (UInt32(bitPattern: imm7) & 0x7F) << 15
        insn |= rt2 << 10
        insn |= rn << 5
        insn |= rt1
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

public extension ARM64Encoder {
    /// Scale of the unsigned imm12 load/store family, including SIMD Q loads.
    /// This changes only an existing instruction's immediate, never its opcode.
    private static func pageOffsetScale(_ instruction: UInt32) -> UInt32? {
        if instruction & 0x3B00_0000 == 0x3900_0000 {
            let size = instruction >> 30
            if size == 0, instruction & 0x0480_0000 == 0x0480_0000 {
                return 16
            }
            return 1 << size
        }
        if instruction & 0xFFC0_0000 == 0x9100_0000 {
            return 1
        }
        return nil
    }

    static func decodePageOffset(_ instruction: UInt32) -> UInt32? {
        guard let scale = pageOffsetScale(instruction) else { return nil }
        return ((instruction >> 10) & 0xFFF) * scale
    }

    /// Same truncation of low alignment bits as the cache export's OFF12 fixup.
    static func retargetPageOffset(_ instruction: UInt32, offset: UInt32) -> Data? {
        guard offset < 4096, let scale = pageOffsetScale(instruction) else { return nil }
        return ARM64.encodeU32((instruction & 0xFFC0_03FF) | ((offset / scale) << 10))
    }
}
