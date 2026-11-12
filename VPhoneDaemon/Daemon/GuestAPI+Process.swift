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
        case .processesOutput:
            return try processesOutput(params)
        case .processesOutputRelease:
            return try processesOutputRelease(params)
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
        let outputCap = try GuestPaging.strictInt(params["max_output_bytes"], name: "max_output_bytes", range: 1 ... GuestProcessSpawnPolicy.outputLimit) ?? GuestProcessSpawnPolicy.outputLimit
        let captureCap = try GuestPaging.strictInt(params["max_capture_bytes"], name: "max_capture_bytes", range: 1 ... 16_777_216) ?? 2_097_152

        let spool = GuestProcessSpool.shared
        let reservation = try spool.reserve(maxCaptureBytes: captureCap)
        var keep = false
        defer { spool.finish(reservation, keep: keep) }
        let stdoutFile = try spool.writer(reservation, stream: "stdout")
        let stderrFile = try spool.writer(reservation, stream: "stderr")

        // A write error is kept and the pipes keep draining (ceiling 0 discards), so the child never blocks.
        var captured = [0, 0]
        var capturedAll = true
        var writeError: Error?
        let run = try runProgram(executable, arguments, timeout: timeout) { stdout, stderr in
            for (index, (descriptor, file)) in [(stdout, stdoutFile), (stderr, stderrFile)].enumerated() {
                do {
                    let counts = try GuestProcessOutput.drain(descriptor, to: file, ceiling: writeError == nil ? captureCap - captured[index] : 0)
                    captured[index] += counts.written
                    if counts.written < counts.total { capturedAll = false }
                } catch {
                    writeError = writeError ?? error
                }
            }
        }
        if let writeError { throw GuestAPIError.operationFailed("spool write failed: \(writeError.localizedDescription); repeat the command") }
        let pages = try ["stdout", "stderr"].map { try spool.firstPage(outputID: reservation.outputID, stream: $0, cap: outputCap) }
        // The String/Int/Bool wrappers let the result-schema drift check infer each key's type.
        var reply: [String: Any] = [
            "executable": executable, "arguments": arguments, "pid": Int(run.pid),
            "timed_out": run.timedOut, "exit_code": run.exitCode.map { $0 as Any } ?? NSNull(),
            "signal": run.signal.map { $0 as Any } ?? NSNull(),
            "stdout": String(pages[0].text), "stderr": String(pages[1].text),
            "stdout_total": Int(captured[0]), "stderr_total": Int(captured[1]),
            "stdout_truncated": Bool(pages[0].truncated), "stderr_truncated": Bool(pages[1].truncated),
            "capture_truncated": !capturedAll,
        ]
        // A timed-out spawn drops its spool, so it has no output_id to page.
        if !run.timedOut, pages[0].truncated || pages[1].truncated {
            reply["output_id"] = reservation.outputID
            reply["output_dir"] = reservation.outputDir.path
            keep = true
        }
        return reply
    }

    private static func processesOutput(_ params: [String: Any]) throws -> [String: Any] {
        let offset = try GuestPaging.strictInt(params["offset"], name: "offset", range: 0 ... 1_099_511_627_776) ?? 0
        let limit = try GuestPaging.strictInt(params["limit"], name: "limit", range: 1 ... 65536) ?? 65536
        let slice = try GuestProcessSpool.shared.slice(outputID: string(params, "output_id"), stream: string(params, "stream"),
                                                       offset: offset, limit: limit, binary: bool(params, "binary"))
        var reply: [String: Any] = ["data": slice.data, "total": slice.total]
        if let next = slice.nextOffset { reply["next_offset"] = next }
        return reply
    }

    private static func processesOutputRelease(_ params: [String: Any]) throws -> [String: Any] {
        try GuestProcessSpool.shared.release(outputID: string(params, "output_id"))
        return ["released": true]
    }

    struct ProgramRun {
        let pid: pid_t
        let timedOut: Bool
        /// Nil when the program was killed by a signal or did not exit.
        let exitCode: Int?
        let signal: Int?
        /// Empty when the caller passed its own `drain`.
        let stdout: String
        let stderr: String
    }

    /// Run a program at a fixed path with no shell and kill it at `timeout`. `drain` is
    /// called with the nonblocking stdout and stderr read ends while the program runs and
    /// once after it ends; without one, both outputs are captured in memory up to
    /// GuestProcessSpawnPolicy.outputLimit.
    static func runProgram(_ executable: String, _ arguments: [String], timeout: Double,
                           drain: ((_ stdout: Int32, _ stderr: Int32) -> Void)? = nil) throws -> ProgramRun {
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
        let drainBoth = drain ?? { stdout, stderr in
            drainSpawnPipe(stdout, into: &output); drainSpawnPipe(stderr, into: &errorOutput)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var exited = false
        while Date() < deadline {
            drainBoth(stdoutPipe.readEnd, stderrPipe.readEnd)
            if waitpid(pid, &status, WNOHANG) == pid { exited = true; break }
            usleep(10_000)
        }
        if !exited {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
        drainBoth(stdoutPipe.readEnd, stderrPipe.readEnd)
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
