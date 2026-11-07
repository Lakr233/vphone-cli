// Fixture for the type-inference forms (REQ-RPC-007). Parsed only, never compiled.
// Each expect line is: function => catalog cell.

struct Probe {
    var pid: Int32
    var name: String
    var alive: Bool
    var pair: (code: Int, label: String)
    func status() -> Int { 0 }
    func describe(verbose: Bool) -> String { "" }
    func raw() -> [String: Any] { [:] }
}

enum Level: Int {
    case low = 1
}

func makeProbe() -> Probe { fatalError() }
func countThings() -> Int { 0 }
func table() -> [String: Any] { [:] }

// expect: typedParam => alive:boolean,name:string,pid:integer
func typedParam(probe: Probe) -> [String: Any] {
    return ["pid": probe.pid, "name": probe.name, "alive": probe.alive]
}

// expect: typedLocalAndCalls => count:integer,described:string,status:integer
func typedLocalAndCalls() -> [String: Any] {
    let probe = makeProbe()
    return ["status": probe.status(), "described": probe.describe(verbose: true), "count": countThings()]
}

// expect: tupleMembers => code:integer,label:string
func tupleMembers(probe: Probe) -> [String: Any] {
    return ["code": probe.pair.code, "label": probe.pair.1]
}

// expect: castsAndConversions => as_int:integer,as_text:string,converted:integer,optional_cast:boolean
func castsAndConversions(value: Any) -> [String: Any] {
    return [
        "as_int": value as! Int,
        "as_text": String(describing: value),
        "converted": Int("4") ?? 0,
        "optional_cast": (value as? Bool) ?? false,
    ]
}

// expect: comparisons => both:boolean,equal:boolean,is_string:boolean,negated:boolean
func comparisons(a: Int, b: Int, value: Any) -> [String: Any] {
    return ["equal": a == b, "both": a > 1 && b < 2, "negated": !(a == b), "is_string": value is String]
}

// expect: ternaries => agree:integer,disagree:any
func ternaries(flag: Bool) -> [String: Any] {
    return ["agree": flag ? 1 : 2, "disagree": flag ? 1 : "two"]
}

// expect: coalescing => fallback:string,number:number
func coalescing(text: String?, scale: Double?) -> [String: Any] {
    return ["fallback": text ?? "none", "number": scale ?? 1]
}

// expect: arithmetic => ratio:number,sum:integer,widest:integer
func arithmetic(a: Int, b: Int, ratio: Double) -> [String: Any] {
    return ["sum": a + b * 2, "ratio": ratio * 2, "widest": max(a, b)]
}

// expect: bindings => from_guard:string?,from_if:integer?,from_loop:integer?
func bindings(text: String?, numbers: [Int]) -> [String: Any] {
    var out: [String: Any] = [:]
    if let count = numbers.first { out["from_if"] = count }
    guard let value = text else { return out }
    out["from_guard"] = value
    for number in numbers { out["from_loop"] = number }
    return out
}

// expect: destructuring => code:integer,label:string
func destructuring(probe: Probe) -> [String: Any] {
    let (code, label) = probe.pair
    return ["code": code, "label": label]
}

// expect: nestedFunction => inner:integer
func nestedFunction() -> [String: Any] {
    func measure() -> Int { 1 }
    return ["inner": measure()]
}

// expect: arrays => doubled:array,empty:array,names:array
func arrays(names: [String]) -> [String: Any] {
    return ["names": names, "doubled": names.map { $0 + $0 }, "empty": [Int]()]
}

// expect: rawValue => level:integer
func rawValue(level: Level) -> [String: Any] {
    return ["level": level.rawValue]
}

// expect: builtins => date:number,process:integer
func builtins(start: Date) -> [String: Any] {
    return ["process": getpid(), "date": Date().timeIntervalSince(start)]
}

// expect: cStruct => height:integer,width:integer
func cStruct() -> [String: Any] {
    let size = probe_size()
    return ["width": size.width, "height": size.height]
}

// Genuinely dynamic sources stay any.
// expect: dynamic => boxed:any,subscript:any
func dynamic(box: Any, bag: [String: Any]) -> [String: Any] {
    return ["boxed": box, "subscript": bag["x"] ?? 0]
}

// A closure parameter that shadows a typed name is not the outer type.
// expect: shadowed => inner:any?
func shadowed(item: Int, boxes: [Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    boxes.forEach { item in out["inner"] = item }
    return out
}
