import CoreLocation
import CryptoKit
import Darwin
import Foundation
import IcliKit
import IcliSystem
import UIKit
import VphonedNative

enum CoreMethod: String, GuestMethod {
    case deviceSnapshot = "device.snapshot"
    case deviceScreen = "device.screen"
    case screenScreenshot = "screen.screenshot"
    case appsList = "apps.list"
    case appsSearch = "apps.search"
    case appsRefresh = "apps.refresh"
    case appsLaunch = "apps.launch"
    case appsTerminate = "apps.terminate"
    case appsUninstall = "apps.uninstall"
    case appsForeground = "apps.foreground"
    case appsOpenUrl = "apps.open_url"
    case appsInstall = "apps.install"
    case bootstrapInstall = "bootstrap.install"
    case bootstrapPackages = "bootstrap.packages"
    case bootstrapStatus = "bootstrap.status"
    case bootstrapInspect = "bootstrap.inspect"
    case bootstrapUninstall = "bootstrap.uninstall"
    case bootstrapFirmware = "bootstrap.firmware"
    case inputTouch = "input.touch"
    case inputTouch2 = "input.touch2"
    case inputPointer = "input.pointer"
    case inputScroll = "input.scroll"
    case inputHid = "input.hid"
    case locationSet = "location.set"
    case locationClear = "location.clear"
    case locationCurrent = "location.current"
    case developerModeStatus = "developer_mode.status"
    case developerModeEnable = "developer_mode.enable"
    case powerLowPowerMode = "power.low_power_mode"
    case locationServices = "location.services"
    case clipboardGet = "clipboard.get"
    case clipboardSet = "clipboard.set"
    case clipboardClear = "clipboard.clear"
    case filesList = "files.list"
    case filesMkdir = "files.mkdir"
    case filesRemove = "files.remove"
    case filesRename = "files.rename"
    case settingsGet = "settings.get"
    case settingsSet = "settings.set"
    case settingsDelete = "settings.delete"
    case keychainList = "keychain.list"
    case keychainAdd = "keychain.add"
    case keychainGet = "keychain.get"
    case keychainUpdate = "keychain.update"
    case keychainDelete = "keychain.delete"
    case agentApplyUpdate = "agent.apply_update"
    case methodsList = "methods.list"

