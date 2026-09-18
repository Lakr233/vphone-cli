import Darwin
import Foundation
import Virtualization

// MARK: - Errors

public enum VPhoneTunnelNetworkError: Error, Equatable {
    /// No `gvproxy` helper was found in any of the searched locations.
    case helperNotFound(searched: [String])
    /// A helper path was found but is not executable.
    case helperNotExecutable(path: String)
    /// Unix socket paths are limited by `sun_path`; the generated one is too long.
    case socketPathTooLong(path: String, limit: Int)
    /// `socket`/`bind`/`connect`/`setsockopt` failed.
    case socketSetupFailed(operation: String, errno: Int32)
    /// The helper died before its vfkit socket became ready.
    case helperExited(status: Int32, logTail: String?)
    /// `Process.run()` refused to launch the helper (permissions, wrong architecture, …).
    case helperStartFailed(path: String, reason: String)
    /// The helper is alive but never created its vfkit socket.
    case helperNotReady(socketPath: String, seconds: Double, logTail: String?)
    /// `start()` was called twice on the same instance.
    case alreadyStarted
}

extension VPhoneTunnelNetworkError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .helperNotFound(searched):
            """
            network mode 'tunnel' needs the 'gvproxy' helper, but it was not found. \
            Searched: \(searched.joined(separator: ", ")). \
            Run 'make net_helper' to download it into .tools/bin, or set VPHONE_GVPROXY \
            to an existing gvproxy binary.
            """
        case let .helperNotExecutable(path):
            "network helper at '\(path)' is not executable (chmod +x it, or set VPHONE_GVPROXY)"
        case let .socketPathTooLong(path, limit):
            """
            unix socket path is too long for sun_path (\(path.utf8.count) > \(limit) bytes): \(path). \
            Set VPHONE_NET_SOCKET_DIR to a short directory (e.g. /tmp).
            """
        case let .socketSetupFailed(operation, code):
            "network socket \(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        case let .helperExited(status, logTail):
            "network helper exited with status \(status) before its socket was ready"
                + (logTail.map { "\n--- helper log ---\n\($0)" } ?? "")
        case let .helperStartFailed(path, reason):
            "could not launch network helper at '\(path)': \(reason)"
        case let .helperNotReady(socketPath, seconds, logTail):
            "network helper did not create \(socketPath) within \(seconds)s"
                + (logTail.map { "\n--- helper log ---\n\($0)" } ?? "")
        case .alreadyStarted:
            "tunnel network backend already started"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - VPhoneTunnelNetwork

/// Host-side userspace networking for a guest NIC.
///
/// Apple's `VZNATNetworkDeviceAttachment` reuses Internet Sharing / vmnet, whose pf
/// NAT rules are pinned to the host's *physical* interface. When the host routes its
/// default route through a VPN (`utun`), guest egress is black-holed and neither mode
/// of NAT nor bridging can reach the network (see `research/userspace_networking_gvproxy.md`).
///
/// This backend replaces the kernel NAT with a userspace network stack:
/// the guest NIC is wired to a `SOCK_DGRAM` unix socket (`VZFileHandleNetworkDeviceAttachment`)
/// that is connected to `gvproxy`'s vfkit transport. All egress leaves the helper as ordinary
/// host sockets, so it follows the host routing table — VPN included — for free.
public final class VPhoneTunnelNetwork: @unchecked Sendable {
    public struct Options: Sendable {
        /// Explicit helper binary; when nil, `resolveHelper` searches the usual places.
        public var helperURL: URL?
        /// Where the helper writes its log; defaults to a file next to the VM (set by the caller).
        public var logFileURL: URL?
        /// Directory holding the two unix sockets. Must be short — see `sun_pathLimit`.
        public var socketDirectory: URL?
        /// How long to wait for the helper to publish its vfkit socket.
        public var readinessTimeout: TimeInterval
        /// Ask the helper for `-debug`: it then logs every guest frame it decodes.
        public var debug: Bool
        /// Ask the helper for `-pcap <path>`: it writes the guest's frames to a capture file.
        public var pcapURL: URL?

