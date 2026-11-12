import Foundation

enum ProcessMethod: String, GuestMethod {
    case processesSpawn = "processes.spawn"
    case processesOutput = "processes.output"
    case processesOutputRelease = "processes.output_release"
    case posterInspect = "poster.inspect"
    case processesList = "processes.list"
    case processesKill = "processes.kill"
    case memoryJetsam = "memory.jetsam"
    case memoryPressure = "memory.pressure"

    var spec: MethodSpec {
        switch self {
        case .processesSpawn:
            MethodSpec(.required("executable", .string, "Allowed program to run, looked up at a fixed path", values: ["ps", "launchctl", "log"]),
                       .optional("arguments", .array, "Up to 16 argument strings, each 1-256 bytes, passed directly with no shell"),
                       .optional("timeout_ms", .number, "Milliseconds to wait before the process is killed", default: 3000, min: 100, max: 10000),
                       .optional("max_output_bytes", .integer, "Bytes of each stream returned inline; the rest stays readable through output_id", default: GuestProcessSpawnPolicy.outputLimit, min: 1, max: Double(GuestProcessSpawnPolicy.outputLimit)),
                       .optional("max_capture_bytes", .integer, "Bytes of each stream captured to the spool; the excess is discarded", default: 2097152, min: 1, max: 16777216),
                       summary: "Run ps, launchctl or log in the guest without a shell; return exit code and the first page of stdout and stderr.", result: [.required("arguments", .array), .required("capture_truncated", .boolean), .required("executable", .string), .required("exit_code", .integer).nullable(), .optional("output_dir", .string), .optional("output_id", .string), .required("pid", .integer), .required("signal", .integer).nullable(), .required("stderr", .string), .required("stderr_total", .integer), .required("stderr_truncated", .boolean), .required("stdout", .string), .required("stdout_total", .integer), .required("stdout_truncated", .boolean), .required("timed_out", .boolean)])
        case .processesOutput:
            MethodSpec(.required("output_id", .string, "output_id from a truncated processes.spawn reply"),
                       .required("stream", .string, "Which captured stream to read", values: ["stdout", "stderr"]),
                       .optional("offset", .integer, "Byte position to start reading at", default: 0, min: 0, max: 1099511627776),
                       .optional("limit", .integer, "Maximum bytes to read", default: 65536, min: 1, max: 65536),
                       .optional("binary", .boolean, "Return the raw bytes as base64 instead of UTF-8 text", default: false),
                       summary: "Read a slice of the output a processes.spawn call spooled; next_offset continues where it ended.", result: [.required("data", .string), .optional("next_offset", .integer), .required("total", .integer)])
        case .processesOutputRelease:
            MethodSpec(.required("output_id", .string, "output_id from a truncated processes.spawn reply"),
                       summary: "Delete the spooled output of a processes.spawn call to free guest disk.", result: [.required("released", .boolean)])
        case .posterInspect: MethodSpec(.required("pid", .integer, "Process id to inspect", min: 2), summary: "Report whether the poster scene inspection helper is available for a process; currently never inspects.", result: [.required("available", .boolean), .required("pid", .integer), .required("reason", .string)])
        case .processesList: MethodSpec(.optional("filter", .string, "Keep only processes whose name contains this text, ignoring case"), summary: "List guest processes with pid, parent, uid, CPU, memory, jetsam band and app bundle id.", result: [.required("count", .integer), .required("processes", .array)], paged: MethodSpec.Paged(key: "processes", order: .keys(["pid"])))
        case .processesKill:
            MethodSpec(.required("pid", .integer, "Process id to signal; 1 and the daemon itself are refused", min: 2),
                       .optional("signal", .string, "Signal name, with or without the SIG prefix", values: ["HUP", "INT", "QUIT", "KILL", "TERM", "STOP", "CONT", "USR1", "USR2"], default: "TERM"),
                       summary: "Send a signal to a guest process by pid; defaults to SIGTERM.",
                       force: .always("send SIG<signal> to <pid>") { p in
                           let r = try GuestAPI.killRequest(p)
                           return "send SIG\(r.name) to \(r.pid)"
                       }, result: [.required("pid", .integer), .required("signal", .string)])
        case .memoryJetsam: MethodSpec(summary: "Read guest memory totals, pressure level, jetsam priority list and memorystatus properties.", result: [.required("memory", .object), .optional("priorities", .array), .optional("priorities_error", .string), .required("properties", .object).open()])
        case .memoryPressure: MethodSpec(summary: "Read guest total memory, free level and pressure level; cheaper than memory.jetsam for polling.", result: [.required("memory", .object)])
        }
    }
}
