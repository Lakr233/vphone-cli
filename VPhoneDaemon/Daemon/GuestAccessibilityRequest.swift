import CoreFoundation
import Foundation

// MARK: - Accessibility settings request

/// The checks `accessibility.get` and `accessibility.set` make before the
/// native call, and the error a native failure becomes. Nothing here touches
/// the guest, so `VPhoneDaemon/Tests/run-logic-tests.sh` builds this file on
/// the Mac.
enum GuestAccessibilityRequest {
    static let boolFeatures = ["voiceover", "assistive_touch", "switch_control", "reduce_motion", "full_keyboard_access"]
    static let textSizes = ["xs", "s", "m", "l", "xl", "xxl", "xxxl", "ax1", "ax2", "ax3", "ax4", "ax5"]
    static var features: [String] { boolFeatures + ["text_size"] }

    private static func checkedFeature(_ value: Any?) throws -> String {
        guard let feature = value as? String, features.contains(feature) else {
            throw GuestAPIError.invalidRequest("feature must be one of \(features.joined(separator: ", "))")
        }
        return feature
    }

    /// The one feature a `get` names, or nil for all of them.
    static func get(_ params: [String: Any]) throws -> String? {
        guard let feature = params["feature"] else { return nil }
        return try checkedFeature(feature)
    }

    /// The feature and the value to store, in the form the native call takes.
    static func set(_ params: [String: Any]) throws -> (feature: String, value: Any) {
        let feature = try checkedFeature(params["feature"])
        let value = params["value"]
        if feature == "text_size" {
            guard let name = value as? String, textSizes.contains(name) else {
                throw GuestAPIError.invalidRequest("value for text_size must be one of \(textSizes.joined(separator: ", "))")
            }
            return (feature, name)
        }
        guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
            throw GuestAPIError.invalidRequest("value for \(feature) must be true or false")
        }
        return (feature, flag)
    }

    /// The preference that records a feature's first-use confirmation, as if the user had pressed OK on the
    /// alert; nil when `value` is not true or the feature raises no such alert.
    static func preConfirmation(feature: String, value: Any) -> (domain: String, key: String, value: Any)? {
        guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else { return nil }
        switch feature {
        case "switch_control": return ("com.apple.AssistiveTouch", "AXSAssistiveTouchSwitchUsageConfirmedPreference", true)
        case "voiceover": return ("com.apple.Accessibility", "VoiceOverTouchUsageConfirmed", 1)
        default: return nil
        }
    }

    /// Runs `available`, then the pre-confirmation write when one applies, then `set`. A failed write stops
    /// before `set`.
    static func apply(
        feature: String,
        value: Any,
        available: () throws -> Void,
        write: (_ domain: String, _ key: String, _ value: Any) throws -> Void,
        set: () throws -> [String: Any],
    ) throws -> [String: Any] {
        try available()
        if let confirmation = preConfirmation(feature: feature, value: value) {
            do {
                try write(confirmation.domain, confirmation.key, confirmation.value)
            } catch {
                throw GuestAPIError.operationFailed("\(feature): pre-confirm write failed: \(error)")
            }
        }
        return try set()
    }

    /// The native result, or the `GuestAPIError` its `error` code stands for.
    static func result(_ native: [String: Any]?) throws -> [String: Any] {
        guard let native else { throw GuestAPIError.operationFailed("Native accessibility settings call returned nothing") }
        guard let code = native["error"] as? String else { return native }
        let message = native["message"] as? String ?? code
        switch code {
        case "invalid_request": throw GuestAPIError.invalidRequest(message)
        case "unavailable": throw GuestAPIError.unavailable(message)
        default: throw GuestAPIError.operationFailed(message)
        }
    }
}
