// ARM64EncoderTests.swift — every ARM64Encoder output asserted against keystone.
//
// The expected words below are keystone-engine's. They are frozen constants,
// not a live call: they were taken at repo commit `78cbeea` from the repo venv,
// one instruction at a time —
//
//   .venv/bin/python3 -c "from keystone import *; \
//     ks = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN); print(ks.asm('cset w0, eq')[0])"
//
// keystone is what the Python patchers called, so agreement with it is the
// migration's correctness bar: a disagreement is a bug in ARM64Encoder. Nothing
// in this file runs Python, so the bar survived `scripts/patchers/` leaving.
//
// `asmCallSiteCases` is not an arbitrary sample — it is the closed set of
// instructions the 19 patchers in scripts/patchers/ assembled at 78cbeea, one
// entry per `asm(...)` / `asm_at(...)` call site, each tagged with that site.
// `operandCoverageCases` then exercises the rest of each encoder's operand range
// (encoding-boundary immediates, backward branches, every shift amount), because
// the call sites alone leave most fields pinned at one value.

@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Case Model

/// One encoder output paired with the keystone encoding of the same instruction.
struct ARM64EncodingCase: Sendable, CustomStringConvertible {
    /// The assembly the Python patcher passed to keystone.
    let source: String
    /// keystone-engine's encoding of `source` (at `address`, where it matters).
    let keystone: UInt32
    /// What `ARM64Encoder` produced; nil means the encoder refused.
    let encoded: Data?
    /// The patcher call site this instruction comes from, or the field being covered.
    let origin: String

    var description: String {
        "\(source)  [\(origin)]"
    }
}

private func word(_ data: Data) -> UInt32 {
    let bytes = [UInt8](data)
    return UInt32(bytes[0])
        | UInt32(bytes[1]) << 8
        | UInt32(bytes[2]) << 16
        | UInt32(bytes[3]) << 24
}

// MARK: - Parity Against Keystone

struct ARM64EncoderKeystoneParityTests {
    // MARK: The instructions the patchers assemble

