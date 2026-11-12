/// Result key types; raw values are the catalog `result` column spellings.
public enum KeyType: String, Sendable {
    case string, integer, number, boolean, array, object, any, null
}

public enum Presence: Sendable {
    case required, optional
}

public struct ExtractedKey: Equatable, Sendable {
    public let name: String
    public var type: KeyType
    public var presence: Presence
    /// Emitted on every path but nil/NSNull on some; separate from type and presence.
    public var nullable: Bool

    public init(name: String, type: KeyType, presence: Presence, nullable: Bool = false) {
        self.name = name
        self.type = type
        self.presence = presence
        self.nullable = nullable
    }
}

public typealias KeyMap = [String: ExtractedKey]

/// Key-set combination shared by both extractors.
public enum KeyMerge {
    /// Adds one key; a repeated name with a different type becomes `any`, a required
    /// occurrence makes the key required, and nullability is OR-ed.
    public static func merge(_ keys: inout KeyMap, name: String, type: KeyType, presence: Presence, nullable: Bool = false) {
        if var existing = keys[name] {
            let unified = unify(existing, ExtractedKey(name: name, type: type, presence: presence, nullable: nullable))
            existing.type = unified.type
            existing.nullable = unified.nullable
            if presence == .required { existing.presence = .required }
            keys[name] = existing
        } else {
            keys[name] = ExtractedKey(name: name, type: type, presence: presence, nullable: nullable)
        }
    }

    /// Type and nullability of two occurrences of one key: equal types stay, `null` with a
    /// concrete type is that type made nullable, any other difference is `any`.
    static func unify(_ a: ExtractedKey, _ b: ExtractedKey) -> (type: KeyType, nullable: Bool) {
        unify((a.type, a.nullable), (b.type, b.nullable))
    }

    /// `integersAreNumbers` (native extraction): `integer` with `number` is `number`, since JSON
    /// integers are numbers; the Swift extractor keeps it `any`.
    static func unify(
        _ a: (type: KeyType, nullable: Bool), _ b: (type: KeyType, nullable: Bool), integersAreNumbers: Bool = false
    ) -> (type: KeyType, nullable: Bool) {
        let nullable = a.nullable || b.nullable
        if a.type == b.type { return (a.type, nullable) }
        if a.type == .null { return (b.type, true) }
        if b.type == .null { return (a.type, true) }
        if integersAreNumbers, Set([a.type, b.type]) == [.integer, .number] { return (.number, nullable) }
        return (.any, nullable)
    }

    /// Union of per-path key sets; a key absent from any set (or optional in one) is optional.
    public static func union(_ sets: [KeyMap]) -> KeyMap {
        var result: KeyMap = [:]
        for set in sets {
            for (name, key) in set {
                if var existing = result[name] {
                    let unified = unify(existing, key)
                    existing.type = unified.type
                    existing.nullable = unified.nullable
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

/// Renders keys as a methods-catalog.tsv `result` cell: `name:type[:null]` (plus `?` when
/// optional; a null-only key is `name:null`) sorted by name and comma separated; `-` when there are none.
public func catalogCell(_ keys: [ExtractedKey]) -> String {
    if keys.isEmpty { return "-" }
    return keys.sorted { $0.name < $1.name }
        .map { "\($0.name):\($0.type.rawValue)\($0.nullable && $0.type != .null ? ":null" : "")\($0.presence == .optional ? "?" : "")" }
        .joined(separator: ",")
}
