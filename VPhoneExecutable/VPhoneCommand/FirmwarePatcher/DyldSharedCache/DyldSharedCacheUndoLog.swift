// DyldSharedCacheUndoLog.swift — The original bytes behind every dyld-shared-cache edit.
//
// The shared cache is several gigabytes, so turning a cache patch back off
// cannot mean keeping a pristine copy. It means knowing, byte for byte, what
// each patch overwrote. Before a `DyldSharedCacheChunkSet` writes, it reads the
// bytes it is about to replace and appends them here, tagged with the chunk
// file and the file offset they came from. A later run that finds a patch now
// deselected writes those bytes back where they were and re-attests the pages
// they land in, which is byte-for-byte the pristine cache for that patch.
//
// What this does NOT store is the re-attestation writes themselves — the slot
// hashes `DyldSharedCacheCodeSignature` rewrites after a content edit. Those are
// derived, not chosen: the slot hash of a 16 KiB page is the SHA-256 of the
// page. Two patches can land in one page, so restoring one patch's slot bytes
// to "pristine" while the other patch stays would write the wrong hash for a
// page that is not pristine. The correct inverse is therefore: put the content
// bytes back, then re-hash whatever the page now holds. Re-attesting the
// restored page reproduces the pristine slot hash exactly when (and only when)
// the page is now pristine, and the right non-pristine hash otherwise. So the
// undo log records content writes and leaves the slot hashes to be recomputed.
//
// A record is keyed by the patch identifier that wrote it, so a revert can act
// on one patch without disturbing another's bytes. An identifier with no
// records is a patch that wrote nothing — an idempotent no-op on an
// already-patched or self-gated cache — and reverting it is likewise nothing.
//
// Byte runs suit patches that write a few dozen sites. The X1 lowering writes
// 24.6 million instructions in 212,573 page runs; as runs that was 3.3 GB of
// originals, a 4.4 GB JSON file, and a 24.5 GB peak to encode it, which a
// 16 GB Mac swapped on for hours (issue #789). Such a patch keeps `words`
// instead: the address and original of each instruction it changed and nothing
// between them, 12 bytes apiece, in a binary file beside the JSON log
// (`.vphone-dsc-undo.words` beside `.vphone-dsc-undo.json`). The JSON format is
// unchanged, so an older CLI still reads every other patch's records.

import Foundation
import VPhonePatchKit

/// Every byte range a set of dyld-shared-cache patches overwrote, enough to put
/// the original bytes back for any subset of them.
public struct DyldSharedCacheUndoLog: Codable, Sendable, Hashable {
    /// One contiguous run of bytes a patch replaced, and what was there before.
    public struct Record: Codable, Sendable, Hashable {
        /// The patch declaration identifier whose write this was.
        public var patchID: String
        /// The chunk file, named relative to the cache directory
        /// (`dyld_shared_cache_arm64e`, `…​.01`, …) so the log stays valid when
        /// the cache directory is the same tree at a different absolute path.
        public var chunk: String
        /// Byte offset of the run within `chunk`.
        public var fileOffset: Int
        /// The virtual address the run starts at, for re-attestation.
        public var vma: UInt64
        /// The bytes that were there before the patch wrote. Base64 in JSON.
        public var original: Data

        public init(patchID: String, chunk: String, fileOffset: Int, vma: UInt64, original: Data) {
            self.patchID = patchID
            self.chunk = chunk
            self.fileOffset = fileOffset
            self.vma = vma
            self.original = original
        }

        private enum CodingKeys: String, CodingKey {
            case patchID = "PatchID"
            case chunk = "Chunk"
            case fileOffset = "FileOffset"
            case vma = "VMA"
            case original = "Original"
        }
    }

    /// One patch's originals, one 4-byte instruction each, in ascending address
    /// order with no address twice.
    public struct Words: Sendable, Hashable {
        public fileprivate(set) var addresses: [UInt64] = []
        public fileprivate(set) var originals: [UInt32] = []

        public init() {}

        public var count: Int {
            addresses.count
        }

        public var isEmpty: Bool {
            addresses.isEmpty
        }

        /// Append the original of the instruction at `vma`, which must be
        /// above every address already held.
        public mutating func append(vma: UInt64, original: UInt32) {
            precondition(addresses.last.map { $0 < vma } ?? true, "undo words must arrive in ascending address order")
            addresses.append(vma)
            originals.append(original)
        }

