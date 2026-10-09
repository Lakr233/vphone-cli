import Darwin
import Foundation
import Virtualization
import VPhoneCoreKit

/// The VM UI's direct HTTP client over VSOCK. It does not open a host TCP
/// listener; only --api-listen creates one through VPhoneAPIProxy.
@MainActor
@Observable
final class VPhoneGuestControl {
    enum ControlError: Error, CustomStringConvertible {
        case notConnected
        case unsupportedCapability(String)
        case protocolError(String)
        case guestError(String)
        /// `bootstrap.install` found a completed installation in the guest.
        case bootstrapAlreadyInstalled(String)
        /// The guest's Location Services switch is off, so it has no location to
        /// give an app, a simulated one included.
        case locationServicesOff(String)

        var description: String {
            switch self {
            case .notConnected:
                VPhoneLocalization.text("The guest agent is not connected. Wait for it to connect, then try again.")
            case let .unsupportedCapability(value): "guest does not support capability: \(value)"
            case let .protocolError(value): "API protocol error: \(value)"
            case let .guestError(value), let .bootstrapAlreadyInstalled(value), let .locationServicesOff(value): value
            }
        }
    }

    /// vphoned refused an `/v1/rpc` call. `body` is its error object as sent;
    /// it came from JSON, so it serializes back unchanged.
    struct GuestRPCFailure: Error, CustomStringConvertible, @unchecked Sendable {
        let body: [String: Any]

        var message: String {
            body["message"] as? String ?? "Guest operation failed"
        }

        var description: String {
            message
        }
    }

    struct ClipboardContent {
        let text: String?
        let types: [String]
        let hasImage: Bool
        let changeCount: Int
        let imageData: Data?
    }

    // Windows observe the connection state below; transport state is not UI.
    @ObservationIgnored private weak var device: VZVirtioSocketDevice?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var orderedInput: Task<Void, Never>?
    @ObservationIgnored private var orderedLocation: Task<Void, Never>?
    @ObservationIgnored private var locationGeneration: UInt64 = 0
    private(set) var isConnected = false
    private(set) var guestCapabilities: [String] = []
    private(set) var guestIPAddress: String?
    private(set) var guestIOSVersion: String?
    @ObservationIgnored var guestBinaryURL: URL?
    /// The bundled vphoned's hash, kept between probes (VPhoneFileDigestCache).
    @ObservationIgnored private var guestBinaryDigest = VPhoneFileDigestCache()
    @ObservationIgnored var onConnect: (([String]) -> Void)?
    @ObservationIgnored var onDisconnect: (() -> Void)?
    /// What en0 should be configured as, from the manifest. Applied on every
    /// connect, so a guest that was changed while the host was away is put back.
    @ObservationIgnored var guestIPv4Setting: VPhoneGuestIPv4Setting?
    /// The guest's mDNS name from the manifest, applied on every connect; nil
    /// puts back a name vphoned replaced, and leaves any other alone.
    @ObservationIgnored var guestLocalHostName: String?
    /// The guest's device name, the VM's name, applied on every connect; nil
    /// gives the guest its own back.
    @ObservationIgnored var guestDeviceName: String?
    /// Names the guest resolves locally, worked out on each connect (the Mac's
    /// name or a bridged address can change while the VM runs). Nil sends
    /// nothing.
    @ObservationIgnored var guestStaticNames: (() -> [VPhoneNetworking.StaticName])?
    /// Whether to wake the guest and dismiss its Lock Screen when a vphoned
    /// that has just started connects, from the manifest. Read at each connect,
    /// so a change from the menu holds from the next guest start.
    @ObservationIgnored var unlocksAtStartup = false
    /// Whether the Mac's location is forwarded to the guest, from the manifest.
    /// The VM window's Location menu starts from it and writes it back.
    @ObservationIgnored var syncsHostLocation = false
    /// Called on the main actor when a `location.set` or `location.clear` fails.
    @ObservationIgnored var onLocationFailure: ((Error) -> Void)?
    /// The `instance` of the last vphoned connected to. Kept across
    /// disconnects: a lost probe reconnects to the same vphoned, which is not
    /// a start. Guest counters such as the clipboard's change count start
    /// again with each instance.
    @ObservationIgnored private(set) var connectedInstance: String?
    /// Called whenever the address the guest reports changes, nil on disconnect.
    @ObservationIgnored var onGuestIPAddressChange: ((String?) -> Void)?

