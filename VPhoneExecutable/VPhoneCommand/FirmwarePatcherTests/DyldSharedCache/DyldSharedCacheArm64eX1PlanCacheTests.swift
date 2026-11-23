import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

/// A one-chunk cache with real page slots, enough for the plan key, the
/// batched page runs and re-attestation.
private enum PlanCacheFixture {
    static let base: UInt64 = 0x1_8000_0000
    static let pageSize = 0x4000
    static let pages = 4
    static let codeLimit = pageSize * pages
    static let hashOffset = 0x30
    static let chunkName = "dyld_shared_cache_arm64e"

    /// A fresh directory by its canonical path, which a confined directory
    /// requires: the temporary directory lives behind the /var link.
    static func scratch(_ name: String) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &buffer) != nil else {
            throw POSIXError(.ENOENT)
        }
        let root = URL(fileURLWithPath: String(cString: buffer))
            .appending(path: "vphone_x1_plan_cache").appending(path: name)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    static func makeCache(at directory: URL) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: codeLimit)
        for index in 0x1000 ..< codeLimit { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 >> 3) }
        func put(_ value: some FixedWidthInteger, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { source in
                for (index, byte) in source.enumerated() { bytes[offset + index] = byte }
            }
        }
        for (index, byte) in Array("dyld_v1  arm64e".utf8).enumerated() { bytes[index] = byte }
        let mappingOffset = 0x238
        put(UInt32(mappingOffset), at: 0x10)
        put(UInt32(1), at: 0x14)
        put(base, at: mappingOffset)
        put(UInt64(codeLimit), at: mappingOffset + 8)
        put(UInt64(0), at: mappingOffset + 16)
        put(UInt32(5), at: mappingOffset + 24)
        put(UInt32(5), at: mappingOffset + 28)

        let blobLength = hashOffset + pages * 32
        var directoryBlob = Data(repeating: 0, count: blobLength)
        func putBE(_ value: UInt32, at offset: Int) {
            for (index, byte) in withUnsafeBytes(of: value.bigEndian, Array.init).enumerated() {
                directoryBlob[offset + index] = byte
            }
        }
        putBE(0xFADE_0C02, at: 0)
        putBE(UInt32(blobLength), at: 4)
        putBE(0x0002_0400, at: 8)
        putBE(UInt32(hashOffset), at: 16)
        putBE(UInt32(pages), at: 28)
        putBE(UInt32(codeLimit), at: 32)
        directoryBlob[36] = 32
        directoryBlob[37] = 2
        directoryBlob[39] = 14
        var signature = Data()
        for value: UInt32 in [0xFADE_0CC0, UInt32(20 + blobLength), 1, 0, 20] {
            signature += withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        put(UInt64(codeLimit), at: 0x28)
        put(UInt64(signature.count + blobLength), at: 0x30)
        for page in 0 ..< pages {
            let start = page * pageSize
            let hash = Data(SHA256.hash(data: Data(bytes[start ..< start + pageSize])))
            directoryBlob.replaceSubrange(hashOffset + page * 32 ..< hashOffset + page * 32 + 32, with: hash)
        }
        let chunk = directory.appending(path: chunkName)
        try (Data(bytes) + signature + directoryBlob).write(to: chunk)
        return chunk
    }

    /// The stored slot of `page`, and what the page hashes to now.
    static func slot(_ page: Int, in chunk: URL) throws -> (stored: Data, actual: Data) {
        let file = try Data(contentsOf: chunk)
        let slot = codeLimit + 20 + hashOffset + page * 32
        let actual = Data(SHA256.hash(data: file[page * pageSize ..< (page + 1) * pageSize]))
        return (file[slot ..< slot + 32], actual)
    }
}

@Suite("X1 plan cache")
struct DyldSharedCacheArm64eX1PlanCacheTests {
    typealias Cache = DyldSharedCacheArm64eX1PlanCache

    static let paths = ["/usr/lib/libA.dylib", "/usr/lib/libB.dylib", "/usr/lib/libC.dylib"]
    static let images: [Cache.Image] = [
        .planned(.init(writes: [
            .init(address: 0x1_8000_1000, word: 0xD503_233F),
            .init(address: 0x1_8000_1004, word: 0xD65F_0BFF),
            .init(address: 0x1_8004_0000, word: 0x9100_03FD),
        ], unvisitedCandidates: 7)),
        .skipped("X1 cache image has no function starts"),
        .planned(.init(writes: [], unvisitedCandidates: 0)),
    ]

    static func flattened(_ images: [Cache.Image]) -> [String] {
        images.map { image in
            switch image {
            case let .planned(plan):
                "planned \(plan.unvisitedCandidates) " + plan.writes.map { "\($0.address):\($0.word)" }.joined(separator: ",")
            case let .skipped(reason):
                "skipped \(reason)"
            }
        }
    }

    @Test func `a plan comes back as it was stored`() throws {
        let file = try #require(Cache.encode(Self.images, paths: Self.paths))
        let decoded = try #require(Cache.decode(file, paths: Self.paths))
        #expect(Self.flattened(decoded) == Self.flattened(Self.images))
    }

