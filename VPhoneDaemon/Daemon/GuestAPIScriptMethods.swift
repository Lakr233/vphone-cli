import Foundation

enum ScriptMethod: String, GuestMethod {
    case scriptEval = "script.eval"
    case scriptInfo = "script.info"

    var spec: MethodSpec {
        switch self {
        case .scriptEval: MethodSpec(.required("source", .string, "JavaScript source to run in a JavaScriptCore session"), .optional("timeout_ms", .number, "Milliseconds before the script is stopped; clamped to the range", default: 30000, min: 1000, max: 600000), summary: "Run a JavaScript snippet in an isolated guest session and return its result, output and crash state.", result: [.required("crashed", .boolean), .optional("error", .string), .optional("message", .string), .optional("ok", .boolean), .optional("output", .string), .optional("result", .string)])
        case .scriptInfo: MethodSpec(summary: "Report whether script evaluation is available, the engine, script globals and available shell programs.", result: [.required("available", .boolean), .required("engine", .string), .required("globals", .array), .required("programs", .object)])
        }
    }
}
