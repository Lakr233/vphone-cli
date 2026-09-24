// DSCSymbolResolver.swift — Symbol addresses in the shared cache, without `ipsw`.
//
// Three CFW patchers used to shell out to `ipsw dyld symaddr`:
// `cfw_patch_camera_dsc.py`, `cfw_patch_iomfb_swapend.py` and
// `cfw_patch_iomfb_force_kern.py`. Between them they need two kinds of symbol,
// and the cache stores them in two different places:
//
//   * **Exported** symbols — `_IOMobileFramebufferSwapBegin` and its siblings —
//     live in each image's export trie, addressed as an offset from the image's
//     mach header.
//   * **Local** symbols — every `+[Class method]`, and private C functions such
//     as `_kern_SwapEnd` — are stripped out of the images at cache-build time
//     and parked in `dyld_shared_cache_<arch>.symbols`, sliced per image.
//
// Resolving both, per image, is what replaces the Go tool on the patch path.

import Foundation
import MachOKit

/// Symbol lookup across the images of a chunked dyld shared cache.
public final class DSCSymbolResolver {
    /// Where a resolved address came from. Worth reporting: a symbol found only
    /// in the local table is one `ipsw dyld symaddr` may also be slow to find,
    /// and a symbol found in both should agree.
    public enum Source: String, Sendable {
        case exportTrie
        case localSymbols
    }

    public struct Resolution: Sendable {
        public let name: String
        public let address: UInt64
        public let source: Source
    }

    /// The cache and all its sub-caches as one view.
    ///
    /// This has to be the full cache, not the unsuffixed file: an image's
    /// export trie lives in the `.dyldlinkedit` sub-cache, and the main
    /// chunk's own mapping table covers only its first megabyte, so a
    /// `DyldCache` opened on it alone reports no images past `.00` and no
    /// exported symbols at all.
    private let cache: FullDyldCache
    private let localSymbols: DSCLocalSymbolTable?
    private let localSymbolsURL: URL
    private let sharedRegionStart: UInt64
    /// image path → mach header address.
    private let imageAddresses: [String: UInt64]
    private var symbolCacheByImage: [String: [String: Resolution]] = [:]

    // MARK: - Construction

    /// Open the cache whose unsuffixed chunk is `mainCacheURL`.
    ///
    /// The `.symbols` side file is expected beside it. Its *absence* is not
    /// fatal — exported symbols still resolve — but every ObjC method lookup
    /// will then fail, so callers that need one should check `hasLocalSymbols`.
    /// A file that is present but unparseable *is* fatal: that is a broken
    /// cache, and reporting it as "no local symbols" would turn it into a pile
    /// of `symbolNotFound`s pointing at the wrong thing.
    public init(mainCacheURL: URL) throws {
        cache = try FullDyldCache(url: mainCacheURL)
        sharedRegionStart = cache.mainCacheHeader.sharedRegionStart

        var addresses: [String: UInt64] = [:]
        if let infos = cache.imageInfos {
            for info in infos {
                guard let path = info.path(in: cache) else { continue }
                if addresses[path] == nil {
                    addresses[path] = info.address
                }
            }
        }
        imageAddresses = addresses

        let symbolsURL = mainCacheURL.deletingLastPathComponent()
            .appendingPathComponent(mainCacheURL.lastPathComponent + ".symbols")
        localSymbols = FileManager.default.fileExists(atPath: symbolsURL.path)
            ? try DSCLocalSymbolTable(url: symbolsURL)
            : nil
        localSymbolsURL = symbolsURL
    }

    /// Open the cache a `DSCChunkSet` already found.
    public convenience init(chunks: DSCChunkSet) throws {
        try self.init(mainCacheURL: chunks.mainCacheURL)
    }

    public var hasLocalSymbols: Bool {
        localSymbols != nil
    }

    /// Fail now if the local symbol table is not there.
    ///
    /// For the discovery-shaped callers — `cfw_patch_iomfb_force_kern` looks
    /// for `_kern_Swap*`, which exist only in the local table. Without this,
    /// a missing `.symbols` file makes discovery return an empty set, which
    /// reads as "this cache has no such functions" rather than "I had nowhere
    /// to look".
    public func requireLocalSymbols() throws {
        guard localSymbols != nil else {
            throw DSCError.localSymbolsMissing(path: localSymbolsURL.path)
        }
    }

