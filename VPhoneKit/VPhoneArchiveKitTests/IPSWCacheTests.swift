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
}
