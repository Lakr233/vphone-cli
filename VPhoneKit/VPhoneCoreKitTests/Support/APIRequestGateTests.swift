import Foundation
import Testing
@testable import VPhoneCoreKit

struct APIRequestGateTests {
    typealias Gate = VPhoneAPIRequestGate

    let token = String(repeating: "ab", count: 32)

    private func request(_ head: String, body: String = "") -> Data {
        Data((head.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n" + body).utf8)
    }

    private func forwarded(_ decision: Gate.Decision) -> String? {
        guard case let .accept(data) = decision else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Accepted Tokens

    @Test func `bearer token is accepted and the header is dropped`() {
        let data = request("""
        POST /v1/rpc HTTP/1.1
        Host: 127.0.0.1:8765
        Authorization: Bearer \(token)
        Content-Type: application/json
        Content-Length: 2

        """, body: "{}")
        #expect(forwarded(Gate.evaluate(data, token: token)) == """
        POST /v1/rpc HTTP/1.1\r
        Host: 127.0.0.1:8765\r
        Content-Type: application/json\r
        Content-Length: 2\r
        \r
        {}
        """)
    }

    @Test func `query token is accepted and stripped from the target`() {
        let data = request("""
        GET /v1/events?token=\(token) HTTP/1.1
        Host: localhost:8765
        Upgrade: websocket

        """)
        let output = forwarded(Gate.evaluate(data, token: token))
        #expect(output?.hasPrefix("GET /v1/events HTTP/1.1\r\nHost: localhost:8765\r\nUpgrade: websocket\r\n\r\n") == true)
    }

    @Test func `query token is stripped while other items stay in order`() {
        let data = request("""
        GET /v1/files/content?path=%2Ftmp%2Fa&token=\(token)&mode=644 HTTP/1.1

        """)
        #expect(forwarded(Gate.evaluate(data, token: token)) ==
            "GET /v1/files/content?path=%2Ftmp%2Fa&mode=644 HTTP/1.1\r\n\r\n")
    }

    @Test func `websocket protocol token is accepted and left in place`() {
        let head = """
        GET /v1/events HTTP/1.1
        Host: 127.0.0.1
        Sec-WebSocket-Protocol: chat, vphone-token.\(token)

        """
        let data = request(head)
        #expect(forwarded(Gate.evaluate(data, token: token)) == String(decoding: data, as: UTF8.self))
    }

    @Test func `bytes after the head are forwarded unchanged`() {
        let data = request("PUT /v1/files/content?path=%2Fx HTTP/1.1\nAuthorization: bearer \(token)\n", body: "\u{0}\r\n\r\nraw")
        #expect(forwarded(Gate.evaluate(data, token: token)) == "PUT /v1/files/content?path=%2Fx HTTP/1.1\r\n\r\n\u{0}\r\n\r\nraw")
    }

    @Test func `host is replaced only when requested`() {
        let data = request("GET /v1/health HTTP/1.1\nHost: 192.168.1.5:8765\nAuthorization: Bearer \(token)\n")
        #expect(forwarded(Gate.evaluate(data, token: token, host: "localhost")) ==
            "GET /v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    }

    // MARK: - Refused Requests

    @Test func `wrong token is refused`() {
        let wrong = String(repeating: "cd", count: 32)
        #expect(Gate.evaluate(request("GET /v1/health HTTP/1.1\nAuthorization: Bearer \(wrong)\n"), token: token) == .reject)
        #expect(Gate.evaluate(request("GET /v1/health?token=\(wrong) HTTP/1.1\n"), token: token) == .reject)
        #expect(Gate.evaluate(request("GET /v1/health?token=\(token.dropLast()) HTTP/1.1\n"), token: token) == .reject)
        #expect(Gate.evaluate(request("GET /v1/events HTTP/1.1\nSec-WebSocket-Protocol: vphone-token.\(wrong)\n"),
                              token: token) == .reject)
    }

    @Test func `missing token is refused`() {
        #expect(Gate.evaluate(request("GET /v1/health HTTP/1.1\nHost: 127.0.0.1\n"), token: token) == .reject)
        #expect(Gate.evaluate(request("GET /v1/health HTTP/1.1\nAuthorization: Basic \(token)\n"), token: token) == .reject)
        #expect(Gate.evaluate(request("GET /v1/health?token= HTTP/1.1\n"), token: token) == .reject)
        #expect(Gate.evaluate(request("GET /?token=\(token) HTTP/1.1\n"), token: "") == .reject)
    }

    @Test func `incomplete head waits and oversized head is refused`() {
        let partial = Data("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n".utf8)
        #expect(Gate.evaluate(partial, token: token) == .needMore)
        let filler = String(repeating: "a", count: Gate.maximumHeadLength)
        #expect(Gate.evaluate(Data("GET /v1/health HTTP/1.1\r\nX: \(filler)".utf8), token: token) == .reject)
        let complete = request("GET /v1/health HTTP/1.1\nAuthorization: Bearer \(token)\nX: \(filler)\n")
        #expect(Gate.evaluate(complete, token: token) == .reject)
    }

    @Test func `header injection attempts are refused`() {
        let bearer = "Authorization: Bearer \(token)"
        let attempts = [
            // Bare LF hides a second header from a CRLF-only reader.
            "GET /v1/health HTTP/1.1\r\n\(bearer)\nOrigin: http://evil\r\n\r\n",
            // Bare CR inside a value.
            "GET /v1/health HTTP/1.1\r\n\(bearer)\rX: y\r\n\r\n",
            // Obsolete line folding.
            "GET /v1/health HTTP/1.1\r\n\(bearer)\r\n Origin: http://evil\r\n\r\n",
            // Whitespace before the colon.
            "GET /v1/health HTTP/1.1\r\nAuthorization : Bearer \(token)\r\n\r\n",
            // NUL in a header value.
            "GET /v1/health HTTP/1.1\r\n\(bearer)\r\nX: a\u{0}b\r\n\r\n",
            // Extra spaces in the request line.
            "GET  /v1/health HTTP/1.1\r\n\(bearer)\r\n\r\n",
            // Not HTTP/1.x.
            "GET /v1/health HTTP/2.0\r\n\(bearer)\r\n\r\n",
            // A line with no colon.
            "GET /v1/health HTTP/1.1\r\n\(bearer)\r\nbroken\r\n\r\n",
            // Non-ASCII bytes.
            "GET /v1/health HTTP/1.1\r\n\(bearer)\r\nX: é\r\n\r\n",
        ]
        for attempt in attempts {
            #expect(Gate.evaluate(Data(attempt.utf8), token: token) == .reject, "\(attempt.debugDescription)")
        }
    }

    // MARK: - Tokens

    @Test func `token validation and constant time comparison`() {
        #expect(Gate.isValidToken(token))
        #expect(Gate.isValidToken("abcdefghij-._~0123"))
        #expect(!Gate.isValidToken("short"))
        #expect(!Gate.isValidToken("has space in the token value"))
        #expect(!Gate.isValidToken("comma,separated,token,value"))
        #expect(Gate.hexToken([0x00, 0x0F, 0xAB]) == "000fab")
        #expect(Gate.constantTimeEquals("abc", "abc"))
        #expect(!Gate.constantTimeEquals("abc", "abd"))
        #expect(!Gate.constantTimeEquals("abc", "abcd"))
        #expect(!Gate.constantTimeEquals("", "a"))
    }
}
