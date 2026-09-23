import Foundation

// MARK: - Byte access

// Mach-O fields are little-endian in every slice this signs; code signing
// structures are big-endian whatever the slice is. Keeping the two spellings
// apart in the names is the only thing that stops them being mixed up.

extension Data {
    /// A Mach-O field.
    func littleEndianValue<T: FixedWidthInteger>(at offset: Int) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count)
        return T(littleEndian: withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        })
    }

    /// A code signing field.
    func bigEndianValue<T: FixedWidthInteger>(at offset: Int) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count)
        return T(bigEndian: withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        })
    }

    /// True when `offset ..< offset + length` is inside the data. Every read
    /// of a value whose offset came out of the file goes through this first.
    func holds(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    mutating func storeLittleEndian(_ value: some FixedWidthInteger, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            replaceSubrange(offset ..< offset + $0.count, with: $0)
        }
    }

    mutating func appendBigEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension Int {
    func aligned(to boundary: Int) -> Int {
        (self + boundary - 1) / boundary * boundary
    }
}
