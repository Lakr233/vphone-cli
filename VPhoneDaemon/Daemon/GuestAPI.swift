import CryptoKit
import Darwin
import Foundation
import IcliKit
import IcliSystem
import UIKit
import VphonedNative

enum GuestAPIError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case unsupportedMethod(String)
    case operationFailed(String)

    var description: String {
        switch self {
        case let .invalidRequest(message), let .operationFailed(message): message
        case let .unsupportedMethod(method): "Unknown method: \(method)"
        }
    }
}

/// The API boundary is deliberately small: named operations and JSON values.
/// IcliKit owns general device work, including app installation and Keychain
/// metadata. vphone signs app code before IcliKit installs it.
enum GuestAPI {
    // Each request executes independently. A synchronous system service such
    // as powerd may wait during boot; it must not hold up HID or file requests.
    static let queue = DispatchQueue(label: "vphoned.api.operations", qos: .userInitiated,
                                     attributes: .concurrent)
    static let binaryHash: String = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unknown" }
        return sha256Hex(data)
    }()

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func health() -> [String: Any] {
        let addresses = networkInfo()["addresses"] as? [String] ?? []
        let ip = addresses.first(where: { $0.hasPrefix("en") && !$0.contains("127.0.0.1") })?
            .split(separator: " ").last.map(String.init)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "name": "vphoned",
            "api_version": 1,
            "status": "ok",
            "binary_hash": binaryHash,
            "ios": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "ip": ip ?? "",
            "capabilities": [
                "touch",
                "hid",
                "apps",
                "url",
                "files",
                "clipboard",
                "location",
                "keychain",
                "ipa_install",
                "camera",
                "screenshot",
            ],
        ]
    }

    static func execute(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "device.snapshot":
            return try collectDeviceSnapshot()
        case "device.screen":
            return screenInfo()
        case "screen.screenshot":
            return try takeScreenshot(base64: true, nativeResolution: true)
        case "apps.list":
            let filter = params["filter"] as? String ?? "all"
            let apps = try listApps()["apps"] as? [[String: Any]] ?? []
            let running = try runningApps()["apps"] as? [[String: Any]] ?? []
            let pids = Dictionary(uniqueKeysWithValues: running.compactMap { app -> (String, Int)? in
                guard let id = app["bundle_id"] as? String, let pid = app["pid"] as? Int else { return nil }
                return (id, pid)
            })
            return ["apps": apps.compactMap { app -> [String: Any]? in
                var info = app
                guard let id = app["bundle_id"] as? String, !id.isEmpty else { return nil }
                let pid = pids[id] ?? 0
                let path = app["bundle_path"] as? String ?? ""
                let type: String
                if let registeredType = (app["type"] as? String)?.lowercased(),
                   registeredType == "system" || registeredType == "user" {
                    type = registeredType
                } else {
                    type = path.hasPrefix("/System/") || id.hasPrefix("com.apple.") ? "system" : "user"
                }
                if filter == "running" && pid == 0 {
                    return nil
                }
                if filter == "user" && type != "user" {
                    return nil
                }
                if filter == "system" && type != "system" {
                    return nil
                }
                info["pid"] = pid
                info["type"] = type
                info["state"] = pid > 0 ? "running" : "not_running"
                info["path"] = path
                info["version"] = app["version"] ?? ""
                return info
            }]
        case "apps.search":
            return try searchApps(string(params, "query"))
        case "apps.refresh":
            return try refreshApps(directory: params["directory"] as? String)
        case "apps.launch":
            let id = try string(params, "bundle_id")
            if let url = params["url"] as? String {
                _ = try openAppURL(url, bundleID: id)
            } else {
                let before = try runningApps()["apps"] as? [[String: Any]] ?? []
                let wasRunning = before.contains { $0["bundle_id"] as? String == id }
                do {
                    _ = try launchApp(id)
                } catch IcliError.failed(let message) where message == "app did not become frontmost: \(id)" {
                    let after = try runningApps()["apps"] as? [[String: Any]] ?? []
                    guard let pid = after.first(where: { $0["bundle_id"] as? String == id })?["pid"] as? Int
                    else { throw IcliError.failed(message) }
                    let front = frontmostApp()
                    if front["verified"] as? Bool == true,
                       front["bundle_id"] as? String == id {
                        return ["pid": pid, "frontmost_verified": true]
                    }
                    guard !wasRunning else { throw IcliError.failed(message) }
                    return [
                        "pid": pid,
                        "frontmost_verified": false,
                        "warning": "App process started, but foreground state could not be confirmed",
                    ]
                }
            }
            let running = try? runningApps()["apps"] as? [[String: Any]]
            let front = frontmostApp()
            return [
                "pid": running?.first(where: { $0["bundle_id"] as? String == id })?["pid"] ?? 0,
                "frontmost_verified": params["url"] == nil
                    && front["verified"] as? Bool == true
                    && front["bundle_id"] as? String == id,
            ]
        case "apps.terminate":
            return try killApp(string(params, "bundle_id"), force: true)
        case "apps.uninstall":
            return try uninstallApp(string(params, "bundle_id"), force: params["force"] as? Bool == true)
        case "apps.foreground":
            let front = frontmostApp()
            let id = front["bundle_id"] as? String ?? ""
            let apps = try searchApps(id)["apps"] as? [[String: Any]] ?? []
            let running = try runningApps()["apps"] as? [[String: Any]] ?? []
            let name = id == "com.apple.springboard"
                ? "Home Screen"
                : (apps.first(where: { $0["bundle_id"] as? String == id })?["name"] as? String ?? "")
            return [
                "bundle_id": id,
                "name": name,
                "pid": running.first(where: { $0["bundle_id"] as? String == id })?["pid"] ?? 0,
                "verified": front["verified"] ?? false,
                "source": front["source"] ?? "",
            ]
        case "apps.open_url":
            return try openAppURL(string(params, "url"), bundleID: params["bundle_id"] as? String)
        case "apps.install":
            let path = try string(params, "path")
            let certificate = params["cert_path"] as? String ?? ""
            let registration: AppRegistrationType = params["registration"] as? String == "System" ? .system : .user
            defer {
                try? FileManager.default.removeItem(atPath: path)
                if !certificate.isEmpty { try? FileManager.default.removeItem(atPath: certificate) }
            }
            var result = try installIPAInContainer(path, registration: registration) { app in
                try signAppForInstall(app, certificate: certificate)
            }
            let id = result["bundle_id"] as? String ?? "app"
            result["msg"] = "Installed \(id) as a \(registration.rawValue) app."
            return result
        case "input.touch":
            guard let phase = (params["phase"] as? String).flatMap(TouchPhase.init(rawValue:)) else {
                throw GuestAPIError.invalidRequest("phase must be down, move or up")
            }
            return try touch(phase, x: number(params, "x"), y: number(params, "y"),
                             normalized: params["normalized"] as? Bool ?? true)
        case "input.hid":
            let page = try integer(params, "page")
            let usage = try integer(params, "usage")
            if let down = params["down"] as? Bool {
                return try hidEvent(page: page, usage: usage, down: down)
            }
            return try hidPress(page: page, usage: usage)
        case "location.set":
            return try simulateLocation(
                latitude: number(params, "latitude"),
                longitude: number(params, "longitude"),
                altitude: number(params, "altitude", default: 0),
                horizontalAccuracy: number(params, "horizontal_accuracy", default: 5),
                verticalAccuracy: number(params, "vertical_accuracy", default: 5),
                speed: (params["speed"] as? NSNumber)?.doubleValue,
                course: (params["course"] as? NSNumber)?.doubleValue,
            )
        case "location.clear":
            return try clearSimulatedLocation()
        case "location.current":
            return try currentLocation(timeout: number(params, "timeout", default: 10))
        case "developer_mode.status":
            return try developerModeStatus()
        case "developer_mode.enable":
            return try enableDeveloperMode()
        case "power.low_power_mode":
            if let enabled = params["enabled"] as? Bool {
                return try setLowPowerMode(enabled)
            }
            return try lowPowerMode()
        case "clipboard.get":
            return try clipboardInfo()
        case "clipboard.set":
            return try setClipboard(string(params, "text"))
        case "clipboard.clear":
            guard let pasteboard = UIPasteboard(name: .general, create: false) else {
                throw GuestAPIError.operationFailed("The system clipboard is unavailable")
            }
            pasteboard.items = []
            return try clipboardInfo()
        case "files.list":
            return try fileList(string(params, "path"))
        case "files.mkdir":
            return try makeDirectory(string(params, "path"), mode: nil)
        case "files.remove":
            return try removePath(string(params, "path"), recursive: params["recursive"] as? Bool ?? false,
                                  force: true)
        case "files.rename":
            return try movePath(string(params, "from"), to: string(params, "to"))
        case "settings.get":
            return try readPreference(domain: string(params, "domain"), key: params["key"] as? String)
        case "settings.set":
            let rawValue = params["value"] ?? NSNull()
            let type = params["type"] as? String
                ?? (rawValue is Bool ? "bool"
                    : rawValue is NSNumber ? "float"
                    : rawValue is String ? "string" : "json")
            let text: String = if type == "json" {
                try String(data: JSONSerialization.data(withJSONObject: rawValue), encoding: .utf8) ?? ""
            } else {
                String(describing: rawValue)
            }
            return try writePreference(
                domain: string(params, "domain"),
                key: string(params, "key"),
                value: PreferenceValue(text: text, type: type),
            )
        case "settings.delete":
            return try deletePreference(domain: string(params, "domain"), key: string(params, "key"))
        case "accessibility.tree":
            throw GuestAPIError.operationFailed("The accessibility tree is not available on this guest yet.")
        case "keychain.list":
            return try GuestKeychain.list(className: params["class"] as? String)
        case "keychain.add":
            return try GuestKeychain.add(
                account: string(params, "account"),
                service: string(params, "service"),
                password: string(params, "password")
            )
        case "keychain.delete":
            return try GuestKeychain.delete(
                account: string(params, "account"),
                service: string(params, "service")
            )
        case "agent.apply_update":
            let expected = try string(params, "sha256")
            let cache = "/var/root/Library/Caches/vphoned"
            let next = cache + ".next"
            let data = try Data(contentsOf: URL(fileURLWithPath: next), options: .mappedIfSafe)
            let actual = sha256Hex(data)
            guard actual == expected else { throw GuestAPIError.invalidRequest("Update hash mismatch") }
            guard chmod(next, 0o755) == 0 else {
                throw GuestAPIError.operationFailed("Could not make update executable")
            }
            guard rename(next, cache) == 0 else { throw GuestAPIError.operationFailed("Could not install update") }
            try Data(expected.utf8).write(
                to: URL(fileURLWithPath: "/var/root/Library/Caches/vphoned.api-v2"),
                options: .atomic,
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return ["restarting": true]
        default:
            throw GuestAPIError.unsupportedMethod(method)
        }
    }

    private static func signAppForInstall(_ app: String, certificate: String) throws {
        let usableCertificate = FileManager.default.fileExists(atPath: certificate) ? certificate : ""
        let error = app.withCString { appPath in
            if usableCertificate.isEmpty { return vp_sign_app_for_install(appPath, nil) }
            return usableCertificate.withCString { vp_sign_app_for_install(appPath, $0) }
        }
        if let error {
            defer { free(error) }
            throw GuestAPIError.operationFailed(String(cString: error))
        }
    }

    private static func fileList(_ path: String) throws -> [String: Any] {
        var result = try listDirectory(path)
        let entries = result["entries"] as? [[String: Any]] ?? []
        result["entries"] = entries.compactMap { entry -> [String: Any]? in
            guard let fullPath = entry["path"] as? String else { return nil }
            var metadata = stat()
            guard lstat(fullPath, &metadata) == 0 else { return nil }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            let isLink = kind == mode_t(S_IFLNK)
            var target = stat()
            let targetsDirectory = isLink && stat(fullPath, &target) == 0
                && target.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            var enriched = entry
            enriched["type"] = isLink ? "link" : kind == mode_t(S_IFDIR) ? "dir" : "file"
            enriched["link_target_dir"] = targetsDirectory
            if kind == mode_t(S_IFDIR) || targetsDirectory,
               let canonicalPath = fullPath.withCString({ realpath($0, nil) }) {
                enriched["resolved_path"] = String(cString: canonicalPath)
                free(canonicalPath)
            }
            enriched["size"] = metadata.st_size
            enriched["perm"] = String(metadata.st_mode & 0o777, radix: 8)
            enriched["mtime"] = Double(metadata.st_mtimespec.tv_sec)
            return enriched
        }
        return result
    }

    private static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw GuestAPIError.invalidRequest("\(key) is required")
        }
        return value
    }

    private static func integer(_ params: [String: Any], _ key: String) throws -> Int {
        guard let value = params[key] as? NSNumber else {
            throw GuestAPIError.invalidRequest("\(key) must be an integer")
        }
        return value.intValue
    }

    private static func number(_ params: [String: Any], _ key: String, default fallback: Double = .nan) -> Double {
        if let value = params[key] as? NSNumber { return value.doubleValue }
        if let value = params[key] as? String, let number = Double(value) { return number }
        return fallback
    }
}
