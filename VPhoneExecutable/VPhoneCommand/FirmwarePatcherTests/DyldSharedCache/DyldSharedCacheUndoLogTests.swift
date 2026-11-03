// DyldSharedCacheUndoLogTests.swift — The dyld-cache undo log, over a synthetic buffer.
//
// The undo log records the original bytes behind each cache edit so a later run
// can put them back for a patch turned off. These tests do not need the 6.7 GB
// cache: they build chunk-sized files in a temp directory, "patch" a range by
// writing over it while recording the original, then restore and assert the
// bytes are back. Idempotence — patching an already-patched range records
// nothing — is checked at the record level, which is where the live chunk set
// skips a no-op write.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Dyld shared cache undo log")
struct DyldSharedCacheUndoLogTests {
    /// A temp directory with one "chunk" file of known bytes, cleaned up after.
    private func withChunk(
        name: String = "dyld_shared_cache_arm64e",
        bytes: [UInt8],
        _ body: (URL, URL) throws -> Void,
    ) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = dir.appendingPathComponent(name)
        try Data(bytes).write(to: chunk)
        try body(dir, chunk)
    }

    /// Overwrite `[offset, offset+patched.count)` and return the original bytes.
    private func overwrite(_ url: URL, offset: Int, patched: [UInt8]) throws -> Data {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let original = try handle.read(upToCount: patched.count) ?? Data()
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(patched))
        return original
    }

    @Test
    func `Restore puts the original bytes back for the named patch`() throws {
        try withChunk(bytes: Array(0 ..< 64)) { dir, chunk in
            let original = try overwrite(chunk, offset: 16, patched: [0xAA, 0xBB, 0xCC, 0xDD])

            var log = DyldSharedCacheUndoLog()
            log.capture(chunk: chunk.lastPathComponent, fileOffset: 16, vma: 0x10000, original: original)
            log.stamp(patchID: "dyld-boot-example")

            // The range reads as the patched bytes before the revert.
            #expect(try Data(contentsOf: chunk)[16 ..< 20] == Data([0xAA, 0xBB, 0xCC, 0xDD]))

            let spans = try log.restore(patchIDs: ["dyld-boot-example"], in: dir)
            #expect(spans.count == 1)
            #expect(spans.first?.vma == 0x10000)
            #expect(spans.first?.length == 4)

            // And the original 16,17,18,19 are back.
            #expect(try Data(contentsOf: chunk)[16 ..< 20] == Data([16, 17, 18, 19]))
        }
    }

    @Test
    func `Restore touches only the named patch`() throws {
        try withChunk(bytes: Array(repeating: 0, count: 64)) { dir, chunk in
            let a = try overwrite(chunk, offset: 0, patched: [1, 1, 1, 1])
            let b = try overwrite(chunk, offset: 32, patched: [2, 2, 2, 2])
            var log = DyldSharedCacheUndoLog()
            log.capture(chunk: chunk.lastPathComponent, fileOffset: 0, vma: 0x1000, original: a)
            log.stamp(patchID: "patch-a")
            var logB = DyldSharedCacheUndoLog()
            logB.capture(chunk: chunk.lastPathComponent, fileOffset: 32, vma: 0x2000, original: b)
            logB.stamp(patchID: "patch-b")
            log.merge(logB)

            try log.restore(patchIDs: ["patch-a"], in: dir)
            let data = try Data(contentsOf: chunk)
            #expect(data[0 ..< 4] == Data([0, 0, 0, 0]), "patch-a reverted")
            #expect(data[32 ..< 36] == Data([2, 2, 2, 2]), "patch-b untouched")

            #expect(log.patchIDs == ["patch-a", "patch-b"])
            #expect(log.removing(patchIDs: ["patch-a"]).patchIDs == ["patch-b"])
        }
    }

    @Test
    func `Restore is idempotent`() throws {
        try withChunk(bytes: Array(0 ..< 32)) { dir, chunk in
            let original = try overwrite(chunk, offset: 8, patched: [0xFF, 0xFF])
            var log = DyldSharedCacheUndoLog()
            log.capture(chunk: chunk.lastPathComponent, fileOffset: 8, vma: 0x4000, original: original)
            log.stamp(patchID: "p")

            try log.restore(patchIDs: ["p"], in: dir)
            let afterFirst = try Data(contentsOf: chunk)
            try log.restore(patchIDs: ["p"], in: dir)
            let afterSecond = try Data(contentsOf: chunk)
            #expect(afterFirst == afterSecond)
            #expect(afterFirst[8 ..< 10] == Data([8, 9]))
        }
    }

    @Test
    func `A plist round-trips through encode and decode`() throws {
        var log = DyldSharedCacheUndoLog()
        log.capture(chunk: "dyld_shared_cache_arm64e.01", fileOffset: 0x2000, vma: 0x18000, original: Data([1, 2, 3, 4, 5]))
        log.stamp(patchID: "dyld-cfw-camera")
        let decoded = try DyldSharedCacheUndoLog.decode(log.encoded())
        #expect(decoded == log)
        #expect(decoded.records.first?.original == Data([1, 2, 3, 4, 5]))
        #expect(decoded.records.first?.patchID == "dyld-cfw-camera")
    }

    @Test
    func `Stamp only fills records that have no identifier yet`() {
        var log = DyldSharedCacheUndoLog()
        log.capture(chunk: "c", fileOffset: 0, vma: 0, original: Data([0]))
        log.stamp(patchID: "first")
        log.capture(chunk: "c", fileOffset: 1, vma: 1, original: Data([1]))
        log.stamp(patchID: "second")
        #expect(log.records(forPatchIDs: ["first"]).count == 1)
        #expect(log.records(forPatchIDs: ["second"]).count == 1)
    }

    @Test
    func `A chunk name with a path separator is refused`() throws {
        try withChunk(bytes: [0, 0, 0, 0]) { dir, _ in
            var log = DyldSharedCacheUndoLog()
            log.capture(chunk: "../escape", fileOffset: 0, vma: 0, original: Data([9]))
            log.stamp(patchID: "p")
            #expect(throws: DyldSharedCacheError.self) {
                try log.restore(patchIDs: ["p"], in: dir)
            }
        }
    }

    // MARK: - updated (the merge rule a re-run uses)

    @Test
    func `An empty capture keeps the stored records for the patch`() {
        var existing = DyldSharedCacheUndoLog()
        existing.capture(chunk: "c", fileOffset: 0, vma: 0x1000, original: Data([1, 2]))
        existing.stamp(patchID: "p")
        // An idempotent re-run captured nothing: the log must be left as it is,
        // not emptied — nil means "do not write".
        let updated = DyldSharedCacheUndoLog.updated(existing: existing, captured: DyldSharedCacheUndoLog(), patchID: "p")
        #expect(updated == nil)
    }

    @Test
    func `A capture of new sites merges without dropping the old`() {
        var existing = DyldSharedCacheUndoLog()
        existing.capture(chunk: "c", fileOffset: 0, vma: 0x1000, original: Data([1]))
        existing.stamp(patchID: "p")
        var captured = DyldSharedCacheUndoLog()
        captured.capture(chunk: "c", fileOffset: 16, vma: 0x1010, original: Data([2]))
        let updated = DyldSharedCacheUndoLog.updated(existing: existing, captured: captured, patchID: "p")
        #expect(updated?.records.count == 2)
        #expect(updated?.records(forPatchIDs: ["p"]).count == 2)
    }

    @Test
    func `A re-capture of a known site keeps the earliest original`() {
        var existing = DyldSharedCacheUndoLog()
        existing.capture(chunk: "c", fileOffset: 8, vma: 0x2000, original: Data([0xAA]))
        existing.stamp(patchID: "p")
        var captured = DyldSharedCacheUndoLog()
        // Same (chunk, offset) as the stored record: the earlier original wins.
        captured.capture(chunk: "c", fileOffset: 8, vma: 0x2000, original: Data([0xBB]))
        let updated = DyldSharedCacheUndoLog.updated(existing: existing, captured: captured, patchID: "p")
        #expect(updated?.records.count == 1)
        #expect(updated?.records.first?.original == Data([0xAA]))
    }

    // MARK: - validate (item 9)

    @Test
    func `Validate refuses a record that runs past the chunk`() throws {
        try withChunk(bytes: Array(repeating: 0, count: 16)) { dir, chunk in
            var log = DyldSharedCacheUndoLog()
            log.capture(chunk: chunk.lastPathComponent, fileOffset: 12, vma: 0, original: Data([1, 2, 3, 4, 5, 6, 7, 8]))
            log.stamp(patchID: "p")
            #expect(throws: DyldSharedCacheError.self) {
                try log.validate(in: dir)
            }
        }
    }

    @Test
    func `Validate refuses a chunk that is not a file beside the cache`() throws {
        try withChunk(bytes: [0, 0, 0, 0]) { dir, _ in
            var log = DyldSharedCacheUndoLog()
            log.capture(chunk: "does_not_exist", fileOffset: 0, vma: 0, original: Data([1]))
            log.stamp(patchID: "p")
            #expect(throws: DyldSharedCacheError.self) {
                try log.validate(in: dir)
            }
        }
    }

    @Test
    func `Validate accepts a record that fits`() throws {
        try withChunk(bytes: Array(0 ..< 32)) { dir, chunk in
            var log = DyldSharedCacheUndoLog()
            log.capture(chunk: chunk.lastPathComponent, fileOffset: 28, vma: 0, original: Data([1, 2, 3, 4]))
            log.stamp(patchID: "p")
            try log.validate(in: dir) // does not throw
        }
    }
}

