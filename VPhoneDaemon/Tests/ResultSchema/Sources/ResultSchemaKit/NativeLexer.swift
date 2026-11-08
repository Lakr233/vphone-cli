import Foundation

/// One lexical token of an Objective-C or C source.
struct Tok {
    enum Kind { case ident, objcString, cString, number, boxed, punct }
    let kind: Kind
    let text: String
    let line: Int
}

private let openers: Set<String> = ["(", "[", "{", "@{", "@[", "@("]
private let closers: Set<String> = [")", "]", "}"]
private let twoChar: Set<String> = ["==", "!=", "<=", ">=", "&&", "||", "->", "++", "--", "+=", "-=", "*=", "/=", "|=", "&=", "<<", ">>"]

/// A lexed source with bracket structure: `match[i]` is the closer of opener `i`
/// (or -1), `open[i]` the opener of closer `i`, `enclosing[i]` the innermost opener around `i`.
final class Src {
    let file: String
    let toks: [Tok]
    private(set) var match: [Int]
    private(set) var open: [Int]
    private(set) var enclosing: [Int]

    init(file: String, text: String) {
        self.file = file
        toks = Src.lex(text)
        match = Array(repeating: -1, count: toks.count)
        open = Array(repeating: -1, count: toks.count)
        enclosing = Array(repeating: -1, count: toks.count)
        var stack: [Int] = []
        for (i, t) in toks.enumerated() {
            enclosing[i] = stack.last ?? -1
            guard t.kind == .punct else { continue }
            if openers.contains(t.text) {
                stack.append(i)
            } else if closers.contains(t.text), let o = stack.popLast() {
                match[o] = i
                open[i] = o
                enclosing[i] = stack.last ?? -1
            }
        }
    }

    static func lex(_ text: String) -> [Tok] {
        let b = Array(text.utf8)
        func at(_ k: Int) -> UInt8 { k < b.count ? b[k] : 0 }
        func isIdentStart(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }
        func string(_ from: UInt8, _ i: inout Int) -> String {
            var out: [UInt8] = []
            i += 1
            while i < b.count, b[i] != from {
                if b[i] == 92, i + 1 < b.count { out.append(b[i]); i += 1 }
                out.append(b[i])
                i += 1
            }
            i += 1
            return String(decoding: out, as: UTF8.self)
        }
        var toks: [Tok] = []
        var i = 0
        var line = 1
        var lineStart = true
        while i < b.count {
            let c = b[i]
            if c == 10 { line += 1; i += 1; lineStart = true; continue }
            if c == 32 || c == 9 || c == 13 { i += 1; continue }
            if c == 47, at(i + 1) == 47 {
                while i < b.count, b[i] != 10 { i += 1 }
                continue
            }
            if c == 47, at(i + 1) == 42 {
                i += 2
                while i < b.count, !(b[i] == 42 && at(i + 1) == 47) {
                    if b[i] == 10 { line += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            if c == 35, lineStart {
                while i < b.count, b[i] != 10 {
                    if b[i] == 92, at(i + 1) == 10 { line += 1; i += 1 }
                    i += 1
                }
                continue
            }
            lineStart = false
            if c == 34 {
                toks.append(Tok(kind: .cString, text: string(34, &i), line: line))
            } else if c == 39 {
                toks.append(Tok(kind: .number, text: string(39, &i), line: line))
            } else if c == 64 {  // @
                if at(i + 1) == 34 {
                    i += 1
                    toks.append(Tok(kind: .objcString, text: string(34, &i), line: line))
                } else if isIdentStart(at(i + 1)) {
                    var j = i + 1
                    while isIdent(at(j)) { j += 1 }
                    toks.append(Tok(kind: .ident, text: String(decoding: b[i..<j], as: UTF8.self), line: line))
                    i = j
                } else if isDigit(at(i + 1)) || (at(i + 1) == 45 && isDigit(at(i + 2))) {
                    var j = i + 1
                    while isIdent(at(j)) || at(j) == 46 || at(j) == 45 { j += 1 }
                    toks.append(Tok(kind: .boxed, text: String(decoding: b[(i + 1)..<j], as: UTF8.self), line: line))
                    i = j
                } else if [123, 91, 40].contains(at(i + 1)) {
                    toks.append(Tok(kind: .punct, text: "@" + String(UnicodeScalar(at(i + 1))), line: line))
                    i += 2
                } else {
                    toks.append(Tok(kind: .punct, text: "@", line: line))
                    i += 1
                }
            } else if isIdentStart(c) {
                var j = i + 1
                while isIdent(at(j)) { j += 1 }
                toks.append(Tok(kind: .ident, text: String(decoding: b[i..<j], as: UTF8.self), line: line))
                i = j
            } else if isDigit(c) || (c == 46 && isDigit(at(i + 1))) {
                var j = i + 1
                let hex = c == 48 && (at(i + 1) == 120 || at(i + 1) == 88)
                while isIdent(at(j)) || at(j) == 46
                    || ((at(j) == 43 || at(j) == 45) && !hex && [101, 69].contains(at(j - 1))) { j += 1 }
                toks.append(Tok(kind: .number, text: String(decoding: b[i..<j], as: UTF8.self), line: line))
                i = j
            } else {
                let two = String(decoding: [c, at(i + 1)], as: UTF8.self)
                if twoChar.contains(two) {
                    toks.append(Tok(kind: .punct, text: two, line: line))
                    i += 2
                } else {
                    toks.append(Tok(kind: .punct, text: String(decoding: [c], as: UTF8.self), line: line))
                    i += 1
                }
            }
        }
        return toks
    }
}