    /// The guest interface orientation: the one the window last read, or the
    /// one a menu rotation is turning to. Nil until one is known, and again
    /// after a disconnect.
    var interfaceOrientation: VPhoneDisplayOrientation? {
        didSet {
            guard interfaceOrientation != oldValue else { return }
            for observer in orientationObservers {
                observer(interfaceOrientation)
            }
        }
    }

    /// True while a menu rotation waits for the guest, so the poll does not
    /// turn the window back to an orientation read before the guest turned.
    var isChangingOrientation: Bool {
        pendingRotations > 0
    }

    @ObservationIgnored private var pendingRotations = 0
    @ObservationIgnored private var orientationObservers: [(VPhoneDisplayOrientation?) -> Void] = []

    func observeInterfaceOrientation(_ observer: @escaping (VPhoneDisplayOrientation?) -> Void) {
        orientationObservers.append(observer)
    }

    /// True while the guest will show Setup Assistant, from `/v1/health`.
    /// False when disconnected.
    private(set) var isSetupAssistantPending = false {
        didSet {
            for observer in setupAssistantObservers {
                observer(isSetupAssistantPending)
            }
        }
    }

    @ObservationIgnored private var setupAssistantObservers: [(Bool) -> Void] = []

    func observeSetupAssistantPending(_ observer: @escaping (Bool) -> Void) {
        setupAssistantObservers.append(observer)
    }

    /// Turns the guest to the first of `candidates` it accepts. Each is set
    /// before the guest is asked, so the window turns with the guest instead
    /// of after it, and a refused one moves straight on to the next. When
    /// every one is refused, the orientation from before is restored and the
    /// last refusal is thrown.
    func rotate(toFirstOf candidates: [VPhoneDisplayOrientation]) async throws {
        let previous = interfaceOrientation
        pendingRotations += 1
        defer { pendingRotations -= 1 }
        var refusal: Error = ControlError.protocolError("no orientation to rotate to")
        for orientation in candidates {
            interfaceOrientation = orientation
            do {
                _ = try await call("display.rotation", params: ["orientation": String(orientation.rawValue)])
                return
            } catch {
                print("[rotate] \(orientation) refused: \(error)")
                refusal = error
            }
        }
        interfaceOrientation = previous
        throw refusal
    }

    var useGuestTouchInjection: Bool {
        guard isConnected, guestCapabilities.contains("touch"),
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
                try? await Task.sleep(for: .seconds(self?.isConnected == true ? 3 : 1))
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        orderedInput?.cancel()
        orderedInput = nil
        orderedLocation?.cancel()
        orderedLocation = nil
        device = nil
        setDisconnected()
    }

    private func probe() async {
        do {
            let response = try await http(method: "GET", path: "/v1/health")
            guard response.status == 200,
                  let info = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  info["api_version"] as? Int == 1
            else {
                throw ControlError.protocolError("incompatible guest API")
            }
            if let binary = guestBinaryURL,
               let hash = guestBinaryDigest.sha256(of: binary),
               hash != info["binary_hash"] as? String,
               let data = try? Data(contentsOf: binary, options: .mappedIfSafe)
            {
                print("[control] updating vphoned over HTTP...")
                try await createDirectory(path: "/var/root/Library/Caches")
                try await uploadFile(path: "/var/root/Library/Caches/vphoned.next", data: data)
                _ = try await call("agent.apply_update", params: ["sha256": hash])
                setDisconnected()
                return
            }
            // The probe repeats every few seconds; assign only changes so
            // observing windows do not redraw on every probe.
            let capabilities = info["capabilities"] as? [String] ?? []
            if capabilities != guestCapabilities {
                guestCapabilities = capabilities
            }
            let ip = info["ip"] as? String
            if ip != guestIPAddress {
                guestIPAddress = ip
                onGuestIPAddressChange?(ip)
            }
            let ios = info["ios"] as? String
            if ios != guestIOSVersion {
                guestIOSVersion = ios
            }
            let setupPending = info["setup_pending"] as? Bool ?? false
            if setupPending != isSetupAssistantPending {
                isSetupAssistantPending = setupPending
            }
            if !isConnected {
                isConnected = true
                print("[control] connected to vphoned HTTP API (iOS \(guestIOSVersion ?? "?"))")
                onConnect?(guestCapabilities)
                let instance = info["instance"] as? String
                let started = instance == nil || instance != connectedInstance
                connectedInstance = instance
                if started, unlocksAtStartup, capabilities.contains("screen_unlock") {
                    if setupPending {
                        print("[unlock] Setup Assistant is pending; leaving the guest as it is")
                    } else {
                        Task { await unlockAtStartup() }
                    }
                }
                if capabilities.contains("environment_update") {
                    Task { await syncEnvironment() }
                }
                if capabilities.contains("network_ipv4"), let setting = guestIPv4Setting {
                    Task { await applyGuestIPv4(setting) }
                }
                if capabilities.contains("network_hostname") {
                    Task { await applyGuestLocalHostName(guestLocalHostName) }
                }
                if capabilities.contains("device_name") {
                    Task { await applyGuestDeviceName(guestDeviceName) }
                }
                if capabilities.contains("network_static_names"), let entries = guestStaticNames?() {
                    Task { await applyGuestStaticNames(entries) }
                }
            }
        } catch {
            if !isConnected {
                print("[control] probe failed: \(error)")
            }
            setDisconnected()
        }
    }

