// FirmwarePatcherTests.swift — Tests for ARM64 constants, encoders, and round-trip verification.

@testable import FirmwarePatcher
import Foundation
import Img4tool
import Testing
import VPhoneCoreKit
import VPhonePatchKit

struct ARM64ConstantTests {
    let disasm = ARM64Disassembler()

    func verifyConstant(_ data: Data, expectedMnemonic: String, file _: String = #file, line _: Int = #line) {
        let insn = disasm.disassembleOne(data, at: 0)
        #expect(insn != nil, "Failed to disassemble constant")
        #expect(insn?.mnemonic == expectedMnemonic,
                "Expected \(expectedMnemonic), got \(insn?.mnemonic ?? "nil")")
    }

    @Test func nop() {
        verifyConstant(ARM64.nop, expectedMnemonic: "nop")
    }

    @Test func ret() {
        verifyConstant(ARM64.ret, expectedMnemonic: "ret")
    }

    @Test func retaa() {
        verifyConstant(ARM64.retaa, expectedMnemonic: "retaa")
    }

    @Test func retab() {
        verifyConstant(ARM64.retab, expectedMnemonic: "retab")
    }

    @Test func pacibsp() {
        // PACIBSP is encoded as HINT #27, capstone may show it as "pacibsp" or "hint"
        let insn = disasm.disassembleOne(ARM64.pacibsp, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "pacibsp" || insn?.mnemonic == "hint")
    }

    @Test func `mov X 0 0`() {
        let insn = disasm.disassembleOne(ARM64.movX0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func `mov X 0 1`() {
        let insn = disasm.disassembleOne(ARM64.movX0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func `mov W 0 0`() {
        let insn = disasm.disassembleOne(ARM64.movW0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func `mov W 0 1`() {
        let insn = disasm.disassembleOne(ARM64.movW0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func `cmp W 0 W 0`() {
        verifyConstant(ARM64.cmpW0W0, expectedMnemonic: "cmp")
    }

    @Test func `cmp X 0 X 0`() {
        verifyConstant(ARM64.cmpX0X0, expectedMnemonic: "cmp")
    }

    @Test func `mov X 0 X 20`() {
        let insn = disasm.disassembleOne(ARM64.movX0X20, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "orr")
    }

    @Test func `strb W 0 X 20 30`() {
        verifyConstant(ARM64.strbW0X20_30, expectedMnemonic: "strb")
    }

    @Test func `mov W 0 0 x A 1`() {
        let insn = disasm.disassembleOne(ARM64.movW0_0xA1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }
}

struct ARM64EncoderTests {
    let disasm = ARM64Disassembler()

    @Test func `encode B forward`() throws {
        // B from 0x1000 to 0x2000 (forward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func `encode B backward`() throws {
        // B from 0x2000 to 0x1000 (backward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x2000, to: 0x1000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x2000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func `encode BL forward`() throws {
        let data = ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "bl")
    }

    @Test func `decode branch target`() throws {
        // Encode a B, then decode and verify the target matches
        let from: UInt64 = 0x10000
        let to: UInt64 = 0x20000
        let data = try #require(ARM64Encoder.encodeB(from: Int(from), to: Int(to)))
        let insn: UInt32 = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let decoded = ARM64Encoder.decodeBranchTarget(insn: insn, pc: from)
        #expect(decoded == to)
    }

    @Test func `encode B out of range`() {
        // Try to encode a branch that's too far (> 128MB)
        let data = ARM64Encoder.encodeB(from: 0, to: 0x1000_0000)
        #expect(data == nil)
    }

    @Test func `encode ADRP`() throws {
        let data = ARM64Encoder.encodeADRP(rd: 0, pc: 0x1000, target: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "adrp")
    }

    @Test func `encode add imm 12`() throws {
        let data = ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0x100)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0)
        #expect(insn?.mnemonic == "add")
    }

    @Test func `encode mov X from ZR`() {
        // `mov x8, xzr` — the mac_mount state-clear encoding (ORR X8, XZR, XZR).
        let bytes = ARM64Encoder.encodeMovX(rd: 8, rm: 31)
        let insn = disasm.disassembleOne(bytes, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "orr")
        // Byte-for-byte equal to the legacy hand-encoded constant 0xAA1F03E8.
        #expect(bytes == withUnsafeBytes(of: UInt32(0xAA1F_03E8).littleEndian) { Data($0) })
    }

    @Test func `encode mov X is register move`() {
        // `mov x0, x20` matches the project's preverified ARM64.movX0X20 constant.
        #expect(ARM64Encoder.encodeMovX(rd: 0, rm: 20) == ARM64.movX0X20)
    }

    @Test func `encode test bit branch round trips`() throws {
        // The vm_map_delete --frida patch retargets `tbz/tbnz w8,#9` to bit 13
        // (current-protection.X → max_protection.X), preserving sense and target.
        let tbz = try #require(ARM64Encoder.encodeTestBitBranch(
            nonzero: false,
            register: 8,
            bit: 13,
            from: 0x1000,
            to: 0x1020,
        ))
        let tbzI = try #require(disasm.disassembleOne(tbz, at: 0x1000))
        #expect(tbzI.mnemonic == "tbz")
        #expect(tbzI.operandString.contains("w8"))
        #expect(tbzI.operandString.contains("#0xd"))
        #expect(tbzI.operandString.contains("0x1020"))

        let tbnz = try #require(ARM64Encoder.encodeTestBitBranch(
            nonzero: true,
            register: 8,
            bit: 13,
            from: 0x2000,
            to: 0x1F00,
        ))
        let tbnzI = try #require(disasm.disassembleOne(tbnz, at: 0x2000))
        #expect(tbnzI.mnemonic == "tbnz")
        #expect(tbnzI.operandString.contains("#0xd"))
        #expect(tbnzI.operandString.contains("0x1f00"))

        // Rejects bad register / bit / out-of-range target.
        #expect(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 32, bit: 13, from: 0, to: 4) == nil)
        #expect(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 64, from: 0, to: 4) == nil)
        #expect(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 13, from: 0, to: 0x8000) == nil)
    }

    @Test func `encode movz W clears TSSF check entitlement`() throws {
        // The thread_set_state --frida patch rewrites `mov w6, #0x201`
        // (TSSF_TRANSLATE_TO_USER | TSSF_CHECK_ENTITLEMENT) to `mov w6, #0x1`,
        // clearing only the entitlement bit while preserving user translation.
        let bytes = try #require(ARM64Encoder.encodeMovzW(rd: 6, imm16: 0x1))
        let insn = try #require(disasm.disassembleOne(bytes, at: 0))
        #expect(insn.mnemonic == "mov" || insn.mnemonic == "movz")
        #expect(insn.operandString.contains("w6"))
        #expect(insn.operandString.contains("#1") || insn.operandString.contains("#0x1"))
    }
}

/// Round-trip coverage for the shared raw-instruction predicates in `ARM64Inst`,
/// the single source of truth for the JB pattern scanners. Each predicate is
/// cross-checked against Capstone's decode of the same word so the masks cannot
/// silently drift from the ISA.
struct ARM64InstTests {
    let disasm = ARM64Disassembler()

    private func mnemonic(of word: UInt32) -> String? {
        let data = withUnsafeBytes(of: word.littleEndian) { Data($0) }
        return disasm.disassembleOne(data, at: 0)?.mnemonic
    }

    @Test func `field accessors`() {
        // ldr x1, [x0, #0x3e0]  → Rt=1, Rn=0
        let ldr: UInt32 = 0xF941_F001
        #expect(ARM64Inst.rd(ldr) == 1)
        #expect(ARM64Inst.rn(ldr) == 0)
        // cmp x0, x1 (SUBS XZR, X0, X1) → Rn=0, Rm=1
        let cmp: UInt32 = 0xEB01_001F
        #expect(ARM64Inst.rn(cmp) == 0)
        #expect(ARM64Inst.rm(cmp) == 1)
        // movz w0, #0x16 → imm16=0x16
        let movz: UInt32 = 0x5280_02C0
        #expect(ARM64Inst.movImm16(movz) == 0x16)
        // sub w2, w3, #1 → imm12=1
        let sub: UInt32 = 0x5100_0462
        #expect(ARM64Inst.addSubImm12(sub) == 1)
    }

    @Test func adrp() {
        let w: UInt32 = 0x9000_0000 // adrp x0, ...
        #expect(mnemonic(of: w) == "adrp")
        #expect(ARM64Inst.isADRP(w))
        #expect(!ARM64Inst.isADRP(0xF941_F001)) // an ldr is not adrp
    }

    @Test func `ldr imm 64`() {
        let w: UInt32 = 0xF941_F001 // ldr x1, [x0, #0x3e0]
        #expect(mnemonic(of: w) == "ldr")
        #expect(ARM64Inst.isLDRImm64(w))
        #expect(!ARM64Inst.isLDRImm64(0x9000_0000))
    }

    @Test func `cmp reg 64`() {
        let w: UInt32 = 0xEB01_001F // cmp x0, x1
        #expect(mnemonic(of: w) == "cmp")
        #expect(ARM64Inst.isCMPReg64(w))
        // operand order is irrelevant: cmp x1, x0
        #expect(ARM64Inst.isCMPReg64(0xEB00_003F))
        #expect(!ARM64Inst.isCMPReg64(0x5100_0462)) // sub-imm is not cmp-reg
    }

    @Test func `sub imm 32`() {
        let w: UInt32 = 0x5100_0462 // sub w2, w3, #1
        #expect(mnemonic(of: w) == "sub")
        #expect(ARM64Inst.isSUBImm32(w))
        #expect(!ARM64Inst.isSUBImm32(0x5280_02C0)) // movz is not sub
    }

    @Test func `movz W`() {
        let w: UInt32 = 0x5280_02C0 // movz w0, #0x16
        let m = mnemonic(of: w)
        #expect(m == "mov" || m == "movz")
        #expect(ARM64Inst.isMOVZW(w))
        #expect(ARM64Inst.rd(w) == 0)
        #expect(!ARM64Inst.isMOVZW(0xF941_F001))
    }

    /// The prefilter in front of the vm_map_protect Shape C scan accepts both ways
    /// an assembler can spell `mov wD, #imm`, so it cannot narrow what Capstone is
    /// then asked to confirm. This pins both encodings and records which mnemonic
    /// the printer gives each: for a MOVZ-encodable value like #6 the ORR form
    /// prints as `orr`, because the MOV-bitmask alias applies only when MOVZ cannot
    /// hold the immediate. The scan does not rely on that — it lets the ORR form
    /// through either way — but if the printer ever changed its mind, this is where
    /// it shows up.
    @Test func `orr immediate W is the other mov immediate encoding`() {
        // `mov w9, #6` and `movz w9, #6` both assemble to this (clang, arm64).
        let movz: UInt32 = 0x5280_00C9
        #expect(mnemonic(of: movz) == "mov" || mnemonic(of: movz) == "movz")
        #expect(ARM64Inst.isMOVZW(movz))
        #expect(ARM64Inst.movImm16(movz) == 6)
        #expect(ARM64Inst.rd(movz) == 9)
        #expect(!ARM64Inst.isORRImmW(movz))

        // `orr w9, wzr, #6` — same value, logical-immediate encoding.
        let orr6: UInt32 = 0x321F_07E9
        #expect(ARM64Inst.isORRImmW(orr6))
        #expect(ARM64Inst.rn(orr6) == 31) // wzr
        #expect(ARM64Inst.rd(orr6) == 9)
        #expect(!ARM64Inst.isMOVZW(orr6))
        #expect(mnemonic(of: orr6) == "orr")

        // `orr w9, wzr, #7` — a different element size behind the same mask.
        let orr7: UInt32 = 0x3200_0BE9
        #expect(ARM64Inst.isORRImmW(orr7))
        #expect(ARM64Inst.rn(orr7) == 31)

        // Neither a register-form AND nor a branch is an ORR-immediate.
        #expect(!ARM64Inst.isORRImmW(0x0A05_0083))
        #expect(!ARM64Inst.isORRImmW(0x1400_0000))
    }

    @Test func `and reg W`() {
        let w: UInt32 = 0x0A05_0083 // and w3, w4, w5
        #expect(mnemonic(of: w) == "and")
        #expect(ARM64Inst.isANDRegW(w))
        #expect(!ARM64Inst.isANDRegW(0x5280_02C0))
    }

    @Test func `lsr imm 7 W`() {
        let w: UInt32 = 0x5307_7C20 // lsr w0, w1, #7
        let m = mnemonic(of: w)
        #expect(m == "lsr" || m == "ubfm")
        #expect(ARM64Inst.isLSRImm7W(w))
        #expect(!ARM64Inst.isLSRImm7W(0x0A05_0083))
    }

    @Test func `branch predicates`() throws {
        let bl = try #require(ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)?
            .withUnsafeBytes { $0.load(as: UInt32.self) })
        #expect(ARM64Inst.isBL(bl))
        // b.eq vs b.ne (cond field)
        #expect(ARM64Inst.isBEQ(0x5400_0020)) // b.eq #4
        #expect(!ARM64Inst.isBEQ(0x5400_0021)) // b.ne #4
    }

    /// `isBorBL` gates the thread_set_state scan, which then checks the decoded
    /// mnemonic for exactly `b` or `bl`. It has to accept both and nothing else, or
    /// the scan quietly loses sites.
    @Test func `b or bl`() throws {
        let b = try #require(ARM64Encoder.encodeB(from: 0x1000, to: 0x2000)?
            .withUnsafeBytes { $0.load(as: UInt32.self) })
        let bl = try #require(ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)?
            .withUnsafeBytes { $0.load(as: UInt32.self) })
        #expect(mnemonic(of: b) == "b")
        #expect(mnemonic(of: bl) == "bl")
        #expect(ARM64Inst.isBorBL(b))
        #expect(ARM64Inst.isBorBL(bl))
        // Backward branches set the sign bits of imm26; the mask must ignore them.
        let back = try #require(ARM64Encoder.encodeB(from: 0x2000, to: 0x1000)?
            .withUnsafeBytes { $0.load(as: UInt32.self) })
        #expect(ARM64Inst.isBorBL(back))
        // A conditional branch, a cbz and a movz are not unconditional branches.
        #expect(!ARM64Inst.isBorBL(0x5400_0020)) // b.eq #4
        #expect(!ARM64Inst.isBorBL(0x3400_0020)) // cbz w0, #4
        #expect(!ARM64Inst.isBorBL(0x5280_02C0)) // movz w0, #0x16
    }

    @Test func `compare and branch`() {
        #expect(ARM64Inst.isCBZW(0x3400_0020)) // cbz w0, #4
        #expect(!ARM64Inst.isCBZW(0x3500_0020)) // that is cbnz
        #expect(ARM64Inst.isCBNZW(0x3500_0020))
        #expect(ARM64Inst.isCBZorCBNZW(0x3400_0020))
        #expect(ARM64Inst.isCBZorCBNZW(0x3500_0020))
        #expect(ARM64Inst.isCBZX(0xB400_0020)) // cbz x0, #4 (64-bit)
        #expect(!ARM64Inst.isCBZX(0x3400_0020)) // 32-bit cbz is not the X form
    }
}