@Suite("Dyld shared cache undo words")
struct DyldSharedCacheUndoWordsTests {
    static let base: UInt64 = 0x1_8000_0000

    private func words(_ entries: [(UInt64, UInt32)]) -> DyldSharedCacheUndoLog.Words {
        var words = DyldSharedCacheUndoLog.Words()
        for (vma, original) in entries {
            words.append(vma: vma, original: original)
        }
        return words
    }

    /// A two-page cache whose one mapping puts file offset 0 at `base`, with
    /// every word past the header holding its own file offset.
    private func withCache(_ body: (URL, URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undo-words-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = Data(count: 0x8000)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        for offset in stride(from: 0x400, to: 0x8000, by: 4) {
            put(UInt32(offset), at: offset)
        }
        bytes.replaceSubrange(0 ..< 15, with: Data("dyld_v1  arm64e".utf8))
        put(UInt32(0x238), at: 0x10)
        put(UInt32(1), at: 0x14)
        put(Self.base, at: 0x238)
        put(UInt64(0x8000), at: 0x240)
        put(UInt64(0), at: 0x248)
        put(UInt32(5), at: 0x250)
        put(UInt32(5), at: 0x254)
        put(Self.base, at: 0xE0)
        put(UInt64(0x8000), at: 0xE8)
        let chunk = dir.appendingPathComponent("dyld_shared_cache_arm64e")
        try bytes.write(to: chunk)
        try body(dir, chunk)
    }

    private func word(in chunk: URL, at offset: Int) throws -> UInt32 {
        try Data(contentsOf: chunk).loadLE(UInt32.self, at: offset)
    }

    private func overwrite(_ chunk: URL, at offsets: [Int], with bytes: [UInt8]) throws {
        let handle = try FileHandle(forUpdating: chunk)
        defer { try? handle.close() }
        for offset in offsets {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: Data(bytes))
        }
    }