    private func setDisconnected() {
        guard isConnected || !guestCapabilities.isEmpty || guestIPAddress != nil || guestIOSVersion != nil
        else { return }
        let wasConnected = isConnected
        isConnected = false
        guestCapabilities = []
        guestIPAddress = nil
        onGuestIPAddressChange?(nil)
        guestIOSVersion = nil
        interfaceOrientation = nil
        isSetupAssistantPending = false
        if wasConnected {
            onDisconnect?()
        }
    }

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
        var params: [String: Any] = ["page": page, "usage": usage]
        if let down {
            params["down"] = down
        }
        enqueueInput("input.hid", params: params)
    }

    func sendTouch(phase: Int, x: Double, y: Double) {
        let name =
            switch phase {
            case 0: "down"
            case 1: "move"
            default: "up"
            }
        enqueueInput("input.touch", params: ["phase": name, "x": x, "y": y, "normalized": true])
    }

    /// Whether the guest takes two fingers in one hand event. Guests that only
    /// advertise `touch` cannot: icli's single-finger `input.touch` is all they
    /// have, so a pinch has to fall back to moving one finger.
    var supportsMultiTouch: Bool {
        isConnected && guestCapabilities.contains("touch2")
    }

    /// Two fingers in one hand event, for a trackpad pinch. Coordinates are
    /// normalized 0..1 with the origin at the top-left, like `sendTouch`.
    func sendTouch2(phase: Int, x1: Double, y1: Double, x2: Double, y2: Double) {
        let name =
            switch phase {
            case 0: "down"
            case 1: "move"
            default: "up"
            }
        enqueueInput("input.touch2", params: [
            "phase": name, "x1": x1, "y1": y1, "x2": x2, "y2": y2, "normalized": true,
        ])
    }

    private func enqueueInput(_ method: String, params: [String: Any]) {
        let previous = orderedInput
        orderedInput = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do { _ = try await call(method, params: params) } catch { print("[control] \(method): \(error)") }
        }
    }

    /// Calls one vphoned operation after the input events already queued, so a
    /// key or text request cannot overtake a tap sent before it.
    func callAfterQueuedInput(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        await orderedInput?.value
        return try await call(method, params: params)
    }

    /// `callAfterQueuedInput`, but a refusal from vphoned is thrown as
    /// `GuestRPCFailure` with its whole error object, for a caller that passes
    /// it on (`vphone.sock`'s `rpc`).
    func rpcAfterQueuedInput(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        await orderedInput?.value
        return try await rpc(method, params: params)
    }

    func isDeveloperModeEnabled() async throws -> Bool {
        try await call("developer_mode.status")["enabled"] as? Bool ?? false
    }

    func sendPing() async throws {
        _ = try await http(method: "GET", path: "/v1/health")
    }

    func guestBinaryHash() async throws -> String {
        let response = try await http(method: "GET", path: "/v1/health")
        let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return value?["binary_hash"] as? String ?? "unknown"
    }

    func screenshotJPEG() async throws -> Data {
        let result = try await call("screen.screenshot")
        guard result["mime_type"] as? String == "image/jpeg",
              let encoded = result["data"] as? String,
              let data = Data(base64Encoded: encoded),
              data.starts(with: [0xFF, 0xD8])
        else {
            throw ControlError.protocolError("invalid guest screenshot")
        }
        return data
    }

    /// Retains the UI-facing request shape while all transport and guest
    /// operations use the versioned HTTP API.
    func sendRequest(_ request: [String: Any]) async throws -> ([String: Any], Data?) {
        guard let type = request["t"] as? String else {
            throw ControlError.protocolError("missing operation")
        }
        if type == "file_get" {
            return try await ([:], downloadFile(path: request["path"] as? String ?? ""))
        }
        if type == "clipboard_get" {
            var info = try await call("clipboard.get")
            let image =
                (info["has_image"] as? Bool == true)
                    ? try await http(method: "GET", path: "/v1/clipboard/image", limits: .download).body : nil
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
        case "keychain_get": method = "keychain.get"
        case "keychain_update": method = "keychain.update"
        case "keychain_delete": method = "keychain.delete"
        case "open_url": method = "apps.open_url"
        case "settings_get": method = "settings.get"
        case "settings_set": method = "settings.set"
        case "low_power_mode": method = "power.low_power_mode"
        default: throw ControlError.protocolError("unknown operation \(type)")
        }
        var params = request
        params.removeValue(forKey: "t")
        var result = try await call(method, params: params)
        if result["ok"] == nil {
            result["ok"] = true
        }
        return (result, nil)
    }

    /// Calls one named vphoned operation over `/v1/rpc` and returns its result object.
    func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        do {
            return try await rpc(method, params: params)
        } catch let failure as GuestRPCFailure {
            if failure.body["code"] as? String == "bootstrap_already_installed" {
                throw ControlError.bootstrapAlreadyInstalled(failure.message)
            }
            if failure.body["code"] as? String == "location_services_off" {
                throw ControlError.locationServicesOff(failure.message)
            }
            throw ControlError.guestError(failure.message)
        }
    }

    /// `call`, with vphoned's refusal kept whole as `GuestRPCFailure`: `code`,
    /// `message` and whatever the command adds (`results`, `reason`, `errno`,
    /// `retryable` …).
    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let object: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        let body = try JSONSerialization.data(withJSONObject: object)
        let response = try await http(method: "POST", path: "/v1/rpc", body: body)
        guard let envelope = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw ControlError.protocolError("invalid JSON response") }
        if let error = envelope["error"] as? [String: Any] {
            throw GuestRPCFailure(body: error)
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
        let response = try await http(method: "GET", path: filePath(path), limits: .download)
        guard response.status == 200 else { throw try httpError(response) }
        return response.body
    }

    func uploadFile(
        path: String, data: Data, permissions: String = "644",
        progress: (@Sendable (Int, Int) -> Void)? = nil,
    ) async throws {
        let response = try await http(
            method: "PUT",
            path: filePath(path, mode: permissions),
            body: data,
            contentType: "application/octet-stream",
            limits: .upload,
            uploadProgress: progress,
        )
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

    /// Where the Files app shows a dropped file: On My iPhone › vphone-drop.
    static let dropFolder = "vphone-drop"

    /// Uploads a file dropped on the window, then has vphoned move it into
    /// the Files app's On My iPhone › vphone-drop. vphoned finds that storage,
    /// keeps a name already taken by numbering the new one, and gives the
    /// file the owner and mode the Files app uses. Returns the name used.
    func saveDroppedFile(localURL: URL) async throws -> String {
        guard guestCapabilities.contains("files_app_drop") else {
            throw ControlError.unsupportedCapability("files_app_drop")
        }
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        let path = "/var/root/Library/Caches/vphoned-drop-\(UUID().uuidString)"
        try await createDirectory(path: "/var/root/Library/Caches")
        try await uploadFile(path: path, data: data)
        do {
            let result = try await call(
                "files.save_to_files_app", params: ["path": path, "name": localURL.lastPathComponent],
            )
            return result["name"] as? String ?? localURL.lastPathComponent
        } catch {
            try? await deleteFile(path: path)
            throw error
        }
    }

    func installBootstrap(layout: String, localURL: URL? = nil) async throws -> [String: Any] {
        guard guestCapabilities.contains("bootstrap_install") else {
            throw ControlError.unsupportedCapability("bootstrap_install")
        }
        if let localURL {
            let size = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int ?? 0
            guard localURL.pathExtension.lowercased() == "deb", size > 0, size <= 64 * 1024 * 1024 else {
                throw ControlError.guestError("Choose an Irisin .deb file no larger than 64 MiB.")
            }
            let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
            let path = "/var/root/Library/Caches/vphoned-irisin-\(UUID().uuidString).deb"
            try await createDirectory(path: "/var/root/Library/Caches")
            try await uploadFile(path: path, data: data)
            defer { Task { try? await deleteFile(path: path) } }
            return try await callBootstrapInstall(["layout": layout, "package_path": path])
        }
        return try await callBootstrapInstall(["layout": layout])
    }

    /// vphoned refuses a second install. A current guest says so with an error
    /// code; an older one only with this message.
    private func callBootstrapInstall(_ params: [String: Any]) async throws -> [String: Any] {
        do {
            return try await call("bootstrap.install", params: params)
        } catch let ControlError.guestError(message)
            where message.hasPrefix("Irisin bootstrap already completed")
        {
            throw ControlError.bootstrapAlreadyInstalled(message)
        }
    }

    /// The completed installation vphoned would refuse to install over, or nil
    /// when there is none or the guest cannot be asked. Only `jbroot` marks a
    /// completed install; `roots` also lists foreign roots install may reuse.
    func completedBootstrap() async -> (root: String, layout: String)? {
        guard guestCapabilities.contains("bootstrap_uninstall"),
              let installation = try? await call("bootstrap.inspect"),
              let root = installation["jbroot"] as? String, !root.isEmpty
        else { return nil }
        return (root, installation["layout"] as? String ?? "")
    }

    func bootstrapStatus() async throws -> [String: Any] {
        try await call("bootstrap.status")
    }

    func installedBootstrap() async throws -> [String: Any] {
        guard guestCapabilities.contains("bootstrap_uninstall") else {
            throw ControlError.unsupportedCapability("bootstrap_uninstall")
        }
        return try await call("bootstrap.inspect")
    }

    func uninstallBootstrap(at roots: [String], reboot: Bool) async throws -> [String: Any] {
        guard guestCapabilities.contains("bootstrap_uninstall") else {
            throw ControlError.unsupportedCapability("bootstrap_uninstall")
        }
        return try await call("bootstrap.uninstall", params: ["roots": roots, "reboot": reboot, "force": true])
    }

    /// `uicache -a` for the bootstrap: vphoned registers every app under the
    /// bootstrap's /Applications again through LaunchServices.
    func rebuildBootstrapAppRegistrations() async throws -> [String: Any] {
        guard guestCapabilities.contains("bootstrap_uninstall") else {
            throw ControlError.unsupportedCapability("bootstrap_uninstall")
        }
        return try await call("system.uicache")
    }

    /// Asks the guest to restart. The guest usually restarts before it can
    /// reply, so a dropped connection is the expected result.
    func restartGuest() async throws {
        guard guestCapabilities.contains("system_control") else {
            throw ControlError.unsupportedCapability("system_control")
        }
        _ = try await call("system.reboot", params: ["force": true])
    }

    /// Asks the guest to shut down. The virtual machine stops with it, so a
    /// dropped connection is the expected result.
    func shutDownGuest() async throws {
        guard guestCapabilities.contains("system_shutdown") else {
            throw ControlError.unsupportedCapability("system_shutdown")
        }
        _ = try await call("system.shutdown", params: ["force": true])
    }

    func clipboardGet() async throws -> ClipboardContent {
        let (info, image) = try await sendRequest(["t": "clipboard_get"])
        return ClipboardContent(
            text: info["text"] as? String,
            types: info["types"] as? [String] ?? [],
            hasImage: info["has_image"] as? Bool ?? false,
            changeCount: info["change_count"] as? Int ?? 0,
            imageData: image,
        )
    }

    /// The guest clipboard without its image, read after the input already
    /// queued so it sees the effect of a key sent before it.
    func clipboardInfoAfterQueuedInput() async throws -> ClipboardContent {
        let info = try await callAfterQueuedInput("clipboard.get")
        return ClipboardContent(
            text: info["text"] as? String,
            types: info["types"] as? [String] ?? [],
            hasImage: info["has_image"] as? Bool ?? false,
            changeCount: info["change_count"] as? Int ?? 0,
            imageData: nil,
        )
    }

    /// The guest clipboard image as PNG.
    func clipboardImagePNG() async throws -> Data {
        let response = try await http(method: "GET", path: "/v1/clipboard/image")
        guard response.status == 200 else { throw try httpError(response) }
        return response.body
    }

    func clipboardSet(text: String) async throws {
        _ = try await call("clipboard.set", params: ["text": text])
    }

    func clipboardSet(imageData: Data) async throws {
        let response = try await http(
            method: "PUT",
            path: "/v1/clipboard/image",
            body: imageData,
            contentType: "application/octet-stream",
            limits: .upload,
        )
        guard response.status == 200 else { throw try httpError(response) }
    }

    func sendLocation(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        course: Double,
    ) {
        var params: [String: Any] = [
            "latitude": latitude, "longitude": longitude, "altitude": altitude,
            "horizontal_accuracy": horizontalAccuracy, "vertical_accuracy": verticalAccuracy,
        ]
        // CoreLocation uses negative values for unavailable speed and course.
        // IcliKit expects those fields to be absent in that case.
        if speed >= 0 {
            params["speed"] = speed
        }
        if course >= 0 {
            params["course"] = course
        }
        enqueueLocation("location.set", params: params)
    }

    func sendLocationStop() {
        enqueueLocation("location.clear")
    }

    private func enqueueLocation(_ method: String, params: [String: Any] = [:]) {
        locationGeneration &+= 1
        let generation = locationGeneration
        let previous = orderedLocation
        orderedLocation = Task {
            await previous?.value
            guard !Task.isCancelled, generation == locationGeneration else { return }
            do {
                _ = try await call(method, params: params)
            } catch {
                print("[control] \(method): \(error)")
                onLocationFailure?(error)
            }
        }
    }

    private func filePath(_ guestPath: String, mode: String? = nil) throws -> String {
        guard guestPath.hasPrefix("/"), !guestPath.contains("\0") else {
            throw ControlError.protocolError("guest path must be absolute")
        }
        var components = URLComponents()
        components.path = "/v1/files/content"
        components.queryItems = [URLQueryItem(name: "path", value: guestPath)]
        if let mode {
            components.queryItems?.append(URLQueryItem(name: "mode", value: mode))
        }
        return components.string ?? ""
    }

    private func httpError(_ response: VPhoneHTTPResponse) throws -> ControlError {
        let body = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let error = body?["error"] as? [String: Any]
        return .guestError(error?["message"] as? String ?? "HTTP \(response.status)")
    }

    private func http(
        method: String,
        path: String,
        body: Data = Data(),
        contentType: String = "application/json",
        limits: VPhoneHTTPLimits = .rpc,
        uploadProgress: (@Sendable (Int, Int) -> Void)? = nil,
    ) async throws -> VPhoneHTTPResponse {
        guard let device else { throw ControlError.notConnected }
        let socket = await withCheckedContinuation {
            (continuation: CheckedContinuation<VPhoneSocketResult, Never>) in
            device.connect(toPort: 1339) { continuation.resume(returning: VPhoneSocketResult($0)) }
        }
        let connection = try socket.result.get()
        let transaction = VPhoneHTTPTransaction(
            connection: connection,
            method: method,
            path: path,
            body: body,
            contentType: contentType,
            limits: limits,
            uploadProgress: uploadProgress,
        )
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try continuation.resume(returning: transaction.run()) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct VPhoneHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

// MARK: - Limits

/// How much one guest response may send and how long the whole exchange may
/// take. SO_RCVTIMEO bounds each read; the deadline bounds a guest that
/// drips bytes so that queued input behind the request is not held forever.
private struct VPhoneHTTPLimits: Sendable {
    let maxBodyLength: Int
    let deadline: Duration

    /// JSON, RPC and clipboard responses. A guest operation may run up to the
    /// 120 s read timeout before it answers, so the deadline sits above it.
    static let rpc = VPhoneHTTPLimits(maxBodyLength: 64 * 1024 * 1024, deadline: .seconds(180))
    /// File downloads: the response body is the file.
    static let download = VPhoneHTTPLimits(maxBodyLength: 2_147_483_647, deadline: .seconds(30 * 60))
    /// Uploads: the request body is large, the response is a small JSON reply.
    static let upload = VPhoneHTTPLimits(maxBodyLength: 64 * 1024 * 1024, deadline: .seconds(30 * 60))
}

private struct VPhoneSocketResult: @unchecked Sendable {
    let result: Result<VZVirtioSocketConnection, any Error>
    init(_ result: Result<VZVirtioSocketConnection, any Error>) {
        self.result = result
    }
}

// MARK: - Transaction

private final class VPhoneHTTPTransaction: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
    let method: String
    let path: String
    let body: Data
    let contentType: String
    let limits: VPhoneHTTPLimits
    let uploadProgress: (@Sendable (Int, Int) -> Void)?
    private let deadline: ContinuousClock.Instant

    /// Per-read and per-write socket timeout.
    private static let socketTimeout: Duration = .seconds(120)

    init(
        connection: VZVirtioSocketConnection,
        method: String,
        path: String,
        body: Data,
        contentType: String,
        limits: VPhoneHTTPLimits,
        uploadProgress: (@Sendable (Int, Int) -> Void)?,
    ) {
        self.connection = connection
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType
        self.limits = limits
        self.uploadProgress = uploadProgress
        deadline = ContinuousClock.now + limits.deadline
    }

    func run() throws -> VPhoneHTTPResponse {
        // vphoned waits for this side to close before it releases the
        // connection, because its own close would reset unsent reply bytes.
        defer { connection.close() }
        let fd = connection.fileDescriptor
        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
            throw VPhoneGuestControl.ControlError.notConnected
        }
        var timeout = Self.socketTimeval(Self.socketTimeout)
        guard
            setsockopt(
                fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                socklen_t(MemoryLayout<timeval>.size),
            ) == 0,
            setsockopt(
                fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                socklen_t(MemoryLayout<timeval>.size),
            ) == 0
        else {
            throw VPhoneGuestControl.ControlError.notConnected
        }
        let headers =
            "\(method) \(path) HTTP/1.1\r\nHost: vphoned\r\nConnection: close\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n"
        try write(fd, data: Data(headers.utf8))
        if !body.isEmpty {
            try write(fd, data: body, progress: uploadProgress)
        }

        var received = Data()
        let marker = Data("\r\n\r\n".utf8)
        while received.range(of: marker) == nil {
            guard received.count < 64 * 1024 else {
                throw VPhoneGuestControl.ControlError.protocolError("HTTP headers too large")
            }
            try readMore(fd, into: &received)
        }
        let boundary = received.range(of: marker)!
        let header = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw VPhoneGuestControl.ControlError.protocolError("invalid HTTP status")
        }
        let length = try Self.contentLength(lines.dropFirst())
        guard length <= limits.maxBodyLength else {
            throw VPhoneGuestControl.ControlError.protocolError("HTTP body of \(length) bytes exceeds the \(limits.maxBodyLength)-byte limit")
        }
        var payload = Data(received[boundary.upperBound...])
        while payload.count < length {
            try readMore(fd, into: &payload)
        }
        guard payload.count == length else {
            throw VPhoneGuestControl.ControlError.protocolError("HTTP body length mismatch")
        }
        return VPhoneHTTPResponse(status: status, body: payload)
    }

    /// The single Content-Length of a response. A missing, malformed, negative
    /// or repeated-but-different value is a protocol error.
    private static func contentLength(_ lines: ArraySlice<String>) throws -> Int {
        var length: Int?
        for line in lines {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }), let value = Int(text), value >= 0 else {
                throw VPhoneGuestControl.ControlError.protocolError("invalid HTTP content length")
            }
            if let length, length != value {
                throw VPhoneGuestControl.ControlError.protocolError("conflicting HTTP content lengths")
            }
            length = value
        }
        guard let length else {
            throw VPhoneGuestControl.ControlError.protocolError("missing HTTP content length")
        }
        return length
    }

    private func write(
        _ fd: Int32, data: Data, progress: (@Sendable (Int, Int) -> Void)? = nil,
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard ContinuousClock.now < deadline else {
                    throw VPhoneGuestControl.ControlError.protocolError("HTTP request timed out")
                }
                let sent = Darwin.write(fd, base + offset, min(bytes.count - offset, 1024 * 1024))
                if sent < 0, errno == EINTR {
                    continue
                }
                if sent <= 0 {
                    throw VPhoneGuestControl.ControlError.notConnected
                }
                offset += sent
                progress?(offset, bytes.count)
            }
        }
    }

    private func readMore(_ fd: Int32, into data: inout Data) throws {
        // Each read waits at most until the overall deadline.
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else {
            throw VPhoneGuestControl.ControlError.protocolError("HTTP response timed out")
        }
        var timeout = Self.socketTimeval(min(remaining, Self.socketTimeout))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw VPhoneGuestControl.ControlError.notConnected
        }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        var count = 0
        repeat {
            count = Darwin.read(fd, &bytes, bytes.count)
        } while count < 0 && errno == EINTR
        guard count > 0 else {
            throw VPhoneGuestControl.ControlError.notConnected
        }
        data.append(contentsOf: bytes[..<count])
    }

    private static func socketTimeval(_ duration: Duration) -> timeval {
        let (seconds, attoseconds) = duration.components
        // A zero timeval means "wait forever", so round up to at least 1 µs.
        let microseconds = max(Int32(attoseconds / 1_000_000_000_000), seconds == 0 ? 1 : 0)
        return timeval(tv_sec: Int(seconds), tv_usec: microseconds)
    }
}

