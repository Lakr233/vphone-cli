import AppKit
import Foundation

@MainActor
@Observable
final class VPhoneServicesModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case running
        case stopped
        case disabled

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .all: String(localized: "All", bundle: VPhoneLocalization.bundle)
            case .running: String(localized: "Running", bundle: VPhoneLocalization.bundle)
            case .stopped: String(localized: "Stopped", bundle: VPhoneLocalization.bundle)
            case .disabled: String(localized: "Disabled", bundle: VPhoneLocalization.bundle)
            }
        }

        func matches(_ row: VPhoneServiceRow) -> Bool {
            switch self {
            case .all: true
            case .running: row.isRunning
            case .stopped: !row.isRunning
            case .disabled: row.disabled == true
            }
        }
    }

    /// launchd's description of the selected service, from `services.print`.
    struct Detail {
        let label: String
        let domain: String
        let text: String
    }

    let control: VPhoneGuestControl
    private(set) var isConnected = false
    private(set) var activity: String?
    private(set) var status: VPhoneGuestToolStatus?
    private(set) var hasLoaded = false

    private(set) var rows: [VPhoneServiceRow] = [] {
        didSet { updateVisibleRows() }
    }

    var filter: Filter = .all {
        didSet { updateVisibleRows() }
    }

    var searchText = "" {
        didSet { updateVisibleRows() }
    }

    var sortOrder = [KeyPathComparator(\VPhoneServiceRow.label, comparator: .localizedStandard)] {
        didSet { updateVisibleRows() }
    }

    private(set) var visibleRows: [VPhoneServiceRow] = []
    private(set) var runningCount = 0
    var selection: VPhoneServiceRow.ID?
    var pendingAction: VPhoneServicePendingAction?

    private(set) var detail: Detail?
    private(set) var detailError: String?

    var isBusy: Bool {
        activity != nil
    }

    var selectedRow: VPhoneServiceRow? {
        selection.flatMap(row)
    }

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    func row(_ label: String) -> VPhoneServiceRow? {
        rows.first { $0.label == label }
    }

    // MARK: - Connection

    /// Follows the guest connection while the window is open and loads the
    /// service table each time vphoned connects, including when the window
    /// opens on an already connected guest.
    func monitorConnection() async {
        isConnected = false
        while !Task.isCancelled {
            let connected = control.isConnected
            if connected != isConnected {
                isConnected = connected
                if connected {
                    await refresh()
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Load

    func refresh() async {
        guard !isBusy else { return }
        activity = String(localized: "Loading services…", bundle: VPhoneLocalization.bundle)
        do {
            try await apply(listResult: control.call("services.list"))
            status = nil
        } catch {
            fail(String(localized: "Unable to load services. Check the connection, then try again.", bundle: VPhoneLocalization.bundle))
        }
        activity = nil
        if selection != nil {
            detail = nil
            await loadDetail()
        }
    }

    func apply(listResult: [String: Any]) {
        rows = listResult.objects("services").compactMap(VPhoneServiceRow.init)
        hasLoaded = true
    }

    /// Replaces one row with a `services.status` payload, or drops it when
    /// launchd no longer has the label loaded.
    func apply(statusResult: [String: Any]) {
        guard var updated = VPhoneServiceRow(statusResult) else { return }
        let index = rows.firstIndex { $0.label == updated.label }
        guard statusResult.bool("loaded") ?? true else {
            if let index {
                rows.remove(at: index)
            }
            return
        }
        if let index {
            // Status omits Program when launchd's record lacks it.
            updated.program = updated.program ?? rows[index].program
            rows[index] = updated
        } else {
            rows.append(updated)
        }
    }

    // MARK: - Detail

    /// Loads `services.print` for the selection after a short pause, so
    /// arrowing through the table does not print every service.
    func loadDetail() async {
        guard let label = selection else {
            detail = nil
            detailError = nil
            return
        }
        if detail?.label == label, detailError == nil {
            return
        }
        detailError = nil
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, selection == label else { return }
        do {
            let result = try await control.call("services.print", params: ["label": label])
            guard selection == label else { return }
            apply(printResult: result)
        } catch {
            guard selection == label else { return }
            detail = nil
            detailError = String(localized: "Unable to load details for \(label). \(Self.reason(error))", bundle: VPhoneLocalization.bundle)
        }
    }

    func apply(printResult: [String: Any]) {
        guard let label = printResult.string("label") else { return }
        detail = Detail(
            label: label,
            domain: printResult.string("domain") ?? "system",
            text: printResult.string("description") ?? "",
        )
        detailError = nil
    }

    // MARK: - Actions

    func canPerform(_ action: VPhoneServiceAction, on row: VPhoneServiceRow?) -> Bool {
        guard let row, !isBusy, isConnected else { return false }
        switch action {
        case .start: return !row.isRunning
        case .stop, .restart, .signal: return row.isRunning
        case .enable: return row.disabled == true
        case .disable: return row.disabled != true
        case .remove: return true
        }
    }

    /// Runs a safe action now, or asks before a destructive one.
    func request(_ action: VPhoneServiceAction, on label: String) {
        if action.needsConfirmation {
            pendingAction = VPhoneServicePendingAction(action: action, label: label)
        } else {
            Task { await perform(action, on: label) }
        }
    }

    func perform(_ action: VPhoneServiceAction, on label: String) async {
        guard !isBusy else { return }
        activity = action.progressTitle(label)
        defer { activity = nil }
        let message: String
        do {
            message = try await run(action, on: label)
        } catch {
            fail(action.failureMessage(label, reason: Self.reason(error)))
            await refreshRow(label)
            return
        }
        await refreshRow(label)
        succeed(message)
        if selection == label {
            detail = nil
            await loadDetail()
        }
    }

    private func run(_ action: VPhoneServiceAction, on label: String) async throws -> String {
        let forced: [String: Any] = ["label": label, "force": true]
        switch action {
        case .start:
            let result = try await control.call("services.start", params: ["label": label])
            return result.bool("unchanged") == true
                ? String(localized: "\(label) is already running.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Started \(label).", bundle: VPhoneLocalization.bundle)
        case .stop:
            let result = try await control.call("services.stop", params: forced)
            return result.bool("unchanged") == true
                ? String(localized: "\(label) was not running.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Stopped \(label).", bundle: VPhoneLocalization.bundle)
        case .restart:
            return try await restart(label)
        case .enable:
            let result = try await control.call("services.enable", params: ["label": label])
            return result.bool("changed") == false
                ? String(localized: "\(label) is already enabled.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Enabled \(label).", bundle: VPhoneLocalization.bundle)
        case .disable:
            let result = try await control.call("services.disable", params: forced)
            return result.bool("changed") == false
                ? String(localized: "\(label) is already disabled.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Disabled \(label).", bundle: VPhoneLocalization.bundle)
        case let .signal(signal):
            var params = forced
            params["signal"] = signal.rawValue
            _ = try await control.call("services.signal", params: params)
            return String(localized: "Sent \(signal.title) to \(label).", bundle: VPhoneLocalization.bundle)
        case .remove:
            let result = try await control.call("services.remove", params: forced)
            return result.bool("unchanged") == true
                ? String(localized: "\(label) was not loaded.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Removed \(label).", bundle: VPhoneLocalization.bundle)
        }
    }

    /// Stops the service, waits up to two seconds for it to exit, then starts
    /// it unless KeepAlive already brought it back under a new pid.
    private func restart(_ label: String) async throws -> String {
        let before = row(label)?.pid
        _ = try await control.call("services.stop", params: ["label": label, "force": true])
        var current = VPhoneServiceRow(label: label)
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(100))
            guard let status = try? await control.call("services.status", params: ["label": label]),
                  let row = VPhoneServiceRow(status) else { continue }
            current = row
            if !row.isRunning || row.pid != before {
                break
            }
        }
        if !current.isRunning {
            _ = try await control.call("services.start", params: ["label": label])
            current = await (try? control.call("services.status", params: ["label": label]))
                .flatMap(VPhoneServiceRow.init) ?? current
        }
        if let pid = current.pid {
            return String(localized: "Restarted \(label) as PID \(pid).", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "Restarted \(label).", bundle: VPhoneLocalization.bundle)
    }

    private func refreshRow(_ label: String) async {
        guard let result = try? await control.call("services.status", params: ["label": label]) else { return }
        apply(statusResult: result)
    }

    // MARK: - Copy

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        succeed(String(localized: "Copied \(text).", bundle: VPhoneLocalization.bundle))
    }

    // MARK: - Filtering

    private func updateVisibleRows() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleRows = rows
            .filter { row in
                filter.matches(row) && (query.isEmpty
                    || row.label.localizedCaseInsensitiveContains(query)
                    || row.programText.localizedCaseInsensitiveContains(query))
            }
            .sorted(using: sortOrder)
        // Actions follow the selection, so never leave it on a hidden row.
        if let selection, !visibleRows.contains(where: { $0.label == selection }) {
            self.selection = nil
        }
        runningCount = rows.reduce(0) { $0 + ($1.isRunning ? 1 : 0) }
    }

    // MARK: - Status

    /// The guest's own message for a refused request, or the connection hint.
    private static func reason(_ error: Error) -> String {
        if case let VPhoneGuestControl.ControlError.guestError(message) = error, !message.isEmpty {
            return String(localized: "The guest reported: \(message)", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "Check the connection, then try again.", bundle: VPhoneLocalization.bundle)
    }

    private func succeed(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: false)
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
    }
}
