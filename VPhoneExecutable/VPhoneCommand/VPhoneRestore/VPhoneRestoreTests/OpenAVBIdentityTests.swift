import Compression
import CryptoKit
import Foundation
import MobileRestoreCore
import Testing

/// The stage header a restore uploads to OpenAVB before iBSS.
///
/// The ROM checks the iBSS it receives against these fields and refuses it on
/// any mismatch, far from here, so the layout is pinned against OpenAVB's
/// `AVPPatchStageHeader`: magic, version, rows, flags, the two ROM-owned
/// words, sizes, load base, entry level, then the two SHA-256 digests.
struct OpenAVBIdentityTests {
    // MARK: - Fixtures

    /// An iBoot-shaped image: the link base at 0x300 in filler that
    /// compresses, large enough to decode past the first buffer the decoder
    /// is offered.
    /// With `literal`, the image starts as iBoot 27 does: its third
    /// instruction is `ldr x1, =base` from `literal`, and 0x300 holds the
    /// version string.
    private func iBootImage(base: UInt64 = 0x7006_C000, size: Int = 3 << 20, literal: Int? = nil) -> Data {
        var image = (0 ..< size).map { UInt8(truncatingIfNeeded: ($0 >> 6) ^ ($0 >> 13)) }
        let at = literal ?? 0x300
        for i in 0 ..< 8 {
            image[at + i] = UInt8(truncatingIfNeeded: base >> (8 * i))
        }
        if let literal {
            // LDR x1, literal (pc-relative, from 0x8).
            let ldr = UInt32(0x5800_0001) | UInt32((literal - 0x8) / 4) << 5
            for i in 0 ..< 4 {
                image[0x8 + i] = UInt8(truncatingIfNeeded: ldr >> (8 * i))
            }
            image.replaceSubrange(0x300 ..< 0x310, with: Array("iBoot-20457.42.5".utf8))
        }
        return Data(image)
    }

    private func lzfse(_ data: Data) -> Data {
        var output = Data(count: data.count + 4096)
        let count = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZFSE,
                )
            }
        }
        output.count = count
        return output
    }

    private func der(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        if body.count < 0x80 {
            out.append(UInt8(body.count))
        } else {
            let length = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }.drop { $0 == 0 }
            out.append(0x80 | UInt8(length.count))
            out.append(length)
        }
        out.append(body)
        return out
    }

    private func ia5(_ text: String) -> Data {
        der(0x16, Data(text.utf8))
    }

    private func im4p(payload: Data) -> Data {
        der(0x30, ia5("IM4P") + ia5("ibss") + ia5("iBoot-13822") + der(0x04, payload))
    }

    /// IMG4 { "IMG4", IM4P, [0] IM4M }, as idevicerestore personalizes it.
    private func img4(wrapping im4p: Data) -> Data {
        der(0x30, ia5("IMG4") + im4p + der(0xA0, der(0x30, ia5("IM4M"))))
    }

    private func identity(of image: Data) -> (status: Int32, header: [UInt8], reason: String?) {
        var header = [UInt8](repeating: 0, count: Int(VPHONE_OPENAVB_IDENTITY_SIZE))
        var reason: UnsafePointer<CChar>?
        let status = image.withUnsafeBytes { bytes in
            vphone_restore_openavb_ibss_identity(bytes.baseAddress, bytes.count, &header, &reason)
        }
        return (status, header, reason.map { String(cString: $0) })
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0 ..< 8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }

    // MARK: - Layout

    @Test func `the header describes the payload and the image it decodes to`() throws {
        let raw = iBootImage()
        let payload = lzfse(raw)
        #expect(payload.prefix(4) == Data("bvx2".utf8))

        let result = identity(of: img4(wrapping: im4p(payload: payload)))
        #expect(result.status == 0)
        #expect(result.reason == nil)
        let header = result.header
        #expect(u32(header, 0x00) == 0x4843_5450) // 'PTCH'
        #expect(u32(header, 0x04) == 1)
        #expect(u32(header, 0x08) == 0) // no patch rows: fw patch already patched it
        #expect(u32(header, 0x0C) == 1) // the identity flag
        #expect(u32(header, 0x10) == 0)
        #expect(u32(header, 0x14) == 0)
        #expect(u32(header, 0x18) == UInt32(payload.count))
        #expect(u32(header, 0x1C) == UInt32(raw.count))
        #expect(u64(header, 0x20) == 0x7006_C000)
        #expect(u32(header, 0x28) == 2)
        #expect(Array(header[0x30 ..< 0x50]) == Array(SHA256.hash(data: payload)))
        #expect(Array(header[0x50 ..< 0x70]) == Array(SHA256.hash(data: raw)))
    }

    @Test func `a bare IM4P gives the same header as the IMG4 around it`() {
        let container = im4p(payload: lzfse(iBootImage()))
        let bare = identity(of: container)
        let wrapped = identity(of: img4(wrapping: container))
        #expect(bare.status == 0)
        #expect(bare.header == wrapped.header)
    }

    @Test func `the link address is the literal iBoot's start loads, as in iOS 27`() {
        let result = identity(of: im4p(payload: lzfse(iBootImage(literal: 0x380))))
        #expect(result.status == 0)
        #expect(u64(result.header, 0x20) == 0x7006_C000)
    }

    // MARK: - Refusals

    @Test func `an uncompressed payload is refused, because OpenAVB decodes only LZFSE`() {
        let result = identity(of: img4(wrapping: im4p(payload: iBootImage())))
        #expect(result.status == -1)
        #expect(result.reason?.contains("not LZFSE") == true)
    }

    @Test func `an image with no link address is refused`() {
        let result = identity(of: im4p(payload: lzfse(iBootImage(base: 0))))
        #expect(result.status == -1)
        #expect(result.reason?.contains("link address") == true)
    }

    @Test func `something that is not IMG4 or IM4P is refused`() {
        #expect(identity(of: Data("not a container".utf8)).status == -1)
        #expect(identity(of: der(0x30, ia5("IM4M"))).status == -1)
        // A length running past the end of the data.
        #expect(identity(of: Data([0x30, 0x84, 0x7F, 0xFF, 0xFF, 0xFF, 0x16])).status == -1)
    }
}
