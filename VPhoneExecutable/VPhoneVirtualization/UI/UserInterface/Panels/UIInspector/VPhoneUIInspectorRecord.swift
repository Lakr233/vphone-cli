import Foundation

// MARK: - Detail

/// One key of a guest record, flattened for the detail readout
/// (`frame.x`, `frame.width`, …).
struct VPhoneUIInspectorDetail: Identifiable {
    let key: String
    let value: String

    var id: String {
        key
    }
}

// MARK: - Record Formatting

/// Renders the raw vphoned dictionaries behind the inspector rows.
enum VPhoneUIInspectorRecord {
    /// A point value without noise: `12`, `104.5`, `0.98`.
    static func number(_ value: Double, fractionDigits: Int = 2) -> String {
        guard value.isFinite else { return "—" }
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int(value))
        }
        var text = String(format: "%.*f", fractionDigits, value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    /// `x,y w×h` in guest points.
    static func frame(_ rect: CGRect) -> String {
        let point = { (value: Double) in number(value, fractionDigits: 1) }
        return "\(point(rect.minX)),\(point(rect.minY)) \(point(rect.width))×\(point(rect.height))"
    }

    static func details(_ object: [String: Any], prefix: String = "") -> [VPhoneUIInspectorDetail] {
        object.keys.sorted().flatMap { key -> [VPhoneUIInspectorDetail] in
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = object[key] as? [String: Any] {
                return details(nested, prefix: path)
            }
            return [VPhoneUIInspectorDetail(key: path, value: display(object[key]))]
        }
    }

    static func display(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return text.isEmpty ? "\"\"" : text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return self.number(number.doubleValue)
        case nil, is NSNull:
            return "null"
        case let other?:
            guard JSONSerialization.isValidJSONObject(other),
                  let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys])
            else { return String(describing: other) }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
