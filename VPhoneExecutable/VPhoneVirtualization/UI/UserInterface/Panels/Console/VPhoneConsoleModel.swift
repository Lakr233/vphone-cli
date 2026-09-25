import AppKit
import Foundation
import UniformTypeIdentifiers

/// Streams the guest unified log by running vphoned `logs.syslog` captures
/// back to back while the window is open and not paused.
///
/// Each capture opens its own `OSLogEventLiveStream` in the guest, collects
/// events for `captureSeconds`, then invalidates it. Captures never overlap in
/// time, so no event is reported twice and rows are appended without
/// de-duplication. Events logged during the round trip between two captures
/// are not seen.
@MainActor
@Observable
final class VPhoneConsoleModel {
    static let maximumEntries = 10000
    static let captureSeconds = 2.0
    static let captureMaxLines = 2000
    static let retryDelay: Duration = .seconds(3)

    let control: VPhoneGuestControl

    /// Whether captures run. The window opens streaming.
    var isRunning = true
    /// A server-side process name filter (case-insensitive substring), sent
    /// with the next capture.
    var processFilter = ""
    var levelFilter: VPhoneConsoleLevelFilter = .all {
        didSet { rebuildVisible() }
    }

    /// A client-side filter over the loaded rows.
    var searchText = "" {
        didSet { rebuildVisible() }
    }

    var sortOrder = [KeyPathComparator(\VPhoneConsoleEntry.id)] {
        didSet { rebuildVisible() }
    }

    var autoScroll = true
    var selection: Set<VPhoneConsoleEntry.ID> = []

    /// Every loaded row, oldest first, capped at `maximumEntries`.
    private(set) var entries: [VPhoneConsoleEntry] = []
    /// The rows the table shows: filtered and sorted.
    private(set) var visibleEntries: [VPhoneConsoleEntry] = []
    /// The newest row that passes the filters, for Auto-Scroll.
    private(set) var newestVisibleID: VPhoneConsoleEntry.ID?
    private(set) var isCapturing = false
    private(set) var status: VPhoneGuestToolStatus?
    /// Whether the guest dropped events because a capture hit `captureMaxLines`.
    private(set) var lastCaptureTruncated = false

    private var nextID = 0

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Streaming

