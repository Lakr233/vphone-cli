// DyldSharedCacheChunkSet.swift — Flat virtual-address access over a chunked dyld shared cache.
//
// The iOS 26/27 SystemOS cryptex ships the shared cache as many files:
//
//     dyld_shared_cache_arm64e
//     dyld_shared_cache_arm64e.01
//     dyld_shared_cache_arm64e.02
//     ...
//     dyld_shared_cache_arm64e.75.dylddata
//     dyld_shared_cache_arm64e.77.dyldlinkedit
//
// Every one of them carries its own `dyld_cache_header` and its own mapping
// table. The address ranges are disjoint across chunks, so together they are
// one contiguous virtual address space. This type is the translation from an
// address in that space to (file, offset), and back.
//
// It deliberately does not extract dylibs. Patchers want to read four bytes at
// a vmaddr, decide something, and write four bytes back; anything more is the
// symbol resolver's job.
//
// Port of `scripts/patchers/cfw_dsc_chunks.py`. The Python remains the
// independent reference for this layer — see `DyldSharedCacheFoundationTests`.
//
// Two places diverge from it on purpose, both pinned by tests:
//
//   * `bytes_at_vma` bounds-checks only its first byte and then reads `length`
//     raw bytes from the file, so a read near the end of a mapping comes back
//     padded with whatever follows — at 0x1800BBFFC on this cache, with the
//     chunk's own code signature. Here the whole span has to be addressable.
//   * `write_at_vma` compares only the chunk path, so it will write across a
//     mapping seam whether or not the file offsets continue across it. Here a
//     span may cross a seam only when the bytes behind it really are one run of
//     one file, which on this cache accepts every seam the Python accepts.

import Foundation

/// A half-open span of virtual addresses that was written, or is about to be.
///
/// Re-attestation consumes these rather than bare addresses. An address alone
/// cannot say how many 16 KiB pages a write dirtied, and a caller that writes
/// eight bytes across a page boundary and then re-attests the one address it
/// started at leaves the second page's code slot stale — a
/// `KERN_PROTECTION_FAILURE` on the first demand-page-in, with nothing pointing
/// back at the patch. Carrying the length is what makes that unexpressible.
public struct DyldSharedCacheWriteSpan: Sendable, Hashable {
    /// First address the span covers.
    public let vma: UInt64
    /// Byte length. Always at least 1.
    public let length: Int

    public init(vma: UInt64, length: Int) {
        precondition(length > 0, "a write span covers at least one byte")
        self.vma = vma
        self.length = length
    }

    /// The single byte at `vma` — the only honest way to spell "just this
    /// address", and it has to be spelled out.
    public static func byte(at vma: UInt64) -> DyldSharedCacheWriteSpan {
        DyldSharedCacheWriteSpan(vma: vma, length: 1)
    }

    /// Last address the span covers.
    public var lastVMA: UInt64 {
        vma &+ UInt64(length - 1)
    }

    /// One past the last address the span covers.
    public var endVMA: UInt64 {
        vma &+ UInt64(length)
    }
}

/// Random-access byte view over a chunked dyld shared cache.
public final class DyldSharedCacheChunkSet {
    /// One `dyld_cache_mapping_info` entry, tagged with the chunk it came from.
    public struct Mapping: Sendable {
        /// First address the mapping covers.
        public let address: UInt64
        /// Byte length of the mapping.
        public let size: UInt64
        /// Offset of `address` within `chunkURL`.
        public let fileOffset: UInt64
        public let maxProt: UInt32
        /// VM_PROT mask: read 1, write 2, execute 4.
        public let initProt: UInt32
        public let chunkURL: URL

        /// One past the last address the mapping covers.
        public var endAddress: UInt64 {
            address &+ size
        }

        public var isExecutable: Bool {
            initProt & DyldSharedCacheChunkSet.vmProtExecute != 0
        }
    }

    public static let vmProtExecute: UInt32 = 4

