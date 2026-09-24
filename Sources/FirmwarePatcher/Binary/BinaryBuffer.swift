// BinaryBuffer.swift — Mutable binary data buffer with read/write helpers.

import Foundation

extension Data {
    /// Load a little-endian integer without assuming the buffer is naturally aligned.
    @inlinable
    func loadLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count)
        var value: T = .zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { dst in
            copyBytes(to: dst, from: offset ..< offset + MemoryLayout<T>.size)
        }
        return T(littleEndian: value)
    }
}

/// A mutable binary buffer for reading and patching firmware data.
public final class BinaryBuffer: @unchecked Sendable {
    /// The mutable working data.
    public var data: Data

    /// The original immutable snapshot (for before/after comparison).
    public let original: Data

    public var count: Int {
        data.count
    }

    public init(_ data: Data) {
        // Rebase to startIndex 0 so zero-based subscripts are always valid.
        let rebased = data.startIndex == 0 ? data : Data(data)
        self.data = rebased
        original = rebased
    }

    public convenience init(contentsOf url: URL) throws {
        // Read, not mapped. A `BinaryBuffer` exists to be mutated, and what it
        // is built from — a kernelcache, an iBoot — is written back over the
        // path it came from. See InPlaceRewrite.swift for why a mapping cannot
        // survive that.
        try self.init(Data(contentsOfFileToRewrite: url))
    }

    // MARK: - Read Helpers

    /// Read a little-endian UInt32 at the given byte offset.
    @inlinable
    public func readU32(at offset: Int) -> UInt32 {
        data.loadLE(UInt32.self, at: offset)
    }

    /// Read a little-endian UInt64 at the given byte offset.
    @inlinable
    public func readU64(at offset: Int) -> UInt64 {
        data.loadLE(UInt64.self, at: offset)
    }

    /// Read bytes at the given range.
    public func readBytes(at offset: Int, count: Int) -> Data {
        data[offset ..< offset + count]
    }

    // MARK: - Write Helpers

    /// Write a little-endian UInt32 at the given byte offset.
    @inlinable
    public func writeU32(at offset: Int, value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { src in
            data.replaceSubrange(offset ..< offset + 4, with: src)
        }
    }

    /// Write raw bytes at the given offset.
    public func writeBytes(at offset: Int, bytes: Data) {
        data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }

    // MARK: - Search Helpers

    /// Find all occurrences of a byte pattern in the data.
    public func findAll(_ pattern: Data, in range: Range<Int>? = nil) -> [Int] {
        let searchRange = range ?? 0 ..< data.count
        var results: [Int] = []
        var offset = searchRange.lowerBound
        while offset < searchRange.upperBound - pattern.count + 1 {
            if let found = data.range(of: pattern, in: offset ..< searchRange.upperBound) {
                results.append(found.lowerBound)
                offset = found.lowerBound + 1
            } else {
                break
            }
        }
        return results
    }

    /// Find the first occurrence of a C string in the data.
    /// Matches Python `find_string()`: walks backward from the match to the
    /// preceding NUL byte so that the returned offset is the C-string start.
    public func findString(_ string: String, from: Int = 0) -> Int? {
        guard let encoded = string.data(using: .utf8) else { return nil }
        // Try with null terminator first (exact C-string match)
        var pattern = encoded
        pattern.append(0)
        if let range = data.range(of: pattern, in: from ..< data.count) {
            // Walk backward to the preceding NUL — that's the C string start
            var cstr = range.lowerBound
            while cstr > 0, data[cstr - 1] != 0 {
                cstr -= 1
            }
            return cstr
        }
        // Try without null terminator (substring match)
        if let range = data.range(of: encoded, in: from ..< data.count) {
            var cstr = range.lowerBound
            while cstr > 0, data[cstr - 1] != 0 {
                cstr -= 1
            }
            return cstr
        }
        return nil
    }
}
