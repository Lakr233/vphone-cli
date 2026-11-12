import Foundation

/// A native source file offered to the extractor for following calls into other files.
public struct NativeSource: Sendable {
    public let file: String
    public let text: String
    public init(file: String, text: String) {
        self.file = file
        self.text = text
    }
}

/// How a producer entry is read: a plain function (`return` values, falling back to the
/// dictionaries it writes to a plist), or a `writer:` function.
public enum NativeMode: Sendable {
    case produce, writer
}

/// Derives an Objective-C or C function's result keys (design.md extraction rules 6-9).
public enum NativeExtractor {
    /// - Parameters:
    ///   - lookup: finds other sources whose text contains a given name or string (the icli
    ///     checkout, repo headers); the function's own source is searched first.
    public static func extract(
        source: String, function: String, mode: NativeMode = .produce,
        method: String = "", file: String = "",
        lookup: @escaping (String) -> [NativeSource] = { _ in [] }
    ) throws -> [ExtractedKey] {
        let engine = Engine(method: method, lookup: lookup)
        let src = Src(file: file, text: source)
        let found = engine.functions(of: src).filter { $0.name == function }
        guard found.count == 1, let fn = found.first else {
            let at = found.dropFirst().first ?? found.first
            throw engine.failure(src, function, at?.nameIdx ?? 0)
        }
        return Array(try engine.run(fn, mode).values)
    }
}

extension NativeExtractor {
    /// As `extract`, for a function defined in exactly one of `sources` (rule 6: a bridge
    /// function that lives in another file than the Swift caller).
    public static func extract(
        function: String, sources: [NativeSource], mode: NativeMode = .produce, method: String = "",
        lookup: @escaping (String) -> [NativeSource] = { _ in [] }
    ) throws -> [ExtractedKey] {
        let engine = Engine(method: method, lookup: lookup)
        let fn = try single(engine, function, sources, method)
        return Array(try engine.run(fn, mode).values)
    }

    private static func single(_ engine: Engine, _ function: String, _ sources: [NativeSource], _ method: String) throws -> Fn {
        var found: [Fn] = []
        // Sources stay alive as long as the engine: it caches functions by object identity.
        let parsed = sources.map { Src(file: $0.file, text: $0.text) }
        engine.retained += parsed
        for src in parsed {
            found += engine.functions(of: src).filter { $0.name == function }
        }
        guard found.count == 1, let fn = found.first else {
            let at = found.first
            throw engine.failure(at?.src ?? Src(file: sources.first?.file ?? "", text: ""), function, at?.nameIdx ?? 0)
        }
        return fn
    }

    /// Rule 10: the keys of the value stored under `key` in the `@{...}` envelope literals of the
    /// native function `function` (found in exactly one of `sources`) and of the functions it
    /// calls, in the same file or through `lookup`. A value that is not a dictionary literal
    /// (passed through from another dictionary) is `open`.
    public static func unwrap(
        function: String, key: String, sources: [NativeSource], method: String = "",
        lookup: @escaping (String) -> [NativeSource] = { _ in [] }
    ) throws -> (keys: [ExtractedKey], open: Bool) {
        let engine = Engine(method: method, lookup: lookup)
        let root = try single(engine, function, sources, method)
        var sets: [KeyMap] = []
        var open = false
        var seen = false
        var visited: Set<String> = []

        func scan(_ fn: Fn) throws {
            let id = fn.src.file + "#" + fn.name + "@\(fn.open)"
            guard visited.insert(id).inserted else { return }
            let src = fn.src
            let t = src.toks
            var i = fn.open + 1
            while i < fn.close {
                if t[i].text == "@{", src.match[i] > i {
                    let end = src.match[i]
                    var s = i + 1
                    while s < end {
                        let e = engine.topLevel(src, ",", s, end) ?? end
                        if t[s].kind == .objcString, t[s].text == key, s + 2 < e, t[s + 1].text == ":" {
                            seen = true
                            if t[s + 2].text == "@{", src.match[s + 2] == e - 1 {
                                sets.append(try engine.keys(fn, s + 2, e, use: s))
                            } else {
                                open = true
                            }
                        }
                        s = e + 1
                    }
                    i = end + 1
                    continue
                }
                if t[i].kind == .ident, i + 1 < fn.close, t[i + 1].text == "(", t[i + 1].kind == .punct,
                   !reserved.contains(t[i].text), t[i].text != fn.name,
                   let callee = engine.tryResolve(t[i].text, from: fn) {
                    try scan(callee)
                }
                i += 1
            }
        }
        try scan(root)
        guard seen else { throw engine.fail(root, root.nameIdx) }
        return (Array(KeyMerge.union(sets).values), open)
    }

    /// Rule 11 for a bridge whose JSON is an envelope: the key set of the dictionaries added with
    /// `[array addObject:x]` to the array stored under `key` of the `@{...}` literal `function` builds
    /// (`icli_system_json(@{@"processes": rows})`).
    public static func elements(
        function: String, key: String, sources: [NativeSource], method: String = "",
        lookup: @escaping (String) -> [NativeSource] = { _ in [] }
    ) throws -> [ExtractedKey] {
        let engine = Engine(method: method, lookup: lookup)
        let fn = try single(engine, function, sources, method)
        let src = fn.src
        let t = src.toks
        var arrays: Set<String> = []
        for i in (fn.open + 1)..<fn.close where t[i].text == "@{" && src.match[i] > i {
            let end = src.match[i]
            var s = i + 1
            while s < end {
                let e = engine.topLevel(src, ",", s, end) ?? end
                if t[s].kind == .objcString, t[s].text == key, s + 3 == e, t[s + 1].text == ":", t[s + 2].kind == .ident {
                    arrays.insert(t[s + 2].text)
                }
                s = e + 1
            }
        }
        var sets: [KeyMap] = []
        for i in (fn.open + 1)..<fn.close where t[i].text == "[" && src.match[i] > i {
            guard i + 3 < fn.close, t[i + 1].kind == .ident, arrays.contains(t[i + 1].text),
                  t[i + 2].text == "addObject", t[i + 3].text == ":" else { continue }
            sets.append(try engine.keys(fn, i + 4, src.match[i], use: i))
        }
        if sets.isEmpty { throw engine.fail(fn, fn.nameIdx) }
        return Array(KeyMerge.union(sets).values)
    }

    /// Rule 11 for a bridge: the key set of the dictionaries a native function adds with
    /// `[array addObject:x]` to the array it returns.
    public static func elements(
        function: String, sources: [NativeSource], method: String = "",
        lookup: @escaping (String) -> [NativeSource] = { _ in [] }
    ) throws -> [ExtractedKey] {
        let engine = Engine(method: method, lookup: lookup)
        let fn = try single(engine, function, sources, method)
        let src = fn.src
        let t = src.toks
        var returned: Set<String> = []
        for i in (fn.open + 1)..<fn.close where t[i].text == "return" && t[i].kind == .ident {
            let e = engine.endOfStatement(src, i + 1, limit: fn.close)
            for j in (i + 1)..<e where t[j].kind == .ident { returned.insert(t[j].text) }
        }
        var sets: [KeyMap] = []
        for i in (fn.open + 1)..<fn.close where t[i].text == "[" && src.match[i] > i {
            guard i + 3 < fn.close, t[i + 1].kind == .ident, returned.contains(t[i + 1].text),
                  t[i + 2].text == "addObject", t[i + 3].text == ":" else { continue }
            sets.append(try engine.keys(fn, i + 4, src.match[i], use: i))
        }
        if sets.isEmpty { throw engine.fail(fn, fn.nameIdx) }
        return Array(KeyMerge.union(sets).values)
    }
}

/// Calls whose block argument produces the result: the keys are those of the block's returns.
private let blockWrappers: Set<String> = ["icli_archive_with_utf8_names"]
private let wrappers: Set<String> = ["icli_json_or_empty", "icli_json", "icli_system_json", "strndup", "strdup","decodeBridgeJSON", "takeCString", "launchJSON"]
private let dictClasses: Set<String> = ["NSDictionary", "NSMutableDictionary"]
let reserved: Set<String> = [
    "return", "else", "case", "goto", "sizeof", "new", "in", "typeof", "if", "while", "for", "do", "switch",
    "@throw", "@catch", "@try",
]
let integerTypes: Set<String> = [
    "CFIndex", "CFOptionFlags", "CFTypeID", "int", "long", "short", "unsigned", "signed", "NSInteger", "NSUInteger", "size_t", "ssize_t", "pid_t", "uid_t",
    "gid_t", "off_t", "time_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
    "uint64_t", "uintptr_t", "intptr_t",
]
let numberTypes: Set<String> = ["double", "float", "CGFloat", "NSTimeInterval", "CFTimeInterval"]
let booleanTypes: Set<String> = ["BOOL", "bool", "Boolean", "_Bool"]

