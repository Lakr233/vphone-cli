import Foundation
import Testing
@testable import VPhoneArchiveKit

private final class IPSWStubProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var status = 200

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.payload.count)],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProgressReports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(done: Int64, total: Int64)] = []

    func append(_ done: Int64, _ total: Int64) {
        lock.withLock { storage.append((done, total)) }
    }

    var values: [(done: Int64, total: Int64)] {
        lock.withLock { storage }
    }
}

/// A server that answers range requests, as Apple's CDN does, and can close a
/// connection partway through a segment or replace the file between requests.
private final class RangeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var payload = Data()
    private var etag = "\"v1\""
    private var cutShortOnce: Set<Int64> = []
    private var replaceAfterProbe = false
    private var ranges: [String] = []

    func reset(payload: Data, cutShortOnce: Set<Int64> = [], replaceAfterProbe: Bool = false) {
        lock.withLock {
            self.payload = payload
            etag = "\"v1\""
            self.cutShortOnce = cutShortOnce
            self.replaceAfterProbe = replaceAfterProbe
            ranges = []
        }
    }

    var requestedRanges: [String] {
        lock.withLock { ranges }
    }

    /// The response to `range` and `ifRange`, and whether to end it halfway.
    func answer(range: String?, ifRange: String?) -> (status: Int, headers: [String: String], body: Data, cutShort: Bool) {
        lock.withLock {
            ranges.append(range ?? "")
            let current = etag
            if range == "bytes=0-0", replaceAfterProbe {
                etag = "\"v2\""
            }
            guard let range, ifRange == nil || ifRange == current,
                  let bounds = Self.bounds(range, size: payload.count)
            else {
                return (200, ["Content-Length": "\(payload.count)", "ETag": current], payload, false)
            }
            let body = payload.subdata(in: bounds.lowerBound ..< bounds.upperBound + 1)
            let headers = [
                "Content-Length": "\(body.count)",
                "Content-Range": "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(payload.count)",
                "ETag": current,
            ]
            let cutShort = cutShortOnce.remove(Int64(bounds.lowerBound)) != nil
            return (206, headers, body, cutShort)
        }
    }

    private static func bounds(_ range: String, size: Int) -> ClosedRange<Int>? {
        guard range.hasPrefix("bytes=") else { return nil }
        let parts = range.dropFirst(6).split(separator: "-")
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start <= end, start < size else {
            return nil
        }
        return start ... min(end, size - 1)
    }
}