    @Test func `a plan for other images, another format or damaged bytes is a miss`() throws {
        let file = try #require(Cache.encode(Self.images, paths: Self.paths))
        #expect(Cache.decode(file, paths: Array(Self.paths.reversed())) == nil)
        #expect(Cache.decode(file, paths: Array(Self.paths.prefix(2))) == nil)
        var version = file
        version[Cache.magic.count] &+= 1
        #expect(Cache.decode(version, paths: Self.paths) == nil)
        #expect(Cache.decode(file.prefix(file.count - 9), paths: Self.paths) == nil)
    }

    @Test func `writes out of address order are not stored`() {
        let images: [Cache.Image] = [.planned(.init(writes: [
            .init(address: 0x2000, word: 1), .init(address: 0x1000, word: 2),
        ], unvisitedCandidates: 0))]
        #expect(Cache.encode(images, paths: ["/a"]) == nil)
    }

    @Test func `a stored plan loads by its key`() throws {
        let root = try PlanCacheFixture.scratch("store").appending(path: "plans")
        let cache = Cache(root: root)
        #expect(try cache.load(key: "absent", paths: Self.paths) == nil)
        #expect(try cache.store(Self.images, paths: Self.paths, key: "k"))
        let loaded = try #require(try cache.load(key: "k", paths: Self.paths))
        #expect(Self.flattened(loaded) == Self.flattened(Self.images))
    }

    @Test func `the key follows the signed pages, the patch and nothing else`() throws {
        let directory = try PlanCacheFixture.scratch("key")
        try PlanCacheFixture.makeCache(at: directory)
        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        let key = try Cache.key(for: chunks, patchID: "remaining")
        #expect(try Cache.key(for: chunks, patchID: "remaining") == key)
        #expect(try Cache.key(for: chunks, patchID: "bootstrap") != key)

        // A file in the directory with no mapping is not read by the planner.
        try Data("atlas".utf8).write(to: directory.appending(path: PlanCacheFixture.chunkName + ".atlas"))
        #expect(try Cache.key(for: DyldSharedCacheChunkSet(directory: directory), patchID: "remaining") == key)

        // A written and re-attested page changes its slot, and so the key.
        let written = try DyldSharedCacheChunkSet(directory: directory)
        try written.write(at: PlanCacheFixture.base + 0x5000, Data([1, 2, 3, 4]))
        try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: written, log: nil)
        #expect(try Cache.key(for: DyldSharedCacheChunkSet(directory: directory), patchID: "remaining") != key)
    }
}

@Suite("Batched page runs and re-attestation")
struct DyldSharedCacheBatchedPageRunTests {
    @Test func `a batch reads back its own writes and records them`() throws {
        let directory = try PlanCacheFixture.scratch("batch")
        let chunk = try PlanCacheFixture.makeCache(at: directory)
        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        let site = PlanCacheFixture.base + 0x4010
        let before = try chunks.bytesAtVMA(site, length: 8)
        try chunks.withBatch { batch in
            #expect(try batch.bytesAtVMA(site, length: 8) == before)
            try batch.write(at: site, Data([0xAA, 0xBB, 0xCC, 0xDD]))
            // Served from the block read ahead before the write.
            #expect(try batch.bytesAtVMA(site, length: 8) == Data([0xAA, 0xBB, 0xCC, 0xDD]) + before.suffix(4))
        }
        #expect(try Data(contentsOf: chunk)[0x4010 ..< 0x4014] == Data([0xAA, 0xBB, 0xCC, 0xDD]))
        #expect(chunks.recordedWrites == [DyldSharedCacheWriteSpan(vma: site, length: 4)])
    }

    @Test func `re-attestation stores every dirty page and only those`() throws {
        let directory = try PlanCacheFixture.scratch("reattest")
        let chunk = try PlanCacheFixture.makeCache(at: directory)
        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        // Pages 1 and 3, not adjacent, so the slot table is written in two runs.
        try chunks.write(at: PlanCacheFixture.base + 0x4100, Data([9, 9, 9, 9]))
        try chunks.write(at: PlanCacheFixture.base + 0xC100, Data([7, 7, 7, 7]))
        let untouched = try PlanCacheFixture.slot(2, in: chunk).stored

        var lines: [String] = []
        let result = try DyldSharedCacheCodeSignature.reattestRecordedWrites(
            in: chunks, logsEachSlot: false, log: { lines.append($0) },
        )
        #expect(result.updated.map(\.pageIndex) == [1, 3])
        #expect(result.isFullyAttested)
        for page in 0 ..< PlanCacheFixture.pages {
            let slot = try PlanCacheFixture.slot(page, in: chunk)
            #expect(slot.stored == slot.actual)
        }
        #expect(try PlanCacheFixture.slot(2, in: chunk).stored == untouched)
        #expect(lines.count == 1 && lines[0].contains("updated 2 slot hash(es)"))

        // A second run finds both pages attested and writes nothing.
        let again = try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks, log: nil)
        #expect(again.updated.isEmpty)
        #expect(again.alreadyAttested.map(\.pageIndex) == [1, 3])
    }
}
