// Fixture for the value-type inference forms. Parsed only, never compiled.
// Each expect line is: function => catalog cell. SwiftFormTests mutates a marked token per form.

struct Info {
    var path: String
    var count: Int
}

func load() -> [String: Any] { [:] }
func rows() -> [[String: Any]] { [] }
func maybe() -> Info? { nil }
func values() -> [String: Int] { [:] }

// expect: dictSubscript => count:integer
func dictSubscript() -> [String: Any] {
    let table: [String: Int] = values()
    return ["count": table["a"]]
}

// expect: optionalChain => name:string
func optionalChain() -> [String: Any] {
    let info = maybe()
    return ["name": info?.path]
}

// expect: optionalMap => size:integer
func optionalMap() -> [String: Any] {
    return ["size": maybe().map { $0.count }]
}

// expect: coalesced => path:string
func coalesced() -> [String: Any] {
    let info = maybe()
    return ["path": info?.path ?? ""]
}

// expect: castAny => n:integer
func castAny(n: Int) -> [String: Any] {
    return ["n": n as Any]
}

// expect: tryOptional => info:object
func tryOptional() -> [String: Any] {
    let table = try? values()
    return ["info": table]
}

// expect: literalArrays => ints:array,names:array
func literalArrays() -> [String: Any] {
    let names = ["a", "b"]
    let ints = [1, 2]
    return ["names": names.map { $0 }, "ints": ints.filter { $0 > 1 }]
}

// expect: switchValue => level:string
func switchValue(flag: Int) -> [String: Any] {
    let text = switch flag {
    case 0: "zero"
    default: "other"
    }
    return ["level": text]
}

// expect: ifValue => level:integer
func ifValue(flag: Bool) -> [String: Any] {
    let n = if flag { 1 } else { 2 }
    return ["level": n]
}

// expect: localClosure => label:string
func localClosure() -> [String: Any] {
    let make = { "label" }
    return ["label": make()]
}

// expect: reduceInto => total:object
func reduceInto() -> [String: Any] {
    let total = rows().reduce(into: [String: Int]()) { $0["x"] = 1 }
    return ["total": total]
}

// expect: shapeRead => name:string
func shapeRead() -> [String: Any] {
    let source = load()
    var out: [String: Any] = [:]
    out["name"] = "n"
    let copy = out
    return ["name": copy["name"] ?? ""]
}
