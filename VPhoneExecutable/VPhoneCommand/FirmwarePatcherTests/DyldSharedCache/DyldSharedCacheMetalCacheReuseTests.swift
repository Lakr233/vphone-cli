@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Metal cache reboot reuse preserves the client key")
struct DyldSharedCacheMetalCacheReuseTests {
    typealias Patcher = DyldSharedCacheMetalCacheReusePatcher
    let base: UInt64 = 0x1000
    let thirdParty: UInt64 = 0x3000
    let comparison: UInt64 = 0x3100
    let stackFailure: UInt64 = 0x3200
    let literal: UInt64 = 0x5000
    let siteOffset = 0xc8

    // Entire verify_list_file from libCoreFSCache, iOS 26.6.2 (23G90).
    // Relocate calls and the environment literal; retain the actual multiple
    // return/control-flow layout, stack canary and ABI register save/restore.
    func fixture() throws -> Data {
        let words: [UInt32] = [
            0xd503237f, 0xd10303ff, 0xa9085ff8, 0xa90957f6,
            0xa90a4ff4, 0xa90b7bfd, 0x9102c3fd, 0xaa0303f4,
            0xaa0203f3, 0xaa0103f5, 0xaa0003f6, 0x901bc1e8,
            0xf9424108, 0xf9400108, 0xf81c83a8, 0xb9000fff,
            0x94097a37, 0x910033e0, 0x52800021, 0x52800082,
            0xaa1603e3, 0x940979d6, 0xaa0003e8, 0x52800000,
            0xb9400fe9, 0xf100111f, 0x5286c8a8, 0x72a304e8,
            0x7a480120, 0x540003e1, 0xf9003bff, 0x6f00e400,
            0xad0283e0, 0xad0183e0, 0xad0083e0, 0x910043e0,
            0x52800021, 0x52800d02, 0xaa1603e3, 0x940979c4,
            0xf101a01f, 0x54000241, 0x90000020, 0x91388c00,
            0x940979e3, 0xb40000c0, 0x39400017, 0x97fffb29,
            0x7100c6ff, 0x54000061, 0x1400001c, 0x97fffb25,
            0xaa0003f6, 0x910043e8, 0x910102a0, 0x91010101,
            0x52800402, 0x94000f9f, 0x340001c0, 0x52800000,
            0xf85c83a8, 0x901bc1e9, 0xf9424129, 0xf9400129,
            0xeb08013f, 0x54000401, 0xa94b7bfd, 0xa94a4ff4,
            0xa94957f6, 0xa9485ff8, 0x910303ff, 0xd65f0fff,
            0x370000d6, 0x910043e1, 0xaa1503e0, 0x52800802,
            0x94000f8c, 0x35fffdc0, 0xb98073e8, 0xd37ae509,
            0xcb080d28, 0x9101b115, 0xeb15027f, 0x54000142,
            0x901bc1e0, 0xf9447800, 0x52800201, 0x940979e0,
            0x34fffc80, 0xaa1503e0, 0xaa1303e1, 0x94000e5e,
            0x17ffffdf, 0x9101a108, 0xf9000288, 0x52800020,
            0x17ffffdc, 0x94097946,
        ]
        var bytes = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        for offset in [0xbc, 0xcc] { put(try #require(ARM64Encoder.encodeBL(from: Int(base) + offset, to: Int(thirdParty))), in: &bytes, at: offset) }
        for offset in [0xe4, 0x130] { put(try #require(ARM64Encoder.encodeBL(from: Int(base) + offset, to: Int(comparison))), in: &bytes, at: offset) }
        put(try #require(ARM64Encoder.encodeBL(from: Int(base) + 0x184, to: Int(stackFailure))), in: &bytes, at: 0x184)
        put(try #require(ARM64Encoder.encodeADRP(rd: 0, pc: base + 0xa8, target: literal)), in: &bytes, at: 0xa8)
        put(try #require(ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0)), in: &bytes, at: 0xac)
        return bytes
    }

    func put(_ instruction: Data, in bytes: inout Data, at offset: Int) {
        bytes.replaceSubrange(offset ..< offset + instruction.count, with: instruction)
    }

    func site(_ bytes: Data, environment: Data = Patcher.environment) throws -> Patcher.Site {
        try Patcher.findSite(in: ARM64Disassembler().disassemble(bytes, at: base), thirdParty: thirdParty, stackFailure: stackFailure) { address, count in
            if address != literal { return Data(repeating: 0, count: count) }
            #expect(address == literal)
            #expect(count == Patcher.environment.count)
            return environment
        }
    }

    @Test func `whole function reveals the environment branch and both identity checks`() throws {
        let found = try site(fixture())
        #expect(found.address == base + UInt64(siteOffset))
        #expect(found.resume == base + 0xd4)
        #expect(found.flagRegister == 22)
        #expect(found.existingCave == nil)
        // verify_list_file returns before its boot comparison and success
        // block; truncating disassembly at that first return is insufficient.
        #expect(throws: (any Error).self) { try site(Data(try fixture().prefix(0x120))) }
        let code = ARM64Disassembler().disassemble(try fixture(), at: base)
        #expect(throws: (any Error).self) {
            try Patcher.findSite(in: code + code, thirdParty: thirdParty, stackFailure: stackFailure) { _, _ in Patcher.environment }
        }
        #expect(throws: (any Error).self) { try site(fixture(), environment: Data("FS_CACHE_REUSE_ON_REBOOTX".utf8)) }
    }

    @Test func `rejects changed environment key boot and saved-register dataflow`() throws {
        let edits: [(Int, Data)] = [
            (0xc0, try #require(ARM64Encoder.encodeCmpWImmediate(rn: 23, imm12: 48))), // env '0'
            (0xb8, try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 0, rn: 0, offset: 0))),
            (0xcc, try #require(ARM64Encoder.encodeBL(from: Int(base) + 0xcc, to: 0x3300))),
            (0xd8, try #require(ARM64Encoder.encodeAddImm12(rd: 0, rn: 21, imm12: 32))),
            (0xe0, try #require(ARM64Encoder.encodeMovzW(rd: 2, imm16: 64))),
            (0x12c, try #require(ARM64Encoder.encodeMovzW(rd: 2, imm16: 32))),
            (0x130, try #require(ARM64Encoder.encodeBL(from: Int(base) + 0x130, to: 0x3300))),
            (0x120, try #require(ARM64Encoder.encodeTestBitBranch(nonzero: true, register: 23, bit: 0, from: Int(base) + 0x120, to: Int(base) + 0x138))),
            (0x138, ARM64Encoder.encodeMovX(rd: 8, rm: 22)), // live read on success
            (0x140, ARM64Encoder.encodeMovX(rd: 22, rm: 8)), // flag redefinition
            (0x110, ARM64.nop), // missing restore
            (0x0c, ARM64.nop), // missing original save
            (0x40, ARM64Encoder.encodeMovX(rd: 21, rm: 2)), // saved client key clobbered
            (0x104, ARM64.ret), // early return skips restoration
            (0x180, try #require(ARM64Encoder.encodeB(from: Int(base) + 0x180, to: 0x9000))),
            (0x184, try #require(ARM64Encoder.encodeBL(from: Int(base) + 0x184, to: 0x9000))),
        ]
        for (offset, instruction) in edits {
            var bytes = try fixture()
            put(instruction, in: &bytes, at: offset)
            #expect(throws: (any Error).self) { try site(bytes) }
        }
        var callerSavedCharacter = try fixture()
        put(try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 0, rn: 0, offset: 0)), in: &callerSavedCharacter, at: 0xb8)
        put(try #require(ARM64Encoder.encodeCmpWImmediate(rn: 0, imm12: 49)), in: &callerSavedCharacter, at: 0xc0)
        #expect(throws: (any Error).self) { try site(callerSavedCharacter) }
    }

    @Test func `terminal no-return exception resolves the actual stack failure through its island`() throws {
        let island: UInt64 = 0x7000
        let resolved: UInt64 = 0x9124
        // BR x16 is frozen from the cache-builder island inspected alongside
        // verify_list_file. The relocation-dependent words use the encoder.
        let program = try #require(ARM64Encoder.encodeADRP(rd: 16, pc: island, target: resolved))
            + #require(ARM64Encoder.encodeAddImm12(rd: 16, rn: 16, imm12: UInt32(resolved & 0xfff)))
            + ARM64.encodeU32(0xd61f0200)
        let accepted = try Patcher.isStackFailure(island, resolved: resolved) { at, count in
            #expect(at == island)
            #expect(count == 12)
            return program
        }
        #expect(accepted)
        #expect(try !Patcher.isStackFailure(island, resolved: resolved + 4) { _, _ in program })
        #expect(try !Patcher.isStackFailure(island, resolved: resolved) { _, _ in Data(program.prefix(8)) + ARM64.ret })
    }

    @Test func `plans an eight byte cave and verifies exact complete prior output`() throws {
        let original = try fixture()
        let found = try site(original)
        let padding: Range<UInt64> = 0x800 ..< 0x840
        var bytes = Data(repeating: 0, count: padding.count)
        bytes[0] = 1
        func read(_ at: UInt64, _ count: Int) -> Data {
            Data(bytes[Int(at - padding.lowerBound) ..< Int(at - padding.lowerBound) + count])
        }
        let first = try Patcher.plan(site: found, padding: padding, read: read)
        #expect(first.cave == 0x804)
        #expect(first.program.count == 8)
        #expect(!first.alreadyPatched)
        let program = ARM64Disassembler().disassemble(first.program, at: first.cave)
        #expect(Patcher.immediateMove(program[0], .w(22), 1))
        #expect(Patcher.branch(program[1], "b") == found.resume)
        var patched = original
        put(first.branch, in: &patched, at: siteOffset)
        let patchedSite = try site(patched)
        #expect(patchedSite.existingCave == first.cave)
        #expect(throws: (any Error).self) { try Patcher.plan(site: patchedSite, padding: padding, read: read) }
        bytes.replaceSubrange(4 ..< 12, with: first.program)
        #expect(throws: (any Error).self) { try Patcher.plan(site: found, padding: padding, read: read) }
        let again = try Patcher.plan(site: patchedSite, padding: padding, read: read)
        #expect(again.alreadyPatched)
        #expect(again.program == first.program)
        bytes[8] ^= 1
        #expect(throws: (any Error).self) { try Patcher.plan(site: patchedSite, padding: padding, read: read) }
        #expect(throws: (any Error).self) {
            try Patcher.plan(site: found, padding: padding) { _, count in Data(repeating: 0xff, count: count) }
        }
        for destination: UInt64 in [0x802, 0x83c, 0x1000, 0x9000] {
            let foreign = Patcher.Site(address: found.address, resume: found.resume, flagRegister: found.flagRegister, existingCave: destination)
            #expect(throws: (any Error).self) { try Patcher.plan(site: foreign, padding: padding, read: read) }
        }
        #expect(throws: (any Error).self) { try Patcher.trampoline(at: 0x800, returningTo: 0x1000, flagRegister: 18) }
    }
}
