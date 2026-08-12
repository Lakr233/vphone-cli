import Foundation

// MARK: - VPhoneProgressBar

/// A single-line, redrawing byte progress bar for long transfers. Renders to
/// stderr only when it is a TTY, so piped/`--json`/GUI-subprocess invocations
/// (stdout consumed elsewhere) stay clean and the bar simply no-ops.
final class VPhoneProgressBar {
    private let label: String
    private let enabled: Bool
    private let start = Date()
    private let width = 28
    private var lastRender = Date.distantPast
    private var total: Int64 = 0

    init(label: String) {
        self.label = label
        self.enabled = isatty(FileHandle.standardError.fileDescriptor) != 0
    }

    func update(done: Int64, total: Int64) {
        guard enabled else { return }
        self.total = total
        let now = Date()
        if done < total, now.timeIntervalSince(lastRender) < 0.066 { return }  // ~15 fps
        lastRender = now
        render(done: done, now: now)
    }

    func finish() {
        guard enabled else { return }
        render(done: total, now: Date())
        FileHandle.standardError.write(Data("\n".utf8))
    }

    private func render(done: Int64, now: Date) {
        let frac = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
        let filled = Int(frac * Double(width))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let elapsed = now.timeIntervalSince(start)
        let rate = elapsed > 0 ? Double(done) / elapsed : 0

        var line = "\r\(label) [\(bar)] \(Int(frac * 100))%  \(Self.bytes(done))"
        if total > 0 { line += "/\(Self.bytes(total))" }
        if rate > 0 { line += "  \(Self.bytes(Int64(rate)))/s" }
        if total > 0, rate > 0, done < total { line += "  eta \(Self.clock(Double(total - done) / rate))" }
        line += "\u{1B}[K"  // clear to end of line
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(n), i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[i])
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
