// DSCLocalSymbolTable.swift — The cache's stripped local symbol table.
//
// dyld strips local symbols out of the images in the shared cache and parks
// them in a side file, `dyld_shared_cache_<arch>.symbols`. That file is where
// every ObjC method symbol lives — `+[AVCaptureDevice authorizationStatusFor…]`
// is not exported, so the export trie will never have it — and where private C
// functions such as `_kern_SwapEnd` live too.
//
// This is parsed directly rather than shelled out to `ipsw dyld symaddr`:
// on this cache that tool takes long enough to time out, which is exactly why
// the Python reference parses the table itself. Keeping the property matters
// more than the line count.
//
//     struct dyld_cache_local_symbols_info {   // at header.localSymbolsOffset
//         uint32_t nlistOffset;                // all offsets are relative to
//         uint32_t nlistCount;                 // localSymbolsOffset
//         uint32_t stringsOffset;
//         uint32_t stringsSize;
//         uint32_t entriesOffset;
//         uint32_t entriesCount;
//     };
//
//     struct dyld_cache_local_symbols_entry_64 {
//         uint64_t dylibOffset;                // image's __TEXT, as a cache
//         uint32_t nlistStartIndex;            // VM offset from sharedRegionStart
//         uint32_t nlistCount;
//     };

import Foundation

/// Reader over `dyld_shared_cache_<arch>.symbols`.
public struct DSCLocalSymbolTable: Sendable {
    /// One image's slice of the nlist array.
    public struct ImageEntry: Sendable {
        /// The image's `__TEXT` address as an offset from the cache's
        /// `sharedRegionStart`, which is how entries are keyed.
        public let dylibOffset: UInt64
        public let nlistStartIndex: Int
        public let nlistCount: Int
    }

    public let url: URL
    /// The whole nlist array, `nlistCount` × 16 bytes.
    let nlistData: Data
    /// The string table the nlist entries index into.
    let stringData: Data
    public let nlistCount: Int
    public let entries: [ImageEntry]

    // MARK: - Construction

    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let head = try handle.read(upToCount: 0x100), head.count >= 0x50,
              head.prefix(7) == Data("dyld_v1".utf8)
        else {
            throw DSCError.notADyldCache(url.path)
        }

        let infoOffset = head.loadLE(UInt64.self, at: 0x48)
        guard infoOffset > 0 else {
            throw DSCError.symbolNotFound(symbol: "<local symbols table>", image: nil)
        }

        try handle.seek(toOffset: infoOffset)
        guard let info = try handle.read(upToCount: 24), info.count == 24 else {
            throw DSCError.symbolNotFound(symbol: "<local symbols table>", image: nil)
        }
        let nlistOffset = UInt64(info.loadLE(UInt32.self, at: 0))
        let nlistCount = Int(info.loadLE(UInt32.self, at: 4))
        let stringsOffset = UInt64(info.loadLE(UInt32.self, at: 8))
        let stringsSize = Int(info.loadLE(UInt32.self, at: 12))
        let entriesOffset = UInt64(info.loadLE(UInt32.self, at: 16))
        let entriesCount = Int(info.loadLE(UInt32.self, at: 20))

        try handle.seek(toOffset: infoOffset + stringsOffset)
        stringData = try handle.read(upToCount: stringsSize) ?? Data()

        try handle.seek(toOffset: infoOffset + nlistOffset)
        nlistData = try handle.read(upToCount: nlistCount * 16) ?? Data()
        self.nlistCount = min(nlistCount, nlistData.count / 16)

        try handle.seek(toOffset: infoOffset + entriesOffset)
        let entryData = try handle.read(upToCount: entriesCount * 16) ?? Data()
        entries = (0 ..< min(entriesCount, entryData.count / 16)).map { index in
            let base = index * 16
            return ImageEntry(
                dylibOffset: entryData.loadLE(UInt64.self, at: base),
                nlistStartIndex: Int(entryData.loadLE(UInt32.self, at: base + 8)),
                nlistCount: Int(entryData.loadLE(UInt32.self, at: base + 12))
            )
        }
    }

    // MARK: - Lookup

    /// The name at `stringIndex`, or `nil` when the index is out of range.
    func name(atStringIndex stringIndex: Int) -> String? {
        guard stringIndex >= 0, stringIndex < stringData.count else { return nil }
        var end = stringIndex
        while end < stringData.count, stringData[stringData.startIndex + end] != 0 { end += 1 }
        guard end > stringIndex else { return "" }
        let bytes = stringData[(stringData.startIndex + stringIndex) ..< (stringData.startIndex + end)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `n_value` of the first entry named `name`, scanning the whole table.
    ///
    /// First match wins, which is what the Python reference does. Names repeat
    /// across images — every ObjC class that answers `+alloc` contributes one —
    /// so prefer `symbols(in:)` when the image is known.
    public func firstAddress(of name: String) -> UInt64? {
        let wanted = Array(name.utf8)
        return nlistData.withUnsafeBytes { nlist -> UInt64? in
            stringData.withUnsafeBytes { strings -> UInt64? in
                for index in 0 ..< nlistCount {
                    let base = index * 16
                    let stringIndex = Int(
                        nlist.loadUnaligned(fromByteOffset: base, as: UInt32.self).littleEndian
                    )
                    guard Self.matches(wanted, in: strings, at: stringIndex) else { continue }
                    return nlist
                        .loadUnaligned(fromByteOffset: base + 8, as: UInt64.self)
                        .littleEndian
                }
                return nil
            }
        }
    }

    /// Every symbol in one image's slice of the table, as name → address.
    ///
    /// Later duplicates are kept out, so the first spelling of a name in the
    /// image's own slice wins — same rule as `firstAddress(of:)`, applied to a
    /// smaller range.
    public func symbols(in entry: ImageEntry) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        let upperBound = min(entry.nlistStartIndex + entry.nlistCount, nlistCount)
        guard entry.nlistStartIndex >= 0, entry.nlistStartIndex < upperBound else { return result }
        for index in entry.nlistStartIndex ..< upperBound {
            let base = index * 16
            let stringIndex = Int(nlistData.loadLE(UInt32.self, at: base))
            let value = nlistData.loadLE(UInt64.self, at: base + 8)
            guard value != 0, let name = name(atStringIndex: stringIndex), !name.isEmpty
            else { continue }
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    /// The entry whose image starts at `dylibOffset` (a cache VM offset).
    public func entry(forDylibOffset dylibOffset: UInt64) -> ImageEntry? {
        entries.first { $0.dylibOffset == dylibOffset }
    }

    private static func matches(
        _ wanted: [UInt8],
        in strings: UnsafeRawBufferPointer,
        at stringIndex: Int
    ) -> Bool {
        guard stringIndex >= 0, stringIndex + wanted.count < strings.count else { return false }
        for offset in 0 ..< wanted.count where strings[stringIndex + offset] != wanted[offset] {
            return false
        }
        return strings[stringIndex + wanted.count] == 0
    }
}
