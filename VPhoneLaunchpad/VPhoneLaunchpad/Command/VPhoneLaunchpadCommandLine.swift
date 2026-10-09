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

    /// `error` as an action's failure: itself when it already is one, else
    /// "Unable to Complete Action" with the error's text under it.
    init(actionFailure error: any Error) {
        self = error as? VPhoneLaunchpadError
            ?? VPhoneLaunchpadError(String(localized: "Unable to Complete Action"), detail: error.localizedDescription)
    }

    var errorDescription: String? {
        message
    }

    var failureReason: String? {
        detail
    }

    /// Any error as one string: the message, and under it the output that says
    /// why. For a view that shows a single line of text rather than an alert
    /// with its own detail area.
    static func message(for error: any Error) -> String {
        [error.localizedDescription, (error as? VPhoneLaunchpadError)?.detail]
            .compactMap(\.self)
            .joined(separator: "\n")
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

    /// The JSON document in the output.
    ///
    /// stderr is merged into the same stream, so warnings can precede it, and a
    /// pretty-printed document spans many lines — `fw patches --json` prints
    /// one. Only its opening brace sits at column zero, so the last line that
    /// opens a document starts it, and it runs to the end of the output.
    var jsonData: Data? {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("[") || $0.hasPrefix("{") }) else {
            return nil
        }
        return Data(lines[start...].joined(separator: "\n").utf8)
    }
}

// MARK: - History

/// Every command Launchpad runs, shown so it can be copied into a terminal.
@MainActor
@Observable
final class VPhoneLaunchpadCommandHistory {
    nonisolated struct Entry: Identifiable, Sendable {
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

/// Runs one installed bundle's `vphone-cli` by absolute path. Nothing here goes
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

    /// The fraction a `progress <done> <total>` line reports, or nil for any
    /// other line.
    nonisolated static func progress(in line: String) -> Double? {
        let fields = line.split(separator: " ")
        guard fields.count == 3, fields[0] == "progress",
              let done = Double(fields[1]), let total = Double(fields[2]), total > 0
        else { return nil }
        return min(1, done / total)
    }

    /// Runs to completion. Cancelling the calling task sends SIGINT.
    /// `onLine` and `onProgress` run on the reader thread, never on the main
    /// actor. Progress lines go only to `onProgress`, never to the output.
    func run(
        _ arguments: [String],
        recordInHistory: Bool = true,
        onLine: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> VPhoneLaunchpadCommandResult {
        let entry = recordInHistory ? history.record(Self.display(arguments)) : nil
        let collector = VPhoneLaunchpadLineCollector()
        let child = try VPhoneLaunchpadChildProcess(executable: executable, arguments: arguments) { line in
            if let fraction = Self.progress(in: line) {
                onProgress?(fraction)
                return
            }
            collector.append(line)
            onLine?(line)
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
        onLine: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> VPhoneLaunchpadCommandResult {
        let result = try await run(arguments, onLine: onLine, onProgress: onProgress)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw VPhoneLaunchpadError(
                String(localized: "\(Self.display(arguments)) failed. Check the output and try again."),
                detail: result.tail,
            )
        }
        return result
    }

    /// Starts a long-running command such as `vm launch` and returns at once.
    /// Its output goes to `logFile`, so it outlives Launchpad. `onLine` runs on
    /// the reader thread: a guest console can print faster than the main
    /// thread should wake for.
    func start(
        _ arguments: [String],
        logFile: URL,
        onLine: @escaping @Sendable (String) -> Void,
    ) throws -> VPhoneLaunchpadChildProcess {
        let entry = history.record(Self.display(arguments))
        let child = try VPhoneLaunchpadChildProcess(
            executable: executable,
            arguments: arguments,
            logFile: logFile,
            onLine: onLine,
        )
        let history = history
        Task {
            let status = await child.wait()
            history.finish(entry, status: status)
        }
        return child
    }
}

/// Collects output lines from the reader thread, keeping the most recent.
final nonisolated class VPhoneLaunchpadLineCollector: @unchecked Sendable {
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
