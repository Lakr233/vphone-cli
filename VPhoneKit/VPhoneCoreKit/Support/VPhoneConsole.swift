import Foundation

public enum VPhoneConsoleKind: Sendable { case plain, step, done, note, warning, failure }
public enum VPhoneConsoleStream: Sendable { case output, error }

/// Reporting channel for long-running commands. Plain renderer only: bytes are identical to the
/// former `print` calls, written on the calling thread (the restore core swaps stdio's stdout
/// process-wide, so handing output to another queue would misroute it).
public final class VPhoneConsole: @unchecked Sendable {
    public static let shared = VPhoneConsole()

    private let lock = NSRecursiveLock()
    private let write: @Sendable (String, VPhoneConsoleStream) -> Void
    private var log: FileHandle?

    init(write: @escaping @Sendable (String, VPhoneConsoleStream) -> Void = VPhoneConsole.defaultWrite) {
        self.write = write
    }

    private static let defaultWrite: @Sendable (String, VPhoneConsoleStream) -> Void = { text, stream in
        switch stream {
        case .output: Swift.print(text, terminator: "")
        case .error: FileHandle.standardError.write(Data(text.utf8))
        }
    }

    // MARK: - Reporting

    /// Plain mode: "\n=== name ===\n" on standard output.
    public func phase(_ name: String) {
        emit("\n=== \(name) ===\n", .output)
    }

    /// Plain mode: text + terminator verbatim; `kind` does not change the bytes.
    public func line(_ text: String, _ kind: VPhoneConsoleKind = .plain,
                     to stream: VPhoneConsoleStream = .output, terminator: String = "\n") {
        emit(text + terminator, stream)
    }

    /// Screen-only; plain mode prints nothing.
    public func activity(_ name: String, fraction: Double? = nil) {}
    public func activity(_ name: String, done: Int, of total: Int) {}

    /// Appends every plain-mode byte (both streams) to this file too. nil turns it off.
    public func setLog(_ url: URL?) throws {
        try lock.withLock {
            try? log?.close()
            log = nil
            guard let url else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            log = handle
        }
    }

    // MARK: - Private

    private func emit(_ text: String, _ stream: VPhoneConsoleStream) {
        lock.withLock {
            write(text, stream)
            try? log?.write(contentsOf: Data(text.utf8))
        }
    }
}
