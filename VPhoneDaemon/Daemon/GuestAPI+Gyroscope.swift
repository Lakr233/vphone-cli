import CoreFoundation
import Foundation
import VphonedNative

// MARK: - Virtual Gyroscope

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
                        throw GuestAPIError.invalidRequest("enabled must be a boolean", hint: "true or false")
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
