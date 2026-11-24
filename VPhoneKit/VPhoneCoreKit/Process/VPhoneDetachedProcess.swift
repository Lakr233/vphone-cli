import Darwin
import Foundation

// MARK: - VPhoneDetachedProcess

/// Starts a child that outlives its parent: its own session, stdin on
/// /dev/null, stdout and stderr appended to an existing log file. `vm launch
/// --detach` and Launchpad's `vm start` share it.
public enum VPhoneDetachedProcess {
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    public struct SpawnError: Error, CustomStringConvertible, LocalizedError {
        public let reason: String
        /// The log or launcher the failure concerns; nil when it concerns neither.
        public let path: String?
        public var description: String { path.map { "\(reason) (\($0))" } ?? reason }
        public var errorDescription: String? { description }
    }

    /// Starts `executable` in a new session with no descriptor of ours
    /// inherited. `logFile` must exist; it is never created or truncated.
    /// `disclaim` makes the child responsible for itself, so macOS does not
    /// attribute it to the caller. Throws when `posix_spawn` fails, which
    /// includes opening the log.
    public static func spawn(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        logFile: URL,
        disclaim: Bool,
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Private libSystem call that Chromium and LLDB use for the same
        // reason. Without it the child still runs, just attributed to us.
        if disclaim, let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logFile.path, O_WRONLY | O_APPEND, 0)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let cwd {
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&actions, cwd.path)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
            }
        }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard result == 0 else {
            // posix_spawn does not say which of its steps failed, so name the
            // log or the launcher only when one of them is plainly at fault.
            let culprit = access(logFile.path, W_OK) != 0 ? logFile.path
                : access(executable.path, X_OK) != 0 ? executable.path : nil
            throw SpawnError(reason: String(cString: strerror(result)), path: culprit)
        }
        return pid
    }

    /// The raw wait status once `pid` has exited, nil while it runs. A pid
    /// already reaped, or not our child, gives `-errno` (a real status is
    /// never negative), so a second call is not nil.
    public static func exitStatus(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        if result == 0 { return nil }
        if result == -1 { return -errno }
        return status
    }

    /// "exit <n>", "signal <n>", or "unknown (errno <e>)" for a negative status.
    public static func describe(status: Int32) -> String {
        if status < 0 { return "unknown (errno \(-status))" }
        let signal = status & 0x7F
        return signal == 0 ? "exit \((status >> 8) & 0xFF)" : "signal \(signal)"
    }
}
