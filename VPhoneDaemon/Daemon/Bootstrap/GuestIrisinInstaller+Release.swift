import Darwin
import Foundation

// MARK: - Release and local package

extension GuestIrisinInstaller {
    static let releaseURL = URL(string: "https://api.github.com/repos/Lakr233/Irisin/releases/latest")!

    struct Asset {
        let tag: String
        let version: String
        let name: String
        let url: URL
        let digest: String
    }

    static func copyLocalPackage(_ path: String, to destination: URL) throws {
        let prefix = "/var/root/Library/Caches/vphoned-irisin-"
        guard path.hasPrefix(prefix), path.hasSuffix(".deb"),
              let id = UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(4))),
              path == prefix + id.uuidString + ".deb"
        else { throw GuestAPIError.invalidRequest("Invalid staged Irisin package path") }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw GuestAPIError.operationFailed("Could not open staged Irisin package")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= 64 * 1024 * 1024
        else { throw GuestAPIError.invalidRequest("Irisin package must be a regular file under 64 MiB") }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count == info.st_size else {
            throw GuestAPIError.operationFailed("Could not read the complete Irisin package")
        }
        try data.write(to: destination, options: .atomic)
        try? FileManager.default.removeItem(atPath: path)
    }

    static func releaseAsset(architecture: String) throws -> Asset {
        let data = try fetch(releaseURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              tag.range(of: "^v[0-9]+(\\.[0-9]+){2,3}$", options: .regularExpression) != nil,
              let assets = json["assets"] as? [[String: Any]]
        else { throw GuestAPIError.operationFailed("GitHub did not return a valid Irisin release") }
        let version = String(tag.dropFirst())
        let name = "wiki.qaq.irisin_\(version)_\(architecture).deb"
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
              let address = asset["browser_download_url"] as? String,
              let url = URL(string: address), url.scheme == "https", url.host == "github.com",
              url.path == "/Lakr233/Irisin/releases/download/\(tag)/\(name)",
              let rawDigest = asset["digest"] as? String,
              rawDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw GuestAPIError.operationFailed("The latest Irisin release has no verified \(architecture) package") }
        return Asset(tag: tag, version: version, name: name, url: url,
                     digest: String(rawDigest.dropFirst("sha256:".count)))
    }
}

// MARK: - HTTPS

extension GuestIrisinInstaller {
    private final class HTTPResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var value: Result<(Data, URLResponse), Error>?

        func finish(data: Data?, response: URLResponse?, error: Error?) {
            if let error {
                value = .failure(error)
            } else if let data, let response {
                value = .success((data, response))
            } else {
                value = .failure(GuestAPIError.operationFailed("Empty Irisin download response"))
            }
            semaphore.signal()
        }
    }

    static func fetch(_ url: URL, reportDownload: Bool = false) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        // A guest that has just booted may not have a route yet.
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("vphoned-Irisin-installer", forHTTPHeaderField: "User-Agent")
        let result = HTTPResult()
        let task = session.dataTask(with: request) { data, response, error in
            result.finish(data: data, response: response, error: error)
        }
        task.resume()
        let deadline = Date().addingTimeInterval(190)
        while result.semaphore.wait(timeout: .now() + 0.2) != .success {
            if reportDownload {
                downloadProgress(received: task.countOfBytesReceived,
                                 total: task.countOfBytesExpectedToReceive)
            }
            if Date() >= deadline {
                task.cancel()
                throw GuestAPIError.operationFailed("Irisin download timed out")
            }
        }
        if reportDownload {
            downloadProgress(received: task.countOfBytesReceived,
                             total: task.countOfBytesExpectedToReceive)
        }
        let (data, response) = try result.value!.get()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GuestAPIError.operationFailed("Irisin download returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw GuestAPIError.operationFailed("Irisin download exceeds 64 MiB")
        }
        return data
    }
}
