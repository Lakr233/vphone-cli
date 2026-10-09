import Foundation

// MARK: - VPhoneProgressBar

/// A single-line, redrawing byte progress bar for long transfers. Renders to
/// stderr only when it is a TTY, so piped/`--json`/GUI-subprocess invocations
/// (stdout consumed elsewhere) stay clean and the bar simply no-ops.
///
/// A caller that reads the output through a pipe, such as vphone-launchpad,
/// sets `VPHONE_PROGRESS=lines` to get `progress <done> <total>` lines on
/// stderr instead, at most a few per second.
///
/// Unchecked Sendable so a transfer's callback can drive it from another
/// thread: every caller reports serially (`VPhoneIPSWCache` reports one at a
/// time even across several connections) and calls `finish()` only after the
/// transfer has returned.
final class VPhoneProgressBar: @unchecked Sendable {
    private enum Mode {
        case off, bar, lines
    }

    private let label: String
    private let mode: Mode
    private let start = Date()
    private let width = 28
    private var lastRender = Date.distantPast
    private var total: Int64 = 0
    private var updated = false

    init(label: String) {
        self.label = label
        mode = if isatty(FileHandle.standardError.fileDescriptor) != 0 {
            .bar
        } else if ProcessInfo.processInfo.environment["VPHONE_PROGRESS"] == "lines" {
            .lines
        } else {
            .off
        }
    }

    func update(done: Int64, total: Int64) {
        guard mode != .off else { return }
        self.total = total
        updated = true
        let now = Date()
        let interval = mode == .bar ? 0.066 : 0.25 // ~15 fps, or 4 lines a second
        if done < total, now.timeIntervalSince(lastRender) < interval {
            return
        }
        lastRender = now
        render(done: done, now: now)
    }

    /// Draws the final state. Draws nothing when no update came, such as for
    /// a download the cache already held.
    func finish() {
        guard updated else { return }
        switch mode {
        case .off:
            return
        case .bar:
            render(done: total, now: Date())
            write("\n")
        case .lines:
            render(done: total, now: Date())
        }
    }

    private func render(done: Int64, now: Date) {
        if mode == .lines {
            write("progress \(done) \(total)\n")
            return
        }
        let frac = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
        let filled = Int(frac * Double(width))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let elapsed = now.timeIntervalSince(start)
        let rate = elapsed > 0 ? Double(done) / elapsed : 0

        var line = "\r\(label) [\(bar)] \(Int(frac * 100))%  \(Self.bytes(done))"
        if total > 0 {
            line += "/\(Self.bytes(total))"
        }
        if rate > 0 {
            line += "  \(Self.bytes(Int64(rate)))/s"
        }
        if total > 0, rate > 0, done < total {
            line += "  eta \(Self.clock(Double(total - done) / rate))"
        }
        line += "\u{1B}[K" // clear to end of line
        write(line)
    }

    /// Progress is best effort. A reader that went away, such as a quit
    /// vphone-launchpad, leaves stderr a broken pipe; `write(_:)` raises an
    /// Objective-C exception for that and aborts the transfer under way.
    private func write(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }

    static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(n), i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024; i += 1
        }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[i])
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
