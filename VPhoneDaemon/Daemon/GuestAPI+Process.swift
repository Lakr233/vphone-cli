import Darwin
import Foundation
import IcliKit
import IcliSystem
import VphonedNative

// MARK: - Processes and Memory

extension GuestAPI {
    static func executeProcess(_ m: ProcessMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .processesSpawn:
            return try spawnProcess(params)
        case .posterInspect:
            return try inspectPoster(params)
        case .processesList:
            return try processList(filter: optionalString(params, "filter"))
        case .processesKill:
            let (pid, name, signal) = try killRequest(params)
            guard kill(pid_t(pid), signal) == 0 else {
                throw GuestAPIError.fromErrno(errno, "kill(\(pid)): \(String(cString: strerror(errno)))")
            }
            return ["pid": pid, "signal": name]
        case .memoryJetsam:
            return try jetsamSnapshot()
        case .memoryPressure:
            return ["memory": memoryPressure()]
        }
    }

    static func killRequest(_ params: [String: Any]) throws -> (pid: Int, name: String, signal: Int32) {
        let pid = try integer(params, "pid")
        guard pid > 1, pid != Int(getpid()) else {
            throw GuestAPIError.invalidRequest("pid \(pid) cannot be signalled", hint: "pid must be greater than 1 and not vphoned's own process")
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
        guard pid > 1 else { throw GuestAPIError.invalidRequest("pid must be a positive process id", hint: "pid must be an integer greater than 1") }
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
        let timeout = (params["timeout_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? 3.0
        if let error = GuestProcessSpawnPolicy.validate(executable: name, arguments: arguments, timeout: timeout) { throw GuestAPIError.invalidRequest(error) }
        let run = try runProgram(executable, arguments, timeout: timeout)
        return [
            "executable": executable, "arguments": arguments, "pid": Int(run.pid),
            "timed_out": run.timedOut, "exit_code": run.exitCode.map { $0 as Any } ?? NSNull(),
            "signal": run.signal.map { $0 as Any } ?? NSNull(),
            "stdout": run.stdout, "stderr": run.stderr,
        ]
    }

    struct ProgramRun {
        let pid: pid_t
        let timedOut: Bool
        /// Nil when the program was killed by a signal or did not exit.
        let exitCode: Int?
        let signal: Int?
        let stdout: String
        let stderr: String
    }

    /// Run a program at a fixed path with no shell, capture both outputs up to
    /// GuestProcessSpawnPolicy.outputLimit, and kill it at `timeout`.
    static func runProgram(_ executable: String, _ arguments: [String], timeout: Double) throws -> ProgramRun {
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
        guard spawnError == 0 else { throw GuestAPIError.fromErrno(spawnError, "posix_spawn: " + String(cString: strerror(spawnError))) }
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
        return ProgramRun(
            pid: pid, timedOut: !exited,
            exitCode: exited && (status & 0x7f) == 0 ? Int((status >> 8) & 0xff) : nil,
            signal: exited && (status & 0x7f) != 0 ? Int(status & 0x7f) : nil,
            stdout: String(decoding: output, as: UTF8.self), stderr: String(decoding: errorOutput, as: UTF8.self),
        )
    }

    static func drainSpawnPipe(_ fd: Int32, into data: inout Data) {
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