private final class Node {
    enum Kind { case simple, block, ifelse, loop, trycatch, switchStmt }
    let kind: Kind
    let range: Range<Int>
    let children: [Node]
    init(_ kind: Kind, _ range: Range<Int>, _ children: [Node] = []) {
        self.kind = kind
        self.range = range
        self.children = children
    }
}

private final class Fn {
    let src: Src
    let name: String
    let nameIdx: Int
    let open: Int
    let close: Int
    lazy var tree: [Node] = Engine.parseList(src, open + 1, close)

    init(src: Src, name: String, nameIdx: Int, open: Int, close: Int) {
        self.src = src
        self.name = name
        self.nameIdx = nameIdx
        self.open = open
        self.close = close
    }

    func contains(_ i: Int) -> Bool { i > open && i < close }
}

private struct Assign {
    let key: String
    let value: Range<Int>
    let pos: Int
}

private final class Engine {
    let method: String
    let lookup: (String) -> [NativeSource]
    var cache: [String: Src] = [:]
    var fnCache: [ObjectIdentifier: [Fn]] = [:]
    /// Every parsed source whose functions are cached (see `fnCache`).
    var retained: [Src] = []
    var visiting: Set<String> = []
    /// Variables whose `id` bindings are being typed (guards a binding that names itself).
    var inferring: Set<String> = []
    /// C structs found through `lookup` (field types of `state.x`).
    lazy var ctypes = CTypes(sources: lookup)

    init(method: String, lookup: @escaping (String) -> [NativeSource]) {
        self.method = method
        self.lookup = lookup
    }

    // MARK: failures

    func failure(_ src: Src, _ function: String, _ idx: Int) -> Unresolvable {
        let line = src.toks.indices.contains(idx) ? src.toks[idx].line : 1
        return Unresolvable(method: method, file: src.file, function: function, line: line)
    }

    func fail(_ fn: Fn, _ idx: Int) -> Unresolvable { failure(fn.src, fn.name, idx) }

    // MARK: functions

    func functions(of src: Src) -> [Fn] {
        if let cached = fnCache[ObjectIdentifier(src)] { return cached }
        var result: [Fn] = []
        let t = src.toks
        let skip: Set<String> = ["if", "for", "while", "switch", "return", "sizeof", "@catch", "@synchronized"]
        for i in t.indices where t[i].kind == .ident && src.enclosing[i] == -1 && !skip.contains(t[i].text) {
            guard i + 1 < t.count, t[i + 1].text == "(", t[i + 1].kind == .punct else { continue }
            let close = src.match[i + 1]
            guard close > 0, close + 1 < t.count, t[close + 1].text == "{", t[close + 1].kind == .punct,
                  src.match[close + 1] > 0 else { continue }
            result.append(Fn(src: src, name: t[i].text, nameIdx: i, open: close + 1, close: src.match[close + 1]))
        }
        fnCache[ObjectIdentifier(src)] = result
        return result
    }

    func function(containing idx: Int, in src: Src) -> Fn? {
        functions(of: src).first { $0.contains(idx) }
    }

    /// Resolves a called function: the caller's source first, then `lookup`.
    func resolve(_ name: String, from fn: Fn, at idx: Int) throws -> Fn {
        let local = functions(of: fn.src).filter { $0.name == name }
        if local.count == 1 { return local[0] }
        if local.isEmpty {
            var others: [Fn] = []
            for source in lookup(name) {
                let key = source.file + "\u{0}" + source.text
                let src = cache[key] ?? Src(file: source.file, text: source.text)
                cache[key] = src
                others += functions(of: src).filter { $0.name == name }
            }
            if others.count == 1 { return others[0] }
        }
        throw fail(fn, idx)
    }

    /// `resolve` that reports no match as nil.
    func tryResolve(_ name: String, from fn: Fn) -> Fn? {
        try? resolve(name, from: fn, at: fn.nameIdx)
    }

    // MARK: token helpers

    func text(_ src: Src, _ a: Int, _ b: Int) -> String {
        src.toks[a..<b].map(\.text).joined(separator: " ")
    }

    /// First index in a..<b at bracket depth 0 whose token is the punctuation `p`.
    func topLevel(_ src: Src, _ p: String, _ a: Int, _ b: Int) -> Int? {
        var k = a
        while k < b {
            let t = src.toks[k]
            if t.kind == .punct {
                if t.text == p { return k }
                if src.match[k] > k { k = src.match[k] + 1; continue }
            }
            k += 1
        }
        return nil
    }

    /// Index of the `;` ending the statement that contains `from` (or the enclosing closer).
    func endOfStatement(_ src: Src, _ from: Int, limit: Int) -> Int {
        var k = from
        while k < limit {
            let t = src.toks[k]
            if t.kind == .punct {
                if t.text == ";" { return k }
                if src.match[k] > k { k = src.match[k] + 1; continue }
                if t.text == ")" || t.text == "]" || t.text == "}" { return k }
            }
            k += 1
        }
        return limit
    }

    func insideBlockLiteral(_ src: Src, _ i: Int) -> Bool {
        var j = src.enclosing[i]
        while j >= 0 {
            if src.toks[j].text == "{", j > 0 {
                var k = j - 1
                if src.toks[k].text == ")", src.open[k] >= 0 { k = src.open[k] - 1 }
                // `^bool(args) {`: an explicit return type sits between the caret and the parameters.
                if k > 0, src.toks[k].kind == .ident, src.toks[k - 1].text == "^" { k -= 1 }
                if k >= 0, src.toks[k].text == "^" { return true }
            }
            j = src.enclosing[j]
        }
        return false
    }

    func isNil(_ src: Src, _ a: Int, _ b: Int) -> Bool {
        b - a == 1 && (src.toks[a].text == "nil" || src.toks[a].text == "NULL")
    }

    func isNilish(_ src: Src, _ a: Int, _ b: Int) -> Bool {
        let t = src.toks
        if b - a == 1 { return ["nil", "NULL", "NO", "YES", "0", "NSNull"].contains(t[a].text) || t[a].kind == .number }
        return b - a == 3 && t[a].text == "NSNull" && t[a + 2].text == "null"
    }

    // MARK: statement tree

    static func parseList(_ src: Src, _ from: Int, _ to: Int) -> [Node] {
        var nodes: [Node] = []
        var i = from
        while i < to {
            if src.toks[i].text == ";", src.toks[i].kind == .punct { i += 1; continue }
            let (node, next) = parseOne(src, i, to)
            nodes.append(node)
            i = max(next, i + 1)
        }
        return nodes
    }

    private static func parseOne(_ src: Src, _ i: Int, _ end: Int) -> (Node, Int) {
        let t = src.toks
        let tok = t[i]
        func header(_ at: Int) -> Int? {
            guard at < end, t[at].text == "(", src.match[at] > at else { return nil }
            return src.match[at]
        }
        if tok.kind == .punct, tok.text == "{", src.match[i] > i {
            let m = src.match[i]
            return (Node(.block, i..<(m + 1), parseList(src, i + 1, m)), m + 1)
        }
        if tok.kind == .ident {
            switch tok.text {
            case "if":
                if let h = header(i + 1), h + 1 < end {
                    let (then, n1) = parseOne(src, h + 1, end)
                    if n1 < end, t[n1].text == "else", n1 + 1 < end {
                        let (els, n2) = parseOne(src, n1 + 1, end)
                        return (Node(.ifelse, i..<n2, [then, els]), n2)
                    }
                    return (Node(.ifelse, i..<n1, [then]), n1)
                }
            case "for", "while":
                if let h = header(i + 1), h + 1 < end {
                    let (body, n) = parseOne(src, h + 1, end)
                    return (Node(.loop, i..<n, [body]), n)
                }
            case "do":
                let (body, n) = parseOne(src, i + 1, end)
                if n < end, t[n].text == "while", let h = header(n + 1) {
                    var next = h + 1
                    if next < end, t[next].text == ";" { next += 1 }
                    return (Node(.loop, i..<next, [body]), next)
                }
            case "switch":
                if let h = header(i + 1), h + 1 < end, t[h + 1].text == "{", src.match[h + 1] > h {
                    let m = src.match[h + 1]
                    return (Node(.switchStmt, i..<(m + 1)), m + 1)
                }
            case "@try":
                var children: [Node] = []
                var n = i + 1
                var blockStart = n
                while true {
                    guard blockStart < end, t[blockStart].text == "{", src.match[blockStart] > blockStart else { break }
                    let (block, after) = parseOne(src, blockStart, end)
                    children.append(block)
                    n = after
                    guard n < end, t[n].text == "@catch" || t[n].text == "@finally" else { break }
                    blockStart = n + 1
                    if t[n].text == "@catch", let h = header(n + 1) { blockStart = h + 1 }
                }
                return (Node(.trycatch, i..<n, children), n)
            case "@autoreleasepool":
                if i + 1 < end { return parseOne(src, i + 1, end) }
            default:
                break
            }
        }
        let e = Engine.statementEnd(src, i, end)
        let next = e < end && t[e].text == ";" ? e + 1 : max(e, i + 1)
        return (Node(.simple, i..<next), next)
    }

