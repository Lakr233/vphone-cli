import CryptoKit
import Foundation
import Virtualization
import VPhoneCore

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
    private static let reconnectDelay: TimeInterval = 3
    private static let handshakeTimeout: TimeInterval = 8
    private static let defaultRequestTimeout: TimeInterval = 10
    private static let slowRequestTimeout: TimeInterval = 30
    private static let transferRequestTimeout: TimeInterval = 180

    private var connection: VZVirtioSocketConnection?
    private weak var device: VZVirtioSocketDevice?
    private(set) var isConnected = false
    private(set) var guestName = ""
    private(set) var guestCaps: [String] = []
    private(set) var guestIP: String?
    /// Guest userland iOS version reported at handshake (e.g. "18.6.2"), if known.
    private(set) var guestIOSVersion: String?

    /// Whether touches should be injected guest-side via vphoned rather than the
    /// VZ USB touchscreen. True for iOS 18 bases: on the 26.x kernel their USB
    /// touchscreen dext receives reports but emits no digitizer events, so the
    /// UI never sees touches. 26.x bases keep the native VZ multitouch path.
    var useGuestTouchInjection: Bool {
        guard isConnected, guestCaps.contains("touch"),
              let major = guestIOSVersion.flatMap({ Int($0.split(separator: ".").first ?? "") })
        else { return false }
        return major < 26
    }
    /// Path to the signed vphoned binary. When set, enables auto-update.
    var guestBinaryURL: URL?

    /// Called when guest is ready (not updating). Receives guest capabilities.
    var onConnect: (([String]) -> Void)?

    /// Called when the guest disconnects (before reconnect attempt).
    var onDisconnect: (() -> Void)?

    private var guestBinaryData: Data?
    private var guestBinaryHash: String?
    private var nextRequestId: UInt64 = 0
    private var connectionAttemptToken: UInt64 = 0
    private var reconnectWorkItem: DispatchWorkItem?
    public var variant: VPhoneVirtualMachine.Variant = .regular

    init(variant: VPhoneVirtualMachine.Variant) {
        self.variant = variant
    }
    
    // MARK: - Pending Requests

    /// Callback for a pending request. Called on the read-loop queue.
    private struct PendingRequest: @unchecked Sendable {
        let requestType: String
        let deadline: TimeInterval
        let output: Int32?
        let handler: (Result<([String: Any], Data?), any Error>) -> Void
    }

    private let pendingLock = NSLock()
    private nonisolated(unsafe) var pendingRequests: [String: PendingRequest] = [:]

    private nonisolated func addPending(
        id: String, type: String, timeout: TimeInterval, output: Int32? = nil, handler: @escaping (Result<([String: Any], Data?), any Error>) -> Void
    ) {
        pendingLock.lock()
        pendingRequests[id] = PendingRequest(requestType: type, deadline: ProcessInfo.processInfo.systemUptime + timeout, output: output, handler: handler)
        pendingLock.unlock()
    }

    private nonisolated func removePending(id: String) -> PendingRequest? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingRequests.removeValue(forKey: id)
    }

    private nonisolated func failAllPending(with error: ControlError = .notConnected) {
        pendingLock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        pendingLock.unlock()
        for (_, req) in pending {
            req.handler(.failure(error))
        }
    }

    enum ControlError: Error, CustomStringConvertible {
        case notConnected
        case unsupportedCapability(String)
        case cancelled(String)
        case requestTimedOut(type: String, seconds: Int)
        case protocolError(String)
        case guestError(String)

        var description: String {
            switch self {
            case .notConnected: "not connected to vphoned"
            case let .unsupportedCapability(capability):
                "guest does not support capability: \(capability)"
            case let .cancelled(reason): "request cancelled: \(reason)"
            case let .requestTimedOut(type, seconds):
                "request timed out (\(type), \(seconds)s)"
            case let .protocolError(msg): "protocol error: \(msg)"
            case let .guestError(msg): msg
            }
        }
    }

    private static func signCertURL() -> URL? {
        let signcert = VPhoneResources.resolve().signcert
        return FileManager.default.fileExists(atPath: signcert.path) ? signcert : nil
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
        cancelReconnect()
        loadGuestBinary()
        attemptConnect()
    }

    private func attemptConnect() {
        guard let device else { return }
        connectionAttemptToken += 1
        let attemptToken = connectionAttemptToken
        device.connect(toPort: Self.vsockPort) {
            [weak self] (result: Result<VZVirtioSocketConnection, any Error>) in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken) else { return }
                switch result {
                case let .success(conn):
                    self.connection = conn
                    self.performHandshake(fd: conn.fileDescriptor, attemptToken: attemptToken)
                case let .failure(error):
                    print("[control] connect failed: \(error)")
                    self.scheduleReconnect(for: attemptToken, reason: "connect failed")
                }
            }
        }
    }

    // MARK: - Handshake

    private func performHandshake(fd: Int32, attemptToken: UInt64) {
        var hello: [String: Any] = ["v": Self.protocolVersion, "t": "hello"]
        if let hash = guestBinaryHash {
            hello["bin_hash"] = hash
        }
        guard writeMessage(fd: fd, dict: hello) else {
            print("[control] handshake: failed to send hello")
            disconnect(ifCurrentAttempt: attemptToken)
            return
        }
        armHandshakeTimeout(fd: fd, attemptToken: attemptToken)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let resp = Self.readMessage(fd: fd) else {
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                    print("[control] handshake: no response")
                    self.disconnect(ifCurrentAttempt: attemptToken)
                }
                return
            }

            let version = resp["v"] as? Int ?? 0
            let type = resp["t"] as? String ?? ""
            let name = resp["name"] as? String ?? "unknown"
            let caps = resp["caps"] as? [String] ?? []
            let ip = resp["ip"] as? String
            let iosVersion = resp["ios"] as? String
            let needUpdate = resp["need_update"] as? Bool ?? false

            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                guard type == "hello", version == Self.protocolVersion else {
                    print(
                        "[control] handshake: version mismatch (guest v\(version), host v\(Self.protocolVersion))"
                    )
                    self.disconnect(ifCurrentAttempt: attemptToken)
                    return
                }
                self.guestName = name
                self.guestCaps = caps
                self.guestIP = ip
                self.guestIOSVersion = iosVersion
                self.isConnected = true
                let ipSuffix = ip.map { " (\($0))" } ?? ""
                let iosSuffix = iosVersion.map { " iOS \($0)" } ?? ""
                print("[control] connected to \(name) v\(version)\(ipSuffix)\(iosSuffix), caps: \(caps)")
                if self.useGuestTouchInjection {
                    print("[control] guest-side touch injection enabled (iOS \(iosVersion ?? "?"))")
                }

                if needUpdate && self.variant != .less {
                    self.pushUpdate(fd: fd)
                } else {
                    self.startReadLoop(fd: fd, attemptToken: attemptToken)
                    self.onConnect?(caps)
                }
            }
        }
    }

    // MARK: - Auto-update Push

    private func pushUpdate(fd: Int32) {
        guard let data = guestBinaryData else {
            print("[control] update requested but no binary available")
            startReadLoop(fd: fd, attemptToken: connectionAttemptToken)
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
        startReadLoop(fd: fd, attemptToken: connectionAttemptToken)
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

    /// Inject a single-finger digitizer touch guest-side (bypasses VZ USB touch).
    /// phase: 0 = down, 1 = move, 3 = up. x/y are normalized 0..1, top-left origin.
    func sendTouch(phase: Int, x: Double, y: Double) {
        nextRequestId += 1
        let msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "touch",
            "id": String(nextRequestId, radix: 16),
            "phase": phase,
            "x": x,
            "y": y,
        ]
        guard let fd = connection?.fileDescriptor, writeMessage(fd: fd, dict: msg) else {
            print("[control] touch send failed (not connected)")
            return
        }
    }

    // MARK: - Developer Mode

    struct DevModeStatus {
        let enabled: Bool
    }

    func sendDevModeStatus() async throws -> DevModeStatus {
        let (resp, _) = try await sendRequest(["t": "devmode", "action": "status"])
        let enabled = resp["enabled"] as? Bool ?? false
        return DevModeStatus(enabled: enabled)
    }

    func sendPing() async throws {
        _ = try await sendRequest(["t": "ping"])
    }

    func sendVersion() async throws -> String {
        let (resp, _) = try await sendRequest(["t": "version"])
        return resp["hash"] as? String ?? "unknown"
    }

    /// Cancel all currently pending request continuations.
    func cancelPendingRequests(reason: String = "cancelled by host") {
        failAllPending(with: .cancelled(reason))
    }

    // MARK: - Async Request-Response

    /// Send a request and await the response. Returns the response dict and optional raw data.
    func sendRequest(_ dict: [String: Any], output: Int32? = nil) async throws -> ([String: Any], Data?) {
        guard let fd = connection?.fileDescriptor else {
            throw ControlError.notConnected
        }

        nextRequestId += 1
        let reqId = String(nextRequestId, radix: 16)
        var msg = dict
        msg["v"] = Self.protocolVersion
        msg["id"] = reqId
        let requestType = msg["t"] as? String ?? "unknown"
        let timeout = Self.timeoutForRequest(type: requestType)

        return try await withCheckedThrowingContinuation { continuation in
            addPending(id: reqId, type: requestType, timeout: timeout, output: output) { result in
                nonisolated(unsafe) let r = result
                continuation.resume(with: r)
            }
            armRequestTimeout(id: reqId, type: requestType, timeout: timeout)
            guard writeMessage(fd: fd, dict: msg) else {
                removePending(id: reqId)?.handler(.failure(ControlError.notConnected))
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

    /// The caller keeps the safe destination descriptor open until this returns.
    func downloadFile(path: String, toFileDescriptor output: Int32) async throws {
        _ = try await sendRequest(["t": "file_get", "path": path], output: output)
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
        let timeout = Self.timeoutForRequest(type: "file_put")

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            addPending(id: reqId, type: "file_put", timeout: timeout) { result in
                switch result {
                case .success: continuation.resume()
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
            armRequestTimeout(id: reqId, type: "file_put", timeout: timeout)

            // Write header + raw data atomically (same pattern as pushUpdate)
            guard writeMessage(fd: fd, dict: header) else {
                removePending(id: reqId)?.handler(.failure(ControlError.notConnected))
                return
            }
            let ok = data.withUnsafeBytes { buf in
                Self.writeFully(fd: fd, buf: buf.baseAddress!, count: data.count)
            }
            guard ok else {
                removePending(id: reqId)?.handler(.failure(ControlError.protocolError("failed to write file data")))
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

    func installIPA(localURL: URL) async throws -> String {
        do {
            return try await installIPAWithBuiltInInstaller(localURL: localURL)
        } catch let ControlError.guestError(message) where message == "unknown type: ipa_install" {
            throw ControlError.guestError(
                "Guest vphoned does not support ipa_install yet. Reconnect or reboot the guest so the updated daemon can take over."
            )
        }
    }

    private func installIPAWithBuiltInInstaller(localURL: URL) async throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: localURL)
        } catch {
            throw ControlError.protocolError("failed to read IPA: \(error)")
        }

        let remoteDir = "/var/mobile/Documents/vphone-installs"
        let remoteName = "\(UUID().uuidString)-\(localURL.lastPathComponent)"
        let remotePath = "\(remoteDir)/\(remoteName)"

        var cleanupPaths = [remotePath]
        defer {
            Task {
                for cleanupPath in cleanupPaths {
                    try? await deleteFile(path: cleanupPath)
                }
            }
        }

        try await createDirectory(path: remoteDir)
        try await uploadFile(path: remotePath, data: data)

        var request: [String: Any] = [
            "t": "ipa_install",
            "path": remotePath,
            "registration": "User",
        ]

        if let signCertURL = Self.signCertURL() {
            let signCertData = try Data(contentsOf: signCertURL)
            let certRemotePath = "\(remoteDir)/\(UUID().uuidString)-signcert.p12"
            cleanupPaths.append(certRemotePath)
            try await uploadFile(path: certRemotePath, data: signCertData)
            request["cert_path"] = certRemotePath
        }

        let (resp, _) = try await sendRequest(request)
        if let detail = resp["msg"] as? String, !detail.isEmpty {
            return detail
        }
        return "Installed \(localURL.lastPathComponent) through the built-in IPA installer."
    }

    // MARK: - Keychain Operations

    struct KeychainResult {
        let items: [[String: Any]]
        let diagnostics: [String]
    }

    func listKeychainItems(filterClass: String? = nil) async throws -> KeychainResult {
        var req: [String: Any] = ["t": "keychain_list"]
        if let filterClass { req["class"] = filterClass }
        let (resp, _) = try await sendRequest(req)
        guard let items = resp["items"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing items in keychain response")
        }
        let diag = resp["diag"] as? [String] ?? []
        return KeychainResult(items: items, diagnostics: diag)
    }

    func addKeychainItem(
        account: String = "vphone-test", service: String = "vphone", password: String = "testpass123"
    ) async throws -> Bool {
        let req: [String: Any] = [
            "t": "keychain_add", "account": account, "service": service, "password": password,
        ]
        let (resp, _) = try await sendRequest(req)
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            let msg = resp["msg"] as? String ?? "unknown error"
            throw ControlError.protocolError("keychain_add: \(msg)")
        }
        return true
    }

    // MARK: - Clipboard

    struct ClipboardContent {
        let text: String?
        let types: [String]
        let hasImage: Bool
        let changeCount: Int
        let imageData: Data?
    }

    func clipboardGet() async throws -> ClipboardContent {
        let (resp, data) = try await sendRequest(["t": "clipboard_get"])
        let text = resp["text"] as? String
        let types = resp["types"] as? [String] ?? []
        let hasImage = resp["has_image"] as? Bool ?? false
        let changeCount = resp["change_count"] as? Int ?? 0
        return ClipboardContent(
            text: text, types: types, hasImage: hasImage, changeCount: changeCount, imageData: data
        )
    }

    func clipboardSet(text: String) async throws {
        _ = try await sendRequest(["t": "clipboard_set", "text": text])
    }

    func clipboardSet(imageData: Data) async throws {
        guard let fd = connection?.fileDescriptor else {
            throw ControlError.notConnected
        }

        nextRequestId += 1
        let reqId = String(nextRequestId, radix: 16)
        let header: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "clipboard_set",
            "id": reqId,
            "type": "image",
            "size": imageData.count,
        ]
        let timeout = Self.timeoutForRequest(type: "clipboard_set")

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            addPending(id: reqId, type: "clipboard_set", timeout: timeout) { result in
                switch result {
                case .success: continuation.resume()
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
            armRequestTimeout(id: reqId, type: "clipboard_set", timeout: timeout)

            guard writeMessage(fd: fd, dict: header) else {
                removePending(id: reqId)?.handler(.failure(ControlError.notConnected))
                return
            }
            let ok = imageData.withUnsafeBytes { buf in
                Self.writeFully(fd: fd, buf: buf.baseAddress!, count: imageData.count)
            }
            guard ok else {
                removePending(id: reqId)?.handler(.failure(ControlError.protocolError("failed to write image data")))
                return
            }
        }
    }

    // MARK: - App Management

    struct AppInfo {
        let bundleId: String
        let name: String
        let version: String
        let type: String
        let state: String
        let pid: Int
        let path: String
        let dataContainer: String
    }

    func appList(filter: String = "all") async throws -> [AppInfo] {
        let (resp, _) = try await sendRequest(["t": "app_list", "filter": filter])
        guard let apps = resp["apps"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing apps in response")
        }
        return apps.map { app in
            AppInfo(
                bundleId: app["bundle_id"] as? String ?? "",
                name: app["name"] as? String ?? "",
                version: app["version"] as? String ?? "",
                type: app["type"] as? String ?? "",
                state: app["state"] as? String ?? "",
                pid: app["pid"] as? Int ?? 0,
                path: app["path"] as? String ?? "",
                dataContainer: app["data_container"] as? String ?? ""
            )
        }
    }

    func appLaunch(bundleId: String, url: String? = nil) async throws -> Int {
        var req: [String: Any] = ["t": "app_launch", "bundle_id": bundleId]
        if let url { req["url"] = url }
        let (resp, _) = try await sendRequest(req)
        return resp["pid"] as? Int ?? 0
    }

    func appTerminate(bundleId: String) async throws {
        _ = try await sendRequest(["t": "app_terminate", "bundle_id": bundleId])
    }

    func appForeground() async throws -> (bundleId: String, name: String, pid: Int) {
        let (resp, _) = try await sendRequest(["t": "app_foreground"])
        return (
            bundleId: resp["bundle_id"] as? String ?? "",
            name: resp["name"] as? String ?? "",
            pid: resp["pid"] as? Int ?? 0
        )
    }

    // MARK: - URL

    func openURL(_ url: String) async throws {
        let (resp, _) = try await sendRequest(["t": "open_url", "url": url])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            let msg = resp["msg"] as? String ?? "failed to open URL"
            throw ControlError.guestError(msg)
        }
    }

    // MARK: - Settings

    func settingsGet(domain: String, key: String? = nil) async throws -> Any? {
        var req: [String: Any] = ["t": "settings_get", "domain": domain]
        if let key { req["key"] = key }
        let (resp, _) = try await sendRequest(req)
        return resp["value"]
    }

    func settingsSet(domain: String, key: String, value: Any, type: String? = nil) async throws {
        var req: [String: Any] = ["t": "settings_set", "domain": domain, "key": key, "value": value]
        if let type { req["type"] = type }
        _ = try await sendRequest(req)
    }

    func lowPowerMode(enabled: Bool) async throws {
        let (resp, _) = try await sendRequest(["t": "low_power_mode", "enabled": enabled])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            throw ControlError.guestError("low_power_mode: failed to set state on guest")
        }
    }

    // MARK: - Accessibility

    func accessibilityTree(depth: Int = -1) async throws -> [String: Any] {
        guard guestCaps.contains("accessibility_tree") else {
            throw ControlError.unsupportedCapability("accessibility_tree")
        }
        let (resp, _) = try await sendRequest(["t": "accessibility_tree", "depth": depth])
        return resp
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

    private func disconnect(ifCurrentAttempt expectedAttemptToken: UInt64? = nil) {
        if let expectedAttemptToken, !isCurrentAttempt(expectedAttemptToken) {
            return
        }

        let reconnectAttemptToken = connectionAttemptToken
        let wasConnected = isConnected
        let hadConnection = connection != nil
        let fd = connection?.fileDescriptor
        if let fd { Self.shutdownSocket(fd: fd) }
        connection = nil
        isConnected = false
        guestName = ""
        guestCaps = []
        guestIP = nil

        // Fail all pending requests
        failAllPending()

        if wasConnected {
            onDisconnect?()
        }

        if hadConnection, device != nil {
            scheduleReconnect(for: reconnectAttemptToken, reason: "connection lost")
        }
    }

    // MARK: - Background Read Loop

    private func startReadLoop(fd: Int32, attemptToken: UInt64) {
        // Own the reader descriptor until its queue exits, including disconnect.
        // The original VZ connection can otherwise close and reuse its fd.
        let readerFD = Darwin.dup(fd)
        guard readerFD >= 0 else { disconnect(ifCurrentAttempt: attemptToken); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { Darwin.close(readerFD) }
            while let msg = Self.readMessage(fd: readerFD) {
                guard let self else { break }
                let type = msg["t"] as? String ?? ""
                let reqId = msg["id"] as? String

                // Check for pending request callback
                if let reqId, let pending = removePending(id: reqId) {
                    nonisolated(unsafe) let safeMsg = msg

                    if type == "err" {
                        let detail = msg["msg"] as? String ?? "unknown error"
                        DispatchQueue.main.async { pending.handler(.failure(ControlError.guestError(detail))) }
                        continue
                    }

                    do {
                        if let count = try VPhoneControlTransfer.payloadLength(
                            message: msg, requestType: pending.requestType, streaming: pending.output != nil
                        ) {
                            let data = try VPhoneControlTransfer.receive(
                                fd: readerFD, count: count, deadline: pending.deadline, output: pending.output
                            )
                            DispatchQueue.main.async { pending.handler(.success((safeMsg, data))) }
                            continue
                        }
                    } catch {
                        // A rejected or partial body has no recoverable frame boundary.
                        Self.shutdownSocket(fd: readerFD)
                        DispatchQueue.main.async { pending.handler(.failure(error)) }
                        break
                    }

                    // Normal response (ok, pong, etc.)
                    DispatchQueue.main.async { pending.handler(.success((safeMsg, nil))) }
                    continue
                }

                // Never interpret an unsolicited or late binary body as another JSON frame.
                if type == "file_data" || type == "clipboard_get" {
                    Self.shutdownSocket(fd: readerFD)
                    break
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
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                print("[control] read loop ended")
                self.disconnect(ifCurrentAttempt: attemptToken)
            }
        }
    }

    // MARK: - Reconnect Coordination

    private func isCurrentAttempt(_ attemptToken: UInt64, fd: Int32? = nil) -> Bool {
        guard connectionAttemptToken == attemptToken else { return false }
        guard let fd else { return true }
        return connection?.fileDescriptor == fd
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func scheduleReconnect(for attemptToken: UInt64, reason: String) {
        guard isCurrentAttempt(attemptToken) else { return }
        guard device != nil else { return }

        cancelReconnect()
        let delay = Self.reconnectDelay
        print("[control] \(reason); reconnecting in \(Int(delay.rounded()))s...")

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken) else { return }
                self.reconnectWorkItem = nil
                self.loadGuestBinary()
                self.attemptConnect()
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func armHandshakeTimeout(fd: Int32, attemptToken: UInt64) {
        let timeout = Self.handshakeTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            guard isCurrentAttempt(attemptToken, fd: fd) else { return }
            guard !isConnected else { return }
            print("[control] handshake timed out after \(Int(timeout.rounded()))s")
            Self.shutdownSocket(fd: fd)
            disconnect(ifCurrentAttempt: attemptToken)
        }
    }

    // MARK: - Request Timeout

    private static func timeoutForRequest(type: String) -> TimeInterval {
        switch type {
        case "file_get", "file_put", "ipa_install":
            transferRequestTimeout
        case "devmode", "file_list", "file_delete", "file_rename", "file_mkdir", "keychain_list",
             "app_list", "app_launch", "open_url", "accessibility_tree":
            slowRequestTimeout
        default:
            defaultRequestTimeout
        }
    }

    private func armRequestTimeout(id: String, type: String, timeout: TimeInterval) {
        guard timeout > 0 else { return }
        let timeoutSeconds = max(Int(timeout.rounded()), 1)
        let attemptToken = connectionAttemptToken
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.isCurrentAttempt(attemptToken),
                  let pending = self.removePending(id: id) else { return }
            pending.handler(.failure(ControlError.requestTimedOut(type: type, seconds: timeoutSeconds)))
            // A timed-out request may still have a partial response on the wire.
            self.disconnect(ifCurrentAttempt: attemptToken)
        }
    }

    // MARK: - Framing: Length-Prefixed JSON

    @discardableResult
    private func writeMessage(fd: Int32, dict: [String: Any]) -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        let length = UInt32(json.count)
        var header = length.bigEndian
        let headerOK = withUnsafeBytes(of: &header) { buf in
            Self.writeFully(fd: fd, buf: buf.baseAddress!, count: 4)
        }
        guard headerOK else { return false }
        return json.withUnsafeBytes { buf in
            Self.writeFully(fd: fd, buf: buf.baseAddress!, count: json.count)
        }
    }

    private nonisolated static func readMessage(fd: Int32) -> [String: Any]? {
        // Idle connections may wait for the first byte. Once a frame starts,
        // a guest cannot hold the reader forever with a partial header or JSON.
        var first: UInt8 = 0
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, -1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let received = Darwin.read(fd, &first, 1)
            if received < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard received == 1 else { return nil }
            break
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        do {
            var header = Data([first])
            header.append(try VPhoneControlTransfer.receive(fd: fd, count: 3, deadline: deadline))
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length < 4 * 1024 * 1024 else { return nil }
            let data = try VPhoneControlTransfer.receive(fd: fd, count: length, deadline: deadline)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private nonisolated static func writeFully(fd: Int32, buf: UnsafeRawPointer, count: Int) -> Bool {
        do {
            try VPhoneControlTransfer.send(fd: fd, bytes: UnsafeRawBufferPointer(start: buf, count: count),
                                          deadline: ProcessInfo.processInfo.systemUptime + 30)
            return true
        } catch {
            // A partial outbound frame cannot safely share the next request.
            shutdownSocket(fd: fd)
            return false
        }
    }

    private nonisolated static func shutdownSocket(fd: Int32) {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }
}
