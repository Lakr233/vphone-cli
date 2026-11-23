import Foundation

// MARK: - Guest Paged List

/// Every row of a paged vphoned list method (`processes.list`, `services.list`,
/// `apps.list`, `files.list`, `logs.crashes`, `apfs.snapshots` …). vphoned
/// answers those one page at a time (200 rows unless `limit` says otherwise)
/// with `truncated` and, while rows remain, `next_cursor`; one plain call
/// misses everything after the first page.
///
/// The first call carries only the method's own params, so a vphoned from
/// before paging, which refuses unknown params and answers whole, still
/// works. Every later call repeats them with the previous reply's cursor.
/// vphoned's cursor is an offset into a fresh listing, so a guest change
/// between two calls can shift rows across the page boundary.
public struct VPhoneGuestPagedList {
    /// More pages than this means a guest that never stops answering `truncated`.
    static let maxPages = 1000

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    let key: String
    let params: [String: Any]
    private var rows: [Any] = []
    private var pages = 0
    private var cursor: String?

    /// `key` names the reply's row list, `params` the method's own params
    /// (no `limit` or `cursor`).
    public init(key: String, params: [String: Any] = [:]) {
        self.key = key
        self.params = params
    }

    /// The params of the first call.
    public var firstParams: [String: Any] { params }

    /// Takes the reply to the last call. Returns the params of the next call,
    /// or nil once `result` holds every row.
    public mutating func take(_ reply: [String: Any]) throws -> [String: Any]? {
        guard let page = reply[key] as? [Any] else {
            throw Failure(message: "the reply has no \(key) list")
        }
        pages += 1
        rows += page
        guard reply["truncated"] as? Bool == true else { return nil }
        guard let next = reply["next_cursor"] as? String, !page.isEmpty, next != cursor else {
            throw Failure(message: "a truncated \(key) page has no rows or no new next_cursor")
        }
        guard pages < Self.maxPages else {
            throw Failure(message: "\(key) is still truncated after \(pages) pages")
        }
        cursor = next
        var params = params
        params["cursor"] = next
        return params
    }

    /// The last reply with every row under `key`, `count` set to the row count
    /// when the method reports one, and no `next_cursor`.
    public func result(lastReply: [String: Any]) -> [String: Any] {
        var result = lastReply
        result[key] = rows
        if result["count"] != nil {
            result["count"] = rows.count
        }
        result["truncated"] = false
        result.removeValue(forKey: "next_cursor")
        return result
    }

    // MARK: - Collect

    /// Calls `fetch` until the list is complete and returns every row.
    public static func collect(
        key: String,
        params: [String: Any] = [:],
        fetch: ([String: Any]) throws -> [String: Any],
    ) throws -> [String: Any] {
        var list = VPhoneGuestPagedList(key: key, params: params)
        var sent = list.firstParams
        while true {
            let reply = try fetch(sent)
            guard let next = try list.take(reply) else {
                return list.result(lastReply: reply)
            }
            sent = next
        }
    }
}
