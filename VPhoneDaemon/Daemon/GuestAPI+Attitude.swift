import CoreFoundation
import Foundation
import VphonedNative

// MARK: - Device Attitude

enum AttitudeMethod: String, GuestMethod {
    case motionAttitudeGet = "motion.attitude.get"
    case motionAttitudeSet = "motion.attitude.set"
    case motionAttitudeClear = "motion.attitude.clear"

    var spec: MethodSpec {
        switch self {
        case .motionAttitudeGet: MethodSpec(summary: "Read the simulated device attitude (roll, pitch, yaw in degrees) and whether it is enabled.", result: [.required("enabled", .any),
                                                     .required("pitch", .any),
                                                     .required("provider_installed", .any),
                                                     .required("reference_frame", .string),
                                                     .required("roll", .any),
                                                     .required("units", .string),
                                                     .required("yaw", .any)])
        case .motionAttitudeSet: MethodSpec(.required("roll", .number, "Roll in degrees", min: -180, max: 180), .required("pitch", .number, "Pitch in degrees", min: -90, max: 90), .required("yaw", .number, "Yaw in degrees", min: -180, max: 180), .optional("enabled", .boolean, "Whether the simulated attitude is active", default: true), summary: "Set the simulated device attitude (roll, pitch, yaw in degrees) that motion sensors report.", result: [.required("enabled", .any),
                                                     .required("pitch", .any),
                                                     .required("provider_installed", .any),
                                                     .required("reference_frame", .string),
                                                     .required("roll", .any),
                                                     .required("units", .string),
                                                     .required("yaw", .any)])
        case .motionAttitudeClear: MethodSpec(summary: "Turn off the simulated device attitude and reset its angles to zero.", result: [.required("enabled", .any),
                                                       .required("pitch", .any),
                                                       .required("provider_installed", .any),
                                                       .required("reference_frame", .string),
                                                       .required("roll", .any),
                                                       .required("units", .string),
                                                       .required("yaw", .any)])
        }
    }
}

extension GuestAPI {
    private static let attitudeLock = NSLock()

    static func executeAttitude(_ m: AttitudeMethod, _ params: [String: Any]) throws -> [String: Any] {
        attitudeLock.lock()
        defer { attitudeLock.unlock() }
        if m != .motionAttitudeGet {
            var angles = [Double](repeating: 0, count: 3)
            var enabled = m == .motionAttitudeSet
            if m == .motionAttitudeSet {
                if let flag = params["enabled"] {
                    guard let number = flag as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        throw GuestAPIError.invalidRequest("enabled must be a boolean")
                    }
                    enabled = number.boolValue
                }
                for (index, key) in ["roll", "pitch", "yaw"].enumerated() {
                    let limit = index == 1 ? 90.0 : 180.0
                    guard let number = params[key] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                          abs(number.doubleValue) <= limit
                    else { throw GuestAPIError.invalidRequest("\(key) must be a number between -\(limit) and \(limit) degrees") }
                    angles[index] = number.doubleValue
                }
            }
            guard vp_attitude_set(angles[0], angles[1], angles[2], enabled) else {
                throw GuestAPIError.operationFailed("Could not publish the attitude configuration")
            }
        }
        return vp_attitude_get() as? [String: Any] ?? [:]
    }
}