    var spec: MethodSpec {
        switch self {
        case .deviceSnapshot: MethodSpec(result: [.required("battery", .object),
                                                  .required("boot_session_uuid", .any),
                                                  .required("boot_time", .any),
                                                  .required("host", .string),
                                                  .required("ios_version", .string),
                                                  .required("jailbreak", .object),
                                                  .required("kernel", .string),
                                                  .required("lock", .object),
                                                  .required("memory_bytes", .integer),
                                                  .required("model", .string),
                                                  .required("processor_count", .integer),
                                                  .required("storage", .object),
                                                  .required("sysname", .string),
                                                  .required("uptime_seconds", .any)])
        case .deviceScreen: MethodSpec(result: [.required("height", .number),
                                                .required("locked", .boolean),
                                                .required("orientation", .integer),
                                                .required("scale", .number),
                                                .required("screen_off", .boolean),
                                                .required("width", .number)])
        case .screenScreenshot: MethodSpec(.optional("max_dimension", .integer),
                                           .optional("quality", .number),
                                           .optional("region", .object),
                                           result: [.required("bytes", .integer),
                                                    .required("coordinate_scale", .number),
                                                    .required("data", .string),
                                                    .required("height", .integer),
                                                    .required("mime_type", .string),
                                                    .required("point_height", .number),
                                                    .required("point_width", .number),
                                                    .required("region", .object),
                                                    .required("width", .integer)])
        case .appsList: MethodSpec(.optional("filter", .string), result: [.required("apps", .array)])
        case .appsSearch: MethodSpec(.required("query", .string), result: [.required("apps", .any), .required("query", .string)])
        case .appsRefresh: MethodSpec(.optional("directory", .string), result: [
                                          .required("directory", .string),
                                          .required("failed", .array),
                                          .required("registered", .array),
                                          .required("skipped", .array),
                                          .required("unchanged", .array),
                                          .required("unregistered", .array),
                                          .required("unverified", .array)])
        case .appsLaunch: MethodSpec(.required("bundle_id", .string), .optional("url", .string), result: [
                                         .required("frontmost_verified", .boolean),
                                         .required("pid", .any),
                                         .optional("warning", .string)])
        case .appsTerminate: MethodSpec(.required("bundle_id", .string), result: [
                                            .required("already_stopped", .boolean),
                                            .required("killed", .string),
                                            .required("pids", .array)])
        case .appsUninstall:
            MethodSpec(.required("bundle_id", .string),
                       force: .always { p in try "uninstall \(GuestAPI.string(p, "bundle_id"))" }, result: [
                           .optional("method", .string),
                           .optional("removed_containers", .array),
                           .required("uninstalled", .string)])
        case .appsForeground: MethodSpec(result: [
                .required("bundle_id", .string),
                .required("name", .string),
                .required("pid", .any),
                .required("source", .any),
                .required("verified", .any)])
        case .appsOpenUrl: MethodSpec(.required("url", .string), .optional("bundle_id", .string), result: [.optional("bundle_id", .string), .required("url", .string)])
        case .appsInstall:
            MethodSpec(.required("path", .string), .optional("cert_path", .string), .optional("registration", .string), result: [
                           .required("bundle_container", .string),
                           .required("bundle_id", .string),
                           .required("bundle_path", .string),
                           .required("containerized", .any),
                           .required("data_container", .any),
                           .required("method", .string),
                           .required("msg", .string),
                           .required("plugins", .any),
                           .required("registration", .string),
                           .required("unregistered_plugins", .any),
                           .required("upgraded", .boolean)])
        case .bootstrapInstall: MethodSpec(.required("layout", .string), .optional("package_path", .string), result: [
                                               .required("app_path", .any),
                                               .required("architecture", .string),
                                               .required("dpkg_database_updated", .boolean),
                                               .required("firmware_version", .string),
                                               .required("jbroot", .string),
                                               .required("layout", .string),
                                               .required("maintainer_scripts_executed", .boolean),
                                               .required("registration", .any),
                                               .optional("roothide_base", .object),
                                               .required("service_load", .object),
                                               .optional("service_start", .object),
                                               .optional("service_start_warning", .string),
                                               .required("service_status", .object),
                                               .required("tag", .string),
                                               .required("version", .any)])
        case .bootstrapPackages: MethodSpec(result: [
                .optional("jbroot", .string),
                .required("packages", .array),
                .optional("repositories", .array),
                .optional("skipped", .string)])
        case .bootstrapStatus: MethodSpec(result: [
                .optional("downloaded_bytes", .integer),
                .optional("error", .string),
                .optional("jbroot", .any),
                .optional("layout", .any),
                .optional("packages", .array),
                .required("phase", .string),
                .optional("tag", .any),
                .optional("total_bytes", .integer),
                .optional("version", .any)])
        case .bootstrapInspect: MethodSpec(result: [
                .required("installed", .boolean),
                .optional("jbroot", .string),
                .optional("layout", .string),
                .required("roots", .any)])
        case .bootstrapUninstall:
            MethodSpec(.optional("roots", .array),
                       .optional("jbroot", .string),
                       .optional("reboot", .boolean),
                       force: .always { _ in "uninstall the bootstrap" }, result: [
                           .required("deleted", .boolean),
                           .required("reboot_scheduled", .boolean),
                           .required("roots", .array)])
        case .bootstrapFirmware: MethodSpec(result: [
                .required("dpkg_database_updated", .boolean),
                .required("firmware_version", .string),
                .required("jbroot", .string),
                .required("layout", .string)])
        case .inputTouch:
            MethodSpec(.required("phase", .string),
                       .optional("x", .number),
                       .optional("y", .number),
                       .optional("edge", .integer),
                       .optional("normalized", .boolean), result: [.optional("digitizer_x", .number),
                                .optional("digitizer_y", .number),
                                .optional("edge", .integer),
                                .optional("normalized", .boolean),
                                .required("phase", .string),
                                .optional("x", .number),
                                .optional("y", .number)])
        case .inputTouch2:
            MethodSpec(.required("phase", .string),
                       .optional("x1", .number),
                       .optional("y1", .number),
                       .optional("x2", .number),
                       .optional("y2", .number),
                       .optional("normalized", .boolean), result: [.required("fingers", .integer), .required("phase", .any)])
        case .inputPointer:
            MethodSpec(.required("x", .number),
                       .required("y", .number),
                       .optional("seq", .integer),
                       .optional("buttons", .integer), result: [.required("buttons", .integer), .required("x", .number), .required("y", .number)])
        case .inputScroll:
            MethodSpec(.required("phase", .string),
                       .optional("dx", .number),
                       .optional("dy", .number),
                       .optional("x", .number),
                       .optional("y", .number), result: [.required("phase", .string)])
        case .inputHid:
            MethodSpec(.required("page", .integer),
                       .required("usage", .integer),
                       .optional("long_press", .boolean),
                       .optional("down", .boolean), result: [.required("action", .string), .optional("long_press", .boolean), .required("page", .integer), .required("usage", .integer)])
        case .locationSet:
            MethodSpec(.required("latitude", .number),
                       .required("longitude", .number),
                       .optional("altitude", .number),
                       .optional("horizontal_accuracy", .number),
                       .optional("vertical_accuracy", .number),
                       .optional("speed", .number),
                       .optional("course", .number), result: [.required("location", .object), .required("simulating", .boolean)])
        case .locationClear: MethodSpec(result: [.optional("location", .object), .required("simulating", .boolean)])
        case .locationCurrent: MethodSpec(.optional("timeout", .number), result: [.optional("age_seconds", .any),
                                                   .optional("altitude", .any),
                                                   .optional("client", .string),
                                                   .optional("course", .any),
                                                   .optional("error", .string),
                                                   .optional("fresh", .any),
                                                   .optional("horizontal_accuracy", .any),
                                                   .optional("latitude", .any),
                                                   .optional("longitude", .any),
                                                   .optional("simulated", .any),
                                                   .optional("speed", .any),
                                                   .optional("timestamp", .any),
                                                   .optional("vertical_accuracy", .any)])
        case .developerModeStatus: MethodSpec(result: [.required("armed", .boolean), .required("enabled", .boolean), .required("writable", .boolean)])
        case .developerModeEnable: MethodSpec(result: [.optional("already_enabled", .any),
                                                       .required("armed", .boolean),
                                                       .required("enabled", .boolean),
                                                       .optional("restart_required", .boolean),
                                                       .required("writable", .boolean)])
        case .powerLowPowerMode: MethodSpec(.optional("enabled", .boolean), result: [.optional("changed", .boolean), .required("enabled", .boolean), .required("method", .string)])
        case .locationServices: MethodSpec(.optional("enabled", .boolean), result: [.required("enabled", .boolean)])
        case .clipboardGet: MethodSpec(result: [
                .required("change_count", .integer),
                .required("has_image", .boolean),
                .required("has_text", .boolean),
                .optional("image", .object),
                .required("items", .integer),
                .required("method", .string),
                .required("text", .any),
                .required("types", .any)])
        case .clipboardSet: MethodSpec(.required("text", .string), result: [
                                           .required("change_count", .integer),
                                           .required("has_image", .boolean),
                                           .required("has_text", .boolean),
                                           .optional("image", .object),
                                           .required("items", .integer),
                                           .required("method", .string),
                                           .required("text", .any),
                                           .required("types", .any)])
        case .clipboardClear: MethodSpec(result: [
                .required("change_count", .integer),
                .required("has_image", .boolean),
                .required("has_text", .boolean),
                .optional("image", .object),
                .required("items", .integer),
                .required("method", .string),
                .required("text", .any),
                .required("types", .any)])
        case .filesList: MethodSpec(.required("path", .string), result: [.required("entries", .array), .required("path", .string)])
        case .filesMkdir: MethodSpec(.required("path", .string), result: [.required("created", .boolean), .required("path", .string)])
        case .filesRemove: MethodSpec(.required("path", .string), .optional("recursive", .boolean), result: [
                                          .optional("message", .string),
                                          .required("path", .string),
                                          .required("removed", .boolean),
                                          .optional("type", .string)])
        case .filesRename: MethodSpec(.required("from", .string), .required("to", .string), result: [.required("destination", .string), .required("source", .string)])
        case .settingsGet: MethodSpec(.required("domain", .string), .optional("key", .string), result: [
                                          .optional("count", .integer),
                                          .required("domain", .string),
                                          .optional("exists", .boolean),
                                          .optional("key", .string),
                                          .optional("type", .string),
                                          .required("user", .string),
                                          .optional("value", .any).open(),
                                          .optional("values", .object).open()])
        case .settingsSet:
            MethodSpec(.required("domain", .string),
                       .required("key", .string),
                       .required("value", .any),
                       .optional("type", .string), result: [
                           .optional("count", .integer),
                           .required("domain", .string),
                           .optional("exists", .boolean),
                           .optional("key", .string),
                           .optional("notified", .string),
                           .optional("type", .string),
                           .required("user", .string),
                           .optional("value", .any).open(),
                           .optional("values", .object).open()])
        case .settingsDelete: MethodSpec(.required("domain", .string), .required("key", .string), result: [
                                             .required("domain", .string),
                                             .required("exists", .boolean),
                                             .required("key", .string),
                                             .optional("notified", .string),
                                             .required("removed", .boolean),
                                             .required("user", .string)])
        case .keychainList: MethodSpec(.optional("class", .string), result: [.required("count", .integer), .required("diag", .array), .required("items", .array)])
        case .keychainAdd:
            MethodSpec(.required("account", .string), .required("service", .string), .required("password", .string), result: [.required("ok", .boolean), .required("status", .integer)])
        case .keychainGet:
            MethodSpec(.optional("class", .string),
                       .optional("account", .string),
                       .optional("service", .string),
                       .optional("server", .string),
                       .optional("group", .string),
                       .optional("accessGroup", .string), result: [.required("ok", .boolean), .required("value", .string).open()])
        case .keychainUpdate:
            MethodSpec(.optional("class", .string),
                       .required("account", .string),
                       .optional("service", .string),
                       .optional("server", .string),
                       .optional("group", .string),
                       .optional("accessGroup", .string),
                       .required("value", .string), result: [.required("ok", .boolean)])
        case .keychainDelete:
            MethodSpec(.optional("class", .string),
                       .optional("account", .string),
                       .optional("service", .string),
                       .optional("server", .string),
                       .optional("group", .string),
                       .optional("accessGroup", .string), result: [.required("ok", .boolean), .required("removed", .boolean)])
        case .agentApplyUpdate: MethodSpec(.required("sha256", .string), result: [.required("restarting", .boolean)])
        case .methodsList: MethodSpec(result: [.required("methods", .array)])
        }
    }
}