    private static func statementEnd(_ src: Src, _ from: Int, _ limit: Int) -> Int {
        var k = from
        while k < limit {
            let t = src.toks[k]
            if t.kind == .punct {
                if t.text == ";" { return k }
                if src.match[k] > k { k = src.match[k] + 1; continue }
            }
            k += 1
        }
        return limit
    }

    // MARK: running a function

    func run(_ fn: Fn, _ mode: NativeMode) throws -> KeyMap {
        switch mode {
        case .writer:
            let sets = try writtenSets(fn)
            if sets.isEmpty { throw fail(fn, fn.nameIdx) }
            return KeyMerge.union(sets)
        case .produce:
            let key = fn.src.file + "#" + fn.name
            if visiting.contains(key) { return [:] }
            visiting.insert(key)
            defer { visiting.remove(key) }
            let src = fn.src
            var sets: [KeyMap] = []
            for i in (fn.open + 1)..<fn.close where src.toks[i].text == "return" && src.toks[i].kind == .ident {
                if insideBlockLiteral(src, i) { continue }
                let e = endOfStatement(src, i + 1, limit: fn.close)
                if e == i + 1 || isNilish(src, i + 1, e) { continue }
                sets.append(try keys(fn, i + 1, e, use: i))
            }
            if sets.isEmpty { sets = try writtenSets(fn) }
            if sets.isEmpty { throw fail(fn, fn.nameIdx) }
            return KeyMerge.union(sets)
        }
    }

    /// Key sets of the receivers of `[x writeToFile:...]` inside the function.
    func writtenSets(_ fn: Fn) throws -> [KeyMap] {
        var sets: [KeyMap] = []
        for idx in writes(fn.src) where fn.contains(idx) {
            let s = fn.src.enclosing[idx]
            sets.append(try keys(fn, s + 1, idx, use: idx))
        }
        return sets
    }

    func writes(_ src: Src) -> [Int] {
        src.toks.indices.filter {
            src.toks[$0].text == "writeToFile" && $0 + 1 < src.toks.count && src.toks[$0 + 1].text == ":"
                && src.enclosing[$0] >= 0 && src.toks[src.enclosing[$0]].text == "["
        }
    }

    /// Text of the first argument of the message whose keyword is at `idx`.
    func firstArgument(_ src: Src, _ idx: Int) -> String {
        let s = src.enclosing[idx]
        let end = src.match[s] > 0 ? src.match[s] : src.toks.count
        var stop = end
        var k = idx + 2
        while k < end {
            if src.enclosing[k] == s, src.toks[k].kind == .ident, k + 1 < end, src.toks[k + 1].text == ":" { stop = k; break }
            k += 1
        }
        return text(src, idx + 2, stop)
    }

    // MARK: expressions

    func keys(_ fn: Fn, _ lo: Int, _ hi: Int, use: Int) throws -> KeyMap {
        let src = fn.src
        let t = src.toks
        var a = lo
        let b = hi
        guard a < b else { throw fail(fn, max(0, min(a, t.count - 1))) }

        // `c ? x : y` and `x ?: y`: a literal on either side counts.
        if let q = topLevel(src, "?", a, b) {
            let elvis = q + 1 < b && t[q + 1].text == ":"
            var sides: [(Int, Int)]
            if elvis {
                sides = [(a, q), (q + 2, b)]
            } else if let colon = topLevel(src, ":", q + 1, b) {
                sides = [(q + 1, colon), (colon + 1, b)]
            } else {
                throw fail(fn, q)
            }
            var sets: [KeyMap] = []
            var firstFailure: Unresolvable?
            for (x, y) in sides where x < y && !isNilish(src, x, y) {
                do { sets.append(try keys(fn, x, y, use: use)) } catch let error as Unresolvable {
                    firstFailure = firstFailure ?? error
                }
            }
            if sets.isEmpty { throw firstFailure ?? fail(fn, q) }
            return KeyMerge.union(sets)
        }

        // Parentheses and casts.
        while t[a].text == "(", t[a].kind == .punct, src.match[a] > a {
            let m = src.match[a]
            if m == b - 1 { return try keys(fn, a + 1, b - 1, use: use) }
            let inner = t[(a + 1)..<m]
            if m + 1 < b, !inner.isEmpty, inner.allSatisfy({ $0.kind == .ident || $0.text == "*" }) { a = m + 1; continue }
            break
        }

        // `@{...}` literal.
        if t[a].text == "@{", src.match[a] == b - 1 {
            var result: KeyMap = [:]
            var s = a + 1
            while s < b - 1 {
                let e = topLevel(src, ",", s, b - 1) ?? (b - 1)
                guard t[s].kind == .objcString, s + 1 < e, t[s + 1].text == ":" else { throw fail(fn, s) }
                let value = inferType(fn, s + 2, e)
                KeyMerge.merge(&result, name: t[s].text, type: value.type, presence: .required, nullable: value.nullable)
                s = e + 1
            }
            return result
        }

        // Message send.
        if t[a].text == "[", src.match[a] == b - 1 { return try messageKeys(fn, a, b, use: use) }

        // Variable.
        if b - a == 1, t[a].kind == .ident, !reserved.contains(t[a].text) {
            return try variableKeys(fn, t[a].text, at: a, use: use)
        }

        // `v.copy` / `v.mutableCopy` (property form) is the variable itself.
        if b - a == 3, t[a].kind == .ident, !reserved.contains(t[a].text), t[a + 1].text == ".",
           ["copy", "mutableCopy", "bytes"].contains(t[a + 2].text) {
            return try variableKeys(fn, t[a].text, at: a, use: use)
        }

        // Call: bridge wrappers pass through; anything else is followed.
        if t[a].kind == .ident, a + 1 < b, t[a + 1].text == "(", src.match[a + 1] == b - 1 {
            if wrappers.contains(t[a].text) {
                let end = topLevel(src, ",", a + 2, b - 1) ?? (b - 1)
                return try keys(fn, a + 2, end, use: use)
            }
            // `f(^{ return g(); })`: the result is what the block returns.
            if blockWrappers.contains(t[a].text), let caret = (a + 2..<b - 1).first(where: { t[$0].text == "^" }),
               let open = (caret..<b - 1).first(where: { t[$0].text == "{" }), src.match[open] > open {
                var sets: [KeyMap] = []
                for i in open..<src.match[open] where t[i].text == "return" && t[i].kind == .ident {
                    let e = endOfStatement(src, i + 1, limit: src.match[open])
                    if e == i + 1 || isNilish(src, i + 1, e) { continue }
                    sets.append(try keys(fn, i + 1, e, use: i))
                }
                if sets.isEmpty { throw fail(fn, a) }
                return KeyMerge.union(sets)
            }
            let callee = try resolve(t[a].text, from: fn, at: a)
            return try run(callee, .produce)
        }
        throw fail(fn, a)
    }