    /// Runs until the calling task is cancelled (the window closes).
    func run() async {
        while !Task.isCancelled {
            guard isRunning else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            guard control.isConnected else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if await !capture() {
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    /// Captures once. Toolbar Refresh uses this while the stream is paused.
    func captureOnce() async {
        guard !isCapturing, control.isConnected else { return }
        await capture(force: true)
    }

    /// Runs one capture and returns whether it succeeded. Rows that arrive
    /// after the user pauses are dropped, so a paused table stays still.
    @discardableResult
    private func capture(force: Bool = false) async -> Bool {
        guard !isCapturing else { return true }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let result = try await control.call("logs.syslog", params: captureParameters)
            if isRunning || force {
                apply(syslogResult: result)
            }
            if status?.isError == true {
                status = nil
            }
            return true
        } catch {
            status = VPhoneGuestToolStatus(
                message: String(localized: "Unable to capture the guest log. Check the connection. Retrying in 3 seconds.", bundle: VPhoneLocalization.bundle),
                isError: true,
            )
            return false
        }
    }

    var captureParameters: [String: Any] {
        var params: [String: Any] = [
            "seconds": Self.captureSeconds,
            "level": levelFilter.rawValue,
            "max_lines": Self.captureMaxLines,
        ]
        let process = processFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !process.isEmpty {
            params["process"] = process
        }
        return params
    }

    // MARK: - Parsing

    /// Appends the entries of one `logs.syslog` result:
    /// `{entries: [{date, level, process, pid, subsystem, category, message}], count, truncated, source, seconds}`.
    func apply(syslogResult result: [String: Any]) {
        lastCaptureTruncated = result.bool("truncated") ?? false
        let raw = result.objects("entries")
        guard !raw.isEmpty else { return }
        var added: [VPhoneConsoleEntry] = []
        added.reserveCapacity(raw.count)
        for object in raw {
            guard let message = object.string("message") else { continue }
            let date = object.string("date").flatMap(Self.parseDate)
            added.append(VPhoneConsoleEntry(
                id: nextID,
                date: date,
                time: date.map { Self.timeFormatter.string(from: $0) } ?? "—",
                level: VPhoneConsoleLevel(guestValue: object.string("level")),
                process: object.string("process") ?? "",
                pid: object.int("pid") ?? 0,
                subsystem: object.string("subsystem") ?? "",
                category: object.string("category") ?? "",
                message: message,
                summary: VPhoneConsoleEntry.summary(of: message),
            ))
            nextID += 1
        }
        entries.append(contentsOf: added)
        let overflow = entries.count - Self.maximumEntries
        if overflow > 0 {
            entries.removeFirst(overflow)
            if let oldest = entries.first?.id {
                selection = selection.filter { $0 >= oldest }
            }
        }
        rebuildVisible()
    }

    /// icli writes dates with `NSISO8601DateFormatter` defaults (whole
    /// seconds); fractional seconds are accepted if the guest ever sends them.
    private static func parseDate(_ text: String) -> Date? {
        fractionalParser.date(from: text) ?? wholeSecondParser.date(from: text)
    }

    private static let wholeSecondParser = ISO8601DateFormatter()

    private static let fractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        return formatter
    }()

    // MARK: - Filtering

    var isFiltered: Bool {
        levelFilter != .all || !trimmedSearch.isEmpty
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildVisible() {
        let query = trimmedSearch
        let level = levelFilter
        var rows = entries
        if level != .all || !query.isEmpty {
            rows = entries.filter { entry in
                level.includes(entry.level) && (query.isEmpty || entry.matches(query))
            }
        }
        newestVisibleID = rows.last?.id
        // Rows are already in arrival order; only sort for another order.
        if sortOrder != [KeyPathComparator(\VPhoneConsoleEntry.id)] {
            rows.sort(using: sortOrder)
        }
        visibleEntries = rows
    }

    // MARK: - Actions

    func toggleRunning() {
        isRunning.toggle()
    }

    func clear() {
        entries = []
        selection = []
        lastCaptureTruncated = false
        rebuildVisible()
    }

    func entry(for id: VPhoneConsoleEntry.ID) -> VPhoneConsoleEntry? {
        // IDs are consecutive in `entries`, so the index is an offset.
        guard let first = entries.first?.id else { return nil }
        let index = id - first
        guard entries.indices.contains(index), entries[index].id == id else { return nil }
        return entries[index]
    }

    /// The single selected row, for the detail pane.
    var selectedEntry: VPhoneConsoleEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entry(for: id)
    }

    func selectedEntries(_ ids: Set<VPhoneConsoleEntry.ID>) -> [VPhoneConsoleEntry] {
        ids.sorted().compactMap(entry(for:))
    }

    func fullDate(_ entry: VPhoneConsoleEntry) -> String {
        entry.date.map { Self.fullDateFormatter.string(from: $0) } ?? "—"
    }

    /// One plain-text line per entry, in the style of `log stream`.
    func logText(_ rows: [VPhoneConsoleEntry]) -> String {
        rows.map { entry in
            var line = "\(fullDate(entry)) \(entry.level.logToken.padding(toLength: 7, withPad: " ", startingAt: 0)) \(entry.process)[\(entry.pid)]"
            if let origin = entry.origin {
                line += " (\(origin))"
            }
            return line + " " + entry.message
        }
        .joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showOnlyProcess(of entry: VPhoneConsoleEntry) {
        processFilter = entry.process
    }

    // MARK: - Save

    func save() {
        let rows = visibleEntries
        guard !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "Guest Console.log"
        panel.canCreateDirectories = true
        let text = logText(rows)
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.write(text, to: url, count: rows.count)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    private func write(_ text: String, to url: URL, count: Int) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = VPhoneGuestToolStatus(
                message: String(localized: "Saved \(count) entries to \(url.lastPathComponent).", bundle: VPhoneLocalization.bundle),
                isError: false,
            )
        } catch {
            status = VPhoneGuestToolStatus(
                message: String(localized: "Unable to save the log. Choose another location, then try again.", bundle: VPhoneLocalization.bundle),
                isError: true,
            )
        }
    }
}