    @Test
    func `Merging keeps addresses ascending and the older original`() {
        let older = words([(0x10, 1), (0x20, 2)])
        let newer = words([(0x08, 7), (0x20, 9), (0x30, 3)])
        let merged = older.merging(newer)
        #expect(merged.addresses == [0x08, 0x10, 0x20, 0x30])
        #expect(merged.originals == [7, 1, 2, 3])
    }

    @Test
    func `Captured words take the identifier they are stamped with`() {
        var log = DyldSharedCacheUndoLog()
        log.capture(words: words([(0x10, 1)]))
        #expect(log.patchIDs == [""])
        log.stamp(patchID: "x1")
        #expect(log.patchIDs == ["x1"])
        #expect(log.words["x1"]?.originals == [1])
        #expect(log.removing(patchIDs: ["x1"]).isEmpty)
    }

    @Test
    func `A re-run merges new words and keeps the stored originals`() throws {
        let existing = DyldSharedCacheUndoLog(words: ["x1": words([(0x10, 1)])])
        var captured = DyldSharedCacheUndoLog()
        captured.capture(words: words([(0x10, 5), (0x14, 2)]))
        let updated = try #require(DyldSharedCacheUndoLog.updated(existing: existing, captured: captured, patchID: "x1"))
        #expect(updated.words["x1"]?.addresses == [0x10, 0x14])
        #expect(updated.words["x1"]?.originals == [1, 2])
        #expect(DyldSharedCacheUndoLog.updated(existing: existing, captured: .init(), patchID: "x1") == nil)
    }

