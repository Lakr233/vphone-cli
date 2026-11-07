import Foundation
import IcliKit
import IcliSystem
import VphonedNative

// MARK: - Developer Mode Snapshot

/// The Developer Mode status `device.info` reports, read off the request path.
/// amfid answers the status request at once on an iPhone, but not on the tvOS
/// 26.6 and HomePod 27.0 guests checked (2026-11-03), where each query waits
/// its full 10 s (`icli_amfi_developer_mode_json`); `device.info` paid that on
/// every call, 10.03 s instead of 0.03 s.
/// The status is read once at startup and again in the background when it is
/// older than ``maximumAge``, one query at a time; `device.info` returns the
/// last answer, empty until there is one or when amfid never answers.
/// `developer_mode.status` still asks amfid directly.
final class GuestDeveloperModeSnapshot: @unchecked Sendable {
    static let shared = GuestDeveloperModeSnapshot()
    static let maximumAge: TimeInterval = 30

    private let lock = NSLock()
    private var status: [String: Any] = [:]
    private var readAt: Date?
    private var reading = false

    func startOnStartup() {
        refreshIfStale()
    }

    func current() -> [String: Any] {
        refreshIfStale()
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    private func refreshIfStale() {
        lock.lock()
        let stale = readAt.map { Date().timeIntervalSince($0) > Self.maximumAge } ?? true
        guard stale, !reading else {
            lock.unlock()
            return
        }
        reading = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let answer = (try? developerModeStatus()) ?? [:]
            self.lock.lock()
            self.status = answer
            self.readAt = Date()
            self.reading = false
            self.lock.unlock()
        }
    }
}

enum DeviceMethod: String, GuestMethod {
    case deviceInfo = "device.info"
    case deviceNetwork = "device.network"
    case networkIpv4Get = "network.ipv4.get"
    case networkIpv4Set = "network.ipv4.set"
    case networkResolve = "network.resolve"
    case networkStaticNamesGet = "network.static_names.get"
    case networkStaticNamesSet = "network.static_names.set"
    case networkHostnameGet = "network.hostname.get"
    case networkHostnameSet = "network.hostname.set"
    case deviceNameGet = "device.name.get"
    case deviceNameSet = "device.name.set"
    case deviceIoreg = "device.ioreg"
    case deviceInputDevices = "device.input_devices"
    case deviceDisplays = "device.displays"
    case displayModes = "display.modes"
    case displayExternalStatus = "display.external.status"
    case displayExternalDiagnostics = "display.external.diagnostics"
    case displayExternalConfigure = "display.external.configure"
    case displayExternalFrame = "display.external.frame"
    case deviceEnvironment = "device.environment"
    case deviceBasebin = "device.basebin"
    case displayBrightness = "display.brightness"
    case displayRotation = "display.rotation"
    case displayOrientation = "display.orientation"
    case displayPosture = "display.posture"
    case displayPose = "display.pose"
    case displayRotationLock = "display.rotation_lock"
    case displayAutoLock = "display.auto_lock"
    case displayAutoLockSet = "display.auto_lock.set"
    case screenUnlock = "screen.unlock"
    case audioVolume = "audio.volume"
    case audioState = "audio.state"
    case networkCapture = "network.capture"
    case securitySslKillswitch = "security.ssl_killswitch"
    case diagnosticsSelfTest = "diagnostics.self_test"
    case notifyPost = "notify.post"
    case notifyState = "notify.state"

