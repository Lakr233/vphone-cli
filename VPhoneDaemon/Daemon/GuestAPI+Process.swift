import Darwin
import Foundation
import IcliKit
import IcliSystem
import VphonedNative

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
                       summary: "Run ps, launchctl or log in the guest without a shell and return exit code, stdout and stderr.", result: [.required("arguments", .array), .required("executable", .any), .required("exit_code", .any), .required("pid", .integer), .required("signal", .any), .required("stderr", .string), .required("stdout", .string), .required("timed_out", .boolean)])
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

// MARK: - Processes and Memory

extension GuestAPI {
    static func executeProcess(_ m: ProcessMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .processSpawn:
            return try spawnProcess(params)
        case .posterInspect:
            return try inspectPoster(params)
        case .processesList:
            return try processList(filter: optionalString(params, "filter"))
        case .processesKill:
            let (pid, name, signal) = try killRequest(params)
            guard kill(pid_t(pid), signal) == 0 else {
                throw GuestAPIError.operationFailed("kill(\(pid)): \(String(cString: strerror(errno)))")
            }
            return ["pid": pid, "signal": name]
        case .memoryJetsam:
            return try jetsamSnapshot()
        case .memoryPressure:
            return ["memory": memoryPressure()]
        }
    }

    fileprivate static func killRequest(_ params: [String: Any]) throws -> (pid: Int, name: String, signal: Int32) {
        let pid = try integer(params, "pid")
        guard pid > 1, pid != Int(getpid()) else {
            throw GuestAPIError.invalidRequest("pid \(pid) cannot be signalled")
        }
        let name = optionalString(params, "signal")?.uppercased() ?? "TERM"
        guard let signal = signals[name.hasPrefix("SIG") ? String(name.dropFirst(3)) : name] else {
            throw GuestAPIError.invalidRequest("signal must be one of \(signals.keys.sorted().joined(separator: ", "))")
        }
        return (pid, name, signal)
    }

    /// Read-only poster probe plumbing. The signed helper is intentionally
    /// optional until the guest payload is installed; callers get an explicit
    /// unavailable result rather than a synthetic scene snapshot.
    private static func inspectPoster(_ params: [String: Any]) throws -> [String: Any] {
        let pid = try integer(params, "pid")
        guard pid > 1 else { throw GuestAPIError.invalidRequest("pid must be a positive process id") }
        let helper = "/usr/libexec/vphone-poster-inspect"
        guard access(helper, X_OK) == 0 else {
            return ["available": false, "pid": pid, "reason": "poster instrumented helper is not installed"]
        }
        // Helper execution is deliberately not enabled until its payload hash
        // and target identity checks are wired into the guest manifest.
        return ["available": false, "pid": pid, "reason": "poster helper is present but not admitted"]
    }

    // This is deliberately a small diagnostic surface. It is not a general
    // shell: every executable has a fixed path and arguments are passed
    // directly to posix_spawn (there is no shell expansion).
    private static func spawnProcess(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["executable"] as? String,
              let executable = GuestProcessSpawnPolicy.executables[name] else { throw GuestAPIError.invalidRequest("executable must be one of " + GuestProcessSpawnPolicy.executables.keys.sorted().joined(separator: ", ")) }
        let arguments = params["arguments"] as? [String] ?? []
        let timeout = (params["timeout_seconds"] as? NSNumber).map { $0.doubleValue } ?? 3.0
        if let error = GuestProcessSpawnPolicy.validate(executable: name, arguments: arguments, timeout: timeout) { throw GuestAPIError.invalidRequest(error) }

        let stdoutPipe: GuestProcessPipe
        let stderrPipe: GuestProcessPipe
        do {
            stdoutPipe = try GuestProcessPipe()
            stderrPipe = try GuestProcessPipe()
        } catch let error as POSIXError {
            throw GuestAPIError.operationFailed("pipe: " + String(cString: strerror(error.code.rawValue)))
        }
        defer { withExtendedLifetime((stdoutPipe, stderrPipe)) {} }

        var argv = [UnsafeMutablePointer<CChar>?](repeating: nil, count: arguments.count + 2)
        argv[0] = strdup(executable)
        for (index, argument) in arguments.enumerated() { argv[index + 1] = strdup(argument) }
        defer { for value in argv where value != nil { free(value) } }
        var actions: posix_spawn_file_actions_t?
        vp_spawn_file_actions_init(&actions)
        defer { vp_spawn_file_actions_destroy(&actions) }
        vp_spawn_file_actions_adddup2(&actions, stdoutPipe.writeEnd, STDOUT_FILENO)
        vp_spawn_file_actions_adddup2(&actions, stderrPipe.writeEnd, STDERR_FILENO)
        vp_spawn_file_actions_addclose(&actions, stdoutPipe.readEnd)
        vp_spawn_file_actions_addclose(&actions, stderrPipe.readEnd)
        var pid: pid_t = 0
        let spawnError = vp_spawn(&pid, executable, &actions, nil, &argv, environ)
        guard spawnError == 0 else { throw GuestAPIError.operationFailed("posix_spawn: " + String(cString: strerror(spawnError))) }
        stdoutPipe.closeWriteEnd(); stderrPipe.closeWriteEnd()

        fcntl(stdoutPipe.readEnd, F_SETFL, O_NONBLOCK)
        fcntl(stderrPipe.readEnd, F_SETFL, O_NONBLOCK)
        var output = Data(); var errorOutput = Data(); var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var exited = false
        while Date() < deadline {
            drainSpawnPipe(stdoutPipe.readEnd, into: &output)
            drainSpawnPipe(stderrPipe.readEnd, into: &errorOutput)
            if waitpid(pid, &status, WNOHANG) == pid { exited = true; break }
            usleep(10_000)
        }
        if !exited {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
        drainSpawnPipe(stdoutPipe.readEnd, into: &output); drainSpawnPipe(stderrPipe.readEnd, into: &errorOutput)
        return [
            "executable": executable, "arguments": arguments, "pid": Int(pid),
            "timed_out": !exited, "exit_code": exited && (status & 0x7f) == 0 ? Int((status >> 8) & 0xff) : NSNull(),
            "signal": exited && (status & 0x7f) != 0 ? Int(status & 0x7f) : NSNull(),
            "stdout": String(decoding: output, as: UTF8.self), "stderr": String(decoding: errorOutput, as: UTF8.self),
        ]
    }

    private static func drainSpawnPipe(_ fd: Int32, into data: inout Data) {
        GuestProcessOutput.drain(fd, into: &data, limit: GuestProcessSpawnPolicy.outputLimit)
    }

    /// The three kernel memory sysctls of `memory.jetsam`, without its priority
    /// list and property plists, for panels that poll.
    private static func memoryPressure() -> [String: Any] {
        var memory: [String: Any] = [:]
        for (key, name) in [
            ("hw_memsize", "hw.memsize"),
            ("memorystatus_level", "kern.memorystatus_level"),
            ("memorystatus_vm_pressure_level", "kern.memorystatus_vm_pressure_level"),
        ] {
            var value: Int64 = 0
            var size = MemoryLayout<Int64>.size
            if sysctlbyname(name, &value, &size, nil, 0) == 0 {
                // The kern values are 32-bit; read them as such.
                memory[key] = size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
            }
        }
        return memory
    }

    private static let signals: [String: Int32] = [
        "HUP": SIGHUP, "INT": SIGINT, "QUIT": SIGQUIT, "KILL": SIGKILL, "TERM": SIGTERM,
        "STOP": SIGSTOP, "CONT": SIGCONT, "USR1": SIGUSR1, "USR2": SIGUSR2,
    ]

    /// The kernel's process list joined with resource usage, jetsam bands and
    /// the bundle identifier RunningBoard reports for app processes.
    private static func processList(filter: String?) throws -> [String: Any] {
        let rows = try listProcesses(filter: filter)["processes"] as? [[String: Any]] ?? []
        let jetsam = (try? jetsamSnapshot())?["priorities"] as? [[String: Any]] ?? []
        let bands = Dictionary(
            jetsam.compactMap { row -> (Int, [String: Any])? in
                guard let pid = row["pid"] as? Int else { return nil }
                return (pid, row)
            },
            uniquingKeysWith: { first, _ in first },
        )
        let apps = (try? runningApps())?["apps"] as? [[String: Any]] ?? []
        let bundles = Dictionary(
            apps.compactMap { app -> (Int, String)? in
                guard let pid = app["pid"] as? Int, let id = app["bundle_id"] as? String else { return nil }
                return (pid, id)
            },
            uniquingKeysWith: { first, _ in first },
        )
        let processes = rows.compactMap { row -> [String: Any]? in
            guard let pid = row["pid"] as? Int else { return nil }
            var usage = VPProcessUsage()
            guard vp_process_usage(Int32(pid), &usage) else { return nil }
            var process = row
            process["ppid"] = Int(usage.ppid)
            process["uid"] = Int(usage.uid)
            process["start_time"] = usage.start_time
            if usage.has_task_info {
                process["cpu_seconds"] = usage.cpu_seconds
                process["footprint_bytes"] = usage.footprint_bytes
                process["resident_bytes"] = usage.resident_bytes
            }
            if let band = bands[pid] {
                process["jetsam_priority"] = band["priority"]
                process["jetsam_limit_mb"] = band["limit_mb"]
            }
            if let bundle = bundles[pid] {
                process["bundle_id"] = bundle
            }
            return process
        }
        return ["processes": processes, "count": processes.count]
    }
}