    @Test
    func `The words file sits beside the JSON log`() {
        #expect(DyldSharedCacheUndoLog.wordsPath(forLog: "a/b/.vphone-dsc-undo.json") == "a/b/.vphone-dsc-undo.words")
    }

    @Test
    func `A log writes words beside its JSON and loads them back`() throws {
        try withCache { dir, _ in
            let url = dir.appendingPathComponent(".vphone-dsc-undo.json")
            var log = DyldSharedCacheUndoLog(words: ["x1": words([(Self.base + 0x4000, 0xD503_201F)])])
            log.capture(chunk: "dyld_shared_cache_arm64e", fileOffset: 0x4100, vma: Self.base + 0x4100, original: Data([1, 2]))
            log.stamp(patchID: "other")
            try log.write(log: url)
            #expect(try DyldSharedCacheUndoLog.load(log: url) == log)
            // The JSON alone is what an older CLI reads: the words are not in it.
            #expect(try DyldSharedCacheUndoLog.decode(Data(contentsOf: url)).words.isEmpty)

            // A log left without words removes the file.
            try log.removing(patchIDs: ["x1"]).write(log: url)
            #expect(!FileManager.default.fileExists(atPath: DyldSharedCacheUndoLog.wordsPath(forLog: url.path)))
        }
    }

    @Test
    func `A damaged words file is refused`() throws {
        let log = DyldSharedCacheUndoLog(words: ["x1": words([(0x10, 1), (0x14, 2)])])
        let data = try #require(log.encodedWords())
        #expect(try DyldSharedCacheUndoLog.decodeWords(data) == log.words)
        #expect(throws: DyldSharedCacheError.self) { try DyldSharedCacheUndoLog.decodeWords(data.dropLast()) }
        #expect(throws: DyldSharedCacheError.self) { try DyldSharedCacheUndoLog.decodeWords(data + Data([0])) }
        // The two addresses swapped.
        var unordered = data
        let first = unordered.count - 8 - 16
        let swapped = unordered.subdata(in: first + 8 ..< first + 16) + unordered.subdata(in: first ..< first + 8)
        unordered.replaceSubrange(first ..< first + 16, with: swapped)
        #expect(throws: DyldSharedCacheError.self) { try DyldSharedCacheUndoLog.decodeWords(unordered) }
    }

    @Test
    func `Restoring words puts back only those instructions, page by page`() throws {
        try withCache { dir, chunk in
            let sites = [0x3000, 0x4010, 0x4020]
            try overwrite(chunk, at: sites, with: [0x1F, 0x20, 0x03, 0xD5])
            // Between two sites, an unrelated write the words must not touch.
            try overwrite(chunk, at: [0x4018], with: [0xAA, 0xAA, 0xAA, 0xAA])
            var log = DyldSharedCacheUndoLog()
            log.capture(words: words(sites.map { (Self.base + UInt64($0), UInt32($0)) }))
            log.stamp(patchID: "x1")

            let spans = try log.restore(patchIDs: ["x1"], in: dir)
            #expect(spans.map(\.vma) == [Self.base + 0x3000, Self.base + 0x4010])
            #expect(spans.map(\.length) == [4, 0x14])
            for site in sites {
                #expect(try word(in: chunk, at: site) == UInt32(site))
            }
            #expect(try word(in: chunk, at: 0x4018) == 0xAAAA_AAAA)
        }
    }

