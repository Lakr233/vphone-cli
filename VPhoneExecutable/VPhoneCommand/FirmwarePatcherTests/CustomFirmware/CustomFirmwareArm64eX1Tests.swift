import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("ARM64E_X1 lowering")
struct CustomFirmwareArm64eX1Tests {
    // Instruction fixtures come from Apple clang 21 or Keystone 0.9.2.
    static let pac: UInt32 = 0xDAC1_A7FE
    static let add: UInt32 = 0x9A0B_2909 // addpt x9,x8,x11,lsl #2
    static let sub: UInt32 = 0xDA04_2063 // subpt x3,x3,x4
    static let auth: UInt32 = 0xF3A0_007F
    static let ret: UInt32 = 0x5520_009F

    static func fixture(_ code: [UInt32]) -> Data {
        var data = Data()
        func word(_ v: UInt32) { data += ARM64.encodeU32(v) }
        func quad(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func name(_ s: String) { data += Data(s.utf8) + Data(repeating: 0, count: 16 - s.utf8.count) }
        word(0xFEED_FACF); word(0x0100_000C); word(0x8000_000C); word(2)
        word(2); word(168); word(0); word(0)
        word(0x19); word(152); name("__TEXT")
        quad(0); quad(0x1000); quad(0); quad(0x400)
        word(5); word(5); word(1); word(0)
        name("__text"); name("__TEXT"); quad(0x200); quad(UInt64(code.count * 4)); word(0x200)
        word(2); word(0); word(0); word(0x8000_0400); word(0); word(0); word(0)
        word(0x26); word(16); word(0x300); word(3)
        data += Data(repeating: 0, count: 0x200 - data.count)
        for v in code { word(v) }
        data += Data(repeating: 0, count: 0x300 - data.count)
        data += Data([0x80, 0x04, 0]) // LC_FUNCTION_STARTS: 0x200, terminator
        return data
    }

    static func signedFixture(hashType: UInt8 = 2, codeLimit: Int = 0x400) -> (Data, Int) {
        var image = fixture([pac, ret])
        let identity = Data("com.apple.fsck\0".utf8)
        let entitlements = Data("<plist><dict><key>platform-application</key><true/></dict></plist>".utf8)
        func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        let hashOffset = 44 + identity.count, directoryLength = hashOffset + 32
        let signatureLength = 28 + directoryLength + 8 + entitlements.count
        image.replaceSubrange(16 ..< 24, with: ARM64.encodeU32(3) + ARM64.encodeU32(184))
        image.replaceSubrange(200 ..< 216, with: ARM64.encodeU32(0x1D) + ARM64.encodeU32(16)
            + ARM64.encodeU32(0x400) + ARM64.encodeU32(UInt32(signatureLength)))
        image += Data(count: 0x400 - image.count)
        var directory = be(0xFADE_0C02) + be(UInt32(directoryLength)) + be(0x20001) + be(0x10002)
        directory += be(UInt32(hashOffset)) + be(44) + be(0) + be(1) + be(UInt32(codeLimit))
        directory += Data([32, hashType, 0, 12]) + be(0) + identity
        directory += Data(SHA256.hash(data: image.prefix(codeLimit)))
        image += be(0xFADE_0CC0) + be(UInt32(signatureLength)) + be(2)
            + be(0) + be(28) + be(5) + be(UInt32(28 + directoryLength))
        image += directory + be(0xFADE_7171) + be(UInt32(8 + entitlements.count)) + entitlements
        return (image, 0x400 + 28 + hashOffset)
    }

    @Test func `signed program lowering changes only instructions and their code slot hashes`() throws {
        var (image, hashOffset) = Self.signedFixture()
        var expected = image
        expected.replaceSubrange(0x200 ..< 0x208, with: ARM64.pacibsp + ARM64.retab)
        expected.replaceSubrange(hashOffset ..< hashOffset + 32, with: Data(SHA256.hash(data: expected.prefix(0x400))))
        let (result, slots) = try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: "test-x1")
        #expect(result.records.count == 2)
        #expect(slots.count == 1)
        #expect(image == expected)
    }

