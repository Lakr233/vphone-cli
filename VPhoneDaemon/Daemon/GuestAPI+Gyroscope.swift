import CoreFoundation
import Foundation
import VphonedNative

// MARK: - Virtual Gyroscope

enum GyroscopeMethod: String, GuestMethod {
    case motionGyroscopeGet = "motion.gyroscope.get"
    case motionGyroscopeSet = "motion.gyroscope.set"
    case motionGyroscopeClear = "motion.gyroscope.clear"

    var spec: MethodSpec {
        switch self {
        case .motionGyroscopeGet: MethodSpec(summary: "Read the simulated gyroscope rotation rates in rad/s and whether it is enabled.", result: [.required("enabled", .any),
                                                      .required("provider", .any),
                                                      .required("provider_running", .any),
                                                      .required("units", .string),
                                                      .required("x", .any),
                                                      .required("y", .any),
                                                      .required("z", .any)])
        case .motionGyroscopeSet: MethodSpec(.required("x", .number, "Rotation rate about x in rad/s", min: -1000, max: 1000), .required("y", .number, "Rotation rate about y in rad/s", min: -1000, max: 1000), .required("z", .number, "Rotation rate about z in rad/s", min: -1000, max: 1000), .optional("enabled", .boolean, "Whether the simulated gyroscope is active", default: true), summary: "Set the simulated gyroscope rotation rates (rad/s) that motion sensors report.", result: [.required("enabled", .any),
                                                      .required("provider", .any),
                                                      .required("provider_running", .any),
                                                      .required("units", .string),
                                                      .required("x", .any),
                                                      .required("y", .any),
                                                      .required("z", .any)])
        case .motionGyroscopeClear: MethodSpec(summary: "Turn off the simulated gyroscope and reset its rates to zero.", result: [.required("enabled", .any),
                                                        .required("provider", .any),
                                                        .required("provider_running", .any),
                                                        .required("units", .string),
                                                        .required("x", .any),
                                                        .required("y", .any),
                                                        .required("z", .any)])
        }
    }
}

extension GuestAPI {
    private static let gyroscopeLock = NSLock()

    static func executeGyroscope(_ m: GyroscopeMethod, _ params: [String: Any]) throws -> [String: Any] {
        // The API queue is concurrent. Serialize publication and readback so
        // the response contains the dictionary this request actually wrote.
        gyroscopeLock.lock()
        defer { gyroscopeLock.unlock() }
        if m != .motionGyroscopeGet {
            var axes = [Double](repeating: 0, count: 3)
            var enabled = m == .motionGyroscopeSet
            if m == .motionGyroscopeSet {
                if let flag = params["enabled"] {
                    guard let value = flag as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                        throw GuestAPIError.invalidRequest("enabled must be a boolean")
                    }
                    enabled = value.boolValue
                }
                for (index, key) in ["x", "y", "z"].enumerated() {
                    guard let value = params[key] as? NSNumber,
                          CFGetTypeID(value) != CFBooleanGetTypeID(),
                          value.doubleValue.isFinite, abs(value.doubleValue) <= 1000
                    else {
                        throw GuestAPIError.invalidRequest("\(key) must be a number between -1000 and 1000 rad/s")
                    }
                    axes[index] = value.doubleValue
                }
            }
            guard vp_gyro_set(axes[0], axes[1], axes[2], enabled) else {
                throw GuestAPIError.operationFailed("Could not publish the gyroscope configuration")
            }
        }
        return vp_gyro_get() as? [String: Any] ?? [:]
    }
}