private final class RangeStubProtocol: URLProtocol {
    static let server = RangeServer()

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let answer = Self.server.answer(
            range: request.value(forHTTPHeaderField: "Range"),
            ifRange: request.value(forHTTPHeaderField: "If-Range"),
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: answer.status,
            httpVersion: "HTTP/1.1",
            headerFields: answer.headers,
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Cut short: the connection closes after half the stated length.
        client?.urlProtocol(self, didLoad: answer.cutShort ? answer.body.prefix(answer.body.count / 2) : answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("IPSW cache", .serialized)
struct IPSWCacheTests {
    private func fixture(in root: URL) throws -> URL {
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "ProductVersion": "26.6.2", "ProductBuildVersion": "23G90",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: manifest,
            format: .xml,
            options: 0,
        )
        try data.write(to: files.appendingPathComponent("BuildManifest.plist"))
        let archive = root.appendingPathComponent("input.ipsw")
        try VPhoneArchiveWriter.create(archive: archive, from: files)
        return archive
    }

    @Test func `local source reads manifest without copying`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let result = try await VPhoneIPSWCache.resolve(
            source.path,
            in: root.appendingPathComponent("cache"),
        )
        #expect(result.file == source)
        #expect(result.version == "26.6.2")
        #expect(result.build == "23G90")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }

    @Test func `a local archive that no longer exists is not here, and an unreadable one still fails`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let source = try fixture(in: root)
        #expect(try VPhoneIPSWCache.localArchive(source.path, in: cache)?.build == "23G90")
        #expect(try VPhoneIPSWCache.localArchive(source.absoluteString, in: cache)?.build == "23G90")

        // Deleted since: nil, so vm template find falls back to the sources
        // a template recorded instead of failing (B4).
        let missing = root.appendingPathComponent("gone/iPhone.ipsw")
        #expect(try VPhoneIPSWCache.localArchive(missing.path, in: cache) == nil)
        #expect(try VPhoneIPSWCache.localArchive(missing.absoluteString, in: cache) == nil)
        // A remote source that is not cached: nil, nothing downloaded.
        #expect(try VPhoneIPSWCache.localArchive("https://example.invalid/iPhone.ipsw", in: cache) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path))

        // Something at the path that is not an IPSW is still an error.
        let junk = root.appendingPathComponent("junk.ipsw")
        try Data("not a zip".utf8).write(to: junk)
        #expect(throws: (any Error).self) { try VPhoneIPSWCache.localArchive(junk.path, in: cache) }
    }

    @Test func `download replaces invalid cache only after validation`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        IPSWStubProtocol.payload = try Data(contentsOf: source)
        IPSWStubProtocol.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IPSWStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try #require(URL(string: "https://example.invalid/input.ipsw"))
        let cacheDir = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent(VPhoneIPSWCache.cacheName(for: url))
        try Data("damaged".utf8).write(to: cached)

        let result = try await VPhoneIPSWCache.resolve(
            url.absoluteString,
            in: cacheDir,
            session: session,
        )
        #expect(result.file == cached)
        #expect(result.build == "23G90")
        #expect(try Data(contentsOf: cached) == Data(contentsOf: source))

        IPSWStubProtocol.status = 503
        let reused = try await VPhoneIPSWCache.resolve(
            url.absoluteString,
            in: cacheDir,
            session: session,
        )
        #expect(reused.file == cached)
    }

    /// A cache moved to another volume and linked back in its place, the way
    /// #655 suggests relocating storage, downloads into the link's target.
    @Test func `a symlinked cache directory downloads into its target`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        IPSWStubProtocol.payload = try Data(contentsOf: source)
        IPSWStubProtocol.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IPSWStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try #require(URL(string: "https://example.invalid/input.ipsw"))
        let relocated = root.appendingPathComponent("relocated")
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        let cacheDir = root.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(at: cacheDir, withDestinationURL: relocated)

