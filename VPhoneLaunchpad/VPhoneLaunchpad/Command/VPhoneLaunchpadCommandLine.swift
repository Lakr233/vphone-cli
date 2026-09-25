import Foundation
import Observation

// MARK: - Errors

nonisolated struct VPhoneLaunchpadError: LocalizedError {
    let message: String
    var detail: String?

    init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    var errorDescription: String? {
        message
    }

    var failureReason: String? {
        detail
    }
}

// MARK: - Result

nonisolated struct VPhoneLaunchpadCommandResult: Sendable {
    let status: Int32
    let lines: [String]

    var succeeded: Bool {
        status == 0
    }

    /// The last few lines, which is where `vphone-cli` reports what failed.
    var tail: String {
        lines.suffix(12).joined(separator: "\n")
    }

    /// The last line that looks like a JSON document. stderr is merged into
    /// the same stream, so warnings can precede it.
    var jsonData: Data? {
        lines.last { $0.hasPrefix("[") || $0.hasPrefix("{") }.map { Data($0.utf8) }
    }
}

// MARK: - History

/// Every command Launchpad runs, shown so it can be copied into a terminal.
@MainActor
@Observable
final class VPhoneLaunchpadCommandHistory {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        var status: Int32?
    }

    private(set) var entries: [Entry] = []

    func record(_ text: String) -> UUID {
        let entry = Entry(text: text)
        entries.append(entry)
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
        return entry.id
    }

    func finish(_ id: UUID, status: Int32) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].status = status
        }
    }
}

// MARK: - vphone-cli

/// Runs the active bundle's `vphone-cli` by absolute path. Nothing here goes
/// through a shell or `$PATH`.
@MainActor
struct VPhoneLaunchpadCommandLine {
    let executable: URL
    let history: VPhoneLaunchpadCommandHistory

    static func display(_ arguments: [String]) -> String {
        (["vphone-cli"] + arguments.map(quoted)).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        let plain = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=,@+".contains($0) }
        return plain && !argument.isEmpty ? argument : "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Runs to completion. Cancelling the calling task sends SIGINT.
    func run(
        _ arguments: [String],
        recordInHistory: Bool = true,
        onLine: (@MainActor @Sendable (String) -> Void)? = nil,
    ) async throws -> VPhoneLaunchpadCommandResult {
        let entry = recordInHistory ? history.record(Self.display(arguments)) : nil
        let collector = VPhoneLaunchpadLineCollector()
        let child = try VPhoneLaunchpadChildProcess(executable: executable, arguments: arguments) { line in
            collector.append(line)
            if let onLine {
                DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
            }
        }
        let status = await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.interrupt()
        }
        if let entry {
            history.finish(entry, status: status)
        }
        return VPhoneLaunchpadCommandResult(status: status, lines: collector.lines)
    }

    /// Runs to completion and throws with the output tail on a non-zero exit.
    @discardableResult
    func runChecked(
        _ arguments: [String],
        onLine: (@MainActor @Sendable (String) -> Void)? = nil,
    ) async throws -> VPhoneLaunchpadCommandResult {
        let result = try await run(arguments, onLine: onLine)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw VPhoneLaunchpadError(
                String(localized: "\(Self.display(arguments)) exited with status \(result.status)."),
                detail: result.tail,
            )
        }
        return result
    }

    /// Starts a long-running command such as `vm launch` and returns at once.
    /// Its output goes to `logFile`, so it outlives Launchpad.
    func start(
        _ arguments: [String],
        logFile: URL,
        onLine: @escaping @MainActor @Sendable (String) -> Void,
    ) throws -> VPhoneLaunchpadChildProcess {
        let entry = history.record(Self.display(arguments))
        let child = try VPhoneLaunchpadChildProcess(
            executable: executable,
            arguments: arguments,
            logFile: logFile,
        ) { line in
            DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
        }
        let history = history
        Task {
            let status = await child.wait()
            history.finish(entry, status: status)
        }
        return child
    }
}

/// Collects output lines from the reader thread, keeping the most recent.
nonisolated final class VPhoneLaunchpadLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock {
            storage.append(line)
            if storage.count > 4000 {
                storage.removeFirst(storage.count - 4000)
            }
        }
    }

    var lines: [String] {
        lock.withLock { storage }
    }
}
