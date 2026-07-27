import Foundation

// MARK: - VPhoneMatchResult

public enum VPhoneMatchResult: Equatable, Sendable {
    case matched
    case exited(Int32)
    case timedOut
}

// MARK: - VPhoneManagedProcess

/// A long-lived child process with stdin driving and stdout/stderr
/// regex-waiting — the primitive for DFU background boot, first-boot
/// command injection, and boot log analysis.
public final class VPhoneManagedProcess: @unchecked Sendable {
    /// Thread-safe accumulator for the combined stdout+stderr bytes, plus an
    /// EOF flag so `waitForOutput` can tell "no more output is coming" apart
    /// from "the handler just hasn't run yet". `@unchecked Sendable` because
    /// access is serialized by its lock, matching `VPhoneProcessRunner.DataBox`.
    ///
    /// Raw `Data` is accumulated (not decoded per-chunk) because a multi-byte
    /// UTF-8 character can straddle two `readabilityHandler` reads — decoding
    /// each chunk independently would turn the split character into U+FFFD.
    /// Decoding the whole buffer at match time is always correct.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var eof = false

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func snapshotText() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }

        func markEOF() {
            lock.lock(); defer { lock.unlock() }
            eof = true
        }

        func hasReachedEOF() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return eof
        }
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let outPipe = Pipe()
    private let box = OutputBox()
    private let echo: Bool

    public init(
        _ executable: URL,
        _ args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        echo: Bool = true
    ) {
        self.echo = echo
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }
    }

    /// Spawn the child with a piped stdin and a combined piped stdout/stderr.
    /// The read side is drained by a readability handler that appends decoded
    /// chunks to `box` and (when `echo`) forwards them live to the terminal.
    public func start() throws {
        process.standardInput = stdinPipe
        process.standardOutput = outPipe
        process.standardError = outPipe

        let box = self.box
        let echo = self.echo
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                box.markEOF()
                return
            }
            box.append(chunk)
            if echo {
                FileHandle.standardOutput.write(chunk)
            }
        }

        try process.run()
    }

    /// Poll (~50 ms) until a captured line matches `regex`, the process exits
    /// first, or `timeout` elapses. Matches against the FULL accumulated
    /// buffer each poll (not just newly-arrived text) so a line that lands
    /// between polls is never missed. On exit, waits briefly for the
    /// readability handler to deliver the final EOF chunk and re-checks the
    /// buffer once more before reporting `.exited` — a real match that
    /// arrives in the same instant as process exit still wins.
    public func waitForOutput(matching regex: String, timeout: TimeInterval) -> VPhoneMatchResult {
        let re = try? NSRegularExpression(pattern: regex)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if matches(re, box.snapshotText()) { return .matched }

            if !process.isRunning {
                while !box.hasReachedEOF() && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if matches(re, box.snapshotText()) { return .matched }
                return .exited(process.terminationStatus)
            }

            if Date() >= deadline { return .timedOut }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func matches(_ re: NSRegularExpression?, _ text: String) -> Bool {
        guard let re else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Write `line + "\n"` to the child's stdin.
    public func send(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `interrupt()` (SIGINT), then escalate to an unmaskable `SIGKILL` if
    /// the process is still running after a ~2 s grace period. `SIGKILL` (not
    /// `Process.terminate()`'s `SIGTERM`) is required here: a child that
    /// traps or ignores `SIGTERM` would otherwise survive and hang
    /// `terminate()`/`waitUntilExit()` forever — exactly the kind of
    /// DFU/boot child this class manages.
    public func terminate() {
        guard process.isRunning else { return }
        process.interrupt()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
