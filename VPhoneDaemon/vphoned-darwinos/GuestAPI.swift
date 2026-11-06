import CryptoKit
import CoreFoundation
import Darwin
import Foundation
import IcliSystem
import IcliSystemPrivate

enum GuestAPIError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case unsupportedMethod(String)
    case operationFailed(String)

    var description: String {
        switch self {
        case let .invalidRequest(message), let .operationFailed(message): message
        case let .unsupportedMethod(method): "darwinOS does not provide the method \(method)"
        }
    }
    var code: String { "invalid_operation" }
}

/// The display's research transport. This target deliberately depends only on
/// libraries carried by darwinOS; the regular daemon links absent UI frameworks.
/// It preserves Apple's display/RemoteXPC jobs. visionOS additionally supports
/// keyboard/consumer HID submission through dynamically loaded system APIs.
enum GuestAPI {
    static let queue = DispatchQueue(label: "vphoned.darwinos.operations", qos: .userInitiated, attributes: .concurrent)
    static let instance = UUID().uuidString
    static let binaryHash: String = {
        guard let path = Bundle.main.executableURL,
              let bytes = try? Data(contentsOf: path, options: .mappedIfSafe) else { return "unknown" }
        return sha256Hex(bytes)
    }()

    static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func health() -> [String: Any] {
        ["name": "vphoned", "api_version": 1, "status": "ok", "binary_hash": binaryHash,
         "instance": instance, "ios": version()["ProductVersion"] ?? "", "os": osName,
         "ip": networkAddresses().first { !$0.hasPrefix("127.") && !$0.contains(":") } ?? "",
         "setup_pending": false, "capabilities": ["files", "port_forward", "device_info", "processes", "services", "shell"] + (osName == "visionOS" && vp_darwin_hid_available() ? ["hid"] : [])]
    }

