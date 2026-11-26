import CoreFoundation
import Foundation

// MARK: - Element request

/// The native request a `ui.element.*` call makes and the error a native
/// failure becomes. Nothing here touches the guest, so
/// `VPhoneDaemon/Tests/run-logic-tests.sh` builds this file on the Mac.
enum GuestElementRequest {
    enum Operation { case activate, focus, setValue, attributes }

    private static let selectorKeys = ["text", "identifier", "role", "match", "index", "path"]

    /// The selector and operation dictionaries `vp_ax_element` takes.
    static func build(_ operation: Operation, _ params: [String: Any]) throws -> (selector: [String: Any], operation: [String: Any]) {
        let selector = try selector(params)
        switch operation {
        case .attributes: return (selector, ["op": "attributes"])
        case .focus: return (selector, ["op": "focus"])
        case .setValue:
            guard let value = params["value"] as? String else { throw GuestAPIError.invalidRequest("value must be a string") }
            return (selector, ["op": "set_value", "value": value])
        case .activate:
            let name = params["action"] ?? "activate"
            guard let name = name as? String else { throw GuestAPIError.invalidRequest("action must be a string") }
            return (selector, ["op": "action", "name": name])
        }
    }

    private static func whole(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue >= 0 && number.doubleValue == number.doubleValue.rounded(.towardZero)
            && number.doubleValue < Double(Int32.max)
    }

    private static func selector(_ params: [String: Any]) throws -> [String: Any] {
        let selector = params.filter { selectorKeys.contains($0.key) }
        for key in ["text", "identifier", "role"] {
            if let value = selector[key], (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw GuestAPIError.invalidRequest("\(key) must be a non-blank string")
            }
        }
        if let match = selector["match"], match as? String != "contains", match as? String != "exact" {
            throw GuestAPIError.invalidRequest("match must be contains or exact")
        }
        if let index = selector["index"], !whole(index) {
            throw GuestAPIError.invalidRequest("index must be a non-negative integer")
        }
        if let path = selector["path"] {
            guard let steps = path as? [Any], steps.allSatisfy(whole) else {
                throw GuestAPIError.invalidRequest("path must be an array of non-negative integers")
            }
            if selector["index"] != nil { throw GuestAPIError.invalidRequest("index cannot be combined with path") }
        }
        guard ["text", "identifier", "role", "path"].contains(where: { selector[$0] != nil }) else {
            throw GuestAPIError.invalidRequest("Give at least one of text, identifier, role or path")
        }
        return selector
    }

    /// The native result, or the `GuestAPIError` its `error` code stands for.
    /// Native messages already carry the one-clause corrective hint.
    static func result(_ native: [String: Any]?) throws -> [String: Any] {
        guard let native else { throw GuestAPIError.operationFailed("Native element call returned nothing") }
        guard let code = native["error"] as? String else { return native }
        let message = native["message"] as? String ?? code
        switch code {
        case "not_found": throw GuestAPIError.notFound(message)
        case "ambiguous", "stale": throw GuestAPIError.operationFailed("\(code): \(message)")
        case "invalid_request": throw GuestAPIError.invalidRequest(message)
        case "unavailable": throw GuestAPIError.unavailable(message)
        default: throw GuestAPIError.operationFailed(message)
        }
    }
}
