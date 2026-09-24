import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class VPhoneAppBrowserModel {
    // MARK: - Types

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case running
        case user
        case system

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .all: String(localized: "All", bundle: VPhoneLocalization.bundle)
            case .running: String(localized: "Running", bundle: VPhoneLocalization.bundle)
            case .user: String(localized: "User", bundle: VPhoneLocalization.bundle)
            case .system: String(localized: "System", bundle: VPhoneLocalization.bundle)
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .all: "1"
            case .running: "2"
            case .user: "3"
            case .system: "4"
            }
        }

        func includes(_ app: VPhoneAppRecord) -> Bool {
            switch self {
            case .all: true
            case .running: app.isRunning
            case .user: !app.isSystem
            case .system: app.isSystem
            }
        }
    }

    enum Activity {
        case loading
        case launching(String)
        case terminating(String)
        case uninstalling(String)
        case installing(String)
        case openingURL
        case repairingNetwork

        var title: String {
            switch self {
            case .loading: String(localized: "Loading apps…", bundle: VPhoneLocalization.bundle)
            case let .launching(name): String(localized: "Launching \(name)…", bundle: VPhoneLocalization.bundle)
            case let .terminating(name): String(localized: "Terminating \(name)…", bundle: VPhoneLocalization.bundle)
            case let .uninstalling(name): String(localized: "Uninstalling \(name)…", bundle: VPhoneLocalization.bundle)
            case let .installing(file): String(localized: "Installing \(file)…", bundle: VPhoneLocalization.bundle)
            case .openingURL: String(localized: "Opening URL…", bundle: VPhoneLocalization.bundle)
            case .repairingNetwork: String(localized: "Repairing network policy…", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    // MARK: - State

    let control: VPhoneGuestControl
    /// Opens the File Browser at a guest path. The window controller wires it.
    var onRevealPath: ((String) -> Void)?

    private(set) var apps: [VPhoneAppRecord] = []
    private(set) var hasLoaded = false
    private(set) var loadFailed = false
    var filter: Filter = .all
    var searchText = ""
    var selection = Set<VPhoneAppRecord.ID>()
    var sortOrder = [KeyPathComparator(\VPhoneAppRecord.displayName)]
    private(set) var activity: Activity?
    private(set) var status: VPhoneGuestToolStatus?
    /// Set by Find; the view focuses the search field and clears it.
    var isSearchFocusRequested = false

    // Info inspector
    var isInspectorPresented = false
    private(set) var detail: VPhoneAppDetail?
    private(set) var isLoadingDetail = false
    /// `apps.url_schemes` covers every app; it is read once per list load.
    private(set) var urlSchemes: [String: [String]]?

    // Dialogs
    var uninstallCandidates: [VPhoneAppRecord] = []
    var isConfirmingUninstall = false
    var openURLTarget: VPhoneAppRecord?
    var openURLText = ""
    var isImportingPackage = false

    private var listGeneration = 0

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Derived

    var isBusy: Bool {
        activity != nil
    }

    var filteredApps: [VPhoneAppRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return apps
            .filter { app in
                filter.includes(app) && (query.isEmpty
                    || app.name.lowercased().contains(query)
                    || app.bundleID.lowercased().contains(query))
            }
            .sorted(using: sortOrder)
    }

    var countText: String {
        let visible = filteredApps.count
        if visible == apps.count {
            return visible == 1
                ? String(localized: "1 app", bundle: VPhoneLocalization.bundle)
                : String(localized: "\(visible) apps", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "\(visible) of \(apps.count) apps", bundle: VPhoneLocalization.bundle)
    }

    func app(_ id: VPhoneAppRecord.ID) -> VPhoneAppRecord? {
        apps.first { $0.id == id }
    }

    func apps(_ ids: Set<VPhoneAppRecord.ID>) -> [VPhoneAppRecord] {
        filteredApps.filter { ids.contains($0.id) }
    }

    /// The single selected app, which the inspector and single-app actions use.
    var selectedApp: VPhoneAppRecord? {
        selection.count == 1 ? selection.first.flatMap(app) : nil
    }

    func canLaunch(_ ids: Set<VPhoneAppRecord.ID>) -> Bool {
        ids.count == 1 && !isBusy && control.isConnected
    }

    func canTerminate(_ ids: Set<VPhoneAppRecord.ID>) -> Bool {
        !isBusy && control.isConnected && apps(ids).contains(where: \.isRunning)
    }

    func canUninstall(_ ids: Set<VPhoneAppRecord.ID>) -> Bool {
        let targets = apps(ids)
        return !isBusy && control.isConnected && !targets.isEmpty && !targets.contains(where: \.isSystem)
    }

    // MARK: - List

    func refresh() async {
        guard !isBusy else { return }
        // The status bar and the empty state already say the guest is not connected.
        guard control.isConnected else { return }
        listGeneration += 1
        let generation = listGeneration
        activity = .loading
        do {
            let result = try await control.appList()
            activity = nil
            guard generation == listGeneration else { return }
            apply(listResult: result)
            status = nil
        } catch {
            activity = nil
            guard generation == listGeneration else { return }
            loadFailed = true
            status = failure(String(localized: "Unable to load apps.", bundle: VPhoneLocalization.bundle), error)
            return
        }
        if urlSchemes == nil, let result = try? await control.appURLSchemes() {
            apply(urlSchemesResult: result)
        }
    }

    func apply(listResult: [String: Any]) {
        apps = listResult.objects("apps").compactMap(VPhoneAppRecord.init(json:))
        hasLoaded = true
        loadFailed = false
        urlSchemes = nil
        selection.formIntersection(Set(apps.map(\.id)))
    }

    func apply(urlSchemesResult: [String: Any]) {
        urlSchemes = urlSchemesResult["schemes"] as? [String: [String]] ?? [:]
        if var detail {
            detail.declaredSchemes = urlSchemes?[detail.bundleID] ?? []
            self.detail = detail
        }
    }

    // MARK: - Actions

    func launch(_ app: VPhoneAppRecord) async {
        await perform(.launching(app.displayName)) {
            let result = try await control.appLaunch(bundleID: app.bundleID)
            let pid = result.int("pid") ?? 0
            if let warning = result.string("warning"), !warning.isEmpty {
                return VPhoneGuestToolStatus(
                    message: String(localized: "Launched \(app.displayName), but it may not be in front.", bundle: VPhoneLocalization.bundle),
                    isError: true,
                )
            }
            return VPhoneGuestToolStatus(
                message: pid > 0
                    ? String(localized: "Launched \(app.displayName) (PID \(pid)).", bundle: VPhoneLocalization.bundle)
                    : String(localized: "Launched \(app.displayName).", bundle: VPhoneLocalization.bundle),
                isError: false,
            )
        } failure: {
            String(localized: "Unable to launch \(app.displayName).", bundle: VPhoneLocalization.bundle)
        }
    }

    func terminate(_ targets: [VPhoneAppRecord]) async {
        let running = targets.filter(\.isRunning)
        guard let first = running.first else { return }
        let name = running.count == 1 ? first.displayName : String(localized: "\(running.count) apps", bundle: VPhoneLocalization.bundle)
        await perform(.terminating(name)) {
            for app in running {
                _ = try await control.appTerminate(bundleID: app.bundleID)
            }
            return VPhoneGuestToolStatus(
                message: String(localized: "Terminated \(name).", bundle: VPhoneLocalization.bundle),
                isError: false,
            )
        } failure: {
            String(localized: "Unable to terminate \(name).", bundle: VPhoneLocalization.bundle)
        }
    }

    func requestUninstall(_ targets: [VPhoneAppRecord]) {
        guard !targets.isEmpty, !targets.contains(where: \.isSystem) else { return }
        uninstallCandidates = targets
        isConfirmingUninstall = true
    }

    func uninstallConfirmed() async {
        let targets = uninstallCandidates
        uninstallCandidates = []
        guard let first = targets.first else { return }
        let name = targets.count == 1 ? first.displayName : String(localized: "\(targets.count) apps", bundle: VPhoneLocalization.bundle)
        await perform(.uninstalling(name)) {
            for app in targets {
                _ = try await control.appUninstall(bundleID: app.bundleID)
                selection.remove(app.id)
                if detail?.bundleID == app.bundleID {
                    detail = nil
                }
            }
            return VPhoneGuestToolStatus(
                message: String(localized: "Uninstalled \(name).", bundle: VPhoneLocalization.bundle),
                isError: false,
            )
        } failure: {
            String(localized: "Unable to uninstall \(name).", bundle: VPhoneLocalization.bundle)
        }
    }

    func requestOpenURL(_ app: VPhoneAppRecord) {
        let scheme = urlSchemes?[app.bundleID]?.first ?? detail.flatMap { $0.bundleID == app.bundleID ? $0.urlSchemes.first : nil }
        openURLText = scheme.map { "\($0)://" } ?? ""
        openURLTarget = app
    }

    func openURL(_ url: String, in app: VPhoneAppRecord) async {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        await perform(.openingURL, refreshAfter: false) {
            _ = try await control.appOpenURL(url, bundleID: app.bundleID)
            return VPhoneGuestToolStatus(
                message: String(localized: "Opened \(url) in \(app.displayName).", bundle: VPhoneLocalization.bundle),
                isError: false,
            )
        } failure: {
            String(localized: "Unable to open the URL in \(app.displayName).", bundle: VPhoneLocalization.bundle)
        }
    }

    func install(packageAt url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        await perform(.installing(url.lastPathComponent)) {
            let message = try await control.installIPA(localURL: url)
            return VPhoneGuestToolStatus(message: message, isError: false)
        } failure: {
            String(localized: "Unable to install \(url.lastPathComponent).", bundle: VPhoneLocalization.bundle)
        }
    }

    /// Opens the File Browser at the app's data container.
    func showDataContainer(_ app: VPhoneAppRecord) async {
        do {
            let result = try await control.appDataDirectory(bundleID: app.bundleID)
            guard let path = result.string("data_path"), !path.isEmpty else {
                status = VPhoneGuestToolStatus(
                    message: String(localized: "\(app.displayName) has no data container.", bundle: VPhoneLocalization.bundle),
                    isError: true,
                )
                return
            }
            onRevealPath?(path)
        } catch {
            status = failure(
                String(localized: "Unable to find the data container of \(app.displayName).", bundle: VPhoneLocalization.bundle),
                error,
            )
        }
    }

    func reveal(path: String) {
        onRevealPath?(path)
    }

    func copy(_ values: [String]) {
        let text = values.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = VPhoneGuestToolStatus(
            message: values.count == 1
                ? String(localized: "Copied \(text).", bundle: VPhoneLocalization.bundle)
                : String(localized: "Copied \(values.count) values.", bundle: VPhoneLocalization.bundle),
            isError: false,
        )
    }

    /// Runs one guest action, reports its result, then reloads the list.
    private func perform(
        _ activity: Activity,
        refreshAfter: Bool = true,
        _ body: () async throws -> VPhoneGuestToolStatus,
        failure message: () -> String,
    ) async {
        guard !isBusy else { return }
        self.activity = activity
        var result: VPhoneGuestToolStatus
        do {
            result = try await body()
        } catch {
            result = failure(message(), error)
        }
        self.activity = nil
        if refreshAfter {
            await refresh()
        }
        status = result
    }

    private func failure(_ sentence: String, _ error: Error) -> VPhoneGuestToolStatus {
        let detail =
            if case let VPhoneGuestControl.ControlError.guestError(message) = error {
                String(localized: "The guest reported: \(message)", bundle: VPhoneLocalization.bundle)
            } else {
                String(localized: "Check the connection, then try again.", bundle: VPhoneLocalization.bundle)
            }
        return VPhoneGuestToolStatus(message: "\(sentence) \(detail)", isError: true)
    }

    // MARK: - Info

    /// Loads the inspector for one app; each section fills in as it returns.
    func loadDetail(for bundleID: VPhoneAppRecord.ID?) async {
        guard let bundleID else {
            detail = nil
            return
        }
        beginDetail(for: bundleID)
        guard control.isConnected else { return }
        isLoadingDetail = true
        defer {
            if detail?.bundleID == bundleID {
                isLoadingDetail = false
            }
        }
        do {
            try await apply(infoResult: control.appInfo(bundleID: bundleID))
        } catch {
            updateDetail(bundleID) { $0.infoError = Self.message(error) }
        }
        guard detail?.bundleID == bundleID, !Task.isCancelled else { return }
        do {
            try await apply(binaryResult: control.appBinary(bundleID: bundleID))
        } catch {
            updateDetail(bundleID) { $0.binaryError = Self.message(error) }
        }
        guard detail?.bundleID == bundleID, !Task.isCancelled else { return }
        if urlSchemes == nil, let result = try? await control.appURLSchemes() {
            apply(urlSchemesResult: result)
        }
        guard detail?.bundleID == bundleID, !Task.isCancelled else { return }
        do {
            try await apply(networkPolicyResult: control.appNetworkPolicy(bundleID: bundleID))
        } catch {
            updateDetail(bundleID) { $0.networkPolicyError = Self.message(error) }
        }
    }

    /// Shows what the list already knows about the app until the guest answers.
    func beginDetail(for bundleID: VPhoneAppRecord.ID) {
        guard detail?.bundleID != bundleID else { return }
        var fresh = VPhoneAppDetail(bundleID: bundleID, record: app(bundleID))
        fresh.declaredSchemes = urlSchemes?[bundleID] ?? []
        detail = fresh
    }

    func apply(infoResult: [String: Any]) {
        guard let id = infoResult.string("bundle_id") else { return }
        updateDetail(id) { $0.apply(info: infoResult) }
    }

    func apply(binaryResult: [String: Any]) {
        guard let id = binaryResult.string("bundle_id") else { return }
        updateDetail(id) { $0.apply(binary: binaryResult) }
    }

    func apply(networkPolicyResult: [String: Any]) {
        guard let id = networkPolicyResult.string("bundle_id") else { return }
        updateDetail(id) {
            $0.networkPolicy = VPhoneAppNetworkPolicy(json: networkPolicyResult)
            $0.networkPolicyError = nil
        }
    }

    func repairNetworkPolicy() async {
        guard let bundleID = detail?.bundleID, !isBusy else { return }
        let name = detail?.displayName ?? bundleID
        activity = .repairingNetwork
        do {
            let result = try await control.appNetworkPolicy(bundleID: bundleID, repair: true)
            apply(networkPolicyResult: result)
            let allowed = result.bool("allowed") ?? false
            status = VPhoneGuestToolStatus(
                message: allowed
                    ? String(localized: "\(name) can use Wi-Fi and cellular data.", bundle: VPhoneLocalization.bundle)
                    : String(localized: "The network policy of \(name) did not change. Try again after relaunching the app.", bundle: VPhoneLocalization.bundle),
                isError: !allowed,
            )
        } catch {
            status = failure(String(localized: "Unable to repair the network policy of \(name).", bundle: VPhoneLocalization.bundle), error)
        }
        activity = nil
    }

    private func updateDetail(_ bundleID: String, _ change: (inout VPhoneAppDetail) -> Void) {
        guard var detail, detail.bundleID == bundleID else { return }
        change(&detail)
        self.detail = detail
    }

    private static func message(_ error: Error) -> String {
        if case let VPhoneGuestControl.ControlError.guestError(message) = error {
            return message
        }
        return String(localized: "Check the connection, then try again.", bundle: VPhoneLocalization.bundle)
    }
}
