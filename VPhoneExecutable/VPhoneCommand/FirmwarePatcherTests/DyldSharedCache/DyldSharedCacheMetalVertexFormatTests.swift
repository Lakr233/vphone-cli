@testable import FirmwarePatcher
import CryptoKit
import Darwin
import Foundation
import Testing
import VPhonePatchKit

@_silgen_name("sys_icache_invalidate")
private func invalidateMetalVertexFormatTestCode(_ memory: UnsafeMutableRawPointer, _ count: Int)

@Suite("Metal serialized vertex ID formats")
struct DyldSharedCacheMetalVertexFormatTests {
    typealias Patcher = DyldSharedCacheMetalVertexFormatPatcher
    let base: UInt64 = 0x1000
    let formatStub: UInt64 = 0x3000

    /// Frozen from Metal in iOS 26.6.2 (23G90), serializer property 1. Only
    /// the BL displacements are relocated by the fixture. These words include
    /// the real authenticated C++ serializer dispatch, not a mock getter.
    func fixture() throws -> Data {
        let words: [UInt32] = [
            0xaa1803e0, 0x9408dea3, 0xaa0003fa, 0xaa1903e0,
            0x9408dea0, 0xaa0003e3, 0xf94002f0, 0xdac11b70,
            0xf8420e08, 0xaa1703e0, 0x52800021, 0xaa1a03e2,
            0xf2ee3070, 0xd73f0910,
        ]
        var result = words.reduce(into: Data()) { $0 += ARM64.encodeU32($1) }
        for offset in [4, 16] {
            result.replaceSubrange(offset ..< offset + 4, with:
                try #require(ARM64Encoder.encodeBL(from: Int(base) + offset, to: Int(formatStub))))
        }
        return result
    }

    func site(_ bytes: Data) throws -> Patcher.Site {
        try Patcher.findFormatSite(in: ARM64Disassembler().disassemble(bytes, at: base), formatStub: formatStub)
    }

    @Test func `finds the actual attribute format and rejects nearby lookalikes`() throws {
        let code = try fixture()
        let found = try site(code)
        #expect(found.address == base + 8)
        #expect(found.valueRegister == 26)
        #expect(found.existingCave == nil)

        var wrongProperty = code
        wrongProperty.replaceSubrange(40 ..< 44, with: try #require(ARM64Encoder.encodeMovzW(rd: 1, imm16: 2)))
        #expect(throws: (any Error).self) { try site(wrongProperty) }
        var wrongGetter = code
        wrongGetter.replaceSubrange(16 ..< 20, with: try #require(ARM64Encoder.encodeBL(from: Int(base) + 16, to: 0x4000)))
        #expect(throws: (any Error).self) { try site(wrongGetter) }
        var wrongValue = code
        wrongValue.replaceSubrange(44 ..< 48, with: ARM64Encoder.encodeMovX(rd: 2, rm: 25))
        #expect(throws: (any Error).self) { try site(wrongValue) }
        let twice = ARM64Disassembler().disassemble(code, at: base)
            + ARM64Disassembler().disassemble(code, at: base)
        #expect(throws: (any Error).self) { try Patcher.findFormatSite(in: twice, formatStub: formatStub) }
    }

    @Test func `plans in unused padding and accepts only its complete prior output`() throws {
        let code = try fixture()
        let found = try site(code)
        let padding: Range<UInt64> = 0x800 ..< 0x880
        var bytes = Data(repeating: 0, count: padding.count)
        bytes[0] = 1 // occupied bytes are never overwritten
        let first = try Patcher.plan(site: found, padding: padding) { at, count in
            Data(bytes[Int(at - padding.lowerBound) ..< Int(at - padding.lowerBound) + count])
        }
        #expect(first.cave == 0x804)
        #expect(first.program.count == 32)
        #expect(!first.alreadyPatched)

        var patched = code
        patched.replaceSubrange(8 ..< 12, with: first.branch)
        let patchedSite = try site(patched)
        #expect(patchedSite.existingCave == first.cave)
        bytes.replaceSubrange(4 ..< 36, with: first.program)
        let again = try Patcher.plan(site: patchedSite, padding: padding) { at, count in
            Data(bytes[Int(at - padding.lowerBound) ..< Int(at - padding.lowerBound) + count])
        }
        #expect(again.alreadyPatched)
        #expect(again.program == first.program)
        bytes[4] ^= 1
        #expect(throws: (any Error).self) {
            try Patcher.plan(site: patchedSite, padding: padding) { at, count in
                Data(bytes[Int(at - padding.lowerBound) ..< Int(at - padding.lowerBound) + count])
            }
        }
        #expect(throws: (any Error).self) {
            try Patcher.plan(site: found, padding: padding) { _, count in Data(repeating: 0xFF, count: count) }
        }
        let alien = Patcher.Site(address: found.address, valueRegister: 26, existingCave: 0x4000)
        #expect(throws: (any Error).self) {
            try Patcher.plan(site: alien, padding: padding) { _, count in Data(repeating: 0, count: count) }
        }
    }

