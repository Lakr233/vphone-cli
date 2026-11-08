/// Result key types; raw values are the catalog `result` column spellings.
public enum KeyType: String, Sendable {
    case string, integer, number, boolean, array, object, any
}

public enum Presence: Sendable {
    case required, optional
}

public struct ExtractedKey: Equatable, Sendable {
    public let name: String
    public var type: KeyType
    public var presence: Presence

    public init(name: String, type: KeyType, presence: Presence) {
        self.name = name
        self.type = type
        self.presence = presence
    }
}

public typealias KeyMap = [String: ExtractedKey]

/// Key-set combination shared by both extractors.
public enum KeyMerge {
    /// Adds one key; a repeated name with a different type becomes `any`, and a
    /// required occurrence makes the key required.
    public static func merge(_ keys: inout KeyMap, name: String, type: KeyType, presence: Presence) {
        if var existing = keys[name] {
            existing.type = unifiedType(existing.type, type)
            if presence == .required { existing.presence = .required }
            keys[name] = existing
        } else {
            keys[name] = ExtractedKey(name: name, type: type, presence: presence)
        }
    }

    /// A repeated name with a different type becomes `any`.
    static func unifiedType(_ a: KeyType, _ b: KeyType) -> KeyType {
        a == b ? a : .any
    }

    /// Union of per-path key sets; a key absent from any set (or optional in one) is optional.
    public static func union(_ sets: [KeyMap]) -> KeyMap {
        var result: KeyMap = [:]
        for set in sets {
            for (name, key) in set {
                if var existing = result[name] {
                    existing.type = unifiedType(existing.type, key.type)
                    result[name] = existing
                } else {
                    result[name] = key
                }
            }
        }
        for name in result.keys {
            let everywhere = sets.allSatisfy { $0[name]?.presence == .required }
            result[name]?.presence = everywhere ? .required : .optional
        }
        return result
    }
}

/// Renders keys as a methods-catalog.tsv `result` cell: `name:type` (plus `?` when
/// optional) sorted by name and comma separated; `-` when there are none.
public func catalogCell(_ keys: [ExtractedKey]) -> String {
    if keys.isEmpty { return "-" }
    return keys.sorted { $0.name < $1.name }
        .map { "\($0.name):\($0.type.rawValue)\($0.presence == .optional ? "?" : "")" }
        .joined(separator: ",")
}