// MARK: - Network

extension VPhoneGuestControl {
    /// Hold en0 to `setting`. vphoned leaves a configuration the user made in
    /// the guest alone when asked for DHCP, so this only ever undoes its own.
    func applyGuestIPv4(_ setting: VPhoneGuestIPv4Setting) async {
        do {
            let result = try await call("network.ipv4.set", params: setting.parameters)
            if result["changed"] as? Bool == true {
                print("[network] guest en0 set to \(setting)")
            }
        } catch {
            print("[network] could not set guest en0 to \(setting): \(error)")
        }
    }
}

extension VPhoneGuestControl {
    /// Hold the guest's mDNS name to `name`, or with nil put back the name
    /// vphoned replaced. A name the user set in the guest is never touched.
    func applyGuestLocalHostName(_ name: String?) async {
        do {
            let result = try await call("network.hostname.set", params: ["local_host_name": name ?? NSNull()])
            if result["changed"] as? Bool == true {
                print("[network] guest mDNS name \(name.map { "set to \($0).local" } ?? "restored")")
            }
        } catch {
            print("[network] could not set the guest's mDNS name: \(error)")
        }
    }
}

extension VPhoneGuestControl {
    /// Pin the guest's device name to `name`, what Xcode, devicectl and Finder
    /// show, or with nil give the guest its own back. vphoned stores it where
    /// the guest's hooks read it at every boot, and applies it at once.
    func applyGuestDeviceName(_ name: String?) async {
        do {
            let result = try await call("device.name.set", params: ["name": name ?? NSNull()])
            if result["changed"] as? Bool == true {
                print("[device] guest device name \(name.map { "set to \($0)" } ?? "restored to its own")")
            }
        } catch {
            print("[device] could not set the guest's device name: \(error)")
        }
    }
}

extension VPhoneGuestControl {
    /// Replace the names vphoned has the guest resolve locally; an empty list
    /// withdraws them.
    func applyGuestStaticNames(_ entries: [VPhoneNetworking.StaticName]) async {
        do {
            let result = try await call("network.static_names.set", params: ["entries": entries.map(\.parameters)])
            if result["changed"] as? Bool == true {
                let lines = entries.map { "\($0.address) \($0.names.joined(separator: " "))" }
                print("[network] guest resolves \(lines.isEmpty ? "no names locally" : lines.joined(separator: ", "))")
            }
        } catch {
            print("[network] could not set the guest's local names: \(error)")
        }
    }
}
