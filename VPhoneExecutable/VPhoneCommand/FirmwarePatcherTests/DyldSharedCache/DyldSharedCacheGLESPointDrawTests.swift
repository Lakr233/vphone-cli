@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("GLES point draw guards")
struct DyldSharedCacheGLESPointDrawTests {
    typealias Patcher = DyldSharedCacheGLESPointDrawPatcher
    let directBase: UInt64 = 0x4000
    let primitiveBase: UInt64 = 0x8000
    let selector: UInt64 = 0x10000
    let draw: UInt64 = 0x11000
    let fields = Patcher.Fields(pipeline: 0x898, usage: 0x8a0, encoder: 0x10)
    let indexedDraw = Patcher.IndexedDrawFields(selector: 0xde8, imp: 0xdf0)

    func decode(_ bytes: Data, at address: UInt64) -> [ARM64Instruction] {
        ARM64Disassembler().disassemble(bytes, at: address)
    }

    func setter(_ fields: Patcher.Fields) throws -> Data {
        let instructions = [
            ARM64Encoder.encodeMovX(rd: 19, rm: 0),
            try #require(ARM64Encoder.encodeBL(from: 0x2004, to: 0x12000)),
            // A later saved return value must not be confused with `this`.
            ARM64Encoder.encodeMovX(rd: 20, rm: 0),
            try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 2, rn: 8, offset: 0)),
            try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 2, rn: 19, offset: UInt32(fields.pipeline))),
            try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 8, offset: 8)),
            try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 8, rn: 19, offset: UInt32(fields.usage))),
            try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 19, offset: UInt32(fields.encoder))),
            try #require(ARM64Encoder.encodeBL(from: 0x2020, to: Int(selector))),
            try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 19, offset: UInt32(fields.usage))),
            ARM64.ret,
        ]
        return instructions.reduce(into: Data()) { $0 += $1 }
    }

    struct Fixture {
        var direct: Data
        var primitive: Data
        let directSites: [Int]
        let primitiveSite: Int
    }

    func fixture(fields: Patcher.Fields? = nil, mode: UInt32 = 0x178) throws -> Fixture {
        let fields = fields ?? self.fields
        func block(at start: Int, primitive: Bool, interveningLoads: Bool) throws -> (Data, Int) {
            // Preserve the two intervening index-buffer loads on the EBO path.
            let extra = interveningLoads ? 8 : 0
            let guardOffset = 20 + extra + (primitive ? 4 : 0)
            let end = start + guardOffset + 16
            var bytes = try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 19, offset: UInt32(fields.pipeline)))
            bytes += try #require(ARM64Encoder.encodeCompareBranch(nonzero: false, register: 8, from: start + 4, to: end, width64: true))
            if interveningLoads {
                bytes += try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 27, offset: 24))
                bytes += try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 27, rn: 8, offset: 0))
            }
            if primitive {
                bytes += try #require(ARM64Encoder.encodeTestBitBranch(nonzero: true, register: 22, bit: 0, from: start + bytes.count, to: end))
            }
            bytes += try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 19, offset: mode))
            bytes += try #require(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 0, from: start + bytes.count, to: start + guardOffset + 4))
            bytes += try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 19, offset: UInt32(fields.usage)))
            #expect(bytes.count == guardOffset)
            bytes += try #require(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 7, from: start + bytes.count, to: end))
            bytes += try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 19, offset: UInt32(fields.encoder)))
            bytes += try #require(ARM64Encoder.encodeBL(from: start + bytes.count, to: Int(draw)))
            bytes += ARM64.nop
            bytes += ARM64.ret
            return (bytes, guardOffset)
        }
        // An early RET is deliberate: discovery must use the symbol span and
        // inspect the later draw paths, as the real direct callback requires.
        var direct = ARM64Encoder.encodeMovX(rd: 19, rm: 0) + ARM64.ret
        var directSites: [Int] = []
        for path in 0 ..< 3 {
            let start = direct.count
            let (bytes, site) = try block(at: Int(directBase) + start, primitive: false, interveningLoads: path == 1)
            directSites.append(start + site)
            direct += bytes
        }
        var primitive = ARM64Encoder.encodeMovX(rd: 19, rm: 0)
        let (bytes, site) = try block(at: Int(primitiveBase) + primitive.count, primitive: true, interveningLoads: false)
        let primitiveSite = primitive.count + site
        primitive += bytes
        return .init(direct: direct, primitive: primitive, directSites: directSites, primitiveSite: primitiveSite)
    }

    func plan(_ fixture: Fixture, fields: Patcher.Fields? = nil) throws -> Patcher.Plan {
        try Patcher.plan(direct: decode(fixture.direct, at: directBase), primitive: decode(fixture.primitive, at: primitiveBase),
                         fields: fields ?? self.fields, indexedDraw: indexedDraw, drawTargets: [draw])
    }

    @Test func `derives context layout from the actual pipeline call`() throws {
        #expect(try Patcher.pipelineFields(in: decode(setter(fields), at: 0x2000), selector: selector) == fields)
        let relocated = Patcher.Fields(pipeline: 0x280, usage: 0x288, encoder: 0x28)
        #expect(try Patcher.pipelineFields(in: decode(setter(relocated), at: 0x2000), selector: selector) == relocated)
        #expect(try plan(fixture(fields: relocated, mode: 0x90), fields: relocated).sites.count == 4)
        var wrong = try setter(fields)
        wrong.replaceSubrange(12 ..< 16, with: try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 3, rn: 8, offset: 0)))
        #expect(throws: (any Error).self) { try Patcher.pipelineFields(in: decode(wrong, at: 0x2000), selector: selector) }
        wrong = try setter(fields)
        wrong.replaceSubrange(36 ..< 40, with: try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 19, offset: 0x900)))
        #expect(throws: (any Error).self) { try Patcher.pipelineFields(in: decode(wrong, at: 0x2000), selector: selector) }
        #expect(throws: (any Error).self) { try Patcher.pipelineFields(in: decode(setter(fields), at: 0x2000), selector: selector + 4) }
    }

    @Test func `uses the next symbol rather than an early return`() throws {
        let fixture = try fixture()
        let end = directBase + UInt64(fixture.direct.count)
        #expect(try Patcher.functionSpan(at: directBase, symbolAddresses: [directBase, directBase, end, end + 4]) == directBase ..< end)
        #expect(try plan(fixture).sites.count == 4)
        #expect(throws: (any Error).self) { try Patcher.functionSpan(at: directBase, symbolAddresses: [directBase]) }
        #expect(throws: (any Error).self) { try Patcher.functionSpan(at: directBase, symbolAddresses: [directBase + 65540]) }
        #expect(throws: (any Error).self) { try Patcher.functionSpan(at: directBase, symbolAddresses: [directBase + 3]) }
        let truncated = Fixture(direct: Data(fixture.direct.prefix(8)), primitive: fixture.primitive,
                                directSites: [], primitiveSite: fixture.primitiveSite)
        #expect(throws: (any Error).self) { try plan(truncated) }
    }

    @Test func `derives indexed IMP slots from the named selector and method lookup`() throws {
        let lookup: UInt64 = 0x12000
        let literalAddress: UInt64 = 0x307b4
        let literal = Data((Patcher.indexedDrawSelector + "\0").utf8)
        func setup(_ slots: Patcher.IndexedDrawFields) throws -> Data {
            let instructions = [
                ARM64Encoder.encodeMovX(rd: 19, rm: 0),
                try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 19, offset: UInt32(fields.encoder))),
                try #require(ARM64Encoder.encodeADRP(rd: 8, pc: 0x2008, target: literalAddress)),
                try #require(ARM64Encoder.encodeAddImm12(rd: 2, rn: 8, imm12: UInt32(literalAddress & 0xfff))),
                try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 2, rn: 19, offset: UInt32(slots.selector))),
                try #require(ARM64Encoder.encodeBL(from: 0x2014, to: Int(lookup))),
                try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 19, offset: UInt32(slots.imp))),
                ARM64.ret,
            ]
            return instructions.reduce(into: Data()) { $0 += $1 }
        }
        func discover(_ bytes: Data, text: Data? = nil) throws -> Patcher.IndexedDrawFields {
            try Patcher.indexedDrawFields(in: decode(bytes, at: 0x2000), fields: fields, methodForSelector: lookup) { address, count in
                #expect(address == literalAddress)
                #expect(count == literal.count)
                return text ?? literal
            }
        }
        #expect(try discover(setup(indexedDraw)) == indexedDraw)
        let relocated = Patcher.IndexedDrawFields(selector: 0x380, imp: 0x388)
        #expect(try discover(setup(relocated)) == relocated)
        // An equally shaped cached method with another selector is not a draw.
        #expect(throws: (any Error).self) { try discover(setup(indexedDraw), text: Data("setVertexBuffer:offset:atIndex:\0".utf8)) }
        #expect(throws: (any Error).self) { try discover(setup(indexedDraw), text: Data(literal.dropLast())) }
        let mutations: [(Int, Data)] = [
            (4, try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 19, offset: 0x28))),
            (12, try #require(ARM64Encoder.encodeAddImm12(rd: 3, rn: 8, imm12: UInt32(literalAddress & 0xfff)))),
            (20, try #require(ARM64Encoder.encodeBL(from: 0x2014, to: Int(lookup + 4)))),
            (24, try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 1, rn: 19, offset: UInt32(indexedDraw.imp)))),
            (24, try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 19, offset: UInt32(indexedDraw.imp + 8)))),
        ]
        for (offset, replacement) in mutations {
            var wrong = try setup(indexedDraw)
            wrong.replaceSubrange(offset ..< offset + 4, with: replacement)
            #expect(throws: (any Error).self) { try discover(wrong) }
        }
    }

    @Test func `requires all four original guards or all four exact NOPs`() throws {
        let original = try fixture()
        let initial = try plan(original)
        #expect(!initial.alreadyPatched)
        #expect(initial.sites.map(\.address) == original.directSites.map { directBase + UInt64($0) } + [primitiveBase + UInt64(original.primitiveSite)])
        for count in 1 ... 4 {
            var changed = original
            for site in original.directSites.prefix(count) { changed.direct.replaceSubrange(site ..< site + 4, with: ARM64.nop) }
            if count == 4 { changed.primitive.replaceSubrange(changed.primitiveSite ..< changed.primitiveSite + 4, with: ARM64.nop) }
            if count < 4 {
                #expect(throws: (any Error).self) { try plan(changed) }
            } else {
                #expect(try plan(changed).alreadyPatched)
                #expect(try plan(changed).sites.map(\.address) == initial.sites.map(\.address))
            }
        }
    }

    @Test func `refuses stale flags mode pipeline skip and draw shapes`() throws {
        let original = try fixture()
        let site = original.directSites[0]
        let address = Int(directBase) + site
        let skip = try #require(try plan(original).sites.first?.skip)
        let mutations: [(Int, Data)] = [
            (site, try #require(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 6, from: address, to: Int(skip)))),
            (site, try #require(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 7, from: address, to: Int(skip) - 4))),
            (site - 4, try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 19, offset: 0x900))),
            (site - 8, try #require(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 1, from: address - 8, to: address + 4))),
            (site - 12, try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 19, offset: 0x188))),
            (site - 20, try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 19, offset: 0x900))),
            (site + 8, ARM64.ret),
        ]
        for (offset, replacement) in mutations {
            var changed = original
            changed.direct.replaceSubrange(offset ..< offset + 4, with: replacement)
            #expect(throws: (any Error).self) { try plan(changed) }
        }
        var wrongPrimitive = original
        let gate = original.primitiveSite - 16
        wrongPrimitive.primitive.replaceSubrange(gate ..< gate + 4, with: ARM64.nop)
        #expect(throws: (any Error).self) { try plan(wrongPrimitive) }
    }

    @Test func `recognizes the real authenticated indexed draw call`() throws {
        // Frozen 23G90 input at renderer __TEXT + 0x145cc. This is the
        // existing call sequence, not generated replacement instructions.
        let words: [UInt32] = [
            0xf9400a60, 0xd0000028, 0x9117e108, 0xf8765902,
            0x93407ea3, 0xa94093e6, 0x93407e87, 0xf946fa68,
            0xf946f661, 0xaa1703e5, 0xd63f091f,
        ]
        let bytes = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        #expect(Patcher.containsDraw(decode(bytes, at: directBase), context: .x(19), fields: fields, indexedDraw: indexedDraw, drawTargets: []))
        var wrong = bytes
        wrong.replaceSubrange(32 ..< 36, with: try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 1, rn: 20, offset: 0xde8)))
        #expect(!Patcher.containsDraw(decode(wrong, at: directBase), context: .x(19), fields: fields, indexedDraw: indexedDraw, drawTargets: []))
        // A different adjacent selector/IMP pair can have exactly the same
        // calling shape; it must not satisfy this guard's draw proof.
        wrong = bytes
        wrong.replaceSubrange(28 ..< 32, with: try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 19, offset: 0xde0)))
        wrong.replaceSubrange(32 ..< 36, with: try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 1, rn: 19, offset: 0xdd8)))
        #expect(!Patcher.containsDraw(decode(wrong, at: directBase), context: .x(19), fields: fields, indexedDraw: indexedDraw, drawTargets: []))
        wrong = bytes
        wrong.replaceSubrange(0 ..< 4, with: ARM64.nop)
        #expect(!Patcher.containsDraw(decode(wrong, at: directBase), context: .x(19), fields: fields, indexedDraw: indexedDraw, drawTargets: []))
        // A call after an unconditional return is not a draw on this path.
        wrong = bytes
        wrong.replaceSubrange(4 ..< 8, with: ARM64.ret)
        #expect(!Patcher.containsDraw(decode(wrong, at: directBase), context: .x(19), fields: fields, indexedDraw: indexedDraw, drawTargets: []))
        wrong = bytes
        wrong.replaceSubrange(16 ..< 20, with: ARM64Encoder.encodeMovX(rd: 0, rm: 19))
        #expect(!Patcher.containsDraw(decode(wrong, at: directBase), context: .x(19), fields: fields, indexedDraw: indexedDraw, drawTargets: []))
    }
}
