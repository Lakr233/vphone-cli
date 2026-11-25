import Foundation
import VPhoneCoreKit

/// A started child process whose merged stdout and stderr arrive line by line
/// on a background thread.
///
/// Two output modes:
/// - A pipe, for commands that finish. Output ends when every holder of the
///   pipe has closed it.
/// - A log file, for `vm launch`. The guest must outlive Launchpad: with a
///   pipe, quitting the app would close the read end and the next line of
///   guest serial output would kill the VM with SIGPIPE. The file is tailed
///   while the app runs and stays behind as the machine's console log.
///   The guest is also detached: it gets its own session and Launchpad
///   disclaims responsibility for it, so macOS does not keep Launchpad listed
///   as running in the background after the app quits.
///
///   What is started detached is `vphone-launchpad-launcher` from the app's
///   Contents/MacOS, with `vphone-cli` and its arguments after it. The
///   launcher is responsible for itself and starts `vphone-cli` without
///   disclaiming, so it is responsible for `vphone-vm` and its Virtualization
///   service. macOS ties a privacy permission (microphone, location) to the
///   responsible process's signature. `vphone-cli` is signed ad hoc, so every
///   bundle build would be asked again. A tool in the app's Contents/MacOS
///   is attributed to the app, so the request is the app's and is asked
///   once for its Developer ID signature; under the hardened runtime the app
///   needs the matching entitlement (Resources/VPhoneLaunchpad.entitlements).
///   Without the launcher (previews, a build that lacks it) or for a
///   `vphone-cli` it would refuse, Launchpad starts `vphone-cli` directly,
///   responsible for itself as before.
final nonisolated class VPhoneLaunchpadChildProcess: @unchecked Sendable {
    private let process = Process()
    /// Set instead of `process` for a detached child.
    private var detachedPID: pid_t?
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var hasExited = false
    private var exitCode: Int32 = 0
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        logFile: URL? = nil,
        // Added to the environment of a child without `logFile`.
        environment extra: [String: String] = [:],
        onLine: @escaping @Sendable (String) -> Void,
    ) throws {
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.standardInput = FileHandle.nullDevice

        if let logFile {
            try FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            let command = Self.throughLauncher(executable: executable, arguments: arguments)
            let pid = try Self.spawnDetached(
                executable: command.executable,
                arguments: command.arguments,
                currentDirectory: currentDirectory,
                logFile: logFile,
            )
            detachedPID = pid
            Thread.detachNewThread { [self] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                lock.withLock {
                    exitCode = Self.exitCode(status)
                    hasExited = true
                }
            }
            let reader = try FileHandle(forReadingFrom: logFile)
            Thread.detachNewThread { [self] in
                tail(reader, onLine)
            }
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Transfers report `progress <done> <total>` lines instead of a
            // terminal bar, which the pipe would drop.
            var environment = ProcessInfo.processInfo.environment
            environment["VPHONE_PROGRESS"] = "lines"
            environment.merge(extra) { _, given in given }
            process.environment = environment
            try process.run()
            let reader = pipe.fileHandleForReading
            Thread.detachNewThread { [self] in
                VPhoneLaunchpadLineReader.readLines(from: reader, onLine: onLine)
                process.waitUntilExit()
                finish(process.terminationStatus)
            }
        }
    }

    var isRunning: Bool {
        lock.withLock { exitStatus == nil }
    }

    /// The exit status, once the process has exited and its output drained.
    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// SIGINT, which `vphone-cli` treats as a graceful stop.
    func interrupt() {
        signal(SIGINT)
    }

    func terminate() {
        signal(SIGTERM)
    }

    private func signal(_ signal: Int32) {
        if let detachedPID {
            // Until waitpid reaps it the PID cannot be reused, so this only
            // ever reaches our own child. The launcher passes the signal on
            // to vphone-cli and exits the way it does.
            if lock.withLock({ !hasExited }) {
                kill(detachedPID, signal)
            }
        } else if process.isRunning {
            kill(process.processIdentifier, signal)
        }
    }

    private func tail(_ reader: FileHandle, _ onLine: (String) -> Void) {
        var splitter = VPhoneLaunchpadLineSplitter()
        while true {
            let exited = lock.withLock { hasExited }
            if let chunk = try? reader.readToEnd(), !chunk.isEmpty {
                splitter.feed(chunk, onLine)
            }
            if exited {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        splitter.flush(onLine)
        try? reader.close()
        finish(lock.withLock { exitCode })
    }

    // MARK: - Detached spawn

    /// The launcher with `executable` and `arguments` after it, when the app
    /// carries one and it would accept them; otherwise the command unchanged.
    private static func throughLauncher(
        executable: URL,
        arguments: [String],
    ) -> (executable: URL, arguments: [String]) {
        guard let launcher = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(VPhoneLaunchpadLauncherPolicy.executableName),
            FileManager.default.isExecutableFile(atPath: launcher.path),
            (try? VPhoneLaunchpadLauncherPolicy.check(executable: executable.path, arguments: arguments)) != nil
        else {
            return (executable, arguments)
        }
        return (launcher, [executable.path] + arguments)
    }

    /// Starts `executable` in a new session, responsible for itself, with
    /// stdin on /dev/null and stdout and stderr appended to `logFile`. No other
    /// descriptor of Launchpad's is inherited.
    private static func spawnDetached(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        logFile: URL,
    ) throws -> pid_t {
        try VPhoneDetachedProcess.spawn(
            executable: executable,
            arguments: arguments,
            cwd: currentDirectory,
            logFile: logFile,
            disclaim: true,
        )
    }

    /// The same number `Process.terminationStatus` reports: the exit code, or
    /// the signal that ended the process.
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }

    private func finish(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: status)
        }
    }
}