        public init(
            helperURL: URL? = nil,
            logFileURL: URL? = nil,
            socketDirectory: URL? = nil,
            readinessTimeout: TimeInterval = 5,
            debug: Bool = false,
            pcapURL: URL? = nil
        ) {
            self.helperURL = helperURL
            self.logFileURL = logFileURL
            self.socketDirectory = socketDirectory
            self.readinessTimeout = readinessTimeout
            self.debug = debug
            self.pcapURL = pcapURL
        }

        public static let `default` = Options()

        /// `default` with the diagnostic switches folded in from the environment, so a
        /// boot that misbehaves can be captured without new CLI surface:
        /// `VPHONE_NET_DEBUG=1` (frame-level helper log) and
        /// `VPHONE_NET_PCAP=<path>` (capture file of the guest's frames).
        ///
        /// Both stay off unless asked for — the helper is chatty and a capture grows fast.
        public static func fromEnvironment(
            logFileURL: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Options {
            var options = Options(logFileURL: logFileURL)
            options.debug = environment["VPHONE_NET_DEBUG"] == "1"
            if let path = environment["VPHONE_NET_PCAP"], !path.isEmpty {
                options.pcapURL = URL(fileURLWithPath: path)
            }
            return options
        }
    }

    /// `sun_path` on Darwin is 104 bytes including the trailing NUL.
    public static let sunPathLimit = 103

    private let options: Options
    private let stateLock = NSLock()
    private var process: Process?
    private var logHandle: FileHandle?
    private var socketPaths: [String] = []
    private var started = false

    public init(options: Options = .default) {
        self.options = options
    }

    deinit {
        stop()
    }

    // MARK: - Start / stop

    /// Start the helper and return the attachment to hand to a `VZVirtioNetworkDeviceConfiguration`.
    public func start() throws -> VZFileHandleNetworkDeviceAttachment {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !started else { throw VPhoneTunnelNetworkError.alreadyStarted }

        let helper = try Self.resolveHelperOrThrow(explicit: options.helperURL)
        let directory = options.socketDirectory ?? Self.defaultSocketDirectory()
        let token = Self.randomToken()
        let vfkitPath = directory.appendingPathComponent("vp-gv-\(token).sock").path
        let clientPath = directory.appendingPathComponent("vp-cl-\(token).sock").path
        for path in [vfkitPath, clientPath] where !Self.isSocketPathUsable(path) {
            throw VPhoneTunnelNetworkError.socketPathTooLong(path: path, limit: Self.sunPathLimit)
        }

        // A previous run can leave the paths behind; bind() refuses an existing file.
        for path in [vfkitPath, clientPath] { unlink(path) }

        let log = Self.openLog(at: options.logFileURL)
        let child = Process()
        child.executableURL = helper
        child.arguments = Self.helperArguments(
            vfkitSocketPath: vfkitPath, sshPort: Self.pickFreePort(),
            debug: options.debug, pcapPath: options.pcapURL?.path)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log
        child.standardError = log
        do {
            try child.run()
        } catch {
            try? log.close()
            throw VPhoneTunnelNetworkError.helperStartFailed(
                path: helper.path, reason: error.localizedDescription)
        }

        process = child
        logHandle = log
        socketPaths = [vfkitPath, clientPath]

        do {
            try waitUntilSocketReady(vfkitPath, child: child)
            let fd = try Self.connectDatagramSocket(localPath: clientPath, remotePath: vfkitPath)
            let vmFD = dup(fd)
            close(fd)
            guard vmFD >= 0 else {
                throw VPhoneTunnelNetworkError.socketSetupFailed(operation: "dup", errno: errno)
            }
            // VZ takes ownership of the duplicated descriptor: the FileHandle must not
            // close it, and we keep no reference of our own (vfkit does the same).
            let attachment = VZFileHandleNetworkDeviceAttachment(
                fileHandle: FileHandle(fileDescriptor: vmFD, closeOnDealloc: false))
            started = true
            Self.registry.register(self)
            return attachment
        } catch {
            stopLocked()
            throw error
        }
    }

