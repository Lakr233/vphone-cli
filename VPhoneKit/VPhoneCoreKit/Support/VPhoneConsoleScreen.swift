import Foundation

/// What a `vm create` run has reported so far, and the plain-text lines of one frame.
/// Pure value type: no terminal I/O, no colour (the console colours lines when it draws them).
struct VPhoneConsoleScreen {
    private enum State { case pending, active, finished, failed }

    private struct Phase {
        var name: String
        var state: State = .pending
        var startedAt: TimeInterval = 0
        var endedAt: TimeInterval = 0
        var summary: String?
        var steps: [String] = []
        var current: String?
        var detail: String?
        var fraction: Double?
        var count: (done: Int, total: Int)?
    }

    private enum Drop { case keep, detail, step, warning, pending }

    private static let spinner = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    private static let markers = ["[*] ", "[+] ", "[-] ", "[!] ", "[.] ", "- "]

    let title: String
    let startedAt: TimeInterval
    private var phases: [Phase]
    private var alerts: [(failure: Bool, text: String)] = []
    private var finishedAt: TimeInterval?
    private var failed = false
    private(set) var lastLines: [String] = []

    init(title: String, pendingPhases: [String], startedAt: TimeInterval) {
        self.title = title
        self.startedAt = startedAt
        phases = pendingPhases.map { Phase(name: $0) }
    }

    // MARK: - Collecting

    /// "Done" only closes the current phase; it is not listed.
    mutating func phase(_ name: String, at now: TimeInterval) {
        close(.finished, at: now)
        guard name != "Done" else { return }
        let i = phases.firstIndex { $0.name == name && $0.state == .pending } ?? { phases.append(Phase(name: name)); return phases.count - 1 }()
        phases[i].state = .active
        phases[i].startedAt = now
    }

    mutating func line(_ text: String, _ kind: VPhoneConsoleKind) {
        lastLines.append(text)
        if lastLines.count > 15 { lastLines.removeFirst(lastLines.count - 15) }
        let shown = Self.displayText(text)
        switch kind {
        case .step: mutateActive { Self.setStep(shown, in: &$0) }
        case .done: mutateActive { $0.summary = shown }
        case .note, .plain: mutateActive { $0.detail = shown }
        case .warning: alerts.append((false, shown))
        case .failure: alerts.append((true, shown))
        }
    }

    mutating func activity(_ name: String, fraction: Double?) {
        mutateActive { Self.setStep(name, in: &$0); $0.fraction = fraction; $0.count = nil }
    }

    mutating func activity(_ name: String, done: Int, of total: Int) {
        mutateActive { Self.setStep(name, in: &$0); $0.count = (done, total); $0.fraction = nil }
    }

    mutating func finish(failed: Bool, at now: TimeInterval) {
        close(failed ? .failed : .finished, at: now)
        self.failed = failed
        finishedAt = now
    }

    private mutating func mutateActive(_ body: (inout Phase) -> Void) {
        if let i = phases.firstIndex(where: { $0.state == .active }) { body(&phases[i]) }
    }

    private mutating func close(_ state: State, at now: TimeInterval) {
        mutateActive { $0.state = state; $0.endedAt = now }
    }

    private static func setStep(_ name: String, in p: inout Phase) {
        guard name != p.current else { return }
        if let c = p.current { p.steps.append(c) }
        p.current = name
    }

    // MARK: - Text

    /// Leading blanks, one leading marker, and a trailing "..." or "…" are removed.
    static func displayText(_ text: String) -> String {
        var s = Substring(text.drop { $0 == " " || $0 == "\t" })
        if let m = markers.first(where: { s.hasPrefix($0) }) { s = s.dropFirst(m.count) }
        if s.hasSuffix("...") { s = s.dropLast(3) } else if s.hasSuffix("…") { s = s.dropLast() }
        return String(s)
    }

    private static func clock(_ t: TimeInterval) -> String {
        let n = max(0, Int(t))
        return "\(n / 60):" + (n % 60 < 10 ? "0" : "") + "\(n % 60)"
    }

    private static func pad(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: max(0, n - s.count)) }
    private static func padLeft(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }

    // MARK: - Frame

    /// Lines no wider than `width - 1`, at most `height - 1` of them.
    func frame(at now: TimeInterval, width: Int, height: Int) -> [String] {
        let spin = String(Self.spinner[Int(max(0, now) * 10) % Self.spinner.count])
        var rows: [(text: String, drop: Drop)] = []

        let total = Self.clock((finishedAt ?? now) - startedAt)
        let room = width - 1 - title.count - total.count
        rows.append((title + String(repeating: " ", count: max(2, room)) + total, .keep))

        for p in phases {
            let name = Self.pad(p.name, 17)
            let time = Self.padLeft(Self.clock((p.state == .active ? now : p.endedAt) - p.startedAt), 5)
            switch p.state {
            case .pending:
                rows.append((" ○ \(p.name)", .pending))
            case .finished:
                rows.append((" ✓ \(name) \(time)  \(p.summary ?? "")".trimmingTrailingSpaces, .keep))
            case .failed:
                rows.append((" ✗ \(name) \(time)", .keep))
            case .active:
                var row = " \(spin) \(name) \(time)"
                // A non-finite fraction is no fraction; a finite one is held to 0...1.
                if let f = (p.fraction ?? p.count.map({ $0.total > 0 ? Double($0.done) / Double($0.total) : 0 }))
                    .flatMap({ $0.isFinite ? min(1, max(0, $0)) : nil })
                {
                    let filled = Int((f * 16).rounded())
                    row += "  " + String(repeating: "█", count: filled) + String(repeating: "░", count: 16 - filled) + " "
                    row += p.count.map { "\($0.done)/\($0.total)" } ?? "\(Int((f * 100).rounded()))%"
                }
                rows.append((row, .keep))
                for s in p.steps.suffix(3) { rows.append(("     ✓ \(s)", .step)) }
                if let c = p.current { rows.append(("     \(spin) \(c)", .keep)) }
                if let d = p.detail { rows.append(("       \(d)", .detail)) }
            }
        }

        let recent = alerts.indices.filter { i in
            alerts[i...].filter { $0.failure == alerts[i].failure }.count <= 3
        }
        for i in recent { rows.append((" ! \(alerts[i].text)", .warning)) }
        if let end = finishedAt, !failed { rows.append((" Done in \(Self.clock(end - startedAt))", .keep)) }

        let limit = max(0, height - 1)
        for kind in [Drop.detail, .step, .warning, .pending] where rows.count > limit {
            while rows.count > limit, let i = kind == .pending ? rows.lastIndex(where: { $0.drop == kind }) : rows.firstIndex(where: { $0.drop == kind }) {
                rows.remove(at: i)
            }
        }
        return rows.prefix(limit).map { String($0.text.prefix(max(0, width - 1))) }
    }
}

private extension String {
    var trimmingTrailingSpaces: String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