struct BinaryBufferTests {
    @Test func `loads little endian values from sliced data`() {
        let source = Data([0xFF, 0x78, 0x56, 0x34, 0x12, 0xEE])
        let slice = source[1 ..< 5]
        #expect(slice.startIndex == 1)
        #expect(slice.loadLE(UInt32.self, at: 0) == 0x1234_5678)
    }

    @Test func `read write U 32`() {
        let data = Data(repeating: 0, count: 16)
        let buf = BinaryBuffer(data)
        buf.writeU32(at: 4, value: 0xDEAD_BEEF)
        #expect(buf.readU32(at: 4) == 0xDEAD_BEEF)
    }

    @Test func `find string`() {
        let testStr = "Hello, World!\0Extra"
        let data = Data(testStr.utf8)
        let buf = BinaryBuffer(data)
        let offset = buf.findString("Hello, World!")
        #expect(offset == 0)
    }

    @Test func `find all`() {
        var data = Data(repeating: 0, count: 32)
        // Write NOP at offset 8 and 20
        let nop = ARM64.nop
        data.replaceSubrange(8 ..< 12, with: nop)
        data.replaceSubrange(20 ..< 24, with: nop)
        let buf = BinaryBuffer(data)
        let offsets = buf.findAll(nop)
        #expect(offsets.count == 2)
        #expect(offsets.contains(8))
        #expect(offsets.contains(20))
    }

