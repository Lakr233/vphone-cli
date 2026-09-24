import Foundation

// MARK: - Just enough ASN.1

/// A DER reader and writer sized to what code signing needs: walking a
/// PKCS#12, pulling two names and a serial number out of a certificate, and
/// writing a CMS SignedData.
///
/// It is here rather than a library because the whole point of `VPhoneSign`
/// is that the signer links nothing outside the system frameworks, and
/// because DER is small when you only need definite-length encodings.
enum VPhoneDER {
    /// One element: its tag, where its value is, and where the whole thing
    /// ends in the buffer it was read from.
    struct Element {
        let tag: UInt8
        /// The value, with the tag and length stripped.
        let content: Data
        /// The element including its tag and length, which is what has to be
        /// carried over verbatim when one structure is embedded in another.
        let encoded: Data
        /// Where the next element starts.
        let end: Int

        var isConstructed: Bool { tag & 0x20 != 0 }
    }

    // MARK: Reading

    /// The element starting at `index`. `data` must be 0-based.
    static func element(in data: Data, at index: Int) throws -> Element {
        guard data.holds(index, 2) else { throw VPhoneSignError.identityUnreadable("a DER element runs off the end") }
        let tag = data[index]
        var cursor = index + 1
        let first = data[cursor]
        cursor += 1
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7F)
            // an indefinite length is BER, not DER, and nothing here writes one
            guard count > 0, count <= 4, data.holds(cursor, count) else {
                throw VPhoneSignError.identityUnreadable("a DER length this reader does not accept")
            }
            length = 0
            for _ in 0 ..< count {
                length = length << 8 | Int(data[cursor])
                cursor += 1
            }
        }
        guard data.holds(cursor, length) else {
            throw VPhoneSignError.identityUnreadable("a DER element claims \(length) bytes it does not have")
        }
        return Element(
            tag: tag,
            content: data.subdata(in: cursor ..< cursor + length),
            encoded: data.subdata(in: index ..< cursor + length),
            end: cursor + length
        )
    }

    /// Every element of a constructed value's content.
    static func children(of content: Data) throws -> [Element] {
        var elements: [Element] = []
        var cursor = 0
        while cursor < content.count {
            let element = try element(in: content, at: cursor)
            elements.append(element)
            cursor = element.end
        }
        return elements
    }

    /// The dotted form of an OBJECT IDENTIFIER's content, for comparing
    /// against the constants below.
    static func objectIdentifier(_ content: Data) -> String {
        guard let first = content.first else { return "" }
        var parts = ["\(first / 40)", "\(first % 40)"]
        var value = 0
        for byte in content.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append("\(value)")
                value = 0
            }
        }
        return parts.joined(separator: ".")
    }

    /// An INTEGER's value, for the small ones this reads (iteration counts,
    /// key lengths, versions).
    static func integer(_ content: Data) throws -> Int {
        guard !content.isEmpty, content.count <= 8 else {
            throw VPhoneSignError.identityUnreadable("an INTEGER of \(content.count) bytes")
        }
        return content.reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: Writing

    static func encode(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = Data()
            var value = content.count
            while value > 0 {
                length.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            out.append(0x80 | UInt8(length.count))
            out.append(length)
        }
        return out + content
    }

    static func sequence(_ elements: [Data]) -> Data {
        encode(0x30, elements.reduce(Data(), +))
    }

    /// DER sorts a SET OF by the encoded bytes of its members, which is what
    /// a verifier re-derives the digest over.
    static func setOf(_ elements: [Data]) -> Data {
        encode(0x31, elements.sorted { left, right in
            left.lexicographicallyPrecedes(right)
        }.reduce(Data(), +))
    }

    static func octetString(_ content: Data) -> Data { encode(0x04, content) }

    static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var value = value
        repeat {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        } while value > 0
        // DER integers are signed, so a leading bit set needs a zero byte
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return encode(0x02, Data(bytes))
    }

    static func objectIdentifier(dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        var content = Data([UInt8(parts[0] * 40 + parts[1])])
        for part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7F)]
            var value = part >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            content.append(contentsOf: chunk)
        }
        return encode(0x06, content)
    }

    /// An AlgorithmIdentifier with the explicit NULL parameters the RSA and
    /// SHA OIDs carry in a CMS structure.
    static func algorithm(_ oid: String, parameters: Data = Data([0x05, 0x00])) -> Data {
        sequence([objectIdentifier(dotted: oid), parameters])
    }

    /// A UTCTime, which is what CMS uses for a signing time before 2050.
    static func utcTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(
            format: "%02d%02d%02d%02d%02d%02dZ",
            parts.year! % 100, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!
        )
        return encode(0x17, Data(text.utf8))
    }

    // MARK: The OIDs this deals in

    enum OID {
        static let data = "1.2.840.113549.1.7.1"
        static let signedData = "1.2.840.113549.1.7.2"
        static let encryptedData = "1.2.840.113549.1.7.6"
        static let contentType = "1.2.840.113549.1.9.3"
        static let messageDigest = "1.2.840.113549.1.9.4"
        static let signingTime = "1.2.840.113549.1.9.5"
        static let sha256 = "2.16.840.1.101.3.4.2.1"
        static let sha1 = "1.3.14.3.2.26"
        static let rsaEncryption = "1.2.840.113549.1.1.1"
        static let sha256WithRSA = "1.2.840.113549.1.1.11"
        static let pbes2 = "1.2.840.113549.1.5.13"
        static let pbkdf2 = "1.2.840.113549.1.5.12"
        static let hmacWithSHA1 = "1.2.840.113549.2.7"
        static let hmacWithSHA224 = "1.2.840.113549.2.8"
        static let hmacWithSHA256 = "1.2.840.113549.2.9"
        static let hmacWithSHA384 = "1.2.840.113549.2.10"
        static let hmacWithSHA512 = "1.2.840.113549.2.11"
        static let aes128CBC = "2.16.840.1.101.3.4.1.2"
        static let aes192CBC = "2.16.840.1.101.3.4.1.22"
        static let aes256CBC = "2.16.840.1.101.3.4.1.42"
        static let certBag = "1.2.840.113549.1.12.10.1.3"
        static let keyBag = "1.2.840.113549.1.12.10.1.1"
        static let shroudedKeyBag = "1.2.840.113549.1.12.10.1.2"
        static let x509Certificate = "1.2.840.113549.1.9.22.1"
        static let commonName = "2.5.4.3"
        static let organizationalUnit = "2.5.4.11"
        /// Apple's code signing hash agility attributes: the first carries a
        /// plist of truncated cdhashes, the second one entry per digest.
        static let hashAgility = "1.2.840.113635.100.9.1"
        static let hashAgilityV2 = "1.2.840.113635.100.9.2"
    }
}