    @Test func `header padding excludes all section bytes`() throws {
        // One LC_SEGMENT_64 containing one __text section.
        var header = Data(repeating: 0, count: 32 + 72 + 80)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        func name(_ string: String, at offset: Int) {
            header.replaceSubrange(offset ..< offset + string.utf8.count, with: string.utf8)
        }
        put(UInt32(0xFEED_FACF), at: 0)
        put(UInt32(1), at: 16)
        put(UInt32(152), at: 20)
        put(UInt32(0x19), at: 32)
        put(UInt32(152), at: 36)
        name("__TEXT", at: 40)
        put(base, at: 56)
        put(UInt64(0x1000), at: 64)
        put(UInt32(1), at: 96)
        name("__text", at: 104)
        name("__TEXT", at: 120)
        put(base + 0x200, at: 136)
        put(UInt64(0x100), at: 144)
        let padding = try Patcher.headerPadding(in: header, at: base)
        #expect(padding == base + UInt64(header.count) ..< base + 0x200)
        put(base + UInt64(header.count) + 16, at: 136)
        #expect(throws: (any Error).self) { try Patcher.headerPadding(in: header, at: base) }
    }

    enum FailurePoint: String, CaseIterable {
        case partialSecondWrite, partialReattestation, readback
    }

    enum InjectedFailure: Error { case operation, rollback }

