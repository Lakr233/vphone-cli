import CoreGraphics
import Foundation
import ImageIO
import MachO

// MARK: - Harness

/// Checks the guest-independent parts of vphoned on the Mac: the service
/// profile lists and bookkeeping, the first-boot settle verdict (data
/// migration included), the device name rule, the pointer scroll
/// parameters, the Irisin package a guest takes and the MobileGestalt
/// answers vphoned adds, and the screenshot crop, scale and encode.
/// `run-logic-tests.sh` builds this file with those sources.
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL line \(line): \(message())")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", line: Int = #line) {
    expect(actual == expected, "\(message) expected \(expected), got \(actual)", line: line)
}

@main
enum LogicTests {
    static func main() {
        profileCatalog()
        profileCatalog26()
        profileSelection()
        neverDisableEnforcement()
        reconciliation()
        noneRestoresOnlyRecorded()
        recordRoundTrip()
        settleVerdicts()
        dataMigrationRecord()
        deviceNameRule()
        pointerScroll()
        processSpawnPolicy()
        paging()
        spawnOutputCut()
        pagedFindOrder()
        spool()
        bootstrapPlatform()
        setupAssistantState()
        homeViewDistancePolicy()
        locationServicesOffError()
        mobileGestaltAnswers()
        settingsValue()
        screenshotSizing()
        methodDispatch()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func settingsValue() {
        // Decoded the way the daemon gets its params; nil is no `value` at all.
        func typedText(_ json: String?, _ type: String?) -> String? {
            let body = json.map { "{\"value\":\($0)}" } ?? "{}"
            guard let params = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let result = GuestSettingsValue.typedText(params["value"], type: type)
            else { return nil }
            return "\(result.text)|\(result.type)"
        }
        expectEqual(typedText(nil, nil), nil, "no value")
        expectEqual(typedText("null", nil), nil, "null")
        expectEqual(typedText(nil, "string"), nil, "no value, type string")
        expectEqual(typedText("null", "string"), nil, "null, type string")
        expectEqual(typedText("5", "json"), nil, "number, type json")
        expectEqual(typedText("\"x\"", "json"), nil, "string, type json")
        expectEqual(typedText("true", nil), "1|bool")
        expectEqual(typedText("5", nil), "5|float")
        expectEqual(typedText("\"x\"", nil), "x|string")
        expectEqual(typedText("[1]", nil), "[1]|json")
        expectEqual(typedText("{\"a\":1}", nil), "{\"a\":1}|json")
        expectEqual(typedText("true", "string"), "1|string")
        expectEqual(typedText("5", "string"), "5|string")
        expectEqual(typedText("\"x\"", "string"), "x|string")
        expectEqual(typedText("[1]", "json"), "[1]|json")
        expectEqual(typedText("{\"a\":1}", "json"), "{\"a\":1}|json")
        expectEqual(typedText("\"\"", nil), "|string")
        expectEqual(typedText("false", nil), "0|bool")
        expectEqual(typedText("0", "float"), "0|float")
        expectEqual(typedText("[]", nil), "[]|json")
        expectEqual(typedText("{}", nil), "{}|json")
        // A decoded 1 or 0 is also a Bool, as it always was here.
        expectEqual(typedText("1", nil), "1|bool")
        expectEqual(typedText("0", nil), "0|bool")
    }

    static func mobileGestaltAnswers() {
        let answers = GuestMobileGestaltAnswers.alwaysOnDisplay
        func cache(_ extra: [String: Any]) -> Data {
            try! PropertyListSerialization.data(fromPropertyList: [
                "CacheData": Data([1, 2, 3]), "CacheExtra": extra, "CacheUUID": "u", "CacheVersion": "24A446",
            ], format: .binary, options: 0)
        }
        let original = cache(["ybGkijAwLTwevankfVzsDQ": Data(count: 16), "aoJSd/MXk7M40NgXTM6x+g": false])
        guard case let .updated(data) = GuestMobileGestaltAnswers.answeringYes(answers, in: original) else {
            expect(false, "a cache without the answers is updated")
            return
        }
        let plist = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let extra = plist["CacheExtra"] as! [String: Any]
        expectEqual(extra["2OOJf1VhaM7NxfRok3HbWQ"] as? Bool, true, "DeviceSupportsAlwaysOnDisplay")
        expectEqual(extra["j8/Omm6s1lsmTDFsXjsBfA"] as? Bool, true, "DeviceSupportsAlwaysOnTime")
        expectEqual(extra["aoJSd/MXk7M40NgXTM6x+g"] as? Bool, false, "the flipbook answer is left as it was")
        expectEqual(extra["ybGkijAwLTwevankfVzsDQ"] as? Data, Data(count: 16), "other answers are kept")
        expectEqual(plist["CacheData"] as? Data, Data([1, 2, 3]), "the computed answers are kept")
        expectEqual(plist["CacheVersion"] as? String, "24A446")
        expectEqual(GuestMobileGestaltAnswers.answeringYes(answers, in: data), .present, "a second pass changes nothing")
        expectEqual(GuestMobileGestaltAnswers.answeringYes(answers, in: Data("half a fi".utf8)), .unreadable)
        let noExtra = try! PropertyListSerialization.data(fromPropertyList: ["CacheVersion": "24A446"], format: .binary, options: 0)
        expectEqual(GuestMobileGestaltAnswers.answeringYes(answers, in: noExtra), .unreadable, "a cache needs CacheExtra")
    }

    static func locationServicesOffError() {
        let error = GuestAPIError.locationServicesOff
        expectEqual(error.code, "location_services_off")
        expect(error.description.contains("location.services {enabled:true}"), "the message names the RPC that turns Location Services on")
    }

    static func homeViewDistancePolicy() {
        expect(GuestHomeViewDistancePolicy.rejection(mode: "automatic", resetEnvironment: false) != nil,
            "environment-wide reset requires explicit acknowledgement before native transport")
        expect(GuestHomeViewDistancePolicy.rejection(mode: "automatic", resetEnvironment: true) == nil,
            "acknowledged environment-wide reset is admitted")
        for mode in ["near", "standard", "far"] {
            expect(GuestHomeViewDistancePolicy.rejection(mode: mode, resetEnvironment: false) == nil,
                "detail-only override preserves unrelated fields without a reset acknowledgement")
        }
        for mode in ["", "Near", "middle", "3", "automatic "] {
            expect(GuestHomeViewDistancePolicy.rejection(mode: mode, resetEnvironment: true) != nil,
                "strict native enum mapping rejects unsupported mode \(mode)")
        }
    }

    static func processSpawnPolicy() {
        let valid = GuestProcessSpawnPolicy.validate(executable: "ps", arguments: ["-axo", "pid=,ppid=,args="], timeout: 3)
        expect(valid == nil, "standard ps discovery request is accepted")
        expect(GuestProcessSpawnPolicy.validate(executable: "sh", arguments: [], timeout: 3) != nil, "shell is refused")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: Array(repeating: "x", count: 17), timeout: 3) != nil, "argument count is bounded")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [String(repeating: "x", count: 257)], timeout: 3) != nil, "argument length is bounded")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: ["x\n"], timeout: 3) != nil, "control characters are refused")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 0.09) == "timeout_ms must be 100–10000", "short timeout is refused with the range")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 10.01) == "timeout_ms must be 100–10000", "long timeout is refused with the range")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 0.1) == nil, "100 ms timeout is accepted")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 10) == nil, "10000 ms timeout is accepted")
        let refusal = GuestAPIError.invalidRequest(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 10.001) ?? "").wireBody
        expect(refusal["code"] as? String == "invalid_param" && refusal["message"] as? String == "timeout_ms must be 100–10000" && refusal["hint"] == nil,
               "timeout refusal is a hintless invalid_param naming the range")
    }

    // MARK: - Paging

    /// Probe methods whose specs declare `paged:`, dispatched through the real `GuestMethodArea`.
    enum PagingProbe: String, GuestMethod {
        case keep = "probe.keep"
        case strings = "probe.strings"
        case keys = "probe.keys"
        case pid = "probe.pid"

        var spec: MethodSpec {
            switch self {
            case .keep: MethodSpec(summary: "Fixture.", paged: MethodSpec.Paged(key: "rows", order: .keep))
            case .strings: MethodSpec(summary: "Fixture.", paged: MethodSpec.Paged(key: "matches", order: .strings))
            case .keys: MethodSpec(summary: "Fixture.", paged: MethodSpec.Paged(key: "rows", order: .keys(["bundle_id", "path"])))
            case .pid: MethodSpec(summary: "Fixture.", paged: MethodSpec.Paged(key: "rows", order: .keys(["pid"])))
            }
        }
    }

    /// Dispatches `method` over an executor that returns `result`, with params decoded as the daemon gets them.
    static func dispatchPaged(_ method: PagingProbe, _ result: [String: Any], _ params: String = "{}") throws -> [String: Any] {
        let decoded = (try? JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: Any]) ?? [:]
        let area = GuestMethodArea.make(PagingProbe.self) { _, _ in result }
        return try GuestMethodArea.dispatch([area], method: method.rawValue, params: decoded)
    }

    static func paging() {
        func page(_ result: [String: Any], _ params: String = "{}", _ method: PagingProbe = .keep) -> [String: Any]? {
            try? dispatchPaged(method, result, params)
        }
        func message(_ result: [String: Any], _ params: String) -> String {
            do { _ = try dispatchPaged(.keep, result, params); return "" } catch {
                return (error as? GuestAPIError).map { if case .invalidRequest = $0 { return String(describing: $0) } else { return "" } } ?? ""
            }
        }
        let dicts: [String: Any] = ["rows": (0 ..< 250).map { ["id": $0] as [String: Any] }, "count": 250, "path": "/x"]
        let strings: [String: Any] = ["matches": (0 ..< 250).map { String(format: "s%03d", $0) }]

        // dict rows and string rows: three pages, exact concatenation, no cursor on the last
        for (name, source, method) in [("dict", dicts, PagingProbe.keep), ("string", strings, PagingProbe.strings)] {
            var collected: [Any] = []
            var cursor: String?
            var sizes: [Int] = []
            var truncatedFlags: [Bool] = []
            var lastHasCursor = true
            for _ in 0 ..< 3 {
                let params = cursor.map { "{\"limit\":100,\"cursor\":\"\($0)\"}" } ?? "{\"limit\":100}"
                guard let reply = page(source, params, method) else { expect(false, "\(name) page failed"); break }
                let key = method == .strings ? "matches" : "rows"
                let rows = reply[key] as? [Any] ?? []
                collected += rows
                sizes.append(rows.count)
                truncatedFlags.append(reply["truncated"] as? Bool ?? false)
                expectEqual(reply["total"] as? Int, 250, "\(name) total counts entries before paging")
                cursor = reply["next_cursor"] as? String
                lastHasCursor = cursor != nil
            }
            expectEqual(sizes, [100, 100, 50], "\(name) pages")
            expectEqual(truncatedFlags, [true, true, false], "\(name) truncated flags")
            expect(!lastHasCursor, "\(name) last page has no next_cursor")
            expectEqual(json(["rows": collected]), json(["rows": source[method == .strings ? "matches" : "rows"] as Any]), "\(name) pages concatenate to the full list")
        }
        let first = page(dicts, "{\"limit\":10}")
        expectEqual((first?["rows"] as? [Any])?.count, 10, "limit 10 returns 10")
        expectEqual(first?["count"] as? Int, 10, "count is the page size")
        expectEqual(first?["path"] as? String, "/x", "other keys are kept")
        expectEqual(first?["next_cursor"] as? String, "10", "cursor is the decimal offset")
        let capped = page(dicts)
        expectEqual((capped?["rows"] as? [Any])?.count, 200, "default cap is 200")
        expectEqual(capped?["truncated"] as? Bool, true, "default cap truncates 250")
        let empty = page(["rows": [Any]()])
        expectEqual((empty?["rows"] as? [Any])?.count, 0, "empty list stays empty")
        expectEqual(empty?["truncated"] as? Bool, false, "empty list is not truncated")
        expectEqual(empty?["total"] as? Int, 0, "empty list total")
        expect(empty?["next_cursor"] == nil, "empty list has no next_cursor")
        expectEqual((page(dicts, "{\"limit\":1000}")?["rows"] as? [Any])?.count, 250, "limit 1000 is accepted")
        expectEqual((page(dicts, "{\"cursor\":\"250\"}")?["rows"] as? [Any])?.count, 0, "cursor at total is the empty last page")

        for bad in ["0", "1001", "10.5", "1e20", "true", "\"5\"", "null", "-1"] {
            let text = message(dicts, "{\"limit\":\(bad)}")
            expect(text.contains("limit") && text.contains("1 to 1000") && text.contains("got"), "limit \(bad) is invalid: \(text)")
        }
        expect(message(dicts, "{\"limit\":0}").hasSuffix("got 0"), "message carries the received value")
        for bad in ["\"abc\"", "\"-1\"", "\"+5\"", "\" 5\"", "\"251\"", "\"\"", "5", "true"] {
            let text = message(dicts, "{\"cursor\":\(bad)}")
            expect(text.contains("cursor") && text.contains("without a cursor"), "cursor \(bad) is invalid: \(text)")
        }

        // a missing or non-array key is an operation failure, never a crash
        for source: [String: Any] in [["x": 1], ["rows": "nope"]] {
            var failed = false
            do { _ = try GuestPaging.apply(source, MethodSpec.Paged(key: "rows", order: .keep), [:]) } catch { failed = true }
            expect(failed, "apply throws without an array under the key")
        }

        // strictInt, also used for max_output_bytes
        func strict(_ json: String) -> Int?? {
            let value = (try? JSONSerialization.jsonObject(with: Data("{\"v\":\(json)}".utf8)) as? [String: Any])?["v"]
            do { return try GuestPaging.strictInt(value, name: "max_output_bytes", range: 1 ... 65536) } catch { return .some(nil) }
        }
        expect(strict("1") == .some(1) && strict("65536") == .some(65536) && strict("100.0") == .some(100), "range bounds are accepted")
        expect(try! GuestPaging.strictInt(nil, name: "n", range: 1 ... 2) == nil, "an absent param is nil")

        // sorted: every order, with missing, string and wrong-typed keys
        let unsorted: [Any] = [
            ["pid": 30, "bundle_id": "b", "path": "/2"] as [String: Any], ["bundle_id": "a"] as [String: Any],
            ["pid": 5, "bundle_id": "b", "path": "/1"] as [String: Any], ["pid": 30] as [String: Any],
            ["pid": "7", "bundle_id": 9] as [String: Any],
        ]
        func pids(_ rows: [Any]) -> [Int] { rows.map { ($0 as? [String: Any])?["pid"] as? Int ?? -1 } }
        expectEqual(pids(GuestPaging.sorted(unsorted, .keys(["pid"]))), [-1, -1, 5, 30, 30], "a missing or string pid sorts as -1")
        expectEqual(GuestPaging.sorted(unsorted, .keys(["bundle_id", "path"])).map { row -> String in
            let dict = row as? [String: Any]
            return (dict?["bundle_id"] as? String ?? "") + (dict?["path"] as? String ?? "")
        }, ["", "", "a", "b/1", "b/2"], "bundle_id then path, missing and wrong-typed keys as empty")
        expectEqual(json(["rows": GuestPaging.sorted(unsorted, .keep)]), json(["rows": unsorted]), "keep leaves the order")
        expectEqual(GuestPaging.sorted(["b", "a", 3, "c"], .strings).map { $0 as? String ?? "" }, ["", "a", "b", "c"], "strings sort, a non-string sorts as empty")
        expectEqual(GuestPaging.sorted([], .keys(["nothing"])).count, 0, "sorting nothing is fine")
        let shuffled = page(["rows": unsorted], "{}", .pid)
        expectEqual(pids(shuffled?["rows"] as? [Any] ?? []), [-1, -1, 5, 30, 30], "dispatch sorts by the declared order")
    }

    // MARK: - processes.spawn output cap

    static func spawnOutputCut() {
        func cut(_ bytes: [UInt8], _ cap: Int) -> (data: Data, truncated: Bool) {
            GuestProcessSpawnPolicy.cutOutput(Data(bytes), cap: cap)
        }
        // exactly cap bytes is whole; one more is cut
        let exact = cut(Array(repeating: 0x61, count: 100), 100)
        expectEqual(exact.data.count, 100, "cap bytes stay whole")
        expect(!exact.truncated, "cap bytes are not truncated")
        let over = cut(Array(repeating: 0x61, count: 101), 100)
        expectEqual(over.data.count, 100, "cap + 1 bytes are cut to the cap")
        expect(over.truncated, "cap + 1 bytes are truncated")
        let short = cut([0x61, 0x62], 100)
        expect(!short.truncated && short.data.count == 2, "a short stream is untouched")

        // multi-byte characters: 2, 3 and 4 byte forms cut at every offset end on a character boundary
        for scalar in ["\u{E9}", "\u{20AC}", "\u{1F600}"] {
            let unit = Array(scalar.utf8)
            for pad in 0 ..< unit.count {
                let bytes = Array(repeating: UInt8(0x61), count: pad) + unit + unit + Array("tail".utf8)
                for cap in pad + 1 ... pad + unit.count + 1 {
                    let result = cut(bytes, cap)
                    expect(result.truncated, "\(scalar) pad \(pad) cap \(cap) is truncated")
                    expect(result.data.count <= cap, "\(scalar) pad \(pad) cap \(cap) stays within the cap")
                    expect(String(data: result.data, encoding: .utf8) != nil, "\(scalar) pad \(pad) cap \(cap) ends on a character boundary")
                }
            }
        }
        // a complete character right at the cap stays; a split one goes
        expectEqual(cut(Array("a\u{20AC}b".utf8), 4).data, Data(Array("a\u{20AC}".utf8)), "a character that fits at the cap stays")
        expectEqual(cut(Array("a\u{20AC}b".utf8), 3).data, Data(Array("a".utf8)), "a character the cap splits goes whole")

        let euro = Array("\u{20AC}".utf8)
        let straddle = cut(Array(repeating: 0x61, count: 98) + euro + Array("tail".utf8), 100)
        expectEqual(straddle.data.count, 98, "a 3-byte character straddling cap 100 is dropped whole")
        let fits = cut(Array(repeating: 0x61, count: 97) + euro + Array("tail".utf8), 100)
        expectEqual(fits.data.count, 100, "a 3-byte character ending exactly at cap 100 is kept")

        // no lead byte in the window: cut exactly at the cap, no error
        let run = cut(Array(repeating: 0x80, count: 200), 100)
        expect(run.truncated && run.data.count == 100, "a run of continuation bytes is cut at the cap")
        let invalid = cut(Array("valid text here".utf8) + Array(repeating: 0x61, count: 100) + [0xFF], 100)
        expect(invalid.truncated && invalid.data.count <= 100, "a stray 0xFF stays within the cap")
        let tail = cut(Array(repeating: 0x61, count: 99) + [0xFF, 0x61, 0x61], 100)
        expect(tail.truncated && tail.data.count == 100, "an invalid lead byte at the cap is cut at the cap")
        let empty = cut([], 1)
        expect(!empty.truncated && empty.data.isEmpty, "empty output is untouched")
    }

    // MARK: - files.find order

    static func pagedFindOrder() {
        let paths = (0 ..< 120).map { "/var/mobile/dir\($0 % 7)/file\($0).txt" }
        // two different input orders of the same matches
        var rotated = paths
        for _ in 0 ..< 37 { rotated.append(rotated.removeFirst()) }
        let reversed = Array(paths.reversed())
        func pages(_ input: [String]) -> [String] {
            var result: [String] = []
            var cursor: String?
            repeat {
                let params = cursor.map { "{\"limit\":50,\"cursor\":\"\($0)\"}" } ?? "{\"limit\":50}"
                guard let page = try? dispatchPaged(.strings, ["matches": input, "root": "/"], params) else {
                    expect(false, "paging the matches failed")
                    return result
                }
                result.append(json(["rows": page["matches"] ?? []]))
                cursor = page["next_cursor"] as? String
            } while cursor != nil
            return result
        }
        let reference = pages(paths)
        expectEqual(reference.count, 3, "120 matches make three pages of 50")
        expectEqual(pages(rotated), reference, "a rotated input pages identically")
        expectEqual(pages(reversed), reference, "a reversed input pages identically")
    }

    // MARK: - processes.spawn spool

    final class TestClock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)
    }

    static func failure(_ body: () throws -> Void) -> (kind: String, message: String)? {
        do { try body(); return nil } catch let error as GuestAPIError { return (error.code, error.description) } catch { return ("other", "\(error)") }
    }

    static let releasedText = "is released, expired or evicted; repeat processes.spawn to capture the output again"

    /// A fresh parent dir with a `spool` root inside it (not created yet).
    static func spoolParent() -> (parent: URL, root: URL) {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vphone-spool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (parent, parent.appendingPathComponent("spool"))
    }

    /// Spools `stdout` bytes through the real reserve, writer and finish path.
    @discardableResult
    static func fill(_ spool: GuestProcessSpool, _ stdout: Data, stderr: Data = Data(), capture: Int = 100, keep: Bool = true) throws -> GuestProcessSpool.Reservation {
        let r = try spool.reserve(maxCaptureBytes: capture)
        try spool.writer(r, stream: "stdout").write(contentsOf: stdout)
        try spool.writer(r, stream: "stderr").write(contentsOf: stderr)
        spool.finish(r, keep: keep)
        return r
    }

    static func mode(_ url: URL) -> Int {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
    }

    static func spool() {
        let (parent, root) = spoolParent()
        defer { chmodTree(parent); try? FileManager.default.removeItem(at: parent) }
        let clock = TestClock()
        var logged: [String] = []
        let store = GuestProcessSpool(root: root, totalCap: 1000, now: { clock.date }, log: { logged.append($0) })

        // slices: successive next_offset values concatenate byte-exactly; a normal spool is private
        let bytes = Data((0 ..< 700).map { UInt8($0 % 251) })
        guard let r = try? fill(store, bytes, stderr: Data("err".utf8)) else { expect(false, "a spool is created"); return }
        expectEqual(mode(root), 0o700, "the spool root is 0700")
        expectEqual(mode(r.outputDir), 0o700, "a spool dir is 0700")
        expectEqual(mode(r.outputDir.appendingPathComponent("stdout")), 0o600, "a stream file is 0600")
        var joined = Data()
        var offset = 0
        var slices = 0
        while true {
            guard let slice = try? store.slice(outputID: r.outputID, stream: "stdout", offset: offset, limit: 300, binary: true) else { expect(false, "slice failed"); break }
            joined.append(Data(base64Encoded: slice.data) ?? Data())
            expectEqual(slice.total, 700, "total counts the raw bytes captured")
            slices += 1
            guard let next = slice.nextOffset else { break }
            offset = next
        }
        expectEqual(joined, bytes, "binary slices join to the captured bytes")
        expectEqual(slices, 3, "700 bytes make three slices of 300")
        let past = try? store.slice(outputID: r.outputID, stream: "stdout", offset: 5000, limit: 300, binary: false)
        expect(past?.data == "" && past?.nextOffset == nil && past?.total == 700, "an offset past the end gives empty data")
        expectEqual(try? store.slice(outputID: r.outputID.lowercased(), stream: "stderr", offset: 0, limit: 10, binary: false).data, "err", "a lowercase UUID reads the same spool")

        // a 3-byte character split across slices joins back; text mode cuts on a boundary
        let euros = Data(Array("aa\u{20AC}\u{20AC}b".utf8))
        if let e = try? fill(store, euros) {
            var parts = Data()
            var at = 0
            while let slice = try? store.slice(outputID: e.outputID, stream: "stdout", offset: at, limit: 4, binary: true) {
                parts.append(Data(base64Encoded: slice.data) ?? Data())
                guard let next = slice.nextOffset else { break }
                at = next
            }
            expectEqual(parts, euros, "a split character joins to the original bytes")
            let text = try? store.slice(outputID: e.outputID, stream: "stdout", offset: 0, limit: 4, binary: false)
            expectEqual(text?.data, "aa", "text mode drops a character the slice end splits")
            expectEqual(text?.nextOffset, 2, "next_offset counts the raw bytes returned")
        } else { expect(false, "euro spool") }
        if let tiny = try? fill(store, Data(Array("\u{20AC}".utf8))) {
            let stalled = try? store.slice(outputID: tiny.outputID, stream: "stdout", offset: 0, limit: 1, binary: false)
            expectEqual(stalled?.nextOffset, 1, "a limit inside the first character still advances")
        }

        // a max-length 0xFF run decodes to at most 3 times the cap
        let roomy = GuestProcessSpool(root: root, log: { _ in })
        if let ff = try? fill(roomy, Data(repeating: 0xFF, count: 65536), capture: 65536) {
            let page = try? roomy.firstPage(outputID: ff.outputID, stream: "stdout", cap: 65536)
            expect((page?.text.utf8.count ?? .max) <= 196_608, "firstPage of 65536 x 0xFF is at most 196608 bytes")
            let text = try? roomy.slice(outputID: ff.outputID, stream: "stdout", offset: 0, limit: 65536, binary: false)
            expect((text?.data.utf8.count ?? .max) <= 196_608, "a text slice of 65536 x 0xFF is at most 196608 bytes")
        } else { expect(false, "0xFF spool") }

        // firstPage reports truncated only when more than cap bytes were spooled
        for (size, expected) in [(9, false), (10, false), (11, true)] {
            if let spool = try? fill(roomy, Data(repeating: 0x61, count: size), capture: 100),
               let page = try? roomy.firstPage(outputID: spool.outputID, stream: "stdout", cap: 10) {
                expect(page.truncated == expected && page.text.utf8.count == min(size, 10), "firstPage of \(size) bytes at cap 10: truncated \(expected)")
            } else { expect(false, "firstPage spool of \(size) bytes") }
        }

        // hostile and unknown ids; invalid stream
        for hostile in ["../../etc/passwd", "/", "", "not-a-uuid"] {
            let read = failure { _ = try store.slice(outputID: hostile, stream: "stdout", offset: 0, limit: 10, binary: false) }
            expect(read?.kind == "invalid_param" && read?.message == "output_id must be a UUID", "slice rejects id '\(hostile)': \(String(describing: read))")
            let page = failure { _ = try store.firstPage(outputID: hostile, stream: "stdout", cap: 10) }
            expect(page?.message == "output_id must be a UUID", "firstPage rejects id '\(hostile)'")
            let drop = failure { try store.release(outputID: hostile) }
            expect(drop?.kind == "invalid_param" && drop?.message == "output_id must be a UUID", "release rejects id '\(hostile)'")
        }
        let unknown = UUID().uuidString
        let missing = failure { _ = try store.slice(outputID: unknown, stream: "stdout", offset: 0, limit: 10, binary: false) }
        expect(missing?.kind == "not_found" && missing?.message == "output_id \(unknown) \(releasedText)", "an unknown UUID is released/expired/evicted: \(String(describing: missing))")
        expect(failure { try store.release(outputID: unknown) }.map { $0.kind == "not_found" && $0.message == "output_id \(unknown) \(releasedText)" } == true, "release of an unknown UUID")
        let badStream = failure { _ = try store.slice(outputID: r.outputID, stream: "both", offset: 0, limit: 10, binary: false) }
        expect(badStream?.kind == "invalid_param" && badStream?.message.contains("stream") == true, "an unknown stream names the param")
        expectEqual(FileManager.default.fileExists(atPath: parent.appendingPathComponent("etc").path), false, "nothing outside the root is created")

        // stream files removed after the id check give the released text
        if let gone = try? fill(store, Data("x".utf8)) {
            try? FileManager.default.removeItem(at: gone.outputDir.appendingPathComponent("stdout"))
            let result = failure { _ = try store.slice(outputID: gone.outputID, stream: "stdout", offset: 0, limit: 10, binary: false) }
            expect(result?.kind == "not_found" && result?.message == "output_id \(gone.outputID) \(releasedText)", "a removed stream file reads as released")
            try? store.release(outputID: gone.outputID)
        }

        // strictInt for the offset, limit and capture params
        func strict(_ json: String, _ name: String, _ range: ClosedRange<Int>) -> String? {
            let value = (try? JSONSerialization.jsonObject(with: Data("{\"v\":\(json)}".utf8)) as? [String: Any])?["v"]
            do { _ = try GuestPaging.strictInt(value, name: name, range: range); return nil } catch GuestAPIError.invalidRequest(let text, _) { return text } catch { return "other" }
        }
        for bad in ["-1", "10.5", "1e20", "9223372036854775808", "18446744073709551621", "true", "\"5\"", "1099511627777", "1e300"] {
            let text = strict(bad, "offset", 0 ... 1_099_511_627_776)
            expect(text?.contains("offset") == true && text?.contains("0 to 1099511627776") == true && text?.contains("got") == true, "offset \(bad): \(text ?? "accepted")")
        }
        for bad in ["0", "65537", "-1", "10.5", "1e20", "9223372036854775808", "18446744073709551621", "true", "\"5\""] {
            let text = strict(bad, "limit", 1 ... 65536)
            expect(text?.contains("limit") == true && text?.contains("1 to 65536") == true && text?.contains("got") == true, "limit \(bad): \(text ?? "accepted")")
        }
        for bad in ["0", "16777217", "10.5", "18446744073709551621", "true"] {
            let text = strict(bad, "max_capture_bytes", 1 ... 16_777_216)
            expect(text?.contains("max_capture_bytes") == true && text?.contains("1 to 16777216") == true && text?.contains("got") == true, "max_capture_bytes \(bad): \(text ?? "accepted")")
        }
        expect(strict("0", "offset", 0 ... 1_099_511_627_776) == nil && strict("1099511627776", "offset", 0 ... 1_099_511_627_776) == nil, "offset bounds are accepted")

        spoolLifecycle(clock: clock)
        spoolSafety()
    }

    static func chmodTree(_ url: URL) {
        for case let item as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) ?? NSEnumerator() { chmod(item.path, 0o700) }
    }

    static func spoolLifecycle(clock: TestClock) {
        let (parent, root) = spoolParent()
        defer { chmodTree(parent); try? FileManager.default.removeItem(at: parent) }
        clock.date = Date(timeIntervalSince1970: 1_000_000)
        var logged: [String] = []
        let store = GuestProcessSpool(root: root, totalCap: 1000, now: { clock.date }, log: { logged.append($0) })
        func readable(_ r: GuestProcessSpool.Reservation) -> Bool {
            (try? store.slice(outputID: r.outputID, stream: "stdout", offset: 0, limit: 10, binary: false)) != nil
        }
        let blob = Data(repeating: 0x61, count: 300)

        // TTL: 10 minutes from creation, then release
        guard let old = try? fill(store, blob) else { expect(false, "spool created"); return }
        clock.date += 599
        expect(readable(old), "a spool is readable before the TTL")
        clock.date += 2
        let expired = failure { _ = try store.slice(outputID: old.outputID, stream: "stdout", offset: 0, limit: 10, binary: false) }
        expect(expired?.kind == "not_found" && expired?.message == "output_id \(old.outputID) \(releasedText)", "an expired spool reads as released")
        expectEqual(FileManager.default.fileExists(atPath: old.outputDir.path), false, "an expired spool is removed")
        if let gone = try? fill(store, blob) {
            try? store.release(outputID: gone.outputID)
            expect(!readable(gone) && !FileManager.default.fileExists(atPath: gone.outputDir.path), "release removes the files and later reads fail")
            expectEqual(failure { try store.release(outputID: gone.outputID) }?.kind, "not_found", "a second release is not_found")
        }

        // eviction: the oldest goes first and the newest stays; still no room is "spool full"
        var spools: [GuestProcessSpool.Reservation] = []
        for _ in 0 ..< 3 {
            clock.date += 1
            if let s = try? fill(store, blob) { spools.append(s) }
        }
        clock.date += 1
        if let fourth = try? fill(store, blob) {
            spools.append(fourth)
            expect(!readable(spools[0]), "the oldest spool is evicted first")
            expect(readable(spools[1]) && readable(spools[2]) && readable(spools[3]), "newer spools stay")
        } else { expect(false, "creation past the cap evicts and succeeds") }
        let full = failure { _ = try store.reserve(maxCaptureBytes: 600) }
        expect(full?.kind == "unavailable" && full?.message == "spool full: release outputs with processes.output_release or repeat later", "a reservation that cannot fit is spool full: \(String(describing: full))")
        for s in spools { try? store.release(outputID: s.outputID) }

        // a spawn that has not replied is never evicted
        if let inflight = try? store.reserve(maxCaptureBytes: 400) {
            let blocked = failure { _ = try store.reserve(maxCaptureBytes: 200) }
            expect(blocked?.message.hasPrefix("spool full:") == true, "an in-flight reservation is not evicted")
            store.finish(inflight, keep: false)
            expect((try? store.reserve(maxCaptureBytes: 200)) != nil, "a released reservation lets the creation succeed")
        } else { expect(false, "in-flight reservation") }
        store.sweepAll()

        // two concurrent creations under a cap that forces eviction both stay readable
        _ = try? fill(store, Data(repeating: 0x62, count: 700))
        let lock = NSLock()
        final class Made: @unchecked Sendable { var list: [GuestProcessSpool.Reservation] = [] }
        let box = Made()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            if let r = try? fill(store, Data("hello".utf8), capture: 200) {
                lock.lock(); box.list.append(r); lock.unlock()
            }
        }
        let made = box.list
        expectEqual(made.count, 2, "both concurrent creations succeed")
        expect(made.allSatisfy(readable), "both concurrent spools are readable")
        store.sweepAll()

        // failed exit paths (write error, timeout, launch failure) leave nothing and free the reservation
        if let failed = try? store.reserve(maxCaptureBytes: 400) {
            _ = try? store.writer(failed, stream: "stdout")
            let again = failure { _ = try store.writer(failed, stream: "stdout") }
            expect(again?.kind == "invalid_operation" && again?.message.hasPrefix("spool write failed: ") == true && again?.message.hasSuffix("; repeat the command") == true, "a stream write failure: \(String(describing: again))")
            store.finish(failed, keep: false)
            expectEqual(FileManager.default.fileExists(atPath: failed.outputDir.path), false, "a failed spawn leaves no subdir")
            expect(!readable(failed), "a failed spawn's id is unreadable")
            expect((try? fill(store, blob, capture: 400)) != nil, "a same-size creation succeeds after a failed one")
        } else { expect(false, "reservation for the failure path") }
        store.sweepAll()

        // restart: a new store over the same dir removes the old subdirs
        _ = try? fill(store, blob)
        _ = try? fill(store, blob)
        let restarted = GuestProcessSpool(root: root, totalCap: 1000, now: { clock.date }, log: { logged.append($0) })
        restarted.sweepAll()
        expectEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count, 0, "the startup sweep removes old subdirs")

        // an undeletable old spool does not fail a new creation
        if let stuck = try? fill(store, blob) {
            chmod(stuck.outputDir.path, 0o500)
            clock.date += 601
            expect((try? fill(store, blob)) != nil, "an undeletable expired spool does not fail a new creation")
            chmod(stuck.outputDir.path, 0o700)
        }
    }

    static func spoolSafety() {
        let (parent, root) = spoolParent()
        defer { chmodTree(parent); try? FileManager.default.removeItem(at: parent) }
        let unsafe = "is not private (it must be a daemon-owned 0700 directory, not a symlink); remove it on the guest and repeat"
        let target = parent.appendingPathComponent("target")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // root as a symlink: creation fails, nothing is written through it
        symlink(target.path, root.path)
        var logged: [String] = []
        let linked = GuestProcessSpool(root: root, log: { logged.append($0) })
        let viaLink = failure { _ = try linked.reserve(maxCaptureBytes: 10) }
        expect(viaLink?.kind == "invalid_operation" && viaLink?.message == "spool directory \(root.path) \(unsafe)", "a symlink root is refused: \(String(describing: viaLink))")
        expectEqual((try? FileManager.default.contentsOfDirectory(atPath: target.path))?.count, 0, "nothing is written through the symlink")

        // a fresh store (restart) over a root symlinked to a dir holding a subdir leaves it
        let kept = target.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        GuestProcessSpool(root: root, log: { logged.append($0) }).sweepAll()
        expect(FileManager.default.fileExists(atPath: kept.path), "the startup sweep leaves a symlinked root's target alone")
        expect(!logged.isEmpty, "the refused sweep is logged")
        unlink(root.path)

        // a pre-created 0777 root is refused and stays empty
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o777)
        let loose = failure { _ = try GuestProcessSpool(root: root, log: { _ in }).reserve(maxCaptureBytes: 10) }
        expect(loose?.kind == "invalid_operation" && loose?.message == "spool directory \(root.path) \(unsafe)", "a 0777 root is refused: \(String(describing: loose))")
        expectEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count, 0, "the 0777 root stays empty")
        try? FileManager.default.removeItem(at: root)

        // the root replaced by a symlink after a spool exists: release, TTL sweep and reserve leave the target intact
        let clock = TestClock()
        let store = GuestProcessSpool(root: root, totalCap: 1000, now: { clock.date }, log: { logged.append($0) })
        guard let a = try? fill(store, Data("a".utf8)), let b = try? fill(store, Data("b".utf8)) else { expect(false, "spools created"); return }
        try? FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("moved"))
        symlink(target.path, root.path)
        let planted = [a, b].map { target.appendingPathComponent($0.outputID) }
        for dir in planted { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try? store.release(outputID: a.outputID)
        clock.date += 601
        _ = try? store.reserve(maxCaptureBytes: 10)
        expect(planted.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "release, TTL sweep and reserve leave the symlink target intact")
    }

    // MARK: - Setup Assistant

    static func setupAssistantState() {
        for machine in ["AppleTV5,3", "AppleTV18,1"] {
            expect(GuestSetupAssistantState.usesTVPolicy(machine: machine), "TV policy for \(machine)")
        }
        for machine in ["iPhone17,3", "iPad16,1", "AudioAccessory5,1", ""] {
            expect(!GuestSetupAssistantState.usesTVPolicy(machine: machine), "existing policy for \(machine)")
        }
        expect(GuestSetupAssistantState.usesHomeViewPolicy(machine: "HomeAccessory17,1"), "HomeView native setup policy")
        expect(!GuestSetupAssistantState.usesHomeViewPolicy(machine: "AudioAccessory5,1"), "HomePod keeps its policy")
        for done in [false, true] {
            for bypass in [false, true] {
                let home = GuestSetupAssistantState(setupDone: done, version: nil, currentVersion: nil,
                    requiresTVCompletion: false, tvCompleted: false,
                    requiresHomeViewCompletion: true, forceNoBuddy: bypass)
                expect(home.pending == (!done && !bypass), "HomeView reads native completion or ForceNoBuddy without an iOS version")
            }
        }
        func state(_ done: Bool, _ version: Int?, _ current: Int?, tv: Bool = true, completed: Bool = true) -> GuestSetupAssistantState {
            GuestSetupAssistantState(setupDone: done, version: version, currentVersion: current, requiresTVCompletion: tv, tvCompleted: completed)
        }
        expect(!state(true, 15, 15).pending, "native TV completion with its current version")
        expect(!state(true, 16, 15).pending, "newer recorded TV version")
        expect(state(false, 15, 15).pending, "TV SetupDone remains required")
        expect(state(true, 14, 15).pending, "TV update setup remains pending")
        expect(state(true, nil, 15).pending, "missing TV version is pending")
        expect(state(true, 15, 15, completed: false).pending, "native TV success flag remains required")
        expect(state(true, 15, nil).pending, "unknown TV current version cannot prove completion")
        expect(!state(true, 11, 11, tv: false, completed: false).pending, "iPhone ignores the TV flag")
        expect(state(false, 11, 11, tv: false).pending, "iPhone SetupDone remains required")
        expect(state(true, 10, 11, tv: false).pending, "iPhone update version remains required")
        expect(!state(true, nil, nil, tv: false).pending, "existing unknown-version fallback")
        expect(state(true, nil, 11, tv: false).pending, "HomePod keeps its existing version policy")
    }

    // MARK: - Service Profile

    static let labelPattern = "^[A-Za-z0-9][A-Za-z0-9._:\\[\\]-]{0,200}$"

    static func profileCatalog() {
        let groups = GuestServiceProfile.groups27
        expectEqual(GuestServiceProfile.base27.count, 133, "appendix A less siriactionsd, passd, financed and generativeexperiencesd")
        expectEqual(Set(GuestServiceProfile.base27).count, 133, "appendix A has no duplicates")
        let all = groups.flatMap(\.labels)
        expectEqual(Set(all).count, all.count, "no label is in two groups")
        for label in all + GuestServiceProfile.neverDisable {
            expect(label.range(of: labelPattern, options: .regularExpression) != nil, "\(label) is a valid label")
        }
        expectEqual(groups.map(\.name), ["base", "app_store", "signin_followup", "accounts"])
        expectEqual(groups.filter(\.byDefault).map(\.name), ["base", "app_store", "signin_followup"])
        expect(GuestServiceProfile.base27.contains("com.apple.appstorecomponentsd"), "appstorecomponentsd is in base")
        expect(GuestServiceProfile.groups(iosMajor: 25) == nil, "no list for iOS 25")
        expect(GuestServiceProfile.groups(iosMajor: 28) == nil, "no list for iOS 28")
        expect(GuestServiceProfile.groups(iosMajor: 26) != nil, "a list for iOS 26")
        expect(GuestServiceProfile.groups(iosMajor: 27) != nil, "a list for iOS 27")
        expectEqual(GuestServiceProfile.supportedMajors, [26, 27])
    }

    static func profileCatalog26() {
        let base26 = GuestServiceProfile.base26
        expectEqual(base26.count, 127, "133 minus six 26.6.2 does not load")
        expectEqual(Set(base26).count, base26.count, "no duplicates")
        expect(Set(base26).isSubset(of: GuestServiceProfile.base27), "26 adds no label of its own")
        expect(GuestServiceProfile.notLoadedOn26.isSubset(of: GuestServiceProfile.base27), "only 27 labels are left out")
        expect(Set(base26).isDisjoint(with: GuestServiceProfile.notLoadedOn26), "what 26 does not load is left out")
        for label in ["com.apple.cloudtelemetryd", "com.apple.hybridsearchd", "com.apple.safetyalertsd"] {
            expect(!base26.contains(label), "\(label) is not in the 26 list")
        }
        let groups = GuestServiceProfile.groups26
        expectEqual(groups.map(\.name), GuestServiceProfile.groups27.map(\.name), "same groups as 27")
        expectEqual(groups.filter(\.byDefault).map(\.name), ["base", "app_store", "signin_followup"])
        expectEqual(groups.first?.labels, base26, "base is the 26 list")
        expectEqual(
            groups.dropFirst().map(\.labels), GuestServiceProfile.groups27.dropFirst().map(\.labels),
            "store, follow-up and account labels are the same on 26",
        )
        let all = groups.flatMap(\.labels)
        expectEqual(Set(all).count, all.count, "no label is in two 26 groups")
    }

    static func profileSelection() {
        let trimmed = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 27)
        expectEqual(trimmed?.labels.count, 137, "default trimmed = 133 + 2 store + 2 follow-up")
        expectEqual(trimmed?.groups, ["base", "app_store", "signin_followup"])
        expect(trimmed?.labels.contains("com.apple.followupd") == true, "followupd is in trimmed")
        expect(trimmed?.labels.contains("com.apple.akd") == false, "akd is not in trimmed by default")
        expect(trimmed?.labels.contains("com.apple.siriactionsd") == false, "siriactionsd serves App Intents controls")
        expect(GuestServiceProfile.neverDisable.contains("com.apple.siriactionsd"), "siriactionsd is never disabled")
        expect(trimmed?.labels.contains("com.apple.passd") == false && trimmed?.labels.contains("com.apple.financed") == false, "Wallet's daemons stay")
        expect(trimmed?.labels.contains("com.apple.generativeexperiencesd") == false, "BackgroundShortcutRunner spins without it")
        if let labels = trimmed?.labels {
            // A guest trimmed by list version 3 owns it; applying again turns it back on.
            let v3 = labels + ["com.apple.generativeexperiencesd"]
            let change = GuestServiceProfile.reconcile(
                target: labels, owned: v3, overrides: Dictionary(uniqueKeysWithValues: v3.map { ($0, true) }),
            )
            expectEqual(change.enable, ["com.apple.generativeexperiencesd"], "list version 3 guests get it back")
        }
        expectEqual(trimmed?.labels, trimmed?.labels.sorted(), "labels sorted")

        let accounts = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 27, extraGroups: ["accounts"])
        expectEqual(accounts?.labels.count, 140, "accounts adds three")
        expect(accounts?.labels.contains("com.apple.amsaccountsd") == true, "amsaccountsd with accounts")

        let allowed = try? GuestServiceProfile.select(
            profile: "trimmed", iosMajor: 27, allow: ["com.apple.weatherd", "com.example.not-listed"],
        )
        expectEqual(allowed?.labels.count, 136, "allow removes one")
        expectEqual(allowed?.allowed, ["com.apple.weatherd"], "only catalog labels are reported as allowed")
        expect(allowed?.labels.contains("com.apple.weatherd") == false, "weatherd kept")

        let trimmed26 = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 26)
        expectEqual(trimmed26?.labels.count, 131, "26 trimmed = 127 + 2 store + 2 follow-up")
        expectEqual(trimmed26?.groups, ["base", "app_store", "signin_followup"])
        expect(trimmed26?.refused.isEmpty == true, "the 26 list names nothing never disabled")
        expectEqual(
            (try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 26, extraGroups: ["accounts"]))?.labels.count,
            134, "accounts adds three on 26",
        )

        expectEqual(try? GuestServiceProfile.select(profile: "none", iosMajor: 25), GuestServiceProfile.Selection())
        expectThrows(.unsupported(iosMajor: 25)) { try GuestServiceProfile.select(profile: "trimmed", iosMajor: 25) }
        expectEqual(
            GuestServiceProfile.Failure.unsupported(iosMajor: 25).description,
            "No trimmed service list for iOS 25; lists exist for iOS 26, 27",
        )
        expectThrows(.unknownGroup("bogus")) {
            try GuestServiceProfile.select(profile: "trimmed", iosMajor: 27, extraGroups: ["bogus"])
        }
        expectThrows(.unknownProfile("lean")) { try GuestServiceProfile.select(profile: "lean", iosMajor: 27) }
    }

    static func expectThrows(_ expected: GuestServiceProfile.Failure, line: Int = #line, _ body: () throws -> Any) {
        do {
            _ = try body()
            expect(false, "expected \(expected)", line: line)
        } catch let failure as GuestServiceProfile.Failure {
            expectEqual(failure, expected, line: line)
        } catch {
            expect(false, "unexpected \(error)", line: line)
        }
    }

    static func neverDisableEnforcement() {
        for group in GuestServiceProfile.groups27 + GuestServiceProfile.groups26 {
            let overlap = Set(group.labels).intersection(GuestServiceProfile.neverDisable)
            expect(overlap.isEmpty, "\(group.name) names never-disabled \(overlap.sorted())")
        }
        for trap in [
            "com.apple.sleepd", "com.apple.generativeexperiencesd", "com.apple.CommCenter",
            "com.apple.CommCenterMobileHelper", "com.apple.CommCenterRootHelper", "com.apple.cloudd", "com.apple.nanoregistryd",
            "com.apple.nanoregistrylaunchd", "com.apple.mobileassetd", "com.apple.storekitd",
            "com.apple.cfprefsd.xpc.daemon", "com.apple.SpringBoard", "com.apple.backboardd",
            "com.apple.mobile.installd", "com.apple.lsd", "com.apple.mobileactivationd",
            "com.apple.locationd", "com.apple.bluetoothd", "com.vphone.vphoned",
        ] {
            expect(GuestServiceProfile.neverDisable.contains(trap), "\(trap) is never disabled")
        }
        // Even a target that names them, as a future list might, leaves them alone.
        let change = GuestServiceProfile.reconcile(
            target: ["com.apple.sleepd", "com.apple.tipsd"], owned: [], overrides: [:],
        )
        expectEqual(change.disable, ["com.apple.tipsd"])
        expectEqual(change.skipped, [GuestServiceProfile.Skip(label: "com.apple.sleepd", reason: "never disabled")])
    }

    static func reconciliation() {
        let overrides = [
            "com.apple.a": true, // disabled by the profile earlier
            "com.apple.b": true, // disabled by somebody else (the OTA block)
            "com.apple.d": true, // owned, no longer selected
            "com.apple.e": false, // owned, re-enabled by the user
        ]
        let change = GuestServiceProfile.reconcile(
            target: ["com.apple.a", "com.apple.b", "com.apple.c"],
            owned: ["com.apple.a", "com.apple.d", "com.apple.e"],
            overrides: overrides,
        )
        expectEqual(change.keep, ["com.apple.a"])
        expectEqual(change.disable, ["com.apple.c"])
        expectEqual(change.enable, ["com.apple.d"])
        expectEqual(change.skipped, [
            GuestServiceProfile.Skip(label: "com.apple.b", reason: GuestServiceProfile.disabledElsewhere),
            GuestServiceProfile.Skip(label: "com.apple.e", reason: GuestServiceProfile.enabledElsewhere),
        ])
        expectEqual(
            GuestServiceProfile.owned(after: change, failedDisable: [], failedEnable: []),
            ["com.apple.a", "com.apple.c"], "owned after success",
        )
        expectEqual(
            GuestServiceProfile.owned(after: change, failedDisable: ["com.apple.c"], failedEnable: ["com.apple.d"]),
            ["com.apple.a", "com.apple.d"], "a failed disable is not owned; a failed enable stays owned",
        )

        // Applying again once the overrides reflect the first apply changes nothing.
        let after = ["com.apple.a": true, "com.apple.b": true, "com.apple.c": true, "com.apple.e": false]
        let again = GuestServiceProfile.reconcile(
            target: ["com.apple.a", "com.apple.b", "com.apple.c"], owned: ["com.apple.a", "com.apple.c"], overrides: after,
        )
        expect(again.disable.isEmpty && again.enable.isEmpty, "idempotent")
        expectEqual(again.keep, ["com.apple.a", "com.apple.c"])
    }

    static func noneRestoresOnlyRecorded() {
        // The OTA trio was disabled before the profile ran, so it was never owned.
        let ota = ["com.apple.mobile.softwareupdated", "com.apple.OTATaskingAgent", "com.apple.softwareupdateservicesd"]
        guard let trimmed = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 27) else {
            return expect(false, "trimmed selects")
        }
        var overrides = Dictionary(uniqueKeysWithValues: ota.map { ($0, true) })
        overrides["com.apple.user-choice"] = true
        let apply = GuestServiceProfile.reconcile(target: trimmed.labels, owned: [], overrides: overrides)
        expectEqual(apply.disable.count, 134, "137 minus the three already disabled")
        expectEqual(apply.skipped.map(\.label), ota.sorted())
        let owned = GuestServiceProfile.owned(after: apply, failedDisable: [], failedEnable: [])
        for label in apply.disable {
            overrides[label] = true
        }

        let restore = GuestServiceProfile.reconcile(target: [], owned: owned, overrides: overrides)
        expectEqual(restore.enable, owned, "none enables exactly what the profile owned")
        expect(Set(restore.enable).isDisjoint(with: ota), "the OTA trio stays disabled")
        expect(!restore.enable.contains("com.apple.user-choice"), "a user's override stays")
        expectEqual(GuestServiceProfile.owned(after: restore, failedDisable: [], failedEnable: []), [])
    }

    static func recordRoundTrip() {
        let directory = NSTemporaryDirectory() + "vphoned-logic-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/db/service-profile.plist"
        expect(GuestServiceProfile.readRecord(at: path) == nil, "no record yet")
        let record = GuestServiceProfile.Record(
            profile: "trimmed", listVersion: 1, iosMajor: 27, groups: ["base"], allow: ["com.apple.weatherd"],
            labels: ["com.apple.tipsd"], updated: Date(timeIntervalSince1970: 1_791_331_200),
        )
        do {
            try GuestServiceProfile.writeRecord(record, to: path)
        } catch {
            return expect(false, "write: \(error)")
        }
        expectEqual(GuestServiceProfile.readRecord(at: path), record, "record round-trips")
        expect(GuestServiceProfile.Record(propertyList: ["Profile": "none"]) == nil, "a record needs Labels")
        expectEqual(record.json["updated"] as? String, "2026-10-07T00:00:00Z")
    }

    // MARK: - First-Boot Settle

    typealias Sample = GuestFirstBootSettle.Sample

    static func sample(_ time: Double, staged: Int? = 0, apps: Int? = 248, pid: Int? = 90, cpu: Double? = 1.0) -> Sample {
        Sample(time: time, stagedSystemApps: staged, appCount: apps, installdPID: pid, installdCPUSeconds: cpu)
    }

    static func settleVerdicts() {
        let quiet = [sample(0), sample(5, cpu: 1.05), sample(10, cpu: 1.1)]
        let verdict = GuestFirstBootSettle.evaluate(quiet, stablePolls: 3)
        expect(verdict.settled, "quiet polls settle: \(verdict.reasons)")
        expectEqual(verdict.installdCPUDelta.map { ($0 * 100).rounded() }, 5)

        expect(!GuestFirstBootSettle.evaluate(Array(quiet.prefix(2)), stablePolls: 3).settled, "too few polls")
        expect(GuestFirstBootSettle.evaluate(quiet, stablePolls: 1).settled, "at least two polls even when asked for one")

        let staged = GuestFirstBootSettle.evaluate([sample(0), sample(5), sample(10, staged: 4)], stablePolls: 3)
        expect(!staged.settled && staged.reasons == ["staged_system_apps has 4 entries"], "\(staged.reasons)")

        let emptied = GuestFirstBootSettle.evaluate([sample(0, staged: 2), sample(5), sample(10)], stablePolls: 3)
        expectEqual(emptied.reasons, ["staged_system_apps only just emptied"])

        let unreadable = GuestFirstBootSettle.evaluate([sample(0), sample(5), sample(10, staged: nil)], stablePolls: 3)
        expectEqual(unreadable.reasons, ["staged_system_apps could not be read"])

        let growing = GuestFirstBootSettle.evaluate([sample(0, apps: 250), sample(5, apps: 258), sample(10, apps: 258)], stablePolls: 3)
        expectEqual(growing.reasons, ["app count changed: 250 → 258 → 258"])

        let unknownApps = GuestFirstBootSettle.evaluate([sample(0), sample(5, apps: nil), sample(10)], stablePolls: 3)
        expectEqual(unknownApps.reasons, ["app count unavailable"])

        let busy = GuestFirstBootSettle.evaluate([sample(0), sample(5, cpu: 3.0), sample(10, cpu: 3.1)], stablePolls: 3)
        expectEqual(busy.reasons, ["installd used 2.00 s CPU between polls"])

        // An older busy poll outside the window no longer counts.
        let recovered = GuestFirstBootSettle.evaluate(
            [sample(0), sample(5, cpu: 3.0), sample(10, cpu: 3.05), sample(15, cpu: 3.1)], stablePolls: 2,
        )
        expect(recovered.settled, "window of two: \(recovered.reasons)")

        // installd exiting counts as idle; a new installd counts all of its CPU.
        let exited = [sample(0), sample(5, pid: nil, cpu: nil), sample(10, pid: nil, cpu: nil)]
        expect(GuestFirstBootSettle.evaluate(exited, stablePolls: 3).settled, "installd gone is idle")
        let restarted = GuestFirstBootSettle.evaluate([sample(0), sample(5, pid: nil, cpu: nil), sample(10, pid: 120, cpu: 0.9)], stablePolls: 3)
        expectEqual(restarted.reasons, ["installd used 0.90 s CPU between polls"])
        let restartedIdle = GuestFirstBootSettle.evaluate([sample(0), sample(5, pid: 120, cpu: 0.05), sample(10, pid: 120, cpu: 0.06)], stablePolls: 3)
        expect(restartedIdle.settled, "a new, idle installd: \(restartedIdle.reasons)")

        // Data migration holds the verdict back until the latest poll has it
        // done; an unknown state (no build version) does not.
        func migrating(_ time: Double, _ done: Bool?) -> Sample {
            var polled = sample(time)
            polled.dataMigrationDone = done
            return polled
        }
        let pending = GuestFirstBootSettle.evaluate([migrating(0, false), migrating(5, false), migrating(10, false)], stablePolls: 3)
        expectEqual(pending.reasons, ["data migration has not finished"])
        let finished = GuestFirstBootSettle.evaluate([migrating(0, false), migrating(5, false), migrating(10, true)], stablePolls: 3)
        expect(finished.settled, "migration done in the latest poll: \(finished.reasons)")
        expect(GuestFirstBootSettle.evaluate([migrating(0, nil), migrating(5, nil), migrating(10, nil)], stablePolls: 3).settled, "unknown is not pending")
        let stillStaging = GuestFirstBootSettle.evaluate([migrating(0, false), migrating(5, false), {
            var polled = migrating(10, false)
            polled.stagedSystemApps = 30
            return polled
        }()], stablePolls: 3)
        expectEqual(stillStaging.reasons, ["staged_system_apps has 30 entries", "data migration has not finished"])
    }

    static func dataMigrationRecord() {
        func done(_ build: String?, _ last: String?, _ results: String?, running: Bool = true) -> Bool? {
            GuestFirstBootSettle.dataMigrationDone(
                build: build, lastSystemVersion: last, lastResultsBuild: results, migratorRunning: running,
            )
        }
        // A fresh restore: com.apple.migration is empty until DataMigrator ends.
        expectEqual(done("24A435", nil, nil), false)
        expectEqual(done("24A435", "24A435", "24A435"), true)
        expectEqual(done("24A435", "24A435", nil), true)
        expectEqual(done("24A435", nil, "24A435"), true)
        expectEqual(done("24A435", "24A435", "24A435", running: false), true)
        // The build changed (an update): the old record is not this build's.
        expectEqual(done("24A446", "24A435", "24A435"), false)
        // Nothing recorded and DataMigrator not running: unknown, never waited for.
        expectEqual(done("24A435", nil, nil, running: false), nil)
        expectEqual(done(nil, "24A435", "24A435"), nil)
        expectEqual(done("", nil, nil), nil)
        let migrator = "/System/Library/PrivateFrameworks/DataMigration.framework/XPCServices/com.apple.datamigrator.xpc/com.apple.datamigrator"
        expect(migrator.hasSuffix(GuestFirstBootSettle.dataMigratorSuffix), "the path seen on 27.0")
    }

    // MARK: - Device Name

    static func deviceNameRule() {
        expect(GuestDeviceNameRule.problem("p0-a") == nil, "plain name")
        expect(GuestDeviceNameRule.problem("dhtest 27 测试") == nil, "spaces and CJK")
        expect(GuestDeviceNameRule.problem("Jacky’s iPhone") == nil, "typographic apostrophe")
        expectEqual(GuestDeviceNameRule.problem(""), "name must not be blank")
        expectEqual(GuestDeviceNameRule.problem(" \n\t"), "name must not be blank")
        expectEqual(GuestDeviceNameRule.problem("a\u{7}b"), "name must not contain a control character")
        expectEqual(GuestDeviceNameRule.problem("line\nbreak"), "name must not contain a control character")
        expect(GuestDeviceNameRule.problem(String(repeating: "a", count: 255)) == nil, "255 bytes")
        expectEqual(GuestDeviceNameRule.problem(String(repeating: "a", count: 256)), "name must be at most 255 bytes in UTF-8")
        // 85 three-byte characters are 255 bytes; one more is 258.
        expect(GuestDeviceNameRule.problem(String(repeating: "测", count: 85)) == nil, "255 bytes of CJK")
        expect(GuestDeviceNameRule.problem(String(repeating: "测", count: 86)) != nil, "258 bytes of CJK")
    }

    // MARK: - Pointer Scroll

    static func scrollProblem(_ params: [String: Any]) -> String? {
        do {
            _ = try GuestPointerScroll.scroll(params)
            return nil
        } catch {
            return error.message
        }
    }

    static func screenshotSizing() {
        typealias Sizing = GuestScreenshotSizing
        let pointSize = (width: 100.0, height: 50.0)

        // 200x100 px, two per point: red top-left, green top-right, blue
        // bottom-left, yellow bottom-right.
        let colors: [(r: Double, g: Double, b: Double)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
        func jpeg(_ image: CGImage, quality: Double) -> Data {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            _ = CGImageDestinationFinalize(destination)
            return data as Data
        }
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (index, color) in colors.enumerated() {
            context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
            // CoreGraphics counts y from the bottom.
            context.fill(CGRect(x: (index % 2) * 100, y: index < 2 ? 50 : 0, width: 100, height: 50))
        }
        let original = jpeg(context.makeImage()!, quality: 1.0)

        func isColor(_ data: Data, _ x: Int, _ y: Int, _ color: (r: Double, g: Double, b: Double)) -> Bool {
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
            let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = canvas.data!.assumingMemoryBound(to: UInt8.self) + y * canvas.bytesPerRow + x * 4
            return abs(Int(bytes[0]) - Int(color.r * 255)) < 40 && abs(Int(bytes[1]) - Int(color.g * 255)) < 40
                && abs(Int(bytes[2]) - Int(color.b * 255)) < 40
        }
        func region(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
            ["x": x, "y": y, "width": width, "height": height]
        }
        func run(_ params: [String: Any]) -> (jpeg: Data, width: Int, height: Int, region: Sizing.Region)? {
            guard let options = try? Sizing.parse(params) else { return nil }
            return try? Sizing.apply(options, jpeg: original, pointSize: pointSize)
        }
        func parseError(_ params: [String: Any]) -> GuestAPIError? {
            do { _ = try Sizing.parse(params) } catch let error as GuestAPIError { return error } catch {}
            return nil
        }
        func applyError(_ params: [String: Any], _ data: Data? = nil) -> GuestAPIError? {
            do { _ = try Sizing.apply(Sizing.parse(params), jpeg: data ?? original, pointSize: pointSize) }
            catch let error as GuestAPIError { return error } catch {}
            return nil
        }

        // no params: nothing to do, so the daemon never decodes
        expect((try? Sizing.parse([:]))?.isEmpty == true, "no param is an empty option set")
        expect((try? Sizing.parse(["quality": 0.5]))?.isEmpty == false, "quality alone is not empty")

        // crop alone: the bottom-right quarter
        let crop = run(["region": region(50, 25, 50, 25)])
        expectEqual(crop.map { [$0.width, $0.height] } ?? [], [100, 50], "crop size")
        expectEqual(crop?.region, Sizing.Region(x: 50, y: 25, width: 50, height: 25), "crop reports the requested region")
        expect(crop.map { isColor($0.jpeg, 50, 25, colors[3]) && isColor($0.jpeg, 2, 2, colors[3]) } ?? false, "crop shows yellow")

        // a fractional region rounds each edge to whole pixels
        let fractional = run(["region": region(10.3, 5.2, 20.4, 10.1)])
        expectEqual(fractional.map { [$0.width, $0.height] } ?? [], [40, 21], "edge-rounded crop size")

        // scale alone
        let scaled = run(["max_dimension": 100])
        expectEqual(scaled.map { [$0.width, $0.height] } ?? [], [100, 50], "scale keeps the aspect ratio")
        expectEqual(scaled?.region, Sizing.Region(x: 0, y: 0, width: 100, height: 50), "no region is the full screen")
        expect(scaled.map { isColor($0.jpeg, 10, 10, colors[0]) && isColor($0.jpeg, 90, 40, colors[3]) } ?? false, "scale keeps the quadrants")
        expectEqual(run(["max_dimension": 5000]).map { [$0.width, $0.height] } ?? [], [200, 100], "never scales up")
        expectEqual(run(["max_dimension": 200])?.width, 200, "at the longer side is unchanged")

        // both: the crop is scaled
        let both = run(["region": region(0, 0, 50, 25), "max_dimension": 50])
        expectEqual(both.map { [$0.width, $0.height] } ?? [], [50, 25], "crop then scale")
        expect(both.map { isColor($0.jpeg, 25, 12, colors[0]) } ?? false, "crop then scale shows red")

        // quality changes the byte size, not the image size
        let low = run(["quality": 0.5])
        let high = run(["quality": 0.9])
        expect((low?.jpeg.count ?? Int.max) < (high?.jpeg.count ?? 0), "quality 0.5 is smaller than quality 0.9")
        let cropExplicit = run(["region": region(50, 25, 50, 25), "quality": 0.8])
        expect(crop != nil && crop?.jpeg == cropExplicit?.jpeg, "a crop without quality encodes at 0.8")
        let scaleExplicit = run(["max_dimension": 100, "quality": 0.8])
        expect(scaled != nil && scaled?.jpeg == scaleExplicit?.jpeg, "a scale without quality encodes at 0.8")
        expectEqual(low.map { [$0.width, $0.height] } ?? [], [200, 100], "quality alone keeps the size")

        // the coordinate mapping: pixel (px, py) is point (x + px / scale, y + py / scale)
        // a crop across the red/green edge (point 50) puts the edge at (50 - region.x) * scale
        for maxDimension in [nil, 20] as [Int?] {
            var params: [String: Any] = ["region": region(40, 0, 20, 25)]
            if let maxDimension { params["max_dimension"] = maxDimension }
            guard let edge = run(params) else { expect(false, "the edge crop ran"); continue }
            let scale = Double(edge.width) / edge.region.width
            let expected = (50 - edge.region.x) * scale
            let row = edge.height / 4
            let boundary = (0 ..< edge.width).first { !isColor(edge.jpeg, $0, row, colors[0]) } ?? -1
            expect(abs(Double(boundary) - expected) <= 1, "the red/green edge is at pixel \(boundary), expected \(expected)")
        }

        let tiny = run(["max_dimension": 1])
        expectEqual(tiny.map { [$0.width, $0.height] } ?? [], [1, 1], "max_dimension 1 on a 2:1 image")
        if let tiny {
            let scale = Double(tiny.width) / tiny.region.width
            expectEqual(scale, 0.01, "1 pixel over 100 points")
            expectEqual(tiny.region.x + 1 / scale, 100, "the pixel's far edge is the screen's")
        }

        // the reply: empty options keep the image bytes and add the point keys
        let capture: [String: Any] = ["bytes": original.count, "mime_type": "image/jpeg", "width": 200, "height": 100,
                                      "coordinate_scale": 2.0, "data": original.base64EncodedString(),
                                      "jpeg": original]
        func reply(_ params: [String: Any], _ input: [String: Any]) -> [String: Any]? {
            guard let options = try? Sizing.parse(params) else { return nil }
            return try? Sizing.reply(capture: input, options: options, pointSize: pointSize)
        }
        if let plain = reply([:], capture) {
            expect(plain["data"] as? String == original.base64EncodedString(), "empty options leave the data identical")
            expectEqual(plain["bytes"] as? Int, original.count, "empty options leave bytes identical")
            expectEqual(plain["point_width"] as? Double, 100, "empty options add point_width")
            expectEqual(plain["point_height"] as? Double, 50, "empty options add point_height")
            expectEqual((plain["region"] as? [String: Double])?["width"], 100, "empty options add the full-screen region")
        } else {
            expect(false, "the empty-options reply ran")
        }
        // pinned replies on the 200x100 px, 100x50 pt fixture: width, height, region, pixels per point
        let sizedCases: [(params: [String: Any], width: Int, height: Int, region: [String: Double], scale: Double)] = [
            (["quality": 0.5], 200, 100, ["x": 0, "y": 0, "width": 100, "height": 50], 2),
            (["region": region(50, 25, 50, 25)], 100, 50, ["x": 50, "y": 25, "width": 50, "height": 25], 2),
            (["max_dimension": 100], 100, 50, ["x": 0, "y": 0, "width": 100, "height": 50], 1),
            // 40x21 px crop scaled to 30 wide: 21 * 30 / 40 rounds to 16
            (["region": region(10.3, 5.2, 20.4, 10.1), "max_dimension": 30], 30, 16,
             ["x": 10.3, "y": 5.2, "width": 20.4, "height": 10.1], 30 / 20.4),
        ]
        for testCase in sizedCases {
            let label = "\(testCase.params)"
            guard let out = reply(testCase.params, capture) else { expect(false, "reply ran for \(label)"); continue }
            expectEqual(out["width"] as? Int, testCase.width, "\(label) width")
            expectEqual(out["height"] as? Int, testCase.height, "\(label) height")
            expectEqual(out["point_width"] as? Double, 100, "\(label) point_width")
            expectEqual(out["point_height"] as? Double, 50, "\(label) point_height")
            expectEqual(out["region"] as? [String: Double], testCase.region, "\(label) region")
            expectEqual(out["coordinate_scale"] as? Double, testCase.scale, "\(label) coordinate_scale")
        }

        // one-past-bound rejections: the code, and a message naming param, value and range
        func rejected(_ error: GuestAPIError?, _ parts: [String], _ label: String, line: Int = #line) {
            guard let error else { expect(false, "\(label) is rejected", line: line); return }
            expectEqual(error.code, "invalid_param", label, line: line)
            guard case .invalidRequest = error else { expect(false, "\(label) is invalidRequest", line: line); return }
            for part in parts {
                expect(error.description.contains(part), "\(label): \"\(error.description)\" names \(part)", line: line)
            }
        }
        rejected(parseError(["max_dimension": 0]), ["max_dimension", "0", "1 or more"], "max_dimension 0")
        rejected(parseError(["max_dimension": 1.5]), ["max_dimension", "1.5"], "max_dimension fraction")
        rejected(parseError(["max_dimension": "9"]), ["max_dimension", "9"], "max_dimension text")
        rejected(parseError(["quality": 0.09]), ["quality", "0.09", "0.1 to 1.0"], "quality 0.09")
        rejected(parseError(["quality": 1.01]), ["quality", "1.01", "0.1 to 1.0"], "quality 1.01")
        rejected(parseError(["quality": true]), ["quality", "true"], "quality boolean")
        rejected(parseError(["region": region(0, 0, 0, 10)]), ["region.width", "0", "above 0"], "width 0")
        rejected(parseError(["region": region(0, 0, 10, -1)]), ["region.height", "-1", "above 0"], "height -1")
        rejected(parseError(["region": region(-1, 0, 10, 10)]), ["region.x", "-1", "0 or more"], "x -1")
        rejected(parseError(["region": region(0, -1, 10, 10)]), ["region.y", "-1", "0 or more"], "y -1")
        rejected(parseError(["region": ["x": 0, "y": 0, "width": 10]]), ["region.height", "missing"], "missing field")
        rejected(parseError(["region": ["x": 0, "y": 0, "width": 10, "height": "ten"]]), ["region.height", "ten"], "non-numeric field")
        rejected(parseError(["region": "all"]), ["region", "all"], "region not an object")
        rejected(applyError(["region": region(50, 0, 50.1, 10)]), ["x + width", "100.1", "at most 100"], "x + width one past the edge")
        rejected(applyError(["region": region(0, 40, 10, 10.5)]), ["y + height", "50.5", "at most 50"], "y + height past the edge")
        rejected(applyError(["region": region(10, 10, 0.1, 10)]), ["region.width", "0.1", "at least 0.5"], "0.1-point region")
        expect(applyError(["region": region(0, 0, 100, 50)]) == nil, "the whole screen is inside")

        // an image that does not decode fails the operation, never succeeds
        if let error = applyError(["quality": 0.5], Data("not a jpeg".utf8)) {
            expectEqual(error.code, "invalid_operation")
            if case .operationFailed = error {} else { expect(false, "non-JPEG is operationFailed") }
            expect(error.description.contains("decode"), "the message names the decode step: \(error.description)")
        } else {
            expect(false, "non-JPEG bytes are rejected")
        }
    }

    static func pointerScroll() {
        typealias Scroll = GuestPointerScroll.Scroll
        expectEqual(try? GuestPointerScroll.scroll(["phase": "changed", "dx": 1.5, "dy": -20]),
                    Scroll(phase: .changed, dx: 1.5, dy: -20, pointer: nil))
        expectEqual(try? GuestPointerScroll.scroll(["phase": "began"]),
                    Scroll(phase: .began, dx: 0, dy: 0, pointer: nil), "deltas default to 0")
        expectEqual(try? GuestPointerScroll.scroll(["phase": "began", "x": 0, "y": 1]),
                    Scroll(phase: .began, dx: 0, dy: 0, pointer: .init(x: 0, y: 1)), "a pointer position comes with it")
        expectEqual(GuestPointerScroll.Phase.allCases.map(\.rawValue), ["began", "changed", "ended", "cancelled"],
                    "the names IcliKit's ScrollPhase takes")
        let phase = "phase must be began, changed, ended or cancelled"
        expectEqual(scrollProblem([:]), phase)
        expectEqual(scrollProblem(["phase": "move"]), phase)
        expectEqual(scrollProblem(["phase": 2]), phase)
        let delta = "must be a number within ±10000"
        expectEqual(scrollProblem(["phase": "changed", "dy": "20"]), "dy \(delta)")
        expectEqual(scrollProblem(["phase": "changed", "dx": true]), "dx \(delta)", "a boolean is not a number")
        expectEqual(scrollProblem(["phase": "changed", "dy": 10001]), "dy \(delta)")
        expectEqual(scrollProblem(["phase": "changed", "dy": Double.infinity]), "dy \(delta)")
        let point = "x and y must be numbers within 0...1"
        expectEqual(scrollProblem(["phase": "began", "x": 0.5]), point, "x without y")
        expectEqual(scrollProblem(["phase": "began", "x": 0.5, "y": 1.01]), point)
        expectEqual(scrollProblem(["phase": "began", "x": -0.1, "y": 0.5]), point)
        expectEqual(try? GuestPointerScroll.point(["x": 0.25, "y": 0.75]), GuestPointerScroll.Point(x: 0.25, y: 0.75))
        expect((try? GuestPointerScroll.point(["x": false, "y": 0])) == nil, "a boolean is not a coordinate")
        expectEqual(try? GuestPointerScroll.sequence([:]), 0, "no seq always moves")
        expectEqual(try? GuestPointerScroll.sequence(["seq": 42]), 42)
        expectEqual(try? GuestPointerScroll.sequence(["seq": 9_007_199_254_740_992.0]), 1 << 53)
        for bad: Any in [-1, 1.5, true, "7", 9_007_199_254_740_994.0] {
            expect((try? GuestPointerScroll.sequence(["seq": bad])) == nil, "seq \(bad) is refused")
        }
        expectEqual(try? GuestPointerScroll.buttons([:]), 0, "no buttons held when there are none")
        expectEqual(try? GuestPointerScroll.buttons(["buttons": 1]), 1)
        expectEqual(try? GuestPointerScroll.buttons(["buttons": 7]), 7)
        for bad: Any in [-1, 8, 1.5, true, "1"] {
            expect((try? GuestPointerScroll.buttons(["buttons": bad])) == nil, "buttons \(bad) is refused")
        }
    }

    // MARK: - Bootstrap Platform

    static func bootstrapPlatform() {
        let architecture = GuestBootstrapPlatform.packageArchitecture
        expectEqual(architecture("roothide", false), "iphoneos-arm64e")
        expectEqual(architecture("rootless", false), "iphoneos-arm64")
        expectEqual(architecture("roothide", true), "appletvos-arm64e", "an Apple TV takes Irisin's Apple TV package")
        expectEqual(architecture("rootless", true), nil, "Irisin serves no rootless Apple TV")
        expectEqual(architecture("rootful", false), nil)
        expect(GuestBootstrapPlatform.packageRequiresApp(architecture: "iphoneos-arm64e"), "the iOS packages carry the app")
        expect(GuestBootstrapPlatform.packageRequiresApp(architecture: "iphoneos-arm64"), "the iOS packages carry the app")
        expect(!GuestBootstrapPlatform.packageRequiresApp(architecture: "appletvos-arm64e"), "the Apple TV package has none")
        expectEqual(GuestBootstrapPlatform.mainExecutablePlatform(), UInt32(PLATFORM_MACOS), "this test runs as macOS")
        expect(!GuestBootstrapPlatform.isTVOS, "the Mac is not tvOS")

        // Irisin 5.1.4's roothide list
        let roothide: [[String: Any]] = [
            ["source": "deb https://roothide.github.io/procursus iphoneos-arm64e/1800 main", "maximumSystemVersion": 15],
            ["source": "deb https://stripe.owngoal.dev 1900 main", "minimumSystemVersion": 16],
            ["source": "https://apt.owngoal.dev"],
        ]
        let sources = GuestBootstrapPlatform.recommendedSources
        expectEqual(sources([], roothide, 27), ["deb https://stripe.owngoal.dev 1900 main", "https://apt.owngoal.dev"])
        expectEqual(sources(nil, roothide, 15), ["deb https://roothide.github.io/procursus iphoneos-arm64e/1800 main", "https://apt.owngoal.dev"])
        expectEqual(sources([["source": "https://repo.example"]], roothide, 27), ["https://repo.example"], "a managed list with entries wins")
        expectEqual(sources(nil, nil, 27), [], "no list recommends nothing")
    }

    // MARK: Method dispatch

    enum FixtureMethod: String, GuestMethod {
        case echo = "fixture.echo"
        case always = "fixture.always"
        case when = "fixture.when"
        case varies = "fixture.varies"
        case declared = "fixture.declared"
        case empty = "fixture.empty"

        var spec: MethodSpec {
            switch self {
            case .echo: MethodSpec(.required("a", .string, "a"), .optional("b", .integer, "b"), summary: "echo fixture")
            case .always:
                MethodSpec(.required("a", .string, "a"), summary: "always fixture", force: .always("act on <a>") { p in
                    guard let a = p["a"] as? String, !a.isEmpty else { throw GuestAPIError.invalidRequest("a is required") }
                    return "act on \(a)"
                })
            case .when: MethodSpec(.optional("kill", .boolean, "kill"), summary: "when fixture", force: .when("kill", "kill fixture") { _ in "kill fixture" })
            case .varies:
                MethodSpec(.optional("userspace", .boolean, "userspace"), summary: "varies fixture", force: .always("reboot fixture") { p in
                    GuestMethodArea.flag(p, "userspace") ? "restart fixture userspace" : "reboot fixture"
                })
            case .declared:
                MethodSpec(.required("a", .string, "a"), summary: "declared fixture", result: [
                    .optional("z", .boolean), .required("x", .integer), .hidden("y", .string), .required("e", .object).open(),
                ])
            case .empty: MethodSpec(summary: "empty fixture", result: [])
            }
        }
    }

    nonisolated(unsafe) static var specCount = 0

    enum CountedMethod: String, GuestMethod {
        case one = "counted.one"
        case two = "counted.two"

        var spec: MethodSpec {
            LogicTests.specCount += 1
            return MethodSpec(summary: "counted fixture")
        }
    }

    static func json(_ value: [String: Any]?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func methodDispatch() {
        methodDispatchBody()
        rpcErrorEnvelope()
        inBandFailures()
    }

    static func methodDispatchBody() {
        let area = GuestMethodArea.make(FixtureMethod.self) { _, params in params }
        func run(_ method: String, _ params: [String: Any]) -> (result: [String: Any]?, error: String?, code: String?, hint: String?) {
            do { return (try area.execute(method, params), nil, nil, nil) } catch let error as GuestAPIError {
                return (nil, String(describing: error), error.code, error.hint)
            } catch { return (nil, "\(error)", nil, nil) }
        }

        expect(run("other", [:]).result == nil && run("other", [:]).error == nil, "an unknown name is not this area's")
        let extra = run("fixture.echo", ["a": "x", "b": 1, "z": 9])
        expectEqual(extra.result == nil, true, "an undeclared key fails the call")
        expectEqual(extra.code ?? "", "invalid_param")
        expectEqual(extra.error ?? "", "Unknown param: z")
        expectEqual(extra.hint ?? "", "Did you mean `a`? Valid params: a, b")
        expectEqual(json(run("fixture.echo", ["a": "x", "b": 1]).result), json(["a": "x", "b": 1]), "declared keys pass")
        expectEqual(run("fixture.echo", ["z": 9]).error ?? "", "Unknown param: z", "no declared key still fails on the extra")

        let refusal = "Pass force: true to act on x"
        let refused = run("fixture.always", ["a": "x"])
        expectEqual(refused.error ?? "", refusal)
        expectEqual(refused.code ?? "", "force_required")
        expectEqual(refused.hint ?? "", "Confirm with the user, then repeat the call with force: true")
        expectEqual(run("fixture.always", ["a": "x", "force": false]).error ?? "", refusal)
        expectEqual(run("fixture.always", ["a": "x", "force": "yes"]).error ?? "", refusal)
        expectEqual(json(run("fixture.always", ["a": "x", "force": true]).result), json(["a": "x"]), "force: true admits")
        expectEqual(json(run("fixture.always", ["a": "x", "force": 1]).result), json(["a": "x"]), "force: 1 admits")
        expectEqual(run("fixture.always", [:]).error ?? "", "a is required", "invalid and unforced fails validation first")

        expectEqual(run("fixture.varies", [:]).error ?? "", "Pass force: true to reboot fixture")
        expectEqual(run("fixture.varies", ["userspace": true]).error ?? "", "Pass force: true to restart fixture userspace", "the action text follows the params")
        expectEqual(json(run("fixture.varies", ["userspace": true, "force": true]).result), json(["userspace": true]), "forced action runs")

        expectEqual(json(run("fixture.when", ["kill": false]).result), json(["kill": false]), "kill: false needs no force")
        expectEqual(json(run("fixture.when", [:]).result), "{}", "no kill needs no force")
        expectEqual(run("fixture.when", ["kill": true]).error ?? "", "Pass force: true to kill fixture")
        expectEqual(json(run("fixture.when", ["kill": true, "force": true]).result), json(["kill": true]), "forced kill admits")

        // ResultKey storage: undeclared is nil, declared empty is []
        expect(FixtureMethod.echo.spec.result == nil, "no result: reads back nil")
        expectEqual(FixtureMethod.empty.spec.result?.count ?? -1, 0, "result: [] reads back empty")

        let catalog = GuestMethodArea.catalog([area])
        let expected: [String: Any] = ["methods": [
            ["name": "fixture.echo", "description": "echo fixture", "params": [
                ["name": "a", "type": "string", "required": true, "description": "a"],
                ["name": "b", "type": "integer", "required": false, "description": "b"],
            ], "force": "never"],
            ["name": "fixture.always", "description": "always fixture", "params": [["name": "a", "type": "string", "required": true, "description": "a"]], "force": "always", "force_action": "act on <a>"],
            ["name": "fixture.when", "description": "when fixture", "params": [["name": "kill", "type": "boolean", "required": false, "description": "kill"]], "force": "when:kill", "force_action": "kill fixture"],
            ["name": "fixture.varies", "description": "varies fixture", "params": [["name": "userspace", "type": "boolean", "required": false, "description": "userspace"]], "force": "always", "force_action": "reboot fixture"],
            ["name": "fixture.declared", "description": "declared fixture", "params": [["name": "a", "type": "string", "required": true, "description": "a"]], "force": "never", "result": [
                ["name": "e", "type": "object", "required": true, "open": true, "nullable": false],
                ["name": "x", "type": "integer", "required": true, "open": false, "nullable": false],
                ["name": "z", "type": "boolean", "required": false, "open": false, "nullable": false],
            ]],
            ["name": "fixture.empty", "description": "empty fixture", "params": [] as [[String: Any]], "force": "never", "result": [] as [[String: Any]]],
        ]]
        expectEqual(json(catalog), json(expected), "catalog")

        // catalog and dispatcher agree
        let listed = (catalog["methods"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let dispatched = FixtureMethod.allCases.map(\.rawValue).filter { name in
            var params: [String: Any] = ["force": true]
            for declared in FixtureMethod(rawValue: name)?.spec.params ?? [] { params[declared.name] = "x" }
            return (try? area.execute(name, params)) != nil
        }
        expectEqual(listed, dispatched, "catalog names equal dispatched names")
        expectEqual(Set(listed).count, listed.count, "catalog names are unique")

        // specs are built lazily
        let counted = GuestMethodArea.make(CountedMethod.self) { _, params in params }
        specCount = 0
        for _ in 0 ..< 1000 { _ = try? counted.execute("other", [:]) }
        expectEqual(specCount, 0, "no spec is built for a foreign name")
        for _ in 0 ..< 1000 { _ = try? counted.execute("counted.one", [:]) }
        expectEqual(specCount, 1000, "one spec per dispatch")
        _ = GuestMethodArea.catalog([counted])
        expectEqual(specCount, 1002, "catalog builds each spec once")

        // methods.list reaches the dispatch through the same walk GuestAPI.execute uses
        enum FixtureCore: String, GuestMethod {
            case methodsList = "methods.list"
            var spec: MethodSpec { MethodSpec(summary: "core fixture") }
        }
        nonisolated(unsafe) var table: [GuestMethodArea] = []
        table = [
            .make(FixtureCore.self) { _, _ in GuestMethodArea.catalog(table) },
            GuestMethodArea.make(FixtureMethod.self) { _, params in params },
        ]
        func call(_ params: [String: Any]) -> [String: Any]? {
            try? GuestMethodArea.dispatch(table, method: "methods.list", params: params)
        }
        let answer = call([:])
        let names = (answer?["methods"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        expect(names.contains("methods.list") && names.contains("fixture.echo"), "methods.list lists itself and the other areas")
        expectEqual(call(["x": 1]) == nil, true, "methods.list takes no params")
        expectEqual(json(call([:])), json(answer), "two calls are byte-identical")
        expect(json(answer).utf8.count < 1 << 20, "the answer is far below the 1 MiB body limit")
        // every param methods.list describes is admitted by the unknown-param check
        for entry in answer?["methods"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String, name.hasPrefix("fixture.") else { continue }
            var all: [String: Any] = ["force": true]
            for param in entry["params"] as? [[String: Any]] ?? [] { all[param["name"] as? String ?? ""] = "x" }
            var rejected = false
            do { _ = try GuestMethodArea.dispatch(table, method: name, params: all) } catch { rejected = String(describing: error).hasPrefix("Unknown param") }
            expect(!rejected, "\(name): every listed param is admitted")
        }
        var unknown = ""
        do { _ = try GuestMethodArea.dispatch(table, method: "nope.nothing", params: [:]) } catch { unknown = String(describing: error) }
        expectEqual(unknown, "Unknown method: nope.nothing", "no area answering is an unknown method")
    }

    // MARK: RPC error envelope

    /// The wire body of one failure as JSON text, as APIWire.execute sends it (it uses `GuestAPIError.wireBody`).
    static func wire(_ error: GuestAPIError) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: error.wireBody, options: [.sortedKeys])
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// inBandFailure turns a producer's error map into the thrown error the caller's closure builds, and passes a clean result through.
    /// Which code each of the three handlers picks is not asserted here: they need a guest.
    static func inBandFailures() {
        var thrown: GuestAPIError?
        var returned: [String: Any]?
        do { returned = try GuestAPIError.inBandFailure(["entries": [Any](), "error": "no io registry"], as: { .operationFailed($0) }) }
        catch let error as GuestAPIError { thrown = error } catch {}
        expect(returned == nil, "no success body")
        let body = thrown.map(wire) ?? [:]
        expectEqual(body["code"] as? String ?? "", "invalid_operation")
        expectEqual(body["message"] as? String ?? "", "no io registry")
        expect(body["hint"] == nil, "no hint key")
        let ok = try? GuestAPIError.inBandFailure(["enabled": true, "ok": true], as: { .operationFailed($0) })
        expect(ok?["enabled"] as? Bool == true, "a result without an error key passes through")
    }

    static func rpcErrorEnvelope() {
        // Wire: code, message, hint; the hint key is absent (not null) without one.
        let withHint = wire(.notFound("No such file", hint: "List the directory first"))
        expectEqual(withHint["code"] as? String ?? "", "not_found")
        expectEqual(withHint["message"] as? String ?? "", "No such file")
        expectEqual(withHint["hint"] as? String ?? "", "List the directory first")
        // Each constructor maps to one code; none carries a hint key without one.
        let codes: [(GuestAPIError, String)] = [
            (.notFound("x"), "not_found"), (.unavailable("x"), "unavailable"), (.permission("x"), "permission"),
            (.forceRequired("x"), "force_required"), (.invalidRequest("x"), "invalid_param"),
            (.operationFailed("x"), "invalid_operation"), (.unsupportedMethod("x"), "not_found"),
            (.locationServicesOff, "location_services_off"), (.alreadyDone(code: "already_done", message: "x"), "already_done"),
        ]
        for (error, code) in codes {
            let body = wire(error)
            expectEqual(body["code"] as? String ?? "", code, "code of \(error.code)")
            expect(body["hint"] == nil, "no hint key on \(error.code)")
            expect(!json(body).contains("hint"), "no hint text on \(error.code)")
        }

        enum Wide: String, GuestMethod {
            case wide = "wide.call"
            case none = "wide.none"
            var spec: MethodSpec {
                switch self {
                case .wide: MethodSpec(.optional("alpha", .string, "alpha"), .optional("beta", .string, "beta"), .optional("gamma", .string, "gamma"), summary: "fixture")
                case .none: MethodSpec(summary: "fixture")
                }
            }
        }
        let area = GuestMethodArea.make(Wide.self) { _, params in params }
        func failure(_ method: String, _ params: [String: Any]) -> [String: Any] {
            do { _ = try area.execute(method, params) } catch let error as GuestAPIError { return wire(error) } catch {}
            return [:]
        }

        // Unknown params
        var body = failure("wide.call", ["alpa": 1])
        expectEqual(body["code"] as? String ?? "", "invalid_param")
        expectEqual(body["message"] as? String ?? "", "Unknown param: alpa")
        expectEqual(body["hint"] as? String ?? "", "Did you mean `alpha`? Valid params: alpha, beta, gamma")
        body = failure("wide.call", ["zzzzzzzz": 1])
        expectEqual(body["hint"] as? String ?? "", "Valid params: alpha, beta, gamma", "no near param, no suggestion")
        body = failure("wide.call", ["zeta": 1, "alpa": 1])
        expectEqual(body["message"] as? String ?? "", "Unknown param: alpa, zeta", "two extras are sorted")
        expectEqual(body["hint"] as? String ?? "", "Did you mean `alpha`? Valid params: alpha, beta, gamma", "the first sorted extra drives the suggestion")
        body = failure("wide.none", ["a": 1])
        expectEqual(body["message"] as? String ?? "", "Unknown param: a")
        expectEqual(body["hint"] as? String ?? "", "This method takes no params")
        expectEqual(failure("wide.call", ["alpha": 1, "force": true]).isEmpty, true, "force is always admitted")

        // 5 extras list all, 6 add " and 1 more"; 1000 extras stay bounded
        func extras(_ n: Int) -> [String: Any] { Dictionary(uniqueKeysWithValues: (0 ..< n).map { (String(format: "k%04d", $0), 1) }) }
        expectEqual(failure("wide.call", extras(5))["message"] as? String ?? "", "Unknown param: k0000, k0001, k0002, k0003, k0004")
        expectEqual(failure("wide.call", extras(6))["message"] as? String ?? "", "Unknown param: k0000, k0001, k0002, k0003, k0004 and 1 more")
        body = failure("wide.call", extras(1000))
        expectEqual(body["message"] as? String ?? "", "Unknown param: k0000, k0001, k0002, k0003, k0004 and 995 more")
        expect((body["message"] as? String ?? "").count < 500, "1000 extras: bounded message")

        // closest: bounds and ties
        let sixtyFour = String(repeating: "a", count: 64)
        let sixtyFive = String(repeating: "a", count: 65)
        expectEqual(GuestAPIError.closest(sixtyFour, [sixtyFour + "bb"]) ?? "", sixtyFour + "bb", "a 64-character name is matched")
        expect(GuestAPIError.closest(sixtyFive, [sixtyFive]) == nil, "a 65-character name is not")
        expect(GuestAPIError.closest(String(repeating: "a", count: 10_000), ["a"]) == nil, "a 10,000-character name is not")
        expectEqual(GuestAPIError.closest("cat", ["cap", "car"]) ?? "", "cap", "equidistant: the first candidate wins")
        expectEqual(GuestAPIError.closest("cat", ["car", "cap"]) ?? "", "car", "equidistant: order decides")
        expectEqual(GuestAPIError.closest("abcdef", ["abcdxx"]) ?? "", "abcdxx", "distance 2 is within the bound")
        expect(GuestAPIError.closest("abcdef", ["abcxxx"]) == nil, "distance 3 over a 6-character name is out")
        expectEqual(GuestAPIError.closest("abcdefghi", ["abcdefxxx"]) ?? "", "abcdefxxx", "9 characters allow distance 3")
        expect(GuestAPIError.closest("x", ["abc"]) == nil, "nothing near")

        // Unknown method: hint only with a near method
        func unknownMethod(_ name: String) -> [String: Any] {
            do { _ = try GuestMethodArea.dispatch([area], method: name, params: [:]) } catch let error as GuestAPIError { return wire(error) } catch {}
            return [:]
        }
        body = unknownMethod("wide.cal")
        expectEqual(body["code"] as? String ?? "", "not_found")
        expectEqual(body["message"] as? String ?? "", "Unknown method: wide.cal")
        expectEqual(body["hint"] as? String ?? "", "Did you mean `wide.call`?")
        expect(unknownMethod("nothing.like.it")["hint"] == nil, "no near method: no hint key")
        body = unknownMethod(String(repeating: "m", count: 10_000))
        expect(body["hint"] == nil, "no Did you mean for a 10,000-character name")
        expect((body["message"] as? String ?? "").count < 500, "a 10,000-character name keeps the message under 500 characters")
        expectEqual(body["message"] as? String ?? "", "Unknown method: " + String(repeating: "m", count: 64) + "…", "the name is cut at 64 characters")
        expectEqual(unknownMethod(String(repeating: "m", count: 64))["message"] as? String ?? "", "Unknown method: " + String(repeating: "m", count: 64), "a 64-character name is shown whole")
        expectEqual(unknownMethod("wide.nonf")["hint"] as? String ?? "", "Did you mean `wide.none`?")

        errnoClassification()
    }

    /// `fromErrno` is the one reclassification helper the handlers share (kill, posix_spawn, shutdown);
    /// the handlers themselves need a guest, so the mapping is proven here.
    static func errnoClassification() {
        let cases: [(errno: Int32, code: String)] = [
            (ENOENT, "not_found"), (ESRCH, "not_found"), (EACCES, "permission"), (EPERM, "permission"),
            (EIO, "invalid_operation"), (EINVAL, "invalid_operation"), (0, "invalid_operation"),
        ]
        for c in cases {
            let body = wire(GuestAPIError.fromErrno(c.errno, "boom \(c.errno)"))
            expectEqual(body["code"] as? String ?? "", c.code, "errno \(c.errno)")
            expectEqual(body["message"] as? String ?? "", "boom \(c.errno)", "errno \(c.errno) keeps the message")
            expect(body["hint"] == nil, "errno \(c.errno): no hint key")
        }
    }
}