    @Test func `read unaligned values`() {
        let data = Data([0xFF, 0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x9A])
        let buf = BinaryBuffer(data)
        #expect(buf.readU32(at: 1) == 0x1234_5678)
        #expect(buf.readU64(at: 1) == 0x9ABC_DEF0_1234_5678)
    }
}

final class BytePatchPatcher: Patcher {
    let component = "test"
    let verbose = false
    let data: Data
    let offset: Int
    let byte: UInt8
    let id: String

    init(data: Data, offset: Int, byte: UInt8, id: String) {
        self.data = data
        self.offset = offset
        self.byte = byte
        self.id = id
    }

    func findAll() throws -> [PatchRecord] {
        [
            PatchRecord(
                patchID: id,
                component: component,
                fileOffset: offset,
                originalBytes: Data([data[offset]]),
                patchedBytes: Data([byte]),
                description: id,
            ),
        ]
    }

    func apply() throws -> Int {
        1
    }
}

struct FirmwarePipelineDataFlowTests {
    @Test func `chained patchers receive previous patched bytes`() throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            verbose: false,
        )
        var secondInput = Data()

        let (patched, records) = try pipeline.patchData(
            Data([0x00, 0x00]),
            componentName: "test",
            patcherFactories: [
                { data, _ in
                    BytePatchPatcher(data: data, offset: 0, byte: 0xAA, id: "first")
                },
                { data, _ in
                    secondInput = data
                    return BytePatchPatcher(data: data, offset: 1, byte: 0xBB, id: "second")
                },
            ],
        )

        #expect(secondInput == Data([0xAA, 0x00]))
        #expect(patched == Data([0xAA, 0xBB]))
        #expect(records.map(\.patchID) == ["first", "second"])
    }
}

