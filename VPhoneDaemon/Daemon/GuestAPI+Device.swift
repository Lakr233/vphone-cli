import Foundation
import IcliKit
import IcliSystem
import VphonedNative

// MARK: - Device, Display, Audio, Network

extension GuestAPI {
    private static let rotationLock = NSLock()

    static func executeDevice(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "device.info":
            var info = try collectDeviceSnapshot()
            info["jailbreak"] = jailbreakInfo()
            info["network"] = networkInfo()
            info["screen"] = screenInfo()
            info["rotation"] = rotationInfo()
            info["brightness"] = brightnessState()
            info["volume"] = volume()
            info["low_power_mode"] = (try? lowPowerMode()) ?? [:]
            info["developer_mode"] = (try? developerModeStatus()) ?? [:]
            info["agent"] = ["binary_hash": binaryHash, "pid": getpid()]
            info["device_name"] = deviceNameInfo()
            return info
        case "device.network":
            return networkInfo()
        case "network.ipv4.get":
            return try networkIPv4(interface: optionalString(params, "interface") ?? "en0", set: nil)
        case "network.ipv4.set":
            return try networkIPv4(interface: optionalString(params, "interface") ?? "en0", set: params)
        case "network.resolve":
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
        case "network.static_names.get":
            return GuestStaticNames.shared.describe()
        case "network.static_names.set":
            return try GuestStaticNames.shared.set(params["entries"] as? [[String: Any]] ?? [])
        case "network.hostname.get":
            return try networkHostName(set: nil)
        case "network.hostname.set":
            // An absent or null name puts back the one vphoned replaced.
            return try networkHostName(set: .some(params["local_host_name"] as? String))
        case "device.name.get":
            return deviceNameState()
        case "device.name.set":
            // An absent or null name gives the guest its own back.
            let name = params["name"].flatMap { $0 is NSNull ? nil : $0 }
            guard name == nil || name is String else {
                throw GuestAPIError.invalidRequest("name must be a string or null")
            }
            return try setDeviceName(name as? String)
        case "device.ioreg":
            return try ioregistry(plane: optionalString(params, "plane") ?? "IOService")
        case "device.environment":
            return try environmentReport()
        case "device.basebin":
            return try compareBaseBin(bundled: optionalString(params, "archive"))
        case "display.brightness":
            if params["value"] != nil {
                try setBrightness(requiredNumber(params, "value"))
            }
            return brightnessState()
        case "display.rotation":
            rotationLock.lock()
            defer { rotationLock.unlock() }
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
        case "display.orientation":
            return interfaceOrientation()
        case "display.posture":
            return try setDevicePose(params)
        case "display.rotation_lock":
            guard let locked = params["locked"] as? Bool else {
                throw GuestAPIError.invalidRequest("locked must be true or false")
            }
            return try setRotationLock(locked)
        case "display.auto_lock":
            return GuestLockScreenIdle.describe()
        case "display.auto_lock.set":
            guard let seconds = (params["seconds"] as? NSNumber)?.intValue else {
                throw GuestAPIError.invalidRequest("seconds must be an integer")
            }
            return try GuestLockScreenIdle.setAutoLockSeconds(seconds)
        case "screen.unlock":
            return try GuestScreenUnlock.unlock(
                passcode: optionalString(params, "passcode"),
                timeout: number(params, "timeout", default: 10),
            )
        case "audio.volume":
            let category = optionalString(params, "category") ?? "Audio/Video"
            if params["value"] != nil {
                return try setVolume(requiredNumber(params, "value"), category: category)
            }
            return ["volume": volume(category), "category": category]
        case "audio.state":
            return try audioState()
        case "network.capture":
            let seconds = number(params, "seconds", default: 5)
            return try capturePackets(
                seconds: seconds,
                interface: optionalString(params, "interface") ?? "en0",
                filter: optionalString(params, "filter"),
            )
        case "security.ssl_killswitch":
            return sslKillswitchStatus()
        case "diagnostics.self_test":
            return try runSelfTests()
        case "notify.post":
            let state = try params["state"].map(notificationState)
            return try postDarwinNotification(string(params, "name"), state: state)
        case "notify.state":
            return try darwinNotificationState(string(params, "name"))
        default:
            return nil
        }
    }

    /// Reads SpringBoard directly; the UIScreen path can abort before display registration.
    private static func interfaceOrientation() -> [String: Any] {
        [
            "degrees": interfaceRotationDegrees().map { $0 as Any } ?? NSNull(),
            "source": "springboard",
        ]
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

    /// Set a foldable guest's pose through SpringBoard's test-automation
    /// override: `hinge` (a name or 0–4), `orientation` (a name or 0–6,
    /// default portrait) and `tabletop` (0–10, default 0, ambiguous).
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
        let hinge = try value("hinge", names: poseHingeStates, range: 0 ... 4, default: nil)
        let orientation = try value("orientation", names: poseOrientations, range: 0 ... 6, default: 1)
        let tabletop = try value("tabletop", names: [:], range: 0 ... 10, default: 0)
        guard vp_device_pose_set(Int32(orientation), Int32(hinge), Int32(tabletop)) else {
            throw GuestAPIError.operationFailed("SpringBoardServices has no device pose override on this guest")
        }
        return ["hinge": hinge, "orientation": orientation, "tabletop": tabletop]
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
