import Foundation

// MARK: - Entitlements

/// A program's entitlements as `ldid -M -S<file>` treats them: read from the
/// XML the old signature carries, merged with a file's, and written back as
/// the XML and DER blobs of the new signature.
///
/// ldid reads and writes that XML with libplist, whose dictionary keeps its
/// keys in the order they arrived and replaces a value where it stands, and
/// whose reader keeps every byte of a string as it was. Foundation sorts the
/// keys, and `XMLParser` folds line ends and reads entities its own way. So
/// both directions are written here, the writer held to Foundation in
/// everything but the order (`xml()`) and the DER ldid's own.
///
/// Ported from `Lakr233/Irisin`'s `LdidEntitlements`, which the fixtures
/// there hold to `ldid` byte for byte.
struct VPhoneSignEntitlements: Equatable {
    enum Value: Equatable {
        case boolean(Bool)
        case integer(Integer)
        case string(String)
        case data(Data)
        case array([Value])
        case dictionary([Entry])
    }

    /// An `<integer>` held the way libplist holds one, because that is what
    /// decides both of the things a signer has to reproduce.
    ///
    /// libplist keeps a single `uint64_t intval` and a `length` that is 8 or
    /// 16. ldid asks for `intval` through `plist_get_uint_val` and encodes
    /// that whole number, so the DER never sees a sign: `<integer>-1</integer>`
    /// and `<integer>18446744073709551615</integer>` both come out
    /// `0208ffffffffffffffff`. `plist_to_xml` is the half that remembers —
    /// `%llu` when `length == 16`, `%lli` otherwise — so the same bits print
    /// back as `-1` or as `18446744073709551615` depending on how they were
    /// spelled. Both were checked against `ldid -S<file>` and the blob it
    /// writes; see `Reader`'s `<integer>` case for the parse.
    struct Integer: Equatable {
        /// libplist's `intval`: a negative value in two's complement.
        var raw: UInt64
        /// libplist's `length == 16` — a value above `INT64_MAX` written
        /// with no sign, which prints unsigned and nothing else does.
        var isUnsigned: Bool

        init(raw: UInt64, isUnsigned: Bool = false) {
            self.raw = raw
            self.isUnsigned = isUnsigned
        }

        /// What `plist_to_xml` prints.
        var text: String {
            isUnsigned ? "\(raw)" : "\(Int64(bitPattern: raw))"
        }
    }

    struct Entry: Equatable {
        var key: String
        var value: Value
    }

    private(set) var entries: [Entry]

