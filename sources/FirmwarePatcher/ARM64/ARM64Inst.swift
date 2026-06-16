// ARM64Inst.swift — Raw (UInt32) instruction decoding for the fast pattern scanners.
//
// These operate directly on a 4-byte little-endian instruction word so the kernel
// patchers can scan megabytes of __TEXT_EXEC without paying Capstone's per-instruction
// cost. They are the SINGLE SOURCE OF TRUTH for the opcode masks that were previously
// re-spelled inline in each JB patch file (KernelJBPatchTaskConversion, VmProtect,
// ProcPidinfo, HookCredLabel) and in KernelJBPatcherBase.findProcSecurityPolicy.
//
// Every mask/value is documented against the ARM64 ISA encoding and round-trip
// verified against Capstone in ARM64InstTests. When a Capstone `Instruction` is
// already in hand, prefer its typed operands (see ARM64Disassembler); these raw
// predicates exist for the hot scan loops only.

import Foundation

public enum ARM64Inst {
    // MARK: - Register / immediate field accessors

    /// Rd / Rt — destination (or transfer) register, bits [4:0].
    public static func rd(_ i: UInt32) -> UInt32 { i & 0x1F }
    /// Rn — first source / base register, bits [9:5].
    public static func rn(_ i: UInt32) -> UInt32 { (i >> 5) & 0x1F }
    /// Rm — second source register, bits [20:16].
    public static func rm(_ i: UInt32) -> UInt32 { (i >> 16) & 0x1F }
    /// MOVZ/MOVN/MOVK 16-bit immediate, bits [20:5].
    public static func movImm16(_ i: UInt32) -> UInt32 { (i >> 5) & 0xFFFF }
    /// Unsigned 12-bit immediate of an ADD/SUB (immediate), bits [21:10].
    public static func addSubImm12(_ i: UInt32) -> UInt32 { (i >> 10) & 0xFFF }

    // MARK: - Opcode predicates (mask/value verified against the ISA)

    /// ADRP (any Rd): op=1, [28:24]=10000.
    public static func isADRP(_ i: UInt32) -> Bool { (i & 0x9F00_0000) == 0x9000_0000 }

    /// LDR Xt, [Xn, #imm] — 64-bit unsigned-offset load, [31:22]=1111100101.
    public static func isLDRImm64(_ i: UInt32) -> Bool { (i & 0xFFC0_0000) == 0xF940_0000 }

    /// CMP Xn, Xm ≡ SUBS XZR, Xn, Xm (64-bit, shift=0, imm6=0); Rn/Rm left free.
    public static func isCMPReg64(_ i: UInt32) -> Bool { (i & 0xFFE0_FC1F) == 0xEB00_001F }

    /// SUB Wd, Wn, #imm — 32-bit SUB (immediate), shift=0; [31:22]=0101000100.
    public static func isSUBImm32(_ i: UInt32) -> Bool { (i & 0xFFC0_0000) == 0x5100_0000 }

    /// MOVZ Wd, #imm16 (32-bit, no shift): [31:21]=01010010100.
    public static func isMOVZW(_ i: UInt32) -> Bool { (i & 0xFFE0_0000) == 0x5280_0000 }

    /// AND Wd, Wn, Wm — 32-bit shifted-register AND (imm6=0; shift type left free,
    /// harmless at shift amount 0): [31:24]=00001010, N=0.
    public static func isANDRegW(_ i: UInt32) -> Bool { (i & 0xFF20_FC00) == 0x0A00_0000 }

    /// LSR Wd, Wn, #7 ≡ UBFM Wd, Wn, #7, #31 (immr=7, imms=0x1F).
    public static func isLSRImm7W(_ i: UInt32) -> Bool { (i & 0xFFFF_FC00) == 0x5307_7C00 }

    /// BL — branch with link, [31:26]=100101.
    public static func isBL(_ i: UInt32) -> Bool { i >> 26 == 0b100101 }

    /// B.EQ — conditional branch, [31:24]=0x54, bit4=0, cond=0000.
    public static func isBEQ(_ i: UInt32) -> Bool { (i & 0xFF00_001F) == 0x5400_0000 }

    /// CBZ Wn (sf=0): top byte 0x34.
    public static func isCBZW(_ i: UInt32) -> Bool { (i & 0xFF00_0000) == 0x3400_0000 }
    /// CBNZ Wn (sf=0): top byte 0x35.
    public static func isCBNZW(_ i: UInt32) -> Bool { (i & 0xFF00_0000) == 0x3500_0000 }
    /// CBZ or CBNZ Wn.
    public static func isCBZorCBNZW(_ i: UInt32) -> Bool { isCBZW(i) || isCBNZW(i) }
    /// CBZ Xn (sf=1): top byte 0xB4.
    public static func isCBZX(_ i: UInt32) -> Bool { (i & 0xFF00_0000) == 0xB400_0000 }
}
