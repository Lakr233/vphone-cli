import Foundation

// MARK: - Reading entitlements the way libplist reads them

extension VPhoneSignEntitlements {
    /// The XML read as libplist's `plist_from_xml` reads it, for what an
    /// entitlements file holds. What libplist reads its own way is refused
    /// rather than guessed at: an entity it matches by the first letters,
    /// text split by a comment or CDATA, a second key in a row, a key left
    /// without a value, a byte that ends its C strings early, and elements
    /// after an empty root, which it reads into that root. The rest it reads
    /// as written here: every byte of a string kept (a CR too), the document
    /// read up to the end of its root and no further, and an `<integer>` in
    /// any base with any sign (`integer(_:)`).
    ///
    /// The refusals are deliberately stricter than ldid on one axis, measured
    /// 2026-09-23: 28 `<integer>` spellings ldid takes are refused here — `08`,
    /// `09`, `0x`, `42abc`, `1e3`, `0b101`, `0_1`, `12 34`, `&#52;2`, overflow
    /// either way, and so on. Every one is a shape `plist_to_xml` and
    /// CFPropertyList never emit, and no plist in this repo contains one, so
    /// the `-M` path (which re-reads canonical decimal) and the `-e`-then-`-S`
    /// installer flows are unaffected. The case it would bite is a
    /// hand-written entitlements plist added later with, say, a leading zero:
    /// that would abort a CFW build where ldid completed. If that happens the
    /// answer is to fix the plist, not to loosen this.
    ///
    /// Ported from `Lakr233/Irisin`'s `LdidEntitlements.Reader`.
    struct Reader {
        /// A container being read.
        private struct Frame {
            let isDictionary: Bool
            /// The key read for the next value of a dictionary.
            var key: String?
            var entries: [VPhoneSignEntitlements.Entry] = []
            /// Where each key of `entries` stands, by its bytes.
            var index: [[UInt8]: Int] = [:]
            var values: [VPhoneSignEntitlements.Value] = []

            /// As `plist_dict_set_item`: the value replaced where the key stands.
            mutating func set(_ key: String, _ value: VPhoneSignEntitlements.Value) {
                if let at = index[Array(key.utf8)] {
                    entries[at].value = value
                } else {
                    index[Array(key.utf8)] = entries.count
                    entries.append(VPhoneSignEntitlements.Entry(key: key, value: value))
                }
            }
        }

        /// Deeper than any entitlements go, and shallow enough for the
        /// writers' recursion on a small stack.
        private static let depth = 64

        private let bytes: [UInt8]
        private var at = 0
        private var stack: [Frame] = []
        /// An empty root, which libplist reads past.
        private var root: [VPhoneSignEntitlements.Entry]?

        init(_ data: Data) {
            bytes = Array(data)
        }

        private static func refuse(_ reason: String) -> VPhoneSignError {
            .unsupportedEntitlements(reason)
        }

        /// The root dictionary's entries.
        mutating func read() throws -> [VPhoneSignEntitlements.Entry] {
            let entries = try document()
            // libplist turns a lone CF$UID into a UID, which ldid refuses
            if entries.count == 1, entries[0].key.utf8.elementsEqual("CF$UID".utf8), case .integer = entries[0].value {
                throw Self.refuse("a lone CF$UID libplist would read as a UID")
            }
            return entries
        }

