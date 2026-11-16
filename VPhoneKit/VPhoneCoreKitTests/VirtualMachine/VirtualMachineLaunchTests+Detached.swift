import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

// MARK: - Detached start

extension VirtualMachineLaunchTests {
    private typealias Started = Result<VPhoneVirtualMachineLaunch.Detached, any Error>

    private func startDetached(_ guest: FakeGuestVM, readyTimeout: TimeInterval = 10) -> Started {
        Result { try guest.launch().startDetached(logURL: guest.logURL, readyTimeout: readyTimeout) }
    }

    private func launchError(_ result: Started) -> VPhoneVirtualMachineLaunchError? {
        if case let .failure(error) = result { return error as? VPhoneVirtualMachineLaunchError }
        return nil
    }

    /// No process of this guest's folder is left.
    private func expectNoGuestProcess(_ guest: FakeGuestVM) throws {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", guest.executable.path]
        pgrep.standardOutput = FileHandle.nullDevice
        try pgrep.run()
        pgrep.waitUntilExit()
        #expect(pgrep.terminationStatus == 1)
    }

    @Test("without a readyTimeout the start waits up to 120 seconds, and a guest ready after 1.5 s is waited for")
    func defaultReadyTimeout() throws {
        #expect(VPhoneVirtualMachineLaunch.defaultReadyTimeout == 120)
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, waitFor: guest.argumentsFile)
        defer { socket.stop(); guest.cleanUp() }
        try guest.writeScript("""
        #!/bin/sh
        /bin/sleep 1.5
        echo started > '\(guest.argumentsFile.path)'
        while :; do /bin/sleep 0.1; done
        """)
        let detached = try Result { try guest.launch().startDetached(logURL: guest.logURL) }.get()
        defer { kill(detached.pid, SIGKILL); var s: Int32 = 0; waitpid(detached.pid, &s, 0) }
        #expect(detached.pid > 0)
    }

    @Test("detached start is ready when the socket answers")
    func detachedReady() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, waitFor: guest.argumentsFile)
        defer { socket.stop(); guest.cleanUp() }
        try guest.writeScript("""
        #!/bin/sh
        echo hello-log
        read -r x; echo "read-status=$?"
        echo started > '\(guest.argumentsFile.path)'
        while :; do /bin/sleep 0.1; done
        """)
        let detached = try startDetached(guest).get()
        defer { kill(detached.pid, SIGKILL); var s: Int32 = 0; waitpid(detached.pid, &s, 0) }
        #expect(detached.logURL == guest.logURL)
        #expect(detached.socketPath == guest.bundle.url.appendingPathComponent("vphone.sock").path)
        #expect(getsid(detached.pid) == detached.pid)
        #expect(getsid(detached.pid) != getsid(0))
        let log = try String(contentsOf: guest.logURL, encoding: .utf8)
        #expect(log.contains("hello-log"))
        #expect(log.contains("read-status=1"))
        var info = stat()
        #expect(stat(guest.logURL.path, &info) == 0)
        #expect(info.st_mode & 0o666 == 0o666)
    }

    @Test("a script that exits 3 before any answer throws exitedBeforeReady with the log tail")
    func exitedBeforeReady() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try guest.writeScript("#!/bin/sh\necho boom\nexit 3")
        let result = startDetached(guest)
        guard case let .exitedBeforeReady(status, tail)? = launchError(result) else {
            Issue.record("expected exitedBeforeReady, got \(result)")
            return
        }
        #expect(status == 3)
        #expect(tail.contains("boom"))
        try expectNoGuestProcess(guest)
    }

    @Test("a script killed by SIGKILL reports 128 plus the signal")
    func killedBySignal() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try guest.writeScript("#!/bin/sh\necho dying\nkill -9 $$")
        guard case let .exitedBeforeReady(status, _)? = launchError(startDetached(guest)) else {
            Issue.record("expected exitedBeforeReady")
            return
        }
        #expect(status == 137)
    }

    @Test("a listener that answers while the script is already gone is not ready")
    func answeredButExited() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, waitFor: guest.argumentsFile)
        defer { socket.stop(); guest.cleanUp() }
        try guest.writeScript("#!/bin/sh\necho gone\necho started > '\(guest.argumentsFile.path)'\nexit 3")
        guard case let .exitedBeforeReady(status, _)? = launchError(startDetached(guest)) else {
            Issue.record("expected exitedBeforeReady")
            return
        }
        #expect(status == 3)
    }

    @Test("no answer within readyTimeout kills and reaps the process")
    func notReady() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try guest.writeScript("""
        #!/bin/sh
        trap '' TERM
        echo waiting
        echo "$$" > '\(guest.pidFile.path)'
        while :; do /bin/sleep 0.1; done
        """)
        let start = Date()
        let result = startDetached(guest, readyTimeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        guard case let .notReady(timeout, tail)? = launchError(result) else {
            Issue.record("expected notReady, got \(result)")
            return
        }
        #expect(timeout == 1)
        #expect(tail.contains("waiting"))
        #expect(elapsed < 2.5)
        let text = try String(contentsOf: guest.pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        try expectNoGuestProcess(guest)
    }

    @Test("a listener that accepts and stays silent times out in under 2.5 s")
    func silentListener() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, mode: .silent, waitFor: guest.argumentsFile)
        defer { socket.stop(); guest.cleanUp() }
        try guest.writeScript("""
        #!/bin/sh
        echo started > '\(guest.argumentsFile.path)'
        while :; do /bin/sleep 0.1; done
        """)
        let start = Date()
        let result = startDetached(guest, readyTimeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        guard case .notReady? = launchError(result) else {
            Issue.record("expected notReady, got \(result)")
            return
        }
        #expect(elapsed < 2.5)
        try expectNoGuestProcess(guest)
    }

    @Test("a machine that is already running is refused before anything is spawned")
    func alreadyRunning() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle)
        defer { socket.stop(); guest.cleanUp() }
        let disk = guest.bundle.url.appendingPathComponent("Disk.img")
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", disk.path]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()
        defer { tail.terminate(); tail.waitUntilExit() }
        for _ in 0 ..< 50 where VPhoneBundleActivity.processesHolding([disk]).isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for _ in 0 ..< 50 where !FileManager.default.fileExists(atPath: socket.path) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let result = startDetached(guest)
        guard case let .failure(error) = result, case VPhoneBundleActivityError.running = error else {
            Issue.record("expected running, got \(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: guest.argumentsFile.path))
        #expect(!FileManager.default.fileExists(atPath: guest.logURL.path))
        try expectNoGuestProcess(guest)
    }

    @Test("spawn failures carry the errno and leave no process")
    func spawnFailures() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }

        let badLog = guest.root.appendingPathComponent("nodir/log.txt")
        let first = Result { try guest.launch().startDetached(logURL: badLog, readyTimeout: 1) }
        guard case let .spawnFailed(code, path)? = launchError(first) else {
            Issue.record("expected spawnFailed, got \(first)")
            return
        }
        #expect(code == ENOENT)
        #expect(path == badLog.path)
        try expectNoGuestProcess(guest)

        let plain = guest.root.appendingPathComponent("plain-file")
        try Data("x".utf8).write(to: plain)
        let launch = VPhoneVirtualMachineLaunch(
            bundle: guest.bundle,
            planner: VPhoneGuestLaunchPlanner(unchecked: plain),
            layout: guest.layout,
            options: .init(),
            restoredCustomisedSystem: false,
        )
        let second = Result { try launch.startDetached(logURL: guest.logURL, readyTimeout: 1) }
        guard case let .spawnFailed(code2, _)? = launchError(second) else {
            Issue.record("expected spawnFailed, got \(second)")
            return
        }
        #expect(code2 == EACCES)
        try expectNoGuestProcess(guest)
    }

    @Test("the spawned guest inherits only stdin, stdout and stderr, not a descriptor the host holds open")
    func guestInheritsNoExtraDescriptor() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, waitFor: guest.argumentsFile)
        defer { socket.stop(); guest.cleanUp() }
        // A host file left open without close-on-exec, as a parallel caller's
        // in-use probe or lock would be.
        let held = open(guest.bundle.url.path, O_RDONLY)
        try #require(held >= 0)
        defer { close(held) }
        _ = fcntl(held, F_SETFD, fcntl(held, F_GETFD) & ~FD_CLOEXEC)
        try guest.writeScript("""
        #!/bin/sh
        if [ -e /dev/fd/\(held) ]; then echo "fd-inherited"; else echo "fd-closed"; fi
        if [ -e /dev/fd/2 ]; then echo "stderr-open"; fi
        echo started > '\(guest.argumentsFile.path)'
        while :; do /bin/sleep 0.1; done
        """)
        let detached = try startDetached(guest).get()
        defer { kill(detached.pid, SIGKILL); var s: Int32 = 0; waitpid(detached.pid, &s, 0) }
        let log = try String(contentsOf: guest.logURL, encoding: .utf8)
        #expect(log.contains("fd-closed"))
        #expect(!log.contains("fd-inherited"))
        #expect(log.contains("stderr-open"))
    }

    @Test("the log tail keeps at most 20 lines and 16 KiB")
    func logTailBounds() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try guest.writeScript("#!/bin/sh\nexit 3")

        let numbered = (1 ... 30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try Data(numbered.utf8).write(to: guest.logURL)
        guard case let .exitedBeforeReady(_, tail)? = launchError(startDetached(guest)) else {
            Issue.record("expected exitedBeforeReady")
            return
        }
        let lines = tail.split(separator: "\n")
        #expect(lines.count == 20)
        #expect(lines.last == "line 30")
        #expect(lines.first == "line 11")

        try Data(String(repeating: "x", count: 1 << 20).utf8).write(to: guest.logURL)
        guard case let .exitedBeforeReady(_, big)? = launchError(startDetached(guest)) else {
            Issue.record("expected exitedBeforeReady")
            return
        }
        #expect(big.utf8.count <= 16 * 1024)
        #expect(big.split(separator: "\n").count <= 20)
        #expect(!big.isEmpty)
    }

    @Test("each launch error describes the cause and the next step")
    func descriptions() {
        let spawn = VPhoneVirtualMachineLaunchError.spawnFailed(errno: ENOENT, logPath: "/x/log.txt").description
        #expect(spawn.contains(String(cString: strerror(ENOENT))))
        #expect(spawn.contains("/x/log.txt"))
        #expect(spawn.contains("Check that the guest binary"))

        let exited = VPhoneVirtualMachineLaunchError.exitedBeforeReady(status: 3, logTail: "last line").description
        #expect(exited.contains("status 3"))
        #expect(exited.contains("last line"))
        #expect(exited.contains("launch again"))

        let notReady = VPhoneVirtualMachineLaunchError.notReady(timeout: 120, logTail: "tail text").description
        #expect(notReady.contains("120 seconds"))
        #expect(notReady.contains("tail text"))
        #expect(notReady.contains("raise the ready timeout"))
    }
}
