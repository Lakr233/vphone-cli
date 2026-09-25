import AppKit
import Foundation

@MainActor
@Observable
final class VPhoneProcessesModel {
    enum Activity {
        case loading
        case signalling(VPhoneProcessSignal)

        var title: String {
            switch self {
            case .loading: String(localized: "Loading processes…", bundle: VPhoneLocalization.bundle)
            case let .signalling(signal): String(localized: "Sending \(signal.name)…", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    static let autoRefreshInterval: Duration = .seconds(3)

    let control: VPhoneGuestControl
    private(set) var rows: [VPhoneProcessRow] = []
    private(set) var memory: VPhoneProcessMemorySummary?
    private(set) var hasLoaded = false
    private(set) var activity: Activity?
    private(set) var status: VPhoneGuestToolStatus?
    private var statusDate = Date.distantPast

    var searchText = ""
    var sortOrder = [KeyPathComparator(\VPhoneProcessRow.footprintSortKey, order: .reverse)]
    var selection = Set<VPhoneProcessRow.ID>()
    var autoRefresh = false
    /// The signal the confirmation dialog is asking about.
    var pendingSignal: VPhoneProcessSignalRequest?

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Derived

    var isBusy: Bool {
        activity != nil
    }

    var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var visibleRows: [VPhoneProcessRow] {
        let query = trimmedSearch
        let rows = query.isEmpty ? rows : rows.filter { $0.matches(query) }
        return rows.sorted(using: sortOrder)
    }

    /// The selected processes the filter still shows. vphoned refuses pid 1.
    var selectedRows: [VPhoneProcessRow] {
        visibleRows.filter { selection.contains($0.id) && $0.pid > 1 }
    }

    var canSignal: Bool {
        !isBusy && !selectedRows.isEmpty
    }

    /// The status bar text: the last result, or the process count and memory
    /// pressure once loaded. The view shows the connection state instead
    /// while the guest is disconnected.
    var displayedStatus: VPhoneGuestToolStatus? {
        if let status {
            return status
        }
        guard hasLoaded else { return nil }
        let query = trimmedSearch
        var parts = [
            query.isEmpty
                ? String(localized: "\(rows.count) processes", bundle: VPhoneLocalization.bundle)
                : String(localized: "\(visibleRows.count) of \(rows.count) processes", bundle: VPhoneLocalization.bundle),
        ]
        if let summary = memory?.summary {
            parts.append(String(localized: "memory pressure: \(summary)", bundle: VPhoneLocalization.bundle))
        }
        if let total = memory?.totalBytes {
            parts.append(String(localized: "\(VPhonePanelFormat.bytes(total)) RAM", bundle: VPhoneLocalization.bundle))
        }
        return VPhoneGuestToolStatus(message: parts.joined(separator: " · "), isError: false)
    }

    // MARK: - Refresh

    /// Reloads the process list and memory summary. A manual refresh shows
    /// progress and clears the last result; an automatic one does neither,
    /// so the table does not flicker.
    func refresh(automatic: Bool = false) async {
        // The status bar already says the guest is not connected.
        guard activity == nil, control.isConnected else { return }
        if !automatic {
            activity = .loading
        }
        defer {
            if !automatic {
                activity = nil
            }
        }
        do {
            try await apply(processesResult: control.call("processes.list"))
            // The memory summary is optional; the list stands without it.
            if let jetsam = try? await control.call("memory.pressure") {
                apply(jetsamResult: jetsam)
            }
            // An automatic refresh leaves a fresh signal result on screen.
            if !automatic || Date().timeIntervalSince(statusDate) > 5 {
                status = nil
            }
        } catch {
            fail(String(localized: "Unable to list guest processes. Check that the guest is connected, then try again.", bundle: VPhoneLocalization.bundle))
            // Any later successful refresh clears this.
            statusDate = .distantPast
        }
    }

    func apply(processesResult: [String: Any]) {
        rows = processesResult.objects("processes").compactMap(VPhoneProcessRow.init)
        hasLoaded = true
        let pids = Set(rows.map(\.id))
        if !selection.isSubset(of: pids) {
            selection.formIntersection(pids)
        }
    }

    func apply(jetsamResult: [String: Any]) {
        memory = jetsamResult.object("memory").map(VPhoneProcessMemorySummary.init)
    }

    // MARK: - Signals

    /// Asks for confirmation before sending `signal` to `pids`, or to the
    /// selection when `pids` is nil.
    func requestSignal(_ signal: VPhoneProcessSignal, pids: Set<VPhoneProcessRow.ID>? = nil) {
        let targets = pids.map { pids in visibleRows.filter { pids.contains($0.id) && $0.pid > 1 } } ?? selectedRows
        guard !targets.isEmpty, !isBusy else { return }
        pendingSignal = VPhoneProcessSignalRequest(signal: signal, targets: targets)
    }

    /// Sends a confirmed signal with `force: true`, one pid at a time, then
    /// reloads the list.
    func send(_ request: VPhoneProcessSignalRequest) async {
        pendingSignal = nil
        guard activity == nil else { return }
        activity = .signalling(request.signal)
        var failures: [(VPhoneProcessRow, String)] = []
        for target in request.targets {
            do {
                _ = try await control.call(
                    "processes.kill",
                    params: ["pid": target.pid, "signal": request.signal.rawValue, "force": true],
                )
            } catch {
                failures.append((target, "\(error)"))
            }
        }
        activity = nil
        await refresh(automatic: true)

        let signal = request.signal.name
        if let (target, _) = failures.first, failures.count == request.targets.count, failures.count == 1 {
            fail(String(localized: "Unable to send \(signal) to \(target.reference). Check that the process still exists, then try again.", bundle: VPhoneLocalization.bundle))
        } else if !failures.isEmpty {
            let names = failures.map(\.0.reference).joined(separator: ", ")
            fail(String(localized: "Unable to send \(signal) to \(names). Check that the processes still exist, then try again.", bundle: VPhoneLocalization.bundle))
        } else if request.targets.count == 1, let target = request.targets.first {
            succeed(String(localized: "Sent \(signal) to \(target.reference).", bundle: VPhoneLocalization.bundle))
        } else {
            succeed(String(localized: "Sent \(signal) to \(request.targets.count) processes.", bundle: VPhoneLocalization.bundle))
        }
    }

    // MARK: - Copy

    func copy(_ value: (VPhoneProcessRow) -> String?, pids: Set<VPhoneProcessRow.ID>) {
        let text = visibleRows
            .filter { pids.contains($0.id) }
            .compactMap(value)
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Status

    private func succeed(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: false)
        statusDate = Date()
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
        statusDate = Date()
    }
}