    /// Terminate the helper and remove its sockets. Safe to call more than once.
    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        if let child = process, child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning, Date() < deadline { usleep(20_000) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        for path in socketPaths { unlink(path) }
        socketPaths = []
        started = false
        Self.registry.unregister(self)
    }

    // MARK: - Readiness

    private func waitUntilSocketReady(_ path: String, child: Process) throws {
        let deadline = Date().addingTimeInterval(options.readinessTimeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            if !child.isRunning {
                throw VPhoneTunnelNetworkError.helperExited(
                    status: child.terminationStatus, logTail: Self.logTail(options.logFileURL))
            }
            usleep(20_000)
        }
        throw VPhoneTunnelNetworkError.helperNotReady(
            socketPath: path, seconds: options.readinessTimeout,
            logTail: Self.logTail(options.logFileURL))
    }

    // MARK: - Helper resolution

    /// Search order: explicit path, `VPHONE_GVPROXY`, next to the executable, the bundle's
    /// resources, then `PATH`. Returns the first executable candidate.
    public static func resolveHelper(
        explicit: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent(),
        resourceDirectory: URL? = Bundle.main.resourceURL,
        pathDirectories: [String]? = nil
    ) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }
        if let fromEnv = environment["VPHONE_GVPROXY"], !fromEnv.isEmpty {
            candidates.append(URL(fileURLWithPath: fromEnv))
        }
        if let executableDirectory { candidates.append(executableDirectory.appendingPathComponent(helperName)) }
        if let resourceDirectory { candidates.append(resourceDirectory.appendingPathComponent(helperName)) }

        let path = pathDirectories ?? (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        candidates.append(contentsOf: path.filter { !$0.isEmpty }.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(helperName)
        })

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    public static let helperName = "gvproxy"

    static func resolveHelperOrThrow(explicit: URL?) throws -> URL {
        if let explicit, !FileManager.default.isExecutableFile(atPath: explicit.path) {
            throw VPhoneTunnelNetworkError.helperNotExecutable(path: explicit.path)
        }
        guard let helper = resolveHelper(explicit: explicit) else {
            throw VPhoneTunnelNetworkError.helperNotFound(searched: searchedLocations(explicit: explicit))
        }
        return helper
    }

