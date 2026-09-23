import Foundation

/// The blobs of a signed file's embedded signature, per slice, read back with
/// a parser that is not the one being tested.
///
/// It is separate from `VPhoneSign`'s own reader on purpose: a test that
/// reads the output with the writer's own code checks that the code agrees
/// with itself. This one starts from the Mach-O header and knows nothing
/// about how the signature was put together.
struct VPhoneSignBlobs {
    /// One dictionary per slice, from slot to the blob's bytes, header
    /// included.
    let slices: [[UInt32: Data]]

    init(fileAt url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        var slices: [[UInt32: Data]] = []
        for range in Self.sliceRanges(data) {
            let image = data.subdata(in: range)
            guard let signature = Self.signatureRange(image) else {
                slices.append([:])
                continue
            }
            let blob = image.subdata(in: signature)
            var found: [UInt32: Data] = [:]
            let count = Int(Self.be32(blob, 8))
            for index in 0 ..< count {
                let slot = Self.be32(blob, 12 + index * 8)
                let offset = Int(Self.be32(blob, 16 + index * 8))
                let length = Int(Self.be32(blob, offset + 4))
                found[slot] = blob.subdata(in: offset ..< offset + length)
            }
            slices.append(found)
        }
        self.slices = slices
    }

    // MARK: Walking the file

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }

    private static func sliceRanges(_ data: Data) -> [Range<Int>] {
        guard data.count >= 8, le32(data, 0) == 0xBEBA_FECA else { return [0 ..< data.count] }
        let count = Int(be32(data, 4))
        return (0 ..< count).map {
            let entry = 8 + $0 * 20
            let offset = Int(be32(data, entry + 8))
            return offset ..< offset + Int(be32(data, entry + 12))
        }
    }

    private static func signatureRange(_ image: Data) -> Range<Int>? {
        guard image.count >= 32 else { return nil }
        var cursor = 32
        for _ in 0 ..< Int(le32(image, 16)) {
            let command = le32(image, cursor)
            let size = Int(le32(image, cursor + 4))
            if command == 0x1D { // LC_CODE_SIGNATURE
                let offset = Int(le32(image, cursor + 8))
                return offset ..< offset + Int(le32(image, cursor + 12))
            }
            cursor += size
        }
        return nil
    }
}
