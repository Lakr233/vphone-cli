import Foundation

/// Admission for the host API proxy (`--api-listen`). The proxy reads the
/// first HTTP request head on each TCP connection and relays the connection to
/// guest vphoned only when that head carries the per-launch token. vphoned
/// cannot tell a proxied connection from the VM's own VSOCK client, so the
/// check lives on the host, in front of the byte relay.
///
/// A token is accepted from, in order of preference:
/// - `Authorization: Bearer <token>`
/// - a `token=<token>` query item on the request target
/// - a `Sec-WebSocket-Protocol` value `vphone-token.<token>`
///
/// The forwarded head drops `Authorization` and the `token` query item, so
/// `/v1/events?token=…` still reaches vphoned as `/v1/events`. Every other
/// byte, including a request body that arrived with the head, is unchanged.
public enum VPhoneAPIRequestGate {
    /// The largest request head the proxy buffers before refusing.
    public static let maximumHeadLength = 16 * 1024
    /// The environment variable that supplies a fixed token to `vphone-vm`
    /// and to `VPhoneAPIClient`.
    public static let environmentKey = "VPHONE_API_TOKEN"
    public static let webSocketProtocolPrefix = "vphone-token."

    public enum Decision: Equatable, Sendable {
        /// The head is incomplete and still under the size limit.
        case needMore
        /// Forward these bytes to the guest, then relay the rest unchanged.
        case accept(Data)
        /// Reply with `unauthorizedResponse` and close.
        case reject
    }

    public static let unauthorizedResponse: Data = {
        let body = #"{"type":"response","id":null,"error":{"code":"unauthorized","message":"Missing or wrong API token"}}"#
        let head = "HTTP/1.1 401 Unauthorized\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "WWW-Authenticate: Bearer\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data((head + body).utf8)
    }()

    // MARK: - Token

    /// A usable token is 16 to 256 URL-unreserved characters, so it needs no
    /// escaping in a header, a query item or a WebSocket protocol name.
    public static func isValidToken(_ token: String) -> Bool {
        (16 ... 256).contains(token.utf8.count) && token.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                true
            default:
                false
            }
        }
    }

    /// Lowercase hexadecimal for random token bytes.
    public static func hexToken(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares every byte regardless of where the first difference is.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0 ..< max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }

    // MARK: - Admission

    /// Decides one connection from the bytes received so far. `host`, when
    /// given, replaces the `Host` header so vphoned's loopback check passes
    /// for a proxy listening on a non-loopback address.
    public static func evaluate(_ received: Data, token: String, host: String? = nil) -> Decision {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = received.range(of: terminator) else {
            return received.count >= maximumHeadLength ? .reject : .needMore
        }
        let headEnd = end.upperBound - received.startIndex
        guard headEnd <= maximumHeadLength, isValidToken(token),
              let request = Head(received[received.startIndex ..< end.lowerBound]),
              request.carries(token)
        else { return .reject }
        var forwarded = Data(request.rewritten(host: host).utf8)
        forwarded.append(received[end.lowerBound...])
        return .accept(forwarded)
    }

    // MARK: - Request Head

    struct Head {
        let requestLine: String
        let method: String
        let target: String
        let version: String
        /// Each header line as received, with its parsed name and value.
        var fields: [(line: String, name: String, value: String)]

        /// Parses a request head without its final blank line. Bare CR, bare
        /// LF, NUL, other control bytes, folded lines and malformed field
        /// names are refused, so the proxy and vphoned cannot read the same
        /// bytes as different headers.
        init?(_ bytes: Data) {
            guard bytes.allSatisfy({ $0 == 0x0D || $0 == 0x0A || $0 == 0x09 || (0x20 ..< 0x7F).contains($0) }),
                  let text = String(data: bytes, encoding: .ascii)
            else { return nil }
            let lines = text.components(separatedBy: "\r\n")
            guard lines.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }),
                  let requestLine = lines.first
            else { return nil }
            let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
                  parts[0].allSatisfy(Self.isTokenCharacter),
                  parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
            else { return nil }
            self.requestLine = requestLine
            method = String(parts[0])
            target = String(parts[1])
            version = String(parts[2])
            fields = []
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon]
                guard !name.isEmpty, name.allSatisfy(Self.isTokenCharacter) else { return nil }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                fields.append((line, String(name), value))
            }
        }

        private static func isTokenCharacter(_ character: Character) -> Bool {
            guard let ascii = character.asciiValue, ascii > 0x20, ascii < 0x7F else { return false }
            return !"\"(),/:;<=>?@[\\]{}".contains(character)
        }

        func values(_ name: String) -> [String] {
            fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }

        /// The raw `name=value` items of the target's query, or nil without one.
        private var queryItems: [Substring]? {
            guard let question = target.firstIndex(of: "?") else { return nil }
            return target[target.index(after: question)...].split(separator: "&", omittingEmptySubsequences: false)
        }

        private static func isTokenItem(_ item: Substring) -> Bool {
            item == "token" || item.hasPrefix("token=")
        }

        func carries(_ token: String) -> Bool {
            var candidates: [String] = []
            for value in values("Authorization") {
                let parts = value.split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame {
                    candidates.append(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            for item in queryItems ?? [] where item.hasPrefix("token=") {
                candidates.append(String(item.dropFirst("token=".count)).removingPercentEncoding ?? "")
            }
            let prefix = VPhoneAPIRequestGate.webSocketProtocolPrefix
            for value in values("Sec-WebSocket-Protocol") {
                for name in value.split(separator: ",") {
                    let name = name.trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix(prefix) {
                        candidates.append(String(name.dropFirst(prefix.count)))
                    }
                }
            }
            // Check every candidate so the time taken does not depend on which
            // one matched.
            var matched = false
            for candidate in candidates {
                matched = VPhoneAPIRequestGate.constantTimeEquals(candidate, token) || matched
            }
            return matched
        }

        /// The head to forward: the request line loses its `token` query
        /// items, `Authorization` is dropped, and `Host` is replaced only when
        /// asked. Every other line is the one received.
        func rewritten(host: String?) -> String {
            var lines = [requestLine]
            if let question = target.firstIndex(of: "?"), let items = queryItems,
               items.contains(where: Self.isTokenItem)
            {
                let kept = items.filter { !Self.isTokenItem($0) }
                let path = String(target[..<question]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
                lines[0] = "\(method) \(path) \(version)"
            }
            for field in fields {
                if field.name.caseInsensitiveCompare("Authorization") == .orderedSame {
                    continue
                }
                if let host, field.name.caseInsensitiveCompare("Host") == .orderedSame {
                    lines.append("\(field.name): \(host)")
                } else {
                    lines.append(field.line)
                }
            }
            return lines.joined(separator: "\r\n")
        }
    }
}
