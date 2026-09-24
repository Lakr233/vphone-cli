import CryptoKit
import Foundation
import VPhoneCoreKit

/// Resolves a local IPSW or downloads one into a reusable, validated cache.
/// Source archives are never rewritten. Remote downloads become visible only
/// after their BuildManifest can be read and their transfer size checks out.
public enum VPhoneIPSWCache {
    public struct Archive: Sendable {
        public let file: URL
        public let version: String
        public let build: String
    }

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedSource(String)
        case missingFile(URL)
        case invalidManifest(URL)
        case unexpectedHTTP(URL, Int)
        case incompleteDownload(URL, expected: Int64, actual: Int64)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSource(source): "Unsupported IPSW source: \(source)"
            case let .missingFile(file): "IPSW does not exist: \(file.path)"
            case let .invalidManifest(file): "IPSW has no readable BuildManifest.plist: \(file.path)"
            case let .unexpectedHTTP(url, status): "IPSW download returned HTTP \(status): \(url)"
            case let .incompleteDownload(url, expected, actual):
                "IPSW download from \(url) is incomplete: \(actual) of \(expected) bytes"
            }
        }
    }

    public static func resolve(
        _ source: String,
        in cacheDirectory: URL,
        session: URLSession = .shared,
    ) async throws -> Archive {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return try inspect(URL(fileURLWithPath: source))
        }
        if scheme == "file" {
            return try inspect(url)
        }
        guard scheme == "http" || scheme == "https" else {
            throw Error.unsupportedSource(source)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cache = cacheDirectory.appendingPathComponent(cacheName(for: url))
        if fm.fileExists(atPath: cache.path) {
            if let valid = try? inspect(cache) {
                try VPhoneHostFilePermissions.makeAccessible(at: cache)
                try VPhoneHostFilePermissions.makeDirectoryAccessible(at: cacheDirectory)
                return valid
            }
            try fm.removeItem(at: cache)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3 * 60 * 60
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Error.unexpectedHTTP(url, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let pending = cacheDirectory.appendingPathComponent(".\(cache.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: pending) }
        guard fm.createFile(atPath: pending.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: pending)
        defer { try? output.close() }
        var buffer = Data()
        var size: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1024 * 1024 {
                try output.write(contentsOf: buffer)
                size += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try output.write(contentsOf: buffer)
            size += Int64(buffer.count)
        }
        try output.close()
        if response.expectedContentLength > 0, size != response.expectedContentLength {
            throw Error.incompleteDownload(
                url,
                expected: response.expectedContentLength,
                actual: size,
            )
        }

        let metadata = try inspect(pending)
        try fm.moveItem(at: pending, to: cache)
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: cacheDirectory)
        return Archive(file: cache, version: metadata.version, build: metadata.build)
    }

    public static func inspect(_ file: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Error.missingFile(file)
        }
        guard let data = try? VPhoneArchiveReader.readMember("BuildManifest.plist", from: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let version = plist["ProductVersion"] as? String, !version.isEmpty,
              let build = plist["ProductBuildVersion"] as? String, !build.isEmpty
        else {
            throw Error.invalidManifest(file)
        }
        return Archive(file: file, version: version, build: build)
    }

    static func cacheName(for url: URL) -> String {
        let base = url.lastPathComponent
        let stem = base.lowercased().hasSuffix(".ipsw") ? String(base.dropLast(5)) : base
        let safe = String(stem.prefix(48).unicodeScalars.map { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122) || value == 45 || value == 46 || value == 95
                ? Character(scalar) : "_"
        })
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe.isEmpty ? "firmware" : safe)-\(suffix).ipsw"
    }
}
