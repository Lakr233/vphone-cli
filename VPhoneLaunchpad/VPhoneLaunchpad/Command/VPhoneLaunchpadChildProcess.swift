import Foundation

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
nonisolated final class VPhoneLaunchpadChildProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var hasExited = false
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        logFile: URL? = nil,
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
            let writer = try FileHandle(forWritingTo: logFile)
            process.standardOutput = writer
            process.standardError = writer
            process.terminationHandler = { [self] _ in
                lock.withLock { hasExited = true }
            }
            try process.run()
            try writer.close()
            let reader = try FileHandle(forReadingFrom: logFile)
            Thread.detachNewThread { [self] in
                tail(reader, onLine)
            }
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
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
        if process.isRunning {
            process.interrupt()
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
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
        finish(process.terminationStatus)
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
