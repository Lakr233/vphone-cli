@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("GLES depth clip matcher")
struct DyldSharedCacheGLESDepthClipTests {
    typealias Patcher = DyldSharedCacheGLESDepthClipPatcher

    // Frozen 23G90 input functions, not replacement instructions. Decode at
    // different bases to ensure discovery uses symbols and relative calls.
    let update: [UInt32] = [
        0xf9403408, 0xbd5b3100, 0xbd5b2101, 0xbd5b3902, 0xbd5b2903,
        0x52827b09, 0x38696809, 0x7100053f, 0x54000161, 0xf940c809,
        0xf9401129, 0x7d416924, 0x7e21d885, 0xbd5b3506, 0xbd5b2504,
        0x1e2428c6, 0x1e2638a5, 0x1e601006, 0x14000005, 0xbd5b3505,
        0xbd5b2504, 0x1e2428a5, 0x1e701006, 0x1e22c084, 0x1e6408c4,
        0x1e22c0a5, 0x1e232843, 0x1e22c063, 0x1e22c042, 0x1e22c026,
        0x1e6628c6, 0x1e213800, 0x1e22c000, 0xfd0a0000, 0xfd0a0405,
        0xfd0a0806, 0xfd0a0c04, 0xfd0a1002, 0xfd0a1403, 0xb949a808,
        0x321c0108, 0xb909a808, 0xd65f03c0,
    ]
    let setter: [UInt32] = [
        0xd503237f, 0xd10143ff, 0xa9034ff4, 0xa9047bfd, 0x910103fd,
        0xaa0003f3, 0x97ffffcf, 0xf9400a60, 0x3dc50260, 0x3dc50661,
        0xad0007e0, 0x3dc50a60, 0x3d800be0, 0x910003e2, 0x940045ea,
        0xf9400a60, 0xf9403668, 0x79400908, 0x7100011f, 0x1a9f17e2,
        0x940045ec, 0xa9447bfd, 0xa9434ff4, 0x910143ff, 0xd65f0fff,
    ]

    func bytes(_ words: [UInt32]) -> Data {
        words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
    }

    @Test func `matches iOS 27 viewport with resolved shared selector`() throws {
        // The 24A94425 viewport differs by one split byte load. Keep its
        // captured instructions, function addresses and actual BL destination.
        var newer = update
        newer.replaceSubrange(6 ..< 7, with: [0x8b090009, 0x39400129])
        var newerSetter = setter
        newerSetter[6] = 0x97fff6b1
        newerSetter[14] = 0x957a0a95
        newerSetter[20] = 0x957a0a93
        let decoder = ARM64Disassembler()
        let code = decoder.disassemble(bytes(newer), at: 0x2421b0100)
        let setterCode = decoder.disassemble(bytes(newerSetter), at: 0x2421b2624)
        let found = try Patcher.findSite(update: code, setter: setterCode, updateAddress: 0x2421b0100, sendAddress: 0x2480350b0)
        #expect(found.address == 0x2421b0174)
        #expect(found.near == 2 && found.source == 2 && found.far == 3)
        #expect(throws: PatcherError.self) {
            try Patcher.findSite(update: code, setter: setterCode, updateAddress: 0x2421b0100, sendAddress: 0x2421c07c0)
        }
    }

    func site(update changedUpdate: Data? = nil, setter changedSetter: Data? = nil, base: UInt64 = 0x4000) throws -> Patcher.Site {
        let decoder = ARM64Disassembler()
        return try Patcher.findSite(
            update: decoder.disassemble(changedUpdate ?? bytes(update), at: base),
            setter: decoder.disassemble(changedSetter ?? bytes(setter), at: base + UInt64(update.count * 4)),
            updateAddress: base, sendAddress: base + (0x2a891da20 - 0x2a890c194)
        )
    }

    @Test(arguments: [UInt64(0x4000), UInt64(0x2a890c194)])
    func `matches original and recognizes existing branch`(_ base: UInt64) throws {
        let original = try site(base: base)
        #expect(original.address == base + 28 * 4)
        #expect(original.near == 2 && original.source == 2 && original.far == 3)
        #expect(original.existingCave == nil)
        let cave = base - 0x800
        let program = try Patcher.trampoline(original, at: cave)
        let decoded = ARM64Disassembler().disassemble(program, at: cave)
        #expect(decoded.map(\.mnemonic) == ["fcvt", "fadd", "fsub", "b"])
        #expect(Patcher.branch(try #require(decoded.last)) == original.address + 4)
        var patched = bytes(update)
        patched.replaceSubrange(112 ..< 116, with: try #require(ARM64Encoder.encodeB(from: Int(original.address), to: Int(cave))))
        #expect(try site(update: patched, base: base).existingCave == cave)
    }

    @Test func `rejects wrong context stack layout argument and callee`() throws {
        let base = 0x4000
        let setterBase = base + update.count * 4
        let changes: [(Int, Data)] = [
            (5, ARM64Encoder.encodeMovX(rd: 20, rm: 0)),
            (7, try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 20, offset: 16))),
            (9, ARM64.encodeU32(setter[8])), // q0 twice instead of q0/q1
            (10, ARM64.encodeU32(setter[2])), // same mnemonic, wrong registers and stack offset
            (11, ARM64.encodeU32(setter[8])), // reload first 16 bytes instead of depth
            (12, ARM64.nop),
            (13, ARM64Encoder.encodeMovX(rd: 2, rm: 19)),
            (14, try #require(ARM64Encoder.encodeBL(from: setterBase + 14 * 4, to: base))),
        ]
        for (index, replacement) in changes {
            var wrong = bytes(setter)
            wrong.replaceSubrange(index * 4 ..< index * 4 + 4, with: replacement)
            #expect(throws: PatcherError.self) { try site(setter: wrong) }
        }
    }

    @Test func `rejects overwritten depth context and conversion bypass`() throws {
        let changes: [(Int, Data)] = [
            (5, try #require(ARM64Encoder.encodeFcvtDFromS(rd: 2, rn: 4))),
            (5, try #require(ARM64Encoder.encodeFcvtDFromS(rd: 3, rn: 4))),
            (5, ARM64Encoder.encodeMovX(rd: 8, rm: 9)),
            (5, ARM64Encoder.encodeMovX(rd: 0, rm: 9)),
            (29, try #require(ARM64Encoder.encodeFcvtDFromS(rd: 2, rn: 4))),
            (29, try #require(ARM64Encoder.encodeFcvtDFromS(rd: 3, rn: 4))),
            (18, try #require(ARM64Encoder.encodeB(from: 0x4000 + 18 * 4, to: 0x4000 + 29 * 4))),
            (26, ARM64.nop),
            (38, ARM64.nop),
            (42, ARM64.nop),
        ]
        for (index, replacement) in changes {
            var wrong = bytes(update)
            wrong.replaceSubrange(index * 4 ..< index * 4 + 4, with: replacement)
            #expect(throws: PatcherError.self) { try site(update: wrong) }
        }
        let halfLoad = try #require(ARM64Disassembler().disassembleOne(ARM64.encodeU32(update[11])))
        #expect(Patcher.writes(halfLoad, registers: Patcher.simdAliases(4)))
    }
}