    var spec: MethodSpec {
        switch self {
        case .deviceInfo: MethodSpec(result: [.required("agent", .object),
                                              .required("battery", .object),
                                              .required("boot_session_uuid", .any),
                                              .required("boot_time", .any),
                                              .required("brightness", .object),
                                              .required("developer_mode", .object),
                                              .required("device_name", .object),
                                              .required("host", .string),
                                              .required("ios_version", .string),
                                              .required("jailbreak", .object),
                                              .required("kernel", .string),
                                              .required("lock", .object),
                                              .required("low_power_mode", .object),
                                              .required("memory_bytes", .integer),
                                              .required("model", .string),
                                              .required("network", .object),
                                              .required("processor_count", .integer),
                                              .required("rotation", .object),
                                              .required("screen", .object),
                                              .required("storage", .object),
                                              .required("sysname", .string),
                                              .required("uptime_seconds", .any),
                                              .required("volume", .number)])
        case .deviceNetwork: MethodSpec(result: [.required("addresses", .array)])
        case .networkIpv4Get: MethodSpec(.optional("interface", .string), result: [.optional("address", .any), .required("dns", .array), .required("interface", .string), .required("managed", .any), .required("method", .string), .optional("router", .any), .required("service", .string), .optional("subnet_mask", .any)])
        case .networkIpv4Set:
            MethodSpec(.optional("interface", .string),
                       .required("method", .string),
                       .optional("address", .string),
                       .optional("subnet_mask", .string),
                       .optional("router", .string),
                       .optional("dns", .array), result: [.optional("address", .any), .required("changed", .boolean), .required("dns", .array), .required("interface", .string), .required("managed", .any), .required("method", .string), .optional("router", .any), .required("service", .string), .optional("subnet_mask", .any)])
        case .networkResolve:
            MethodSpec(.required("host", .string),
                       .optional("port", .integer),
                       .optional("family", .string),
                       .optional("first_only", .boolean),
                       .optional("timeout_ms", .number), result: [.optional("addresses", .any), .required("elapsed_ms", .any), .optional("error", .string), .required("host", .string), .optional("status", .string)])
        case .networkStaticNamesGet: MethodSpec(result: [.required("entries", .any)])
        case .networkStaticNamesSet: MethodSpec(.optional("entries", .array), result: [.required("changed", .boolean), .required("entries", .array)])
        case .networkHostnameGet: MethodSpec(result: [.required("local_host_name", .any), .required("managed", .boolean)])
        case .networkHostnameSet: MethodSpec(.optional("local_host_name", .string), result: [.required("changed", .boolean), .required("local_host_name", .any), .required("managed", .boolean)])
        case .deviceNameGet: MethodSpec(result: [.required("name", .any)])
        case .deviceNameSet: MethodSpec(.optional("name", .any), result: [.required("changed", .boolean), .required("name", .any), .required("reboot_required", .boolean)])
        case .deviceIoreg: MethodSpec(.optional("plane", .string), result: [.optional("count", .any),
                                               .required("entries", .array),
                                               .optional("error", .string),
                                               .optional("plane", .any)])
        case .deviceInputDevices: MethodSpec(result: [.required("available", .boolean),
                                                      .optional("reason", .string),
                                                      .optional("serviceCount", .integer),
                                                      .optional("services", .array)])
        case .deviceDisplays: MethodSpec(result: [.required("displays", .any)])
        case .displayModes: MethodSpec(result: [.required("available", .boolean), .optional("displays", .array), .optional("reason", .any)])
        case .displayExternalStatus: MethodSpec(result: [.required("enabled", .any),
                                                         .optional("error", .any),
                                                         .optional("height", .integer),
                                                         .optional("name", .string),
                                                         .optional("nonce", .string),
                                                         .optional("ok", .boolean),
                                                         .optional("width", .integer)])
        case .displayExternalDiagnostics: MethodSpec(result: [.optional("available", .boolean),
                                                              .optional("error", .any),
                                                              .optional("externalPolicyClasses", .object),
                                                              .optional("monitor", .any),
                                                              .optional("owners", .object),
                                                              .optional("sceneManager", .any),
                                                              .optional("scenes", .array),
                                                              .optional("transformer", .any),
                                                              .optional("updated", .any)])
        case .displayExternalConfigure:
            MethodSpec(.required("enabled", .boolean),
                       .optional("width", .integer),
                       .optional("height", .integer), result: [.optional("enabled", .any),
                                .optional("error", .any),
                                .optional("height", .integer),
                                .optional("name", .string),
                                .optional("nonce", .string),
                                .optional("ok", .boolean),
                                .optional("width", .integer)])
        case .displayExternalFrame: MethodSpec(result: [.required("data", .string), .required("mime_type", .string)])
        case .deviceEnvironment: MethodSpec(result: [.required("basebin_version", .string),
                                                     .required("bootstrap_tools_present", .any),
                                                     .required("euid", .integer),
                                                     .required("executable", .any),
                                                     .required("external_tools_used", .object),
                                                     .required("ios_version", .string),
                                                     .required("jbroot", .any),
                                                     .required("jbroot_source", .string),
                                                     .required("layout", .any),
                                                     .required("maintainer_scripts", .string),
                                                     .required("markers", .array),
                                                     .required("native", .array),
                                                     .required("platform_binary", .boolean),
                                                     .required("rootfs_prefix", .string),
                                                     .required("roothide_runtime_active", .boolean),
                                                     .required("spawns_processes", .boolean)])
        case .deviceBasebin: MethodSpec(.optional("archive", .string), result: [.optional("bundled", .string),
                                                 .optional("bundled_present", .boolean),
                                                 .required("installed", .string),
                                                 .required("installed_path", .string),
                                                 .required("installed_present", .boolean),
                                                 .optional("matches", .boolean),
                                                 .optional("update_available", .boolean)])
        case .displayBrightness: MethodSpec(.optional("value", .number), result: [.required("auto", .any), .required("value", .number)])
        case .displayRotation: MethodSpec(.optional("orientation", .string), result: [.optional("accelerometer", .any),
                                                   .required("degrees", .integer),
                                                   .required("device_orientation", .integer),
                                                   .required("locked", .boolean),
                                                   .required("name", .string),
                                                   .optional("requested", .any)])
        case .displayOrientation: MethodSpec(result: [.required("degrees", .any),
                                                      .optional("fold_angle", .number),
                                                      .optional("screen_off", .boolean),
                                                      .required("source", .string)])
        case .displayPosture:
            MethodSpec(.optional("position", .any),
                       .optional("duration", .number),
                       .optional("profile", .string),
                       .optional("hinge", .any),
                       .optional("orientation", .any),
                       .optional("tabletop", .integer),
                       .optional("angle", .number), result: [.required("angle", .number),
                                .required("hinge", .integer),
                                .required("hinge_hid", .any),
                                .required("orientation", .integer),
                                .required("source", .string),
                                .optional("sweep", .object),
                                .required("tabletop", .any)])
        case .displayPose: MethodSpec(result: [.required("available", .boolean),
                                               .optional("device_orientation", .any),
                                               .optional("hinge", .any),
                                               .optional("orientation", .any),
                                               .optional("reason", .string),
                                               .optional("tabletop", .any)])
        case .displayRotationLock: MethodSpec(.required("locked", .boolean), result: [.required("degrees", .integer),
                                                       .required("device_orientation", .integer),
                                                       .required("locked", .boolean),
                                                       .required("name", .string)])
        case .displayAutoLock: MethodSpec(result: [.required("auto_lock_seconds", .any), .required("lock_screen_minimum_seconds", .any), .required("never", .any)])
        case .displayAutoLockSet: MethodSpec(.required("seconds", .integer), result: [.required("auto_lock_seconds", .any),
                                                      .required("lock_screen_minimum_seconds", .any),
                                                      .required("never", .any),
                                                      .required("requested_auto_lock_seconds", .integer)])
        case .screenUnlock: MethodSpec(.optional("passcode", .string), .optional("timeout", .number), result: [.required("locked", .any),
                                                .required("screen_off", .any),
                                                .required("was_locked", .boolean),
                                                .required("was_screen_off", .boolean)])
        case .audioVolume: MethodSpec(.optional("value", .number), .optional("category", .string), result: [.required("category", .string), .required("volume", .number)])
        case .audioState: MethodSpec(result: [.optional("active_category", .string),
                                              .optional("active_muted", .boolean),
                                              .optional("active_volume", .number),
                                              .optional("error", .string)])
        case .networkCapture:
            MethodSpec(.optional("seconds", .number),
                       .optional("interface", .string),
                       .optional("filter", .string), result: [.optional("bytes", .any), .optional("error", .string), .required("file_bytes", .integer), .optional("filter", .any), .optional("interface", .any), .optional("link_type", .string), .optional("packets", .integer), .optional("path", .any), .required("seconds", .any), .optional("summary", .array)])
        case .securitySslKillswitch: MethodSpec(result: [.required("present", .boolean)])
        case .diagnosticsSelfTest: MethodSpec(result: [.required("complete", .boolean),
                                                       .required("environment", .object),
                                                       .required("failed", .integer),
                                                       .required("not_tested", .array),
                                                       .required("passed", .integer),
                                                       .required("skipped", .integer),
                                                       .required("status", .integer),
                                                       .required("tests", .array)])
        case .notifyPost: MethodSpec(.required("name", .string), .optional("state", .any), result: [
                                         .required("delivered", .boolean),
                                         .required("name", .string),
                                         .required("posted", .boolean),
                                         .optional("state", .integer)])
        case .notifyState: MethodSpec(.required("name", .string), result: [.required("name", .string), .required("state", .integer)])
        }
    }
}

