import Foundation

// MARK: - Report Content

/// The text of one report from vphoned `logs.crash`, split for display.
/// `.ips` reports are a one-line JSON header followed by a JSON body; the
/// header becomes `header` and the body is re-indented. Anything else is
/// shown as it is.
struct VPhoneCrashReportContent: Sendable {
    /// The fields of `logs.crash` needed to build the content. Read on the
    /// main actor, then parsed off it.
    struct Fields: Sendable {
        let path: String
        let text: String
        let size: Int
        let truncated: Bool

        init?(crashResult: [String: Any], path requestedPath: String? = nil) {
            guard let path = requestedPath ?? crashResult.string("path") else { return nil }
            let content = crashResult["content"] as? String ?? ""
            if crashResult.string("encoding") == "base64" {
                guard let data = Data(base64Encoded: content) else { return nil }
                text = String(decoding: data, as: UTF8.self)
            } else {
                guard crashResult["content"] is String else { return nil }
                text = content
            }
            self.path = path
            size = crashResult.int("size") ?? text.utf8.count
            truncated = crashResult.bool("truncated") ?? false
        }
    }

    struct Header: Sendable {
        let appName: String?
        let bugType: String?
        let osVersion: String?
        let timestamp: String?
        let incidentID: String?
    }

    let path: String
    /// The report exactly as the guest stored it. Copy and Export use this.
    let rawText: String
    let header: Header?
    /// What the text view shows: the body after the header line, re-indented
    /// when it is JSON.
    let displayText: String
    let isReindented: Bool
    let size: Int
    let truncated: Bool

    init(_ fields: Fields) {
        path = fields.path
        rawText = fields.text
        size = fields.size
        truncated = fields.truncated

        let text = fields.text
        guard let newline = text.firstIndex(of: "\n"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)),
              let json = object as? [String: Any]
        else {
            header = nil
            displayText = text
            isReindented = false
            return
        }

        header = Header(
            appName: json.string("app_name") ?? json.string("name") ?? json.string("procName"),
            bugType: json.string("bug_type"),
            osVersion: json.string("os_version"),
            timestamp: json.string("timestamp"),
            incidentID: json.string("incident_id"),
        )
        let body = text[text.index(after: newline)...]
        // A body past the size cap, or one reindent() declines, is shown as it is.
        if body.utf8.count <= Self.maxReindentInput,
           (try? JSONSerialization.jsonObject(with: Data(body.utf8))) != nil,
           let reindented = Self.reindent(body)
        {
            displayText = reindented
            isReindented = true
        } else {
            displayText = String(body)
            isReindented = false
        }
    }

    // MARK: - JSON Layout

    /// Largest body, in bytes, that is re-indented.
    static let maxReindentInput = 4 * 1024 * 1024
    /// Deepest nesting that is re-indented. Each newline adds `depth * 2`
    /// spaces, so deep guest JSON could otherwise grow the text many times over.
    static let maxReindentDepth = 64
    /// Largest re-indented text, in bytes.
    static let maxReindentOutput = 16 * 1024 * 1024

    /// Re-indents valid JSON two spaces per level. Unlike a round trip
    /// through JSONSerialization, this keeps the report's key order.
    /// Returns nil when the input, nesting or output passes its limit.
    static func reindent(_ json: Substring) -> String? {
        guard json.utf8.count <= maxReindentInput else { return nil }
        let input = Array(json.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count + input.count / 2)
        var depth = 0
        var inString = false
        var escaped = false

        func newline() {
            output.append(UInt8(ascii: "\n"))
            output.append(contentsOf: repeatElement(UInt8(ascii: " "), count: depth * 2))
        }

        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        var index = 0
        while index < input.count {
            let byte = input[index]
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                index += 1
                continue
            }

            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                output.append(byte)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                output.append(byte)
                var next = index + 1
                while next < input.count, isWhitespace(input[next]) {
                    next += 1
                }
                if next < input.count, input[next] == UInt8(ascii: "}") || input[next] == UInt8(ascii: "]") {
                    output.append(input[next])
                    index = next
                } else {
                    depth += 1
                    guard depth <= maxReindentDepth else { return nil }
                    newline()
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth = max(depth - 1, 0)
                newline()
                output.append(byte)
            case UInt8(ascii: ","):
                output.append(byte)
                newline()
            case UInt8(ascii: ":"):
                output.append(byte)
                output.append(UInt8(ascii: " "))
            default:
                if !isWhitespace(byte) {
                    output.append(byte)
                }
            }
            index += 1
            if output.count > maxReindentOutput {
                return nil
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
