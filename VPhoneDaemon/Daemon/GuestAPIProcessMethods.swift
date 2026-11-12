import Foundation

enum ProcessMethod: String, GuestMethod {
    case processSpawn = "process.spawn"
    case posterInspect = "poster.inspect"
    case processesList = "processes.list"
    case processesKill = "processes.kill"
    case memoryJetsam = "memory.jetsam"
    case memoryPressure = "memory.pressure"

    var spec: MethodSpec {
        switch self {
        case .processSpawn:
            MethodSpec(.required("executable", .string, "Allowed program to run, looked up at a fixed path", values: ["ps", "launchctl", "log"]),
                       .optional("arguments", .array, "Up to 16 argument strings, each 1-256 bytes, passed directly with no shell"),
                       .optional("timeout_seconds", .number, "Seconds to wait before the process is killed", default: 3.0, min: 0.1, max: 10),
                       summary: "Run ps, launchctl or log in the guest without a shell and return exit code, stdout and stderr.", result: [.required("arguments", .array), .required("executable", .string), .required("exit_code", .integer).nullable(), .required("pid", .integer), .required("signal", .integer).nullable(), .required("stderr", .string), .required("stdout", .string), .required("timed_out", .boolean)])
        case .posterInspect: MethodSpec(.required("pid", .integer, "Process id to inspect", min: 2), summary: "Report whether the poster scene inspection helper is available for a process; currently never inspects.", result: [.required("available", .boolean), .required("pid", .integer), .required("reason", .string)])
        case .processesList: MethodSpec(.optional("filter", .string, "Keep only processes whose name contains this text, ignoring case"), summary: "List guest processes with pid, parent, uid, CPU, memory, jetsam band and app bundle id.", result: [.required("count", .integer), .required("processes", .array)])
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
