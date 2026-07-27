import Foundation

// MARK: - VPhoneProcessResult

public struct VPhoneProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

// MARK: - VPhoneProcessRunner

public enum VPhoneProcessRunner {
    /// Thread-safe accumulator for a pipe's bytes. `@unchecked Sendable`
    /// because access is serialized by its lock, satisfying the readability
    /// handler's `@Sendable` requirement under Swift 6 strict concurrency.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Run `executable args` to completion, capturing stdout/stderr.
    /// Throws only if the process cannot be launched; a nonzero exit is
    /// returned in the result, not thrown.
    ///
    /// stdout and stderr are drained CONCURRENTLY via readability handlers —
    /// a sequential "read stdout fully, then stderr" drain deadlocks when a
    /// child fills one pipe's ~64 KB buffer while still writing the other.
    public static func runCapturing(
        _ executable: URL,
        _ args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil
    ) throws -> VPhoneProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; group.leave() }
            else { outBox.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; group.leave() }
            else { errBox.append(chunk) }
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        return VPhoneProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.take(), as: UTF8.self),
            stderr: String(decoding: errBox.take(), as: UTF8.self))
    }

    /// Run `executable args`, inheriting the parent's stdout/stderr so output
    /// streams live to the terminal (for long-running tools: downloads, restore,
    /// CFW install). Returns the child's exit status; throws only on spawn failure.
    /// When `echo` is false, the child's stdout/stderr are redirected to the null
    /// device so nothing reaches the terminal; the exit status is still returned.
    public static func runStreaming(
        _ executable: URL,
        _ args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        echo: Bool = true
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }

        if !echo {
            let devNull = FileHandle.nullDevice
            process.standardOutput = devNull
            process.standardError = devNull
        }
        // When echo is true: no pipe redirection → child inherits our stdio (live streaming).

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