        /// Both sets of words; where both hold an address, this one's original
        /// wins, because it is the older and so the closer to pristine.
        func merging(_ newer: Words) -> Words {
            var merged = Words()
            merged.addresses.reserveCapacity(count + newer.count)
            merged.originals.reserveCapacity(count + newer.count)
            var mine = 0, theirs = 0
            while mine < count || theirs < newer.count {
                if theirs == newer.count || mine < count && addresses[mine] <= newer.addresses[theirs] {
                    if theirs < newer.count, addresses[mine] == newer.addresses[theirs] { theirs += 1 }
                    merged.append(vma: addresses[mine], original: originals[mine])
                    mine += 1
                } else {
                    merged.append(vma: newer.addresses[theirs], original: newer.originals[theirs])
                    theirs += 1
                }
            }
            return merged
        }
    }

    public var records: [Record]
    /// Word originals by patch identifier, stored beside the JSON log rather
    /// than in it. The empty identifier holds words not yet stamped.
    public var words: [String: Words] = [:]

    public init(records: [Record] = [], words: [String: Words] = [:]) {
        self.records = records
        self.words = words
    }

    private enum CodingKeys: String, CodingKey {
        case records = "Records"
    }

    /// Whether the log holds nothing to put back.
    public var isEmpty: Bool {
        records.isEmpty && words.values.allSatisfy(\.isEmpty)
    }

    // MARK: - Building

    /// Append a run, assuming it has not been recorded yet. The caller — a
    /// `DyldSharedCacheChunkSet` capturing a write — supplies everything but the
    /// identifier, which `stamp(patchID:)` fills once the patch is known.
    public mutating func capture(chunk: String, fileOffset: Int, vma: UInt64, original: Data) {
        records.append(Record(patchID: "", chunk: chunk, fileOffset: fileOffset, vma: vma, original: original))
    }

    /// Add word originals, unstamped like a captured run.
    public mutating func capture(words captured: Words) {
        guard !captured.isEmpty else { return }
        words[""] = words[""]?.merging(captured) ?? captured
    }

    /// Give every still-unstamped record and word this patch identifier. Called
    /// once per patcher invocation, because one invocation applies one declared
    /// patch.
    public mutating func stamp(patchID: String) {
        for index in records.indices where records[index].patchID.isEmpty {
            records[index].patchID = patchID
        }
        if let unstamped = words.removeValue(forKey: "") {
            words[patchID] = words[patchID]?.merging(unstamped) ?? unstamped
        }
    }

    /// The identifiers that have at least one recorded run or word.
    public var patchIDs: Set<String> {
        Set(records.map(\.patchID)).union(words.filter { !$0.value.isEmpty }.keys)
    }

    /// Fold `other`'s records in after this log's. A patch identifier present in
    /// both keeps both sides' runs; de-duplication is not needed because each
    /// run is a distinct (chunk, offset) a patch wrote exactly once per install.
    /// Words already held keep their originals.
    public mutating func merge(_ other: DyldSharedCacheUndoLog) {
        records.append(contentsOf: other.records)
        for (patchID, newer) in other.words {
            words[patchID] = words[patchID]?.merging(newer) ?? newer
        }
    }

    /// The log to store after a patch run for `patchID` captured `captured`, or
    /// nil when the stored log should be left exactly as it is.
    ///
    /// Nothing captured — an idempotent re-run over sites that already carry
    /// the patch, a self-gated no-op, or a dry run — returns nil, so the
    /// originals an earlier run recorded for the patch are kept. Without that a
    /// second install would forget how to revert every patch it found already
    /// applied.
    ///
    /// Something captured is merged in, not swapped in: a run can find some
    /// sites of a patch already written and write the rest, and only the new
    /// sites are captured. A record for a (chunk, offset) the log already has
    /// keeps the older original, which is the byte that was there before any
    /// run touched it.
    public static func updated(
        existing: DyldSharedCacheUndoLog?,
        captured: DyldSharedCacheUndoLog,
        patchID: String,
    ) -> DyldSharedCacheUndoLog? {
        var fresh = captured
        fresh.stamp(patchID: patchID)
        guard !fresh.isEmpty else { return nil }
        var merged = existing ?? DyldSharedCacheUndoLog()
        let known = Set(merged.records.map { "\($0.chunk)@\($0.fileOffset)" })
        merged.records.append(contentsOf: fresh.records.filter { !known.contains("\($0.chunk)@\($0.fileOffset)") })
        merged.merge(DyldSharedCacheUndoLog(words: fresh.words))
        return merged
    }