    /// Every distinct `asm(...)` / `asm_at(...)` instruction that was in
    /// scripts/patchers/ at 78cbeea, the last commit that carried it. The three
    /// fixed ones (`nop`, `ret`, `mov x0, #1`) live in ARM64Constants and are
    /// checked in `constantsMatchKeystone` below.
    ///
    /// `origin` names the patcher and the Python expression, not a line number.
    /// The set was derived with `grep -rnE '\basm(_at)?\(' scripts/patchers/`;
    /// that tree is gone, so re-derive from `git show 78cbeea:scripts/patchers`.
    static let asmCallSiteCases: [ARM64EncodingCase] = [
        // asm("mov w0, #0\nret") — force the camera check to return 0
        ARM64EncodingCase(
            source: "mov w0, #0", keystone: 0x5280_0000,
            encoded: ARM64Encoder.encodeMovzW(rd: 0, imm16: 0),
            origin: #"camera_dsc asm("mov w0, #0\nret")"#,
        ),
        // asm("mov w0, #3\nret")
        ARM64EncodingCase(
            source: "mov w0, #3", keystone: 0x5280_0060,
            encoded: ARM64Encoder.encodeMovzW(rd: 0, imm16: 3),
            origin: #"camera_dsc asm("mov w0, #3\nret")"#,
        ),
        // asm_at(f"b #{kern_va}", pub_va) — redirect the public stub at its own address
        ARM64EncodingCase(
            source: "b #0x1010 @0x1000", keystone: 0x1400_0004,
            encoded: ARM64Encoder.encodeB(from: 0x1000, to: 0x1010),
            origin: #"iomfb_force_kern asm_at("b #{kern_va}", pub_va)"#,
        ),
        // asm_at(f"b #0x{patch_target:X}", patch_off) — the same shape, backwards
        ARM64EncodingCase(
            source: "b #0x1000 @0x2000", keystone: 0x17FF_FC00,
            encoded: ARM64Encoder.encodeB(from: 0x2000, to: 0x1000),
            origin: #"jetsam asm_at("b #{patch_target}", patch_off)"#,
        ),
        // asm(f"mov w3, #{target_size}"), where TARGET_SIZE == 0x588
        ARM64EncodingCase(
            source: "mov w3, #0x588", keystone: 0x5280_B103,
            encoded: ARM64Encoder.encodeMovzW(rd: 3, imm16: 0x588),
            origin: #"iomfb_swapend asm("mov w3, #{target_size}")"#,
        ),
        // The next seven build the SwapEnd call-setup sequence in _self_test().
        ARM64EncodingCase(
            source: "ldr w0, [x0, #0x14]", keystone: 0xB940_1400,
            encoded: ARM64Encoder.encodeLdrWUnsignedOffset(rt: 0, rn: 0, offset: 0x14),
            origin: #"iomfb_swapend asm("ldr w0, [x0, #0x14]")"#,
        ),
        ARM64EncodingCase(
            source: "add x2, x19, #0x18", keystone: 0x9100_6262,
            encoded: ARM64Encoder.encodeAddImm12(rd: 2, rn: 19, imm12: 0x18),
            origin: #"iomfb_swapend asm("add x2, x19, #0x18")"#,
        ),
        ARM64EncodingCase(
            source: "mov w1, #5", keystone: 0x5280_00A1,
            encoded: ARM64Encoder.encodeMovzW(rd: 1, imm16: 5),
            origin: #"iomfb_swapend asm("mov w1, #5")"#,
        ),
        ARM64EncodingCase(
            source: "mov w3, #0x548", keystone: 0x5280_A903,
            encoded: ARM64Encoder.encodeMovzW(rd: 3, imm16: 0x548),
            origin: #"iomfb_swapend asm("mov w3, #0x548")"#,
        ),
        ARM64EncodingCase(
            source: "mov x4, #0", keystone: 0xD280_0004,
            encoded: ARM64Encoder.encodeMovzX(rd: 4, imm16: 0),
            origin: #"iomfb_swapend asm("mov x4, #0")"#,
        ),
        ARM64EncodingCase(
            source: "mov x5, #0", keystone: 0xD280_0005,
            encoded: ARM64Encoder.encodeMovzX(rd: 5, imm16: 0),
            origin: #"iomfb_swapend asm("mov x5, #0")"#,
        ),
        // asm("bl #0x40") — plain asm(), so keystone assembles it at address 0.
        ARM64EncodingCase(
            source: "bl #0x40 @0x0", keystone: 0x9400_0010,
            encoded: ARM64Encoder.encodeBL(from: 0, to: 0x40),
            origin: #"iomfb_swapend asm("bl #0x40")"#,
        ),
        // asm(f"mov {m['cset_reg']}, #1") — cset_reg is always a W register; the
        // matcher rejects any destination that does not start with "w".
        ARM64EncodingCase(
            source: "mov w8, #1", keystone: 0x5280_0028,
            encoded: ARM64Encoder.encodeMovzW(rd: 8, imm16: 1),
            origin: #"watchdogd asm("mov {cset_reg}, #1")"#,
        ),
        // asm("cset w0, eq") — the one instruction with no encoder before this change
        ARM64EncodingCase(
            source: "cset w0, eq", keystone: 0x1A9F_17E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .eq),
            origin: #"xpc_lwcr asm("cset w0, eq")"#,
        ),
    ]

    // MARK: The rest of each encoder's operand range

    static let operandCoverageCases: [ARM64EncodingCase] = [
        // --- encodeB: both signs, and both ends of the imm26 range -------
        ARM64EncodingCase(
            source: "b #0x7FFFFFC @0x0", keystone: 0x15FF_FFFF,
            encoded: ARM64Encoder.encodeB(from: 0, to: 0x7FFFFFC),
            origin: "B max forward",
        ),
        ARM64EncodingCase(
            source: "b #0x0 @0x8000000", keystone: 0x1600_0000,
            encoded: ARM64Encoder.encodeB(from: 0x8000000, to: 0),
            origin: "B max backward",
        ),
        // --- encodeBL ----------------------------------------------------
        ARM64EncodingCase(
            source: "bl #0x1100 @0x1000", keystone: 0x9400_0040,
            encoded: ARM64Encoder.encodeBL(from: 0x1000, to: 0x1100),
            origin: "BL forward",
        ),
        ARM64EncodingCase(
            source: "bl #0x2000 @0x3000", keystone: 0x97FF_FC00,
            encoded: ARM64Encoder.encodeBL(from: 0x3000, to: 0x2000),
            origin: "BL backward",
        ),
        // --- encodeTestBitBranch: b5 both ways, TBZ and TBNZ, both signs --
        ARM64EncodingCase(
            source: "tbz w8, #0xb, #0x14", keystone: 0x3658_00A8,
            encoded: ARM64Encoder.encodeTestBitBranch(
                nonzero: false, register: 8, bit: 11, from: 0, to: 0x14,
            ),
            origin: "TBZ W, bit<32",
        ),
        ARM64EncodingCase(
            source: "tbz w8, #0xa, #0x14", keystone: 0x3650_00A8,
            encoded: ARM64Encoder.encodeTestBitBranch(
                nonzero: false, register: 8, bit: 10, from: 0, to: 0x14,
            ),
            origin: "TBZ W, bit<32",
        ),
        ARM64EncodingCase(
            source: "tbnz w0, #0, #0x8", keystone: 0x3700_0040,
            encoded: ARM64Encoder.encodeTestBitBranch(
                nonzero: true, register: 0, bit: 0, from: 0, to: 8,
            ),
            origin: "TBNZ bit 0",
        ),
        ARM64EncodingCase(
            source: "tbz x9, #32, #0x40", keystone: 0xB600_0209,
            encoded: ARM64Encoder.encodeTestBitBranch(
                nonzero: false, register: 9, bit: 32, from: 0, to: 0x40,
            ),
            origin: "TBZ X, b5 set",
        ),
        ARM64EncodingCase(
            source: "tbnz x3, #63, #0x0 @0x100", keystone: 0xB7FF_F803,
            encoded: ARM64Encoder.encodeTestBitBranch(
                nonzero: true, register: 3, bit: 63, from: 0x100, to: 0,
            ),
            origin: "TBNZ bit 63, backward",
        ),
        // --- encodeADRP: forward, backward, and same page ----------------
        ARM64EncodingCase(
            source: "adrp x2, #0x5000 @0x1000", keystone: 0x9000_0022,
            encoded: ARM64Encoder.encodeADRP(rd: 2, pc: 0x1000, target: 0x5000),
            origin: "ADRP forward",
        ),
        ARM64EncodingCase(
            source: "adrp x0, #0x1000 @0x9000", keystone: 0x90FF_FFC0,
            encoded: ARM64Encoder.encodeADRP(rd: 0, pc: 0x9000, target: 0x1000),
            origin: "ADRP backward",
        ),
        ARM64EncodingCase(
            source: "adrp x17, #0x1000 @0x1FFF", keystone: 0x9000_0011,
            encoded: ARM64Encoder.encodeADRP(rd: 17, pc: 0x1FFF, target: 0x1000),
            origin: "ADRP same page, unaligned PC",
        ),
        // --- encodeAddImm12 ----------------------------------------------
        ARM64EncodingCase(
            source: "add x2, x2, #0xabc", keystone: 0x912A_F042,
            encoded: ARM64Encoder.encodeAddImm12(rd: 2, rn: 2, imm12: 0xABC),
            origin: "ADD imm12",
        ),
        ARM64EncodingCase(
            source: "add x0, x0, #0", keystone: 0x9100_0000,
            encoded: ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0),
            origin: "ADD imm12 = 0",
        ),
        // --- encodeMovzW / encodeMovzX: every legal hw --------------------
        ARM64EncodingCase(
            source: "movz w5, #0x1234, lsl #16", keystone: 0x52A2_4685,
            encoded: ARM64Encoder.encodeMovzW(rd: 5, imm16: 0x1234, shift: 16),
            origin: "MOVZ W hw=1",
        ),
        ARM64EncodingCase(
            source: "movz x3, #0x4000", keystone: 0xD288_0003,
            encoded: ARM64Encoder.encodeMovzX(rd: 3, imm16: 0x4000, shift: 0),
            origin: "MOVZ X hw=0",
        ),
        ARM64EncodingCase(
            source: "movz x9, #0xbeef, lsl #32", keystone: 0xD2D7_DDE9,
            encoded: ARM64Encoder.encodeMovzX(rd: 9, imm16: 0xBEEF, shift: 32),
            origin: "MOVZ X hw=2",
        ),
        ARM64EncodingCase(
            source: "movz x1, #0xdead, lsl #48", keystone: 0xD2FB_D5A1,
            encoded: ARM64Encoder.encodeMovzX(rd: 1, imm16: 0xDEAD, shift: 48),
            origin: "MOVZ X hw=3",
        ),
        // --- encodeMovX ---------------------------------------------------
        ARM64EncodingCase(
            source: "mov x0, x20", keystone: 0xAA14_03E0,
            encoded: ARM64Encoder.encodeMovX(rd: 0, rm: 20),
            origin: "MOV X reg",
        ),
        ARM64EncodingCase(
            source: "mov x9, xzr", keystone: 0xAA1F_03E9,
            encoded: ARM64Encoder.encodeMovX(rd: 9, rm: 31),
            origin: "MOV X from XZR",
        ),
        ARM64EncodingCase(
            source: "mov x30, x1", keystone: 0xAA01_03FE,
            encoded: ARM64Encoder.encodeMovX(rd: 30, rm: 1),
            origin: "MOV X high Rd",
        ),
        // --- encodeCsetW: all 14 conditions, plus other destinations ------
        ARM64EncodingCase(
            source: "cset w0, ne", keystone: 0x1A9F_07E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .ne), origin: "CSET ne",
        ),
        ARM64EncodingCase(
            source: "cset w0, hs", keystone: 0x1A9F_37E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .hs), origin: "CSET hs",
        ),
        ARM64EncodingCase(
            source: "cset w0, lo", keystone: 0x1A9F_27E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .lo), origin: "CSET lo",
        ),
        ARM64EncodingCase(
            source: "cset w0, mi", keystone: 0x1A9F_57E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .mi), origin: "CSET mi",
        ),
        ARM64EncodingCase(
            source: "cset w0, pl", keystone: 0x1A9F_47E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .pl), origin: "CSET pl",
        ),
        ARM64EncodingCase(
            source: "cset w0, vs", keystone: 0x1A9F_77E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .vs), origin: "CSET vs",
        ),
        ARM64EncodingCase(
            source: "cset w0, vc", keystone: 0x1A9F_67E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .vc), origin: "CSET vc",
        ),
        ARM64EncodingCase(
            source: "cset w0, hi", keystone: 0x1A9F_97E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .hi), origin: "CSET hi",
        ),
        ARM64EncodingCase(
            source: "cset w0, ls", keystone: 0x1A9F_87E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .ls), origin: "CSET ls",
        ),
        ARM64EncodingCase(
            source: "cset w0, ge", keystone: 0x1A9F_B7E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .ge), origin: "CSET ge",
        ),
        ARM64EncodingCase(
            source: "cset w0, lt", keystone: 0x1A9F_A7E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .lt), origin: "CSET lt",
        ),
        ARM64EncodingCase(
            source: "cset w0, gt", keystone: 0x1A9F_D7E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .gt), origin: "CSET gt",
        ),
        ARM64EncodingCase(
            source: "cset w0, le", keystone: 0x1A9F_C7E0,
            encoded: ARM64Encoder.encodeCsetW(rd: 0, condition: .le), origin: "CSET le",
        ),
        ARM64EncodingCase(
            source: "cset w8, ne", keystone: 0x1A9F_07E8,
            encoded: ARM64Encoder.encodeCsetW(rd: 8, condition: .ne), origin: "CSET Rd=8",
        ),
        ARM64EncodingCase(
            source: "cset w19, eq", keystone: 0x1A9F_17F3,
            encoded: ARM64Encoder.encodeCsetW(rd: 19, condition: .eq), origin: "CSET Rd=19",
        ),
        // --- encodeLdrWUnsignedOffset: zero, SP base, both imm12 ends -----
        ARM64EncodingCase(
            source: "ldr w7, [x19]", keystone: 0xB940_0267,
            encoded: ARM64Encoder.encodeLdrWUnsignedOffset(rt: 7, rn: 19, offset: 0),
            origin: "LDR W offset 0",
        ),
        ARM64EncodingCase(
            source: "ldr w8, [sp, #0xcc]", keystone: 0xB940_CFE8,
            encoded: ARM64Encoder.encodeLdrWUnsignedOffset(rt: 8, rn: 31, offset: 0xCC),
            origin: "LDR W base = SP",
        ),
        ARM64EncodingCase(
            source: "ldr w8, [x0, #0x454]", keystone: 0xB944_5408,
            encoded: ARM64Encoder.encodeLdrWUnsignedOffset(rt: 8, rn: 0, offset: 0x454),
            origin: "LDR W mid offset",
        ),
        ARM64EncodingCase(
            source: "ldr w30, [x29, #0x3ffc]", keystone: 0xB97F_FFBE,
            encoded: ARM64Encoder.encodeLdrWUnsignedOffset(rt: 30, rn: 29, offset: 0x3FFC),
            origin: "LDR W max imm12",
        ),
    ]

    static let allCases: [ARM64EncodingCase] = asmCallSiteCases + operandCoverageCases

    // MARK: Parity

    @Test(arguments: ARM64EncoderKeystoneParityTests.allCases)
    func `matches keystone`(_ testCase: ARM64EncodingCase) throws {
        let data = try #require(testCase.encoded, "encoder refused \(testCase.source)")
        #expect(data.count == 4, "\(testCase.source): expected 4 bytes, got \(data.count)")
        let produced = word(data)
        #expect(
            produced == testCase.keystone,
            """
            \(testCase.source) [\(testCase.origin)]
              ARM64Encoder: 0x\(String(produced, radix: 16, uppercase: true))
              keystone:     0x\(String(testCase.keystone, radix: 16, uppercase: true))
            """,
        )
    }

    /// Every `asm(...)` site the patchers had is represented, and each one
    /// disassembles back to the mnemonic the Python source named.
    @Test(arguments: ARM64EncoderKeystoneParityTests.allCases)
    func `round trips through capstone`(_ testCase: ARM64EncodingCase) throws {
        let data = try #require(testCase.encoded)
        let disasm = ARM64Disassembler()
        // Address 0 is fine: only the mnemonic is asserted, and the keystone parity
        // test above already pins the PC-relative operand bits exactly.
        let insn = try #require(
            disasm.disassembleOne(data, at: 0),
            "capstone could not decode \(testCase.source)",
        )
        let expectedMnemonic = String(testCase.source.prefix(while: { $0 != " " }))
        // A MOVZ with any `hw` is expressible as MOV (wide immediate), and capstone
        // always prints that alias — the keystone source spells it either way.
        let accepted: Set<String> = expectedMnemonic == "movz"
            ? ["movz", "mov"]
            : [expectedMnemonic]
        #expect(
            accepted.contains(insn.mnemonic),
            "\(testCase.source): capstone read it as '\(insn.mnemonic) \(insn.operandString)'",
        )
    }

    // MARK: Fixed constants used at asm() sites

    /// `nop`, `ret` and `mov x0, #1` are `asm()` results in cfw_asm.py (NOP / RET /
    /// MOV_X0_1) and ship as constants rather than encoder calls. The rest of the
    /// public table is checked alongside them, since keystone was available.
    ///
    /// `retaa`, `retab` and `pacibsp` are absent: this keystone build rejects those
    /// mnemonics (KS_ERR_ASM_MNEMONICFAIL). `pacibsp` is checked through its `hint
    /// #27` spelling, which keystone does accept; retaa/retab stay on the capstone
    /// round-trip in ARM64ConstantTests.
    @Test func `constants match keystone`() {
        let expected: [(String, Data, UInt32)] = [
            ("nop", ARM64.nop, 0xD503_201F),
            ("ret", ARM64.ret, 0xD65F_03C0),
            ("pacibsp (hint #27)", ARM64.pacibsp, 0xD503_237F),
            ("movz x0, #0", ARM64.movX0_0, 0xD280_0000),
            ("movz x0, #1", ARM64.movX0_1, 0xD280_0020),
            ("movz w0, #0", ARM64.movW0_0, 0x5280_0000),
            ("movz w0, #1", ARM64.movW0_1, 0x5280_0020),
            ("mov x0, x20", ARM64.movX0X20, 0xAA14_03E0),
            ("movz w0, #0xa1", ARM64.movW0_0xA1, 0x5280_1420),
            ("cmp w0, w0", ARM64.cmpW0W0, 0x6B00_001F),
            ("cmp x0, x0", ARM64.cmpX0X0, 0xEB00_001F),
            ("strb w0, [x20, #0x30]", ARM64.strbW0X20_30, 0x3900_C280),
            ("cbz x2, #8", ARM64.cbzX2_8, 0xB400_0042),
            ("str x0, [x2]", ARM64.strX0X2, 0xF900_0040),
            ("cmp xzr, xzr", ARM64.cmpXzrXzr, 0xEB1F_03FF),
        ]
        for (source, data, keystone) in expected {
            let produced = String(word(data), radix: 16, uppercase: true)
            let reference = String(keystone, radix: 16, uppercase: true)
            #expect(word(data) == keystone, "\(source): constant 0x\(produced) != keystone 0x\(reference)")
        }
    }

    /// The three constants that stand in for `asm()` results are byte-identical to
    /// the encoder path, so a patcher may use either without a behaviour change.
    @Test func `constants agree with encoders`() {
        #expect(ARM64.movX0_1 == ARM64Encoder.encodeMovzX(rd: 0, imm16: 1))
        #expect(ARM64.movX0_0 == ARM64Encoder.encodeMovzX(rd: 0, imm16: 0))
        #expect(ARM64.movW0_0 == ARM64Encoder.encodeMovzW(rd: 0, imm16: 0))
        #expect(ARM64.movW0_1 == ARM64Encoder.encodeMovzW(rd: 0, imm16: 1))
        #expect(ARM64.movX0X20 == ARM64Encoder.encodeMovX(rd: 0, rm: 20))
    }
}

