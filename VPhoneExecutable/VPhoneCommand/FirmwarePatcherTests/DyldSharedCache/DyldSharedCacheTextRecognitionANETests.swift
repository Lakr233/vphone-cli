@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("TextRecognition modern Neural Engine predicate")
struct DyldSharedCacheTextRecognitionANETests {
    typealias Patcher = DyldSharedCacheTextRecognitionANEPatcher
    let base: UInt64 = 0x1_0000_0000
    let answer: UInt64 = 0x1_0040_0000
    /// Index of the `tbz` in the fixture.
    let gate = 9
    /// Index of the `bl` to MGGetSInt64Answer in the fixture.
    let call = 13

    /// Frozen from `___deviceHasModernNeuralEngine_block_invoke` in
    /// TextRecognition, iOS 27.0.1 (24A446), through its fast-path `retab`.
    /// Only the BL displacement is relocated by the fixture.
    func fixture() throws -> Data {
        let words: [UInt32] = [
            0xd503237f, 0xa9bf7bfd, 0x910003fd, 0xb0053808,
            0xf942b108, 0xb100051f, 0x540001c1, 0xb0053808,
            0x39536108, 0x36000128, 0xd0093c80, 0x911ca000,
            0x52800021, 0x94bb14c5, 0xf1007c1f, 0x1a9fd7e8,
            0xb0053809, 0x39136528, 0xa8c17bfd, 0xd65f0fff,
        ]
        var result = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        try replace(&result, call, ARM64Encoder.encodeBL(from: Int(base) + call * 4, to: Int(answer)))
        return result
    }

    /// `___deviceHasH16OrLaterNeuralEngine_block_invoke` from the same
    /// image: the same block, but subtype > 207 into the next cache byte.
    func h16Fixture() throws -> Data {
        let words: [UInt32] = [
            0xd503237f, 0xa9bf7bfd, 0x910003fd, 0xb0053808,
            0xf942b108, 0xb100051f, 0x540001c1, 0xb0053808,
            0x39536108, 0x36000128, 0xd0093c80, 0x911ca000,
            0x52800021, 0x94bb1499, 0xf1033c1f, 0x1a9fd7e8,
            0xb0053809, 0x39136928, 0xa8c17bfd, 0xd65f0fff,
        ]
        var result = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        try replace(&result, call, ARM64Encoder.encodeBL(from: Int(base) + call * 4, to: Int(answer)))
        return result
    }

    func replace(_ code: inout Data, _ index: Int, _ word: Data?) throws {
        let word = try #require(word)
        code.replaceSubrange(index * 4 ..< index * 4 + 4, with: word)
    }

    func site(_ bytes: Data, stubs: [UInt64: Data] = [:]) throws -> Patcher.Site {
        try Patcher.findSite(in: ARM64Disassembler().disassemble(bytes, at: base), answer: answer) { address in
            guard let stub = stubs[address] else { throw PatcherError.fileNotFound("stub") }
            return ARM64Disassembler().disassemble(stub, at: address)
        }
    }

    @Test func `finds the existence gate and accepts its own nop`() throws {
        let code = try fixture()
        let found = try site(code)
        #expect(found.address == base + UInt64(gate * 4))
        #expect(!found.alreadyPatched)

        var patched = code
        patched.replaceSubrange(gate * 4 ..< gate * 4 + 4, with: ARM64.nop)
        let again = try site(patched)
        #expect(again.address == found.address)
        #expect(again.alreadyPatched)
    }

    @Test func `follows a call through a branch stub`() throws {
        var code = try fixture()
        let stub = base + 0x8000
        try replace(&code, call, ARM64Encoder.encodeBL(from: Int(base) + call * 4, to: Int(stub)))
        let page = try #require(ARM64Encoder.encodeADRP(rd: 16, pc: stub, target: answer))
        let low = try #require(ARM64Encoder.encodeAddImm12(rd: 16, rn: 16, imm12: UInt32(answer & 0xFFF)))
        let branch = try #require(ARM64Encoder.encodeBR(rn: 16))
        #expect(try site(code, stubs: [stub: page + low + branch]).address == base + UInt64(gate * 4))
        #expect(throws: (any Error).self) { try site(code) }
    }

    @Test func `rejects the H16 predicate and other lookalikes`() throws {
        let code = try fixture()
        #expect(throws: (any Error).self) { try site(try h16Fixture()) }
        var otherCall = code
        try replace(&otherCall, call, ARM64Encoder.encodeBL(from: Int(base) + call * 4, to: Int(answer) + 4))
        #expect(throws: (any Error).self) { try site(otherCall) }
        var otherKey = code
        try replace(&otherKey, 12, ARM64Encoder.encodeMovzW(rd: 1, imm16: 0))
        #expect(throws: (any Error).self) { try site(otherKey) }
        var otherCondition = code
        try replace(&otherCondition, 15, ARM64Encoder.encodeCsetW(rd: 8, condition: .ge))
        #expect(throws: (any Error).self) { try site(otherCondition) }
        var otherTarget = code
        try replace(&otherTarget, gate, ARM64Encoder.encodeTestBitBranch(
            nonzero: false, register: 8, bit: 0, from: Int(base) + gate * 4, to: Int(base) + 19 * 4,
        ))
        #expect(throws: (any Error).self) { try site(otherTarget) }
        var otherFlag = code
        try replace(&otherFlag, gate, ARM64Encoder.encodeTestBitBranch(
            nonzero: false, register: 9, bit: 0, from: Int(base) + gate * 4, to: Int(base) + 18 * 4,
        ))
        #expect(throws: (any Error).self) { try site(otherFlag) }
        // A second copy whose call also reaches the answer is ambiguous.
        var twice = code + code
        let second = code.count / 4 + call
        try replace(&twice, second, ARM64Encoder.encodeBL(from: Int(base) + second * 4, to: Int(answer)))
        #expect(throws: (any Error).self) {
            try Patcher.findSite(in: ARM64Disassembler().disassemble(twice, at: base), answer: answer) { _ in [] }
        }
        // Without that call, the copy is no candidate and the first stands.
        let shifted = ARM64Disassembler().disassemble(code + code, at: base)
        #expect(try Patcher.findSite(in: shifted, answer: answer) { _ in [] }.address == base + UInt64(gate * 4))
    }
}