    /// Directory holding the chunk files.
    public let directory: URL
    /// Chunk files, in the order they are enumerated (base file, then `.NN`).
    public let chunkURLs: [URL]
    /// Every mapping across every chunk, sorted by start address.
    public let mappings: [Mapping]

    private let architecture: String

    /// Guards the two pieces of lazily built state below.
    private let stateLock = NSLock()
    private var writeLog: [DyldSharedCacheWriteSpan] = []
    private var loadedLocalSymbols: DyldSharedCacheLocalSymbolTable?

    // MARK: - Construction

    /// Open the cache under `directory`.
    ///
    /// - Parameters:
    ///   - directory: the directory holding `dyld_shared_cache_<arch>*`.
    ///   - architecture: cache architecture suffix; `arm64e` for every device
    ///     this project targets.
    public init(directory: URL, architecture: String = "arm64e") throws {
        self.directory = directory
        self.architecture = architecture
        chunkURLs = try Self.enumerateChunks(in: directory, architecture: architecture)
        guard !chunkURLs.isEmpty else {
            throw DyldSharedCacheError.noChunksFound(directory: directory.path)
        }

        var collected: [Mapping] = []
        for url in chunkURLs {
            for mapping in Self.parseMappings(of: url) where mapping.size != 0 {
                collected.append(mapping)
            }
        }
        guard !collected.isEmpty else {
            throw DyldSharedCacheError.noMappingsParsed(directory: directory.path)
        }
        collected.sort { $0.address < $1.address }
        mappings = collected
    }

    /// The unsuffixed chunk, which carries the cache-wide header (image list,
    /// sub-cache table, local-symbols pointer).
    public var mainCacheURL: URL {
        directory.appendingPathComponent("dyld_shared_cache_\(architecture)")
    }

    /// The `.symbols` side file holding the stripped local symbol table.
    public var localSymbolsURL: URL {
        directory.appendingPathComponent("dyld_shared_cache_\(architecture).symbols")
    }

    /// Lowest and highest address the cache covers.
    public var addressRange: Range<UInt64> {
        (mappings.first?.address ?? 0) ..< (mappings.map(\.endAddress).max() ?? 0)
    }

    // MARK: - Address translation

    /// Locate `vma`'s byte in its chunk file.
    ///
    /// Returns `nil` when no mapping covers the address. Only the first byte is
    /// checked — use `fileRange(of:)` when a whole span has to be addressable.
    public func findChunk(forVMA vma: UInt64) -> (chunkURL: URL, fileOffset: Int)? {
        guard let mapping = mapping(forVMA: vma) else { return nil }
        return (mapping.chunkURL, Int(mapping.fileOffset &+ (vma &- mapping.address)))
    }

    /// The mapping covering `vma`, if any.
    public func mapping(forVMA vma: UInt64) -> Mapping? {
        mappingIndex(forVMA: vma).map { mappings[$0] }
    }

