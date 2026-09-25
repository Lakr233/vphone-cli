import CryptoKit
import Foundation

/// A GitHub release that carries a `VPhone-<tag>.zip` asset. GitHub records a
/// SHA-256 digest for every asset, which is what the download is checked
/// against, here and again in the helper.
nonisolated struct VPhoneLaunchpadRelease: Identifiable, Hashable, Sendable {
    let version: String
    let publishedAt: Date
    let isPrerelease: Bool
    let assetName: String
    let downloadURL: URL
    let size: Int64
    let sha256: String

    var id: String {
        version
    }

    static let endpoint = URL(string: "https://api.github.com/repos/Lakr233/vphone-cli/releases?per_page=30")!

    // MARK: - Listing

    static func fetch() async throws -> [VPhoneLaunchpadRelease] {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("vphone-launchpad", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VPhoneLaunchpadError("GitHub answered the release list with an error.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode([Payload].self, from: data)
        return payload.compactMap { release in
            guard !release.draft, VPhoneLaunchpadNames.isValidVersion(release.tag_name) else {
                return nil
            }
            let asset = release.assets.first {
                $0.name.range(of: "^VPhone-.+\\.zip$", options: .regularExpression) != nil
                    && ($0.digest ?? "").hasPrefix("sha256:")
            }
            guard let asset, let digest = asset.digest else {
                return nil
            }
            return VPhoneLaunchpadRelease(
                version: release.tag_name,
                publishedAt: release.published_at ?? .distantPast,
                isPrerelease: release.prerelease,
                assetName: asset.name,
                downloadURL: asset.browser_download_url,
                size: asset.size,
                sha256: String(digest.dropFirst("sha256:".count)),
            )
        }
        .sorted { $0.publishedAt > $1.publishedAt }
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let digest: String?
            let browser_download_url: URL
        }

        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let published_at: Date?
        let assets: [Asset]
    }

    // MARK: - Download

    /// Downloads the asset into a fresh temporary directory, hashing as it
    /// goes. Returns the file and its hex SHA-256.
    @concurrent func download(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, String) {
        var request = URLRequest(url: downloadURL)
        request.setValue("vphone-launchpad", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VPhoneLaunchpadError("The download of \(assetName) failed.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-launchpad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(assetName)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }

        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                hasher.update(data: buffer)
                try output.write(contentsOf: buffer)
                received += Int64(buffer.count)
                progress(received)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        hasher.update(data: buffer)
        try output.write(contentsOf: buffer)
        received += Int64(buffer.count)
        progress(received)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (file, digest)
    }
}
