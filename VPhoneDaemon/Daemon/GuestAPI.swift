import CryptoKit
import Darwin
import Foundation
import IcliKit
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
/// IcliKit owns general device work; only vphone-specific installation and
/// keychain enumeration cross into the older daemon code.
enum GuestAPI {
    // IcliKit's in-process bridge is synchronous and has not been audited for
    // concurrent callers. Keep its operations off NIO loops and in one order.
    static let queue = DispatchQueue(label: "vphoned.api.operations", qos: .userInitiated)
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
            ],
        ]
    }

    static func execute(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "device.snapshot":
            return try collectDeviceSnapshot()
        case "device.screen":
            return screenInfo()
        case "apps.list":
            let filter = params["filter"] as? String ?? "all"
            let apps = try searchApps("")["apps"] as? [[String: Any]] ?? []
            let running = try runningApps()["apps"] as? [[String: Any]] ?? []
            let pids = Dictionary(uniqueKeysWithValues: running.compactMap { app -> (String, Int)? in
                guard let id = app["bundle_id"] as? String, let pid = app["pid"] as? Int else { return nil }
                return (id, pid)
            })
            return ["apps": apps.compactMap { app -> [String: Any]? in
                var info = app
                let id = app["bundle_id"] as? String ?? ""
                let pid = pids[id] ?? 0
                let path = app["bundle_path"] as? String ?? ""
                let type = app["type"] as? String
                    ?? (path.hasPrefix("/System/") || id.hasPrefix("com.apple.") ? "system" : "user")
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
        case "apps.launch":
            let id = try string(params, "bundle_id")
            if let url = params["url"] as? String {
                _ = try openAppURL(url, bundleID: id)
            } else {
                _ = try launchApp(id)
            }
            let running = try? runningApps()["apps"] as? [[String: Any]]
            return ["pid": running?.first(where: { $0["bundle_id"] as? String == id })?["pid"] ?? 0]
        case "apps.terminate":
            return try killApp(string(params, "bundle_id"), force: true)
        case "apps.foreground":
            let front = frontmostApp()
            let id = front["bundle_id"] as? String ?? ""
            let apps = try searchApps(id)["apps"] as? [[String: Any]] ?? []
            let running = try runningApps()["apps"] as? [[String: Any]] ?? []
            return [
                "bundle_id": id,
                "name": apps.first?["name"] ?? "",
                "pid": running.first(where: { $0["bundle_id"] as? String == id })?["pid"] ?? 0,
            ]
        case "apps.open_url":
            return try openAppURL(string(params, "url"), bundleID: params["bundle_id"] as? String)
        case "apps.install":
            return try native([
                "t": "ipa_install",
                "path": string(params, "path"),
                "registration": params["registration"] as? String ?? "User",
                "cert_path": params["cert_path"] as? String ?? "",
            ])
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
        case "accessibility.tree":
            throw GuestAPIError.operationFailed("The accessibility tree is not available on this guest yet.")
        case "keychain.list":
            return try native(["t": "keychain_list", "class": params["class"] as? String ?? ""])
        case "keychain.add":
            return try native([
                "t": "keychain_add",
                "account": string(params, "account"),
                "service": string(params, "service"),
                "password": string(params, "password"),
            ])
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

    private static func native(_ message: [String: Any]) throws -> [String: Any] {
        let result = vp_native_api_command(message) as? [String: Any] ?? [:]
        if result["t"] as? String == "err" {
            throw GuestAPIError.operationFailed(result["msg"] as? String ?? "Guest operation failed")
        }
        var payload = result
        payload.removeValue(forKey: "v")
        payload.removeValue(forKey: "t")
        payload.removeValue(forKey: "id")
        return payload
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
        (params[key] as? NSNumber)?.doubleValue ?? fallback
    }
}
