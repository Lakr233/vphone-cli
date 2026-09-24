// DyldSharedCacheLocalSymbolTable.swift — The cache's stripped local symbol table.
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
public struct DyldSharedCacheLocalSymbolTable: Sendable {
    /// One image's slice of the nlist array.
    public struct ImageEntry: Sendable {
        /// The image's `__TEXT` address as an offset from the cache's
        /// `sharedRegionStart`, which is how entries are keyed.
        public let dylibOffset: UInt64
        public let nlistStartIndex: Int
        public let nlistCount: Int
    }

    public let url: URL

    /// The whole `.symbols` file, MAPPED — never read.
    ///
    /// On an iOS 27 arm64e cache this file is 1.17 GB, and the string table and
    /// nlist array inside it are most of that. Reading them with
    /// `FileHandle.read(upToCount:)` — which is what this did — made every
    /// `DyldSharedCacheSymbolResolver` cost well over a gigabyte of resident memory, and a
    /// test run that builds several in parallel took the machine down with it.
    ///
    /// `.mappedIfSafe` costs address space instead. Pages fault in only where a
    /// lookup actually touches them, the kernel evicts them again under
    /// pressure, and nothing is ever copied — a symbol lookup reads a few
    /// hundred kilobytes of a 1.17 GB file and that is what it pays for.
    ///
    /// The two tables are held as OFFSET RANGES into this one mapping rather
    /// than as sliced `Data`s. That is not a style choice: `loadLE(_:at:)`
    /// takes an offset it passes straight to `Data.copyBytes(to:from:)`, whose
    /// range is in the collection's own index space, so it is only correct on a
    /// `Data` whose `startIndex` is zero. A slice of a mapping has neither a
    /// zero `startIndex` nor, if it were re-based with `Data(…)`, the mapping.
    private let file: Data
    /// Absolute offsets into `file` for the nlist array (`nlistCount` × 16 B).
    private let nlistBase: Int
    /// Absolute offset and size of the string table the nlist entries index.
    private let stringBase: Int
    private let stringSize: Int

    public let nlistCount: Int
    public let entries: [ImageEntry]

    // MARK: - Construction

    public init(url: URL) throws {
        self.url = url
        let file = try Data(contentsOf: url, options: .mappedIfSafe)
        self.file = file

        guard file.count >= 0x50,
              file.prefix(7) == Data("dyld_v1".utf8)
        else {
            throw DyldSharedCacheError.notADyldCache(url.path)
        }

        // Every read below goes through `at:` on the mapped file, so each one
        // is a page fault at most rather than a copy.
        let infoOffset = Int(file.at(UInt64.self, 0x48))
        guard infoOffset > 0, infoOffset + 24 <= file.count else {
            throw DyldSharedCacheError.symbolNotFound(symbol: "<local symbols table>", image: nil)
        }

        let nlistOffset = Int(file.at(UInt32.self, infoOffset))
        let declaredNlistCount = Int(file.at(UInt32.self, infoOffset + 4))
        let stringsOffset = Int(file.at(UInt32.self, infoOffset + 8))
        let stringsSize = Int(file.at(UInt32.self, infoOffset + 12))
        let entriesOffset = Int(file.at(UInt32.self, infoOffset + 16))
        let entriesCount = Int(file.at(UInt32.self, infoOffset + 20))

        stringBase = infoOffset + stringsOffset
        stringSize = max(0, min(stringsSize, file.count - stringBase))

        nlistBase = infoOffset + nlistOffset
        nlistCount = max(0, min(declaredNlistCount, (file.count - nlistBase) / 16))

        let entryBase = infoOffset + entriesOffset
        let usableEntries = max(0, min(entriesCount, (file.count - entryBase) / 16))
        entries = (0 ..< usableEntries).map { index in
            let base = entryBase + index * 16
            return ImageEntry(
                dylibOffset: file.at(UInt64.self, base),
                nlistStartIndex: Int(file.at(UInt32.self, base + 8)),
                nlistCount: Int(file.at(UInt32.self, base + 12)),
            )
        }
    }

    // MARK: - Lookup

    /// The name at `stringIndex`, or `nil` when the index is out of range.
    func name(atStringIndex stringIndex: Int) -> String? {
        guard stringIndex >= 0, stringIndex < stringSize else { return nil }
        let start = file.startIndex + stringBase + stringIndex
        let limit = file.startIndex + stringBase + stringSize
        var end = start
        while end < limit, file[end] != 0 {
            end += 1
        }
        guard end > start else { return "" }
        return String(decoding: file[start ..< end], as: UTF8.self)
    }

    /// `n_value` of the first entry named `name`, scanning the whole table.
    ///
    /// First match wins, which is what the Python reference does. Names repeat
    /// across images — every ObjC class that answers `+alloc` contributes one —
    /// so prefer `symbols(in:)` when the image is known.
    ///
    /// The scan walks the mapping directly and builds no `String`: a table with
    /// millions of entries would otherwise allocate millions of them to throw
    /// all but one away.
    public func firstAddress(of name: String) -> UInt64? {
        let wanted = Array(name.utf8)
        return file.withUnsafeBytes { bytes -> UInt64? in
            for index in 0 ..< nlistCount {
                let base = nlistBase + index * 16
                let stringIndex = Int(
                    bytes.loadUnaligned(fromByteOffset: base, as: UInt32.self).littleEndian,
                )
                guard matches(wanted, in: bytes, atStringIndex: stringIndex) else { continue }
                return bytes
                    .loadUnaligned(fromByteOffset: base + 8, as: UInt64.self)
                    .littleEndian
            }
            return nil
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
            let base = nlistBase + index * 16
            let stringIndex = Int(file.at(UInt32.self, base))
            let value = file.at(UInt64.self, base + 8)
            guard value != 0, let name = name(atStringIndex: stringIndex), !name.isEmpty
            else { continue }
            if result[name] == nil {
                result[name] = value
            }
        }
        return result
    }

    /// The entry whose image starts at `dylibOffset` (a cache VM offset).
    public func entry(forDylibOffset dylibOffset: UInt64) -> ImageEntry? {
        entries.first { $0.dylibOffset == dylibOffset }
    }

    /// `stringIndex` is relative to the string table; `bytes` covers the file.
    private func matches(
        _ wanted: [UInt8],
        in bytes: UnsafeRawBufferPointer,
        atStringIndex stringIndex: Int,
    ) -> Bool {
        guard stringIndex >= 0, stringIndex + wanted.count < stringSize else { return false }
        let base = stringBase + stringIndex
        for offset in 0 ..< wanted.count where bytes[base + offset] != wanted[offset] {
            return false
        }
        return bytes[base + wanted.count] == 0
    }
}

// MARK: - Reading a mapped file by absolute offset

private extension Data {
    /// Load a little-endian integer at an offset from the START OF THE FILE.
    ///
    /// Deliberately not `loadLE(_:at:)`: that one hands its offset to
    /// `copyBytes(to:from:)`, whose range is in the collection's index space,
    /// so it silently reads the wrong bytes on anything whose `startIndex` is
    /// not zero — which is every slice, and would be every view of a mapping.
    func at<T: FixedWidthInteger>(_: T.Type, _ offset: Int) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count)
        return withUnsafeBytes {
            T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }
}
