// The fixture is a synthetic Mach-O with relative Objective-C methods, selector
// references, import stubs and the SHA-256 argument flow. No Apple binary is
// bundled; real-driver acceptance is checked separately against an extracted
// input without writing back to that input.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

private typealias CachePatcher = CustomFirmwareParavirtGPUCompilerCache

private struct CompilerCacheDriver {
    static let base: UInt64 = 0x1_0000_0000
    static let text = 0x400
    static let seeds = [0x1000, 0x100C]
    static let methods = 0x1100
    static let names = 0x1200
    static let objcStub = 0x1400
    static let imports = 0x1500
    static let refs = 0x1800
    static let symbols = 0x1900
    static let symbolStrings = 0x1A00
    static let indirect = 0x1B00
    static let textCommand = 32
    static let textCommandSize = 72 + 6 * 80
    static let dataCommand = textCommand + textCommandSize
    static let symtabCommand = dataCommand + 72 + 80
    static let dysymtabCommand = symtabCommand + 24
    static let firstSection = textCommand + 72
    var data = Data(count: 0x2000)

    init() throws {
        put(0xFEED_FACF, at: 0)
        put(0x0100_000C, at: 4)
        put(2, at: 8) // arm64e
        put(8, at: 12) // MH_BUNDLE
        put(4, at: 16)
        put(UInt32(Self.dysymtabCommand + 80 - 32), at: 20)
        segment(at: Self.textCommand, name: "__TEXT", fileOffset: 0, size: 0x1800, sections: 6)
        section(0, name: "__text", offset: Self.text, size: 0x400)
        section(1, name: "__cstring", offset: Self.seeds[0], size: 0x40)
        section(2, name: "__objc_methlist", offset: Self.methods, size: 24)
        section(3, name: "__objc_methname", offset: Self.names, size: 0x100)
        section(4, name: "__objc_stubs", offset: Self.objcStub, size: 0x20)
        section(5, name: "__auth_stubs", offset: Self.imports, size: 0x30, flags: 8)
        put(16, at: Self.firstSection + 5 * 80 + 72) // reserved2: stub size
        segment(at: Self.dataCommand, name: "__DATA_CONST", fileOffset: Self.refs, size: 16, sections: 1)
        section(0, name: "__objc_selrefs", offset: Self.refs, size: 16, command: Self.dataCommand, segment: "__DATA_CONST")
        put(2, at: Self.symtabCommand)
        put(24, at: Self.symtabCommand + 4)
        put(UInt32(Self.symbols), at: Self.symtabCommand + 8)
        put(3, at: Self.symtabCommand + 12)
        put(UInt32(Self.symbolStrings), at: Self.symtabCommand + 16)
        put(0x100, at: Self.symtabCommand + 20)
        put(0xB, at: Self.dysymtabCommand)
        put(80, at: Self.dysymtabCommand + 4)
        put(UInt32(Self.indirect), at: Self.dysymtabCommand + 56)
        put(3, at: Self.dysymtabCommand + 60)
        var stringOffset = 1
        for (index, name) in ["_CC_SHA256_Init", "_CC_SHA256_Update", "_CC_SHA256_Final"].enumerated() {
            put(UInt32(stringOffset), at: Self.symbols + index * 16)
            data[Self.symbols + index * 16 + 4] = 1 // N_UNDF | N_EXT
            putString(name, at: Self.symbolStrings + stringOffset)
            put(UInt32(index), at: Self.indirect + index * 4)
            stringOffset += name.utf8.count + 1
        }
        putString("Feb  4 2026", at: Self.seeds[0])
        putString("23:05:00", at: Self.seeds[1])
        putString(CachePatcher.selector, at: Self.names)
        let initializerName = Self.names + CachePatcher.selector.utf8.count + 1
        putString(CachePatcher.compilerSelector, at: initializerName)
        put64(Self.base + UInt64(Self.names), at: Self.refs)
        put64(Self.base + UInt64(initializerName), at: Self.refs + 8)
        methodList(at: Self.methods, implementation: Self.text)
        for offset in stride(from: Self.text, to: Self.text + 0x400, by: 4) { write(ARM64.nop, at: offset) }
        let instructions: [Data?] = [
            ARM64.pacibsp,
            ARM64Encoder.encodeSubImm12(rd: 31, rn: 31, imm12: 0xE0),
            ARM64Encoder.encodeAddImm12(rd: 29, rn: 31, imm12: 0xD0),
            ARM64Encoder.encodeAddImm12(rd: 0, rn: 31, imm12: 8),
            branch(4, target: Self.imports),
            page(5, register: 1, target: Self.seeds[0]),
            ARM64Encoder.encodeAddImm12(rd: 1, rn: 1, imm12: UInt32(Self.seeds[0] & 0xFFF)),
            ARM64Encoder.encodeAddImm12(rd: 0, rn: 31, imm12: 8),
            ARM64Encoder.encodeMovzW(rd: 2, imm16: 8),
            branch(9, target: Self.imports + 16),
            page(10, register: 1, target: Self.seeds[1]),
            ARM64Encoder.encodeAddImm12(rd: 1, rn: 1, imm12: UInt32(Self.seeds[1] & 0xFFF)),
            ARM64Encoder.encodeAddImm12(rd: 0, rn: 31, imm12: 8),
            ARM64Encoder.encodeMovzW(rd: 2, imm16: 8),
            branch(14, target: Self.imports + 16),
            ARM64Encoder.encodeSubImm12(rd: 0, rn: 29, imm12: 0x50),
            ARM64Encoder.encodeAddImm12(rd: 1, rn: 31, imm12: 8),
            branch(17, target: Self.imports + 32),
            ARM64.nop,
            ARM64Encoder.encodeSubImm12(rd: 3, rn: 29, imm12: 0x50),
            ARM64Encoder.encodeMovX(rd: 2, rm: 22),
            ARM64Encoder.encodeMovX(rd: 4, rm: 21),
            ARM64Encoder.encodeMovX(rd: 5, rm: 19),
            ARM64Encoder.encodeMovzW(rd: 6, imm16: 0x24),
            branch(24, target: Self.objcStub),
            ARM64.retab,
        ]
        for (index, instruction) in instructions.enumerated() {
            write(try #require(instruction), at: Self.text + index * 4)
        }
        write(try #require(ARM64Encoder.encodeADRP(rd: 1, pc: Self.base + UInt64(Self.objcStub), target: Self.base + UInt64(Self.refs + 8))), at: Self.objcStub)
        write(try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 1, rn: 1, offset: UInt32((Self.refs + 8) & 0xFFF))), at: Self.objcStub + 4)
    }

