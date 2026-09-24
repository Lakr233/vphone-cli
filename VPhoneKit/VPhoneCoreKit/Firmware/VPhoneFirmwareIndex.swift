// VPhoneFirmwareIndex.swift — where a restore image can be downloaded from.
//
// Two questions used to need two external programs:
//
//   iOS    "every IPSW Apple offers for iPhone17,3"
//          -> `ipsw download ipsw --device … --urls`
//   macOS  "the IPSW for macOS 26.1"
//          -> `ipsw download appledb --os macOS --version … --urls`
//
// Both are answered here, from one file: AppleDB's `main.json.xz`. It is 8 MB
// over the wire, 95 MB of JSON and 18,000 releases once unpacked, and it holds
// every OS, every build, the device each one applies to and the CDN links. One
// request answers both questions and every follow-up, which is why it is worth
// downloading whole rather than walking AppleDB's per-build files — that would
// be hundreds of requests to answer one.
//
// Apple's own iTunes version plist was the obvious alternative and is not
// enough: it lists only the CURRENT release per device. Every older build is a
// `SameAs` pointer at it, so a device like iPhone17,3 comes back with exactly
// one URL where the catalogue needs sixty-eight.
//
// The macOS side exists for one reason: `apfs_sealvolume` is not in an iPhone
// restore image, only in a macOS one. Since 2025 the two share a marketing
// version, so "the macOS that goes with iOS 26.1" is just "macOS 26.1".

import Compression
import Foundation

public enum VPhoneFirmwareIndex {
    public enum Error: Swift.Error, LocalizedError {
        case fetchFailed(URL, Int)
        case unexpectedShape(URL)
        case decompressionFailed
        case noRelease(String, String)

        public var errorDescription: String? {
            switch self {
            case let .fetchFailed(url, status):
                "HTTP \(status) from \(url.host() ?? url.absoluteString)"
            case let .unexpectedShape(url):
                "\(url.host() ?? url.absoluteString) answered in a shape this does not understand"
            case .decompressionFailed:
                "the firmware catalogue did not decompress"
            case let .noRelease(os, what):
                "the firmware catalogue lists no released \(os) \(what)"
            }
        }
    }

    public struct Release: Sendable {
        public let os: String
        public let version: String
        public let build: String
        public let url: URL
    }

    static let catalogueURL = URL(string: "https://api.appledb.dev/main.json.xz")!

    /// How long a downloaded catalogue is reused before it is fetched again.
    ///
    /// Apple ships a firmware every few weeks; a day-old catalogue is wrong
    /// only in the window between a release and the next refresh, and a user
    /// who hits that can delete the file. Re-downloading 8 MB for every
    /// `fw prepare` would be the worse trade.
    static let maxAge: TimeInterval = 24 * 60 * 60

    static var cacheFile: URL {
        VPhoneResources.userDataRoot()
            .appendingPathComponent("cache/appledb-main.json")
    }

    // MARK: - Queries

    /// Every released iOS restore URL for one device identifier, newest first.
    public static func restoreURLs(forDevice device: String) async throws -> [String] {
        try await releases(os: "iOS", device: device).map(\.url.absoluteString)
    }

    /// The released macOS restore image for a marketing version like "26.1".
    public static func macOSRelease(version: String) async throws -> Release {
        let matches = try await releases(os: "macOS", device: nil)
            .filter { $0.version == version }
        guard let release = matches.first else { throw Error.noRelease("macOS", version) }
        return release
    }

    /// Released `.ipsw` entries for an OS, optionally narrowed to one device,
    /// sorted newest version first.
    ///
    /// `beta` and `rc` are both excluded. A release-candidate build is signed
    /// and installable, but it is superseded within days and a catalogue that
    /// offered one as "the 26.1 image" would hand out a different file
    /// depending on the week.
    public static func releases(os: String, device: String?) async throws -> [Release] {
        let entries = try await catalogue()
        var out: [Release] = []
        for entry in entries {
            guard entry["osStr"] as? String == os,
                  entry["beta"] as? Bool != true,
                  entry["rc"] as? Bool != true,
                  let version = entry["version"] as? String,
                  let build = entry["build"] as? String ?? entry["uniqueBuild"] as? String,
                  let sources = entry["sources"] as? [[String: Any]]
            else { continue }
            if let device, !((entry["deviceMap"] as? [String])?.contains(device) ?? false) {
                continue
            }

            for source in sources where source["type"] as? String == "ipsw" {
                // A single release carries one source per hardware family, so
                // the device has to be matched on the SOURCE as well: the
                // Universal Mac image and an iPhone image sit side by side.
                if let device, let map = source["deviceMap"] as? [String], !map.contains(device) {
                    continue
                }
                guard let links = source["links"] as? [[String: Any]] else { continue }
                let active = links.filter { $0["active"] as? Bool != false }
                // `preferred` is the https CDN link; the rest are plain-http
                // mirrors of the same bytes.
                let chosen = active.first { $0["preferred"] as? Bool == true } ?? active.first
                if let string = chosen?["url"] as? String, let url = URL(string: string) {
                    out.append(Release(os: os, version: version, build: build, url: url))
                    break
                }
            }
        }
        return out.sorted { compareVersions($0.version, $1.version) == .orderedDescending }
    }

    /// Numeric, component by component: "26.10" is newer than "26.9", which
    /// string ordering gets backwards, and the firmware picker shows this list
    /// to a human.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r {
                return l < r ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    // MARK: - The catalogue

    static func catalogue() async throws -> [[String: Any]] {
        let data = try await catalogueData()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["ios"] as? [[String: Any]]
        else { throw Error.unexpectedShape(catalogueURL) }
        return entries
    }

    private static func catalogueData() async throws -> Data {
        let cache = cacheFile
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           let cached = try? Data(contentsOf: cache, options: .mappedIfSafe)
        {
            return cached
        }

        let (compressed, response) = try await URLSession.shared.data(from: catalogueURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // A stale catalogue beats no catalogue: the network is the thing
            // most likely to be missing, and last week's list still has every
            // firmware from last week.
            if let cached = try? Data(contentsOf: cache, options: .mappedIfSafe) {
                return cached
            }
            throw Error.fetchFailed(catalogueURL, http.statusCode)
        }

        let json = try decompressXZ(compressed)
        try? FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? json.write(to: cache)
        try? VPhoneHostFilePermissions.makeAccessible(at: cache)
        return json
    }

    /// `.xz`, through libcompression.
    ///
    /// `COMPRESSION_LZMA` reads the xz container, not bare LZMA, which is what
    /// the name suggests and not what it does. Streaming rather than
    /// `compression_decode_buffer` because the output size is not known in
    /// advance and is two orders of magnitude larger than the input.
    static func decompressXZ(_ input: Data) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil,
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
            == COMPRESSION_STATUS_OK
        else { throw Error.decompressionFailed }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 1 << 20
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        var output = Data()
        output.reserveCapacity(input.count * 12)
        var status = COMPRESSION_STATUS_OK
        input.withUnsafeBytes { raw in
            stream.src_ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            stream.src_size = raw.count
            repeat {
                stream.dst_ptr = chunk
                stream.dst_size = chunkSize
                status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue),
                )
                output.append(chunk, count: chunkSize - stream.dst_size)
            } while status == COMPRESSION_STATUS_OK
        }
        guard status == COMPRESSION_STATUS_END else { throw Error.decompressionFailed }
        return output
    }
}
