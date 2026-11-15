import Darwin
import Foundation

public enum VPhoneConsoleKind: Sendable { case plain, step, done, note, warning, failure }
public enum VPhoneConsoleStream: Sendable { case output, error }

/// The terminal descriptor the signal handler shows the cursor on; -1 when no screen is up.
nonisolated(unsafe) private var screenSignalTerminal: Int32 = -1

/// Reporting channel for long-running commands. Plain mode: bytes are identical to the
/// former `print` calls, written on the calling thread (the restore core swaps stdio's stdout
/// process-wide, so handing output to another queue would misroute it). Screen mode: the
/// same bytes go to the log file only, and a redrawn frame goes to the terminal with write(2).
public final class VPhoneConsole: @unchecked Sendable {
    public static let shared = VPhoneConsole()

    private let lock = NSRecursiveLock()
    private let write: @Sendable (String, VPhoneConsoleStream) -> Void
    private var log: FileHandle?

    private var screen: VPhoneConsoleScreen?
    private var frameOut: (@Sendable (String) -> Void)?
    private var terminal: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var drawnRows = 0
    private var savedActions: [(Int32, sigaction)] = []

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
        lock.withLock {
            screen?.phase(name, at: Self.now())
            emit("\n=== \(name) ===\n", .output)
        }
    }

    /// Plain mode: text + terminator verbatim; `kind` does not change the bytes.
    public func line(_ text: String, _ kind: VPhoneConsoleKind = .plain,
                     to stream: VPhoneConsoleStream = .output, terminator: String = "\n") {
        lock.withLock {
            // One screen row per text line; a newline inside a row would break the redraw.
            for piece in screen == nil ? [] : text.split(separator: "\n") { screen?.line(String(piece), kind) }
            emit(text + terminator, stream)
        }
    }

    /// Screen-only; plain mode prints nothing.
    public func activity(_ name: String, fraction: Double? = nil) {
        lock.withLock { screen?.activity(name, fraction: fraction) }
    }

    public func activity(_ name: String, done: Int, of total: Int) {
        lock.withLock { screen?.activity(name, done: done, of: total) }
    }

    /// Appends every plain-mode byte (both streams) to this file too. nil turns it off.
    public func setLog(_ url: URL?) throws {
        try lock.withLock {
            try? log?.close()
            log = nil
            guard let url else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            log = handle
        }
    }

    // MARK: - Screen

    public static func usesScreen(isTerminal: Bool, verbosity: VPhoneVerbosity) -> Bool {
        isTerminal && verbosity == .quiet
    }

    public var isScreenActive: Bool {
        lock.withLock { screen != nil }
    }

    /// Hides the cursor and redraws every 0.1 s. Until `finishScreen`, phase/line/activity
    /// update the screen and the log file instead of writing to the terminal.
    public func startScreen(title: String, pendingPhases: [String]) {
        startScreen(title: title, pendingPhases: pendingPhases, frame: nil)
    }

    /// `frame` receives the frame text (tests); nil writes it to a dup of standard output.
    func startScreen(title: String, pendingPhases: [String], frame: (@Sendable (String) -> Void)?) {
        lock.withLock {
            guard screen == nil else { return }
            let fd = dup(STDOUT_FILENO)
            guard fd >= 0 else { return } // no terminal to draw on: stay in plain mode
            terminal = fd
            frameOut = frame ?? { Self.writeAll($0, to: fd) }
            screen = VPhoneConsoleScreen(title: title, pendingPhases: pendingPhases, startedAt: Self.now())
            drawnRows = 0
            installSignalHandlers(terminal: fd)
            frameOut?("\u{1B}[?25l")
            draw()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "VPhoneConsole.screen"))
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                lock.withLock { self.draw() }
            }
            timer.resume()
            self.timer = timer
        }
    }

    /// Draws the final frame and shows the cursor, leaving it at the start of a line below.
    /// With an error the active phase is marked failed and the last plain lines follow the frame.
    /// Safe to call when no screen is up.
    public func finishScreen(error: (any Error)?) {
        lock.withLock {
            guard screen != nil, let frameOut else { return }
            timer?.cancel()
            timer = nil
            screen?.finish(failed: error != nil, at: Self.now())
            draw()
            if error != nil, let lines = screen?.lastLines {
                frameOut(lines.map { $0 + "\n" }.joined())
            }
            frameOut("\u{1B}[?25h")
            for (signal, action) in savedActions {
                var action = action
                sigaction(signal, &action, nil)
            }
            savedActions = []
            screenSignalTerminal = -1
            close(terminal)
            terminal = -1
            screen = nil
            self.frameOut = nil
        }
    }

    // MARK: - Private

    private func emit(_ text: String, _ stream: VPhoneConsoleStream) {
        lock.withLock {
            if screen == nil { write(text, stream) }
            try? log?.write(contentsOf: Data(text.utf8))
        }
    }

    /// Called with the lock held: moves up over the previous frame, clears below, writes this one.
    private func draw() {
        guard let screen, let frameOut else { return }
        var size = winsize()
        let sized = ioctl(terminal, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 && size.ws_row > 0
        let rows = screen.frame(at: Self.now(), width: sized ? Int(size.ws_col) : 80, height: sized ? Int(size.ws_row) : 24)
        var text = drawnRows > 0 ? "\u{1B}[\(drawnRows)A" : ""
        text += "\r\u{1B}[J"
        for (i, row) in rows.enumerated() { text += Self.coloured(row, isTitle: i == 0) + "\n" }
        drawnRows = rows.count
        frameOut(text)
    }

    /// Colour by the row's leading mark (see VPhoneConsoleScreen.frame for the row shapes).
    private static func coloured(_ row: String, isTitle: Bool) -> String {
        let code = if isTitle || row.hasPrefix(" Done in") {
            "1"
        } else if row.hasPrefix("     ") {
            "2"
        } else {
            switch row.dropFirst().first {
            case "✓": "32"
            case "✗", "!": "31"
            case "○": "2"
            default: "36;1"
            }
        }
        return "\u{1B}[\(code)m\(row)\u{1B}[0m"
    }

    /// A handler, never SIG_IGN: an ignored signal would be inherited by the guest process.
    private func installSignalHandlers(terminal fd: Int32) {
        screenSignalTerminal = fd
        let handler: @convention(c) (Int32) -> Void = { signal in
            // Async-signal-safe only: write(2), signal(3), raise(3).
            let show: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68) // ESC[?25h
            _ = withUnsafeBytes(of: show) { Darwin.write(screenSignalTerminal, $0.baseAddress, $0.count) }
            Darwin.signal(signal, SIG_DFL)
            raise(signal)
        }
        for signal in [SIGINT, SIGTERM] {
            var old = sigaction()
            sigaction(signal, nil, &old)
            // A signal the process was started ignoring stays ignored.
            if unsafeBitCast(old.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) { continue }
            var action = sigaction()
            action.__sigaction_u.__sa_handler = handler
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
            savedActions.append((signal, old))
        }
    }

    private static func writeAll(_ text: String, to fd: Int32) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                bytes = bytes.dropFirst(n)
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