    /// The receiver start and selector index of the message send `[recv selector ...]` in a..<b.
    func messageParts(_ src: Src, _ a: Int, _ b: Int) -> (recvStart: Int, selector: Int)? {
        let t = src.toks
        let e = b - 1
        var r = a + 1
        guard r < e else { return nil }
        let recvStart = r
        if t[r].text == "[" || t[r].text == "(" || t[r].text == "@{" {
            guard src.match[r] > r else { return nil }
            r = src.match[r] + 1
        } else if t[r].kind == .ident {
            r += 1
            if r < e, t[r].text == "(", src.match[r] > r {
                r = src.match[r] + 1
            } else {
                while r + 1 < e, t[r].text == "." || t[r].text == "->", t[r + 1].kind == .ident { r += 2 }
                // `dict[key] selector`: subscripts belong to the receiver.
                while r < e, t[r].text == "[", src.match[r] > r { r = src.match[r] + 1 }
            }
        } else {
            return nil
        }
        guard r < e, t[r].kind == .ident else { return nil }
        return (recvStart, r)
    }

    private func messageKeys(_ fn: Fn, _ a: Int, _ b: Int, use: Int) throws -> KeyMap {
        let src = fn.src
        let t = src.toks
        let e = b - 1
        guard let parts = messageParts(src, a, b) else { throw fail(fn, a) }
        let (recvStart, r) = parts
        let selector = t[r].text
        let receiver = text(src, recvStart, r)
        let bare = r + 1 == e
        let argStart = r + 2
        switch selector {
        case "mutableCopy" where bare, "copy" where bare:
            return try keys(fn, recvStart, r, use: use)
        case "init" where bare && receiver.contains("alloc") && dictClasses.contains(where: receiver.contains):
            return [:]
        case "dictionary", "new":
            if bare, dictClasses.contains(receiver) { return [:] }
        case "dictionaryWithCapacity", "initWithCapacity":
            if receiver.contains("Dictionary") { return [:] }
        case "dataWithJSONObject" where receiver == "NSJSONSerialization":
            // The serialized value is the result (rule 6, `strndup(json.bytes, ...)`).
            let labelled = (argStart..<e).first { src.enclosing[$0] == a && t[$0].kind == .ident && t[$0 + 1].text == ":" }
            return try keys(fn, argStart, labelled ?? e, use: use)
        case "dictionaryWithDictionary", "initWithDictionary":
            if argStart < e { return try keys(fn, argStart, e, use: use) }
        case "dictionaryWithContentsOfFile", "initWithContentsOfFile":
            if argStart < e { return try plistKeys(fn, path: text(src, argStart, e), at: a) }
        default:
            break
        }
        throw fail(fn, a)
    }

    /// A dictionary read from a plist takes the key set of every dictionary written to
    /// the same path expression in this source.
    private func plistKeys(_ fn: Fn, path: String, at idx: Int) throws -> KeyMap {
        let src = fn.src
        let guardKey = src.file + "|" + path
        if visiting.contains(guardKey) { return [:] }
        visiting.insert(guardKey)
        defer { visiting.remove(guardKey) }
        var sets: [KeyMap] = []
        for w in writes(src) where firstArgument(src, w) == path {
            guard let owner = function(containing: w, in: src) else { continue }
            sets.append(try keys(owner, src.enclosing[w] + 1, w, use: w))
        }
        // A path constant names the same file in every source: writers elsewhere count too.
        if let literal = pathLiteral(src, path) {
            for source in lookup(literal) where source.file != src.file {
                let key = source.file + "\u{0}" + source.text
                let other = cache[key] ?? Src(file: source.file, text: source.text)
                cache[key] = other
                for w in writes(other) where pathLiteral(other, firstArgument(other, w)) == literal {
                    guard let owner = function(containing: w, in: other) else { continue }
                    sets.append(try keys(owner, other.enclosing[w] + 1, w, use: w))
                }
            }
        }
        if sets.isEmpty { throw fail(fn, idx) }
        return KeyMerge.union(sets)
    }

    /// The path an argument names: a literal, or `static NSString *const name = @"literal";` at file scope.
    private func pathLiteral(_ src: Src, _ name: String) -> String? {
        if name.contains("/") { return name }  // the argument is the literal itself
        let t = src.toks
        guard let i = t.indices.first(where: {
            t[$0].kind == .ident && t[$0].text == name && src.enclosing[$0] == -1 && $0 + 2 < t.count
                && t[$0 + 1].text == "=" && t[$0 + 2].kind == .objcString
        }) else { return nil }
        return t[i + 2].text
    }

    // MARK: variables

    private func variableKeys(_ fn: Fn, _ name: String, at idx: Int, use: Int) throws -> KeyMap {
        let src = fn.src
        let t = src.toks
        // Every `name = e;` before the use: declarations and plain re-assignments.
        var binds: [Int] = []
        for p in (fn.open + 1)..<min(use, fn.close) where t[p].kind == .ident && t[p].text == name
            && p + 1 < fn.close && t[p + 1].text == "=" {
            if t[p - 1].text == "." || t[p - 1].text == "->" { continue }
            binds.append(p)
        }
        // An unconditional (top-level) re-assignment discards the earlier values.
        if let last = binds.last(where: { p in fn.tree.contains { $0.kind == .simple && $0.range.contains(p) } }) {
            binds = binds.filter { $0 >= last }
        }
        guard let d = binds.first else { throw fail(fn, idx) }
        if binds.count == 1 {
            let initEnd = endOfStatement(src, d + 2, limit: fn.close)
            var result = try keys(fn, d + 2, initEnd, use: d)
            let assigns = try assignments(fn, name, from: d, to: use)
            let definite = definiteKeys(fn, declaration: d, use: use, assigns)
            for assign in assigns {
                let value = inferType(fn, assign.value.lowerBound, assign.value.upperBound)
                KeyMerge.merge(&result, name: assign.key, type: value.type,
                               presence: definite.contains(assign.key) ? .required : .optional, nullable: value.nullable)
            }
            return result
        }
        // Several bindings (`= nil`, then assigned in @try/@catch or branches): union of the values.
        let live = binds.filter { !isNil(src, $0 + 2, endOfStatement(src, $0 + 2, limit: fn.close)) }
        guard !live.isEmpty else { throw fail(fn, idx) }
        var sets: [KeyMap] = []
        for p in live {
            sets.append(try keys(fn, p + 2, endOfStatement(src, p + 2, limit: fn.close), use: p))
        }
        var result = KeyMerge.union(sets)
        for assign in try assignments(fn, name, from: d, to: use) {
            let value = inferType(fn, assign.value.lowerBound, assign.value.upperBound)
            KeyMerge.merge(&result, name: assign.key, type: value.type, presence: .optional, nullable: value.nullable)
        }
        return result
    }

    /// `v[@"k"] = e` and `[v setObject:e forKey:@"k"]` between the declaration and the use.
    private func assignments(_ fn: Fn, _ name: String, from d: Int, to use: Int) throws -> [Assign] {
        let src = fn.src
        let t = src.toks
        var result: [Assign] = []
        let upper = min(use, fn.close)
        for i in (d + 1)..<max(d + 1, upper) where t[i].kind == .ident && t[i].text == name {
            if t[i - 1].text == "." || t[i - 1].text == "->" { continue }
            if i + 1 < fn.close, t[i + 1].text == "[", src.match[i + 1] > 0, src.match[i + 1] + 1 < fn.close,
               t[src.match[i + 1] + 1].text == "=" {
                let close = src.match[i + 1]
                guard close == i + 3, t[i + 2].kind == .objcString else { throw fail(fn, i) }
                let vlo = close + 2
                let vhi = endOfStatement(src, vlo, limit: fn.close)
                if !isNil(src, vlo, vhi) {
                    result.append(Assign(key: t[i + 2].text, value: vlo..<vhi, pos: i))
                }
            } else if i > 0, t[i - 1].text == "[", i + 1 < fn.close, t[i + 1].kind == .ident {
                let sel = t[i + 1].text
                let s = i - 1
                switch sel {
                case "setObject", "setValue":
                    guard let f = (i + 2..<fn.close).first(where: {
                        src.enclosing[$0] == s && t[$0].text == "forKey" && t[$0 + 1].text == ":"
                    }), src.match[s] == f + 3, t[f + 2].kind == .objcString else { throw fail(fn, i) }
                    let vlo = i + 3
                    if !isNil(src, vlo, f) {
                        result.append(Assign(key: t[f + 2].text, value: vlo..<f, pos: i))
                    }
                case "removeObjectForKey", "removeAllObjects", "addEntriesFromDictionary", "setDictionary",
                     "setValuesForKeysWithDictionary", "removeObjectsForKeys":
                    throw fail(fn, i)
                default:
                    break
                }
            }
        }
        return result
    }

