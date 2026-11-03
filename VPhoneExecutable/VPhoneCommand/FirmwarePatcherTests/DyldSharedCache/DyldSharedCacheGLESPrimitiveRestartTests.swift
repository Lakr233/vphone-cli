@testable import FirmwarePatcher
import Darwin
import Foundation
import Testing
import VPhonePatchKit

@_silgen_name("sys_icache_invalidate")
private func invalidateGLESRestartTestCode(_ memory: UnsafeMutableRawPointer, _ count: Int)

@Suite("GLES primitive restart fallback")
struct DyldSharedCacheGLESPrimitiveRestartTests {
    typealias Patcher = DyldSharedCacheGLESPrimitiveRestartPatcher
    let entry: UInt64 = 0x2000

    // Original 23G90 renderer instructions, frozen as input evidence. Patch
    // replacements themselves are produced exclusively by ARM64Encoder.
    func entryFixture() -> Data {
        let words: [UInt32] = [
            0xd503237f, 0xd10303ff, 0xa9066ffc, 0xa90767fa,
            0xa9085ff8, 0xa90957f6, 0xa90a4ff4, 0xa90b7bfd,
            0x9102c3fd, 0xf940c408, 0xb4000748, 0xaa0003f3,
            0x9140041a, 0x394f6f49, 0x37003529, 0xaa0703f4,
            0xaa0603f8, 0xaa0503f9, 0xaa0403f5, 0xaa0303f7,
            0xaa0203f6, 0x3945e269, 0x721c093f, 0x54000060,
        ]
        return words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
    }

    func stateFixture() -> Data {
        let words: [UInt32] = [
            0xf9403408, 0x52878a89, 0x38696908, 0x7100011f,
            0x1a9f07e8, 0x52827b89, 0x38296808, 0xb949a808,
            0x32110108, 0xb909a808, 0xd65f03c0,
        ]
        return words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
    }

    func decode(_ data: Data) -> [ARM64Instruction] { ARM64Disassembler().disassemble(data, at: entry) }

    @Test func `recovers actual fields and rejects stale layouts`() throws {
        let fields = try Patcher.stateFields(in: decode(stateFixture()))
        #expect(fields == .init(pointerOffset: 0x68, enabledOffset: 0x3c54))
        let site = try Patcher.findEntry(in: decode(entryFixture()))
        #expect(site.address == entry)
        #expect(site.existingCave == nil)

        var relocated = stateFixture()
        relocated.replaceSubrange(0 ..< 4, with: try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 0, offset: 0x38)))
        relocated.replaceSubrange(4 ..< 8, with: try #require(ARM64Encoder.encodeMovzW(rd: 9, imm16: 0x2568)))
        #expect(try Patcher.stateFields(in: decode(relocated)) == .init(pointerOffset: 0x38, enabledOffset: 0x2568))
        var wrongBase = stateFixture()
        wrongBase.replaceSubrange(0 ..< 4, with: try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 1, offset: 0x68)))
        #expect(throws: (any Error).self) { try Patcher.stateFields(in: decode(wrongBase)) }
        var cachedInstead = stateFixture()
        cachedInstead.replaceSubrange(8 ..< 12, with: try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 0, offset: 0)))
        #expect(throws: (any Error).self) { try Patcher.stateFields(in: decode(cachedInstead)) }
        var wrongEntry = entryFixture()
        wrongEntry.replaceSubrange(0 ..< 4, with: ARM64.ret)
        #expect(throws: (any Error).self) { try Patcher.findEntry(in: decode(wrongEntry)) }
        wrongEntry = entryFixture()
        wrongEntry.replaceSubrange(20 * 4 ..< 21 * 4, with: ARM64.nop)
        #expect(throws: (any Error).self) { try Patcher.findEntry(in: decode(wrongEntry)) }
    }

    @Test func `admits only unused padding or its complete previous trampoline`() throws {
        let fields = try Patcher.stateFields(in: decode(stateFixture()))
        let site = try Patcher.findEntry(in: decode(entryFixture()))
        let padding: Range<UInt64> = 0x1000 ..< 0x1100
        var bytes = Data(repeating: 0, count: padding.count)
        bytes[0] = 1
        func read(_ at: UInt64, _ count: Int) -> Data {
            Data(bytes[Int(at - padding.lowerBound) ..< Int(at - padding.lowerBound) + count])
        }
        let plan = try Patcher.plan(site: site, fields: fields, padding: padding, read: read)
        #expect(plan.cave == 0x1004)
        #expect(plan.program.count == 68)
        #expect(!plan.alreadyPatched)
        bytes.replaceSubrange(4 ..< 4 + plan.program.count, with: plan.program)
        var patchedEntry = entryFixture()
        patchedEntry.replaceSubrange(0 ..< 4, with: plan.branch)
        let previous = try Patcher.findEntry(in: decode(patchedEntry))
        let again = try Patcher.plan(site: previous, fields: fields, padding: padding, read: read)
        #expect(again.alreadyPatched)
        #expect(again.program == plan.program)
        bytes[4] ^= 1
        #expect(throws: (any Error).self) { try Patcher.plan(site: previous, fields: fields, padding: padding, read: read) }
        #expect(throws: (any Error).self) {
            try Patcher.plan(site: .init(address: entry, existingCave: 0x4000), fields: fields, padding: padding, read: read)
        }
        #expect(throws: (any Error).self) {
            try Patcher.plan(site: site, fields: fields, padding: padding) { _, count in Data(repeating: 0xFF, count: count) }
        }
    }

    #if arch(arm64)
    @Test func `executes disabled indexed strip selection and authenticates both returns`() throws {
        // The original continuation returns 1; the new early fallback returns
        // 0. Execute real generated instructions for all primitive/flag/state
        // combinations, including noncanonical nonzero GLboolean values.
        let fields = Patcher.StateFields(pointerOffset: 0x18, enabledOffset: 0x2f)
        var code = try #require(ARM64Encoder.encodeB(from: 0, to: 0x100)) + ARM64.movW0_1 + ARM64.retab
        code += Data(repeating: 0, count: 0x100 - code.count)
        code += try Patcher.trampoline(at: 0x100, returningTo: 4, fields: fields)
        let memory = try #require(mmap(nil, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        try #require(memory != MAP_FAILED)
        defer { munmap(memory, 0x4000) }
        code.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: code.count)
        try #require(mprotect(memory, 0x4000, PROT_READ | PROT_EXEC) == 0)
        invalidateGLESRestartTestCode(memory, code.count)
        typealias Function = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> UInt32
        let run = unsafeBitCast(memory, to: Function.self)
        let context = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        let state = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { context.deallocate(); state.deallocate() }
        context.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        state.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        context.storeBytes(of: state, toByteOffset: Int(fields.pointerOffset), as: UnsafeMutableRawPointer.self)
        for enabled: UInt8 in [0, 1, 2, 255] {
            state.storeBytes(of: enabled, toByteOffset: Int(fields.enabledOffset), as: UInt8.self)
            for flags: UInt32 in [0, 1, 2, 3, 4, .max] {
                for mode: UInt32 in Array(0 ... 6) + [.max] {
                    let fallback = enabled == 0 && [1, 3].contains(flags) && [3, 5].contains(mode)
                    #expect(run(context, flags, mode) == (fallback ? 0 : 1))
                }
            }
        }
    }
    #endif
}
