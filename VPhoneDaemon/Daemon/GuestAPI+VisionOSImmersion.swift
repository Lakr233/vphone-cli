import Foundation
import VphonedNative

extension GuestAPI {
    static var visionOSImmersionCapabilities: [String] {
        GuestRuntimePlatform.isVisionOS && vp_visionos_immersion_available() ? ["visionos_immersion"] : []
    }

    static func executeVisionOSImmersion(_ method: VisionOSImmersionMethod, _ params: [String: Any]) throws -> [String: Any] {
        guard GuestRuntimePlatform.isVisionOS else {
            throw GuestAPIError.invalidRequest("Immersion control requires a visionOS guest")
        }
        let level: Double
        if method == .set {
            guard let value = params["level"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  (0 ... 1).contains(value.doubleValue) else {
                throw GuestAPIError.invalidRequest("level must be a finite number from 0 to 1")
            }
            level = value.doubleValue
        } else { level = 0 }
        guard let pointer = vp_visionos_immersion_copy_json(level, method == .set) else {
            throw GuestAPIError.operationFailed("Immersion service returned no reply")
        }
        defer { free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestAPIError.operationFailed("Invalid immersion service reply")
        }
        guard reply["ok"] as? Bool == true else {
            throw GuestAPIError.operationFailed(reply["error"] as? String ?? "Immersion control failed")
        }
        guard let state = reply["result"] as? [String: Any],
              state["available"] as? Bool == true,
              state["applied"] as? Bool == (method == .set),
              let observed = state["level"] as? NSNumber,
              CFGetTypeID(observed) != CFBooleanGetTypeID(), observed.doubleValue.isFinite,
              (0 ... 1).contains(observed.doubleValue) else {
            throw GuestAPIError.operationFailed("Malformed native immersion readback")
        }
        if method == .set {
            guard let requested = state["requested_level"] as? NSNumber,
                  CFGetTypeID(requested) != CFBooleanGetTypeID(), requested.doubleValue == level else {
                throw GuestAPIError.operationFailed("Native immersion acknowledgement does not match the request")
            }
            return visionOSImmersionSetResult(requested: level, observed: observed.doubleValue)
        }
        return visionOSImmersionReadResult(level: observed.doubleValue)
    }

    static func visionOSImmersionReadResult(level: Double) -> [String: Any] {
        ["available": true, "applied": false, "level": level]
    }

    static func visionOSImmersionSetResult(requested: Double, observed: Double) -> [String: Any] {
        ["available": true, "applied": true, "requested_level": requested, "level": observed]
    }
}