// MARK: - Device, Display, Audio, Network

extension GuestAPI {
    private static let rotationLock = NSLock()

    static func executeDevice(_ m: DeviceMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .deviceInfo:
            var info = try collectDeviceSnapshot()
            info["jailbreak"] = jailbreakInfo()
            info["network"] = networkInfo()
            info["screen"] = screenInfo()
            info["rotation"] = rotationInfo()
            info["brightness"] = brightnessState()
            info["volume"] = volume()
            info["low_power_mode"] = (try? lowPowerMode()) ?? [:]
            info["developer_mode"] = GuestDeveloperModeSnapshot.shared.current()
            info["agent"] = ["binary_hash": binaryHash, "pid": getpid()]
            info["device_name"] = deviceNameInfo()
            return info
        case .deviceNetwork:
            return networkInfo()
        case .networkIpv4Get:
            return try networkIPv4(interface: optionalString(params, "interface") ?? "en0", set: nil)
        case .networkIpv4Set:
            return try networkIPv4(interface: optionalString(params, "interface") ?? "en0", set: params)
        case .networkResolve:
            let port = (params["port"] as? NSNumber).map(\.intValue)
            let family: Int32 = switch optionalString(params, "family") {
            case "ipv4": AF_INET
            case "ipv6": AF_INET6
            default: AF_UNSPEC
            }
            return try resolveHost(
                string(params, "host"), family: family, port: port,
                firstOnly: params["first_only"] as? Bool ?? false,
                timeout: number(params, "timeout_ms", default: 5000) / 1000,
            )
        case .networkStaticNamesGet:
            return GuestStaticNames.shared.describe()
        case .networkStaticNamesSet:
            return try GuestStaticNames.shared.set(params["entries"] as? [[String: Any]] ?? [])
        case .networkHostnameGet:
            return try networkHostName(set: nil)
        case .networkHostnameSet:
            // An absent or null name puts back the one vphoned replaced.
            return try networkHostName(set: .some(params["local_host_name"] as? String))
        case .deviceNameGet:
            return deviceNameState()
        case .deviceNameSet:
            // An absent or null name gives the guest its own back.
            let name = params["name"].flatMap { $0 is NSNull ? nil : $0 }
            guard name == nil || name is String else {
                throw GuestAPIError.invalidRequest("name must be a string or null")
            }
            return try setDeviceName(name as? String)
        case .deviceIoreg:
            return try ioregistry(plane: optionalString(params, "plane") ?? "IOService")
        case .deviceInputDevices:
            return vp_hid_input_devices()
        case .deviceDisplays:
            return ["displays": vp_display_probe()]
        case .displayModes:
            return vp_display_modes()
        case .displayExternalStatus:
            return vp_external_display_status()
        case .displayExternalDiagnostics:
            return vp_external_display_diagnostics()
        case .displayExternalConfigure:
            guard let enabled = params["enabled"] as? Bool else {
                throw GuestAPIError.invalidRequest("enabled must be a boolean")
            }
            let width = params["width"] as? Int ?? 1920
            let height = params["height"] as? Int ?? 1080
            let result = vp_external_display_configure(enabled, width, height)
            guard result["ok"] as? Bool == true else {
                throw GuestAPIError.operationFailed(result["error"] as? String ?? "External display configuration failed")
            }
            return result
        case .displayExternalFrame:
            var error: NSString?
            guard let data = vp_external_display_frame(&error) else {
                throw GuestAPIError.operationFailed(error as String? ?? "External display capture failed")
            }
            return ["mime_type": "image/jpeg", "data": data.base64EncodedString()]
        case .deviceEnvironment:
            return try environmentReport()
        case .deviceBasebin:
            return try compareBaseBin(bundled: optionalString(params, "archive"))
        case .displayBrightness:
            if params["value"] != nil {
                try setBrightness(requiredNumber(params, "value"))
            }
            return brightnessState()
        case .displayRotation:
            rotationLock.lock()
            defer { rotationLock.unlock() }
            if let orientation = optionalString(params, "orientation"), vp_hinge_get()["enabled"] as? Bool == true {
                return try setFoldableRotation(orientation)
            }
            if let orientation = optionalString(params, "orientation") {
                // Preserve the physical pose across SpringBoard relaunches.
                // CoreMotion's app pose provider cannot feed this HID sink.
                let accelerometer = vp_accelerometer_get()
                let previousPose = (accelerometer["degrees"] as? NSNumber).map { String($0.intValue) }
                let publishesPose = accelerometer["provider_running"] as? Bool == true
                let previousInterface = interfaceRotationDegrees()
                if publishesPose {
                    guard vp_accelerometer_set_orientation(orientation) else {
                        throw GuestAPIError.operationFailed("Could not publish the accelerometer orientation")
                    }
                }
                do {
                    return try setRotation(orientation)
                } catch {
                    // A refused rotation leaves the guest as it was. The pose
                    // is persisted, and a refused request still turns iPadOS's
                    // pointer: with the screen off, an upside-down request
                    // left the interface portrait and the pointer upside down,
                    // so the mouse ran backwards. Asking again for the
                    // interface's own orientation turns the pointer back.
                    if publishesPose, let previousPose {
                        _ = vp_accelerometer_set_orientation(previousPose)
                    }
                    if let previousInterface {
                        _ = try? setRotation(String(previousInterface))
                    }
                    throw error
                }
            }
            var rotation = rotationInfo()
            rotation["accelerometer"] = vp_accelerometer_get()
            return rotation
        case .displayOrientation:
            return interfaceOrientation()
        case .displayPosture:
            return try setDevicePose(params)
        case .displayPose:
            return vp_device_pose_get()
        case .displayRotationLock:
            guard let locked = params["locked"] as? Bool else {
                throw GuestAPIError.invalidRequest("locked must be true or false")
            }
            return try setRotationLock(locked)
        case .displayAutoLock:
            return GuestLockScreenIdle.describe()
        case .displayAutoLockSet:
            guard let seconds = (params["seconds"] as? NSNumber)?.intValue else {
                throw GuestAPIError.invalidRequest("seconds must be an integer")
            }
            return try GuestLockScreenIdle.setAutoLockSeconds(seconds)
        case .screenUnlock:
            return try GuestScreenUnlock.unlock(
                passcode: optionalString(params, "passcode"),
                timeout: number(params, "timeout", default: 10),
            )
        case .audioVolume:
            let category = optionalString(params, "category") ?? "Audio/Video"
            if params["value"] != nil {
                return try setVolume(requiredNumber(params, "value"), category: category)
            }
            return ["volume": volume(category), "category": category]
        case .audioState:
            return try audioState()
        case .networkCapture:
            let seconds = number(params, "seconds", default: 5)
            return try capturePackets(
                seconds: seconds,
                interface: optionalString(params, "interface") ?? "en0",
                filter: optionalString(params, "filter"),
            )
        case .securitySslKillswitch:
            return sslKillswitchStatus()
        case .diagnosticsSelfTest:
            return try runSelfTests()
        case .notifyPost:
            let state = try params["state"].map(notificationState)
            return try postDarwinNotification(string(params, "name"), state: state)
        case .notifyState:
            return try darwinNotificationState(string(params, "name"))
        }
    }

    /// Reads SpringBoard directly; the UIScreen path can abort before display registration.
    /// A foldable guest adds the angle its last fold settled at, so a host
    /// polling the orientation also follows folds it did not ask for (Xcode's
    /// DeviceHub).
    private static func interfaceOrientation() -> [String: Any] {
        var reply: [String: Any] = [
            "degrees": interfaceRotationDegrees().map { $0 as Any } ?? NSNull(),
            "source": "springboard",
        ]
        if let angle = settledFoldAngle() {
            reply["fold_angle"] = angle
            // The window covers the panel while it is off: coming on, it
            // shows its last frame from before until the guest draws again.
            // The always-on Lock Screen keeps the panel on, so it stays shown.
            reply["screen_off"] = GuestScreenUnlock.panelIsDark
        }
        return reply
    }

    /// The angle the virtual hinge holds, which every fold leaves it at; nil
    /// on a guest whose hinge was never configured.
    private static func settledFoldAngle() -> Double? {
        let hinge = vp_hinge_get()
        guard hinge["enabled"] as? Bool == true else { return nil }
        return (hinge["angle"] as? NSNumber)?.doubleValue
    }

    // MARK: Device pose

    /// CoreMotion's magic-pose values, by name. SpringBoard derives the hinge
    /// angle from the hinge state with a five-entry table, so the hinge stops
    /// at "open" (open, ambiguous); "transitioning" is not accepted.
    static let poseHingeStates = ["ambiguous": 0, "closed": 1, "partially-open": 2, "open-flat": 3, "open": 4]
    static let poseOrientations = [
        "ambiguous": 0, "portrait": 1, "upside-down": 2, "landscape-left": 3,
        "landscape-right": 4, "face-up": 5, "face-down": 6,
    ]

    /// The angle a hinge state names, as Apple's screen states have it:
    /// partially open is book (~100°). SpringBoard's own table for the pose
    /// override says 90°, but with CoreMotion's relay it reads the hinge.
    static let poseHingeAngles: [Double] = [0, 0, 100, 180, 180]

    /// Apple's screen-state positions, from suiatool's help text shipped in
    /// SpringBoardFoundation: closed, book (~100°) and open (a fraction of
    /// the 180° range, or a name).
    static let posePositions: [String: Double] = ["closed": 0, "book": 100, "open": 180]

    /// Set a foldable guest's pose the way Apple's Duo tooling does. On a
    /// guest whose CoreMotion has the foldable's capabilities the virtual
    /// hinge's host controls carry the angle and orientation, locationd
    /// relays them into CoreMotion, and SpringBoard reads its pose from there
    /// as on a device; elsewhere SpringBoard's test-automation override sets
    /// the pose beside the hinge. The official model is three screen states —
    /// `position` `closed`, `book` (~100°) or `open`, or a fraction 0–1 of
    /// the hinge's 180° — changed by a sweep from the current angle, which
    /// SpringBoard's display tool service runs (`duration` seconds; default
    /// the per-direction hand-fold time, opening faster than closing; 0 an
    /// instant swap; `profile` `continuous` or `fade`, default SpringBoard's
    /// own). The older `hinge` names still work and set the pose at once.
    private static func setDevicePose(_ params: [String: Any]) throws -> [String: Any] {
        func value(_ key: String, names: [String: Int], range: ClosedRange<Int>, default fallback: Int?) throws -> Int {
            if let name = params[key] as? String {
                guard let value = names[name.lowercased()] else {
                    throw GuestAPIError.invalidRequest("\(key) must be one of \(names.keys.sorted().joined(separator: ", "))")
                }
                return value
            }
            if let number = params[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                guard range.contains(number.intValue), Double(number.intValue) == number.doubleValue else {
                    throw GuestAPIError.invalidRequest("\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)")
                }
                return number.intValue
            }
            guard params[key] == nil, let fallback else { throw GuestAPIError.invalidRequest("\(key) is required") }
            return fallback
        }

        var angle: Double?
        var sweep = false
        var durationMs = -1.0
        var profile: String?
        if let position = params["position"] {
            let target: Double
            switch position {
            case let name as String:
                guard let named = Self.posePositions[name.lowercased()] else {
                    throw GuestAPIError.invalidRequest("position must be closed, book, open, or a fraction in 0...1")
                }
                target = named
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                let fraction = number.doubleValue
                guard fraction.isFinite, 0 ... 1 ~= fraction else {
                    throw GuestAPIError.invalidRequest("position must be closed, book, open, or a fraction in 0...1")
                }
                target = fraction * 180
            default:
                throw GuestAPIError.invalidRequest("position must be closed, book, open, or a fraction in 0...1")
            }
            angle = target
            sweep = true
            if let requested = params["duration"] as? NSNumber, CFGetTypeID(requested) != CFBooleanGetTypeID() {
                let seconds = requested.doubleValue
                guard seconds.isFinite, 0 ... 10 ~= seconds else {
                    throw GuestAPIError.invalidRequest("duration must be a number of seconds in 0...10")
                }
                durationMs = seconds * 1000
            }
            if let name = params["profile"] as? String {
                profile = name.lowercased()
                guard profile == "continuous" || profile == "fade" else {
                    throw GuestAPIError.invalidRequest("profile must be continuous or fade")
                }
            }
        }

        let hinge = try value("hinge", names: poseHingeStates, range: 0 ... 4, default: angle.map(hingeState(for:)))
        let orientation = try value("orientation", names: poseOrientations, range: 0 ... 6, default: 1)
        let tabletop = try value("tabletop", names: [:], range: 0 ... 10, default: 0)
        if angle == nil {
            angle = Self.poseHingeAngles[hinge]
            if let requested = params["angle"] as? NSNumber, CFGetTypeID(requested) != CFBooleanGetTypeID() {
                guard requested.doubleValue.isFinite, 0 ... 180 ~= requested.doubleValue else {
                    throw GuestAPIError.invalidRequest("angle must be a number in 0...180")
                }
                angle = requested.doubleValue
            }
        }
        let relayed = vp_core_motion_hinge()
        if relayed, orientation == 2 {
            throw GuestAPIError.invalidRequest("the host controls have no upside-down orientation")
        }
        foldLock.lock()
        defer { foldLock.unlock() }
        GuestFoldPose.cancelStartupRestore()
        var springBoardSwept = false
        defer { GuestFoldPose.finishExplicitRequest(settledHinge: springBoardSwept ? Int32(hinge) : nil) }
        let published: Bool
        if relayed {
            if let current = vp_hinge_get()["angle"] as? Double, hingeState(for: current) == 1, hingeState(for: angle!) != 1 {
                // Opening a closed device wakes it; the hinge sensor's own wake
                // flag does that on hardware, and the host controls cannot set
                // it. SpringBoard's pose provider publishes a pose in motion only
                // on display frames, so with the cover asleep the new angle would
                // sit unpublished until the next wake. The screen is lit before
                // the sweep starts.
                GuestScreenUnlock.wakeDisplay()
            }
            // With the relay, the hinge is the pose.
            published = sweep
                ? vp_hinge_sweep(angle!, durationMs, profile == "fade" ? 1 : 0, Int32(orientation))
                : vp_hinge_set(angle!, Int32(orientation))
            guard published else {
                throw GuestAPIError.operationFailed("The virtual hinge did not take the pose")
            }
        } else {
            // A sweep is SpringBoard's own, as Apple's tooling runs it: the
            // display tool service moves SpringBoard's hinge pose and swaps
            // displays on the way, keeping the device orientation unless one
            // was asked for, and replies once the swap is done. The override is
            // then left alone: it reaches SpringBoard even under the sweep's
            // test lock and stands for 0, 90 or 180 degrees only, so book (100)
            // would slide back to 90 and start a transition toward the cover.
            // SpringBoard applies the next override against its current pose,
            // so a later one still lands. The virtual hinge takes the end
            // angle. Without the service the virtual hinge sweeps and the
            // override jumps, as before.
            if sweep {
                springBoardSwept = try springBoardFold(
                    to: angle!, seconds: durationMs < 0 ? -1 : durationMs / 1000,
                    orientation: params["orientation"] == nil ? 0 : Int32(orientation),
                    profile: profile == "fade" ? 1 : profile == "continuous" ? 2 : 0,
                )
            }
            guard springBoardSwept || vp_device_pose_set(Int32(orientation), Int32(hinge), Int32(tabletop)) else {
                throw GuestAPIError.operationFailed("SpringBoardServices has no device pose override on this guest")
            }
            if params["orientation"] != nil { vp_device_orientation_publish(Int32(orientation)) }
            // The pose has landed; the hinge half is published beside it, and
            // its absence (no virtual hinge service on this guest) does not
            // undo the pose.
            published = sweep && !springBoardSwept
                ? vp_hinge_sweep(angle!, durationMs, profile == "fade" ? 1 : 0, 0)
                : vp_hinge_set(angle!, 0)
        }
        var hingeHID = vp_hinge_get()
        hingeHID["applied"] = published
        var reply: [String: Any] = [
            "hinge": hinge, "orientation": orientation, "tabletop": relayed ? NSNull() : tabletop,
            "angle": angle!, "hinge_hid": hingeHID, "source": relayed ? "coremotion" : "test-automation",
        ]
        if sweep {
            reply["sweep"] = [
                "duration_ms": durationMs,
                "profile": profile ?? (springBoardSwept ? "springboard" : "continuous"),
                "completed": springBoardSwept,
            ]
        }
        return reply
    }

    /// One posture request at a time: SpringBoard refuses a swap while another
    /// is running, and the next request reads the hinge this one leaves.
    private static let foldLock = NSLock()

    /// Fold through SpringBoard's display tool service, waiting for it to
    /// finish. True once SpringBoard ran the fold, false without the service
    /// or a reply (the caller falls back to the override). SpringBoard answers
    /// a swap it refuses (another one is running) at once and the same way as
    /// a finished one, so a reply faster than any sweep that had to move is a
    /// refusal, retried until SpringBoard is idle. The virtual hinge holds the
    /// angle the last fold ended at, and takes the target as the fold starts:
    /// DeviceHub reads it (through dtdeviceinfod) while its own model animates
    /// to the target, and an old angle lingering through the sweep sent its
    /// slider back there, folding the guest again. A fold that does not run
    /// puts the old angle back.
    private static func springBoardFold(to angle: Double, seconds: Double, orientation: Int32, profile: Int32) throws -> Bool {
        let current = (vp_hinge_get()["angle"] as? NSNumber)?.doubleValue
        let moves = current.map { abs($0 - angle) >= 1 } ?? true
        var ran = false
        if moves { _ = vp_hinge_set(angle, 0) }
        defer { if moves, !ran, let current { _ = vp_hinge_set(current, 0) } }
        let deadline = Date().addingTimeInterval(10 + max(seconds, 0))
        while true {
            let started = Date()
            switch vp_display_swap(angle / 180, seconds, orientation, profile, max(1, deadline.timeIntervalSinceNow)) {
            case -1, 0:
                return false
            default:
                ran = !moves || seconds == 0 || Date().timeIntervalSince(started) >= 0.3
                if ran { return true }
            }
            guard Date() < deadline else {
                throw GuestAPIError.operationFailed("SpringBoard kept refusing the fold; another fold is still running")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// A foldable guest turns with SpringBoard's device pose: each panel's
    /// traits pipeline reads its own device orientation from the pose, so
    /// neither the accelerometer nor the AssistiveTouch rotation icli drives
    /// turns it. The rotation sets the pose orientation that gives the lit
    /// panel the requested interface orientation — the inner panel is mounted
    /// a quarter turn from the cover — and reads the interface back.
    private static func setFoldableRotation(_ spec: String) throws -> [String: Any] {
        let degreesByName = [
            "0": 0, "portrait": 0, "90": 90, "landscape-left": 90, "left": 90, "180": 180, "upside-down": 180,
            "portrait-upside-down": 180, "270": 270, "landscape-right": 270, "right": 270,
        ]
        guard let degrees = degreesByName[spec.lowercased()] else {
            throw GuestAPIError.invalidRequest("unknown rotation: \(spec)")
        }
        let pose = vp_device_pose_get()
        guard pose["available"] as? Bool == true, let readHinge = (pose["hinge"] as? NSNumber)?.int32Value,
              let tabletop = (pose["tabletop"] as? NSNumber)?.int32Value
        else { throw GuestAPIError.operationFailed("SpringBoard's device pose is unavailable") }
        // The pose readback does not follow SpringBoard's own folds; the
        // virtual hinge holds where the last one ended.
        let hinge = settledFoldAngle().map { Int32(hingeState(for: $0)) } ?? readHinge
        // Pose orientations (poseOrientations) by interface degrees, measured
        // on the cover (hinge closed) and on the inner panel (open).
        let cover: [Int: Int32] = [0: 1, 90: 4, 180: 2, 270: 3]
        let inner: [Int: Int32] = [0: 3, 90: 1, 180: 4, 270: 2]
        let deviceOrientation = (hinge == 1 ? cover : inner)[degrees]!
        // Partially open the override stands for 90° and slides the fold
        // toward the cover; CoreMotion's relay reads the hinge instead.
        guard hinge != 2 || vp_core_motion_hinge() else {
            throw GuestAPIError.operationFailed("A partially open fold does not turn through the device pose.")
        }
        GuestFoldPose.cancelStartupRestore()
        defer { GuestFoldPose.finishExplicitRequest() }
        guard try turn(to: deviceOrientation, hinge: hinge, tabletop: tabletop, reaching: { $0 == degrees }) else {
            throw GuestAPIError.operationFailed("The device did not apply the requested rotation.")
        }
        var info = rotationInfo()
        info["requested"] = degrees
        return info
    }

    /// A fold Xcode's DeviceHub asked for (GuestDeviceHubControl): the sweep
    /// `display.posture` runs for a position, to `angle` degrees. With
    /// CoreMotion's relay the hinge follows DeviceHub's values instead.
    static func foldFromDeviceHub(angle: Double) throws {
        _ = try setDevicePose(["position": NSNumber(value: min(max(angle, 0), 180) / 180)])
    }

    /// A device orientation DeviceHub's picker chose (1 portrait … 6 face
    /// down): the pose override takes it with the hinge where it is. The
    /// orientation DeviceHub reads back is published only once the interface
    /// has turned, so a refused turn leaves its model where the guest is: an
    /// iPhone19,4 scene refuses programmatic orientation (see
    /// `display.rotation`), and in book the override, which means 90°, slides
    /// the fold toward the cover, so book is left alone. With CoreMotion's
    /// relay the host controls carry the orientation at any fold.
    static func orientFromDeviceHub(_ deviceOrientation: Int32) throws {
        foldLock.lock()
        defer { foldLock.unlock() }
        GuestFoldPose.cancelStartupRestore()
        defer { GuestFoldPose.finishExplicitRequest() }
        let hinge = settledFoldAngle().map { Int32(hingeState(for: $0)) } ??
            (vp_device_pose_get()["hinge"] as? NSNumber)?.int32Value ?? 1
        guard hinge != 2 || vp_core_motion_hinge() else {
            throw GuestAPIError.operationFailed("a partially open fold does not turn through the pose override")
        }
        let before = interfaceRotationDegrees()
        guard try turn(to: deviceOrientation, hinge: hinge, tabletop: 0, reaching: { $0 != before }) else {
            throw GuestAPIError.operationFailed("SpringBoard did not turn the interface")
        }
    }

    /// Set the device orientation and wait up to 3 s for the interface to
    /// reach `turned`. With CoreMotion's relay the host controls carry it
    /// with the angle the hinge holds, and CoreMotion turns it into each
    /// panel's. Otherwise the pose override takes it; only once the interface
    /// has turned is it published (DeviceHub's stand-in reads it), and a
    /// refused one is put back, since SpringBoard keeps it and later folds
    /// carry it.
    private static func turn(to deviceOrientation: Int32, hinge: Int32, tabletop: Int32,
                             reaching turned: (Int?) -> Bool) throws -> Bool {
        let relayed = vp_core_motion_hinge()
        if relayed, deviceOrientation == 2 {
            throw GuestAPIError.invalidRequest("the host controls have no upside-down orientation")
        }
        let previous = (vp_device_pose_get()["device_orientation"] as? NSNumber)?.int32Value
        if relayed {
            guard let angle = settledFoldAngle(), vp_hinge_set(angle, deviceOrientation) else {
                throw GuestAPIError.operationFailed("The virtual hinge did not take the orientation")
            }
        } else {
            guard vp_device_pose_set(deviceOrientation, hinge, tabletop) else {
                throw GuestAPIError.operationFailed("SpringBoard refused the device pose")
            }
        }
        for _ in 0 ..< 30 where !turned(interfaceRotationDegrees()) {
            usleep(100_000)
        }
        guard turned(interfaceRotationDegrees()) else {
            if !relayed, let previous, (1 ... 6).contains(previous), previous != deviceOrientation {
                _ = vp_device_pose_set(previous, hinge, tabletop)
            }
            return false
        }
        if !relayed { vp_device_orientation_publish(deviceOrientation) }
        return true
    }

    /// The hinge state a settled angle reports: closed under 5°, open flat
    /// from 170°, partially open between — the bands Apple's recorded Duo
    /// samples hold.
    static func hingeState(for angle: Double) -> Int {
        if angle < 5 { return 1 }
        if angle >= 170 { return 3 }
        return 2
    }

    private static func brightnessState() -> [String: Any] {
        ["value": brightness(), "auto": autoBrightness().map { $0 as Any } ?? NSNull()]
    }

    /// A notify(3) state is a full UInt64, beyond what a JSON double holds
    /// exactly, so a decimal string is accepted as well as a number. A JSON
    /// boolean also decodes as NSNumber and is refused.
    private static func notificationState(_ value: Any) throws -> UInt64 {
        let number = (value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 }
        let text = (value as? String) ?? number?.stringValue
        guard let text, let state = UInt64(text) else {
            throw GuestAPIError.invalidRequest("state must be an unsigned 64-bit integer")
        }
        return state
    }
}

// MARK: - Network configuration

extension GuestAPI {
    /// Read, or with `set` write, the interface's IPv4 settings in configd's
    /// network preferences. The host calls `set` after every connect to hold
    /// the guest to the address in its manifest.
    static func networkIPv4(interface: String, set params: [String: Any]?) throws -> [String: Any] {
        var error: NSString?
        let result = if let params {
            vp_network_ipv4_set(interface, params, &error)
        } else {
            vp_network_ipv4_get(interface, &error)
        }
        guard let result = result as? [String: Any] else {
            throw GuestAPIError.operationFailed(error.map(String.init) ?? "network configuration failed")
        }
        return result
    }

    /// Read the guest's mDNS name, or with `set` change it (`.some(nil)` puts
    /// back the one vphoned replaced).
    static func networkHostName(set name: String??) throws -> [String: Any] {
        var error: NSString?
        let result = if let name {
            vp_network_hostname_set(name, &error)
        } else {
            vp_network_hostname_get(&error)
        }
        guard let result = result as? [String: Any] else {
            throw GuestAPIError.operationFailed(error.map(String.init) ?? "host name change failed")
        }
        return result
    }
}

// MARK: - Device name

/// The device name the host pins: what Xcode, devicectl and Finder show.
/// `libdevicename.dylib` in configd and lockdownd reads it from
/// `deviceNameConfigPath` (see `Research/Guest/device_name_pinning.md`):
/// configd publishes it as `Setup:/System`'s ComputerName and lockdownd refuses
/// every rename. The guest's own name stays in preferences.plist.
///
/// The file outlives a reboot, so configd's first publication at boot already
/// carries the name. A change applies at once: both daemons check the file on
/// every decision, and applying the preferences unchanged makes configd's
/// preferences monitor publish again.
extension GuestAPI {
    /// Must match `VP_DEVICE_NAME_CONFIG_PATH` and `VP_DEVICE_NAME_CONFIG_KEY`
    /// in `VPhoneGuestComponents/DeviceName/DeviceNamePolicy.h`.
    static let deviceNameConfigPath = "/var/db/vphone/devicename.plist"
    static let deviceNameConfigKey = "DeviceName"
    /// What lockdownd posts after a rename; lockdown clients read the name again.
    static let deviceNameChangedNotification = "com.apple.mobile.lockdown.device_name_changed"

    /// `{name}`: the pinned name, or null when the guest shows its own.
    static func deviceNameState() -> [String: Any] {
        ["name": storedDeviceName() ?? NSNull()]
    }

    /// Pin `name`, or with nil give the guest its own back. Returns the state
    /// plus `changed` and `reboot_required`: lockdown readers (Finder,
    /// `ideviceinfo`, `idevicename`) follow a change at once, but CoreDevice (Xcode,
    /// `devicectl`) reads the name once per handshake and the DHCP lease keeps
    /// the host name it was requested with, so both show the new name only
    /// after the guest restarts. A clone of a template boots with the
    /// template's pin until `vphone-vm` connects and sets its own.
    static func setDeviceName(_ name: String?) throws -> [String: Any] {
        if let name {
            try validateDeviceName(name)
        }
        let changed = storedDeviceName() != name
        if changed {
            try writeDeviceName(name)
            guard storedDeviceName() == name else {
                throw GuestAPIError.operationFailed("\(deviceNameConfigPath) did not read back as written")
            }
            var error: NSString?
            guard vp_preferences_apply(&error) else {
                throw GuestAPIError.operationFailed(
                    "The name is stored but configd was not asked to publish it: \(error.map(String.init) ?? "apply failed")",
                )
            }
            _ = try? postDarwinNotification(deviceNameChangedNotification, state: nil)
        }
        var state = deviceNameState()
        state["changed"] = changed
        state["reboot_required"] = changed
        return state
    }

    /// For `device.info`: the pinned name, and the guest's own ComputerName in
    /// configd's preferences, which a clone inherits from its template. Two
    /// small file reads.
    static func deviceNameInfo() -> [String: Any] {
        let path = "/private/var/preferences/SystemConfiguration/preferences.plist"
        let preferences = FileManager.default.contents(atPath: path).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let system = (preferences?["System"] as? [String: Any])?["System"] as? [String: Any]
        return [
            "name": storedDeviceName() ?? NSNull(),
            "own_name": system?["ComputerName"] as? String ?? NSNull(),
        ]
    }

    /// `GuestDeviceNameRule`: not blank, at most 255 UTF-8 bytes, no control
    /// character.
    private static func validateDeviceName(_ name: String) throws {
        if let problem = GuestDeviceNameRule.problem(name) {
            throw GuestAPIError.invalidRequest(problem)
        }
    }

    private static func storedDeviceName() -> String? {
        guard let data = FileManager.default.contents(atPath: deviceNameConfigPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist[deviceNameConfigKey] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    /// Replaces the file in one rename, which is what the hook's stamp check
    /// expects, or removes it.
    private static func writeDeviceName(_ name: String?) throws {
        guard let name else {
            if unlink(deviceNameConfigPath) != 0, errno != ENOENT {
                throw GuestAPIError.operationFailed("Could not remove \(deviceNameConfigPath): \(String(cString: strerror(errno)))")
            }
            return
        }
        let directory = (deviceNameConfigPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755],
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: [deviceNameConfigKey: name], format: .binary, options: 0,
            )
            try data.write(to: URL(fileURLWithPath: deviceNameConfigPath), options: .atomic)
        } catch {
            throw GuestAPIError.operationFailed("Could not write \(deviceNameConfigPath): \(error.localizedDescription)")
        }
        // World-readable: the hooks only ever read it.
        chmod(deviceNameConfigPath, 0o644)
    }
}

// MARK: - Name resolution

extension GuestAPI {
    /// One `getaddrinfo` answer, kept as the raw socket address for the
    /// connect test.
    private struct ResolvedAddress {
        let text: String
        let family: Int32
        let storage: Data
    }

    /// The results of a `getaddrinfo` that ran on another thread, which
    /// `resolveHost` stops waiting for after its timeout.
    private final class ResolutionResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (status: Int32, addresses: [ResolvedAddress])?

        func set(_ status: Int32, _ addresses: [ResolvedAddress]) {
            lock.withLock { value = (status, addresses) }
        }

        func get() -> (status: Int32, addresses: [ResolvedAddress])? {
            lock.withLock { value }
        }
    }

    /// What the guest's own resolver makes of `host`: every address
    /// `getaddrinfo` returns, in its order, and how long it took. With `port`,
    /// each address is also connected to (two seconds each; only the first with
    /// `first_only`, as a client that does not fall back would), reporting the
    /// local address the guest used, which names the interface it went out of.
    /// For diagnosing names that resolve slowly, or to an address the guest
    /// cannot reach.
    static func resolveHost(_ host: String, family: Int32, port: Int?, firstOnly: Bool, timeout: Double) throws -> [String: Any] {
        let started = Date()
        let result = ResolutionResult()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_family = family
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, port.map(String.init), &hints, &list)
            var addresses: [ResolvedAddress] = []
            var entry = list
            while let info = entry {
                defer { entry = info.pointee.ai_next }
                guard let address = info.pointee.ai_addr else { continue }
                addresses.append(ResolvedAddress(
                    text: numericHost(address, length: info.pointee.ai_addrlen),
                    family: info.pointee.ai_family,
                    storage: Data(bytes: address, count: Int(info.pointee.ai_addrlen)),
                ))
            }
            if let list {
                freeaddrinfo(list)
            }
            result.set(status, addresses)
            finished.signal()
        }

        let elapsed = { Int(Date().timeIntervalSince(started) * 1000) }
        guard finished.wait(timeout: .now() + max(timeout, 0.1)) == .success, let resolved = result.get() else {
            return ["host": host, "status": "timeout", "elapsed_ms": elapsed()]
        }
        var reply: [String: Any] = ["host": host, "elapsed_ms": elapsed()]
        guard resolved.status == 0 else {
            reply["status"] = "error"
            reply["error"] = String(cString: gai_strerror(resolved.status))
            return reply
        }
        reply["status"] = "resolved"
        reply["addresses"] = resolved.addresses.enumerated().map { index, address -> [String: Any] in
            var item: [String: Any] = [
                "address": address.text,
                "family": address.family == AF_INET6 ? "ipv6" : "ipv4",
            ]
            if port != nil, !firstOnly || index == 0 {
                item.merge(connectTest(address), uniquingKeysWith: { $1 })
            }
            return item
        }
        return reply
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "?" }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A non-blocking connect with a two-second limit.
    private static func connectTest(_ address: ResolvedAddress) -> [String: Any] {
        let started = Date()
        let descriptor = socket(address.family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return ["connect": "error", "connect_error": String(cString: strerror(errno))] }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        let result = address.storage.withUnsafeBytes { raw in
            connect(descriptor, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        var outcome: [String: Any] = [:]
        if result == 0 || errno == EINPROGRESS {
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            if poll(&poller, 1, 2000) == 1 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
                outcome["connect"] = error == 0 ? "connected" : "error"
                if error != 0 {
                    outcome["connect_error"] = String(cString: strerror(error))
                }
            } else {
                outcome["connect"] = "timeout"
            }
        } else {
            outcome["connect"] = "error"
            outcome["connect_error"] = String(cString: strerror(errno))
        }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        if named == 0 {
            outcome["local"] = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { numericHost($0, length: length) }
            }
        }
        outcome["connect_ms"] = Int(Date().timeIntervalSince(started) * 1000)
        return outcome
    }
}
