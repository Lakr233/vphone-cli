// FirmwarePatcherTests.swift — Tests for ARM64 constants, encoders, and round-trip verification.

@testable import FirmwarePatcher
import Foundation
import Testing

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

    @Test func movX0_0() {
        let insn = disasm.disassembleOne(ARM64.movX0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movX0_1() {
        let insn = disasm.disassembleOne(ARM64.movX0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movW0_0() {
        let insn = disasm.disassembleOne(ARM64.movW0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movW0_1() {
        let insn = disasm.disassembleOne(ARM64.movW0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func cmpW0W0() {
        verifyConstant(ARM64.cmpW0W0, expectedMnemonic: "cmp")
    }

    @Test func cmpX0X0() {
        verifyConstant(ARM64.cmpX0X0, expectedMnemonic: "cmp")
    }

    @Test func movX0X20() {
        let insn = disasm.disassembleOne(ARM64.movX0X20, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "orr")
    }

    @Test func strbW0X20_30() {
        verifyConstant(ARM64.strbW0X20_30, expectedMnemonic: "strb")
    }

    @Test func movW0_0xA1() {
        let insn = disasm.disassembleOne(ARM64.movW0_0xA1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }
}

struct ARM64EncoderTests {
    let disasm = ARM64Disassembler()

    @Test func encodeBForward() throws {
        // B from 0x1000 to 0x2000 (forward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func encodeBBackward() throws {
        // B from 0x2000 to 0x1000 (backward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x2000, to: 0x1000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x2000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func encodeBLForward() throws {
        let data = ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "bl")
    }

    @Test func decodeBranchTarget() throws {
        // Encode a B, then decode and verify the target matches
        let from: UInt64 = 0x10000
        let to: UInt64 = 0x20000
        let data = try #require(ARM64Encoder.encodeB(from: Int(from), to: Int(to)))
        let insn: UInt32 = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let decoded = ARM64Encoder.decodeBranchTarget(insn: insn, pc: from)
        #expect(decoded == to)
    }

    @Test func encodeBOutOfRange() {
        // Try to encode a branch that's too far (> 128MB)
        let data = ARM64Encoder.encodeB(from: 0, to: 0x1000_0000)
        #expect(data == nil)
    }

    @Test func encodeADRP() throws {
        let data = ARM64Encoder.encodeADRP(rd: 0, pc: 0x1000, target: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "adrp")
    }

    @Test func encodeAddImm12() throws {
        let data = ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0x100)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0)
        #expect(insn?.mnemonic == "add")
    }

    @Test func encodeMovXFromZR() {
        // `mov x8, xzr` — the mac_mount state-clear encoding (ORR X8, XZR, XZR).
        let bytes = ARM64Encoder.encodeMovX(rd: 8, rm: 31)
        let insn = disasm.disassembleOne(bytes, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "orr")
        // Byte-for-byte equal to the legacy hand-encoded constant 0xAA1F03E8.
        #expect(bytes == withUnsafeBytes(of: UInt32(0xAA1F_03E8).littleEndian) { Data($0) })
    }

    @Test func encodeMovXIsRegisterMove() {
        // `mov x0, x20` matches the project's preverified ARM64.movX0X20 constant.
        #expect(ARM64Encoder.encodeMovX(rd: 0, rm: 20) == ARM64.movX0X20)
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

    @Test func fieldAccessors() {
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

    @Test func ldrImm64() {
        let w: UInt32 = 0xF941_F001 // ldr x1, [x0, #0x3e0]
        #expect(mnemonic(of: w) == "ldr")
        #expect(ARM64Inst.isLDRImm64(w))
        #expect(!ARM64Inst.isLDRImm64(0x9000_0000))
    }

    @Test func cmpReg64() {
        let w: UInt32 = 0xEB01_001F // cmp x0, x1
        #expect(mnemonic(of: w) == "cmp")
        #expect(ARM64Inst.isCMPReg64(w))
        // operand order is irrelevant: cmp x1, x0
        #expect(ARM64Inst.isCMPReg64(0xEB00_003F))
        #expect(!ARM64Inst.isCMPReg64(0x5100_0462)) // sub-imm is not cmp-reg
    }

    @Test func subImm32() {
        let w: UInt32 = 0x5100_0462 // sub w2, w3, #1
        #expect(mnemonic(of: w) == "sub")
        #expect(ARM64Inst.isSUBImm32(w))
        #expect(!ARM64Inst.isSUBImm32(0x5280_02C0)) // movz is not sub
    }

    @Test func movzW() {
        let w: UInt32 = 0x5280_02C0 // movz w0, #0x16
        let m = mnemonic(of: w)
        #expect(m == "mov" || m == "movz")
        #expect(ARM64Inst.isMOVZW(w))
        #expect(ARM64Inst.rd(w) == 0)
        #expect(!ARM64Inst.isMOVZW(0xF941_F001))
    }

    @Test func andRegW() {
        let w: UInt32 = 0x0A05_0083 // and w3, w4, w5
        #expect(mnemonic(of: w) == "and")
        #expect(ARM64Inst.isANDRegW(w))
        #expect(!ARM64Inst.isANDRegW(0x5280_02C0))
    }

    @Test func lsrImm7W() {
        let w: UInt32 = 0x5307_7C20 // lsr w0, w1, #7
        let m = mnemonic(of: w)
        #expect(m == "lsr" || m == "ubfm")
        #expect(ARM64Inst.isLSRImm7W(w))
        #expect(!ARM64Inst.isLSRImm7W(0x0A05_0083))
    }

    @Test func branchPredicates() {
        let bl = ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)!
            .withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(ARM64Inst.isBL(bl))
        // b.eq vs b.ne (cond field)
        #expect(ARM64Inst.isBEQ(0x5400_0020)) // b.eq #4
        #expect(!ARM64Inst.isBEQ(0x5400_0021)) // b.ne #4
    }

    @Test func compareAndBranch() {
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
    @Test func readWriteU32() {
        let data = Data(repeating: 0, count: 16)
        let buf = BinaryBuffer(data)
        buf.writeU32(at: 4, value: 0xDEAD_BEEF)
        #expect(buf.readU32(at: 4) == 0xDEAD_BEEF)
    }

    @Test func findString() {
        let testStr = "Hello, World!\0Extra"
        let data = Data(testStr.utf8)
        let buf = BinaryBuffer(data)
        let offset = buf.findString("Hello, World!")
        #expect(offset == 0)
    }

    @Test func findAll() {
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

    @Test func readUnalignedValues() {
        let data = Data([0xFF, 0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x9A])
        let buf = BinaryBuffer(data)
        #expect(buf.readU32(at: 1) == 0x1234_5678)
        #expect(buf.readU64(at: 1) == 0x9ABC_DEF0_1234_5678)
    }
}

struct IBootPatcherIdempotencyTests {
    @Test func serialLabelsPatchTwoBannerRunsWhenLabelAbsent() {
        let banner = String(repeating: "=", count: 32)
        let payload = Data("prefix \(banner) middle \(banner) suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.count == 2)
        #expect(patcher.patches.allSatisfy {
            String(data: $0.patchedBytes, encoding: .ascii) == "Loaded iBSS"
        })
    }

    @Test func serialLabelsSkipWhenLabelAlreadyPresent() {
        let banner = String(repeating: "=", count: 32)
        let payload = Data("Loaded iBSS\0 prefix \(banner) middle \(banner) suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.isEmpty)
    }
}

struct IM4PPayloadParityTests {
    @Test func ibssIM4PPayloadMatchesRawAndJBPatcherFindsNoncePatch() throws {
        let baseDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ipsws/patch_refactor_input")

        let rawIBSS = try Data(contentsOf: baseDir.appendingPathComponent("raw_payloads/ibss.bin"))
        let (im4pPayload, _) = try IM4PHandler.load(contentsOf: baseDir.appendingPathComponent("Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"))

        #expect(im4pPayload == rawIBSS)

        let patcher = IBootJBPatcher(data: im4pPayload, mode: .ibss, verbose: false)
        let records = try patcher.findAll()
        #expect(records.count == 1)
    }

    @Test func savingIBSSIM4PRoundTripsPayload() throws {
        let baseDir = URL(fileURLWithPath: #filePath)
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
        #expect((try Data(contentsOf: tempURL)).count > originalFile.count)
    }

    @Test func savingTXMIM4PPreservesPAYPTrailer() throws {
        let baseDir = URL(fileURLWithPath: #filePath)
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
    @Test func findFileSupportsGlobPatterns() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("AVPBooter.vresearch1.bin")
        try Data([0xAA]).write(to: target)

        let pipeline = FirmwarePipeline(vmDirectory: tempDir, variant: .regular, verbose: false)
        let found = try pipeline.findFile(in: tempDir, patterns: ["AVPBooter*.bin"], label: "AVPBooter")

        #expect(found == target)
    }
}
