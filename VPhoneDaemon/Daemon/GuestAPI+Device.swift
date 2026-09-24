import Foundation
import IcliKit
import IcliSystem

// MARK: - Device, Display, Audio, Network

extension GuestAPI {
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
            return info
        case "device.network":
            return networkInfo()
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
            if let orientation = optionalString(params, "orientation") {
                return try setRotation(orientation)
            }
            return rotationInfo()
        case "display.rotation_lock":
            guard let locked = params["locked"] as? Bool else {
                throw GuestAPIError.invalidRequest("locked must be true or false")
            }
            return try setRotationLock(locked)
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
        default:
            return nil
        }
    }

    private static func brightnessState() -> [String: Any] {
        ["value": brightness(), "auto": autoBrightness().map { $0 as Any } ?? NSNull()]
    }
}