struct IBootPatcherIdempotencyTests {
    @Test func `serial labels patch two banner runs when label absent`() {
        let banner = String(repeating: "=", count: 32)
        let payload = Data("prefix \(banner) middle \(banner) suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.count == 2)
        #expect(patcher.patches.allSatisfy {
            String(data: $0.patchedBytes, encoding: .ascii) == "Loaded iBSS"
        })
    }

    @Test func `serial labels skip when label already present`() {
        let payload = Data("Loaded iBSS\0 middle Loaded iBSS\0 suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.isEmpty)
    }

    @Test func `serial labels do not skip for unrelated single label`() {
        let banner = String(repeating: "=", count: 32)
        let payload = Data("Loaded iBSS\0 prefix \(banner) middle \(banner) suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.count == 2)
    }
}

struct IM4PPayloadParityTests {
    @Test func `ibss IM 4 P payload matches raw and CFW patcher finds nonce patch`() throws {
        let baseDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ipsws/patch_refactor_input")

        let rawIBSS = try Data(contentsOf: baseDir.appendingPathComponent("raw_payloads/ibss.bin"))
        let (im4pPayload, _) = try IM4PHandler.load(
            contentsOf: baseDir.appendingPathComponent("Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"),
        )

        #expect(im4pPayload == rawIBSS)

        let patcher = IBootCustomFirmwarePatcher(data: im4pPayload, mode: .ibss, verbose: false)
        let records = try patcher.findAll()
        #expect(records.count == 1)
    }

    @Test func `saving IBSSIM 4 P round trips payload`() throws {
        let baseDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ipsws/patch_refactor_input")

        let sourceURL = baseDir.appendingPathComponent("Firmware/dfu/iBSS.vresearch101.RELEASE.im4p")
        let originalFile = try Data(contentsOf: sourceURL)
        let (payload, im4p) = try IM4PHandler.load(contentsOf: sourceURL)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("im4p")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try IM4PHandler.save(patchedData: payload, originalIM4P: im4p, to: tempURL)

        let (roundTripPayload, _) = try IM4PHandler.load(contentsOf: tempURL)
        #expect(roundTripPayload == payload)
        // Written back LZFSE-compressed, as Apple ships it: OpenAVB decodes
        // nothing else.
        #expect(originalFile.range(of: Data("bvx2".utf8)) != nil)
        #expect(try Data(contentsOf: tempURL).range(of: Data("bvx2".utf8)) != nil)
    }

    @Test func `iBSS is saved LZFSE-compressed and other images as they were`() throws {
        let payload = Data((0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 >> 5) })
        let marker = Data("bvx2".utf8)
        for fourcc in ["ibss", "ibec", "illb"] {
            let original = try IM4P(fourcc: fourcc, description: "iBoot-13822", payload: payload)
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("im4p")
            defer { try? FileManager.default.removeItem(at: url) }

            try IM4PHandler.save(patchedData: payload, originalIM4P: original, to: url)

            let saved = try Data(contentsOf: url)
            #expect((saved.range(of: marker) != nil) == (fourcc == "ibss"), "\(fourcc)")
            let (roundTrip, container) = try IM4PHandler.load(contentsOf: url)
            #expect(roundTrip == payload, "\(fourcc)")
            #expect(container?.fourcc == fourcc)
        }
    }

    @Test func `saving TXMIM 4 P preserves PAYP trailer`() throws {
        let baseDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ipsws/patch_refactor_input")

        let sourceURL = baseDir.appendingPathComponent("Firmware/txm.iphoneos.research.im4p")
        let originalFile = try Data(contentsOf: sourceURL)
        let (payload, im4p) = try IM4PHandler.load(contentsOf: sourceURL)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("im4p")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try IM4PHandler.save(patchedData: payload, originalIM4P: im4p, to: tempURL)

        let savedFile = try Data(contentsOf: tempURL)
        #expect(originalFile.range(of: Data("PAYP".utf8)) != nil)
        #expect(savedFile.range(of: Data("PAYP".utf8)) != nil)

        let (roundTripPayload, _) = try IM4PHandler.load(contentsOf: tempURL)
        #expect(roundTripPayload == payload)
    }
}

