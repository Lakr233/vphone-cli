// Fixture for SwiftExtractor rules 0-3. Parsed only, never compiled.
// Each `expect:` line is `<function>[@<arm>] => <catalog result cell>`.

// expect: literalReturn => count:integer,name:string
func literalReturn() -> [String: Any] {
    return ["name": "x", "count": 3]
}

// expect: boundVariable => flag:boolean,items:array,note:string?,path:string
func boundVariable(flag: Bool) -> [String: Any] {
    var result: [String: Any] = ["path": "/tmp", "items": [1, 2]]
    result["flag"] = true
    if flag {
        result["note"] = "set"
    }
    return result
}

// expect: emptyStart => a:string,b:integer?,c:boolean?,d:number?,e:object?
func emptyStart(items: [Int]) -> [String: Any] {
    var out = [String: Any]()
    out["a"] = "always"
    guard !items.isEmpty else { return out }
    out["b"] = 1
    for _ in items { out["c"] = false }
    items.forEach { _ in out["d"] = 1.5 }
    switch items.count {
    case 1: out["e"] = [:]
    default: break
    }
    return out
}

// expect: multipleReturns => always:string,fail:boolean?,ok:boolean?
func multipleReturns(good: Bool) -> [String: Any] {
    if !good {
        return ["always": "a", "fail": true]
    }
    return ["always": "a", "ok": true]
}

// expect: dispatcher@alpha => a:string,shared:integer
// expect: dispatcher@beta => b:integer,shared:integer
func dispatcher(_ method: Method) -> [String: Any] {
    switch method {
    case .alpha:
        return ["a": "x", "shared": 1]
    case .beta, .gamma:
        return ["b": 2, "shared": 3]
    }
}

// expect: dispatcherBound@alpha => a:string,late:integer?
// expect: dispatcherBound@beta => b:integer
func dispatcherBound(_ method: Method, cond: Bool) -> [String: Any] {
    switch method {
    case .alpha:
        var r: [String: Any] = ["a": "x"]
        if cond { r["late"] = 1 }
        return r
    case .beta:
        var r: [String: Any] = ["b": 2]
        return r
    }
}

// Type inference (REQ-RPC-007): declared locals, parameters and properties give a
// type; an external property or `?? NSNull()` gives any.
// expect: typed => count:integer,external:any,fallback:any,items:array,label:string,meta:object,mixed:any,parsed:integer,ratio:number,same:integer,yes:boolean
func typed(_ pasteboard: Pasteboard, value: Int?, flag: Bool) -> [String: Any] {
    let n: Int = 4
    let ratio: Double = 0.5
    let label = "x"
    var items: [String] = []
    let meta: [String: Any] = [:]
    let same = flag ? 1 : 2
    let mixed = flag ? 1 : "a"
    return [
        "count": n, "external": pasteboard.changeCount, "yes": true,
        "fallback": value ?? NSNull(), "ratio": ratio, "label": label,
        "items": items, "meta": meta, "parsed": Int(label), "same": same, "mixed": mixed,
    ]
}

struct Holder {
    var total: Int = 0
    let name: String

    // expect: typedMember => name:string,total:integer
    func typedMember() -> [String: Any] {
        return ["total": self.total, "name": name]
    }
}
