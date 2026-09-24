// DyldSharedCacheError.swift — Errors raised by the dyld shared cache foundation layer.

import Foundation

/// Failures specific to reading and writing a chunked dyld shared cache.
///
/// These are separate from `PatcherError` because every one of them is a
/// statement about the cache on disk, not about a patch site: a caller that
/// sees one of these has been handed a cache it cannot address, and no amount
/// of retrying a different anchor will help.
public enum DyldSharedCacheError: Error, CustomStringConvertible, Sendable {
    /// No `dyld_shared_cache_<arch>` chunk files under the given directory.
    case noChunksFound(directory: String)
    /// Chunks were present but not one of them had a parseable header.
    case noMappingsParsed(directory: String)
    /// The address is outside every chunk's mapping table.
    case addressNotMapped(UInt64)
    /// The span would run past the end of the mapping that holds its first byte.
    case addressSpanCrossesChunk(vma: UInt64, length: Int)
    /// A read came up short — the chunk file is truncated relative to its mappings.
    case shortRead(vma: UInt64, wanted: Int, got: Int)
    /// The chunk has no `CS_SuperBlob` / `CS_CodeDirectory` we can re-sign.
    case noCodeDirectory(chunk: String)
    /// The code directory exists but is shaped in a way this code does not handle.
    case unsupportedCodeDirectory(chunk: String, reason: String)
    /// A file that should carry a `dyld_cache_header` does not.
    case notADyldCache(String)
    /// The `.symbols` side file that holds the stripped local symbols is not
    /// beside the cache. Distinct from `symbolNotFound`: there is nothing to
    /// look in, so "not found" would be a lie.
    case localSymbolsMissing(path: String)
    /// A symbol lookup came back empty.
    case symbolNotFound(symbol: String, image: String?)
    /// An image path is not in the cache's image list.
    case imageNotFound(String)

    public var description: String {
        switch self {
        case let .noChunksFound(directory):
            "No dyld shared cache chunks found under \(directory)"
        case let .noMappingsParsed(directory):
            "Chunks present under \(directory) but no mapping table was recognised"
        case let .addressNotMapped(vma):
            "VMA 0x\(String(vma, radix: 16, uppercase: true)) is not mapped by any chunk"
        case let .addressSpanCrossesChunk(vma, length):
            "Span at VMA 0x\(String(vma, radix: 16, uppercase: true)) length \(length) crosses a chunk boundary"
        case let .shortRead(vma, wanted, got):
            "Short read at VMA 0x\(String(vma, radix: 16, uppercase: true)): got \(got) of \(wanted) bytes"
        case let .noCodeDirectory(chunk):
            "Chunk \(chunk) has no recognised CS_SuperBlob / CS_CodeDirectory"
        case let .unsupportedCodeDirectory(chunk, reason):
            "Chunk \(chunk) code directory unsupported: \(reason)"
        case let .notADyldCache(path):
            "\(path) does not start with a dyld cache header"
        case let .localSymbolsMissing(path):
            "The cache's local symbol table is missing: \(path)"
        case let .symbolNotFound(symbol, image):
            if let image {
                "Symbol \(symbol) not found in \(image)"
            } else {
                "Symbol \(symbol) not found in the cache's local symbol table"
            }
        case let .imageNotFound(path):
            "Image \(path) is not in the cache"
        }
    }
}