    /// Check every record against the cache in `directory` before anything is
    /// written: a plain chunk name, a regular file that is not a link, a
    /// non-negative offset, and a run that ends inside the file. One bad record
    /// refuses the whole log — a log that does not describe this cache must not
    /// half-revert it.
    public func validate(in directory: URL, patchIDs: Set<String>? = nil) throws {
        var sizes: [String: Int] = [:]
        for record in records where patchIDs?.contains(record.patchID) ?? true {
            guard !record.chunk.isEmpty, !record.chunk.contains("/"), record.chunk != ".", record.chunk != ".."
            else {
                throw DyldSharedCacheError.undoChunkOutsideCache(chunk: record.chunk)
            }
            let size: Int
            if let known = sizes[record.chunk] {
                size = known
            } else {
                var metadata = stat()
                let path = directory.appendingPathComponent(record.chunk).path
                guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                    throw DyldSharedCacheError.undoRecordInvalid(chunk: record.chunk, reason: "not a regular file beside the cache")
                }
                size = Int(metadata.st_size)
                sizes[record.chunk] = size
            }
            guard record.fileOffset >= 0, !record.original.isEmpty,
                  record.fileOffset <= size, record.original.count <= size - record.fileOffset
            else {
                throw DyldSharedCacheError.undoRecordInvalid(
                    chunk: record.chunk,
                    reason: "offset \(record.fileOffset) + \(record.original.count) bytes is outside the file (\(size) bytes)",
                )
            }
        }
    }

    /// This log without any record belonging to `patchIDs` — what remains after
    /// those patches are reverted and their runs no longer describe the cache.
    public func removing(patchIDs: Set<String>) -> DyldSharedCacheUndoLog {
        DyldSharedCacheUndoLog(
            records: records.filter { !patchIDs.contains($0.patchID) },
            words: words.filter { !patchIDs.contains($0.key) },
        )
    }

    /// The records belonging to any of `patchIDs`, newest write last so that a
    /// restore replays them in reverse and the earliest original wins when two
    /// runs of one patch overlap (they do not today, but order makes it safe).
    public func records(forPatchIDs patchIDs: Set<String>) -> [Record] {
        records.filter { patchIDs.contains($0.patchID) }
    }

    // MARK: - Serialisation

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DyldSharedCacheUndoLog {
        try JSONDecoder().decode(DyldSharedCacheUndoLog.self, from: data)
    }

    /// The JSON log in `data` with the words file in `words`, if there is one.
    public static func decode(_ data: Data, words: Data?) throws -> DyldSharedCacheUndoLog {
        var log = try decode(data)
        if let words {
            log.words = try decodeWords(words)
        }
        return log
    }

    /// The words file that belongs to the JSON log at `logPath`.
    public static func wordsPath(forLog logPath: String) -> String {
        ((logPath as NSString).deletingPathExtension as NSString).appendingPathExtension("words")!
    }

    /// The log at `url` with its words, or nil when neither file exists.
    public static func load(log url: URL) throws -> DyldSharedCacheUndoLog? {
        let json = try? Data(contentsOf: url)
        let words = try? Data(contentsOf: URL(fileURLWithPath: wordsPath(forLog: url.path)), options: .alwaysMapped)
        guard json != nil || words != nil else { return nil }
        var log = try json.map { try decode($0) } ?? DyldSharedCacheUndoLog()
        if let words {
            log.words = try decodeWords(words)
        }
        return log
    }

    /// Write the JSON log to `url` and the words beside it, and remove a words
    /// file the log no longer needs. The words go first: an interrupted write
    /// then leaves words for a patch the old JSON does not name yet, never JSON
    /// that relies on words that are not there.
    public func write(log url: URL) throws {
        let wordsURL = URL(fileURLWithPath: Self.wordsPath(forLog: url.path))
        if let words = encodedWords() {
            try words.write(to: wordsURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: wordsURL.path) {
            try FileManager.default.removeItem(at: wordsURL)
        }
        try encoded().write(to: url, options: .atomic)
    }

    static let wordsMagic = Data("VPDSCUW1".utf8)

    /// The words as a file, or nil when there are none: the magic, a UInt32
    /// patch count, then per patch a UInt16 identifier length, the UTF-8
    /// identifier, a UInt64 word count, every address as a UInt64 and every
    /// original as a UInt32. All little-endian; the arrays are copied as they
    /// lie in memory, which on an arm64 host is that.
    public func encodedWords() -> Data? {
        let stored = words.filter { !$0.key.isEmpty && !$0.value.isEmpty }.sorted { $0.key < $1.key }
        guard !stored.isEmpty else { return nil }
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        var data = Self.wordsMagic
        data.reserveCapacity(16 + stored.reduce(0) { $0 + 10 + $1.key.utf8.count + 12 * $1.value.count })
        append(UInt32(stored.count), to: &data)
        for (patchID, run) in stored {
            append(UInt16(patchID.utf8.count), to: &data)
            data.append(contentsOf: Array(patchID.utf8))
            append(UInt64(run.count), to: &data)
            run.addresses.withUnsafeBytes { data.append(contentsOf: $0) }
            run.originals.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeWords(_ data: Data) throws -> [String: Words] {
        func invalid(_ reason: String) -> DyldSharedCacheError {
            .undoRecordInvalid(chunk: "undo words", reason: reason)
        }
        var cursor = data.startIndex
        func take(_ length: Int) throws -> Range<Int> {
            guard length >= 0, length <= data.endIndex - cursor else { throw invalid("truncated") }
            defer { cursor += length }
            return cursor ..< cursor + length
        }
        func array<T: FixedWidthInteger>(of _: T.Type, count: Int) throws -> [T] {
            let range = try take(count * MemoryLayout<T>.size)
            return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                _ = data.copyBytes(to: buffer, from: range)
                initialized = count
            }
        }
        guard try data.subdata(in: take(wordsMagic.count)) == wordsMagic else { throw invalid("not an undo words file") }
        let patches = try data.loadLE(UInt32.self, at: take(4).lowerBound - data.startIndex)
        var words: [String: Words] = [:]
        for _ in 0 ..< patches {
            let length = try Int(data.loadLE(UInt16.self, at: take(2).lowerBound - data.startIndex))
            guard let patchID = try String(data: data.subdata(in: take(length)), encoding: .utf8),
                  !patchID.isEmpty, words[patchID] == nil
            else { throw invalid("bad or repeated patch identifier") }
            let declared = try data.loadLE(UInt64.self, at: take(8).lowerBound - data.startIndex)
            guard declared <= UInt64(data.endIndex - cursor) / 12 else { throw invalid("\(patchID): truncated") }
            var run = Words()
            run.addresses = try array(of: UInt64.self, count: Int(declared))
            run.originals = try array(of: UInt32.self, count: Int(declared))
            guard run.addresses.allSatisfy({ $0 % 4 == 0 }),
                  zip(run.addresses, run.addresses.dropFirst()).allSatisfy({ $0 < $1 })
            else { throw invalid("\(patchID): addresses are not ascending aligned instructions") }
            words[patchID] = run
        }
        guard cursor == data.endIndex else { throw invalid("trailing bytes") }
        return words
    }

    // MARK: - Converting

    /// This log with the runs of `patchIDs` held as words: every instruction
    /// whose original differs from what the cache in `directory` holds now,
    /// which is what the patch changed. Logs written before words existed hold
    /// the X1 lowering as page runs, gigabytes of originals for instructions it
    /// never touched. A run that is not whole aligned instructions stays a run.
    /// Nil when no run belongs to `patchIDs`.
    public func convertingRunsToWords(of patchIDs: Set<String>, in directory: URL) throws -> DyldSharedCacheUndoLog? {
        guard records.contains(where: { patchIDs.contains($0.patchID) }) else { return nil }
        try validate(in: directory, patchIDs: patchIDs)
        var kept: [Record] = []
        var changed: [String: [(vma: UInt64, original: UInt32)]] = [:]
        for record in records {
            guard patchIDs.contains(record.patchID), record.vma % 4 == 0, record.original.count % 4 == 0 else {
                kept.append(record)
                continue
            }
            let current = try DyldSharedCacheChunkSet.read(
                url: directory.appendingPathComponent(record.chunk),
                offset: UInt64(record.fileOffset),
                length: record.original.count,
            )
            for offset in stride(from: 0, to: record.original.count, by: 4) {
                let original = record.original.loadLE(UInt32.self, at: offset)
                if current.loadLE(UInt32.self, at: offset) != original {
                    changed[record.patchID, default: []].append((record.vma + UInt64(offset), original))
                }
            }
        }
        var converted = DyldSharedCacheUndoLog(records: kept, words: words)
        for (patchID, entries) in changed {
            // The sort is stable, so of two runs holding one address the
            // earlier, older original stays.
            var run = Words()
            for entry in entries.sorted(by: { $0.vma < $1.vma }) where run.addresses.last != entry.vma {
                run.append(vma: entry.vma, original: entry.original)
            }
            converted.merge(DyldSharedCacheUndoLog(words: [patchID: run]))
        }
        return converted
    }

    // MARK: - Restoring

    /// Put the original bytes of `patchIDs` back into the chunk files under
    /// `directory`, in reverse record order so an earlier write wins any
    /// overlap, then their words, one read and one write per 16 KiB page. The
    /// caller re-attests the touched pages afterwards; the returned spans are
    /// exactly what to re-attest, one per restored run or page.
    ///
    /// A record naming a chunk that is not under `directory`, or a word at an
    /// address the cache does not map, is refused before anything is written —
    /// the log is trusted only to describe the cache it sits beside.
    @discardableResult
    public func restore(
        patchIDs: Set<String>,
        in directory: URL,
        log: ((String) -> Void)? = nil,
    ) throws -> [DyldSharedCacheWriteSpan] {
        try validate(in: directory, patchIDs: patchIDs)
        let wordPatches = patchIDs.compactMap { id in words[id].flatMap { $0.isEmpty ? nil : (id, $0) } }
            .sorted { $0.0 < $1.0 }
        let chunks = try wordPatches.isEmpty ? nil : DyldSharedCacheChunkSet(directory: directory)
        var pages: [(patchID: String, run: Words, groups: [Range<Int>])] = []
        for (patchID, run) in wordPatches {
            var groups: [Range<Int>] = []
            var index = 0
            while index < run.count {
                let first = index
                while index < run.count, run.addresses[index] >> 14 == run.addresses[first] >> 14 {
                    index += 1
                }
                let start = run.addresses[first]
                _ = try chunks!.fileRange(of: .init(vma: start, length: Int(run.addresses[index - 1] + 4 - start)))
                groups.append(first ..< index)
            }
            pages.append((patchID, run, groups))
        }
        var spans: [DyldSharedCacheWriteSpan] = []
        var openChunk: String?, openHandle: FileHandle?
        defer { try? openHandle?.close() }
        for record in records(forPatchIDs: patchIDs).reversed() {
            let handle: FileHandle
            if openChunk == record.chunk, let existing = openHandle {
                handle = existing
            } else {
                try? openHandle?.close()
                handle = try FileHandle(forUpdating: directory.appendingPathComponent(record.chunk))
                openChunk = record.chunk; openHandle = handle
            }
            try handle.seek(toOffset: UInt64(record.fileOffset))
            try handle.write(contentsOf: record.original)
            spans.append(DyldSharedCacheWriteSpan(vma: record.vma, length: record.original.count))
            log?("      [+] revert: \(record.original.count) byte(s) at 0x"
                + String(record.vma, radix: 16, uppercase: true) + " in \(record.chunk) (\(record.patchID))")
        }
        for (patchID, run, groups) in pages {
            for group in groups {
                let start = run.addresses[group.lowerBound]
                var bytes = try chunks!.bytesAtVMA(start, length: Int(run.addresses[group.upperBound - 1] + 4 - start))
                for index in group {
                    let offset = Int(run.addresses[index] - start)
                    bytes.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(run.originals[index]))
                }
                try spans.append(chunks!.write(at: start, bytes))
            }
            log?("      [+] revert: \(run.count) instruction(s) in \(groups.count) page run(s) (\(patchID))")
        }
        return spans
    }
}

// MARK: - Earlier implementations

public extension DyldSharedCacheUndoLog {
    /// Patches whose implementation changed under the same identifier, and how
    /// a record written by an earlier one looks. A guest receipt only names the
    /// identifier, so without this an installed guest would keep the old bytes
    /// for good; `cfw install` and the environment update use it to revert the
    /// old records and apply the current implementation in the same run.
    ///
    /// `dyld-boot-iomfb_force_kern` first rewrote each swap trampoline's first
    /// instruction, one 4-byte record per entry point. It now writes a 16-byte
    /// conditional dispatcher per entry point, so a 4-byte record is the
    /// unconditional version, which leaves DeviceHub's capture display black.
    static let outdatedImplementations: [String: @Sendable (Record) -> Bool] = [
        "dyld-boot-iomfb_force_kern": { $0.original.count == 4 },
    ]

    /// Whether any record of `patchID` was written by an earlier
    /// implementation. False for a patch with no records, which cannot be
    /// reverted from this log anyway.
    func hasOutdatedImplementation(of patchID: String) -> Bool {
        guard let outdated = Self.outdatedImplementations[patchID] else { return false }
        return records(forPatchIDs: [patchID]).contains(where: outdated)
    }
}
