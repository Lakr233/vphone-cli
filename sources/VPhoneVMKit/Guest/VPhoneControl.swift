import CryptoKit
import Darwin
import Foundation
import Virtualization

/// The VM UI's direct HTTP client over VSOCK. It does not open a host TCP
/// listener; only --api-listen creates one through VPhoneAPIProxy.
@MainActor
final class VPhoneControl {
    enum ControlError: Error, CustomStringConvertible {
        case notConnected
        case unsupportedCapability(String)
        case protocolError(String)
        case guestError(String)

        var description: String {
            switch self {
            case .notConnected: "not connected to vphoned"
            case .unsupportedCapability(let value): "guest does not support capability: \(value)"
            case .protocolError(let value): "API protocol error: \(value)"
            case .guestError(let value): value
            }
        }
    }

    struct ClipboardContent {
        let text: String?
        let types: [String]
        let hasImage: Bool
        let changeCount: Int
        let imageData: Data?
    }

    private weak var device: VZVirtioSocketDevice?
    private var monitor: Task<Void, Never>?
    private var orderedInput: Task<Void, Never>?
    private(set) var isConnected = false
    private(set) var guestCaps: [String] = []
    private(set) var guestIP: String?
    private(set) var guestIOSVersion: String?
    var guestBinaryURL: URL?
    var onConnect: (([String]) -> Void)?
    var onDisconnect: (() -> Void)?

    var useGuestTouchInjection: Bool {
        guard isConnected, guestCaps.contains("touch"),
              let major = guestIOSVersion.flatMap({ Int($0.split(separator: ".").first ?? "") })
        else { return false }
        return major < 26
    }

    func connect(device: VZVirtioSocketDevice) {
        self.device = device
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probe()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        orderedInput?.cancel()
        orderedInput = nil
        device = nil
        setDisconnected()
    }

    private func probe() async {
        do {
            let response = try await http(method: "GET", path: "/v1/health")
            guard response.status == 200,
                  let info = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  info["api_version"] as? Int == 1 else {
                throw ControlError.protocolError("incompatible guest API")
            }
            if let binary = guestBinaryURL,
               let data = try? Data(contentsOf: binary, options: .mappedIfSafe) {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if hash != info["binary_hash"] as? String {
                    print("[control] updating vphoned over HTTP...")
                    try await createDirectory(path: "/var/root/Library/Caches")
                    try await uploadFile(path: "/var/root/Library/Caches/vphoned", data: data)
                    _ = try await call("agent.apply_update", params: ["sha256": hash])
                    setDisconnected()
                    return
                }
            }
            guestCaps = info["capabilities"] as? [String] ?? []
            guestIP = info["ip"] as? String
            guestIOSVersion = info["ios"] as? String
            if !isConnected {
                isConnected = true
                print("[control] connected to vphoned HTTP API (iOS \(guestIOSVersion ?? "?"))")
                onConnect?(guestCaps)
            }
        } catch {
            setDisconnected()
        }
    }

    private func setDisconnected() {
        let wasConnected = isConnected
        isConnected = false
        guestCaps = []
        guestIP = nil
        guestIOSVersion = nil
        if wasConnected { onDisconnect?() }
    }

    func sendHIDPress(page: UInt32, usage: UInt32) { sendHID(page: page, usage: usage, down: nil) }
    func sendHIDDown(page: UInt32, usage: UInt32) { sendHID(page: page, usage: usage, down: true) }
    func sendHIDUp(page: UInt32, usage: UInt32) { sendHID(page: page, usage: usage, down: false) }

    private func sendHID(page: UInt32, usage: UInt32, down: Bool?) {
        var params: [String: Any] = ["page": page, "usage": usage]
        if let down { params["down"] = down }
        enqueueInput("input.hid", params: params)
    }

    func sendTouch(phase: Int, x: Double, y: Double) {
        let name = switch phase { case 0: "down"; case 1: "move"; default: "up" }
        enqueueInput("input.touch", params: ["phase": name, "x": x, "y": y, "normalized": true])
    }