    func branch(_ index: Int, target: Int) -> Data? {
        ARM64Encoder.encodeBL(from: Self.text + index * 4, to: target)
    }

    func page(_ index: Int, register: UInt32, target: Int) -> Data? {
        ARM64Encoder.encodeADRP(rd: register, pc: Self.base + UInt64(Self.text + index * 4), target: Self.base + UInt64(target))
    }

    mutating func instruction(_ index: Int, _ bytes: Data?) throws {
        write(try #require(bytes), at: Self.text + index * 4)
    }

    mutating func segment(at command: Int, name: String, fileOffset: Int, size: Int, sections: Int) {
        put(0x19, at: command)
        put(UInt32(72 + sections * 80), at: command + 4)
        putString(name, at: command + 8)
        put64(Self.base + UInt64(fileOffset), at: command + 24)
        put64(UInt64(size), at: command + 32)
        put64(UInt64(fileOffset), at: command + 40)
        put64(UInt64(size), at: command + 48)
        put(UInt32(sections), at: command + 64)
    }

    mutating func section(_ index: Int, name: String, offset: Int, size: Int, flags: UInt32 = 0, command: Int = Self.textCommand, segment: String = "__TEXT") {
        let entry = command + 72 + index * 80
        putString(name, at: entry)
        putString(segment, at: entry + 16)
        put64(Self.base + UInt64(offset), at: entry + 32)
        put64(UInt64(size), at: entry + 40)
        put(UInt32(offset), at: entry + 48)
        put(flags, at: entry + 64)
    }

    mutating func methodList(at offset: Int, implementation: Int) {
        put(0x8000_000C, at: offset)
        put(1, at: offset + 4)
        put(UInt32(bitPattern: Int32(Self.refs - (offset + 8))), at: offset + 8)
        put(UInt32(bitPattern: Int32(implementation - (offset + 16))), at: offset + 16)
    }

    mutating func put(_ value: UInt32, at offset: Int) { write(ARM64.encodeU32(value), at: offset) }
    mutating func put64(_ value: UInt64, at offset: Int) {
        put(UInt32(truncatingIfNeeded: value), at: offset)
        put(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
    }
    mutating func putString(_ value: String, at offset: Int) { write(Data(value.utf8) + [0], at: offset) }
    mutating func write(_ bytes: Data, at offset: Int) { data.replaceSubrange(offset ..< offset + bytes.count, with: bytes) }
}

@Suite("Paravirtual GPU compiler cache identity")
struct CustomFirmwareParavirtGPUCompilerCacheTests {
    static let plugin = Data("compiler plugin build one".utf8)

    @Test func `Only the sixteen hash-input bytes change and the same plugin is idempotent`() throws {
        var fixture = try CompilerCacheDriver()
        let before = fixture.data
        let report = try CachePatcher.patch(&fixture.data, compilerPlugin: Self.plugin, log: nil)
        let expected = Data(SHA256.hash(data: Self.plugin).prefix(12)).base64EncodedString()
        #expect(report.state == .patched)
        #expect(report.identity == expected)
        #expect(report.identity.utf8.count == 16)
        #expect(report.sites.map(\.fileOffset) == CompilerCacheDriver.seeds)
        #expect(report.sites.reduce(into: Data()) { $0.append($1.after) } == Data(expected.utf8))
        let selected = Set(CompilerCacheDriver.seeds.flatMap { Array($0 ..< $0 + 8) })
        #expect(before.count == fixture.data.count)
        #expect(before.indices.filter { before[$0] != fixture.data[$0] }.count == 16)
        #expect(before.indices.allSatisfy { selected.contains($0) || before[$0] == fixture.data[$0] })
        let once = fixture.data
        let again = try CachePatcher.patch(&fixture.data, compilerPlugin: Self.plugin, log: nil)
        #expect(again.state == .alreadyPatched)
        #expect(again.sites.allSatisfy { $0.before == $0.after })
        #expect(fixture.data == once)
    }

    @Test func `Another plugin changes the identity and returning to the first restores its bytes`() throws {
        var fixture = try CompilerCacheDriver()
        let first = try CachePatcher.patch(&fixture.data, compilerPlugin: Self.plugin, log: nil)
        let firstBytes = fixture.data
        let second = try CachePatcher.patch(&fixture.data, compilerPlugin: Data("compiler plugin build two".utf8), log: nil)
        #expect(second.state == .patched)
        #expect(second.identity != first.identity)
        #expect(fixture.data != firstBytes)
        try CachePatcher.patch(&fixture.data, compilerPlugin: Self.plugin, log: nil)
        #expect(fixture.data == firstBytes)
    }

    @Test func `An empty plugin or malformed driver never changes the input`() throws {
        var valid = try CompilerCacheDriver().data
        let original = valid
        #expect(throws: PatcherError.self) { try CachePatcher.patch(&valid, compilerPlugin: Data(), log: nil) }
        #expect(valid == original)
        for size in [0, 1, 31, 32, 100, 0x1000] {
            var truncated = Data(original.prefix(size))
            let before = truncated
            #expect(throws: PatcherError.self) { try CachePatcher.patch(&truncated, compilerPlugin: Self.plugin, log: nil) }
            #expect(truncated == before)
        }
    }

    @Test(arguments: ["count", "flags", "duplicate", "outsideText", "noSelector", "noReference", "sectionBounds", "shortSelrefs"])
    func `Malformed or ambiguous Objective-C metadata refuses`(_ mutation: String) throws {
        var fixture = try CompilerCacheDriver()
        switch mutation {
        case "count": fixture.put(UInt32.max, at: CompilerCacheDriver.methods + 4)
        case "flags": fixture.put(0xC000_000C, at: CompilerCacheDriver.methods)
        case "duplicate":
            fixture.put64(48, at: CompilerCacheDriver.firstSection + 2 * 80 + 40)
            fixture.methodList(at: CompilerCacheDriver.methods + 24, implementation: CompilerCacheDriver.text + 0x100)
        case "outsideText": fixture.methodList(at: CompilerCacheDriver.methods, implementation: CompilerCacheDriver.seeds[0])
        case "noSelector": fixture.data[CompilerCacheDriver.names] = 0
        case "noReference": fixture.put64(0, at: CompilerCacheDriver.refs)
        case "sectionBounds": fixture.put64(UInt64.max, at: CompilerCacheDriver.firstSection + 2 * 80 + 40)
        case "shortSelrefs": fixture.put64(15, at: CompilerCacheDriver.dataCommand + 72 + 40)
        default: Issue.record("Unknown fixture mutation")
        }
        try refusedWithoutChanges(&fixture)
    }

    @Test(arguments: ["hashLength", "hashContext", "hashCall", "hashOutput", "cacheArgument", "argumentClobber", "middleOfStub", "noReturn", "secondFunction", "sharedLiteral", "sharedScheduledLiteral", "sharedLoad"])
    func `Changed hash semantics and shared literals refuse without mutation`(_ mutation: String) throws {
        var fixture = try CompilerCacheDriver()
        switch mutation {
        case "hashLength": try fixture.instruction(13, ARM64Encoder.encodeMovzW(rd: 2, imm16: 9))
        case "hashContext": try fixture.instruction(12, ARM64Encoder.encodeAddImm12(rd: 0, rn: 31, imm12: 16))
        case "hashCall": try fixture.instruction(14, fixture.branch(14, target: CompilerCacheDriver.imports))
        case "hashOutput": try fixture.instruction(15, ARM64Encoder.encodeSubImm12(rd: 0, rn: 29, imm12: 0x48))
        case "cacheArgument": try fixture.instruction(19, ARM64Encoder.encodeSubImm12(rd: 2, rn: 29, imm12: 0x50))
        case "argumentClobber": try fixture.instruction(23, ARM64Encoder.encodeMovzW(rd: 3, imm16: 0))
        case "middleOfStub": try fixture.instruction(9, fixture.branch(9, target: CompilerCacheDriver.imports + 20))
        case "noReturn": try fixture.instruction(25, ARM64.nop)
        case "secondFunction": try fixture.instruction(18, ARM64.pacibsp)
        case "sharedLiteral", "sharedScheduledLiteral", "sharedLoad":
            try fixture.instruction(32, fixture.page(32, register: 8, target: CompilerCacheDriver.seeds[0]))
            if mutation == "sharedLoad" {
                try fixture.instruction(33, ARM64Encoder.encodeLdrBUnsignedOffset(rt: 9, rn: 8, offset: 0))
            } else {
                try fixture.instruction(mutation == "sharedLiteral" ? 33 : 34, ARM64Encoder.encodeAddImm12(rd: 8, rn: 8, imm12: 0))
            }
        default: Issue.record("Unknown fixture mutation")
        }
        try refusedWithoutChanges(&fixture)
    }

    private func refusedWithoutChanges(_ fixture: inout CompilerCacheDriver) throws {
        let original = fixture.data
        #expect(throws: PatcherError.self) { try CachePatcher.patch(&fixture.data, compilerPlugin: Self.plugin, log: nil) }
        #expect(fixture.data == original)
    }
}

@Suite("Mach-O branch symbol targets")
struct MachOSymbolTargetsTests {
    @Test func `Imports resolve only at stub starts`() throws {
        let fixture = try CompilerCacheDriver()
        let symbols = try #require(MachOSymbolTargets(data: fixture.data))
        #expect(symbols.importName(atStub: CompilerCacheDriver.base + UInt64(CompilerCacheDriver.imports + 16)) == "_CC_SHA256_Update")
        #expect(symbols.importName(atStub: CompilerCacheDriver.base + UInt64(CompilerCacheDriver.imports + 20)) == nil)
    }

    @Test(arguments: ["commandSize", "commandBounds", "sectionCount", "symbolCount", "strings", "indirect", "stubSize", "stubAddress"])
    func `Malformed load commands and tables refuse`(_ mutation: String) throws {
        var fixture = try CompilerCacheDriver()
        switch mutation {
        case "commandSize": fixture.put(1, at: CompilerCacheDriver.textCommand + 4)
        case "commandBounds": fixture.put(UInt32.max, at: 20)
        case "sectionCount": fixture.put(7, at: CompilerCacheDriver.textCommand + 64)
        case "symbolCount": fixture.put(UInt32.max, at: CompilerCacheDriver.symtabCommand + 12)
        case "strings": fixture.put(UInt32.max, at: CompilerCacheDriver.symtabCommand + 20)
        case "indirect": fixture.put(UInt32.max, at: CompilerCacheDriver.dysymtabCommand + 56)
        case "stubSize": fixture.put(0, at: CompilerCacheDriver.firstSection + 5 * 80 + 72)
        case "stubAddress": fixture.put64(UInt64.max - 1, at: CompilerCacheDriver.firstSection + 5 * 80 + 32)
        default: Issue.record("Unknown fixture mutation")
        }
        #expect(MachOSymbolTargets(data: fixture.data) == nil)
    }
}
