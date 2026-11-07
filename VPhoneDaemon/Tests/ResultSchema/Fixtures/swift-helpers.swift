// Fixture for SwiftExtractor rules 4, 10, 11 and the unresolvable error. Parsed only, never compiled.
// Each expect line is: function => catalog cell. An expect-open line marks a pass-through envelope.

func plainKeys() -> [String: Any] {
    return ["id": "x", "count": 1]
}

func optionalKeys(flag: Bool) -> [String: Any] {
    var out: [String: Any] = ["id": "x"]
    if flag { out["extra"] = true }
    return out
}

// Rule 4: a helper call returned, bound, or bound then extended.
// expect: returnsHelper => count:integer,id:string
func returnsHelper() throws -> [String: Any] {
    return try plainKeys()
}

// expect: boundHelper => count:integer,id:string,late:number?,sure:boolean
func boundHelper(flag: Bool) -> [String: Any] {
    var out = plainKeys()
    out["sure"] = true
    if flag { out["late"] = 1.5 }
    return out
}

// Helper presence survives: optional in the helper stays optional in the caller.
// expect: viaOptionalHelper => extra:boolean?,id:string
func viaOptionalHelper() -> [String: Any] {
    return optionalKeys(flag: true)
}

// Rule 4 merge / merging.
// expect: mergeStatement => count:integer,extra:boolean?,id:string,mine:string,tail:integer?
func mergeStatement(flag: Bool) -> [String: Any] {
    var out: [String: Any] = ["mine": "m"]
    out.merge(plainKeys()) { current, _ in current }
    out.merge(optionalKeys(flag: flag)) { current, _ in current }
    if flag {
        out.merge(["tail": 1]) { current, _ in current }
    }
    return out
}

// expect: mergingReturn => count:integer,id:string,z:integer
func mergingReturn() -> [String: Any] {
    return plainKeys().merging(["z": 1]) { current, _ in current }
}

// expect: mergingHelpers => count:integer,extra:boolean?,id:string
func mergingHelpers() -> [String: Any] {
    return plainKeys().merging(optionalKeys(flag: false)) { current, _ in current }
}

// Assignments inside for, if and a closure are optional, also through a helper.
// expect: nestedAssignments => base:string,c:boolean?,f:integer?,i:integer?
func nestedAssignments(items: [Int], flag: Bool) -> [String: Any] {
    var out: [String: Any] = ["base": "b"]
    for _ in items { out["f"] = 1 }
    if flag { out["i"] = 2 }
    items.forEach { _ in out["c"] = true }
    return out
}

// expect: viaNested => base:string,c:boolean?,f:integer?,i:integer?
func viaNested() -> [String: Any] {
    return nestedAssignments(items: [], flag: false)
}

// Cycle: a function reached again while it is being analysed contributes nothing.
// expect: ping => p:integer?,q:string?
func ping(_ n: Int) -> [String: Any] {
    if n > 0 { return pong(n - 1) }
    return ["p": 1]
}

func pong(_ n: Int) -> [String: Any] {
    if n > 0 { return ping(n - 1) }
    return ["q": "x"]
}

// Unresolvable: no function of that name anywhere.
func unresolvableHelper() -> [String: Any] {
    let first = 1
    return missingHelper(first)
}

// Several functions of one name in the same file are ambiguous.
func twin() -> [String: Any] { return ["one": 1] }
func twin() -> [String: Any] { return ["two": 2] }
func ambiguousHelper() -> [String: Any] {
    return twin()
}

// Rule 11: an element of a helper's returned array. `a` is in every element, `x` in one.
func widgets() -> [String: Any] {
    return ["widgets": [["a": "first", "x": 1], ["a": "second"]], "total": 2]
}

func widgetsAppended(flag: Bool) -> [String: Any] {
    var list: [[String: Any]] = []
    var entry: [String: Any] = ["a": "s"]
    if flag { entry["x"] = 1 }
    list.append(entry)
    list.append(["a": "t"])
    return ["widgets": list]
}

// expect: widgetInfo => a:string,x:integer?
func widgetInfo(_ id: String) throws -> [String: Any] {
    let items = try widgets()["widgets"] as? [[String: Any]] ?? []
    guard let item = items.first(where: { $0["a"] as? String == id }) else { throw Failure() }
    var info = item
    return info
}

