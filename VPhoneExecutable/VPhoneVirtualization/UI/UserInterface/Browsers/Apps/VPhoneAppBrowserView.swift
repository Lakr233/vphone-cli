import SwiftUI
import VPhoneCoreKit

struct VPhoneAppBrowserView: View {
    @Bindable var model: VPhoneAppBrowserModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.control.isConnected,
                activity: model.activity?.title,
                status: model.status,
            )
            .overlay(alignment: .trailing) {
                if model.hasLoaded {
                    Text(model.countText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .background(.bar)
                }
            }
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            VPhoneAppInfoView(model: model)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 520)
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search Apps"))
        .searchFocused($isSearchFocused)
        .guestToolShortcuts(shortcuts)
        .task { await model.refresh() }
        .task(id: inspectedID) {
            guard model.isInspectorPresented else { return }
            await model.loadDetail(for: inspectedID)
        }
        .onChange(of: model.control.isConnected) { _, connected in
            if connected {
                Task { await model.refresh() }
            }
        }
        .onAppear(perform: applySearchFocusRequest)
        .onChange(of: model.isSearchFocusRequested) { _, _ in applySearchFocusRequest() }
        .confirmationDialog(
            uninstallTitle,
            isPresented: $model.isConfirmingUninstall,
            titleVisibility: .visible,
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await model.uninstallConfirmed() }
            }
            Button("Cancel", role: .cancel) { model.uninstallCandidates = [] }
        } message: {
            Text("The app, its data container and its plug-ins' data are removed from the guest. This cannot be undone.")
        }
        .sheet(item: $model.openURLTarget) { app in
            VPhoneAppOpenURLSheet(model: model, app: app)
        }
        .fileImporter(
            isPresented: $model.isImportingPackage,
            allowedContentTypes: VPhoneInstallPackage.allowedContentTypes,
        ) { result in
            guard case let .success(url) = result else { return }
            Task { await model.install(packageAt: url) }
        }
    }

    /// The inspector follows the selection while it is open.
    private var inspectedID: VPhoneAppRecord.ID? {
        model.isInspectorPresented ? model.selectedApp?.id : nil
    }

    private var uninstallTitle: String {
        let targets = model.uninstallCandidates
        if targets.count == 1, let app = targets.first {
            return String(localized: "Uninstall “\(app.displayName)”?", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "Uninstall \(targets.count) apps?", bundle: VPhoneLocalization.bundle)
    }

    private func applySearchFocusRequest() {
        guard model.isSearchFocusRequested else { return }
        model.isSearchFocusRequested = false
        Task { isSearchFocused = true }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            if model.activity != nil {
                ProgressView()
            } else if !model.control.isConnected {
                VPhonePanelEmptyState(
                    title: "Guest Not Connected",
                    systemImage: "bolt.horizontal.circle",
                    message: "Start the VM and wait for the guest to connect. The app list loads automatically.",
                )
            } else if model.loadFailed {
                VPhonePanelEmptyState(
                    title: "Unable to Load Apps",
                    systemImage: "exclamationmark.triangle",
                    message: "Check the guest connection, then choose Refresh.",
                )
            } else {
                ProgressView()
            }
        } else {
            appTable
        }
    }

    private var appTable: some View {
        Table(of: VPhoneAppRecord.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.displayName) { app in
                Text(app.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(app.displayName)
            }
            .width(min: 100, ideal: 120, max: .infinity)

            TableColumn("Bundle ID", value: \.bundleID) { app in
                VPhonePanelMonoText(app.bundleID)
            }
            .width(min: 130, ideal: 160, max: .infinity)

            TableColumn("Version", value: \.version) { app in
                VPhonePanelMonoText(app.version.isEmpty ? "—" : app.version, secondary: app.version.isEmpty)
            }
            .width(min: 52, ideal: 64, max: 140)

            TableColumn("Type", value: \.type) { app in
                Text(app.typeTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 48, ideal: 56, max: 90)

            TableColumn("PID", value: \.pid) { app in
                HStack(spacing: 4) {
                    Circle()
                        .fill(app.isRunning ? Color.green : Color.clear)
                        .frame(width: 6, height: 6)
                    VPhonePanelMonoText(app.isRunning ? String(app.pid) : "—", secondary: !app.isRunning)
                }
                .accessibilityLabel(app.isRunning ? Text("Running, PID \(app.pid)") : Text("Not running"))
            }
            .width(min: 60, ideal: 64, max: 100)
        } rows: {
            ForEach(model.filteredApps) { app in
                TableRow(app)
            }
        }
        .contextMenu(forSelectionType: VPhoneAppRecord.ID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            guard ids.count == 1 else { return }
            model.selection = ids
            model.isInspectorPresented = true
        }
        .overlay {
            if model.filteredApps.isEmpty {
                VPhonePanelEmptyState(
                    title: "No Apps",
                    systemImage: "app.dashed",
                    message: model.searchText.isEmpty
                        ? "No apps match this filter."
                        : "No apps match your search.",
                )
            }
        }
    }

    // MARK: - Row Menu

    @ViewBuilder
    private func rowMenu(_ ids: Set<VPhoneAppRecord.ID>) -> some View {
        let targets = model.apps(ids)
        let single = targets.count == 1 ? targets.first : nil

        Button("Launch") {
            if let single {
                Task { await model.launch(single) }
            }
        }
        .disabled(!model.canLaunch(ids))
        Button("Terminate") {
            Task { await model.terminate(targets) }
        }
        .disabled(!model.canTerminate(ids))
        Button("Open URL…") {
            if let single {
                model.requestOpenURL(single)
            }
        }
        .disabled(!model.canLaunch(ids))

        Divider()

        Button("Show Info") {
            model.selection = ids
            model.isInspectorPresented = true
        }
        .disabled(single == nil)
        Button("Show Data Container") {
            if let single {
                Task { await model.showDataContainer(single) }
            }
        }
        .disabled(single == nil || !model.control.isConnected)

        Divider()

        Button("Copy Bundle ID") { model.copy(targets.map(\.bundleID)) }
        Button("Copy Path") { model.copy(targets.map(\.bundlePath)) }
            .disabled(targets.allSatisfy(\.bundlePath.isEmpty))

        Divider()

        Button("Uninstall…", role: .destructive) { model.requestUninstall(targets) }
            .disabled(!model.canUninstall(ids))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Filter", selection: $model.filter) {
                ForEach(VPhoneAppBrowserModel.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Filter apps by type (⌘1, ⌘2, ⌘3, ⌘4)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button("Launch", systemImage: "play") {
                if let app = model.selectedApp {
                    Task { await model.launch(app) }
                }
            }
            .help("Launch the selected app (⌘↩)")
            .disabled(!model.canLaunch(model.selection))

            Button("Terminate", systemImage: "stop") {
                Task { await model.terminate(model.apps(model.selection)) }
            }
            .help("Terminate the selected apps (⌥⌘Q)")
            .disabled(!model.canTerminate(model.selection))

            Button("Install App Package", systemImage: "square.and.arrow.down") {
                model.isImportingPackage = true
            }
            .help("Install an IPA or TIPA package (⌘O)")
            .disabled(model.isBusy || !model.control.isConnected)

            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .help("Reload the app list (⌘R)")
            .disabled(model.isBusy)

            Button("App Info", systemImage: "info.circle") {
                model.isInspectorPresented.toggle()
            }
            .help("Show or hide app info (⌘I)")
        }
    }

    private var shortcuts: [VPhoneGuestToolShortcut] {
        let filters = VPhoneAppBrowserModel.Filter.allCases.map { filter in
            VPhoneGuestToolShortcut(key: filter.shortcut) { model.filter = filter }
        }
        return filters + [
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isBusy) {
                Task { await model.refresh() }
            },
            VPhoneGuestToolShortcut(key: "i") { model.isInspectorPresented.toggle() },
            VPhoneGuestToolShortcut(key: .return, isEnabled: model.canLaunch(model.selection)) {
                if let app = model.selectedApp {
                    Task { await model.launch(app) }
                }
            },
            VPhoneGuestToolShortcut(key: "q", modifiers: [.command, .option], isEnabled: model.canTerminate(model.selection)) {
                Task { await model.terminate(model.apps(model.selection)) }
            },
            VPhoneGuestToolShortcut(key: .delete, isEnabled: model.canUninstall(model.selection)) {
                model.requestUninstall(model.apps(model.selection))
            },
            VPhoneGuestToolShortcut(key: "o", isEnabled: !model.isBusy && model.control.isConnected) {
                model.isImportingPackage = true
            },
        ]
    }
}

// MARK: - Open URL Sheet

/// Opens a URL in one app through `apps.open_url`.
struct VPhoneAppOpenURLSheet: View {
    @Bindable var model: VPhoneAppBrowserModel
    let app: VPhoneAppRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open URL in \(app.displayName)")
                .font(.headline)
            TextField("URL", text: $model.openURLText, prompt: Text(verbatim: "scheme://path"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(open)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.openURLText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func open() {
        let url = model.openURLText
        dismiss()
        Task { await model.openURL(url, in: app) }
    }
}
