import AppKit
import Foundation

@MainActor
@Observable
final class VPhoneCrashLogsModel {
    enum Activity {
        case listing
        case exporting

        var title: String {
            switch self {
            case .listing: String(localized: "Loading crash reports…", bundle: VPhoneLocalization.bundle)
            case .exporting: String(localized: "Exporting reports…", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    let control: VPhoneGuestControl
    private(set) var activity: Activity?
    private(set) var status: VPhoneGuestToolStatus?
    private(set) var reports: [VPhoneCrashReport] = []
    /// Whether a list has arrived from the guest at least once.
    private(set) var hasLoaded = false

    var searchText = ""
    var sortOrder = [KeyPathComparator(\VPhoneCrashReport.mtime, order: .reverse)]
    var selection: Set<VPhoneCrashReport.ID> = []
    var wrapLines = false

    /// Parsed report text by path, filled as reports are selected.
    private(set) var contents: [String: VPhoneCrashReportContent] = [:]
    private(set) var loadingPaths: Set<String> = []
    private(set) var loadErrors: [String: String] = [:]

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Derived State

    var isBusy: Bool {
        activity != nil
    }

    var visibleReports: [VPhoneCrashReport] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? reports : reports.filter {
            $0.process.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
        return matches.sorted(using: sortOrder)
    }

    /// The report the detail pane shows: the selection when it is one row.
    var focusedReport: VPhoneCrashReport? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return reports.first { $0.id == id }
    }

    var focusedContent: VPhoneCrashReportContent? {
        focusedReport.flatMap { contents[$0.path] }
    }

    var canCopy: Bool {
        focusedContent != nil
    }

    var canExport: Bool {
        !selection.isEmpty && !isBusy
    }

    func reports(for ids: Set<VPhoneCrashReport.ID>) -> [VPhoneCrashReport] {
        visibleReports.filter { ids.contains($0.id) }
    }

    // MARK: - List

    func refresh() async {
        guard activity == nil else { return }
        guard control.isConnected else {
            fail(String(localized: "The guest is not connected. Start the VM, then choose Refresh.", bundle: VPhoneLocalization.bundle))
            return
        }
        activity = .listing
        defer { activity = nil }
        do {
            let result = try await control.call("logs.crashes")
            apply(crashesResult: result)
            succeed(String(localized: "Crash reports: \(reports.count)", bundle: VPhoneLocalization.bundle))
        } catch {
            fail(String(localized: "Unable to list crash reports. Check the connection, then try again.", bundle: VPhoneLocalization.bundle))
        }
    }

    /// Applies a `logs.crashes` result: `{crashes: [{path, name, process, size, mtime}], count}`.
    func apply(crashesResult: [String: Any]) {
        let fresh = crashesResult.objects("crashes").compactMap(VPhoneCrashReport.init(json:))
        let byPath = Dictionary(fresh.map { ($0.path, $0) }) { first, _ in first }

        // Drop cached text for reports that are gone or were rewritten.
        for report in reports {
            let current = byPath[report.path]
            if current == nil || current?.size != report.size || current?.mtime != report.mtime {
                contents[report.path] = nil
                loadErrors[report.path] = nil
            }
        }
        reports = fresh
        hasLoaded = true
        selection = selection.filter { byPath[$0] != nil }
        loadSelection()
    }

    // MARK: - Report Content

    /// Loads the focused report's text if it is not cached yet.
    func loadSelection() {
        guard let report = focusedReport,
              contents[report.path] == nil,
              !loadingPaths.contains(report.path)
        else { return }
        loadingPaths.insert(report.path)
        loadErrors[report.path] = nil
        Task { await loadContent(of: report) }
    }

    func retryFocusedReport() {
        guard let report = focusedReport else { return }
        loadErrors[report.path] = nil
        loadSelection()
    }

    private func loadContent(of report: VPhoneCrashReport) async {
        defer { loadingPaths.remove(report.path) }
        do {
            _ = try await content(of: report)
        } catch {
            loadErrors[report.path] = loadErrorMessage(error)
        }
    }

    /// Returns the cached text or fetches it. Parsing a large report runs off
    /// the main actor so the window stays responsive.
    private func content(of report: VPhoneCrashReport) async throws -> VPhoneCrashReportContent {
        if let cached = contents[report.path] {
            return cached
        }
        let result = try await control.call("logs.crash", params: ["path": report.path])
        guard let fields = VPhoneCrashReportContent.Fields(crashResult: result, path: report.path) else {
            throw VPhoneGuestControl.ControlError.protocolError("missing report content")
        }
        let content = await Task.detached(priority: .userInitiated) {
            VPhoneCrashReportContent(fields)
        }.value
        contents[report.path] = content
        return content
    }

    /// Applies a `logs.crash` result: `{path, content, size, encoding, truncated}`.
    func apply(crashResult: [String: Any]) {
        guard let fields = VPhoneCrashReportContent.Fields(crashResult: crashResult) else { return }
        contents[fields.path] = VPhoneCrashReportContent(fields)
        loadErrors[fields.path] = nil
    }

    private func loadErrorMessage(_ error: Error) -> String {
        if case let VPhoneGuestControl.ControlError.guestError(message) = error {
            return String(localized: "The guest could not read this report: \(message)", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "Unable to load this report. Check the connection, then try again.", bundle: VPhoneLocalization.bundle)
    }

    // MARK: - Copy

    func copyFocusedReport() {
        guard let content = focusedContent else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.rawText, forType: .string)
        succeed(String(localized: "Copied the report text.", bundle: VPhoneLocalization.bundle))
    }

    func copy(_ values: [String]) {
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Export

    /// Writes one report, as stored on the guest, to a file the user chose.
    func export(_ report: VPhoneCrashReport, to url: URL) async {
        guard activity == nil else { return }
        activity = .exporting
        defer { activity = nil }
        do {
            let content = try await content(of: report)
            try Data(content.rawText.utf8).write(to: url, options: .atomic)
            succeed(String(localized: "Exported \(url.lastPathComponent).", bundle: VPhoneLocalization.bundle))
        } catch {
            fail(String(localized: "Unable to export \(report.name). Check the connection and the destination, then try again.", bundle: VPhoneLocalization.bundle))
        }
    }

    /// Writes each report into a folder under its guest file name. A name
    /// that already exists there gets a numbered suffix instead of replacing it.
    func export(_ reports: [VPhoneCrashReport], toDirectory directory: URL) async {
        guard activity == nil, !reports.isEmpty else { return }
        activity = .exporting
        defer { activity = nil }
        var exported = 0
        var failed: [String] = []
        for report in reports {
            do {
                let content = try await content(of: report)
                let url = Self.availableURL(for: report.name, in: directory)
                try Data(content.rawText.utf8).write(to: url, options: .atomic)
                exported += 1
            } catch {
                failed.append(report.name)
            }
        }
        if failed.isEmpty {
            succeed(String(localized: "Exported \(exported) reports to \(directory.lastPathComponent).", bundle: VPhoneLocalization.bundle))
        } else {
            fail(String(localized: "Exported \(exported) of \(reports.count) reports. Unable to export \(failed.joined(separator: ", ")). Check the connection, then try again.", bundle: VPhoneLocalization.bundle))
        }
    }

    private static func availableURL(for name: String, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            number += 1
        }
    }

    // MARK: - Status

    private func succeed(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: false)
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
    }
}
