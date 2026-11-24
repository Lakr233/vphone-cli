import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

/// The detached spawn, run against `/bin/sh` children and a temp log.
struct DetachedProcessTests {
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    private static func makeLog() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).log")
        try Data().write(to: url)
        return url
    }

    private static func spawn(_ script: String, log: URL, disclaim: Bool = false) throws -> pid_t {
        try VPhoneDetachedProcess.spawn(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            logFile: log,
            disclaim: disclaim,
        )
    }

    private static func waitForStatus(_ pid: pid_t) throws -> Int32 {
        for _ in 0 ..< 200 {
            if let status = VPhoneDetachedProcess.exitStatus(pid: pid) { return status }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TestError("child \(pid) did not exit")
    }

    private struct TestError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// The pid macOS holds responsible for `pid`. Fails the test when the
    /// private symbol does not resolve or the answer is not a pid.
    private static func responsiblePID(of pid: pid_t) throws -> pid_t {
        let symbol = try #require(dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid"))
        let answer = unsafeBitCast(symbol, to: ResponsiblePID.self)(pid)
        try #require(answer > 0)
        return answer
    }

    @Test(arguments: [true, false])
    func `spawn logs both streams, reports exit 3 and starts a new session`(disclaim: Bool) throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try Self.spawn("echo out; echo err >&2; exit 3", log: log, disclaim: disclaim)
        let status = try Self.waitForStatus(pid)
        #expect(VPhoneDetachedProcess.describe(status: status) == "exit 3")
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("out\n"))
        #expect(text.contains("err\n"))
        #expect(getsid(pid) != getsid(0))
    }

    @Test
    func `responsible pid is the child with disclaim and ours without`() throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let disclaimed = try Self.spawn("sleep 5", log: log, disclaim: true)
        let plain = try Self.spawn("sleep 5", log: log, disclaim: false)
        defer {
            kill(disclaimed, SIGKILL)
            kill(plain, SIGKILL)
            _ = try? Self.waitForStatus(disclaimed)
            _ = try? Self.waitForStatus(plain)
        }
        #expect(try Self.responsiblePID(of: disclaimed) == disclaimed)
        #expect(try Self.responsiblePID(of: plain) == Self.responsiblePID(of: getpid()))
    }

    @Test
    func `exit and signal are told apart`() throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let killed = try Self.waitForStatus(Self.spawn("kill -9 $$", log: log))
        #expect(VPhoneDetachedProcess.describe(status: killed) == "signal 9")
        let exited = try Self.waitForStatus(Self.spawn("exit 3", log: log))
        #expect(VPhoneDetachedProcess.describe(status: exited) == "exit 3")
    }

    @Test
    func `exitStatus on a non-child gives an errno status`() {
        let status = VPhoneDetachedProcess.exitStatus(pid: 1)
        #expect(status.map { VPhoneDetachedProcess.describe(status: $0) } == "unknown (errno 10)")
    }

    @Test
    func `a reaped pid keeps answering and the wait sees it as exited`() throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try Self.spawn("exit 0", log: log)
        _ = try Self.waitForStatus(pid)
        #expect(VPhoneDetachedProcess.exitStatus(pid: pid) != nil)
        let outcome = VPhoneGuestWait.run(
            budget: .seconds(5),
            pollInterval: 0.01,
            ping: { false },
            exited: { VPhoneDetachedProcess.exitStatus(pid: pid) != nil },
            panicked: { false },
            cancelled: { false },
            progress: { _ in },
        )
        #expect(outcome == .exited)
    }

    @Test
    func `a second spawn appends to the log`() throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        _ = try Self.waitForStatus(Self.spawn("echo first", log: log))
        _ = try Self.waitForStatus(Self.spawn("echo second", log: log))
        #expect(try String(contentsOf: log, encoding: .utf8) == "first\nsecond\n")
    }

    @Test
    func `spawn throws for a missing executable and an unwritable log, leaving no child`() throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let missingDirectory = URL(fileURLWithPath: "/nonexistent-dir/x.log")
        #expect(throws: (any Error).self) {
            try Self.spawn("touch /tmp/vphone-detached-marker-\(getpid())", log: missingDirectory)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/vphone-detached-marker-\(getpid())"))
    }

    private static func spawnError(executable: String, log: URL) -> VPhoneDetachedProcess.SpawnError? {
        do {
            _ = try VPhoneDetachedProcess.spawn(
                executable: URL(fileURLWithPath: executable), arguments: [], logFile: log, disclaim: false,
            )
        } catch {
            return error as? VPhoneDetachedProcess.SpawnError
        }
        return nil
    }

    @Test
    func `a missing launcher names the launcher, an unwritable log names the log`() throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let missing = "/nonexistent/vphone-test"
        let launcher = try #require(Self.spawnError(executable: missing, log: log))
        #expect(launcher.localizedDescription == "No such file or directory (\(missing))")

        let noLog = "/nonexistent-dir/x.log"
        let logError = try #require(Self.spawnError(executable: "/bin/sh", log: URL(fileURLWithPath: noLog)))
        #expect(logError.localizedDescription == "No such file or directory (\(noLog))")
    }

    @Test
    func `a failure that concerns neither the launcher nor the log names no path`() throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        // A directory is executable (X_OK) but cannot be spawned, and the log is writable.
        let error = try #require(Self.spawnError(executable: "/tmp", log: log))
        #expect(error.path == nil)
    }
}
