import Foundation
import Testing
@testable import VPhoneCoreKit

struct GuestPagedListTests {
    // MARK: - Fake vphoned

    /// vphoned's `GuestPaging.apply` over pids: 200 rows per page, `cursor` as
    /// a decimal offset into a fresh listing of `pids`.
    final class FakeGuest {
        var pids: [Int]
        let pages: Bool
        var sent: [[String: Any]] = []

        init(total: Int, pages: Bool = true) {
            pids = Array(0 ..< total)
            self.pages = pages
        }

        func list(_ params: [String: Any]) throws -> [String: Any] {
            sent.append(params)
            let rows: [Any] = pids.map { ["pid": $0] }
            guard pages else {
                if params["limit"] != nil || params["cursor"] != nil {
                    throw VPhoneGuestPagedList.Failure(message: "Unknown param: cursor")
                }
                return ["processes": rows, "count": rows.count]
            }
            let offset = (params["cursor"] as? String).flatMap(Int.init) ?? 0
            let end = min(offset + 200, rows.count)
            var reply: [String: Any] = [
                "processes": Array(rows[offset ..< end]), "count": end - offset,
                "total": rows.count, "truncated": end < rows.count,
            ]
            if end < rows.count { reply["next_cursor"] = String(end) }
            return reply
        }
    }

    static func pids(_ result: [String: Any]) -> [Int] {
        (result["processes"] as? [[String: Any]] ?? []).compactMap { $0["pid"] as? Int }
    }

    // MARK: - Collect

    @Test func `a list within one page takes one plain call`() throws {
        let guest = FakeGuest(total: 150)
        let result = try VPhoneGuestPagedList.collect(key: "processes", fetch: guest.list)
        #expect(Self.pids(result) == Array(0 ..< 150))
        #expect(result["count"] as? Int == 150)
        #expect(guest.sent.count == 1)
        #expect(guest.sent[0].isEmpty)
    }

    @Test func `a truncated list follows next_cursor to the end`() throws {
        let guest = FakeGuest(total: 430)
        let result = try VPhoneGuestPagedList.collect(key: "processes", params: ["filter": "x"], fetch: guest.list)
        #expect(Self.pids(result) == Array(0 ..< 430))
        #expect(result["count"] as? Int == 430)
        #expect(result["truncated"] as? Bool == false)
        #expect(result["next_cursor"] == nil)
        #expect(guest.sent.map { $0["cursor"] as? String } == [nil, "200", "400"])
        #expect(guest.sent.allSatisfy { $0["filter"] as? String == "x" && $0["limit"] == nil })
    }

    @Test func `a list of exactly one page is not truncated`() throws {
        let guest = FakeGuest(total: 200)
        let result = try VPhoneGuestPagedList.collect(key: "processes", fetch: guest.list)
        #expect(Self.pids(result) == Array(0 ..< 200))
        #expect(guest.sent.count == 1)
    }

    @Test func `a guest without paging is answered by the first call`() throws {
        let guest = FakeGuest(total: 430, pages: false)
        let result = try VPhoneGuestPagedList.collect(key: "processes", fetch: guest.list)
        #expect(Self.pids(result) == Array(0 ..< 430))
        #expect(guest.sent.count == 1)
    }

    @Test func `take drives the calls by hand`() throws {
        let guest = FakeGuest(total: 1200)
        var list = VPhoneGuestPagedList(key: "processes")
        var reply = try guest.list(list.firstParams)
        while let next = try list.take(reply) {
            reply = try guest.list(next)
        }
        #expect(Self.pids(list.result(lastReply: reply)) == Array(0 ..< 1200))
        #expect(guest.sent.count == 6)
    }

    /// The offset cursor's known limit: a row that leaves the listing before
    /// the boundary between two calls shifts the next page by one.
    @Test func `an exit between pages shifts the offset cursor`() throws {
        let guest = FakeGuest(total: 300)
        var list = VPhoneGuestPagedList(key: "processes")
        var reply = try guest.list(list.firstParams)
        guest.pids.removeAll { $0 == 10 }
        while let next = try list.take(reply) {
            reply = try guest.list(next)
        }
        let pids = Self.pids(list.result(lastReply: reply))
        #expect(pids.count == 299)
        #expect(!pids.contains(200))
    }

    // MARK: - Malformed replies

    @Test func `a reply without the list is refused`() {
        #expect(throws: VPhoneGuestPagedList.Failure.self) {
            try VPhoneGuestPagedList.collect(key: "processes") { _ in ["count": 0] }
        }
    }

    @Test func `a truncated page without a cursor is refused`() {
        #expect(throws: VPhoneGuestPagedList.Failure.self) {
            try VPhoneGuestPagedList.collect(key: "processes") { _ in
                ["processes": [["pid": 1]], "truncated": true]
            }
        }
    }

    @Test func `a cursor that does not move is refused`() {
        var calls = 0
        #expect(throws: VPhoneGuestPagedList.Failure.self) {
            try VPhoneGuestPagedList.collect(key: "processes") { _ in
                calls += 1
                return ["processes": [["pid": calls]], "truncated": true, "next_cursor": "1"]
            }
        }
        #expect(calls == 2)
    }

    @Test func `a guest that never ends is cut off`() {
        var calls = 0
        #expect(throws: VPhoneGuestPagedList.Failure.self) {
            try VPhoneGuestPagedList.collect(key: "processes") { _ in
                calls += 1
                return ["processes": [["pid": calls]], "truncated": true, "next_cursor": String(calls)]
            }
        }
        #expect(calls == VPhoneGuestPagedList.maxPages)
    }
}