        private mutating func document() throws -> [VPhoneSignEntitlements.Entry] {
            var inPlist = false
            while true {
                skipSpace()
                guard at < bytes.count else { break }
                try expect("<")
                if try skipMarkup() {
                    continue
                }
                let (name, empty) = try tag()
                switch name {
                case "plist":
                    guard !empty, !inPlist, stack.isEmpty, root == nil else {
                        throw Self.refuse("a second <plist> element")
                    }
                    inPlist = true
                case "/plist":
                    // reached only past an empty root: libplist stops at the
                    // end of any other
                    guard !empty, inPlist, root != nil else { throw Self.refuse("</plist> where no root was open") }
                    inPlist = false
                case _ where root != nil:
                    throw Self.refuse("an element after an empty root, which libplist reads into that root")
                case "dict", "array":
                    if empty {
                        try add(name == "dict" ? .dictionary([]) : .array([]))
                    } else {
                        try open(dictionary: name == "dict")
                    }
                case "/dict", "/array":
                    guard !empty,
                          let frame = stack.popLast(),
                          frame.isDictionary == (name == "/dict"),
                          frame.key == nil
                    else {
                        throw Self.refuse("<\(name)> closes a container that is not open, or a key without a value")
                    }
                    guard !stack.isEmpty else {
                        // the root, a dictionary (`open`): libplist reads no further
                        return frame.entries
                    }
                    try add(frame.isDictionary ? .dictionary(frame.entries) : .array(frame.values))
                case "key":
                    guard !empty, let top = stack.indices.last, stack[top].isDictionary, stack[top].key == nil else {
                        throw Self.refuse("a <key> outside a dictionary, or a second one in a row")
                    }
                    stack[top].key = try Self.string(text(closing: name, skippingSpace: false))
                case "string":
                    let string = try empty ? "" : Self.string(text(closing: name, skippingSpace: false))
                    try add(.string(string))
                case "integer":
                    guard !empty else { throw Self.refuse("an empty <integer/>") }
                    try add(.integer(Self.integer(text(closing: name, skippingSpace: true))))
                case "data":
                    // libplist's decoder skips what it does not know; base64
                    // that reads back the same is what the two agree on
                    let encoded = try empty ? "" : String(
                        decoding: text(closing: name, skippingSpace: true).filter { !Self.isSpace($0) },
                        as: UTF8.self,
                    )
                    guard let value = Data(base64Encoded: encoded), value.base64EncodedString() == encoded else {
                        throw Self.refuse("a <data> whose base64 does not read back the same")
                    }
                    try add(.data(value))
                case "true", "false":
                    // libplist reads past any text in them; there is none here
                    guard try empty || text(closing: name, skippingSpace: true).isEmpty else {
                        throw Self.refuse("text inside <\(name)>")
                    }
                    try add(.boolean(name == "true"))
                default:
                    // a real, a date and anything that is no plist element
                    throw Self.refuse("<\(name)>, which this signer does not carry into DER")
                }
            }
            // the end of the document, fine only after an empty root
            guard stack.isEmpty, !inPlist, let root else { throw Self.refuse("the document ends inside an element") }
            return root
        }

        private mutating func open(dictionary: Bool) throws {
            // a value in a dictionary needs its key, and the root is a dictionary
            guard stack.count < Self.depth, stack.last.map({ !$0.isDictionary || $0.key != nil }) ?? dictionary else {
                throw Self.refuse("a container too deep, or a dictionary value without a key")
            }
            stack.append(Frame(isDictionary: dictionary))
        }

        private mutating func add(_ value: VPhoneSignEntitlements.Value) throws {
            guard let top = stack.indices.last else {
                // a root that is not a container ends libplist's read, and
                // one that is empty does not; only an empty dictionary is a
                // dictionary
                guard value == .dictionary([]) else { throw Self.refuse("a root that is not a dictionary") }
                root = []
                return
            }
            if stack[top].isDictionary {
                guard let key = stack[top].key else { throw Self.refuse("a dictionary value without a key") }
                stack[top].key = nil
                stack[top].set(key, value)
            } else {
                stack[top].values.append(value)
            }
        }

        /// A tag's name, read past its `<` as libplist reads it, and whether
        /// it closes itself. Only `<plist>` may carry attributes, their
        /// double-quoted values skipped whole as libplist skips them.
        private mutating func tag() throws -> (name: String, empty: Bool) {
            let start = at
            while at < bytes.count, !" \t\r\n<>".utf8.contains(bytes[at]) {
                at += 1
            }
            var name = bytes[start ..< at]
            if at < bytes.count, bytes[at] != UInt8(ascii: ">") {
                guard name.elementsEqual("plist".utf8) else {
                    throw Self.refuse("attributes on <\(String(decoding: name, as: UTF8.self))>")
                }
                while at < bytes.count, bytes[at] != UInt8(ascii: "<"), bytes[at] != UInt8(ascii: ">") {
                    if bytes[at] == UInt8(ascii: "\"") {
                        at = try closingQuote()
                    }
                    at += 1
                }
            }
            try expect(">")
            let empty = bytes[at - 2] == UInt8(ascii: "/")
            if empty, name.last == UInt8(ascii: "/") {
                name = name.dropLast()
            }
            return (String(decoding: name, as: UTF8.self), empty)
        }

