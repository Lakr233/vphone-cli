import CryptoKit
import Foundation

/// Streams one file from GitHub into a fresh temporary directory, hashing as
/// it goes. Release assets redirect to storage on
/// another host, which gets the request without the token.
nonisolated enum VPhoneLaunchpadDownload {
    /// Returns the file and its hex SHA-256. The caller removes the file's
    /// directory when it is done with it. A response other than 200 throws
    /// what `refused` makes of its status code.
    static func fetch(
        _ request: URLRequest,
        as name: String,
        refused: @Sendable (Int) -> Error,
        progress: @escaping @Sendable (Int64) -> Void,
    ) async throws -> (URL, String) {
        var request = request
        request.setValue("vphone-launchpad", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: RedirectWithoutToken())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw refused(status)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-launchpad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
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

    /// The token is for api.github.com only. The signed storage URL it
    /// redirects to needs none and must not see it.
    private final class RedirectWithoutToken: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void,
        ) {
            var request = request
            if request.url?.host != task.originalRequest?.url?.host {
                request.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(request)
        }
    }
}