    /// Two real cache pages and SHA-256 CodeDirectory slots, without symbols
    /// or a Mach-O image: transaction tests exercise the same ChunkSet writes,
    /// slot discovery and re-attestation used after production site discovery.
    func withTransactionCache(_ body: (DyldSharedCacheChunkSet, [DyldSharedCacheWriteSpan], Data) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metal-format-transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageSize = 0x4000
        let codeLimit = pageSize * 2
        let blobLength = 48 + 2 * 32
        let signatureLength = 20 + blobLength
        var bytes = Data(repeating: 0, count: codeLimit + signatureLength)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int, bigEndian: Bool = false) {
            var encoded = bigEndian ? value.bigEndian : value.littleEndian
            withUnsafeBytes(of: &encoded) { bytes.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        bytes.replaceSubrange(0 ..< 14, with: Data("dyld_v1  arm64e".utf8))
        put(UInt32(0x238), at: 0x10)
        put(UInt32(1), at: 0x14)
        put(UInt64(codeLimit), at: 0x28)
        put(UInt64(signatureLength), at: 0x30)
        put(base, at: 0x238)
        put(UInt64(codeLimit), at: 0x240)
        put(UInt64(0), at: 0x248)
        put(UInt32(5), at: 0x250)
        put(UInt32(5), at: 0x254)
        for (index, value) in [UInt32(0xFADE_0CC0), UInt32(signatureLength), 1, 0, 20].enumerated() {
            put(value, at: codeLimit + index * 4, bigEndian: true)
        }
        let cd = codeLimit + 20
        for (offset, value) in [(0, UInt32(0xFADE_0C02)), (4, UInt32(blobLength)), (8, 0x20400), (16, 48), (28, 2), (32, UInt32(codeLimit))] {
            put(value, at: cd + offset, bigEndian: true)
        }
        bytes[cd + 36] = 32
        bytes[cd + 37] = 2
        bytes[cd + 39] = 14
        for page in 0 ..< 2 {
            let hash = Data(SHA256.hash(data: bytes[page * pageSize ..< (page + 1) * pageSize]))
            bytes.replaceSubrange(cd + 48 + page * 32 ..< cd + 48 + (page + 1) * 32, with: hash)
        }
        let url = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try bytes.write(to: url)
        let chunks = try DyldSharedCacheChunkSet(directory: directory, captureUndo: true)
        let spans = [
            DyldSharedCacheWriteSpan(vma: base + 0x1000, length: 32),
            DyldSharedCacheWriteSpan(vma: base + 0x5000, length: 4),
        ]
        try body(chunks, spans, bytes)
    }

    @Test(arguments: FailurePoint.allCases)
    func `failed writes signing and readback restore the entire file exactly`(failure: FailurePoint) throws {
        try withTransactionCache { chunks, spans, original in
            let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
            #expect(snapshots.count == 4)
            #expect(snapshots.filter { $0.vma == nil }.count == 2)
            #expect(throws: InjectedFailure.self) {
                try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: "Metal vertex format patch") {
                    try chunks.write(at: spans[0].vma, Data(repeating: 0x55, count: spans[0].length))
                    if failure == .partialSecondWrite {
                        // Deliberately bypass ChunkSet's successful-write log:
                        // a write(2) failure can leave a partial range behind.
                        let (url, range) = try chunks.fileRange(of: spans[1])
                        try DyldSharedCachePatchTransaction.restore(.init(url: url, offset: range.lowerBound, original: Data([0xAA, 0xBB]), vma: nil))
                        throw InjectedFailure.operation
                    }
                    try chunks.write(at: spans[1].vma, Data(repeating: 0x66, count: spans[1].length))
                    if failure == .partialReattestation {
                        let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: [spans[0]], log: nil)
                        #expect(result.updated.count == 1)
                        throw InjectedFailure.operation
                    }
                    let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: nil)
                    #expect(result.updated.count == 2)
                    // Fault after signing, as a failed readback would occur.
                    throw InjectedFailure.operation
                }
            }
            #expect(try Data(contentsOf: chunks.mainCacheURL) == original)
        }
    }

    @Test func `rollback failure is explicit retains recovery records and restores other ranges`() throws {
        try withTransactionCache { chunks, spans, original in
            let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
            var failure: DyldSharedCachePatchRollbackError?
            do {
                try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: "Metal vertex format patch", restoring: { item in
                    if item.vma == spans[1].vma { throw InjectedFailure.rollback }
                    try DyldSharedCachePatchTransaction.restore(item)
                }) {
                    for span in spans { try chunks.write(at: span.vma, Data(repeating: 0x55, count: span.length)) }
                    _ = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: nil)
                    throw InjectedFailure.operation
                }
            } catch let error as DyldSharedCachePatchRollbackError {
                failure = error
            }
            let caught = try #require(failure)
            #expect(caught.localizedDescription.contains("Rollback failed"))
            #expect(caught.recoveryUndo.records.count == 2)
            #expect(caught.recoveryUndo.records.map(\.vma) == spans.map(\.vma))
            let bytes = try Data(contentsOf: chunks.mainCacheURL)
            #expect(bytes != original)
            for item in snapshots where item.vma != spans[1].vma {
                #expect(bytes[item.offset ..< item.offset + item.original.count] == item.original)
            }
            // The normal persisted-undo path can still recover the failed run.
            var recovery = caught.recoveryUndo
            recovery.stamp(patchID: "test-metal-format")
            let restored = try recovery.restore(patchIDs: recovery.patchIDs, in: chunks.directory)
            _ = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: restored, log: nil)
            #expect(try Data(contentsOf: chunks.mainCacheURL) == original)
        }
    }

    @Test func `missing hash coverage is rejected before any writes`() throws {
        try withTransactionCache { chunks, spans, _ in
            let handle = try FileHandle(forUpdating: chunks.mainCacheURL)
            try handle.seek(toOffset: 0x28)
            try handle.write(contentsOf: Data(repeating: 0, count: 16))
            try handle.close()
            let before = try Data(contentsOf: chunks.mainCacheURL)
            #expect(throws: (any Error).self) { try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks) }
            #expect(try Data(contentsOf: chunks.mainCacheURL) == before)
        }
    }

    #if arch(arm64)
    @Test func `native trampoline changes exactly 43 and 44 and preserves getter result`() throws {
        // Preserve the ABI's x26 around the generated code, recording both the
        // original getter result (x0) and wire value (x26) for each input.
        var code = ARM64Encoder.encodeMovX(rd: 10, rm: 26)
        code += try #require(ARM64Encoder.encodeB(from: 4, to: 24))
        code += try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 1, offset: 0))
        code += try #require(ARM64Encoder.encodeStrXUnsignedOffset(rt: 26, rn: 1, offset: 8))
        code += ARM64Encoder.encodeMovX(rd: 26, rm: 10)
        code += ARM64.ret
        code += try Patcher.trampoline(at: 24, returningTo: 8, valueRegister: 26)
        let memory = try #require(mmap(nil, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        try #require(memory != MAP_FAILED)
        defer { munmap(memory, 0x4000) }
        code.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: code.count)
        try #require(mprotect(memory, 0x4000, PROT_READ | PROT_EXEC) == 0)
        invalidateMetalVertexFormatTestCode(memory, code.count)
        typealias Function = @convention(c) (UInt64, UnsafeMutablePointer<UInt64>) -> Void
        let run = unsafeBitCast(memory, to: Function.self)
        let values = (0 ... 255).map(UInt64.init) + [1 << 32 | 43, 1 << 32 | 44, 1 << 63, .max]
        for value in values {
            var output: [UInt64] = [0, 0]
            output.withUnsafeMutableBufferPointer { run(value, $0.baseAddress!) }
            #expect(output[0] == value)
            #expect(output[1] == (value == 43 || value == 44 ? 36 : value))
        }
    }
    #endif
}
