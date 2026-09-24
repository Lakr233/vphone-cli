import Darwin
import Foundation
import IcliKit
import IcliSystem
import VphonedNative

// MARK: - Processes and Memory

extension GuestAPI {
    static func executeProcess(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "processes.list":
            return try processList(filter: optionalString(params, "filter"))
        case "processes.kill":
            let pid = try integer(params, "pid")
            guard pid > 1, pid != Int(getpid()) else {
                throw GuestAPIError.invalidRequest("pid \(pid) cannot be signalled")
            }
            let name = optionalString(params, "signal")?.uppercased() ?? "TERM"
            guard let signal = signals[name.hasPrefix("SIG") ? String(name.dropFirst(3)) : name] else {
                throw GuestAPIError.invalidRequest("signal must be one of \(signals.keys.sorted().joined(separator: ", "))")
            }
            try requireForce(params, "send SIG\(name) to \(pid)")
            guard kill(pid_t(pid), signal) == 0 else {
                throw GuestAPIError.operationFailed("kill(\(pid)): \(String(cString: strerror(errno)))")
            }
            return ["pid": pid, "signal": name]
        case "memory.jetsam":
            return try jetsamSnapshot()
        case "memory.pressure":
            return ["memory": memoryPressure()]
        default:
            return nil
        }
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
