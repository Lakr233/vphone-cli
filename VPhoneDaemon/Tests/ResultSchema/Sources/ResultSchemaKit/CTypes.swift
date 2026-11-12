import Foundation

/// Types of C functions and structs Swift imports (REQ-RPC-007): a call `icli_screen_metrics()` has the
/// return type its declaration gives, and `.width` the field type of the struct it returns.
final class CTypes {
    let sources: (String) -> [NativeSource]
    private var returns: [String: TypeRef] = [:]
    private var fields: [String: [String: TypeRef]] = [:]

    init(sources: @escaping (String) -> [NativeSource]) { self.sources = sources }

    /// A scalar C type name list as its JSON type; anything else is `any`.
    static func key(_ words: [String], pointer: Bool) -> KeyType {
        let words = words.filter { !qualifiers.contains($0) }
        guard !pointer, let last = words.last else { return .any }
        if booleanTypes.contains(last) { return .boolean }
        if numberTypes.contains(last) { return .number }
        if words.contains(where: { integerTypes.contains($0) }) { return .integer }
        return .any
    }

    static let objectiveC: [String: KeyType] = [
        "NSArray": .array, "NSMutableArray": .array, "NSDictionary": .object, "NSMutableDictionary": .object,
        "NSString": .string, "NSMutableString": .string,
    ]

    private static func ref(_ words: [String], pointer: Bool) -> TypeRef {
        let nullable = words.contains("_Nullable")
        let words = words.filter { !["_Nonnull", "_Nullable", "_Null_unspecified"].contains($0) }
        if pointer, words.count == 1, let known = objectiveC[words[0]] { return TypeRef(key: known, optional: nullable) }
        let key = key(words, pointer: pointer)
        if key != .any { return TypeRef(key: key) }
        let named = words.filter { !qualifiers.contains($0) }
        return pointer || named.count != 1 ? TypeRef() : TypeRef(nominal: named[0])
    }

    static let qualifiers: Set<String> = ["const", "volatile", "struct", "enum", "static", "extern", "inline", "__strong"]

    /// The return type declared (or defined) for C function `name`; `any` when absent or ambiguous.
    func returnType(_ name: String) -> TypeRef {
        if let known = returns[name] { return known }
        let pattern = "(?m)^[ \\t]*((?:[A-Za-z_]\\w*[ \\t]+|\\*[ \\t]*)*?[A-Za-z_]\\w*(?:[ \\t]*\\*+)?)[ \\t]*\\b\(name)[ \\t]*\\("
        var found: [TypeRef] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for source in sources(name) {
                let text = source.text
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let declaration = String(text[range])
                    let pointer = declaration.contains("*")
                    let words = declaration.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
                    guard let first = words.first, !reserved.contains(first) else { continue }
                    found.append(CTypes.ref(words, pointer: pointer))
                }
            }
        }
        var result = found.first ?? TypeRef()
        for other in found.dropFirst() { result = result.unified(with: other) }
        returns[name] = result
        return result
    }

    /// The type of field `field` of C struct `type`; nil when the struct is not found.
    func field(_ type: String, _ field: String) -> TypeRef? {
        if fields[type] == nil { fields[type] = parseStruct(type) }
        return fields[type]?[field]
    }

    private func parseStruct(_ name: String) -> [String: TypeRef] {
        let pattern = "typedef\\s+struct\\s*\\w*\\s*\\{([^{}]*)\\}\\s*\(name)\\s*;"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var result: [String: TypeRef] = [:]
        for source in sources(name) {
            let text = source.text
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var body = String(text[range])
                body = body.replacingOccurrences(of: "/\\*[^*]*\\*+(?:[^/*][^*]*\\*+)*/", with: "", options: .regularExpression)
                body = body.replacingOccurrences(of: "//[^\\n]*", with: "", options: .regularExpression)
                for declaration in body.split(separator: ";") {
                    let parts = declaration.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard let head = parts.first, !head.contains("[") else { continue }
                    let words = head.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "*") }).map(String.init)
                    guard words.count >= 2 else { continue }
                    let base = Array(words.dropLast()).map { $0.replacingOccurrences(of: "*", with: "") }
                    let basePointer = words.dropLast().contains { $0.contains("*") }
                    var names = [(words.last!, basePointer || words.last!.hasPrefix("*"))]
                    names += parts.dropFirst().map { ($0.replacingOccurrences(of: "*", with: ""), basePointer || $0.hasPrefix("*")) }
                    for (fieldName, pointer) in names {
                        let clean = fieldName.replacingOccurrences(of: "*", with: "")
                        let ref = CTypes.ref(base.filter { !$0.isEmpty }, pointer: pointer)
                        result[clean] = result[clean].map { $0.unified(with: ref) } ?? ref
                    }
                }
            }
        }
        return result
    }
}