    /// Keys assigned on every path from the declaration to the use (design rule 8).
    private func definiteKeys(_ fn: Fn, declaration d: Int, use: Int, _ assigns: [Assign]) -> Set<String> {
        guard let (list, index) = findSequence(fn.tree, d) else { return [] }
        return sequenceDefs(fn, Array(list[(index + 1)...]), use, assigns)
    }

    private func findSequence(_ nodes: [Node], _ d: Int) -> ([Node], Int)? {
        for (i, node) in nodes.enumerated() {
            if node.kind == .simple && node.range.contains(d) { return (nodes, i) }
            if node.range.contains(d), let found = findSequence(node.children, d) { return found }
        }
        return nil
    }

    private func sequenceDefs(_ fn: Fn, _ nodes: [Node], _ use: Int, _ assigns: [Assign]) -> Set<String> {
        var out = Set<String>()
        var exited = false
        for node in nodes {
            if node.range.lowerBound >= use || node.range.contains(use) { break }
            if !exited { out.formUnion(nodeDefs(fn, node, use, assigns)) }
            if node.kind == .simple, fn.src.toks[node.range.lowerBound].text == "return" { break }
            if hasValueReturn(fn, node.range) { exited = true }
        }
        return out
    }

    private func nodeDefs(_ fn: Fn, _ node: Node, _ use: Int, _ assigns: [Assign]) -> Set<String> {
        switch node.kind {
        case .simple:
            return Set(assigns.filter { node.range.contains($0.pos) && !nestedBrace(fn.src, $0.pos, node.range.lowerBound) }.map(\.key))
        case .block:
            return sequenceDefs(fn, node.children, use, assigns)
        case .ifelse where node.children.count == 2:
            return nodeDefs(fn, node.children[0], use, assigns).intersection(nodeDefs(fn, node.children[1], use, assigns))
        default:
            return []
        }
    }

    private func nestedBrace(_ src: Src, _ pos: Int, _ start: Int) -> Bool {
        var j = src.enclosing[pos]
        while j >= start {
            if src.toks[j].text == "{" { return true }
            j = src.enclosing[j]
        }
        return false
    }

    private func hasValueReturn(_ fn: Fn, _ range: Range<Int>) -> Bool {
        let src = fn.src
        for i in range where src.toks[i].text == "return" && src.toks[i].kind == .ident && !insideBlockLiteral(src, i) {
            let e = endOfStatement(src, i + 1, limit: fn.close)
            if e > i + 1 && !isNilish(src, i + 1, e) { return true }
        }
        return false
    }

    // MARK: type inference (REQ-RPC-007)

    /// A value's type and whether it is `NSNull` on some path (null-only is `(.null, true)`).
    typealias Inferred = (type: KeyType, nullable: Bool)

    func inferType(_ fn: Fn, _ lo: Int, _ hi: Int) -> Inferred {
        let src = fn.src
        let t = src.toks
        var a = lo
        let b = hi
        guard a < b else { return (.any, false) }
        if let narrowed = narrowed(fn, lo, hi) { return (narrowed, false) }
        if let q = topLevel(src, "?", a, b) {
            let elvis = q + 1 < b && t[q + 1].text == ":"
            if elvis { return KeyMerge.unify(inferType(fn, a, q), inferType(fn, q + 2, b), integersAreNumbers: true) }
            if let colon = topLevel(src, ":", q + 1, b) {
                // `[v isKindOfClass:C.class] ? v : w`: the condition types the value.
                let whenTrue = classGuard(src, a, q, value: text(src, q + 1, colon)).map { ($0, false) }
                    ?? inferType(fn, q + 1, colon)
                return KeyMerge.unify(whenTrue, inferType(fn, colon + 1, b), integersAreNumbers: true)
            }
            return (.any, false)
        }
        while t[a].text == "(", src.match[a] > a {
            let m = src.match[a]
            if m == b - 1 { return inferType(fn, a + 1, b - 1) }
            let inner = t[(a + 1)..<m]
            if m + 1 < b, !inner.isEmpty, inner.allSatisfy({ $0.kind == .ident || $0.text == "*" }) { a = m + 1; continue }
            break
        }
        // C comparisons and logic yield `int`, so a boxed one is an integer; arithmetic takes the operands' numeric type.
        for op in ["&&", "||", "==", "!=", "<=", ">=", "<", ">"] where topLevel(src, op, a + 1, b) != nil {
            return (.integer, false)
        }
        if t[a].text == "!", t[a].kind == .punct { return (.integer, false) }
        if t[a].kind == .punct, t[a].text == "-" || t[a].text == "+", a + 1 < b { return inferType(fn, a + 1, b) }
        var operands: [(Int, Int)] = []
        var start = a
        // The first token may open a group (`@(...)`, `[...]`, a cast): scan after it.
        var k = t[a].kind == .punct && src.match[a] > a ? src.match[a] + 1 : a + 1
        while k < b {
            let tok = t[k]
            if tok.kind == .punct {
                if ["+", "-", "*", "/", "%"].contains(tok.text), k > start { operands.append((start, k)); start = k + 1 }
                else if src.match[k] > k { k = src.match[k] }
            }
            k += 1
        }
        if !operands.isEmpty {
            operands.append((start, b))
            let types = operands.map { $0.0 < $0.1 ? inferType(fn, $0.0, $0.1).type : .any }
            if types.allSatisfy({ $0 == .integer || $0 == .number }) {
                return (types.contains(.number) ? .number : .integer, false)
            }
            return (.any, false)
        }
        // `NSNull.null` and `[NSNull null]`.
        if b - a == 3, t[a].text == "NSNull", t[a + 1].text == ".", t[a + 2].text == "null" { return (.null, true) }
        if b - a == 4, t[a].text == "[", t[a + 1].text == "NSNull", t[a + 2].text == "null", t[a + 3].text == "]" {
            return (.null, true)
        }
        let first = t[a]
        let single = b - a == 1
        switch first.kind {
        case .objcString: return (single ? .string : .any, false)
        case .boxed: return (single ? numberType(first.text) : .any, false)
        case .number: return (single ? numberType(first.text) : .any, false)
        default: break
        }
        if first.kind == .ident, single {
            switch first.text {
            case "@YES", "@NO", "@true", "@false", "YES", "NO", "true", "false": return (.boolean, false)
            default: return inferName(fn, first.text)
            }
        }
        // `base.member` and `base->member`: a declared member, a count or length, an exception's name.
        if let chain = memberChain(src, a, b), let sdk = sdkChainType(fn, chain) { return (sdk, false) }
        // `array.firstObject[@"k"]`: the value the dictionaries added to `array` carry under `k`.
        if let element = elementValue(fn, a, b) { return element }
        if let table = tableValue(fn, a, b) { return table }
        if let chain = memberChain(src, a, b), chain.count > 2 {
            // `base.a.count` and `base->a.b`: the last member decides.
            let last = chain[chain.count - 1]
            if last == "count" || last == "length" { return (.integer, false) }
            if let known = foundationSelectors[last] { return (known, false) }
        }
        if b - a == 3, first.kind == .ident, t[a + 1].text == "." || t[a + 1].text == "->", t[a + 2].kind == .ident {
            let member = t[a + 2].text
            let declared = declarations(src, member, in: 0..<t.count, outside: functions(of: src)).map { typeFor($0.words, pointer: $0.pointer) }
            if let known = declared.first, declared.allSatisfy({ $0 == known }) { return (known, false) }
            if let words = declarations(src, first.text, in: (fn.nameIdx + 1)..<fn.close).first?.words, words.count == 1,
               let field = ctypes.field(words[0], member), field.key != .any {
                return (field.key, false)
            }
            if member == "count" || member == "length" { return (.integer, false) }
            if let known = foundationSelectors[member] { return (known, false) }
            if member == "name" || member == "reason",
               declarations(src, first.text, in: (fn.nameIdx + 1)..<fn.close).contains(where: { $0.words.last == "NSException" }) {
                return (.string, false)
            }
            return (.any, false)
        }
        // A call of a function whose declaration gives the return type.
        if first.kind == .ident, !reserved.contains(first.text), a + 1 < b, t[a + 1].text == "(", t[a + 1].kind == .punct,
           src.match[a + 1] == b - 1 {
            if let callee = tryResolve(first.text, from: fn) { return (returnType(callee), false) }
            if first.text == "MAX" || first.text == "MIN" { return extremum(fn, a + 1, b - 1) }
            if let block = blockReturnType(fn, first.text) { return (block, false) }
            return (.any, false)
        }
        if first.text == "@{", src.match[a] == b - 1 { return (.object, false) }
        if first.text == "@[", src.match[a] == b - 1 { return (.array, false) }
        if first.text == "@(", src.match[a] == b - 1 { return (boxedType(fn, a + 1, b - 1), false) }
        if first.text == "[", src.match[a] == b - 1, a + 2 < b {
            // `[[NSMutableArray alloc] init]`: the allocated class decides.
            if t[a + 1].text == "[", src.match[a + 1] > a + 1, a + 3 < b {
                let cls = t[a + 2].text
                if t[a + 3].text == "alloc" {
                    if let known = CTypes.objectiveC[cls] { return (known, false) }
                }
            }
            if t[a + 1].kind == .ident, t[a + 2].kind == .ident {
                let receiver = t[a + 1].text
                let selector = t[a + 2].text
                if let known = CTypes.objectiveC[receiver] { return (known, false) }
                if receiver == "NSNumber" {
                    if selector.hasPrefix("numberWithBool") { return (.boolean, false) }
                    if selector.hasPrefix("numberWithDouble") || selector.hasPrefix("numberWithFloat") { return (.number, false) }
                    if selector.hasPrefix("numberWithInt") || selector.hasPrefix("numberWithLong")
                        || selector.hasPrefix("numberWithUnsigned") || selector.hasPrefix("numberWithShort") { return (.integer, false) }
                }
            }
            // A selector declared in this file, or a Foundation selector with a fixed result type.
            if let parts = messageParts(src, a, b) {
                let selector = t[parts.selector].text
                let declared = selectorTypes(src, selector)
                if let known = declared.first, declared.allSatisfy({ $0 == known }) { return (known, false) }
                if declared.isEmpty, let known = foundationSelectors[selector] { return (known, false) }
            }
        }
        return (.any, false)
    }