/// The API boundary is deliberately small: named operations and JSON values.
/// IcliKit owns general device work, including app installation and Keychain
/// metadata. vphone signs app code before IcliKit installs it.
enum GuestAPI {
    /// Each request executes independently. A synchronous system service such
    /// as powerd may wait during boot; it must not hold up HID or file requests.
    static let queue = DispatchQueue(
        label: "vphoned.api.operations", qos: .userInitiated,
        attributes: .concurrent,
    )
    static let binaryHash: String = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return "unknown" }
        return sha256Hex(data)
    }()

    /// New each time vphoned starts: after a guest boot, a userspace reboot, an
    /// update or a crash. A host tells a vphoned that just started from a
    /// connection it lost and found again by this, not by reconnecting.
    static let instance = UUID().uuidString

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The address the host shows for the guest, from icli's
    /// `"<interface> <address>"` strings: the NIC's (`en0`) IPv4 address,
    /// which is where the host forwards ports to, then a 192.x IPv4 address
    /// (the NAT network), then any other routable IPv4, then a routable IPv6.
    /// Loopback and link-local addresses, which sort first, never qualify.
    static func preferredAddress(_ addresses: [String]) -> String? {
        func routableIPv4(_ host: String) -> Bool {
            !host.contains(":") && !host.hasPrefix("127.") && !host.hasPrefix("169.254.")
        }
        let entries = addresses.map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
        let nic = entries.first { $0.count == 2 && $0[0] == "en0" && routableIPv4($0[1]) }?[1]
        let hosts = entries.compactMap(\.last)
        let ipv4 = hosts.filter(routableIPv4)
        let ipv6 = hosts.filter { $0.contains(":") && $0 != "::1" && !$0.contains("%") && !$0.hasPrefix("fe80:") }
        return nic ?? ipv4.first { $0.hasPrefix("192.") } ?? ipv4.first ?? ipv6.first
    }

    static func health() -> [String: Any] {
        let ip = preferredAddress(networkInfo()["addresses"] as? [String] ?? [])
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "name": "vphoned",
            "api_version": 1,
            "status": "ok",
            "os": GuestRuntimePlatform.isVisionOS ? "visionOS" : GuestRuntimePlatform.productName,
            "binary_hash": binaryHash,
            "instance": instance,
            "ios": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "ip": ip ?? "",
            "setup_pending": GuestRuntimePlatform.isVisionOS ? false : setupAssistantPending(),
            "mobilegestalt_restart_pending": GuestMobileGestaltCache.restartPending(),
            "capabilities": GuestRuntimePlatform.isVisionOS ? (GuestRuntimePlatform.visionOSCapabilities + scriptCapabilities() + visionOSImmersionCapabilities) : [
                "touch",
                "touch2",
                "touch_edge",
                "hid",
                "apps",
                "ota_system_apps",
                "url",
                "files",
                "clipboard",
                "location",
                "keychain",
                "keychain_edit",
                "ipa_install",
                "bootstrap_install",
                "bootstrap_packages",
                "bootstrap_uninstall",
                "port_forward",
                "camera",
                "screenshot",
                "device_info",
                "display",
                "display_layout",
                "display_capture_active",
                "display_orientation",
                "display_auto_lock",
                "device_pose",
                "screen_unlock",
                "audio",
                "input_gestures",
                "ui_inspection",
                "processes",
                "services",
                "service_profile",
                "service_kickstart",
                "logs",
                "network_capture",
                "app_details",
                "system_app_removal",
                "system_control",
                "system_shutdown",
                "file_tools",
                "apfs_snapshots",
                "files_app_drop",
                "packages",
                "environment_update",
                "udid_override",
                "setup_skip",
                "setup_settle",
                "network_ipv4",
                "network_hostname",
                "device_name",
                "network_static_names",
                "network_resolve",
                "timezone",
                "clock",
                "audio_host_latency",
                "motion_gyroscope",
                "motion_gyroscope_toggle",
                "motion_attitude",
                "methods",
            ] + pointerCapabilities() + scriptCapabilities() + GuestHomePodDisplay.capabilities
                + GuestHomePodDebug.capabilities + GuestHomeViewDistance.capabilities,
        ]
    }

    /// iPadOS accepts a pointing device directly. iPhones normally need
    /// AssistiveTouch, but may explicitly opt in to host pointer forwarding.
    /// Advertising the transport does not promise that iOS consumes it.
    private static func pointerCapabilities() -> [String] {
        let machine = GuestVirtualAudioProduct.machine()
        if machine.hasPrefix("iPad") { return ["pointer_scroll", "pointer_buttons"] }
        guard machine.hasPrefix("iPhone"),
              let preference = try? readPreference(domain: "com.vphone.vphoned", key: "iPhonePointerEnabled"),
              preference["type"] as? String == "bool",
              preference["value"] as? Bool == true
        else { return [] }
        return ["pointer_scroll", "pointer_buttons"]
    }

    static func execute(method: String, params: [String: Any]) throws -> [String: Any] {
        try GuestMethodArea.dispatch(areas, method: method, params: params)
    }

    /// `screen.screenshot`. Without options the capture is base64-encoded as it
    /// is; otherwise the daemon crops, scales and encodes it, so only the final
    /// image crosses vsock.
    private static func sizedScreenshot(_ options: GuestScreenshotSizing.Options) throws -> [String: Any] {
        let screen = screenInfo()
        guard let pointWidth = (screen["width"] as? NSNumber)?.doubleValue,
              let pointHeight = (screen["height"] as? NSNumber)?.doubleValue,
              pointWidth > 0, pointHeight > 0
        else {
            throw GuestAPIError.operationFailed("screenshot failed: the screen size is unknown")
        }
        var capture: [String: Any]
        do { capture = try takeScreenshot(base64: options.isEmpty, nativeResolution: true) } catch {
            throw GuestAPIError.operationFailed("screenshot capture failed: \(error)")
        }
        if !options.isEmpty {
            guard let path = capture["path"] as? String else {
                throw GuestAPIError.operationFailed("screenshot capture failed: no scratch file")
            }
            defer { try? FileManager.default.removeItem(atPath: path) }
            do { capture["jpeg"] = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
                throw GuestAPIError.operationFailed("screenshot read failed: \(error.localizedDescription)")
            }
        }
        return try GuestScreenshotSizing.reply(
            capture: capture,
            options: options,
            pointSize: (Double(pointWidth), Double(pointHeight)),
        )
    }

    static func executeCore(_ m: CoreMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .deviceSnapshot:
            var snapshot = try collectDeviceSnapshot()
            snapshot["jailbreak"] = jailbreakInfo()
            return snapshot
        case .deviceScreen:
            return try activeScreenInfo()
        case .screenScreenshot:
            return try sizedScreenshot(try GuestScreenshotSizing.parse(params))
        case .appsList:
            let filter = params["filter"] as? String ?? "all"
            let apps = try listedApps()
            let running = try runningApps()["apps"] as? [[String: Any]] ?? []
            let pids = Dictionary(
                uniqueKeysWithValues: running.compactMap { app -> (String, Int)? in
                    guard let id = app["bundle_id"] as? String, let pid = app["pid"] as? Int else { return nil }
                    return (id, pid)
                },
            )
            return [
                "apps": apps.compactMap { app -> [String: Any]? in
                    var info = app
                    guard let id = app["bundle_id"] as? String, !id.isEmpty else { return nil }
                    let pid = pids[id] ?? 0
                    let path = app["bundle_path"] as? String ?? ""
                    let type: String =
                        if let registeredType = (app["type"] as? String)?.lowercased(),
                        registeredType == "system" || registeredType == "user" {
                            registeredType
                        } else {
                            path.hasPrefix("/System/") || id.hasPrefix("com.apple.") ? "system" : "user"
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
                },
            ]
        case .appsSearch:
            return try searchApps(string(params, "query"))
        case .appsRefresh:
            return try refreshAppRegistrations(directory: params["directory"] as? String)
        case .appsLaunch:
            let id = try string(params, "bundle_id")
            if let url = params["url"] as? String {
                _ = try openAppURL(url, bundleID: id)
            } else {
                let before = try runningApps()["apps"] as? [[String: Any]] ?? []
                let wasRunning = before.contains { $0["bundle_id"] as? String == id }
                do {
                    _ = try launchApp(id)
                } catch let IcliError.failed(message) where message == "app did not become frontmost: \(id)" {
                    let after = try runningApps()["apps"] as? [[String: Any]] ?? []
                    guard let pid = after.first(where: { $0["bundle_id"] as? String == id })?["pid"] as? Int
                    else { throw IcliError.failed(message) }
                    let front = frontmostApp()
                    if front["verified"] as? Bool == true,
                       front["bundle_id"] as? String == id
                    {
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
        case .appsTerminate:
            return try killApp(string(params, "bundle_id"), force: true)
        case .appsUninstall:
            let id = try string(params, "bundle_id")
            return try uninstallApp(id, force: true)
        case .appsForeground:
            let front = frontmostApp()
            let id = front["bundle_id"] as? String ?? ""
            let apps = try searchApps(id)["apps"] as? [[String: Any]] ?? []
            let running = try runningApps()["apps"] as? [[String: Any]] ?? []
            let name =
                id == "com.apple.springboard"
                    ? "Home Screen"
                    : (apps.first(where: { $0["bundle_id"] as? String == id })?["name"] as? String ?? "")
            return [
                "bundle_id": id,
                "name": name,
                "pid": running.first(where: { $0["bundle_id"] as? String == id })?["pid"] ?? 0,
                "verified": front["verified"] ?? false,
                "source": front["source"] ?? "",
            ]
        case .appsOpenUrl:
            return try openAppURL(string(params, "url"), bundleID: params["bundle_id"] as? String)
        case .appsInstall:
            let path = try string(params, "path")
            let certificate = params["cert_path"] as? String ?? ""
            let registration: AppRegistrationType = params["registration"] as? String == "System" ? .system : .user
            defer {
                try? FileManager.default.removeItem(atPath: path)
                if !certificate.isEmpty {
                    try? FileManager.default.removeItem(atPath: certificate)
                }
            }
            var result = try installIPAInContainer(path, registration: registration) { app in
                try signAppForInstall(app, certificate: certificate)
            }
            let id = result["bundle_id"] as? String ?? "app"
            result["msg"] = "Installed \(id) as a \(registration.rawValue) app."
            return result
        case .bootstrapInstall:
            let layout = try string(params, "layout")
            if GuestRuntimePlatform.isVisionOS, layout != "rootless" {
                throw GuestAPIError.invalidRequest("visionOS currently supports the rootless Irisin layout only")
            }
            return try GuestIrisinInstaller.install(
                jailbreak: jailbreakInfo(),
                layout: layout,
                packagePath: params["package_path"] as? String,
            )
        case .bootstrapPackages:
            return try GuestIrisinInstaller.installPackages(GuestIrisinInstaller.initialPackages)
        case .bootstrapStatus:
            return GuestIrisinInstaller.status()
        case .bootstrapInspect:
            return try GuestIrisinInstaller.installedBootstrap()
        case .bootstrapUninstall:
            let roots = try (params["roots"] as? [String]) ?? [string(params, "jbroot")]
            return try GuestIrisinInstaller.uninstall(
                expectedRoots: roots,
                reboot: params["reboot"] as? Bool ?? true,
            )
        case .bootstrapFirmware:
            return try GuestIrisinInstaller.repairFirmwareRecord()
        case .inputTouch:
            return try executeTouch(params)
        case .inputTouch2:
            // Two fingers in one hand event. icli's `input.touch` carries a
            // single digitizer point, so a pinch has to go through vphoned's own
            // injection path (`vp_hid_touch2`) instead.
            guard let phase = (params["phase"] as? String).flatMap(TouchPhase.init(rawValue:)) else {
                throw GuestAPIError.invalidRequest("phase must be down, move or up")
            }
            // `vp_hid_touch2` takes normalized coordinates only. `input.touch`
            // also accepts screen points, so refuse the flag here rather than
            // read points as fractions and put both fingers in the corner.
            guard params["normalized"] as? Bool ?? true else {
                throw GuestAPIError.invalidRequest("touch2 coordinates are normalized 0..1 only")
            }
            vp_hid_touch2(
                touchPhaseCode(phase),
                number(params, "x1"), number(params, "y1"),
                number(params, "x2"), number(params, "y2"),
            )
            return ["phase": phase.rawValue, "fingers": 2]
        case .inputPointer:
            let point: GuestPointerScroll.Point
            let sequence: UInt64
            let buttons: Int32
            do {
                point = try GuestPointerScroll.point(params)
                sequence = try GuestPointerScroll.sequence(params)
                buttons = try GuestPointerScroll.buttons(params)
            } catch {
                throw GuestAPIError.invalidRequest(error.message)
            }
            try movePointer(point, sequence: sequence, buttons: buttons)
            return ["x": point.x, "y": point.y, "buttons": Int(buttons)]
        case .inputScroll:
            let scroll: GuestPointerScroll.Scroll
            do {
                scroll = try GuestPointerScroll.scroll(params)
            } catch {
                throw GuestAPIError.invalidRequest(error.message)
            }
            try scrollPointer(scroll)
            return ["phase": scroll.phase.rawValue]
        case .inputHid:
            let page = try integer(params, "page")
            let usage = try integer(params, "usage")
            if let value = params["long_press"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw GuestAPIError.invalidRequest("long_press must be a boolean")
                }
                if flag.boolValue {
                    guard (0...65535).contains(page), (0...65535).contains(usage),
                          let down = params["down"] as? NSNumber, CFGetTypeID(down) == CFBooleanGetTypeID()
                    else { throw GuestAPIError.invalidRequest("long_press requires a boolean down and 16-bit page and usage") }
                    guard vp_hid_keyboard_hold(UInt16(page), UInt16(usage), down.boolValue) else {
                        throw GuestAPIError.operationFailed("HID long-press injection is unavailable")
                    }
                    return ["page": page, "usage": usage, "action": down.boolValue ? "down" : "up", "long_press": true]
                }
            }
            if let down = params["down"] as? Bool {
                return try hidEvent(page: page, usage: usage, down: down)
            }
            return try hidPress(page: page, usage: usage)
        case .locationSet:
            guard CLLocationManager.locationServicesEnabled() else { throw GuestAPIError.locationServicesOff }
            return try simulateLocation(
                latitude: number(params, "latitude"),
                longitude: number(params, "longitude"),
                altitude: number(params, "altitude", default: 0),
                horizontalAccuracy: number(params, "horizontal_accuracy", default: 5),
                verticalAccuracy: number(params, "vertical_accuracy", default: 5),
                speed: (params["speed"] as? NSNumber)?.doubleValue,
                course: (params["course"] as? NSNumber)?.doubleValue,
            )
        case .locationClear:
            return try clearSimulatedLocation()
        case .locationCurrent:
            guard CLLocationManager.locationServicesEnabled() else { throw GuestAPIError.locationServicesOff }
            return try currentLocation(timeout: number(params, "timeout", default: 10))
        case .developerModeStatus:
            return try developerModeStatus()
        case .developerModeEnable:
            return try enableDeveloperMode()
        case .powerLowPowerMode:
            if let enabled = params["enabled"] as? Bool {
                return try setLowPowerMode(enabled)
            }
            return try lowPowerMode()
        case .locationServices:
            if let enabled = params["enabled"] as? Bool {
                return try setLocationServices(enabled)
            }
            return locationServices()
        case .clipboardGet:
            return try clipboardInfo()
        case .clipboardSet:
            return try setClipboard(string(params, "text"))
        case .clipboardClear:
            #if os(tvOS)
            throw GuestAPIError.operationFailed("tvOS has no system clipboard")
            #else
            guard let pasteboard = UIPasteboard(name: .general, create: false) else {
                throw GuestAPIError.operationFailed("The system clipboard is unavailable")
            }
            pasteboard.items = []
            return try clipboardInfo()
            #endif
        case .filesList:
            return try fileList(string(params, "path"))
        case .filesMkdir:
            return try makeDirectory(string(params, "path"), mode: nil)
        case .filesRemove:
            return try removePath(
                string(params, "path"), recursive: params["recursive"] as? Bool ?? false,
                force: true,
            )
        case .filesRename:
            return try movePath(string(params, "from"), to: string(params, "to"))
        case .settingsGet:
            return try readPreference(domain: string(params, "domain"), key: params["key"] as? String)
        case .settingsSet:
            let domain = try string(params, "domain")
            let key = try string(params, "key")
            guard let value = GuestSettingsValue.typedText(params["value"], type: params["type"] as? String) else {
                throw GuestAPIError.invalidRequest("value is required, and type json takes an array or object")
            }
            return try writePreference(
                domain: domain,
                key: key,
                value: PreferenceValue(text: value.text, type: value.type),
            )
        case .settingsDelete:
            return try deletePreference(domain: string(params, "domain"), key: string(params, "key"))
        case .keychainList:
            return try GuestKeychain.list(className: params["class"] as? String)
        case .keychainAdd:
            return try GuestKeychain.add(
                account: string(params, "account"),
                service: string(params, "service"),
                password: string(params, "password"),
            )
        case .keychainGet:
            return try GuestKeychain.get(GuestKeychain.Identity(params))
        case .keychainUpdate:
            return try GuestKeychain.update(GuestKeychain.Identity(params), value: string(params, "value"))
        case .keychainDelete:
            return try GuestKeychain.delete(GuestKeychain.Identity(params))
        case .agentApplyUpdate:
            let expected = try string(params, "sha256")
            let cache = "/var/root/Library/Caches/vphoned"
            let next = cache + ".next"
            let data = try Data(contentsOf: URL(fileURLWithPath: next), options: .mappedIfSafe)
            let actual = sha256Hex(data)
            guard actual == expected else { throw GuestAPIError.invalidRequest("The update is damaged. Try again.") }
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
        case .methodsList:
            return GuestMethodArea.catalog(areas)
        }
    }

    private static func signAppForInstall(_ app: String, certificate: String) throws {
        let usableCertificate = FileManager.default.fileExists(atPath: certificate) ? certificate : ""
        let error = app.withCString { appPath in
            if usableCertificate.isEmpty {
                return vp_sign_app_for_install(appPath, nil)
            }
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
            let targetsDirectory =
                isLink && stat(fullPath, &target) == 0
                    && target.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            var enriched = entry
            enriched["type"] = isLink ? "link" : kind == mode_t(S_IFDIR) ? "dir" : "file"
            enriched["link_target_dir"] = targetsDirectory
            if kind == mode_t(S_IFDIR) || targetsDirectory,
               let canonicalPath = fullPath.withCString({ realpath($0, nil) })
            {
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

    /// The LaunchServices records `apps.list` reports: those with a bundle
    /// identifier. `setup.settle` counts this list, not icli's `count`, which
    /// was one higher than `apps.list` on an iOS 27 guest.
    static func listedApps() throws -> [[String: Any]] {
        try (listApps()["apps"] as? [[String: Any]] ?? []).filter {
            !(($0["bundle_id"] as? String) ?? "").isEmpty
        }
    }

    static func jailbreakInfo() -> [String: Any] {
        func isDirectory(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }

        // The bootstrap vphoned installed itself, by its completion record.
        // The probes below look for a jailbreak's own traces, and a RootHide
        // root vphoned made has none: vphoned is on the system volume, away
        // from any .jbroot link or libroot library, and vphone's SystemHook
        // has no get_jbroot.
        if let installation = try? GuestIrisinInstaller.completedBootstrap(), isDirectory(installation.root) {
            return ["layout": installation.layout, "jbroot": installation.root, "source": "vphoned bootstrap"]
        }

        // A foreign RootHide can expose its root through its injected hook even
        // when vphoned has no adjacent .jbroot or libroot library.
        if let hook = dlopen("systemhook.dylib", RTLD_NOLOAD) {
            defer { dlclose(hook) }
            if let symbol = dlsym(hook, "get_jbroot") {
                typealias GetRoot = @convention(c) () -> UnsafePointer<CChar>?
                if let prefix = unsafeBitCast(symbol, to: GetRoot.self)() {
                    let path = String(cString: prefix)
                    if path.hasPrefix("/"), path != "/", isDirectory(path) {
                        return ["layout": "roothide", "jbroot": path, "source": "systemhook"]
                    }
                }
            }
        }

        let root = JailbreakRoot.current
        if let layout = root.layout, layout != .rootful, isDirectory(root.jbroot) {
            return ["layout": layout.rawValue, "jbroot": root.jbroot, "source": root.source]
        }
        if isDirectory("/var/jb") {
            return ["layout": "rootless", "jbroot": "/var/jb", "source": "filesystem /var/jb"]
        }
        var rootMount = statfs()
        if statfs("/", &rootMount) == 0, rootMount.f_flags & UInt32(MNT_RDONLY) == 0 {
            return ["layout": "rootful", "jbroot": "/", "source": "root mount"]
        }
        return ["layout": NSNull(), "jbroot": NSNull(), "source": "not detected"]
    }

    static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw GuestAPIError.invalidRequest("\(key) is required")
        }
        return value
    }

    static func integer(_ params: [String: Any], _ key: String) throws -> Int {
        guard let value = params[key] as? NSNumber else {
            throw GuestAPIError.invalidRequest("\(key) must be an integer")
        }
        return value.intValue
    }

    static func number(_ params: [String: Any], _ key: String, default fallback: Double = .nan) -> Double {
        if let value = params[key] as? NSNumber {
            return value.doubleValue
        }
        if let value = params[key] as? String, let number = Double(value) {
            return number
        }
        return fallback
    }

    static func optionalString(_ params: [String: Any], _ key: String) -> String? {
        guard let value = params[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func bool(_ params: [String: Any], _ key: String, default fallback: Bool = false) -> Bool {
        GuestMethodArea.flag(params, key, default: fallback)
    }

    static func requiredNumber(_ params: [String: Any], _ key: String) throws -> Double {
        let value = number(params, key)
        guard value.isFinite else { throw GuestAPIError.invalidRequest("\(key) must be a number") }
        return value
    }

    /// Digitizer phase codes for vphoned's own multi-finger injection path.
    /// icli keeps its equivalent mapping module-internal, and these are the
    /// values the private digitizer entry points take: 0 down, 1 move, 3 up.
    static func touchPhaseCode(_ phase: TouchPhase) -> Int32 {
        switch phase {
        case .down: 0
        case .move: 1
        case .up: 3
        }
    }
}