    private func enqueueInput(_ method: String, params: [String: Any]) {
        let previous = orderedInput
        orderedInput = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do { _ = try await call(method, params: params) }
            catch { print("[control] \(method): \(error)") }
        }
    }

    func sendDevModeStatus() async throws -> Bool {
        try await call("developer_mode.status")["enabled"] as? Bool ?? false
    }

    func sendPing() async throws { _ = try await http(method: "GET", path: "/v1/health") }

    func sendVersion() async throws -> String {
        let response = try await http(method: "GET", path: "/v1/health")
        let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return value?["binary_hash"] as? String ?? "unknown"
    }

    /// Retains the UI-facing request shape while all transport and guest
    /// operations use the versioned HTTP API.
    func sendRequest(_ request: [String: Any]) async throws -> ([String: Any], Data?) {
        guard let type = request["t"] as? String else {
            throw ControlError.protocolError("missing operation")
        }
        if type == "file_get" {
            return ([:], try await downloadFile(path: request["path"] as? String ?? ""))
        }
        if type == "clipboard_get" {
            var info = try await call("clipboard.get")
            let image = (info["has_image"] as? Bool == true)
                ? try await http(method: "GET", path: "/v1/clipboard/image").body : nil
            info["ok"] = true
            return (info, image)
        }
        let method: String
        switch type {
        case "devmode": method = "developer_mode.status"
        case "file_list": method = "files.list"
        case "file_mkdir": method = "files.mkdir"
        case "file_delete": method = "files.remove"
        case "file_rename": method = "files.rename"
        case "ipa_install": method = "apps.install"
        case "clipboard_set": method = "clipboard.set"
        case "app_list": method = "apps.list"
        case "app_launch": method = "apps.launch"
        case "app_terminate": method = "apps.terminate"
        case "app_foreground": method = "apps.foreground"
        case "keychain_list": method = "keychain.list"
        case "keychain_add": method = "keychain.add"
        case "open_url": method = "apps.open_url"
        case "settings_get": method = "settings.get"
        case "settings_set": method = "settings.set"
        case "low_power_mode": method = "power.low_power_mode"
        case "accessibility_tree": method = "accessibility.tree"
        default: throw ControlError.protocolError("unknown operation \(type)")
        }
        var params = request
        params.removeValue(forKey: "t")
        var result = try await call(method, params: params)
        if result["ok"] == nil { result["ok"] = true }
        return (result, nil)
    }

    private func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let object: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        let body = try JSONSerialization.data(withJSONObject: object)
        let response = try await http(method: "POST", path: "/v1/rpc", body: body)
        guard let envelope = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw ControlError.protocolError("invalid JSON response") }
        if let error = envelope["error"] as? [String: Any] {
            throw ControlError.guestError(error["message"] as? String ?? "Guest operation failed")
        }
        guard response.status == 200, let result = envelope["result"] as? [String: Any]
        else { throw ControlError.protocolError("missing result (HTTP \(response.status))") }
        return result
    }

    func listFiles(path: String) async throws -> [[String: Any]] {
        let (value, _) = try await sendRequest(["t": "file_list", "path": path])
        guard let entries = value["entries"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing file entries")
        }
        return entries
    }

    func downloadFile(path: String) async throws -> Data {
        let response = try await http(method: "GET", path: try filePath(path))
        guard response.status == 200 else { throw try httpError(response) }
        return response.body
    }

    func uploadFile(path: String, data: Data, permissions: String = "644") async throws {
        let response = try await http(method: "PUT", path: try filePath(path), body: data,
                                      contentType: "application/octet-stream")
        guard response.status == 200 else { throw try httpError(response) }
    }

    func createDirectory(path: String) async throws {
        _ = try await call("files.mkdir", params: ["path": path])
    }

    func deleteFile(path: String) async throws {
        _ = try await call("files.remove", params: ["path": path, "recursive": true])
    }

    func renameFile(from: String, to: String) async throws {
        _ = try await call("files.rename", params: ["from": from, "to": to])
    }

    func installIPA(localURL: URL) async throws -> String {
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        let path = "/var/mobile/Documents/vphone-installs/\(UUID().uuidString)-\(localURL.lastPathComponent)"
        try await createDirectory(path: "/var/mobile/Documents/vphone-installs")
        try await uploadFile(path: path, data: data)
        defer { Task { try? await deleteFile(path: path) } }
        let result = try await call("apps.install", params: ["path": path, "registration": "User"])
        return result["msg"] as? String ?? "Installed \(localURL.lastPathComponent)."
    }

    func clipboardGet() async throws -> ClipboardContent {
        let (info, image) = try await sendRequest(["t": "clipboard_get"])
        return ClipboardContent(text: info["text"] as? String, types: info["types"] as? [String] ?? [],
                                hasImage: info["has_image"] as? Bool ?? false,
                                changeCount: info["change_count"] as? Int ?? 0, imageData: image)
    }

    func clipboardSet(text: String) async throws {
        _ = try await call("clipboard.set", params: ["text": text])
    }

    func clipboardSet(imageData: Data) async throws {
        let response = try await http(method: "PUT", path: "/v1/clipboard/image", body: imageData,
                                      contentType: "application/octet-stream")
        guard response.status == 200 else { throw try httpError(response) }
    }

    func sendLocation(latitude: Double, longitude: Double, altitude: Double,
                      horizontalAccuracy: Double, verticalAccuracy: Double,
                      speed: Double, course: Double) {
        Task {
            do { _ = try await call("location.set", params: [
                "latitude": latitude, "longitude": longitude, "altitude": altitude,
                "horizontal_accuracy": horizontalAccuracy, "vertical_accuracy": verticalAccuracy,
                "speed": speed, "course": course,
            ]) } catch { print("[control] location: \(error)") }
        }
    }

    func sendLocationStop() {
        Task { do { _ = try await call("location.clear") }
               catch { print("[control] location clear: \(error)") } }
    }

    private func filePath(_ guestPath: String) throws -> String {
        guard guestPath.hasPrefix("/"), !guestPath.contains("\0") else {
            throw ControlError.protocolError("guest path must be absolute")
        }
        var components = URLComponents()
        components.path = "/v1/files/content"
        components.queryItems = [URLQueryItem(name: "path", value: guestPath)]
        return components.string ?? ""
    }

    private func httpError(_ response: VPhoneHTTPResponse) throws -> ControlError {
        let body = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let error = body?["error"] as? [String: Any]
        return .guestError(error?["message"] as? String ?? "HTTP \(response.status)")
    }

    private func http(method: String, path: String, body: Data = Data(),
                      contentType: String = "application/json") async throws -> VPhoneHTTPResponse {
        guard let device else { throw ControlError.notConnected }
        let socket = await withCheckedContinuation {
            (continuation: CheckedContinuation<VPhoneSocketResult, Never>) in
            device.connect(toPort: 1339) { continuation.resume(returning: VPhoneSocketResult($0)) }
        }
        let connection = try socket.result.get()
        let transaction = VPhoneHTTPTransaction(connection: connection, method: method, path: path,
                                                body: body, contentType: contentType)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try transaction.run()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private struct VPhoneHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

private struct VPhoneSocketResult: @unchecked Sendable {
    let result: Result<VZVirtioSocketConnection, any Error>
    init(_ result: Result<VZVirtioSocketConnection, any Error>) { self.result = result }
}

private final class VPhoneHTTPTransaction: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
    let method: String
    let path: String
    let body: Data
    let contentType: String

    init(connection: VZVirtioSocketConnection, method: String, path: String,
         body: Data, contentType: String) {
        self.connection = connection
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType
    }

    func run() throws -> VPhoneHTTPResponse {
        let fd = connection.fileDescriptor
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        let headers = "\(method) \(path) HTTP/1.1\r\nHost: vphoned\r\nConnection: close\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n"
        try write(fd, data: Data(headers.utf8))
        if !body.isEmpty { try write(fd, data: body) }

        var received = Data()
        let marker = Data("\r\n\r\n".utf8)
        while received.range(of: marker) == nil {
            guard received.count < 64 * 1024 else { throw VPhoneControl.ControlError.protocolError("HTTP headers too large") }
            try readMore(fd, into: &received)
        }
        let boundary = received.range(of: marker)!
        let header = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw VPhoneControl.ControlError.protocolError("invalid HTTP status")
        }
        guard let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)),
              length >= 0, length <= 2_147_483_647 else {
            throw VPhoneControl.ControlError.protocolError("missing HTTP content length")
        }
        var payload = Data(received[boundary.upperBound...])
        while payload.count < length { try readMore(fd, into: &payload) }
        guard payload.count == length else {
            throw VPhoneControl.ControlError.protocolError("HTTP body length mismatch")
        }
        return VPhoneHTTPResponse(status: status, body: payload)
    }

    private func write(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.write(fd, base + offset, bytes.count - offset)
                if sent <= 0 { throw VPhoneControl.ControlError.notConnected }
                offset += sent
            }
        }
    }

    private func readMore(_ fd: Int32, into data: inout Data) throws {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else { throw VPhoneControl.ControlError.notConnected }
        data.append(contentsOf: bytes[..<count])
    }
}