    private func numberType(_ text: String) -> KeyType {
        let lower = text.lowercased()
        if lower.hasPrefix("0x") { return .integer }
        return lower.contains(".") || lower.contains("e") ? .number : .integer
    }

    /// `@(expr)`: a cast or a typed variable decides; anything else is `any`.
    private func boxedType(_ fn: Fn, _ lo: Int, _ hi: Int) -> KeyType {
        let src = fn.src
        let t = src.toks
        guard lo < hi else { return .any }
        if t[lo].text == "(", src.match[lo] > lo, src.match[lo] < hi - 1 {
            let inner = Array(t[(lo + 1)..<src.match[lo]])
            if !inner.isEmpty, inner.allSatisfy({ $0.kind == .ident || $0.text == "*" }) {
                return typeFor(inner.filter { $0.kind == .ident }.map(\.text), pointer: inner.contains { $0.text == "*" })
            }
        }
        if hi - lo == 1 {
            if t[lo].kind == .number { return numberType(t[lo].text) }
            if t[lo].kind == .ident { return declaredType(fn, t[lo].text) }
        }
        let value = inferType(fn, lo, hi)
        return value.type == .null ? .any : value.type
    }

    private func typeFor(_ idents: [String], pointer: Bool) -> KeyType {
        if pointer {
            let last = idents.last { !CTypes.qualifiers.contains($0) }
            if let last, let known = CTypes.objectiveC[last] { return known }
            return last == "char" ? .string : .any  // `@(cString)` boxes to an NSString
        }
        return CTypes.key(idents, pointer: false)
    }

    /// The type words of the declaration whose declarator list contains the comma at `comma`
    /// (`NSMutableArray *a = [NSMutableArray array], *b = ...;`); nil when it is not a declaration.
    private func declarationWords(_ src: Src, comma: Int) -> [String]? {
        let t = src.toks
        let level = src.enclosing[comma]
        var k = comma - 1
        while k >= 0, k != level {
            if src.enclosing[k] == level, [";", "{", "}"].contains(t[k].text), t[k].kind == .punct { break }
            k -= 1
        }
        var s = k + 1
        var words: [String] = []
        while s < comma, t[s].kind == .ident, !reserved.contains(t[s].text) { words.append(t[s].text); s += 1 }
        guard s < comma, t[s].text == "*" || t[s].text == "=" || t[s].text == "," else { return nil }
        if t[s].text != "*" { words = Array(words.dropLast()) }
        return words.isEmpty ? nil : words
    }

    /// `a.b->c` as `[a, b, c]` when the tokens a..<b are exactly such a chain.
    private func memberChain(_ src: Src, _ a: Int, _ b: Int) -> [String]? {
        let t = src.toks
        guard (b - a) % 2 == 1, b - a >= 3, t[a].kind == .ident, !reserved.contains(t[a].text) else { return nil }
        var names = [t[a].text]
        var k = a + 1
        while k < b {
            guard t[k].kind == .punct, t[k].text == "." || t[k].text == "->", t[k + 1].kind == .ident else { return nil }
            names.append(t[k + 1].text)
            k += 2
        }
        return names
    }

    /// The scalar type of an SDK property chain such as `location.coordinate.latitude` or
    /// `NSProcessInfo.processInfo.systemUptime` (the head is a class name or a local of an SDK class).
    private func sdkChainType(_ fn: Fn, _ chain: [String]) -> KeyType? {
        var current: String
        if sdkMembers[chain[0]] != nil {
            current = chain[0]
        } else if let words = declarations(fn.src, chain[0], in: (fn.nameIdx + 1)..<fn.close).first?.words,
                  let last = words.last, sdkMembers[last] != nil {
            current = last
        } else {
            return nil
        }
        for (i, member) in chain.dropFirst().enumerated() {
            guard let next = sdkMembers[current]?[member] else { return nil }
            if i == chain.count - 2 { return KeyType(rawValue: next) }
            guard sdkMembers[next] != nil else { return nil }
            current = next
        }
        return nil
    }

    /// `array.firstObject[@"k"]` and `[array lastObject][@"k"]`: the type of `k` in the dictionaries
    /// that `[array addObject:@{...}]` adds. Nil when the array gets elements any other way.
    private func elementValue(_ fn: Fn, _ a: Int, _ b: Int) -> Inferred? {
        let src = fn.src
        let t = src.toks
        let name: String, key: String
        if b - a == 6, t[a].kind == .ident, t[a + 1].text == ".", ["firstObject", "lastObject"].contains(t[a + 2].text),
           t[a + 3].text == "[", src.match[a + 3] == a + 5, t[a + 4].kind == .objcString {
            name = t[a].text
            key = t[a + 4].text
        } else if b - a == 7, t[a].text == "[", src.match[a] == a + 3, t[a + 1].kind == .ident,
                  ["firstObject", "lastObject"].contains(t[a + 2].text), t[a + 4].text == "[",
                  src.match[a + 4] == a + 6, t[a + 5].kind == .objcString {
            name = t[a + 1].text
            key = t[a + 5].text
        } else {
            return nil
        }
        var result: Inferred?
        for i in (fn.open + 1)..<fn.close where t[i].text == "[" && src.match[i] > i && i + 3 < fn.close
            && t[i + 1].text == name && t[i + 2].text == "addObject" && t[i + 3].text == ":" {
            guard let set = try? keys(fn, i + 4, src.match[i], use: i), let found = set[key] else { return nil }
            let value: Inferred = (found.type, found.nullable)
            result = result.map { KeyMerge.unify($0, value, integersAreNumbers: true) } ?? value
        }
        return result
    }

    /// `spec[@"id"]` where every dictionary `spec` can hold comes from the elements of a function's
    /// `@[...]` table (a `for (T spec in table())` variable, an assignment of one, or a parameter every
    /// call site passes one to): the type the table's entries give the key.
    private func tableValue(_ fn: Fn, _ a: Int, _ b: Int) -> Inferred? {
        let t = fn.src.toks
        guard b - a == 4, t[a].kind == .ident, t[a + 1].text == "[", fn.src.match[a + 1] == a + 3,
              t[a + 2].kind == .objcString, let sets = tableProducers(fn, t[a].text, depth: 0), !sets.isEmpty else { return nil }
        var result: Inferred?
        for set in sets {
            guard let found = set[t[a + 2].text] else { return nil }
            let value: Inferred = (found.type, found.nullable)
            result = result.map { KeyMerge.unify($0, value, integersAreNumbers: true) } ?? value
        }
        return result
    }