        /// An element's text up to its closing tag, which must be what
        /// follows it: libplist splits a text at a comment or CDATA and joins
        /// the parts its own way.
        private mutating func text(closing name: String, skippingSpace: Bool) throws -> ArraySlice<UInt8> {
            if skippingSpace {
                skipSpace()
            }
            guard let end = bytes[at...].firstIndex(of: UInt8(ascii: "<")) else {
                throw Self.refuse("<\(name)> is never closed")
            }
            let text = bytes[at ..< end]
            at = end + 1
            try expect("/" + name)
            skipSpace()
            try expect(">")
            return text
        }

        /// Skips what libplist skips between elements, past the `<`: `<?…?>`,
        /// a comment, and a `<!DOCTYPE>` without an internal subset.
        private mutating func skipMarkup() throws -> Bool {
            if bytes[at...].starts(with: "?".utf8) {
                try skip(past: "?>", quotes: true)
            } else if bytes[at...].starts(with: "!--".utf8) {
                at += 3
                try skip(past: "-->", quotes: false)
            } else if bytes[at...].starts(with: "!DOCTYPE".utf8) {
                at += 8
                while true {
                    guard at < bytes.count, bytes[at] != UInt8(ascii: "[") else {
                        throw Self.refuse("a DOCTYPE with an internal subset")
                    }
                    if bytes[at] == UInt8(ascii: "\"") {
                        at = try closingQuote()
                    } else if bytes[at] == UInt8(ascii: ">") {
                        at += 1
                        break
                    }
                    at += 1
                }
            } else if bytes[at...].starts(with: "!".utf8) {
                throw Self.refuse("CDATA or another declaration libplist joins its own way")
            } else {
                return false
            }
            return true
        }

        private mutating func skip(past terminator: String, quotes: Bool) throws {
            while at < bytes.count {
                if bytes[at...].starts(with: terminator.utf8) {
                    at += terminator.utf8.count
                    return
                }
                if quotes, bytes[at] == UInt8(ascii: "\"") {
                    at = try closingQuote()
                }
                at += 1
            }
            throw Self.refuse("markup that is never closed")
        }

        /// Where the double quote opened at `at` closes.
        private func closingQuote() throws -> Int {
            guard let close = bytes[(at + 1)...].firstIndex(of: UInt8(ascii: "\"")) else {
                throw Self.refuse("a quote that is never closed")
            }
            return close
        }

        private mutating func expect(_ literal: String) throws {
            guard bytes[at...].starts(with: literal.utf8) else { throw Self.refuse("expected \(literal)") }
            at += literal.utf8.count
        }

        private mutating func skipSpace() {
            while at < bytes.count, Self.isSpace(bytes[at]) {
                at += 1
            }
        }

        /// What libplist skips as space: these four and nothing else.
        private static func isSpace(_ byte: UInt8) -> Bool {
            [0x20, 0x09, 0x0A, 0x0D].contains(byte)
        }

