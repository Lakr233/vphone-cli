import Foundation

// MARK: - Developer Tunnel

/// Holds the guest's CoreDevice tunnel open while the machine's
/// `holdsDeveloperTunnel` setting is on. CoreDevice pairs a guest as a wired
/// device but brings its tunnel up only while a client holds it, and Xcode
/// and Instruments list a device without one as offline: `xctrace record`
/// waits for it to boot, and neither offers to connect a wired device. A
/// `devicectl device notification observe` session is such a client. It waits
/// for a notification nobody posts, and the tunnel stays up while it runs.
///
/// Call `guestDidConnect()` on every connect to vphoned, when CoreDevice can
/// reach the guest. A session that ends while the setting is on is started
/// again, after a delay that grows while sessions keep ending at once, as
/// they do while the guest reboots, so a failing devicectl does not spin.
@MainActor
final class VPhoneDeveloperTunnel {
    static let devicectlURL = URL(fileURLWithPath: "/usr/bin/devicectl")
    /// devicectl requires the session timeout below the command's timeout.
    /// It also bounds a session left behind by a vphone-vm that was killed.
    private static let sessionSeconds = 3500
    private static let timeoutSeconds = 3600
    /// A session that lasted this long ran its course and is replaced at once.
    private static let healthyRun: Duration = .seconds(60)
    private static let firstRetryDelay: Duration = .seconds(5)
    private static let maxRetryDelay: Duration = .seconds(60)

    private let udid: String
    /// The machine's setting. Changing it starts or ends the session at once.
    var isEnabled: Bool {
        didSet { update() }
    }

    /// Kept through a dropped vphoned connection: the session outlives it,
    /// and a guest that rebooted fails the session and is retried.
    private var guestStarted = false
    private var session: Process?
    private var sessionStart: ContinuousClock.Instant?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Duration = .zero
    private var reportedMissingTool = false

    init(udid: String, isEnabled: Bool) {
        self.udid = udid
        self.isEnabled = isEnabled
        _ = registerExitCleanup
    }

    func guestDidConnect() {
        guestStarted = true
        // A guest back from a reboot need not wait out the retry delay.
        if session == nil {
            retryTask?.cancel()
            retryTask = nil
        }
        update()
    }

    /// Ends the session for good: the virtual machine is stopping.
    func stop() {
        guestStarted = false
        update()
    }

    // MARK: - Session

    private func update() {
        guard isEnabled, guestStarted else {
            end()
            return
        }
        guard session == nil, retryTask == nil else { return }
        launch()
    }

    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: Self.devicectlURL.path) else {
            if !reportedMissingTool {
                reportedMissingTool = true
                print("[developer-tunnel] \(Self.devicectlURL.path) not found; the guest's CoreDevice tunnel is not held")
            }
            return
        }
        let process = Process()
        process.executableURL = Self.devicectlURL
        process.arguments = [
            "device", "notification", "observe",
            "--device", udid,
            "--name", "com.vphone.developer-tunnel",
            "--session-timeout", String(Self.sessionSeconds),
            "--timeout", String(Self.timeoutSeconds),
            "--quiet",
        ]
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.sessionDidEnd(process, status: status) }
        }
        do {
            try process.run()
        } catch {
            print("[developer-tunnel] cannot start devicectl: \(error.localizedDescription)")
            scheduleRetry(ranFor: .zero)
            return
        }
        session = process
        sessionStart = .now
        developerTunnelSessionPID = process.processIdentifier
        print("[developer-tunnel] holding the CoreDevice tunnel to \(udid)")
    }

    private func sessionDidEnd(_ process: Process, status: Int32) {
        guard session === process else { return }
        session = nil
        developerTunnelSessionPID = 0
        let ranFor = sessionStart.map { ContinuousClock.now - $0 } ?? .zero
        print("[developer-tunnel] devicectl exited with status \(status)")
        scheduleRetry(ranFor: ranFor)
    }

    private func scheduleRetry(ranFor: Duration) {
        retryDelay = ranFor >= Self.healthyRun
            ? .zero
            : min(max(retryDelay * 2, Self.firstRetryDelay), Self.maxRetryDelay)
        if retryDelay > .zero {
            print("[developer-tunnel] trying again in \(Int(retryDelay.components.seconds)) s")
        }
        retryTask = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            update()
        }
    }

    private func end() {
        retryTask?.cancel()
        retryTask = nil
        retryDelay = .zero
        guard let session else { return }
        self.session = nil
        developerTunnelSessionPID = 0
        session.terminate()
        print("[developer-tunnel] released the CoreDevice tunnel")
    }
}

// MARK: - Exit Cleanup

/// The running session's pid. `guestDidStop` ends vphone-vm with `exit()`,
/// which skips `applicationWillTerminate` but runs atexit handlers.
private nonisolated(unsafe) var developerTunnelSessionPID: pid_t = 0

private let registerExitCleanup: Void = {
    atexit {
        if developerTunnelSessionPID > 0 {
            kill(developerTunnelSessionPID, SIGTERM)
        }
    }
}()
