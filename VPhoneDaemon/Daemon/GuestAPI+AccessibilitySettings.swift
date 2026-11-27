import Foundation
import IcliKit
import VphonedNative

// MARK: - Accessibility settings

extension GuestAPI {
    /// Takes `interfaceLock`: the settings share libAccessibility with the element and hierarchy walks.
    static func executeAccessibility(_ m: AccessibilityMethod, _ params: [String: Any]) throws -> [String: Any] {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        switch m {
        case .accessibilityGet:
            let feature = try GuestAccessibilityRequest.get(params)
            return try GuestAccessibilityRequest.result(vp_ax_settings_get(feature) as? [String: Any])
        case .accessibilitySet:
            let request = try GuestAccessibilityRequest.set(params)
            return try GuestAccessibilityRequest.apply(
                feature: request.feature,
                value: request.value,
                available: {
                    let read = try GuestAccessibilityRequest.result(vp_ax_settings_get(request.feature) as? [String: Any])
                    if (read["unavailable"] as? [String])?.contains(request.feature) == true {
                        throw GuestAPIError.unavailable("\(request.feature) is not available on this guest")
                    }
                },
                write: { domain, key, value in
                    let stored: PreferenceValue
                    switch value {
                    case let flag as Bool: stored = .bool(flag)
                    case let number as Int: stored = .int(Int64(number))
                    default: throw GuestAPIError.operationFailed("unsupported pre-confirm value for \(key)")
                    }
                    _ = try writePreference(domain: domain, key: key, value: stored, user: .mobile)
                },
                set: { try GuestAccessibilityRequest.result(vp_ax_settings_set(request.feature, request.value) as? [String: Any]) },
            )
        }
    }
}