    private func tableProducers(_ fn: Fn, _ name: String, depth: Int) -> [KeyMap]? {
        guard depth < 4 else { return nil }
        let src = fn.src
        let t = src.toks
        var sets: [KeyMap] = []
        var bound = false
        for i in (fn.open + 1)..<fn.close where t[i].kind == .ident && t[i].text == name && i + 1 < fn.close {
            if t[i + 1].text == "in", i + 4 < fn.close, t[i + 2].kind == .ident, t[i + 3].text == "(", t[i + 4].text == ")" {
                guard let table = tableEntries(fn, t[i + 2].text) else { return nil }
                sets += table
                bound = true
            } else if t[i + 1].text == "=", t[i - 1].text != ".", t[i - 1].text != "->" {
                let end = endOfStatement(src, i + 2, limit: fn.close)
                if isNil(src, i + 2, end) { continue }
                guard end == i + 3, t[i + 2].kind == .ident, let inner = tableProducers(fn, t[i + 2].text, depth: depth + 1)
                else { return nil }
                sets += inner
                bound = true
            }
        }
        if bound { return sets }
        // A parameter: the argument of every call in this source.
        guard t[fn.nameIdx + 1].text == "(", fn.nameIdx + 1 < src.match.count else { return nil }
        let close = src.match[fn.nameIdx + 1]
        var index = 0
        var position: Int?
        var s = fn.nameIdx + 2
        while s < close {
            let e = topLevel(src, ",", s, close) ?? close
            if (s..<e).contains(where: { t[$0].kind == .ident && t[$0].text == name }), t[e - 1].text == name { position = index }
            index += 1
            s = e + 1
        }
        guard let position else { return nil }
        var calls = 0
        for i in t.indices where t[i].kind == .ident && t[i].text == fn.name && i + 1 < t.count && t[i + 1].text == "("
            && src.match[i + 1] > i && !(fn.nameIdx == i) {
            guard let caller = function(containing: i, in: src) else { return nil }
            var from = i + 2
            var arg = 0
            let end = src.match[i + 1]
            var range: Range<Int>?
            while from <= end {
                let e = topLevel(src, ",", from, end) ?? end
                if arg == position { range = from..<e; break }
                arg += 1
                from = e + 1
            }
            guard let range, range.count == 1, t[range.lowerBound].kind == .ident,
                  let inner = tableProducers(caller, t[range.lowerBound].text, depth: depth + 1) else { return nil }
            sets += inner
            calls += 1
        }
        return calls > 0 ? sets : nil
    }

    /// The key sets of the entries of the `@[...]` a function stores in the array it returns.
    private func tableEntries(_ fn: Fn, _ function: String) -> [KeyMap]? {
        guard let table = tryResolve(function, from: fn) else { return nil }
        let src = table.src
        let t = src.toks
        var names: Set<String> = []
        for i in (table.open + 1)..<table.close where t[i].text == "return" && t[i].kind == .ident
            && i + 2 < table.close && t[i + 1].kind == .ident && t[i + 2].text == ";" {
            names.insert(t[i + 1].text)
        }
        var sets: [KeyMap] = []
        for i in (table.open + 1)..<table.close where t[i].kind == .ident && names.contains(t[i].text)
            && i + 2 < table.close && t[i + 1].text == "=" && t[i + 2].text == "@[" {
            let end = src.match[i + 2]
            var s = i + 3
            while s < end {
                let e = topLevel(src, ",", s, end) ?? end
                if s < e {
                    guard let set = try? keys(table, s, e, use: i) else { return nil }
                    sets.append(set)
                }
                s = e + 1
            }
        }
        return sets.isEmpty ? nil : sets
    }

    /// An `NSNumber` local that only ever holds a CFBoolean: each binding is `CFGetTypeID(v) == CFBooleanGetTypeID() ? x : nil`
    /// (the other branch nil, the check not under `||`) or a call to a function returning such a local.
    private func isCFBoolean(_ fn: Fn, _ name: String, depth: Int) -> Bool {
        guard depth < 3 else { return false }
        let src = fn.src
        let t = src.toks
        var bindings = 0
        for i in (fn.open + 1)..<fn.close where t[i].kind == .ident && t[i].text == name && i + 1 < fn.close
            && t[i + 1].text == "=" && t[i - 1].text != "." && t[i - 1].text != "->" {
            let a = i + 2
            let end = endOfStatement(src, a, limit: fn.close)
            guard a < end else { return false }
            bindings += 1
            if isNil(src, a, end) { continue }
            if t[a].kind == .ident, a + 1 < end, t[a + 1].text == "(", src.match[a + 1] == end - 1,
               let callee = tryResolve(t[a].text, from: fn) {
                let names = (callee.open + 1..<callee.close).compactMap { r -> String? in
                    guard callee.src.toks[r].text == "return", r + 2 < callee.close,
                          callee.src.toks[r + 2].text == ";", callee.src.toks[r + 1].kind == .ident else { return nil }
                    return callee.src.toks[r + 1].text
                }
                guard !names.isEmpty, names.allSatisfy({ isCFBoolean(callee, $0, depth: depth + 1) }) else { return false }
                continue
            }
            guard let q = topLevel(src, "?", a, end), let colon = topLevel(src, ":", q + 1, end),
                  topLevel(src, "||", a, q) == nil, isNil(src, colon + 1, end) else { return false }
            let cond = (a..<q).map { t[$0].text }
            guard let g = cond.firstIndex(of: "CFGetTypeID"), g + 4 < cond.count, cond[g + 1] == "(",
                  let close = cond[(g + 1)...].firstIndex(of: ")"), close + 3 < cond.count, cond[close + 1] == "==",
                  cond[close + 2] == "CFBooleanGetTypeID" else { return false }
        }
        return bindings > 0
    }

    /// The return type of a call through a block variable declared `T (^name)(...)`.
    private func blockReturnType(_ fn: Fn, _ name: String) -> KeyType? {
        let src = fn.src
        let t = src.toks
        for p in (fn.open + 1)..<fn.close where t[p].text == name && p >= 3 && t[p - 1].text == "^" && t[p - 2].text == "(" {
            var words: [String] = []
            var j = p - 3
            while j >= 0, t[j].kind == .ident, !reserved.contains(t[j].text) { words.insert(t[j].text, at: 0); j -= 1 }
            if !words.isEmpty { return typeFor(words, pointer: false) }
        }
        return nil
    }

    /// `MAX(a, b)` / `MIN(a, b)`: numeric when every argument is.
    private func extremum(_ fn: Fn, _ open: Int, _ close: Int) -> Inferred {
        let src = fn.src
        var types: [KeyType] = []
        var start = open + 1
        while start <= close {
            let end = topLevel(src, ",", start, close) ?? close
            types.append(inferType(fn, start, end).type)
            start = end + 1
        }
        guard !types.isEmpty, types.allSatisfy({ $0 == .integer || $0 == .number }) else { return (.any, false) }
        return (types.contains(.number) ? .number : .integer, false)
    }

    /// The declarations of `name` in `range`: `T x`, `T *x`, `T a, *x;` and parameters. Occurrences
    /// inside `fns` (their signatures and bodies) are skipped, which leaves file-scope declarations.
    func declarations(_ src: Src, _ name: String, in range: Range<Int>, outside fns: [Fn] = []) -> [(words: [String], pointer: Bool)] {
        let t = src.toks
        var found: [(words: [String], pointer: Bool)] = []
        for i in range where t[i].kind == .ident && t[i].text == name && i > 0 && i + 1 < t.count {
            guard ["=", ";", ",", ")"].contains(t[i + 1].text) else { continue }
            if fns.contains(where: { $0.nameIdx <= i && i <= $0.close }) { continue }
            var j = i - 1
            var pointer = false
            // `NSString *const x`: a qualifier between the star and the name.
            while j >= 0, t[j].text == "const" || t[j].text == "volatile" || t[j].text == "__strong" { j -= 1 }
            while j >= 0, t[j].text == "*" { pointer = true; j -= 1 }
            if j >= 0, t[j].text == "," {
                // `T a = e, *x;`: the type words open the declaration the comma belongs to.
                guard let head = declarationWords(src, comma: j) else { continue }
                found.append((head, pointer))
                continue
            }
            guard j >= 0, t[j].kind == .ident, !reserved.contains(t[j].text) else { continue }
            var words: [String] = []
            while j >= 0, t[j].kind == .ident, !reserved.contains(t[j].text) { words.insert(t[j].text, at: 0); j -= 1 }
            found.append((words, pointer))
        }
        return found
    }

