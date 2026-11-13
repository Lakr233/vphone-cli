import Foundation

/// Bounded replies for the list methods: `limit`/`cursor` in, `truncated`/`total`/`next_cursor`
/// out. A cursor is a decimal offset into a fresh listing, so guest changes between calls can
/// shift entries. Guest-free, so the logic harness compiles it.
enum GuestPaging {
    static let defaultLimit = 200
    static let maxLimit = 1000

    /// An integer param within `range`. A boolean, a string, a fractional number or a number out
    /// of range is `invalidRequest`; the range is checked on the Double before any Int conversion,
    /// so 1e20 never traps. nil means the param is absent.
    static func strictInt(_ value: Any?, name: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value else { return nil }
        let expected = "\(name) must be an integer from \(range.lowerBound) to \(range.upperBound), got \(received(value))"
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw GuestAPIError.invalidRequest(expected)
        }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(),
              double >= Double(range.lowerBound), double <= Double(range.upperBound)
        else { throw GuestAPIError.invalidRequest(expected) }
        return Int(double)
    }

    /// `result[paged.key]` sorted per `paged.order`, then the first `limit` entries from `cursor`;
    /// sets `truncated`, `total` and, when more remain, `next_cursor`. An existing `count` becomes
    /// the page size.
    static func apply(_ result: [String: Any], _ paged: MethodSpec.Paged, _ params: [String: Any]) throws -> [String: Any] {
        let limit = try strictInt(params["limit"], name: "limit", range: 1 ... maxLimit) ?? defaultLimit
        guard let listed = result[paged.key] as? [Any] else {
            throw GuestAPIError.operationFailed("\(paged.key) is not a list")
        }
        let rows = sorted(listed, paged.order)
        var offset = 0
        if let cursor = params["cursor"] {
            guard let text = cursor as? String, !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsed = Int(text), parsed <= rows.count
            else { throw GuestAPIError.invalidRequest("cursor is invalid; repeat the call without a cursor") }
            offset = parsed
        }
        let end = min(offset + limit, rows.count)
        var page = result
        page[paged.key] = Array(rows[offset ..< end])
        page["total"] = rows.count
        page["truncated"] = end < rows.count
        if end < rows.count { page["next_cursor"] = String(end) }
        if page["count"] != nil { page["count"] = end - offset }
        return page
    }

    /// `keep` leaves the rows as they are; `strings` and `keys` sort ascending. A missing or
    /// wrong-typed key sorts as "" (as -1 for `pid`).
    static func sorted(_ rows: [Any], _ order: MethodSpec.PageOrder) -> [Any] {
        switch order {
        case .keep:
            return rows
        case .strings:
            return rows.sorted { ($0 as? String ?? "") < ($1 as? String ?? "") }
        case let .keys(keys):
            return rows.sorted { a, b in
                let (a, b) = (a as? [String: Any] ?? [:], b as? [String: Any] ?? [:])
                for key in keys {
                    if key == "pid" {
                        let (x, y) = (a[key] as? Int ?? -1, b[key] as? Int ?? -1)
                        if x != y { return x < y }
                    } else {
                        let (x, y) = (a[key] as? String ?? "", b[key] as? String ?? "")
                        if x != y { return x < y }
                    }
                }
                return false
            }
        }
    }

    private static func received(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : "\(number)"
        }
        return "\(value)"
    }
}