    private func mappingIndex(forVMA vma: UInt64) -> Int? {
        // Mappings are disjoint and sorted, so the candidate is the last one
        // that starts at or below `vma`.
        var low = 0
        var high = mappings.count
        while low < high {
            let mid = (low + high) / 2
            if mappings[mid].address <= vma {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low > 0 else { return nil }
        return vma < mappings[low - 1].endAddress ? low - 1 : nil
    }

    /// The unbroken run of chunk-file bytes that starts at `vma`.
    ///
    /// A span is addressable when the bytes behind it are one contiguous run of
    /// one file. Usually that means one mapping, but neighbouring mappings of
    /// the same chunk are often contiguous in address *and* in file offset — on
    /// the 24A435 arm64e cache 19 of the 62 adjacent mapping pairs are, all of
    /// them inside a single chunk — and a read or write that crosses such a
    /// seam is still reading or writing exactly the right bytes. A seam where
    /// either the file offsets or the chunk files break is a different story,
    /// and stops the run.
    ///
    /// - Returns: the chunk file, the offset of `vma` in it, and how many bytes
    ///   follow before the run ends. `nil` when `vma` is not mapped at all.
    func contiguousRun(from vma: UInt64) -> (chunkURL: URL, fileOffset: UInt64, available: UInt64)? {
        guard var index = mappingIndex(forVMA: vma) else { return nil }
        let first = mappings[index]
        var available = first.endAddress &- vma
        while index + 1 < mappings.count {
            let current = mappings[index]
            let next = mappings[index + 1]
            guard next.chunkURL == current.chunkURL,
                  next.address == current.endAddress,
                  next.fileOffset == current.fileOffset &+ current.size
            else { break }
            available &+= next.size
            index += 1
        }
        return (first.chunkURL, first.fileOffset &+ (vma &- first.address), available)
    }

    /// Where `span` lives in its chunk file.
    ///
    /// Throws when the first byte is unmapped, and when the span runs off the
    /// end of its contiguous run — the case where the following bytes in the
    /// file belong to some other virtual address, or to none at all.
    public func fileRange(of span: DyldSharedCacheWriteSpan) throws -> (chunkURL: URL, range: Range<Int>) {
        guard let run = contiguousRun(from: span.vma) else {
            throw DyldSharedCacheError.addressNotMapped(span.vma)
        }
        guard UInt64(span.length) <= run.available else {
            throw DyldSharedCacheError.addressSpanCrossesChunk(vma: span.vma, length: span.length)
        }
        let start = Int(run.fileOffset)
        return (run.chunkURL, start ..< (start + span.length))
    }

    // MARK: - Reading

    /// Read `length` bytes at `vma`. The whole span must be addressable.
    ///
    /// This is stricter than `cfw_dsc_chunks.bytes_at_vma`, deliberately. The
    /// Python bounds-checks only the first byte and then reads `length` raw
    /// bytes from the file, so a read that starts near the end of a mapping
    /// comes back padded with whatever happens to follow — on this cache,
    /// asking for 64 bytes at 0x1800BBFFC returns 60 bytes of the chunk's own
    /// `CS_SuperBlob` dressed up as code. That is silent wrong data on a read
    /// API, so here it throws.
    public func bytesAtVMA(_ vma: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let (chunkURL, range) = try fileRange(of: DyldSharedCacheWriteSpan(vma: vma, length: length))
        let data = try Self.read(url: chunkURL, offset: UInt64(range.lowerBound), length: length)
        guard data.count == length else {
            throw DyldSharedCacheError.shortRead(vma: vma, wanted: length, got: data.count)
        }
        return data
    }

    /// Read up to `length` bytes at `vma`.
    ///
    /// With `allowShort` set, a span that would run past the end of what is
    /// addressable comes back truncated instead of throwing — what a
    /// load-command walk wants when it asks for "the next 64 KiB, however much
    /// of it exists".
    public func readAtVMA(_ vma: UInt64, length: Int, allowShort: Bool = false) throws -> Data {
        guard length > 0 else { return Data() }
        guard let run = contiguousRun(from: vma) else {
            throw DyldSharedCacheError.addressNotMapped(vma)
        }
        let wanted: Int
        if run.available >= UInt64(length) {
            wanted = length
        } else if allowShort {
            wanted = Int(run.available)
        } else {
            throw DyldSharedCacheError.addressSpanCrossesChunk(vma: vma, length: length)
        }
        return try Self.read(url: run.chunkURL, offset: run.fileOffset, length: wanted)
    }

    // MARK: - Writing

    /// Write `data` at `vma`, straight through to the chunk that holds it, and
    /// record the span so it can be re-attested.
    ///
    /// The whole span has to be addressable as one run of one chunk file. A
    /// write that would straddle two chunks is refused rather than split: the
    /// second chunk's bytes are a different file with a different code
    /// directory, and silently writing half a patch is worse than not writing
    /// it.
    ///
    /// - Returns: the span written, which is what
    ///   `DyldSharedCacheCodeSignature.reattest(in:modifiedSpans:)` consumes. The same span
    ///   is appended to `recordedWrites`, so a patcher that just writes and
    ///   then calls `reattestRecordedWrites(in:)` cannot under-attest. Empty
    ///   `data` writes nothing and records nothing; the span it hands back is
    ///   the single byte at `vma`, and re-attesting it is a no-op.
    @discardableResult
    public func write(at vma: UInt64, _ data: Data) throws -> DyldSharedCacheWriteSpan {
        guard !data.isEmpty else { return DyldSharedCacheWriteSpan.byte(at: vma) }
        let span = DyldSharedCacheWriteSpan(vma: vma, length: data.count)
        let (chunkURL, range) = try fileRange(of: span)
        let handle = try FileHandle(forUpdating: chunkURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        try handle.write(contentsOf: data)
        stateLock.withLock { writeLog.append(span) }
        return span
    }

    /// Every span `write(at:_:)` has put on disk through this chunk set, oldest
    /// first.
    public var recordedWrites: [DyldSharedCacheWriteSpan] {
        stateLock.withLock { writeLog }
    }

    /// Forget the recorded writes — for a caller that re-attests in batches and
    /// does not want the next batch to redo the previous one's pages.
    public func clearRecordedWrites() {
        stateLock.withLock { writeLog.removeAll() }
    }

    // MARK: - Local symbols

    /// The cache's `.symbols` local symbol table, parsed once and kept.
    ///
    /// Parsed directly rather than shelled out to `ipsw dyld symaddr`, which
    /// times out on a cache this size. The table is big — 1.2 GB resident on
    /// the 24A435 arm64e cache — so it is loaded at most once per chunk set and
    /// can be dropped again with `unloadLocalSymbolTable()`.
    ///
    /// Throws when the side file is missing or unparseable. That is the whole
    /// point of it throwing: "the symbol table is not there" and "that symbol
    /// is not in it" are different answers, and the previous `try?` spelled
    /// both of them `nil`.
    public func localSymbolTable() throws -> DyldSharedCacheLocalSymbolTable {
        try stateLock.withLock {
            if let loadedLocalSymbols {
                return loadedLocalSymbols
            }
            guard FileManager.default.fileExists(atPath: localSymbolsURL.path) else {
                throw DyldSharedCacheError.localSymbolsMissing(path: localSymbolsURL.path)
            }
            let table = try DyldSharedCacheLocalSymbolTable(url: localSymbolsURL)
            loadedLocalSymbols = table
            return table
        }
    }

    /// Drop the cached local symbol table and its ~1.2 GB of buffers.
    public func unloadLocalSymbolTable() {
        stateLock.withLock { loadedLocalSymbols = nil }
    }

    /// Resolve `name` to its address through the cache's own `.symbols` table.
    ///
    /// Returns the first match, matching the Python reference; local symbol
    /// names are not guaranteed unique across images, so callers that care
    /// which image a symbol came from should use `DyldSharedCacheSymbolResolver` instead.
    ///
    /// `nil` means "no symbol by that name". A missing or unreadable table
    /// throws instead, so a force-kern discovery run cannot report "zero pairs"
    /// when what actually happened is that the table was not there.
    public func resolveLocalSymbol(_ name: String) throws -> UInt64? {
        try localSymbolTable().firstAddress(of: name)
    }

    // MARK: - Search helpers

    /// Every address at which `needle` appears in an executable mapping,
    /// anchored at the mapping start or just after a NUL.
    ///
    /// Restricted to RX mappings, which is where `__TEXT,__cstring` lives. That
    /// skips LINKEDIT and the `__DATA` mappings, which between them are most of
    /// the cache's bytes and none of its C strings.
    public func findStringVMAs(_ needle: Data) throws -> [UInt64] {
        guard !needle.isEmpty else { return [] }
        var results: [UInt64] = []
        for mapping in mappings where mapping.isExecutable {
            let buffer = try Self.window(
                over: mapping, at: mapping.fileOffset, length: Int(mapping.size),
            )
            var searchFrom = buffer.startIndex
            while searchFrom < buffer.endIndex,
                  let found = buffer.range(of: needle, in: searchFrom ..< buffer.endIndex)
            {
                let position = found.lowerBound - buffer.startIndex
                if position == 0 || buffer[buffer.startIndex + position - 1] == 0 {
                    results.append(mapping.address &+ UInt64(position))
                }
                searchFrom = found.lowerBound + 1
            }
        }
        return results
    }

    private static let machOMagic64LE = Data([0xCF, 0xFA, 0xED, 0xFE])

    /// Walk back from `vma` to the start of the Mach-O image that contains it.
    ///
    /// Images in the cache start on a page boundary at the head of their
    /// `__TEXT`, and an arm64e dylib's header shares a mapping with its
    /// `__text`, so the search never has to leave the containing mapping.
    public func findMachOHeaderBefore(
        _ vma: UInt64,
        maxWalk: Int = 64 * 1024 * 1024,
    ) throws -> UInt64? {
        guard let mapping = mapping(forVMA: vma) else { return nil }
        let localOffset = Int(vma &- mapping.address)
        let scanLength = min(localOffset, maxWalk)
        let scanStart = localOffset - scanLength
        // +4 so a header sitting right at the scan's end is still matched.
        let buffer = try Self.window(
            over: mapping,
            at: mapping.fileOffset &+ UInt64(scanStart),
            length: scanLength + 4,
        )
        var searchEnd = buffer.endIndex
        while searchEnd > buffer.startIndex,
              let found = buffer.range(
                  of: Self.machOMagic64LE,
                  options: .backwards,
                  in: buffer.startIndex ..< searchEnd,
              )
        {
            let position = found.lowerBound - buffer.startIndex
            let candidate = mapping.address &+ UInt64(scanStart + position)
            if candidate & 0xFFF == 0 {
                return candidate
            }
            searchEnd = found.lowerBound
        }
        return nil
    }

    /// The `LC_ID_DYLIB` install name of the image whose header is at
    /// `headerVMA`, or `nil` when that address is not a dylib header.
    public func readInstallName(atHeaderVMA headerVMA: UInt64) -> String? {
        guard let head = try? readAtVMA(headerVMA, length: 64 * 1024, allowShort: true),
              head.count >= 32,
              head.loadLE(UInt32.self, at: 0) == 0xFEED_FACF
        else { return nil }

        let commandCount = head.loadLE(UInt32.self, at: 16)
        let commandsSize = head.loadLE(UInt32.self, at: 20)
        guard commandCount <= 4096, commandsSize <= 64 * 1024 else { return nil }

        var offset = 32
        for _ in 0 ..< commandCount {
            guard offset + 8 <= head.count else { return nil }
            let command = head.loadLE(UInt32.self, at: offset)
            let commandSize = Int(head.loadLE(UInt32.self, at: offset + 4))
            guard commandSize >= 8, commandSize <= 64 * 1024 else { return nil }
            if command == 0xD { // LC_ID_DYLIB
                let nameOffset = Int(head.loadLE(UInt32.self, at: offset + 8))
                let nameStart = offset + nameOffset
                guard nameStart < head.count, nameStart < offset + commandSize else { return nil }
                let limit = min(head.count, offset + commandSize)
                var end = nameStart
                while end < limit, head[head.startIndex + end] != 0 {
                    end += 1
                }
                let bytes = head[(head.startIndex + nameStart) ..< (head.startIndex + end)]
                return String(decoding: bytes, as: UTF8.self)
            }
            offset += commandSize
            if offset > Int(commandsSize) + 32 {
                return nil
            }
        }
        return nil
    }

    // MARK: - Chunk enumeration and header parsing

    static func enumerateChunks(in directory: URL, architecture: String) throws -> [URL] {
        let prefix = "dyld_shared_cache_\(architecture)"
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) }
            .filter { !$0.hasSuffix(".symbols") && !$0.hasSuffix(".map") }

        /// Base file first, then numerically by sub-cache index. Files whose
        /// suffix is not a bare number (`.75.dylddata`, `.atlas`) sort after,
        /// by name — they still carry mappings and must not be dropped.
        func sortKey(_ name: String) -> (Int, Int, String) {
            if name == prefix {
                return (0, -1, name)
            }
            let suffix = name.dropFirst(prefix.count)
            guard suffix.hasPrefix(".") else { return (1, 0, name) }
            let rest = suffix.dropFirst()
            if let index = Int(rest), !rest.isEmpty {
                return (0, index, name)
            }
            return (1, 0, name)
        }
        return names
            .sorted { sortKey($0) < sortKey($1) }
            .map { directory.appendingPathComponent($0) }
    }

    /// Parse one chunk's `dyld_cache_mapping_info` table.
    ///
    /// Slide-info mappings (`mappingWithSlideOffset`) are left alone: which
    /// address comes from which file offset is fully covered by the standard
    /// mappings, and that is all this layer claims to know.
    static func parseMappings(of url: URL) -> [Mapping] {
        guard let head = try? read(url: url, offset: 0, length: 0x100), head.count >= 24 else {
            return []
        }
        guard head.prefix(4) == Data("dyld".utf8) else { return [] }

        let mappingOffset = head.loadLE(UInt32.self, at: 16)
        let mappingCount = head.loadLE(UInt32.self, at: 20)
        // Sanity bounds — a mis-parsed header must not turn into a huge read.
        guard mappingCount <= 64, mappingOffset <= 0x10000 else { return [] }

        guard let raw = try? read(
            url: url,
            offset: UInt64(mappingOffset),
            length: Int(mappingCount) * 32,
        ), raw.count == Int(mappingCount) * 32 else { return [] }

        return (0 ..< Int(mappingCount)).map { index in
            let base = index * 32
            return Mapping(
                address: raw.loadLE(UInt64.self, at: base),
                size: raw.loadLE(UInt64.self, at: base + 8),
                fileOffset: raw.loadLE(UInt64.self, at: base + 16),
                maxProt: raw.loadLE(UInt32.self, at: base + 24),
                initProt: raw.loadLE(UInt32.self, at: base + 28),
                chunkURL: url,
            )
        }
    }

    /// A bounded read: a seek and a copy of `length` bytes.
    ///
    /// Right for the small reads — a load command, a page, a run of a few
    /// kilobytes. Wrong for a whole mapping; use `window(over:)` for those.
    static func read(url: URL, offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    /// A whole mapping, as a slice of the MAPPED chunk file.
    ///
    /// The scans — `findStringVMAs` over every executable mapping,
    /// `findMachOHeaderBefore` walking back up to 64 MB — used `read` for this,
    /// which copied the mapping into the heap: an executable mapping is around
    /// 130 MB and there are two dozen of them, so one string search cost 3.3 GB
    /// of resident memory and a test run that did a few in a row took the
    /// machine down.
    ///
    /// A slice of a mapping is not a copy. The bytes fault in as the scan walks
    /// them and the kernel evicts them again behind it, so the same search
    /// costs a working set rather than the whole cache.
    ///
    /// The returned slice keeps the mapping alive for as long as it is held,
    /// and its `startIndex` is NOT zero — every caller here already works in
    /// terms of `buffer.startIndex`, which is what makes that safe.
    static func window(over mapping: Mapping, at offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let file = try Data(contentsOf: mapping.chunkURL, options: .mappedIfSafe)
        let lower = file.startIndex + Int(offset)
        guard lower <= file.endIndex else { return Data() }
        let upper = min(file.endIndex, lower + length)
        return file[lower ..< upper]
    }
}
