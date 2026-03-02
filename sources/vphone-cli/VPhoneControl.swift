import CryptoKit
import Foundation
import Virtualization

/// Host-side client for the vphoned guest agent.
///
/// Communicates over vsock using length-prefixed JSON (vphone-control protocol).
/// Each message is `[uint32 big-endian length][UTF-8 JSON]` where JSON
/// always carries `"v"` (protocol version), `"t"` (message type), and
/// optionally `"id"` (request ID, echoed in responses).
///
/// Auto-update: if `guestBinaryURL` is set, the hello message includes
/// its SHA-256 hash. When the guest replies with `need_update`, we push
/// the binary as a raw transfer (`{"t":"update","size":N}` + N bytes).
@MainActor
class VPhoneControl {
    private static let protocolVersion = 1
    private static let vsockPort: UInt32 = 1337

    private var connection: VZVirtioSocketConnection?
    private weak var device: VZVirtioSocketDevice?
    private(set) var isConnected = false
    private(set) var guestName = ""
    private(set) var guestCaps: [String] = []

    /// Path to the signed vphoned binary. When set, enables auto-update.
    var guestBinaryURL: URL?

    /// Called when guest is ready (not updating). Receives guest capabilities.
    var onConnect: (([String]) -> Void)?

    /// Called when the guest disconnects (before reconnect attempt).
    var onDisconnect: (() -> Void)?

    private var guestBinaryData: Data?
    private var guestBinaryHash: String?
    private var nextRequestId: UInt64 = 0

    // MARK: - Pending Requests

    /// Callback for a pending request. Called on the read-loop queue.
    private struct PendingRequest: @unchecked Sendable {
        let handler: (Result<([String: Any], Data?), any Error>) -> Void
    }

    private let pendingLock = NSLock()
    private nonisolated(unsafe) var pendingRequests: [String: PendingRequest] = [:]

    private nonisolated func addPending(
        id: String, handler: @escaping (Result<([String: Any], Data?), any Error>) -> Void
    ) {
        pendingLock.lock()
        pendingRequests[id] = PendingRequest(handler: handler)
        pendingLock.unlock()
    }

