import Foundation

// MARK: - Settings Value

/// The text and type `settings.set` writes for a decoded JSON `value`.
/// `JSONSerialization.data(withJSONObject:)` raises an exception Swift cannot
/// catch on anything but an array or object, so that check comes first.
///
/// Nothing here touches the guest, so `VPhoneDaemon/Tests/run-logic-tests.sh`
/// builds this file on the Mac.
enum GuestSettingsValue {
    /// The text and type to write, nil when `value` cannot be written.
    static func typedText(_ value: Any?, type: String?) -> (text: String, type: String)? {
        guard let value, !(value is NSNull) else { return nil }
        let type =
            type
                ?? (value is Bool
                    ? "bool"
                    : value is NSNumber
                    ? "float"
                    : value is String ? "string" : "json")
        guard type == "json" else { return (String(describing: value), type) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return (text, type)
    }
}
