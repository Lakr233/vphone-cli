import Foundation

// MARK: - Value Type

/// The scalar types `settings.set` accepts. The raw value is the wire name.
enum VPhoneGuestPreferenceType: String, CaseIterable, Identifiable {
    case string
    case bool
    case int
    case float

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .string: String(localized: "String", bundle: VPhoneLocalization.bundle)
        case .bool: String(localized: "Boolean", bundle: VPhoneLocalization.bundle)
        case .int: String(localized: "Integer", bundle: VPhoneLocalization.bundle)
        case .float: String(localized: "Float", bundle: VPhoneLocalization.bundle)
        }
    }

    var prompt: String {
        switch self {
        case .string: String(localized: "Text", bundle: VPhoneLocalization.bundle)
        case .bool: String(localized: "true or false", bundle: VPhoneLocalization.bundle)
        case .int: "42"
        case .float: "3.14"
        }
    }

    /// Parses text typed by the user into the value sent to the guest.
    func parse(_ text: String) -> Result<Any, VPhoneGuestPreferenceParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .string:
            return .success(text)
        case .bool:
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .success(true)
            case "false", "no", "0": return .success(false)
            default: return .failure(.init(message: String(localized: "Enter true or false for a Boolean value.", bundle: VPhoneLocalization.bundle)))
            }
        case .int:
            guard let number = Int64(trimmed) else {
                return .failure(.init(message: String(localized: "Enter a whole number for an Integer value.", bundle: VPhoneLocalization.bundle)))
            }
            return .success(number)
        case .float:
            guard let number = Double(trimmed), number.isFinite else {
                return .failure(.init(message: String(localized: "Enter a finite number for a Float value.", bundle: VPhoneLocalization.bundle)))
            }
            return .success(number)
        }
    }
}

struct VPhoneGuestPreferenceParseError: Error {
    let message: String
}

// MARK: - Entry

/// One node of a preference value as the guest returned it. Dictionaries and
/// arrays carry children so the result reads as an outline.
struct VPhoneGuestPreferenceEntry: Identifiable {
    enum Kind {
        case string
        case bool
        case int
        case float
        case date
        case data
        case array
        case dictionary
        case null
    }

    let id: String
    let key: String
    let kind: Kind
    let summary: String
    let children: [VPhoneGuestPreferenceEntry]?

    var typeTitle: String {
        switch kind {
        case .string: String(localized: "String", bundle: VPhoneLocalization.bundle)
        case .bool: String(localized: "Boolean", bundle: VPhoneLocalization.bundle)
        case .int: String(localized: "Integer", bundle: VPhoneLocalization.bundle)
        case .float: String(localized: "Float", bundle: VPhoneLocalization.bundle)
        case .date: String(localized: "Date", bundle: VPhoneLocalization.bundle)
        case .data: String(localized: "Data", bundle: VPhoneLocalization.bundle)
        case .array: String(localized: "Array", bundle: VPhoneLocalization.bundle)
        case .dictionary: String(localized: "Dictionary", bundle: VPhoneLocalization.bundle)
        case .null: String(localized: "Null", bundle: VPhoneLocalization.bundle)
        }
    }

    /// The write type that round-trips this entry, when it is a scalar.
    var writableType: VPhoneGuestPreferenceType? {
        switch kind {
        case .string: .string
        case .bool: .bool
        case .int: .int
        case .float: .float
        default: nil
        }
    }

    init(key: String, value: Any?, path: String? = nil) {
        let path = path ?? key
        id = path
        self.key = key

        switch value {
        case nil, is NSNull:
            kind = .null
            summary = "—"
            children = nil
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            kind = .bool
            summary = number.boolValue ? "true" : "false"
            children = nil
        case let number as NSNumber:
            let isFloat = CFNumberIsFloatType(number)
            kind = isFloat ? .float : .int
            summary = isFloat ? String(number.doubleValue) : String(number.int64Value)
            children = nil
        case let string as String:
            kind = .string
            summary = string
            children = nil
        case let date as Date:
            kind = .date
            summary = date.ISO8601Format()
            children = nil
        case let data as Data:
            kind = .data
            summary = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)
            children = nil
        case let array as [Any]:
            kind = .array
            summary = array.count == 1
                ? String(localized: "1 item", bundle: VPhoneLocalization.bundle) : String(localized: "\(array.count) items", bundle: VPhoneLocalization.bundle)
            children = array.enumerated().map { index, element in
                VPhoneGuestPreferenceEntry(key: "[\(index)]", value: element, path: "\(path)/\(index)")
            }
        case let dictionary as [String: Any]:
            kind = .dictionary
            summary = dictionary.count == 1
                ? String(localized: "1 key", bundle: VPhoneLocalization.bundle) : String(localized: "\(dictionary.count) keys", bundle: VPhoneLocalization.bundle)
            children = Self.entries(from: dictionary, path: path)
        default:
            kind = .string
            summary = String(describing: value!)
            children = nil
        }
    }

    static func entries(from dictionary: [String: Any], path: String = "") -> [VPhoneGuestPreferenceEntry] {
        dictionary.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { VPhoneGuestPreferenceEntry(key: $0, value: dictionary[$0], path: "\(path)/\($0)") }
    }
}

// MARK: - Read Result

struct VPhoneGuestPreferenceReadResult {
    let domain: String
    /// Nil when the whole domain was read.
    let key: String?
    let entries: [VPhoneGuestPreferenceEntry]
    /// Pretty-printed JSON, or a plain description for scalars.
    let text: String

    init(domain: String, key: String?, value: Any?) {
        self.domain = domain
        self.key = key

        if key == nil, let dictionary = value as? [String: Any] {
            entries = VPhoneGuestPreferenceEntry.entries(from: dictionary)
        } else if let key, value != nil, !(value is NSNull) {
            entries = [VPhoneGuestPreferenceEntry(key: key, value: value)]
        } else {
            entries = []
        }

        if let value, JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8)
        {
            text = string
        } else if let value, !(value is NSNull) {
            text = String(describing: value)
        } else {
            text = ""
        }
    }

    var title: String {
        key.map { "\(domain) › \($0)" } ?? domain
    }
}