struct FirmwarePipelineTests {
    @Test func `public JB includes the former EXP device tree patchers, not the hv_vmm rename`() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let pipeline = FirmwarePipeline(vmDirectory: root, variant: .jb, verbose: false)
        let components = try pipeline.buildComponentList(
            restoreDir: root,
            iOSBase: VPhoneVersion("27.0"),
        )
        // Base and custom firmware, and no KernelExperimentalPatcher: the hv_vmm_present
        // concealment is off unless a preset or a checkmark asks for it, and a
        // patcher that would write nothing is not built. See
        // FirmwareKernelHypervisorPatchSet for what it does to a 26.4 guest.
        let kernel = try #require(components.first { $0.name == "kernelcache" })
        #expect(kernel.patcherFactories.count == 2)
        for factory in kernel.patcherFactories {
            #expect(try !(factory(Data(), false) is KernelExperimentalPatcher))
        }

        let deviceTree = try #require(components.first { $0.name == "DeviceTree" })
        let patcher = try #require(deviceTree.patcherFactories.first?(Data(), false) as? DeviceTreePatcher)
        #expect(patcher.includeIdentityPatches)
        #expect(components.first { $0.name == "Filesystem" }?.patcherFactories.isEmpty == true)
        #expect(components.first { $0.name == "Manifest" }?.patcherFactories.isEmpty == true)
    }

    @Test func `the minimal preset builds no kernel or TXM patcher, and of the boot chain only iBEC's and LLB's`() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        func patched(_ preset: VPhonePatchPreset) throws -> [String] {
            let plan = try VPhonePatchPlan.resolve(
                preset: preset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("26.4"),
                cloudOS: VPhoneVersion("26.4"),
            )
            let pipeline = FirmwarePipeline(vmDirectory: root, variant: .jb, verbose: false)
            return try pipeline.buildComponentList(restoreDir: root, iOSBase: VPhoneVersion("26.4"), plan: plan)
                .filter { !$0.patcherFactories.isEmpty }
                .map(\.name)
        }
        let minimal = try patched(FirmwarePatchSetCatalog.minimalPreset)
        #expect(!minimal.contains("kernelcache"))
        #expect(!minimal.contains("TXM"))
        #expect(Set(minimal).isDisjoint(with: ["AVPBooter", "iBSS"]))
        #expect(Set(["iBEC", "LLB", "DeviceTree", "Filesystem", "Manifest"]).isSubset(of: Set(minimal)))
        let standard = try patched(FirmwarePatchSetCatalog.standardPreset)
        #expect(!standard.contains("Filesystem"))
        #expect(!standard.contains("Manifest"))
    }

    @Test func `standard turns the paravirtual user-client allowlist on before 27`() throws {
        // The flag the kernel CFW patcher is built with, from the standard plan and
        // from the no-plan fallback, which has to give the same answer.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        func flag(_ base: String?, standard: Bool) throws -> Bool {
            let version = VPhoneVersion(base)
            let pipeline = FirmwarePipeline(
                vmDirectory: root,
                variant: .jb,
                verbose: false,
                preset: standard ? FirmwarePatchSetCatalog.standardPreset : nil,
            )
            let plan = try pipeline.resolvePlan(iOSBase: version, cloudOS: VPhoneVersion("26.4"))
            let components = try pipeline.buildComponentList(
                restoreDir: root,
                iOSBase: version,
                plan: plan,
                gate: plan.map { VPhonePatchGate(plan: $0) } ?? .unrestricted,
            )
            let kernel = try #require(components.first { $0.name == "kernelcache" })
            let patcher = try #require(
                kernel.patcherFactories.lazy.compactMap { try? $0(Data(), false) as? KernelCustomFirmwarePatcher }.first,
            )
            return patcher.applyParavirtUserClients
        }
        for standard in [true, false] {
            #expect(try flag("26.6.2", standard: standard))
            #expect(try flag("18.6.2", standard: standard))
            #expect(try !flag("27.0", standard: standard))
            #expect(try !flag(nil, standard: standard))
        }
    }

    @Test func `standard turns ProMotion on unless the VM blocks it`() throws {
        // From the standard plan and from the no-plan fallback, on every base.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        func flag(_ base: String?, standard: Bool, blocked: Set<String> = []) throws -> Bool {
            let version = VPhoneVersion(base)
            let pipeline = FirmwarePipeline(
                vmDirectory: root,
                variant: .jb,
                verbose: false,
                preset: standard ? FirmwarePatchSetCatalog.standardPreset : nil,
                blockedPatches: blocked,
            )
            let plan = try pipeline.resolvePlan(iOSBase: version, cloudOS: VPhoneVersion("26.4"))
            let components = try pipeline.buildComponentList(
                restoreDir: root,
                iOSBase: version,
                plan: plan,
                gate: plan.map { VPhonePatchGate(plan: $0) } ?? .unrestricted,
            )
            let kernel = try #require(components.first { $0.name == "kernelcache" })
            let patcher = try #require(
                kernel.patcherFactories.lazy.compactMap { try? $0(Data(), false) as? KernelCustomFirmwarePatcher }.first,
            )
            return patcher.applyProMotion
        }
        for base in ["18.6.2", "26.6.2", "27.0", nil] {
            for standard in [true, false] {
                #expect(try flag(base, standard: standard))
            }
            #expect(try !flag(base, standard: true, blocked: [FirmwarePatchSetCatalog.proMotionPatch]))
        }
    }

    @Test func `a machine booting OpenAVB has no AVPBooter component to patch`() throws {
        let fm = FileManager.default
        let vm = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: vm, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: vm) }
        // An Apple ROM stays in the folder after a switch; it is not the one that boots.
        try Data([0xAA]).write(to: vm.appendingPathComponent("AVPBooter.vresearch1.bin"))
        try Data("OpenBootROM: SEP bootstrap complete\n".utf8).write(to: vm.appendingPathComponent("OpenAVB.bin"))

        func components(booting rom: String) throws -> [String] {
            try VPhoneVirtualMachineManifest(
                cpuCount: 2,
                memorySize: 2 << 30,
                romImages: .init(avpBooter: rom, avpSEPBooter: "AVPSEPBooter.vresearch1.bin"),
            ).write(to: vm.appendingPathComponent("config.plist"))
            let pipeline = FirmwarePipeline(vmDirectory: vm, variant: .jb, verbose: false)
            return try pipeline.buildComponentList(restoreDir: vm, iOSBase: VPhoneVersion("26.6.2")).map(\.name)
        }

        #expect(try !components(booting: "OpenAVB.bin").contains("AVPBooter"))
        #expect(try components(booting: "OpenAVB.bin").first == "iBSS")
        #expect(try components(booting: "AVPBooter.vresearch1.bin").first == "AVPBooter")
    }

    @Test func `find file supports glob patterns`() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("AVPBooter.vresearch1.bin")
        try Data([0xAA]).write(to: target)

        let pipeline = FirmwarePipeline(vmDirectory: tempDir, variant: .regular, verbose: false)
        let found = try pipeline.findFile(in: tempDir, patterns: ["AVPBooter*.bin"], label: "AVPBooter")

        // Both sides resolved: `NSTemporaryDirectory()` hands back `/var/...`
        // and `findFile` returns what the directory scan saw, which is the
        // realpath `/private/var/...`. Comparing them raw made this test red on
        // every macOS that symlinks /var, which is all of them.
        #expect(found.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
    }
}

struct FridaGatingTests {
    @Test func `cloud OS version gate`() {
        // Frida kernel patches apply on cloudOS 26.4+ only.
        #expect(FirmwarePipeline.productVersionAtLeast("26.4", 26, 4))
        #expect(FirmwarePipeline.productVersionAtLeast("26.5", 26, 4))
        #expect(FirmwarePipeline.productVersionAtLeast("26.10", 26, 4))
        #expect(FirmwarePipeline.productVersionAtLeast("27.0", 26, 4))
        #expect(!FirmwarePipeline.productVersionAtLeast("26.3", 26, 4))
        #expect(!FirmwarePipeline.productVersionAtLeast("18.5", 26, 4))
        #expect(!FirmwarePipeline.productVersionAtLeast(nil, 26, 4))
    }
}
