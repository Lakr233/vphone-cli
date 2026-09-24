import Foundation
import Testing
@testable import VPhoneRestore
import zlib

/// Turning what idevicerestore's `-t/--shsh` wrote into what this project has
/// always kept beside a VM: a gzipped binary plist under
/// `<ecid>-<product>-<version>.shsh`, into a plain plist under
/// `<ECID as %016X>.shsh`.
struct RestoreTicketTests {
    // MARK: - Fixtures

    /// A minimal stand-in for a TSS response: a dict with an AP ticket and one
    /// per-component blob, which is the shape that matters.
    private var tssResponse: [String: Any] {
        [
            "ApImg4Ticket": Data([0x49, 0x4D, 0x34, 0x4D]),
            "Status": ["code": 0] as [String: Any],
            "iBEC": ["Digest": Data([0xAA, 0xBB]), "Trusted": true] as [String: Any],
        ]
    }

    private func plist(_ object: Any, format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }

    /// The mirror of `VPhoneRestoreTicket.gunzip`: zlib deflate with
    /// `windowBits = 15 + 16`, which is what `gzopen`/`gzwrite` produce.
    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let started = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size),
        )
        try #require(started == Z_OK)
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        input.withUnsafeMutableBufferPointer { inputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = uInt(inputBuffer.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk[0 ..< produced])
                }
                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK {
                    break
                }
            }
        }
        return output
    }

    private let anyPath = URL(fileURLWithPath: "/tmp/vm/000000011A2B3C4D.shsh")

    // MARK: - Filename

    @Test(arguments: [
        ("4886718345-iPhone17,3-26.0.shsh", UInt64(4_886_718_345)),
        ("1-iPhone17,3-26.0.shsh", UInt64(1)),
        ("18446744073709551615-iPhone17,3-26.0.shsh", UInt64.max),
    ])
    func `reads the decimal ECID off the filename`(_ name: String, _ expected: UInt64) {
        // idevicerestore prints client->ecid in DECIMAL there, and it is the
        // ECID the device reported — which is how a fetch with no --ecid still
        // produces a named .shsh, exactly as Python's
        // `device.get_ecid_value()` did.
        #expect(VPhoneRestoreTicket.ecid(fromSHSHFilename: name) == expected)
    }

    @Test(arguments: ["shsh", "-iPhone17,3-26.0.shsh", "auto.shsh", "iPhone17,3-26.0.shsh", ""])
    func `a filename without A leading ECID gives nothing`(_ name: String) {
        #expect(VPhoneRestoreTicket.ecid(fromSHSHFilename: name) == nil)
    }

    @Test func `an ECID too large for sixty four bits gives nothing`() {
        // Rather than wrapping into some other device's identifier.
        #expect(VPhoneRestoreTicket.ecid(fromSHSHFilename: "99999999999999999999-x-y.shsh") == nil)
    }

    // MARK: - Magic

    @Test func `recognises the gzip magic`() {
        #expect(VPhoneRestoreTicket.isGzipped(Data([0x1F, 0x8B, 0x08, 0x00])))
        #expect(!VPhoneRestoreTicket.isGzipped(Data("<?xml".utf8)))
        #expect(!VPhoneRestoreTicket.isGzipped(Data("bplist00".utf8)))
        #expect(!VPhoneRestoreTicket.isGzipped(Data([0x1F])))
        #expect(!VPhoneRestoreTicket.isGzipped(Data()))
    }

    // MARK: - Decompression

    @Test func `inflates what gzip wrote`() throws {
        let original = Data("the quick brown fox, repeated: \(String(repeating: "ab", count: 5000))".utf8)
        let compressed = try gzip(original)
        #expect(VPhoneRestoreTicket.isGzipped(compressed))
        let inflated = try #require(VPhoneRestoreTicket.gunzip(compressed))
        #expect(inflated == original)
    }

    @Test func `inflates across the output chunk boundary`() throws {
        // The inflate loop refills a 64 KiB buffer; a blob bigger than that is
        // the case that finds an off-by-one in the refill.
        var original = Data()
        for index in 0 ..< 400_000 {
            original.append(UInt8(index % 251))
        }
        let inflated = try #require(try VPhoneRestoreTicket.gunzip(gzip(original)))
        #expect(inflated.count == original.count)
        #expect(inflated == original)
    }

    @Test func `refuses garbage rather than looping on it`() {
        #expect(VPhoneRestoreTicket.gunzip(Data([0x1F, 0x8B, 0x00, 0x01, 0x02, 0x03])) == nil)
        #expect(VPhoneRestoreTicket.gunzip(Data()) == nil)
        #expect(VPhoneRestoreTicket.gunzip(Data("not compressed at all".utf8)) == nil)
    }

    @Test func `refuses A truncated stream`() throws {
        let compressed = try gzip(Data(repeating: 0x5A, count: 100_000))
        let truncated = compressed.prefix(compressed.count / 2)
        #expect(VPhoneRestoreTicket.gunzip(Data(truncated)) == nil)
    }

    // MARK: - Reading a .shsh

    @Test func `reads the gzipped binary plist idevicerestore writes`() throws {
        let binary = try plist(tssResponse, format: .binary)
        let onDisk = try gzip(binary)
        let recovered = try VPhoneRestoreTicket.plistData(of: onDisk, at: anyPath)
        // The gzip wrapper comes off and the plist bytes are passed through
        // untouched — no re-serialization, so a blob's bytes never change.
        #expect(recovered == binary)
        let parsed = try PropertyListSerialization.propertyList(from: recovered, options: [], format: nil)
        #expect((parsed as? [String: Any])?["ApImg4Ticket"] is Data)
    }

    @Test func `reads the plain XML plist the python bridge wrote`() throws {
        // plistlib.dump defaults to XML, so every .shsh already sitting in a
        // bundle is this shape.
        let xml = try plist(tssResponse, format: .xml)
        let recovered = try VPhoneRestoreTicket.plistData(of: xml, at: anyPath)
        #expect(recovered == xml)
    }

    @Test func `reads A bare binary plist`() throws {
        let binary = try plist(tssResponse, format: .binary)
        let recovered = try VPhoneRestoreTicket.plistData(of: binary, at: anyPath)
        #expect(recovered == binary)
    }

    @Test func `rejects something that is not A plist`() {
        #expect(throws: VPhoneRestoreBackendError.shshMalformed(anyPath)) {
            try VPhoneRestoreTicket.plistData(of: Data("just some bytes".utf8), at: anyPath)
        }
    }

    @Test func `rejects A plist that is not A dictionary`() throws {
        // A TSS response is a dict with an entry per component. An array here
        // means the wrong file, and hearing that now beats hearing it from a
        // device that rejects every component it is sent.
        let array = try plist([1, 2, 3], format: .xml)
        #expect(throws: VPhoneRestoreBackendError.shshMalformed(anyPath)) {
            try VPhoneRestoreTicket.plistData(of: array, at: anyPath)
        }
    }

    @Test func `rejects A gzip stream of something that is not A plist`() throws {
        let compressed = try gzip(Data("hello, not a plist".utf8))
        #expect(throws: VPhoneRestoreBackendError.shshMalformed(anyPath)) {
            try VPhoneRestoreTicket.plistData(of: compressed, at: anyPath)
        }
    }

    @Test func `reports A damaged gzip separately from A damaged plist`() {
        // Different fixes: one is a corrupt file, the other is the wrong file.
        #expect(throws: VPhoneRestoreBackendError.shshNotDecompressible(anyPath)) {
            try VPhoneRestoreTicket.plistData(of: Data([0x1F, 0x8B, 0x08, 0xFF, 0x00]), at: anyPath)
        }
    }
}
