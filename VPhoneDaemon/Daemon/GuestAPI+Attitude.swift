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
        case .motionAttitudeGet: MethodSpec()
        case .motionAttitudeSet: MethodSpec(.required("roll", .number), .required("pitch", .number), .required("yaw", .number), .optional("enabled", .boolean))
        case .motionAttitudeClear: MethodSpec()
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
