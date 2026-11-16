import Darwin
import Foundation

// MARK: - VPhoneVirtualMachineLaunchError

public enum VPhoneVirtualMachineLaunchError: Error, CustomStringConvertible {
    case spawnFailed(errno: Int32, logPath: String)
    case exitedBeforeReady(status: Int32, logTail: String)
    case notReady(timeout: TimeInterval, logTail: String)

    public var description: String {
        switch self {
        case let .spawnFailed(code, logPath):
            return "vphone-vm could not be started: \(String(cString: strerror(code))) (errno \(code)). "
                + "Log file: \(logPath). Check that the guest binary exists and is executable "
                + "and that the log directory exists and is writable."

        case let .exitedBeforeReady(status, logTail):
            return "vphone-vm exited with status \(status) before it was ready.\n"
                + Self.tail(logTail)
                + "Fix the cause shown in the log, then launch again."

        case let .notReady(timeout, logTail):
            let seconds = timeout == timeout.rounded() ? String(Int(timeout)) : String(timeout)
            return "vphone-vm did not answer on vphone.sock within \(seconds) seconds and was killed.\n"
                + Self.tail(logTail)
                + "Read the log for the cause, or raise the ready timeout."
        }
    }

    private static func tail(_ logTail: String) -> String {
        logTail.isEmpty ? "The log is empty.\n" : "Log tail:\n\(logTail)\n"
    }
}

// MARK: - VPhoneVirtualMachineLaunch

/// Boots a VM bundle in `vphone-vm`. The caller has already resolved the
/// bundle, run host preflight and chosen the planner; this type stages
/// `vphoned`, runs the guest and saves the shader cache afterwards.
public struct VPhoneVirtualMachineLaunch: Sendable {
    public struct Options: Sendable {
        public var dfu: Bool
        public var headless: Bool
        public var apiListen: String?
        public var kernelDebugPort: Int?

        public init(dfu: Bool = false, headless: Bool = false, apiListen: String? = nil, kernelDebugPort: Int? = nil) {
            self.dfu = dfu
            self.headless = headless
            self.apiListen = apiListen
            self.kernelDebugPort = kernelDebugPort
        }
    }

    /// A guest started by `startDetached`. The caller owns the process.
    public struct Detached: Sendable {
        public let pid: Int32
        public let logURL: URL
        public let socketPath: String

        public init(pid: Int32, logURL: URL, socketPath: String) {
            self.pid = pid
            self.logURL = logURL
            self.socketPath = socketPath
        }
    }

    public let bundle: VPhoneBundle
    public let planner: VPhoneGuestLaunchPlanner
    public let layout: VPhoneLaunchLayout
    public let options: Options
    /// A system the restore installed customised (`minimal`) is sealed and
    /// boots on a stock AMFI: a vphoned the host pushed would never run, and
    /// the host would push it again on every probe. Without the staged copy,
    /// vphone-vm pushes none.
    public let restoredCustomisedSystem: Bool

    public init(
        bundle: VPhoneBundle,
        planner: VPhoneGuestLaunchPlanner,
        layout: VPhoneLaunchLayout,
        options: Options,
        restoredCustomisedSystem: Bool,
    ) {
        self.bundle = bundle
        self.planner = planner
        self.layout = layout
        self.options = options
        self.restoredCustomisedSystem = restoredCustomisedSystem
    }

    // MARK: - Foreground

    /// Runs the guest in the foreground and returns its exit status. stdio is
    /// inherited, so the guest's serial console streams to the caller's
    /// terminal, and the child gets the terminal's foreground group.
    /// `trace`, when given, receives the `[trace] spawning:` line.
    public func run(trace: ((String) -> Void)? = nil) throws -> Int32 {
        let args = try prepare()

        if let trace {
            let (exe, spawned) = planner.plan(args)
            trace("[trace] spawning: \(exe.path) \(spawned.joined(separator: " "))")
        }

        defer {
            do { try VPhoneShaderCache.checkpoint(machineDirectory: bundle.url) }
            catch { fputs("warning: could not save shader cache: \(error)\n", stderr) }
        }
        return try planner.run(args, cwd: bundle.url)
    }

    // MARK: - Detached

    /// Seconds `startDetached` waits for the guest to answer when the caller
    /// gives no `readyTimeout`.
    public static let defaultReadyTimeout: TimeInterval = 120

    /// Starts the guest in a session of its own, stdin from `/dev/null` and
    /// stdout and stderr appended to `logURL`, and returns once `vphone.sock`
    /// answers a ping. Throws `VPhoneBundleActivityError.running` before
    /// spawning when the machine is already running.
    public func startDetached(logURL: URL, readyTimeout: TimeInterval = defaultReadyTimeout) throws -> Detached {
        try VPhoneBundleActivity.requireStopped(bundle)
        let args = try prepare()

        let pid = try spawn(arguments: args, logURL: logURL)
        try? VPhoneHostFilePermissions.makeAccessible(at: logURL)

        let socketPath = bundle.url.appendingPathComponent("vphone.sock").path
        let deadline = Date().addingTimeInterval(readyTimeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0,
               VPhoneHostAutomationProbe.ping(socketPath: socketPath, timeout: max(1, Int(remaining.rounded(.up))))
            {
                // Ready, unless the process is already gone.
                if let status = Self.exitStatus(of: pid) {
                    throw VPhoneVirtualMachineLaunchError.exitedBeforeReady(status: status, logTail: Self.logTail(of: logURL))
                }
                return Detached(pid: pid, logURL: logURL, socketPath: socketPath)
            }
            if let status = Self.exitStatus(of: pid) {
                throw VPhoneVirtualMachineLaunchError.exitedBeforeReady(status: status, logTail: Self.logTail(of: logURL))
            }
            if deadline.timeIntervalSinceNow <= 0 {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                throw VPhoneVirtualMachineLaunchError.notReady(timeout: readyTimeout, logTail: Self.logTail(of: logURL))
            }
            Thread.sleep(forTimeInterval: min(0.25, max(0.01, deadline.timeIntervalSinceNow)))
        }
    }

    /// The last 20 lines of at most the last 16 KiB of the log.
    static func logTail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let limit: UInt64 = 16 * 1024
        guard let size = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
    }

    /// The exit status when the child has exited (128 plus the signal number
    /// when a signal killed it), nil while it runs.
    private static func exitStatus(of pid: Int32) -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return nil }
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }

    private func spawn(arguments: [String], logURL: URL) throws -> Int32 {
        let (executable, args) = planner.plan(arguments)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, bundle.url.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT: the guest keeps only the three descriptors set above, not
        // whatever files this process (or a parallel caller) holds open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard result == 0 else {
            throw VPhoneVirtualMachineLaunchError.spawnFailed(errno: result, logPath: logURL.path)
        }
        return pid
    }

    // MARK: - Preparation

    /// Stages (or removes) `vphoned` and returns the boot arguments.
    private func prepare() throws -> [String] {
        if !options.dfu {
            if restoredCustomisedSystem {
                try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(".vphoned.signed"))
            } else {
                _ = try layout.stageVphoned(into: bundle)
            }
        }

        let boot = VPhoneBootCommand(
            config: bundle.configURL,
            dfu: options.dfu,
            headless: options.headless,
            apiListen: options.apiListen,
            kernelDebugPort: options.kernelDebugPort,
        )
        return boot.bootArguments
    }
}