// expect: widgetAdded => a:string,note:string?,x:integer?
func widgetAdded(_ id: String, flag: Bool) throws -> [String: Any] {
    let items = try widgets()["widgets"] as? [[String: Any]] ?? []
    guard let item = items.first else { throw Failure() }
    var info = item
    if flag { info["note"] = "n" }
    return info
}

// expect: widgetLoop => a:string,x:integer?
func widgetLoop() throws -> [String: Any] {
    let rows = widgetsAppended(flag: true)["widgets"] as? [[String: Any]] ?? []
    for row in rows {
        return row
    }
    throw Failure()
}

// Rule 10: `env["k"]` of the JSON from a repo vp_*_copy_json (native-forms.m).
// expect: envelopeCall => a:integer
func envelopeCall() throws -> [String: Any] {
    guard let json = vp_demo_copy_json() else { throw Failure() }
    defer { free(json) }
    let data = Data(bytes: json, count: strlen(json))
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure() }
    guard envelope["ok"] as? Bool == true else { throw Failure() }
    return envelope["result"] as? [String: Any] ?? [:]
}

// A value passed through from another dictionary is open.
// expect: envelopeOpen => -
// expect-open: envelopeOpen
func envelopeOpen() throws -> [String: Any] {
    guard let json = vp_open_copy_json() else { throw Failure() }
    let data = Data(bytes: json, count: strlen(json))
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure() }
    return envelope["result"] as? [String: Any] ?? [:]
}

// A dispatcher arm that follows the envelope helper.
// expect: dispatchEnvelope@get => a:integer
func dispatchEnvelope(_ m: Method) throws -> [String: Any] {
    switch m {
    case .get:
        return try envelopeCall()
    }
}

// Rule 10 where the native envelope literal sits in a helper of the native function.
// expect: envelopeNested => available:boolean,level:integer
func envelopeNested() throws -> [String: Any] {
    guard let json = vp_nested_copy_json() else { throw Failure() }
    let data = Data(bytes: json, count: strlen(json))
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure() }
    return envelope["result"] as? [String: Any] ?? [:]
}

// Rule 11 bridge: rows come from a native bridge array plus a Swift helper's array.
func listRows() throws -> [String: Any] {
    var rows = decodeRows(takeCString(icli_rows_json()))
    rows.append(contentsOf: scanRows())
    rows = uniqued(rows)
    return ["rows": rows, "count": rows.count]
}

func scanRows() -> [[String: Any]] {
    var extra: [[String: Any]] = []
    for name in names { extra.append(["id": "scanned", "extra": true]) }
    return extra
}

// expect: rowInfo => extra:boolean?,id:string,name:string?,size:integer?
func rowInfo() throws -> [String: Any] {
    let rows = try listRows()["rows"] as? [[String: Any]] ?? []
    guard let row = rows.first else { throw Failure() }
    var info = row
    return info
}

// Rule 12: a helper writes keys into the dictionary passed as `&payload`; the call sits in a closure.
// expect: inoutStatus => domains:array,label:string,last_exit:any?,pid:integer?,program:any?,running:boolean
func inoutStatus(_ label: String) throws -> [String: Any] {
    var payload: [String: Any] = ["label": label, "running": false]
    var domains: [String] = []
    each { service in
        mergeService(service, into: &payload)
    }
    payload["domains"] = domains
    return payload
}

// Rule 12: an unconditional call and unconditional writes are required; a write under `if` is optional.
// expect: inoutTop => always:boolean,sometimes:string?
func inoutTop() -> [String: Any] {
    var out: [String: Any] = [:]
    fill(&out)
    return out
}

func fill(_ target: inout [String: Any]) {
    target["always"] = true
    if flag { target["sometimes"] = "x" }
}

func mergeService(_ service: [String: Any], into row: inout [String: Any]) {
    let pid = (service["PID"] ?? service["pid"]) as? Int ?? 0
    if pid > 0 || row["pid"] == nil {
        row["pid"] = pid
        row["running"] = pid > 0
        row["last_exit"] = service["LastExitStatus"] ?? 0
    }
    if let program = service["Program"] {
        row["program"] = program
    }
}