    /// Type of a local or parameter by its declaration in the function, else of a file-scope
    /// variable (`any` when absent or ambiguous).
    private func declaredType(_ fn: Fn, _ name: String) -> KeyType {
        let src = fn.src
        let t = src.toks
        var found = declarations(src, name, in: (fn.nameIdx + 1)..<fn.close)
        if found.isEmpty { found = declarations(src, name, in: 0..<t.count, outside: functions(of: src)) }
        let types = found.map { typeFor($0.words, pointer: $0.pointer) }
        guard let first = types.first, types.allSatisfy({ $0 == first }) else { return .any }
        // An `id` local that receives `[name addObject:x]` is an array.
        if first == .any, t.indices.contains(where: {
            $0 > 0 && $0 + 2 < t.count && t[$0].text == name && t[$0 - 1].text == "["
                && t[$0 + 1].text == "addObject" && t[$0 + 2].text == ":"
        }) { return .array }
        return first
    }

    /// A variable's type; an `id` local takes the merged type of the values assigned to it
    /// (`id v = c ? @(x) : NSNull.null;` is a nullable number).
    private func inferName(_ fn: Fn, _ name: String) -> Inferred {
        let type = declaredType(fn, name)
        if type == .any, isCFBoolean(fn, name, depth: 0) { return (.boolean, false) }
        if type != .any { return (type, false) }
        let src = fn.src
        let t = src.toks
        let local = declarations(src, name, in: (fn.nameIdx + 1)..<fn.close)
        guard !local.isEmpty, local.allSatisfy({ $0.words.last == "id" && !$0.pointer }) else { return (.any, false) }
        let guardKey = src.file + "#" + fn.name + "." + name
        guard inferring.insert(guardKey).inserted else { return (.any, false) }
        defer { inferring.remove(guardKey) }
        var result: Inferred?
        for p in (fn.open + 1)..<fn.close where t[p].kind == .ident && t[p].text == name
            && p + 1 < fn.close && t[p + 1].text == "=" && t[p - 1].text != "." && t[p - 1].text != "->" {
            let end = endOfStatement(src, p + 2, limit: fn.close)
            if isNil(src, p + 2, end) { continue }
            let value = inferType(fn, p + 2, end)
            result = result.map { KeyMerge.unify($0, value, integersAreNumbers: true) } ?? value
        }
        return result ?? (.any, false)
    }

    /// The type a class check gives `value` in condition tokens a..<b: `[value isKindOfClass:NSString.class]`
    /// in a conjunction (not negated, no `||`).
    private func classGuard(_ src: Src, _ a: Int, _ b: Int, value: String) -> KeyType? {
        let t = src.toks
        if topLevel(src, "||", a, b) != nil { return nil }
        for k in a..<b where t[k].text == "[" && t[k].kind == .punct && src.match[k] > k && src.match[k] <= b {
            if k > a, t[k - 1].text == "!" { continue }
            let close = src.match[k]
            guard let sel = (k + 1..<close).first(where: {
                t[$0].text == "isKindOfClass" && t[$0 + 1].text == ":" && src.enclosing[$0] == k
            }), sel + 2 < close, text(src, k + 1, sel) == value else { continue }
            if let known = CTypes.objectiveC[t[sel + 2].text] { return known }
        }
        return nil
    }

    /// The type an enclosing `if (... [value isKindOfClass:C.class] ...)` gives the value at lo..<hi.
    private func narrowed(_ fn: Fn, _ lo: Int, _ hi: Int) -> KeyType? {
        let src = fn.src
        let t = src.toks
        let value = text(src, lo, hi)
        func walk(_ nodes: [Node]) -> KeyType? {
            for node in nodes where node.range.contains(lo) {
                if node.kind == .ifelse, let then = node.children.first, then.range.contains(lo) {
                    let head = node.range.lowerBound + 1
                    if head < t.count, t[head].text == "(", src.match[head] > head,
                       let kind = classGuard(src, head + 1, src.match[head], value: value) { return kind }
                }
                if let deeper = walk(node.children) { return deeper }
            }
            return nil
        }
        return walk(fn.tree)
    }

    /// The type a function declares for its result (`any` when it is not a scalar or Foundation class).
    private func returnType(_ callee: Fn) -> KeyType {
        let t = callee.src.toks
        var j = callee.nameIdx - 1
        var pointer = false
        while j >= 0, t[j].text == "*" { pointer = true; j -= 1 }
        var words: [String] = []
        while j >= 0, t[j].kind == .ident, !reserved.contains(t[j].text) { words.insert(t[j].text, at: 0); j -= 1 }
        return words.isEmpty ? .any : typeFor(words, pointer: pointer)
    }

    /// Result types of the declarations `- (T)selector` and `@property T selector;` in this source.
    private func selectorTypes(_ src: Src, _ selector: String) -> [KeyType] {
        let t = src.toks
        var result: [KeyType] = []
        for i in t.indices where t[i].kind == .ident && t[i].text == selector && i > 2 && i + 1 < t.count {
            func words(_ close: Int) -> (words: [String], pointer: Bool) {
                var j = close - 1
                var pointer = false
                while j >= 0, t[j].text == "*" { pointer = true; j -= 1 }
                var out: [String] = []
                while j >= 0, t[j].kind == .ident, !reserved.contains(t[j].text) { out.insert(t[j].text, at: 0); j -= 1 }
                return (out, pointer)
            }
            if t[i - 1].text == ")", src.open[i - 1] > 0, t[src.open[i - 1] - 1].text == "-", [";", "{", ":"].contains(t[i + 1].text) {
                let w = words(i - 1)
                if !w.words.isEmpty { result.append(typeFor(w.words, pointer: w.pointer)) }
            } else if t[i + 1].text == ";" {
                // `@property (attrs) T name;`
                var j = i - 1
                while j >= 0, t[j].text == "*" || (t[j].kind == .ident && !reserved.contains(t[j].text)) { j -= 1 }
                if j >= 0, t[j].text == ")", src.open[j] > 0, t[src.open[j] - 1].text == "@property" {
                    let w = words(i)
                    if !w.words.isEmpty { result.append(typeFor(w.words, pointer: w.pointer)) }
                }
            }
        }
        return result
    }
}

/// Foundation selectors whose result type does not depend on the receiver's class.
private let foundationSelectors: [String: KeyType] = [
    "boolValue": .boolean, "isEqual": .boolean, "isEqualToString": .boolean, "isKindOfClass": .boolean,
    "respondsToSelector": .boolean, "hasPrefix": .boolean, "hasSuffix": .boolean, "containsObject": .boolean,
    "intValue": .integer, "integerValue": .integer, "longValue": .integer, "longLongValue": .integer,
    "unsignedIntValue": .integer, "unsignedIntegerValue": .integer, "unsignedLongValue": .integer,
    "unsignedLongLongValue": .integer, "count": .integer, "length": .integer,
    "doubleValue": .number, "floatValue": .number, "timeIntervalSince1970": .number, "timeIntervalSinceDate": .number,
    "stringValue": .string, "description": .string, "lowercaseString": .string, "uppercaseString": .string,
    "absoluteString": .string, "stringFromDate": .string,
    "timeIntervalSinceNow": .number, "timeIntervalSinceReferenceDate": .number,
    "allObjects": .array, "allKeys": .array, "allValues": .array, "componentsSeparatedByString": .array,
    "sortedArrayUsingSelector": .array, "filteredArrayUsingPredicate": .array, "sortedArrayUsingComparator": .array, "subarrayWithRange": .array,
]

/// SDK classes and structs whose property types the sources do not declare (CoreLocation, Foundation):
/// member -> a JSON scalar type name, or the SDK type the member has.
private let sdkMembers: [String: [String: String]] = [
    "CLLocation": [
        "coordinate": "CLLocationCoordinate2D", "altitude": "number", "horizontalAccuracy": "number",
        "verticalAccuracy": "number", "speed": "number", "course": "number", "timestamp": "NSDate",
        "sourceInformation": "CLLocationSourceInformation",
    ],
    "CLLocationCoordinate2D": ["latitude": "number", "longitude": "number"],
    "CLLocationSourceInformation": ["isSimulatedBySoftware": "boolean", "isProducedByAccessory": "boolean"],
    "NSDate": [
        "date": "NSDate", "timeIntervalSince1970": "number", "timeIntervalSinceNow": "number",
        "timeIntervalSinceReferenceDate": "number",
    ],
    "NSProcessInfo": ["processInfo": "NSProcessInfo", "systemUptime": "number"],
]
