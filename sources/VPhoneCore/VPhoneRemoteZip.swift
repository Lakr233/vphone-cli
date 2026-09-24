// VPhoneRemoteZip.swift — read one file out of a remote .zip without fetching it.
//
// An IPSW is a zip, and a macOS one is about 18 GB. Two files inside it are
// wanted — BuildManifest.plist and a restore ramdisk — and together they are a
// few megabytes. `ipsw download appledb --pattern` did this with HTTP range
// requests; this is the same trick, and removing it was the last thing keeping
// `ipsw` in `fw_prepare.sh`.
//
// The shape of a zip makes it possible: the directory of contents is at the
// END, so three requests find any member. Read the last 64 KiB and look for the
// end-of-central-directory record; follow it to the central directory and parse
// the entries; then range-fetch the one entry's local header and data.
//
// ZIP64 is not optional here. A zip crosses into it at 4 GiB, and every IPSW
// is well past that, so the 32-bit fields in the classic records are all
// 0xFFFFFFFF and the real values live in the ZIP64 records and in each entry's
// extra field.

import Compression
import Foundation

public struct VPhoneRemoteZip: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
        /// 0 = stored, 8 = deflate. IPSWs use both: big payloads are stored,
        /// small text is deflated.
        public let compressionMethod: UInt16
    }

    public enum Error: Swift.Error, LocalizedError {
        case notSeekable(URL)
        case noEndOfCentralDirectory(URL)
        case malformed(String)
        case notFound(String)
        case unsupportedCompression(UInt16)
        case http(Int, URL)

        public var errorDescription: String? {
            switch self {
            case let .notSeekable(url):
                "\(url.host() ?? "the server") does not support range requests, so the archive cannot be read without downloading all of it"
            case let .noEndOfCentralDirectory(url):
                "\(url.lastPathComponent) does not end in a zip central directory"
            case let .malformed(what):
                "malformed zip: \(what)"
            case let .notFound(name):
                "no member matching '\(name)' in the archive"
            case let .unsupportedCompression(method):
                "zip compression method \(method) is not supported (only stored and deflate)"
            case let .http(status, url):
                "HTTP \(status) from \(url.host() ?? url.absoluteString)"
            }
        }
    }

    public let url: URL
    public let entries: [Entry]

    // MARK: - Opening

    public static func open(_ url: URL) async throws -> VPhoneRemoteZip {
        let size = try await contentLength(of: url)

        // The EOCD is 22 bytes plus up to 64 KiB of comment, so the last 64 KiB
        // and change always contains it.
        let tailLength = min(size, 66_000)
        let tail = try await range(of: url, from: size - tailLength, count: tailLength)

        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else {
            throw Error.noEndOfCentralDirectory(url)
        }

        var directoryOffset = UInt64(u32(tail, eocd + 16))
        var directorySize = UInt64(u32(tail, eocd + 12))
        var entryCount = Int(u16(tail, eocd + 10))

        // 0xFFFFFFFF in any of those means the real value is in the ZIP64
        // end-of-central-directory, which the locator right before the EOCD
        // points at. Every IPSW takes this path.
        if directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF || entryCount == 0xFFFF {
            guard let locator = lastIndex(of: [0x50, 0x4B, 0x06, 0x07], in: tail) else {
                throw Error.malformed("ZIP64 fields present but no ZIP64 locator")
            }
            let zip64Offset = u64(tail, locator + 8)
            let record = try await range(of: url, from: zip64Offset, count: 56)
            guard record.count >= 56, record.prefix(4) == Data([0x50, 0x4B, 0x06, 0x06]) else {
                throw Error.malformed("ZIP64 end-of-central-directory not where the locator says")
            }
            entryCount = Int(u64(record, 32))
            directorySize = u64(record, 40)
            directoryOffset = u64(record, 48)
        }

        let directory = try await range(of: url, from: directoryOffset, count: directorySize)
        return VPhoneRemoteZip(
            url: url, entries: try parseCentralDirectory(directory, expected: entryCount)
        )
    }

    // MARK: - Reading a member

    /// The entry named `suffix`, or — failing that — the shallowest one whose
    /// path ends with it.
    ///
    /// An exact match first, and shallowest after, because an IPSW carries
    /// several files called BuildManifest.plist: one at the root, which
    /// describes the restore, and others inside payloads. Taking whichever came
    /// first in the central directory picked a nested one and then failed to
    /// find a ramdisk in it.
    public func entry(endingWith suffix: String) throws -> Entry {
        if let exact = entries.first(where: { $0.name == suffix }) { return exact }
        let matches = entries.filter { $0.name.hasSuffix("/" + suffix) || $0.name.hasSuffix(suffix) }
        guard let shallowest = matches.min(by: {
            ($0.name.count(where: { $0 == "/" }), $0.name.count)
                < ($1.name.count(where: { $0 == "/" }), $1.name.count)
        }) else { throw Error.notFound(suffix) }
        return shallowest
    }

    public func read(_ entry: Entry) async throws -> Data {
        // The local header repeats the name and carries its own extra field,
        // whose length usually differs from the central directory's — so the
        // data offset has to be computed from the local header, not assumed.
        let header = try await Self.range(of: url, from: entry.localHeaderOffset, count: 30)
        guard header.count == 30, header.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw Error.malformed("no local file header at \(entry.localHeaderOffset)")
        }
        let nameLength = UInt64(Self.u16(header, 26))
        let extraLength = UInt64(Self.u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength

        let raw = try await Self.range(of: url, from: dataOffset, count: entry.compressedSize)
        switch entry.compressionMethod {
        case 0: return raw
        case 8: return try Self.inflate(raw, expecting: Int(entry.uncompressedSize))
        default: throw Error.unsupportedCompression(entry.compressionMethod)
        }
    }

    /// Raw DEFLATE, which is what a zip member stores — no zlib header, no
    /// checksum. `COMPRESSION_ZLIB` is libcompression's name for exactly that,
    /// misleadingly; it is the right constant.
    static func inflate(_ data: Data, expecting size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self), size,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else {
            throw Error.malformed("deflate produced \(written) bytes, the directory said \(size)")
        }
        return output
    }

    // MARK: - HTTP

    private static func contentLength(of url: URL) async throws -> UInt64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notSeekable(url) }
        guard http.statusCode == 200 else { throw Error.http(http.statusCode, url) }
        guard http.expectedContentLength > 0,
              (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").contains("bytes")
        else { throw Error.notSeekable(url) }
        return UInt64(http.expectedContentLength)
    }

    private static func range(of url: URL, from offset: UInt64, count: UInt64) async throws -> Data {
        guard count > 0 else { return Data() }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notSeekable(url) }
        // 206 is the only acceptable answer. A 200 means the server ignored the
        // header and is sending the whole 18 GB, which is exactly the thing this
        // type exists to avoid.
        guard http.statusCode == 206 else { throw Error.notSeekable(url) }
        return data
    }

    // MARK: - Parsing

    private static func parseCentralDirectory(_ data: Data, expected: Int) throws -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(expected)
        var offset = 0

        while offset + 46 <= data.count {
            guard data[data.startIndex + offset ..< data.startIndex + offset + 4]
                    == Data([0x50, 0x4B, 0x01, 0x02])
            else { break }

            let method = u16(data, offset + 10)
            var compressed = UInt64(u32(data, offset + 20))
            var uncompressed = UInt64(u32(data, offset + 24))
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            var localOffset = UInt64(u32(data, offset + 42))

            let nameStart = data.startIndex + offset + 46
            let name = String(decoding: data[nameStart ..< nameStart + nameLength], as: UTF8.self)

            // The ZIP64 extra field (id 0x0001) carries whichever of the three
            // 32-bit fields were written as 0xFFFFFFFF, in this fixed order and
            // ONLY for those — so they have to be consumed conditionally.
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                var cursor = offset + 46 + nameLength
                let extraEnd = cursor + extraLength
                while cursor + 4 <= extraEnd {
                    let id = u16(data, cursor)
                    let length = Int(u16(data, cursor + 2))
                    if id == 0x0001 {
                        var field = cursor + 4
                        if uncompressed == 0xFFFF_FFFF, field + 8 <= cursor + 4 + length {
                            uncompressed = u64(data, field); field += 8
                        }
                        if compressed == 0xFFFF_FFFF, field + 8 <= cursor + 4 + length {
                            compressed = u64(data, field); field += 8
                        }
                        if localOffset == 0xFFFF_FFFF, field + 8 <= cursor + 4 + length {
                            localOffset = u64(data, field)
                        }
                        break
                    }
                    cursor += 4 + length
                }
            }

            entries.append(Entry(
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                compressionMethod: method
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }

        guard !entries.isEmpty else { throw Error.malformed("central directory held no entries") }
        return entries
    }

    private static func lastIndex(of needle: [UInt8], in data: Data) -> Int? {
        guard data.count >= needle.count else { return nil }
        let bytes = [UInt8](data)
        var i = bytes.count - needle.count
        while i >= 0 {
            if Array(bytes[i ..< i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian }
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian }
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self).littleEndian }
    }
}