        /// An `<integer>`'s text, read as libplist reads it: an optional sign,
        /// then `strtoull` in base 0, and the `uint64_t` that comes out is
        /// what ldid hands to its DER writer.
        ///
        /// Every released libplist — 2.3 through the 2.7 every shipped `ldid`
        /// links — is `strtoull(str, NULL, 0)` with nothing checked after it,
        /// so it reads `42abc` as 42, `abc` and `<integer></integer>` as 0,
        /// and an overflow as `ULLONG_MAX`. libplist's master branch added
        /// the three checks that turn each of those into a parse error. The
        /// spellings both read the same way are taken here and the rest are
        /// refused, because signing one of the others would seal a number the
        /// next ldid would have refused to write at all. A doubled sign
        /// (`--1`) is refused with them: the two agree it is 1, and nothing
        /// writes it.
        ///
        /// Everything a real entitlements list can hold is in the accepted
        /// group. `0`, `-1`, `007`, `0x10`, `+42`, `-0x10`, `2^63` and
        /// `2^64-1` all round-trip, each checked against the 0xfade7172 blob
        /// `ldid -S<file>` writes for it.
        private static func integer(_ text: ArraySlice<UInt8>) throws -> VPhoneSignEntitlements.Integer {
            // the leading space went before the text was captured; the
            // trailing space strtoull stops at goes here
            var body = text.drop { isSpace($0) }
            while let last = body.last, isSpace(last) {
                body = body.dropLast()
            }
            var isNegative = false
            if let sign = body.first, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") {
                isNegative = sign == UInt8(ascii: "-")
                // strtoull skips its own leading space, so `<integer>- 1</integer>` is -1
                body = body.dropFirst().drop { isSpace($0) }
            }
            // base 0: `0x` is hex, a leading `0` is octal, anything else decimal
            var radix = 10
            if body.count > 1, body.first == UInt8(ascii: "0") {
                let isHex = body.dropFirst().first.map { $0 | 0x20 == UInt8(ascii: "x") } == true
                radix = isHex ? 16 : 8
                body = body.dropFirst(isHex ? 2 : 1)
            }
            let digits = String(decoding: body, as: UTF8.self)
            guard !body.isEmpty, body.first != UInt8(ascii: "-"), body.first != UInt8(ascii: "+"),
                  let magnitude = UInt64(digits, radix: radix),
                  // strtoull would wrap this one and a newer libplist refuses it
                  !isNegative || magnitude <= UInt64(Int64.max) + 1
            else {
                throw refuse("<integer>\(String(decoding: text, as: UTF8.self))</integer>, which libplist would read its own way")
            }
            return VPhoneSignEntitlements.Integer(
                raw: isNegative ? 0 &- magnitude : magnitude,
                // libplist's `length == 16`: above INT64_MAX and unsigned,
                // which is the only case `plist_to_xml` prints with %llu
                isUnsigned: !isNegative && magnitude > UInt64(Int64.max),
            )
        }

        /// A key's or a string's text: the five named entities and a numeric
        /// reference of up to eight characters, as libplist takes them, and
        /// UTF-8 with no NUL, which would end libplist's string.
        private static func string(_ text: ArraySlice<UInt8>) throws -> String {
            var bytes: [UInt8] = []
            var at = text.startIndex
            while at < text.endIndex {
                guard text[at] == UInt8(ascii: "&") else {
                    bytes.append(text[at])
                    at += 1
                    continue
                }
                guard let end = text[at...].firstIndex(of: UInt8(ascii: ";")) else {
                    throw refuse("an entity that is never closed")
                }
                let name = text[(at + 1) ..< end]
                switch String(decoding: name, as: UTF8.self) {
                case "amp": bytes.append(UInt8(ascii: "&"))
                case "lt": bytes.append(UInt8(ascii: "<"))
                case "gt": bytes.append(UInt8(ascii: ">"))
                case "quot": bytes.append(UInt8(ascii: "\""))
                case "apos": bytes.append(UInt8(ascii: "'"))
                default:
                    let hex = name.dropFirst().first.map { $0 | 0x20 == UInt8(ascii: "x") } == true
                    let digits = name.dropFirst(hex ? 2 : 1)
                    guard name.first == UInt8(ascii: "#"), name.count <= 8, !digits.isEmpty,
                          digits.allSatisfy({
                              (0x30 ... 0x39).contains($0)
                                  || hex && (0x61 ... 0x66).contains($0 | 0x20)
                          }),
                          let value = UInt32(String(decoding: digits, as: UTF8.self), radix: hex ? 16 : 10), value != 0,
                          let scalar = Unicode.Scalar(value)
                    else { throw refuse("an entity libplist matches by its first letters") }
                    bytes += Array(String(scalar).utf8)
                }
                at = end + 1
            }
            let string = String(decoding: bytes, as: UTF8.self)
            guard !bytes.contains(0), string.utf8.elementsEqual(bytes) else {
                throw refuse("a string with a NUL or a byte that is not UTF-8")
            }
            return string
        }
    }
}