// MARK: - Range And Refusal

struct ARM64EncoderRangeTests {
    // MARK: Branches

    @Test func `branch refuses unaligned and out of range`() {
        #expect(ARM64Encoder.encodeB(from: 0, to: 2) == nil, "unaligned target")
        #expect(ARM64Encoder.encodeB(from: 0, to: 0x8000000) == nil, "one past +128 MB")
        #expect(ARM64Encoder.encodeB(from: 0x8000004, to: 0) == nil, "one past -128 MB")
        #expect(ARM64Encoder.encodeBL(from: 0, to: 1) == nil, "unaligned target")
        #expect(ARM64Encoder.encodeBL(from: 0, to: 0x8000000) == nil, "one past +128 MB")
    }

    @Test func `bit branch refuses bad operands`() {
        #expect(
            ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 32, bit: 0, from: 0, to: 4) == nil,
            "register out of range",
        )
        #expect(
            ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 0, bit: 64, from: 0, to: 4) == nil,
            "bit out of range",
        )
        #expect(
            ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 0, bit: 0, from: 0, to: 0x8000) == nil,
            "one past +32 KB",
        )
    }

    // MARK: ADRP / ADD / MOVZ

    @Test func `adrp and add refuse out of range`() {
        // ADRP reaches +/-4 GB; one page past that must be refused.
        #expect(ARM64Encoder.encodeADRP(rd: 0, pc: 0, target: 1 << 32) == nil)
        #expect(ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 4096) == nil)
    }

    @Test func `movz refuses unrepresentable shift`() {
        #expect(ARM64Encoder.encodeMovzW(rd: 0, imm16: 1, shift: 32) == nil, "W has hw 0..1")
        #expect(ARM64Encoder.encodeMovzX(rd: 0, imm16: 1, shift: 64) == nil, "X has hw 0..3")
    }

    // MARK: CSET

    @Test func `cset refuses invalid register`() {
        #expect(ARM64Encoder.encodeCsetW(rd: 32, condition: .eq) == nil)
    }

    /// CSET encodes the inverse of the written condition, so inverting twice has to
    /// be the identity — otherwise the alias silently means the opposite thing.
    @Test func `condition inversion is an involution`() {
        for condition in ARM64Condition.allCases {
            #expect(condition.inverted.inverted == condition, "\(condition) inverted twice")
            #expect(condition.inverted != condition, "\(condition) is its own inverse")
            #expect(condition.inverted.rawValue == condition.rawValue ^ 1)
        }
    }

    // MARK: LDR

    @Test func `ldr refuses unscalable offsets`() {
        #expect(
            ARM64Encoder.encodeLdrWUnsignedOffset(rt: 0, rn: 0, offset: 0x13) == nil,
            "offset must be a multiple of 4",
        )
        #expect(
            ARM64Encoder.encodeLdrWUnsignedOffset(rt: 0, rn: 0, offset: 0x4000) == nil,
            "one past the scaled imm12 range",
        )
        #expect(ARM64Encoder.encodeLdrWUnsignedOffset(rt: 32, rn: 0, offset: 0) == nil)
        #expect(ARM64Encoder.encodeLdrWUnsignedOffset(rt: 0, rn: 32, offset: 0) == nil)
    }

    // MARK: Decode

    /// `decodeBranchTarget` is the inverse of `encodeB` / `encodeBL`; the two must
    /// agree, because the patchers use the decoder to find the site they then
    /// re-encode.
    @Test func `decode branch target inverts encode`() throws {
        let sites: [(UInt64, UInt64)] = [
            (0x1000, 0x1010), (0x2000, 0x1000), (0, 0x40), (0x8000000, 0),
        ]
        for (pc, target) in sites {
            let branch = try #require(ARM64Encoder.encodeB(from: Int(pc), to: Int(target)))
            let link = try #require(ARM64Encoder.encodeBL(from: Int(pc), to: Int(target)))
            for data in [branch, link] {
                let bytes = [UInt8](data)
                let insn = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                    | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                #expect(ARM64Encoder.decodeBranchTarget(insn: insn, pc: pc) == target)
            }
        }
    }

    @Test func `decode branch target rejects non branches`() {
        #expect(ARM64Encoder.decodeBranchTarget(insn: ARM64.nopU32, pc: 0) == nil)
        #expect(ARM64Encoder.decodeBranchTarget(insn: ARM64.retU32, pc: 0) == nil)
    }
}