    private static func searchedLocations(explicit: URL?) -> [String] {
        var out: [String] = []
        if let explicit { out.append(explicit.path) }
        if let fromEnv = ProcessInfo.processInfo.environment["VPHONE_GVPROXY"], !fromEnv.isEmpty {
            out.append(fromEnv)
        }
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            out.append(dir.appendingPathComponent(helperName).path)
        }
        if let res = Bundle.main.resourceURL { out.append(res.appendingPathComponent(helperName).path) }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { !$0.isEmpty }
        if path.isEmpty { out.append("PATH") } else { out.append(contentsOf: path) }
        return out
    }

    /// `VPHONE_NET_SOCKET_DIR` wins; otherwise `/tmp`, which is short enough for `sun_path`
    /// even when `$TMPDIR` is not (`/var/folders/...` routinely overflows the limit).
    public static func defaultSocketDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["VPHONE_NET_SOCKET_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
    }

    /// Arguments for the helper's vfkit transport. Kept separate for testing.
    ///
    /// gvproxy also forwards `127.0.0.1:<ssh-port>` into the guest and defaults to 2222,
    /// so two helpers — or a helper and an unrelated service — collide on it. Callers pass
    /// a free port to keep concurrent VMs startable.
    ///
    /// `debug` adds `-debug` (per-frame helper log) and `pcapPath` adds `-pcap <path>`
    /// (capture of everything the guest puts on the NIC); see `Options.fromEnvironment`.
    public static func helperArguments(
        vfkitSocketPath: String,
        sshPort: Int? = nil,
        debug: Bool = false,
        pcapPath: String? = nil
    ) -> [String] {
        var args = ["-listen-vfkit", "unixgram://" + vfkitSocketPath]
        if let sshPort {
            args.append(contentsOf: ["-ssh-port", "\(sshPort)"])
        }
        if debug {
            args.append("-debug")
        }
        if let pcapPath, !pcapPath.isEmpty {
            args.append(contentsOf: ["-pcap", pcapPath])
        }
        return args
    }

    /// Ask the kernel for a free loopback port (bind to :0, read it back).
    /// Best-effort: a nil result just means the helper keeps its default port.
    public static func pickFreePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        return port > 0 ? port : nil
    }

    public static func isSocketPathUsable(_ path: String) -> Bool {
        path.utf8.count <= sunPathLimit
    }

    // MARK: - Sockets

    /// Connected `SOCK_DGRAM` unix socket: bound to `localPath` so the helper can reply,
    /// then connected to `remotePath` as `VZFileHandleNetworkDeviceAttachment` requires.
    static func connectDatagramSocket(localPath: String, remotePath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw VPhoneTunnelNetworkError.socketSetupFailed(operation: "socket", errno: errno)
        }
        // Apple recommends SO_RCVBUF >= 2x SO_SNDBUF (4x for best throughput).
        var sndbuf = Int32(1 << 20)
        var rcvbuf = Int32(4 << 20)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        do {
            try Self.bindUnix(fd: fd, path: localPath)
            try Self.connectUnix(fd: fd, path: remotePath)
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    private static func bindUnix(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard writeSockaddr(&address, path: path) else {
            throw VPhoneTunnelNetworkError.socketPathTooLong(path: path, limit: sunPathLimit)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            throw VPhoneTunnelNetworkError.socketSetupFailed(operation: "bind(\(path))", errno: errno)
        }
    }

    private static func connectUnix(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard writeSockaddr(&address, path: path) else {
            throw VPhoneTunnelNetworkError.socketPathTooLong(path: path, limit: sunPathLimit)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            throw VPhoneTunnelNetworkError.socketSetupFailed(operation: "connect(\(path))", errno: errno)
        }
    }

    private static func writeSockaddr(_ address: inout sockaddr_un, path: String) -> Bool {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return true
    }

    // MARK: - Small helpers

    private static func randomToken() -> String {
        "\(getpid())-" + String(arc4random(), radix: 16)
    }

    private static func openLog(at url: URL?) -> FileHandle {
        guard let url else {
            return FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.nullDevice
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            return FileHandle.nullDevice
        }
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func logTail(_ url: URL?, limit: Int = 1200) -> String? {
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let text = String(decoding: data.suffix(limit), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static let registry = TunnelNetworkRegistry.shared
}

/// Helpers must not outlive the CLI: `exit()` paths (guest stop, signals) skip `deinit`,
/// so every live instance is registered for an `atexit` sweep.
private final class TunnelNetworkRegistry: @unchecked Sendable {
    static let shared = TunnelNetworkRegistry()

    private final class WeakBox {
        weak var value: VPhoneTunnelNetwork?
        init(_ value: VPhoneTunnelNetwork) { self.value = value }
    }

    private let lock = NSLock()
    private var entries: [WeakBox] = []
    private var hookInstalled = false

    func register(_ network: VPhoneTunnelNetwork) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.value == nil }
        entries.append(WeakBox(network))
        if !hookInstalled {
            hookInstalled = true
            atexit(vphoneTunnelNetworkShutdownHook as @convention(c) () -> Void)
        }
    }

    func unregister(_ network: VPhoneTunnelNetwork) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.value == nil || $0.value === network }
    }

    func stopAll() {
        lock.lock()
        let live = entries.compactMap(\.value)
        entries.removeAll()
        lock.unlock()
        for network in live { network.stop() }
    }
}

/// `atexit` takes a C function pointer, so the sweep lives at file scope.
private func vphoneTunnelNetworkShutdownHook() {
    TunnelNetworkRegistry.shared.stopAll()
}