    static func execute(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "input.hid": return try submitHID(params)
        case "device.info", "device.snapshot": return try deviceInfo()
        case "device.network": return ["addresses": networkAddresses()]
        case "processes.list": return try listProcesses(filter: params["filter"] as? String)
        case "services.list": return try listServices()
        case "services.status": return try serviceStatus(string(params, "label"))
        case "services.print": return try printService(string(params, "label"))
        case "services.dump": return try servicesDump()
        case "services.disabled": return try disabledServiceOverrides()
        case "services.start": return try serviceAction(params) { icli_launchd_start_json($0) }
        case "services.enable": return try serviceAction(params) { icli_launchd_enable_json($0, true) }
        case "services.stop":
            try requireForce(params)
            return try serviceAction(params) { icli_launchd_stop_json($0) }
        case "services.disable":
            try requireForce(params)
            return try serviceAction(params) { icli_launchd_enable_json($0, false) }
        case "services.kickstart":
            let kill = params["kill"] as? Bool ?? false
            if kill { try requireForce(params) }
            return try serviceAction(params) { icli_launchd_kickstart_json($0, kill) }
        case "files.list": return try VPhoneDarwinFileSystem.listDirectory(string(params, "path"))
        case "files.mkdir":
            let path = try string(params, "path")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return ["path": path]
        case "files.rename":
            let source = try string(params, "from"), target = try string(params, "to")
            try FileManager.default.moveItem(atPath: source, toPath: target)
            return ["from": source, "to": target]
        case "files.remove":
            let path = try string(params, "path")
            // Match the normal file API: a directory must be empty unless the
            // caller explicitly asks for recursive removal.
            if params["recursive"] as? Bool == true {
                try FileManager.default.removeItem(atPath: path)
            } else if unlink(path) != 0 && rmdir(path) != 0 {
                throw GuestAPIError.operationFailed(String(cString: strerror(errno)))
            }
            return ["path": path]
        case "proc.run": return try runProgram(params)
        case "agent.apply_update": return try applyUpdate(params)
        default: throw GuestAPIError.unsupportedMethod(method)
        }
    }

    static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty, !value.contains("\0") else {
            throw GuestAPIError.invalidRequest("\(key) must be a nonempty string")
        }
        return value
    }

    private static func submitHID(_ params: [String: Any]) throws -> [String: Any] {
        guard osName == "visionOS" else { throw GuestAPIError.unsupportedMethod("input.hid") }
        let page = try hidUsage(params, "page"), usage = try hidUsage(params, "usage")
        let down = try hidBoolean(params, "down")
        let longPress = try hidBoolean(params, "long_press") ?? false
        guard !longPress || down != nil else {
            throw GuestAPIError.invalidRequest("long_press requires an explicit boolean down")
        }
        var error: UnsafeMutablePointer<CChar>?
        defer { free(error) }
        guard vp_darwin_hid_submit(page, usage, down.map { $0 ? 1 : 0 } ?? -1, longPress, &error) else {
            throw GuestAPIError.operationFailed(error.map { String(cString: $0) } ?? "HID submission failed")
        }
        return ["page": Int(page), "usage": Int(usage), "action": down.map { $0 ? "down" : "up" } ?? "press",
                "long_press": longPress, "submitted": true]
    }

    private static func hidUsage(_ params: [String: Any], _ key: String) throws -> UInt16 {
        guard let number = params[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw GuestAPIError.invalidRequest("\(key) must be a 16-bit unsigned integer")
        }
        let value = number.doubleValue
        guard value.isFinite, (0...65535).contains(value), value.rounded(.towardZero) == value else {
            throw GuestAPIError.invalidRequest("\(key) must be a 16-bit unsigned integer")
        }
        return UInt16(value)
    }

    private static func hidBoolean(_ params: [String: Any], _ key: String) throws -> Bool? {
        guard let value = params[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw GuestAPIError.invalidRequest("\(key) must be a boolean")
        }
        return number.boolValue
    }

    private static func requireForce(_ params: [String: Any]) throws {
        guard params["force"] as? Bool == true else { throw GuestAPIError.invalidRequest("This operation requires force: true") }
    }

    private static func serviceAction(_ params: [String: Any], action: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let label = try string(params, "label")
        try validateServiceLabel(label)
        guard let text = label.withCString(action) else { throw GuestAPIError.operationFailed("launchd returned no answer") }
        defer { free(text) }
        guard let result = try JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any] else {
            throw GuestAPIError.operationFailed("launchd returned invalid JSON")
        }
        if let failure = launchdStatusError(result, "change service") { throw failure }
        return result.merging(["label": label]) { _, new in new }
    }

    /// The shared terminal resolver searches system executables when no
    /// package-manager bootstrap exists. This is a path base, not a bootstrap claim.
    static func jailbreakInfo() -> [String: Any] { ["jbroot": "/"] }

    private static func version() -> [String: Any] {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")),
              let value = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { return [:] }
        return value
    }

    private static var osName: String {
        let name = version()["ProductName"] as? String ?? ""
        return ["xrOS", "visionOS"].contains(name) ? "visionOS" : "darwinOS"
    }

    private static func deviceInfo() throws -> [String: Any] {
        let version = version()
        var info = try deviceSnapshot()
        info["os"] = osName
        info["ios_version"] = version["ProductVersion"] ?? info["ios_version"]
        info["build_version"] = version["ProductBuildVersion"] ?? ""
        info["network"] = ["addresses": networkAddresses()]
        info["agent"] = ["pid": getpid(), "binary_hash": binaryHash]
        return info
    }

    private static func networkAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: Set<String> = []
        var next = first
        while let entry = next {
            next = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.insert(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return found.sorted()
    }


    static func runProgram(_ params: [String: Any]) throws -> [String: Any] {
        guard GuestSessionLimit.evaluations.acquire() else {
            throw GuestAPIError.operationFailed(GuestSessionLimit.evaluations.refusal)
        }
        defer { GuestSessionLimit.evaluations.release() }
        let path = try string(params, "path")
        guard path.hasPrefix("/"), access(path, X_OK) == 0,
              params["args"] == nil || params["args"] is [String] else {
            throw GuestAPIError.invalidRequest("proc.run requires an absolute executable path and an array of string arguments")
        }
        let words = [path] + (params["args"] as? [String] ?? [])
        guard words.count <= 1024, words.allSatisfy({ !$0.contains("\0") && $0.utf8.count < 65536 }) else {
            throw GuestAPIError.invalidRequest("Program arguments are too large or contain NUL")
        }
        var arguments: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) } + [nil]
        defer { arguments.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var status: Int32 = 0
        var output: UnsafeMutablePointer<CChar>?, errors: UnsafeMutablePointer<CChar>?
        defer { free(output); free(errors) }
        let failure = if let input = params["input"] as? String {
            input.withCString { vp_spawn_collect(path, &arguments, $0, &status, &output, &errors) }
        } else { vp_spawn_collect(path, &arguments, nil, &status, &output, &errors) }
        guard failure == 0 else { throw GuestAPIError.operationFailed(String(cString: strerror(failure))) }
        let signal = status & 0x7F
        return ["status": signal == 0 ? (status >> 8) & 0xFF : -1,
                "signal": signal != 0 && signal != 0x7F ? signal : NSNull(),
                "stdout": output.map { String(cString: $0) } ?? "", "stderr": errors.map { String(cString: $0) } ?? ""]
    }

    private static func applyUpdate(_ params: [String: Any]) throws -> [String: Any] {
        let expected = try string(params, "sha256")
        let cache = "/var/root/Library/Caches/vphoned", next = cache + ".next"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: next), options: .mappedIfSafe)
        guard sha256Hex(bytes) == expected else { throw GuestAPIError.invalidRequest("The daemon update is damaged") }
        guard chmod(next, 0o755) == 0, rename(next, cache) == 0 else { throw GuestAPIError.operationFailed("Could not install daemon update") }
        try Data(expected.utf8).write(to: URL(fileURLWithPath: cache + ".api-v2"), options: .atomic)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exit(0) }
        return ["restarting": true]
    }
}