    @Test func `missing unsupported or incomplete signing coverage refuses without changing bytes`() throws {
        for source in [Self.fixture([Self.pac, Self.ret]), Self.signedFixture(hashType: 1).0,
                       Self.signedFixture(codeLimit: 0x200).0] {
            var image = source
            #expect(throws: (any Error).self) {
                try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: "test-x1")
            }
            #expect(image == source)
        }
    }

    @Test(arguments: [FirmwareGuestSystemPatchSet.arm64eX1CIBarcode,
                      FirmwareGuestSystemPatchSet.arm64eX1HomePopAccessibility])
    func `standalone bundle lowering attests code and is idempotent`(identifier: String) throws {
        var (image, hashOffset) = Self.signedFixture()
        // Core Image filters use MH_BUNDLE rather than the boot executables'
        // MH_EXECUTE. Recompute the fixture signature after changing its header.
        image.replaceSubrange(12 ..< 16, with: ARM64.encodeU32(8))
        image.replaceSubrange(
            hashOffset ..< hashOffset + 32,
            with: Data(SHA256.hash(data: image.prefix(0x400))),
        )
        let first = try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: identifier)
        #expect(first.result.records.count == 2)
        #expect(first.slots.count == 1)
        #expect(image.loadLE(UInt32.self, at: 12) == 8)
        let patched = image
        let second = try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: identifier)
        #expect(second.result.records.isEmpty)
        #expect(image == patched)
    }

    static func universal(_ first: Data, _ second: Data, wide: Bool = false) -> Data {
        func be<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var data = be(UInt32(wide ? 0xCAFE_BABF : 0xCAFE_BABE)) + be(UInt32(2))
        for (offset, slice) in [(0x1000, first), (0x2000, second)] {
            data += be(slice.loadLE(UInt32.self, at: 4)) + be(slice.loadLE(UInt32.self, at: 8))
            if wide {
                data += be(UInt64(offset)) + be(UInt64(slice.count)) + be(UInt32(12)) + be(UInt32(0))
            } else {
                data += be(UInt32(offset)) + be(UInt32(slice.count)) + be(UInt32(12))
            }
        }
        data += Data(count: 0x1000 - data.count)
        data += first + Data(count: 0x1000 - first.count) + second
        return data
    }

    @Test func `universal lowering preserves other architectures and attests slice relative pages`() throws {
        var (other, hashOffset) = Self.signedFixture()
        other.replaceSubrange(8 ..< 12, with: ARM64.encodeU32(0x8000_0002))
        other.replaceSubrange(hashOffset ..< hashOffset + 32, with: Data(SHA256.hash(data: other.prefix(0x400))))
        let x1 = Self.signedFixture().0
        var expected = x1
        let (thin, hashes) = try CustomFirmwareArm64eX1.lowerAndReattest(&expected, identifier: "thin")
        for wide in [false, true] {
            var image = Self.universal(other, x1, wide: wide)
            let original = image
            let (result, slots) = try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: "fat")
            #expect(image.count == original.count)
            #expect(image.prefix(0x2000) == original.prefix(0x2000))
            #expect(image.subdata(in: 0x2000 ..< image.count) == expected)
            #expect(result.records.map(\.fileOffset) == thin.records.map { 0x2000 + $0.fileOffset })
            #expect(slots.map(\.hashFileOffset) == hashes.map { 0x2000 + $0.hashFileOffset })
            #expect(try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: "fat").result.records.isEmpty)
        }
    }

    @Test func `invalid universal layouts and later signing failures leave the container unchanged`() throws {
        let signed = Self.signedFixture().0
        let valid = Self.universal(signed, signed)
        var overlap = valid, outside = valid, mismatch = valid
        func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        overlap.replaceSubrange(36 ..< 40, with: be(0x1000))
        outside.replaceSubrange(36 ..< 40, with: be(UInt32.max))
        mismatch.replaceSubrange(0x2008 ..< 0x200C, with: ARM64.encodeU32(0x8000_0002))
        for source in [overlap, outside, mismatch, Self.universal(signed, Self.fixture([Self.pac, Self.ret]))] {
            var image = source
            #expect(throws: (any Error).self) { try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: "fat") }
            #expect(image == source)
        }
    }

    @Test func `lowers supported PAC and pointer arithmetic forms without changing operands`() throws {
        var image = Self.fixture([
            Self.pac, Self.add, Self.sub, Self.auth,
            0x9A02_33FF, // addpt sp,sp,x2,lsl #4
            0x9B62_0C20, 0x9B7C_EFBE, // maddpt and msubpt
            0xDAC1_BBFE, 0xDAC1_BFFE, // autia171615 and autib171615
            Self.ret,
        ])
        let result = try CustomFirmwareArm64eX1.lower(&image)
        #expect(result.records.count == 10)
        #expect(result.unvisitedCandidates == 0)
        let decoded = ARM64Disassembler().disassemble(in: image, at: 0x200, count: 10)
        #expect(decoded.map(\.mnemonic) == [
            "pacibsp", "add", "sub", "autibsp", "add",
            "madd", "msub", "autia1716", "autib1716", "retab",
        ])
        #expect(decoded[1].detail?.operands[0].reg == .x(9))
        #expect(decoded[1].detail?.operands[1].reg == .x(8))
        #expect(decoded[1].detail?.operands[2].reg == .x(11))
        #expect(decoded[1].detail?.operands[2].shift.type == .lsl)
        #expect(decoded[1].detail?.operands[2].shift.amount == 2)
        let stackAdd = try #require(ARM64Encoder.encodeAddSubXExtended(
            subtract: false, rd: 31, rn: 31, rm: 2, shift: 4,
        ))
        #expect(image[0x210 ..< 0x214] == stackAdd)
        #expect(image.loadLE(UInt32.self, at: 0x214) == 0x9B02_0C20)
        #expect(image.loadLE(UInt32.self, at: 0x218) == 0x9B1C_EFBE)
        #expect(image.loadLE(UInt32.self, at: 0x21C) == 0xD503_219F)
        #expect(image.loadLE(UInt32.self, at: 0x220) == 0xD503_21DF)
        let again = try CustomFirmwareArm64eX1.lower(&image)
        #expect(again.records.isEmpty)
    }

    @Test func `does not rewrite literal pools skipped by a direct branch`() throws {
        let branch = try #require(ARM64Encoder.encodeB(from: 0x204, to: 0x210))
        let branchWord = branch.loadLE(UInt32.self, at: 0)
        var image = Self.fixture([Self.pac, branchWord, Self.pac, Self.add, Self.add, Self.ret])
        let original = image
        let result = try CustomFirmwareArm64eX1.lower(&image)
        #expect(result.records.map(\.fileOffset) == [0x200, 0x210, 0x214])
        #expect(image[0x208 ..< 0x210] == original[0x208 ..< 0x210])
        #expect(result.unvisitedCandidates == 2)
    }

    @Test func `follows a bounded hardened switch and never rewrites its table`() throws {
        let page = try #require(ARM64Encoder.encodeADRP(rd: 17, pc: 0x208, target: 0x280))
        let low = try #require(ARM64Encoder.encodeAddImm12(rd: 17, rn: 17, imm12: 0x280))
        let code: [UInt32] = [0xF100_061F, 0x9A9F_9210, page.loadLE(UInt32.self, at: 0), low.loadLE(UInt32.self, at: 0),
                              0xB8B0_7A30, 0x1000_0011, 0x8B10_0230, 0xD61F_0200,
                              Self.add, ARM64.retU32, Self.sub, ARM64.retU32]
        var image = Self.fixture(code)
        image.replaceSubrange(0x280 ..< 0x288, with: ARM64.encodeU32(0xC) + ARM64.encodeU32(0x14))
        let original = image
        let result = try CustomFirmwareArm64eX1.lower(&image)
        #expect(result.records.map(\.fileOffset) == [0x220, 0x228])
        #expect(result.unvisitedCandidates == 0)
        #expect(image[0x280 ..< 0x288] == original[0x280 ..< 0x288])

        var invalid = original
        invalid.replaceSubrange(0x284 ..< 0x288, with: ARM64.encodeU32(0x7FFF_0000))
        let before = invalid
        #expect(throws: (any Error).self) { try CustomFirmwareArm64eX1.lower(&invalid) }
        #expect(invalid == before)
    }

    @Test func `authenticated bytecode dispatch discovers label bodies and rejects invalid targets`() throws {
        let page = try #require(ARM64Encoder.encodeADRP(rd: 9, pc: 0x204, target: 0x280))
        let low = try #require(ARM64Encoder.encodeAddImm12(rd: 9, rn: 9, imm12: 0x280))
        let words: [UInt32] = [0xD378_FF08, page.loadLE(UInt32.self, at: 0), low.loadLE(UInt32.self, at: 0),
                              0xF868_7929, 0xD282_6B11, 0xD71F_0931,
                              Self.pac, Self.add, Self.ret, Self.sub, Self.ret, Self.add]
        let bytes = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        func plan(badTarget: Bool = false) throws -> CustomFirmwareArm64eX1.Result {
            try CustomFirmwareArm64eX1.planCode(ranges: [(address: 0x200, data: bytes)], seeds: [0x200],
                excluded: [], identifier: "test-x1", authenticatedPointer: { address, diversity in
                    #expect(diversity == 0x1358)
                    switch address {
                    case 0x280: return badTarget ? 0x400 : 0x218
                    case 0x288: return 0x224
                    default: return nil
                    }
                })
        }
        let result = try plan()
        #expect(result.records.map(\.fileOffset) == [0x218, 0x21C, 0x220, 0x224, 0x228])
        #expect(result.unvisitedCandidates == 1) // skipped instruction-shaped literal
        #expect(throws: (any Error).self) { try plan(badTarget: true) }
    }

    @Test func `already lowered PAC frames still reveal coalesced function entries`() throws {
        let words: [UInt32] = [ARM64.retU32, ARM64.pacibsp.loadLE(UInt32.self, at: 0),
                              0xA9BF_7BFD, Self.add, Self.ret]
        let bytes = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        let result = try CustomFirmwareArm64eX1.planCode(ranges: [(address: 0x200, data: bytes)],
            seeds: [0x200], excluded: [], identifier: "test-x1")
        #expect(result.records.map(\.fileOffset) == [0x20C, 0x210])
        #expect(result.unvisitedCandidates == 0)
    }

    @Test func `hoisted authenticated tables reject overwritten bases and indexes`() throws {
        let page = try #require(ARM64Encoder.encodeADRP(rd: 23, pc: 0x200, target: 0x280))
        let low = try #require(ARM64Encoder.encodeAddImm12(rd: 23, rn: 23, imm12: 0x280))
        let nop = ARM64.nop.loadLE(UInt32.self, at: 0)
        for (baseWrite, indexWrite, interleaved, accepted) in [(nop, nop, UInt32(0xAA1A_03FC), true),
                                                (nop, nop, UInt32(0xF940_07FB), true), // LDR X27,[SP,#8]
                                                (UInt32(0x2A1F_03F7), nop, UInt32(0xAA1A_03FC), false), // W23 aliases X23
                                                (UInt32(0xF840_86E0), nop, UInt32(0xAA1A_03FC), false), // LDR X0,[X23],#8
                                                (nop, UInt32(0x2A1F_03E8), UInt32(0xAA1A_03FC), false)] { // W8 aliases X8
            let words = [page.loadLE(UInt32.self, at: 0), low.loadLE(UInt32.self, at: 0),
                         baseWrite, 0xD378_FF08, indexWrite, 0xF868_7AE9, interleaved,
                         0xD282_6B11, 0xD71F_0931, Self.add, Self.ret, Self.sub, Self.ret, Self.add]
            let bytes = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
            var pointerReads = 0
            let result = try CustomFirmwareArm64eX1.planCode(ranges: [(address: 0x200, data: bytes)],
                seeds: [0x200], excluded: [], identifier: "test-x1", authenticatedPointer: { address, diversity in
                    pointerReads += 1
                    #expect(diversity == 0x1358)
                    switch address {
                    case 0x280: return 0x224
                    case 0x288: return 0x22C
                    default: return nil
                    }
                })
            #expect(result.records.map(\.fileOffset) == (accepted ? [0x224, 0x228, 0x22C, 0x230] : []))
            #expect(pointerReads == (accepted ? 3 : 0))
            #expect(result.unvisitedCandidates == (accepted ? 1 : 5))
        }
    }

    @Test func `invalid discovery or operands refuse the whole plan before writing`() {
        var missingEntries = Self.fixture([Self.pac, Self.ret])
        missingEntries[0x300] = 0
        for source in [
            Self.fixture([Self.pac, 0x9A02_3FFF, Self.ret]), // SP shift 7 has no one-instruction equivalent
            missingEntries,
        ] {
            var image = source
            #expect(throws: (any Error).self) { try CustomFirmwareArm64eX1.lower(&image) }
            #expect(image == source)
        }
    }

    @Test func `non-target and empty images remain unchanged`() throws {
        var otherArchitecture = Self.fixture([Self.pac, Self.ret])
        otherArchitecture.replaceSubrange(8 ..< 12, with: ARM64.encodeU32(2))
        var kernelExtension = Self.fixture([Self.pac, Self.ret])
        kernelExtension.replaceSubrange(12 ..< 16, with: ARM64.encodeU32(11)) // MH_KEXT_BUNDLE
        for source in [otherArchitecture, kernelExtension, Self.fixture([])] {
            var image = source
            let (result, slots) = try CustomFirmwareArm64eX1.lowerAndReattest(&image, identifier: "test-x1")
            #expect(result.records.isEmpty)
            #expect(slots.isEmpty)
            #expect(image == source)
        }
    }

    @Test func `includes instruction sections such as authenticated stubs`() throws {
        var image = Self.fixture([Self.pac, Self.ret])
        image.replaceSubrange(104 ..< 120, with: Data("__auth_stubs".utf8) + Data(repeating: 0, count: 4))
        let result = try CustomFirmwareArm64eX1.lower(&image)
        #expect(result.records.count == 2)
        #expect(MachOParser.parseSections(from: image)["__TEXT,__auth_stubs"]?.flags == 0x8000_0400)
    }

    @Test func `exception metadata seeds cleanup code while skipped literals stay unchanged`() throws {
        let base: UInt64 = 0x1_0000_0000
        let unwind = [UInt32(1), 0, 0, 0, 0, 28, 2,
                      0x2000, 0, 52, 0x2040, 0, 60, 0x2000, 0x4000]
            .reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        var lsda = Data([0xFF, 0xFF, 1, 4, 0, 4, 0x10, 0])
        let sections = [
            MachOSectionInfo(segmentName: "__TEXT", sectionName: "__text", address: base + 0x2000,
                size: 0x40, fileOffset: 0x2000),
            MachOSectionInfo(segmentName: "__TEXT", sectionName: "__unwind_info", address: base + 0x3000,
                size: UInt64(unwind.count), fileOffset: 0x3000),
            MachOSectionInfo(segmentName: "__TEXT", sectionName: "__gcc_except_tab", address: base + 0x4000,
                size: UInt64(lsda.count), fileOffset: 0x4000),
        ]
        func entries() throws -> [UInt64] {
            try CustomFirmwareArm64eX1.exceptionEntries(sections: sections, imageBase: base, readMemory: { address, length in
                let source = address == base + 0x3000 ? unwind : lsda
                return source.subdata(in: 0 ..< min(length, source.count))
            })
        }
        let landing = try entries()
        #expect(landing == [base + 0x2010])
        let code = [Self.pac, Self.ret, Self.pac, Self.add, Self.sub, Self.ret]
            .reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        let result = try CustomFirmwareArm64eX1.planCode(ranges: [(Int(base + 0x2000), code)],
            seeds: [Int(base + 0x2000)] + landing.map(Int.init), excluded: [], identifier: "test")
        #expect(result.records.map(\.fileOffset) == [0x2000, 0x2004, 0x2010, 0x2014].map { Int(base) + $0 })
        #expect(result.unvisitedCandidates == 2)
        lsda[3] = 5
        #expect(throws: (any Error).self) { try entries() }
        lsda[3] = 4; lsda[6] = 0x70
        #expect(throws: (any Error).self) { try entries() }
    }
}