        let result = try await VPhoneIPSWCache.resolve(
            url.absoluteString,
            in: cacheDir,
            session: session,
        )
        #expect(result.build == "23G90")
        let cached = relocated.appendingPathComponent(VPhoneIPSWCache.cacheName(for: url))
        #expect(try Data(contentsOf: cached) == Data(contentsOf: source))
    }

    @Test func `failed download leaves no reusable cache`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        IPSWStubProtocol.payload = Data("server unavailable".utf8)
        IPSWStubProtocol.status = 503
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IPSWStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try #require(URL(string: "https://example.invalid/input.ipsw"))
        let cacheDir = root.appendingPathComponent("cache")
        await #expect(throws: VPhoneIPSWCache.Error.self) {
            try await VPhoneIPSWCache.resolve(url.absoluteString, in: cacheDir, session: session)
        }
        #expect(!FileManager.default.fileExists(
            atPath: cacheDir.appendingPathComponent(VPhoneIPSWCache.cacheName(for: url)).path,
        ))
    }

    /// Launchpad shows this on its firmware step (#590). A cache hit downloads
    /// nothing and reports nothing.
    @Test func `download reports progress against the stated size`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        IPSWStubProtocol.payload = try Data(contentsOf: source)
        IPSWStubProtocol.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IPSWStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let size = Int64(IPSWStubProtocol.payload.count)
        let reports = ProgressReports()
        let cacheDir = root.appendingPathComponent("cache")
        _ = try await VPhoneIPSWCache.resolve(
            "https://example.invalid/input.ipsw",
            in: cacheDir,
            session: session,
            progress: { done, total in reports.append(done, total) },
        )
        let downloaded = reports.values
        #expect(!downloaded.isEmpty)
        #expect(downloaded.allSatisfy { $0.total == size })
        #expect(downloaded.last?.done == size)

        let cached = ProgressReports()
        _ = try await VPhoneIPSWCache.resolve(
            "https://example.invalid/input.ipsw",
            in: cacheDir,
            session: session,
            progress: { done, total in cached.append(done, total) },
        )
        #expect(cached.values.isEmpty)
    }

    /// The cache is shared by every machine, so a download killed midway would
    /// otherwise leave its partial file there for good.
    @Test func `abandoned partial downloads are removed and live ones kept`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        IPSWStubProtocol.payload = try Data(contentsOf: source)
        IPSWStubProtocol.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IPSWStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let cacheDir = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let abandoned = cacheDir.appendingPathComponent(".other.ipsw.A.partial")
        let live = cacheDir.appendingPathComponent(".other.ipsw.B.partial")
        try Data("stale".utf8).write(to: abandoned)
        try Data("live".utf8).write(to: live)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)],
            ofItemAtPath: abandoned.path,
        )

        _ = try await VPhoneIPSWCache.resolve(
            "https://example.invalid/input.ipsw",
            in: cacheDir,
            session: session,
        )
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    // MARK: - Concurrent download

    private func rangeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func randomPayload(_ count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
    }

    private func emptyFile(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("download.partial")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        return file
    }

    /// Several connections write their segments into one file; the bytes must
    /// land exactly where they belong, and progress must add up across them.
    @Test func `segments over several connections reassemble the file`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = randomPayload(1_000_003)
        RangeStubProtocol.server.reset(payload: payload)
        let session = rangeSession()
        defer { session.invalidateAndCancel() }
        let file = try emptyFile(in: root)
        let reports = ProgressReports()

        try await VPhoneIPSWCache.download(
            #require(URL(string: "https://example.invalid/input.ipsw")),
            into: file,
            session: session,
            connections: 4,
            segmentSize: 64 * 1024,
            progress: { done, total in reports.append(done, total) },
        )

        #expect(try Data(contentsOf: file) == payload)
        let ranges = RangeStubProtocol.server.requestedRanges
        #expect(ranges.first == "bytes=0-0")
        #expect(ranges.count == 1 + 16)
        #expect(ranges.contains("bytes=983040-1000002"))
        let values = reports.values
        #expect(values.allSatisfy { $0.total == Int64(payload.count) })
        #expect(values.last?.done == Int64(payload.count))
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.done < $1.done })
    }

    @Test func `a segment cut short resumes where it stopped`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = randomPayload(300_000)
        RangeStubProtocol.server.reset(payload: payload, cutShortOnce: [100_000])
        let session = rangeSession()
        defer { session.invalidateAndCancel() }
        let file = try emptyFile(in: root)

        try await VPhoneIPSWCache.download(
            #require(URL(string: "https://example.invalid/input.ipsw")),
            into: file,
            session: session,
            connections: 3,
            segmentSize: 100_000,
            progress: nil,
        )

        #expect(try Data(contentsOf: file) == payload)
        // Half of 100000-199999 arrived before the connection closed; only the rest is asked again.
        #expect(RangeStubProtocol.server.requestedRanges.contains("bytes=150000-199999"))
    }

    /// If-Range carries the probe's ETag, so a file replaced on the server
    /// fails the download instead of mixing two files' bytes.
    @Test func `a file replaced during the download fails it`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        RangeStubProtocol.server.reset(payload: randomPayload(200_000), replaceAfterProbe: true)
        let session = rangeSession()
        defer { session.invalidateAndCancel() }
        let file = try emptyFile(in: root)

        await #expect {
            try await VPhoneIPSWCache.download(
                #require(URL(string: "https://example.invalid/input.ipsw")),
                into: file,
                session: session,
                connections: 2,
                segmentSize: 50000,
                progress: nil,
            )
        } throws: { error in
            if case .changedDuringDownload? = error as? VPhoneIPSWCache.Error {
                true
            } else {
                false
            }
        }
    }

    /// One connection, or a server that ignores ranges, downloads as one GET.
    @Test func `one connection downloads the file as a single request`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = randomPayload(200_000)
        RangeStubProtocol.server.reset(payload: payload)
        let session = rangeSession()
        defer { session.invalidateAndCancel() }
        let file = try emptyFile(in: root)

        try await VPhoneIPSWCache.download(
            #require(URL(string: "https://example.invalid/input.ipsw")),
            into: file,
            session: session,
            connections: 1,
            segmentSize: 50000,
            progress: nil,
        )

        #expect(try Data(contentsOf: file) == payload)
        #expect(RangeStubProtocol.server.requestedRanges == [""])
    }

    @Test func `content range parses only a complete byte range`() {
        func parse(_ value: String) -> [Int64]? {
            let url = URL(string: "https://example.invalid/")!
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": value])!
            return VPhoneIPSWCache.contentRange(of: response).map { [$0.start, $0.end, $0.total] }
        }
        #expect(parse("bytes 0-0/12343857610") == [0, 0, 12_343_857_610])
        #expect(parse("bytes 100-199/1000") == [100, 199, 1000])
        #expect(parse("bytes 0-0/*") == nil)
        #expect(parse("bytes */1000") == nil)
        #expect(parse("bytes 10-5/1000") == nil)
        #expect(parse("bytes 0-1000/1000") == nil)
    }

    // MARK: - Pairing

    private func ipsw(in root: URL, _ name: String, productTypes: [String], deviceClasses: [String]) throws -> VPhoneIPSWCache.Archive {
        let files = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "ProductVersion": "27.0", "ProductBuildVersion": "24A435",
            "SupportedProductTypes": productTypes,
            "BuildIdentities": deviceClasses.map { ["Info": ["DeviceClass": $0]] },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: files.appendingPathComponent("BuildManifest.plist"))
        let archive = root.appendingPathComponent("\(name).ipsw")
        try VPhoneArchiveWriter.create(archive: archive, from: files)
        return try VPhoneIPSWCache.inspect(archive)
    }

    @Test func `pair check reads each manifest and names the mistake`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try ipsw(in: root, "phone", productTypes: ["iPhone17,3"], deviceClasses: ["D47AP", "D47AP"])
        let cloud = try ipsw(in: root, "cloud", productTypes: ["iProd99,1"], deviceClasses: ["vresearch101ap", "vphone600ap"])
        let other = try ipsw(in: root, "other", productTypes: ["iPhone16,1"], deviceClasses: ["d83ap"])

        #expect(phone.productTypes == ["iPhone17,3"])
        #expect(phone.deviceClasses == ["d47ap"])
        #expect(cloud.deviceClasses == ["vresearch101ap", "vphone600ap"])

        try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: cloud)
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: cloud, cloudOS: phone)
        } throws: { error in
            if case .swappedSources? = error as? VPhoneIPSWCache.Error {
                true
            } else {
                false
            }
        }
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: other, cloudOS: cloud)
        } throws: { error in
            if case .notIPhoneSource? = error as? VPhoneIPSWCache.Error {
                true
            } else {
                false
            }
        }
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: phone)
        } throws: { error in
            if case .notCloudOSSource? = error as? VPhoneIPSWCache.Error {
                true
            } else {
                false
            }
        }
    }

    // `fw prepare` then takes the research board's components and checks that a
    // kernelcache recipe exists for them.
    @Test func `a cloudOS without the virtual iPhone pairs, the research board standing in`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try ipsw(in: root, "phone", productTypes: ["iPhone17,3"], deviceClasses: ["D47AP"])
        // cloudOS 26.4 (23E244) and later: the PCC boards and vresearch101ap, no vphone600ap.
        let cloud = try ipsw(in: root, "cloud", productTypes: ["ComputeModule14,1", "Mac14,14"],
                             deviceClasses: ["j226cap", "j236cap", "vresearch101ap"])

        try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: cloud)
    }

    @Test func `a known TV donor pairs with cloudOS without admitting unknown TVs`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tv = try ipsw(in: root, "tv", productTypes: ["AppleTV5,3"], deviceClasses: ["J42DAP"])
        let cloud = try ipsw(in: root, "cloud", productTypes: ["iProd99,1"], deviceClasses: ["vresearch101ap", "vphone600ap"])
        let otherTV = try ipsw(in: root, "other-tv", productTypes: ["AppleTV14,1"], deviceClasses: ["j255ap"])

        try VPhoneIPSWCache.checkPair(iPhone: tv, cloudOS: cloud)
        #expect(VPhoneIPSWCache.guestDevice(for: tv) == .appleTV5_3)
        #expect(tv.deviceClasses == ["j42dap"])
        #expect(VPhoneIPSWCache.guestProductTypes.contains("AppleTV5,3"))
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: otherTV, cloudOS: cloud)
        } throws: { error in
            if case .notIPhoneSource? = error as? VPhoneIPSWCache.Error { true } else { false }
        }
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: cloud, cloudOS: tv)
        } throws: { error in
            if case .swappedSources? = error as? VPhoneIPSWCache.Error { true } else { false }
        }
    }

    @Test func `HomePod mini pairs with cloudOS without admitting other audio accessories`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let homePod = try ipsw(in: root, "homepod-mini", productTypes: ["AudioAccessory5,1"], deviceClasses: ["B520AP"])
        let cloud = try ipsw(in: root, "cloud", productTypes: ["iProd99,1"], deviceClasses: ["vresearch101ap", "vphone600ap"])
        let other = try ipsw(in: root, "homepod", productTypes: ["AudioAccessory1,1"], deviceClasses: ["b238ap"])

        try VPhoneIPSWCache.checkPair(iPhone: homePod, cloudOS: cloud)
        #expect(VPhoneIPSWCache.guestDevice(for: homePod) == .audioAccessory5_1)
        #expect(homePod.deviceClasses == ["b520ap"])
        #expect(VPhoneIPSWCache.guestProductTypes.contains("AudioAccessory5,1"))
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: other, cloudOS: cloud)
        } throws: { error in
            if case .notIPhoneSource? = error as? VPhoneIPSWCache.Error { true } else { false }
        }
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: cloud, cloudOS: homePod)
        } throws: { error in
            if case .swappedSources? = error as? VPhoneIPSWCache.Error { true } else { false }
        }
    }

    @Test func `an iPad IPSW the guest device list knows pairs with cloudOS`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pad = try ipsw(in: root, "pad", productTypes: ["iPad16,1", "iPad16,2"], deviceClasses: ["j410ap", "j411ap"])
        let cloud = try ipsw(in: root, "cloud", productTypes: ["iProd99,1"], deviceClasses: ["vresearch101ap", "vphone600ap"])
        let otherPad = try ipsw(in: root, "other-pad", productTypes: ["iPad13,1"], deviceClasses: ["j307ap"])

        try VPhoneIPSWCache.checkPair(iPhone: pad, cloudOS: cloud)
        #expect(VPhoneIPSWCache.guestDevice(for: pad) == .iPad16_1)
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: otherPad, cloudOS: cloud)
        } throws: { error in
            if case .notIPhoneSource? = error as? VPhoneIPSWCache.Error {
                true
            } else {
                false
            }
        }
    }
}
