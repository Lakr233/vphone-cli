import Foundation
import Testing
@testable import VPhoneArchive

private final class IPSWStubProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.payload.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
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
            fromPropertyList: manifest, format: .xml, options: 0
        )
        try data.write(to: files.appendingPathComponent("BuildManifest.plist"))
        let archive = root.appendingPathComponent("input.ipsw")
        try VPhoneArchiveWriter.create(archive: archive, from: files)
        return archive
    }

    @Test func localSourceReadsManifestWithoutCopying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let result = try await VPhoneIPSWCache.resolve(
            source.path, in: root.appendingPathComponent("cache")
        )
        #expect(result.file == source)
        #expect(result.version == "26.6.2")
        #expect(result.build == "23G90")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }

    @Test func downloadReplacesInvalidCacheOnlyAfterValidation() async throws {
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

        let url = URL(string: "https://example.invalid/input.ipsw")!
        let cacheDir = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent(VPhoneIPSWCache.cacheName(for: url))
        try Data("damaged".utf8).write(to: cached)

        let result = try await VPhoneIPSWCache.resolve(
            url.absoluteString, in: cacheDir, session: session
        )
        #expect(result.file == cached)
        #expect(result.build == "23G90")
        #expect(try Data(contentsOf: cached) == Data(contentsOf: source))

        IPSWStubProtocol.status = 503
        let reused = try await VPhoneIPSWCache.resolve(
            url.absoluteString, in: cacheDir, session: session
        )
        #expect(reused.file == cached)
    }

    @Test func failedDownloadLeavesNoReusableCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        IPSWStubProtocol.payload = Data("server unavailable".utf8)
        IPSWStubProtocol.status = 503
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IPSWStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "https://example.invalid/input.ipsw")!
        let cacheDir = root.appendingPathComponent("cache")
        await #expect(throws: VPhoneIPSWCache.Error.self) {
            try await VPhoneIPSWCache.resolve(url.absoluteString, in: cacheDir, session: session)
        }
        #expect(!FileManager.default.fileExists(
            atPath: cacheDir.appendingPathComponent(VPhoneIPSWCache.cacheName(for: url)).path
        ))
    }
}