    private nonisolated func removePending(id: String) -> PendingRequest? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingRequests.removeValue(forKey: id)
    }

    private nonisolated func failAllPending() {
        pendingLock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        pendingLock.unlock()
        for (_, req) in pending {
            req.handler(.failure(ControlError.notConnected))
        }
    }

    enum ControlError: Error, CustomStringConvertible {
        case notConnected
        case protocolError(String)
        case guestError(String)

        var description: String {
            switch self {
            case .notConnected: "not connected to vphoned"
            case let .protocolError(msg): "protocol error: \(msg)"
            case let .guestError(msg): msg
            }
        }
    }

    // MARK: - Guest Binary Hash

    private func loadGuestBinary() {
        guard let url = guestBinaryURL,
              let data = try? Data(contentsOf: url)
        else {
            guestBinaryData = nil
            guestBinaryHash = nil
            return
        }
        guestBinaryData = data
        guestBinaryHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print(
            "[control] vphoned binary: \(url.lastPathComponent) (\(data.count) bytes, \(guestBinaryHash!.prefix(12))...)"
        )
    }

    // MARK: - Connect

    func connect(device: VZVirtioSocketDevice) {
        self.device = device
        loadGuestBinary()
        attemptConnect()
    }

    private func attemptConnect() {
        guard let device else { return }
        device.connect(toPort: Self.vsockPort) {
            [weak self] (result: Result<VZVirtioSocketConnection, any Error>) in
            Task { @MainActor in
                switch result {
                case let .success(conn):
                    self?.connection = conn
                    self?.performHandshake(fd: conn.fileDescriptor)
                case let .failure(error):
                    print("[control] vsock: \(error.localizedDescription), retrying...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self?.attemptConnect()
                    }
                }
            }
        }
    }

    // MARK: - Handshake

    private func performHandshake(fd: Int32) {
        var hello: [String: Any] = ["v": Self.protocolVersion, "t": "hello"]
        if let hash = guestBinaryHash {
            hello["bin_hash"] = hash
        }
        guard writeMessage(fd: fd, dict: hello) else {
            print("[control] handshake: failed to send hello")
            disconnect()
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let resp = Self.readMessage(fd: fd) else {
                Task { @MainActor in
                    print("[control] handshake: no response")
                    self?.disconnect()
                }
                return
            }

            let version = resp["v"] as? Int ?? 0
            let type = resp["t"] as? String ?? ""
            let name = resp["name"] as? String ?? "unknown"
            let caps = resp["caps"] as? [String] ?? []
            let needUpdate = resp["need_update"] as? Bool ?? false

            Task { @MainActor in
                guard let self else { return }
                guard type == "hello", version == Self.protocolVersion else {
                    print(
                        "[control] handshake: version mismatch (guest v\(version), host v\(Self.protocolVersion))"
                    )
                    self.disconnect()
                    return
                }
                self.guestName = name
                self.guestCaps = caps
                self.isConnected = true
                print("[control] connected to \(name) v\(version), caps: \(caps)")

                if needUpdate {
                    self.pushUpdate(fd: fd)
                } else {
                    self.startReadLoop(fd: fd)
                    self.onConnect?(caps)
                }
            }
        }
    }

    // MARK: - Auto-update Push

    private func pushUpdate(fd: Int32) {
        guard let data = guestBinaryData else {
            print("[control] update requested but no binary available")
            startReadLoop(fd: fd)
            return
        }

        print("[control] pushing update (\(data.count) bytes)...")
        nextRequestId += 1
        let header: [String: Any] = [
            "v": Self.protocolVersion, "t": "update", "id": String(nextRequestId, radix: 16),
            "size": data.count,
        ]
        guard writeMessage(fd: fd, dict: header) else {
            print("[control] update: failed to send header")
            disconnect()
            return
        }

        let ok = data.withUnsafeBytes { buf in
            Self.writeFully(fd: fd, buf: buf.baseAddress!, count: data.count)
        }
        guard ok else {
            print("[control] update: failed to send binary data")
            disconnect()
            return
        }

        print("[control] update sent, waiting for ack...")
        startReadLoop(fd: fd)
    }

    // MARK: - Send Commands

    func sendHIDPress(page: UInt32, usage: UInt32) {
        sendHID(page: page, usage: usage, down: nil)
    }

    func sendHIDDown(page: UInt32, usage: UInt32) {
        sendHID(page: page, usage: usage, down: true)
    }

    func sendHIDUp(page: UInt32, usage: UInt32) {
        sendHID(page: page, usage: usage, down: false)
    }

    private func sendHID(page: UInt32, usage: UInt32, down: Bool?) {
        nextRequestId += 1
        var msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "hid",
            "id": String(nextRequestId, radix: 16),
            "page": page,
            "usage": usage,
        ]
        if let down { msg["down"] = down }
        guard let fd = connection?.fileDescriptor, writeMessage(fd: fd, dict: msg) else {
            print("[control] send failed (not connected)")
            return
        }
        let suffix = down.map { $0 ? " down" : " up" } ?? ""
        print(
            "[control] hid page=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16))\(suffix)"
        )
    }

    // MARK: - Developer Mode

    struct DevModeStatus {
        let enabled: Bool
    }

    struct DevModeEnableResult {
        let alreadyEnabled: Bool
        let message: String
    }

    func sendDevModeStatus() async throws -> DevModeStatus {
        let (resp, _) = try await sendRequest(["t": "devmode", "action": "status"])
        let enabled = resp["enabled"] as? Bool ?? false
        return DevModeStatus(enabled: enabled)
    }

    func sendDevModeEnable() async throws -> DevModeEnableResult {
        let (resp, _) = try await sendRequest(["t": "devmode", "action": "enable"])
        let alreadyEnabled = resp["already_enabled"] as? Bool ?? false
        let message = resp["msg"] as? String ?? ""
        return DevModeEnableResult(alreadyEnabled: alreadyEnabled, message: message)
    }

    func sendPing() async throws {
        _ = try await sendRequest(["t": "ping"])
    }

    func sendVersion() async throws -> String {
        let (resp, _) = try await sendRequest(["t": "version"])
        return resp["hash"] as? String ?? "unknown"
    }

    // MARK: - Async Request-Response

    /// Send a request and await the response. Returns the response dict and optional raw data.
    func sendRequest(_ dict: [String: Any]) async throws -> ([String: Any], Data?) {
        guard let fd = connection?.fileDescriptor else {
            throw ControlError.notConnected
        }

        nextRequestId += 1
        let reqId = String(nextRequestId, radix: 16)
        var msg = dict
        msg["v"] = Self.protocolVersion
        msg["id"] = reqId

        return try await withCheckedThrowingContinuation { continuation in
            addPending(id: reqId) { result in
                nonisolated(unsafe) let r = result
                continuation.resume(with: r)
            }
            guard writeMessage(fd: fd, dict: msg) else {
                _ = removePending(id: reqId)
                continuation.resume(throwing: ControlError.notConnected)
                return
            }
        }
    }

    // MARK: - File Operations

    func listFiles(path: String) async throws -> [[String: Any]] {
        let (resp, _) = try await sendRequest(["t": "file_list", "path": path])
        guard let entries = resp["entries"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing entries in response")
        }
        return entries
    }

    func downloadFile(path: String) async throws -> Data {
        let (_, data) = try await sendRequest(["t": "file_get", "path": path])
        guard let data else {
            throw ControlError.protocolError("no file data received")
        }
        return data
    }

    func uploadFile(path: String, data: Data, permissions: String = "644") async throws {
        guard let fd = connection?.fileDescriptor else {
            throw ControlError.notConnected
        }

        nextRequestId += 1
        let reqId = String(nextRequestId, radix: 16)
        let header: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "file_put",
            "id": reqId,
            "path": path,
            "size": data.count,
            "perm": permissions,
        ]

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            addPending(id: reqId) { result in
                switch result {
                case .success: continuation.resume()
                case let .failure(error): continuation.resume(throwing: error)
                }
            }

            // Write header + raw data atomically (same pattern as pushUpdate)
            guard writeMessage(fd: fd, dict: header) else {
                _ = removePending(id: reqId)
                continuation.resume(throwing: ControlError.notConnected)
                return
            }
            let ok = data.withUnsafeBytes { buf in
                Self.writeFully(fd: fd, buf: buf.baseAddress!, count: data.count)
            }
            guard ok else {
                _ = removePending(id: reqId)
                continuation.resume(throwing: ControlError.protocolError("failed to write file data"))
                return
            }
        }
    }

    func createDirectory(path: String) async throws {
        _ = try await sendRequest(["t": "file_mkdir", "path": path])
    }

    func deleteFile(path: String) async throws {
        _ = try await sendRequest(["t": "file_delete", "path": path])
    }

    func renameFile(from: String, to: String) async throws {
        _ = try await sendRequest(["t": "file_rename", "from": from, "to": to])
    }

    // MARK: - Location

    func sendLocation(
        latitude: Double, longitude: Double, altitude: Double,
        horizontalAccuracy: Double, verticalAccuracy: Double,
        speed: Double, course: Double
    ) {
        nextRequestId += 1
        let msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "location",
            "id": String(nextRequestId, radix: 16),
            "lat": latitude,
            "lon": longitude,
            "alt": altitude,
            "hacc": horizontalAccuracy,
            "vacc": verticalAccuracy,
            "speed": speed,
            "course": course,
            "ts": Date().timeIntervalSince1970,
        ]
        guard let fd = connection?.fileDescriptor, writeMessage(fd: fd, dict: msg) else {
            print("[control] sendLocation failed (not connected)")
            return
        }
        print("[control] location lat=\(latitude) lon=\(longitude)")
    }

    func sendLocationStop() {
        nextRequestId += 1
        let msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "location_stop",
            "id": String(nextRequestId, radix: 16),
        ]
        guard let fd = connection?.fileDescriptor, writeMessage(fd: fd, dict: msg) else { return }
    }

    // MARK: - Disconnect & Reconnect

    private func disconnect() {
        let wasConnected = isConnected
        connection = nil
        isConnected = false
        guestName = ""
        guestCaps = []

        // Fail all pending requests
        failAllPending()

        if wasConnected {
            onDisconnect?()
        }

        if wasConnected, device != nil {
            print("[control] reconnecting in 3s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.loadGuestBinary()
                self?.attemptConnect()
            }
        }
    }

    // MARK: - Background Read Loop

    private func startReadLoop(fd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let msg = Self.readMessage(fd: fd) {
                guard let self else { break }
                let type = msg["t"] as? String ?? ""
                let reqId = msg["id"] as? String

                // Check for pending request callback
                if let reqId, let pending = removePending(id: reqId) {
                    if type == "err" {
                        let detail = msg["msg"] as? String ?? "unknown error"
                        pending.handler(.failure(ControlError.guestError(detail)))
                        continue
                    }

                    // For file_data, read inline binary payload
                    if type == "file_data" {
                        let size = msg["size"] as? Int ?? 0
                        if size > 0 {
                            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                            if Self.readFully(fd: fd, buf: buf, count: size) {
                                let data = Data(bytes: buf, count: size)
                                buf.deallocate()
                                pending.handler(.success((msg, data)))
                            } else {
                                buf.deallocate()
                                pending.handler(.failure(ControlError.protocolError("failed to read file data")))
                            }
                        } else {
                            pending.handler(.success((msg, Data())))
                        }
                        continue
                    }

                    // Normal response (ok, pong, etc.)
                    pending.handler(.success((msg, nil)))
                    continue
                }

                // No pending request — handle as before (fire-and-forget)
                switch type {
                case "ok":
                    let detail = msg["msg"] as? String ?? ""
                    if !detail.isEmpty { print("[vphoned] ok: \(detail)") }
                case "pong":
                    print("[vphoned] pong")
                case "version":
                    let hash = msg["hash"] as? String ?? "unknown"
                    print("[vphoned] build: \(hash)")
                case "err":
                    let detail = msg["msg"] as? String ?? "unknown"
                    print("[vphoned] error: \(detail)")
                default:
                    print("[vphoned] \(msg)")
                }
            }
            Task { @MainActor in
                print("[control] read loop ended")
                self?.disconnect()
            }
        }
    }

    // MARK: - Framing: Length-Prefixed JSON

    @discardableResult
    private func writeMessage(fd: Int32, dict: [String: Any]) -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        let length = UInt32(json.count)
        var header = length.bigEndian
        let headerOK = withUnsafeBytes(of: &header) { buf in
            Darwin.write(fd, buf.baseAddress!, 4) == 4
        }
        guard headerOK else { return false }
        return json.withUnsafeBytes { buf in
            Darwin.write(fd, buf.baseAddress!, json.count) == json.count
        }
    }

    private nonisolated static func readMessage(fd: Int32) -> [String: Any]? {
        var header: UInt32 = 0
        let hRead = withUnsafeMutableBytes(of: &header) { buf in
            readFully(fd: fd, buf: buf.baseAddress!, count: 4)
        }
        guard hRead else { return nil }

        let length = Int(UInt32(bigEndian: header))
        guard length > 0, length < 4 * 1024 * 1024 else { return nil }

        let payload = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { payload.deallocate() }
        guard readFully(fd: fd, buf: payload, count: length) else { return nil }

        let data = Data(bytes: payload, count: length)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private nonisolated static func readFully(fd: Int32, buf: UnsafeMutableRawPointer, count: Int)
        -> Bool
    {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, buf + offset, count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private nonisolated static func writeFully(fd: Int32, buf: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, buf + offset, count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