    /// Every image path in the cache, sorted.
    public var imagePaths: [String] {
        imageAddresses.keys.sorted()
    }

    /// The mach header address of `imagePath`.
    public func headerAddress(ofImage imagePath: String) throws -> UInt64 {
        guard let address = imageAddresses[imagePath] else {
            throw DSCError.imageNotFound(imagePath)
        }
        return address
    }

    // MARK: - Lookup

    /// Every symbol `imagePath` exposes, as name → resolution.
    ///
    /// Export-trie entries are taken first, so a name that appears in both
    /// tables reports the exported address — the one a caller of the public
    /// entry point would branch to.
    public func symbols(inImage imagePath: String) throws -> [String: Resolution] {
        if let cached = symbolCacheByImage[imagePath] {
            return cached
        }
        let headerAddress = try headerAddress(ofImage: imagePath)

        var result: [String: Resolution] = [:]

        if let machO = machOFile(forImage: imagePath) {
            for exported in machO.exportedSymbols {
                guard let offset = exported.offset, offset != 0 else { continue }
                let address = headerAddress &+ UInt64(offset)
                if result[exported.name] == nil {
                    result[exported.name] = Resolution(
                        name: exported.name,
                        address: address,
                        source: .exportTrie,
                    )
                }
            }
        }

        if let localSymbols {
            let dylibOffset = headerAddress &- sharedRegionStart
            if let entry = localSymbols.entry(forDylibOffset: dylibOffset) {
                for (name, address) in localSymbols.symbols(in: entry) where result[name] == nil {
                    result[name] = Resolution(
                        name: name,
                        address: address,
                        source: .localSymbols,
                    )
                }
            }
        }

        symbolCacheByImage[imagePath] = result
        return result
    }

    /// The address of `symbol` in `imagePath`.
    ///
    /// A miss with no local symbol table loaded reports the missing table
    /// rather than the missing symbol — most of what this resolves (every ObjC
    /// method, every private C function) lives only in that table, so "not
    /// found" would send the caller looking in the wrong place.
    public func address(of symbol: String, inImage imagePath: String) throws -> UInt64 {
        guard let resolution = try symbols(inImage: imagePath)[symbol] else {
            try requireLocalSymbols()
            throw DSCError.symbolNotFound(symbol: symbol, image: imagePath)
        }
        return resolution.address
    }

    /// Resolve several symbols at once, failing on the first one missing.
    ///
    /// Reports every missing name rather than only the first: a patcher that
    /// has lost five ObjC methods to a rename wants to see all five.
    public func addresses(
        of symbols: [String],
        inImage imagePath: String,
    ) throws -> [String: UInt64] {
        let table = try self.symbols(inImage: imagePath)
        var result: [String: UInt64] = [:]
        var missing: [String] = []
        for symbol in symbols {
            if let resolution = table[symbol] {
                result[symbol] = resolution.address
            } else {
                missing.append(symbol)
            }
        }
        guard missing.isEmpty else {
            try requireLocalSymbols()
            throw DSCError.symbolNotFound(
                symbol: missing.joined(separator: ", "),
                image: imagePath,
            )
        }
        return result
    }

    /// Every symbol in `imagePath` whose name starts with `prefix`.
    ///
    /// `cfw_patch_iomfb_force_kern` works this way: it does not know the set of
    /// `_IOMobileFramebufferSwap*` entry points ahead of time, it discovers
    /// them and pairs each with its `_kern_` sibling.
    public func symbols(
        inImage imagePath: String,
        withPrefix prefix: String,
    ) throws -> [String: UInt64] {
        try symbols(inImage: imagePath)
            .filter { $0.key.hasPrefix(prefix) }
            .mapValues(\.address)
    }

    // MARK: - Image lookup

    private func machOFile(forImage imagePath: String) -> MachOFile? {
        cache.machOFiles().first { $0.imagePath == imagePath }
    }
}