    @Test
    func `A word the cache does not map refuses the whole restore`() throws {
        try withCache { dir, chunk in
            try overwrite(chunk, at: [0x4010], with: [0, 0, 0, 0])
            let log = DyldSharedCacheUndoLog(words: ["x1": words([(Self.base + 0x4010, 0x4010), (Self.base + 0x9000, 0)])])
            #expect(throws: DyldSharedCacheError.self) { try log.restore(patchIDs: ["x1"], in: dir) }
            #expect(try word(in: chunk, at: 0x4010) == 0)
        }
    }

    @Test
    func `Page runs from an older log become the words that differ`() throws {
        try withCache { dir, chunk in
            let name = chunk.lastPathComponent
            let pristine = try Data(contentsOf: chunk)
            try overwrite(chunk, at: [0x4004, 0x400C], with: [0x1F, 0x20, 0x03, 0xD5])
            let run = DyldSharedCacheUndoLog.Record(
                patchID: "x1", chunk: name, fileOffset: 0x4000, vma: Self.base + 0x4000,
                original: pristine.subdata(in: 0x4000 ..< 0x4010),
            )
            let odd = DyldSharedCacheUndoLog.Record(
                patchID: "x1", chunk: name, fileOffset: 0x4101, vma: Self.base + 0x4101, original: Data([1, 2, 3]),
            )
            let other = DyldSharedCacheUndoLog.Record(
                patchID: "other", chunk: name, fileOffset: 0x5000, vma: Self.base + 0x5000, original: Data([1, 2, 3, 4]),
            )
            let log = DyldSharedCacheUndoLog(records: [run, odd, other])

            let converted = try #require(try log.convertingRunsToWords(of: ["x1"], in: dir))
            #expect(converted.records == [odd, other])
            #expect(converted.words["x1"]?.addresses == [Self.base + 0x4004, Self.base + 0x400C])
            #expect(converted.words["x1"]?.originals == [0x4004, 0x400C])
            #expect(try converted.convertingRunsToWords(of: ["x2"], in: dir) == nil)

            try converted.restore(patchIDs: ["x1"], in: dir)
            #expect(try Data(contentsOf: chunk).subdata(in: 0x4000 ..< 0x4010) == pristine.subdata(in: 0x4000 ..< 0x4010))
        }
    }
}

@Suite("Dyld patches whose implementation changed")
struct DyldSharedCacheOutdatedImplementationTests {
    private func record(_ id: String, bytes: Int, offset: Int = 0) -> DyldSharedCacheUndoLog.Record {
        .init(patchID: id, chunk: "dyld_shared_cache_arm64e", fileOffset: offset, vma: 0x1_8000_0000, original: Data(count: bytes))
    }

    @Test func `The unconditional force-kern records are an earlier implementation`() {
        let id = "dyld-boot-iomfb_force_kern"
        let old = DyldSharedCacheUndoLog(records: (0 ..< 31).map { record(id, bytes: 4, offset: $0 * 64) })
        #expect(old.hasOutdatedImplementation(of: id))
        let current = DyldSharedCacheUndoLog(records: (0 ..< 10).map { record(id, bytes: 16, offset: $0 * 64) })
        #expect(!current.hasOutdatedImplementation(of: id))
    }

    @Test func `Patches without a recorded change, or without records, are never outdated`() {
        let log = DyldSharedCacheUndoLog(records: [record("dyld-boot-maxslide", bytes: 4)])
        #expect(!log.hasOutdatedImplementation(of: "dyld-boot-maxslide"))
        #expect(!log.hasOutdatedImplementation(of: "dyld-boot-iomfb_force_kern"))
        #expect(!DyldSharedCacheUndoLog().hasOutdatedImplementation(of: "dyld-boot-iomfb_force_kern"))
    }
}
