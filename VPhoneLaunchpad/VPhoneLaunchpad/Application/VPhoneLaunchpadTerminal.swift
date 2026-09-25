import Foundation
import GhosttyTerminal
import SwiftUI

// MARK: - Theme

/// The one terminal look for every console and log. The light palette is the
/// project's; the dark side keeps the same ANSI colours.
/// `TerminalSurfaceView` picks the side from the SwiftUI colour scheme.
enum VPhoneLaunchpadTerminalTheme {
    static let configuration = TerminalConfiguration {
        $0.withCursorStyle(.block)
        $0.withCursorStyleBlink(true)
        $0.withFontSize(10)
        $0.withFontThicken(true)
        $0.withCustom("window-padding-color", "extend")
        // The default background is clear: the sheet or window shows through.
        $0.withBackgroundOpacity(0)
    }

    static let theme = TerminalTheme(
        light: TerminalConfiguration {
            $0.withBackground("feffff")
            $0.withForeground("000000")
            $0.withCursorColor("98989d")
            $0.withCursorText("ffffff")
            $0.withSelectionBackground("abd8ff")
            $0.withSelectionForeground("000000")
            palette(&$0)
        },
        dark: TerminalConfiguration {
            $0.withBackground("1e1e1e")
            $0.withForeground("ffffff")
            $0.withCursorColor("98989d")
            $0.withCursorText("000000")
            $0.withSelectionBackground("3f638b")
            $0.withSelectionForeground("ffffff")
            palette(&$0)
        },
    )

    private static func palette(_ builder: inout TerminalConfiguration.Builder) {
        let colors = [
            "#1a1a1a", "#cc372e", "#26a439", "#cdac08", "#0869cb", "#9647bf", "#479ec2", "#98989d",
            "#464646", "#ff453a", "#32d74b", "#e5bc00", "#0a84ff", "#bf5af2", "#69c9f2", "#ffffff",
        ]
        for (index, color) in colors.enumerated() {
            builder.withPalette(index, color: color)
        }
    }
}

// MARK: - Log terminal

/// A log file shown in a Ghostty terminal.
///
/// The file is the only source. The view replays its tail when it appears
/// and follows it off the main actor while it stays on screen; Ghostty
/// parses on its own queue. No output passes through the app model, so a
/// chatty guest or restore never invalidates a SwiftUI view. Keystrokes go
/// nowhere: the terminal is read only.
struct VPhoneLaunchpadLogTerminal: View {
    let url: URL
    @StateObject private var terminal = TerminalViewState(
        theme: VPhoneLaunchpadTerminalTheme.theme,
        terminalConfiguration: VPhoneLaunchpadTerminalTheme.configuration,
    )
    @State private var session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .task(id: url) {
                terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
                #if DEBUG
                    if VPhoneLaunchpadPreview.isActive {
                        session.receive(VPhoneLaunchpadPreview.log(for: url).joined(separator: "\r\n"))
                        return
                    }
                #endif
                await VPhoneLaunchpadLogTail.follow(url, into: session)
            }
    }
}

// MARK: - Tail

/// Follows a log file into a terminal session until the task is cancelled.
/// Polls, like the child process's own tail: the writer may be a process an
/// earlier Launchpad session started.
nonisolated enum VPhoneLaunchpadLogTail {
    /// How much of an existing log the terminal replays when it opens.
    static let replayBytes: UInt64 = 4 << 20
    static let chunkBytes = 1 << 20

    @concurrent
    static func follow(_ url: URL, into session: InMemoryTerminalSession) async {
        var file: UInt64?
        var offset: UInt64 = 0
        var newline = VPhoneLaunchpadNewlineTranslator()
        var reportedMissing = false

        while !Task.isCancelled {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
               let size = (attributes[.size] as? NSNumber)?.uint64Value,
               let handle = try? FileHandle(forReadingFrom: url)
            {
                // A new run replaces the file. Start the terminal over.
                var skipsPartialLine = false
                if file != number || size < offset {
                    if file != nil || reportedMissing {
                        session.receive("\u{1B}c")
                    }
                    file = number
                    offset = size > replayBytes ? size - replayBytes : 0
                    skipsPartialLine = offset > 0
                    newline = VPhoneLaunchpadNewlineTranslator()
                }
                try? handle.seek(toOffset: offset)
                while !Task.isCancelled, var chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty {
                    offset += UInt64(chunk.count)
                    if skipsPartialLine {
                        guard let end = chunk.firstIndex(of: 0x0A) else {
                            continue
                        }
                        chunk = chunk[chunk.index(after: end)...]
                        skipsPartialLine = false
                    }
                    session.receive(newline.translate(chunk))
                }
                try? handle.close()
            } else if file == nil, !reportedMissing {
                reportedMissing = true
                session.receive("\u{1B}[2m\(String(localized: "No output yet."))\u{1B}[0m\r\n")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// Log files end lines with a bare line feed, which a terminal treats as
/// "down one row" without returning to the first column.
nonisolated struct VPhoneLaunchpadNewlineTranslator {
    private var previous: UInt8 = 0

    mutating func translate(_ data: Data) -> Data {
        var output = Data(capacity: data.count + data.count / 32)
        for byte in data {
            if byte == 0x0A, previous != 0x0D {
                output.append(0x0D)
            }
            output.append(byte)
            previous = byte
        }
        return output
    }
}

// MARK: - Writer

/// Appends lines to a log file on a serial queue, so command output is
/// written from the thread that read it and never waits on the main actor.
/// Keeps the last few lines for error details.
final nonisolated class VPhoneLaunchpadLogWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.vphone.launchpad.log")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var recent: [String] = []

    /// Starts an empty log at `url`, replacing any earlier one.
    init(url: URL) {
        self.url = url
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
    }

    deinit {
        try? handle?.close()
    }

    func write(_ line: String) {
        lock.withLock {
            recent.append(line)
            if recent.count > 12 {
                recent.removeFirst(recent.count - 12)
            }
        }
        queue.async { [self] in
            try? handle?.write(contentsOf: Data("\(line)\n".utf8))
        }
    }

    /// The last lines written, for an error's detail text.
    var tail: String {
        lock.withLock { recent.joined(separator: "\n") }
    }
}