    /// `xml` is what an entitlements file or a signature's slot 5 holds;
    /// empty is no entitlements.
    init(xml: Data) throws {
        guard !xml.isEmpty else {
            entries = []
            return
        }
        var reader = Reader(xml)
        entries = try reader.read()
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    /// Merges `other` in as `-M` does: each of its keys set to its value
    /// where the key already stands, appended where it does not.
    mutating func merge(_ other: VPhoneSignEntitlements) {
        for entry in other.entries {
            if let index = entries.firstIndex(where: { $0.key.utf8.elementsEqual(entry.key.utf8) }) {
                entries[index].value = entry.value
            } else {
                entries.append(entry)
            }
        }
    }

    /// The executable segment flags ldid derives: the main binary's for a
    /// program's slice, and one for each entitlement that asks. ldid gives
    /// can-execute-cdhash the bit of can-load-cdhash (0x100), and so does
    /// this.
    func executableSegmentFlags(mainBinary: Bool) -> UInt64 {
        let flags: [(key: String, bit: UInt64)] = [
            ("get-task-allow", 0x10), ("run-unsigned-code", 0x10), ("com.apple.private.cs.debugger", 0x20),
            ("dynamic-codesigning", 0x40), ("com.apple.private.skip-library-validation", 0x80),
            ("com.apple.private.amfi.can-load-cdhash", 0x100), ("com.apple.private.amfi.can-execute-cdhash", 0x100),
        ]
        return flags.reduce(mainBinary ? 1 : 0) { result, flag in
            entries.first { $0.key.utf8.elementsEqual(flag.key.utf8) }?.value == .boolean(true) ? result | flag.bit : result
        }
    }

    /// As libplist's `plist_to_xml` writes it, which is Foundation's XML to
    /// the byte but in one thing: libplist keeps a dictionary's keys in the
    /// order they arrived and Foundation sorts them, so Foundation cannot
    /// write it. The writer here is held to Foundation on every call — the
    /// same list with its keys in Foundation's order must come out as
    /// `PropertyListSerialization` writes it — so every byte but the order
    /// is Foundation's, and a list the two would write differently is
    /// refused rather than signed.
    func xml() throws -> Data {
        let foundation = try? PropertyListSerialization.data(
            fromPropertyList: Self.foundation(.dictionary(entries)), format: .xml, options: 0,
        )
        guard Self.document(.dictionary(entries), sorted: true) == foundation else {
            throw VPhoneSignError.unsupportedEntitlements("Foundation and libplist would write this list differently")
        }
        return Self.document(.dictionary(entries), sorted: false)
    }

    /// As ldid writes it: the dictionary a SET whose members are sorted as
    /// encoded byte strings, not by key, and no wrapper around it.
    var der: Data {
        Data(Self.der(.dictionary(entries)))
    }

    // MARK: Writing

    /// Tabs, only `<`, `>` and `&` escaped, an empty container closed on
    /// itself; `sorted` puts keys in the UTF-16 order Foundation writes.
    private static func document(_ value: Value, sorted: Bool) -> Data {
        var out = Array("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """.utf8)
        write(value, depth: 0, sorted: sorted, into: &out)
        out += "</plist>\n".utf8
        return Data(out)
    }

    /// The list as Foundation holds it. The keys stay `NSString`s, which
    /// compare as UTF-16, so two spellings of one character stay two keys.
    private static func foundation(_ value: Value) -> Any {
        switch value {
        case let .boolean(value): NSNumber(value: value)
        // the same split libplist makes when it prints one, so Foundation
        // spells 2^63 and above unsigned the way `plist_to_xml` does
        case let .integer(value):
            value.isUnsigned ? NSNumber(value: value.raw) : NSNumber(value: Int64(bitPattern: value.raw))
        case let .string(value): NSString(string: value)
        case let .data(value): NSData(data: value)
        case let .array(values): NSArray(array: values.map(foundation))
        case let .dictionary(entries):
            NSDictionary(
                objects: entries.map { foundation($0.value) },
                forKeys: entries.map { NSString(string: $0.key) },
            )
        }
    }

    private static func write(_ value: Value, depth: Int, sorted: Bool, into out: inout [UInt8]) {
        let indent = [UInt8](repeating: 0x09, count: depth)
        out += indent
        func text(_ tag: String, _ content: String) {
            out += "<\(tag)>".utf8
            for byte in content.utf8 {
                switch byte {
                case UInt8(ascii: "<"): out += "&lt;".utf8
                case UInt8(ascii: ">"): out += "&gt;".utf8
                case UInt8(ascii: "&"): out += "&amp;".utf8
                default: out.append(byte)
                }
            }
            out += "</\(tag)>\n".utf8
        }
        switch value {
        case let .boolean(value):
            out += (value ? "<true/>\n" : "<false/>\n").utf8
        case let .integer(value):
            out += "<integer>\(value.text)</integer>\n".utf8
        case let .string(value):
            text("string", value)
        case let .data(value):
            out += "<data>\n".utf8
            // lines no wider than 76 columns counting a tab as 8, whole
            // groups of three bytes each, at most eight tabs in
            let lineIndent = [UInt8](repeating: 0x09, count: min(depth, 8))
            let perLine = (76 - lineIndent.count * 8) / 4 * 3
            for start in stride(from: 0, to: value.count, by: perLine) {
                let line = value.dropFirst(start).prefix(perLine)
                out += lineIndent + Data(line).base64EncodedString().utf8 + [0x0A]
            }
            out += indent + "</data>\n".utf8
        case let .array(values):
            guard !values.isEmpty else {
                out += "<array/>\n".utf8
                return
            }
            out += "<array>\n".utf8
            for value in values {
                write(value, depth: depth + 1, sorted: sorted, into: &out)
            }
            out += indent + "</array>\n".utf8
        case let .dictionary(entries):
            guard !entries.isEmpty else {
                out += "<dict/>\n".utf8
                return
            }
            out += "<dict>\n".utf8
            for entry in sorted ? entries.sorted(by: { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }) : entries {
                out += indent + [0x09]
                text("key", entry.key)
                write(entry.value, depth: depth + 1, sorted: sorted, into: &out)
            }
            out += indent + "</dict>\n".utf8
        }
    }

    private static func der(_ value: Value) -> [UInt8] {
        switch value {
        case let .boolean(value):
            [0x01, 0x01, value ? 1 : 0]
        case let .integer(value):
            tagged(0x02, bigEndian(value.raw))
        case let .string(value):
            tagged(0x0C, Array(value.utf8))
        case let .data(value):
            tagged(0x04, Array(value))
        case let .array(values):
            tagged(0x30, values.flatMap(der))
        case let .dictionary(entries):
            tagged(
                0x31,
                entries.map { tagged(0x30, tagged(0x0C, Array($0.key.utf8)) + der($0.value)) }
                    .sorted { $0.lexicographicallyPrecedes($1) }
                    .flatMap(\.self),
            )
        }
    }

    private static func tagged(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        guard content.count >= 0x80 else { return [tag, UInt8(content.count)] + content }
        let length = bigEndian(UInt64(content.count))
        return [tag, 0x80 | UInt8(length.count)] + length + content
    }

    /// The fewest bytes that hold `value`, most significant first, and one
    /// byte for zero. That last part is ldid's `bytes()`, which answers 1 for
    /// 0 rather than 0, and is why `<integer>0</integer>` encodes as `020100`
    /// and not as an INTEGER with no content. ldid writes no leading zero
    /// pad either, so a value with its top bit set is not a DER-legal signed
    /// INTEGER — 2^63 is `02088000000000000000`. Reproducing ldid means
    /// reproducing that.
    private static func bigEndian(_ value: UInt64) -> [UInt8] {
        let bytes = Array(withUnsafeBytes(of: value.bigEndian, Array.init).drop { $0 == 0 })
        return bytes.isEmpty ? [0] : bytes
    }
}
