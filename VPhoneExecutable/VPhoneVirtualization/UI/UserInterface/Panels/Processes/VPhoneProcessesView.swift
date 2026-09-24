import SwiftUI

struct VPhoneProcessesView: View {
    @Bindable var model: VPhoneProcessesModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.control.isConnected,
                activity: model.activity?.title,
                status: model.control.isConnected || model.status != nil ? model.displayedStatus : nil,
            )
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search Processes"))
        .searchFocused($searchFocused)
        .guestToolShortcuts([
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isBusy) {
                Task { await model.refresh() }
            },
            // ⌘⌫ stays with the search field while it is being edited.
            VPhoneGuestToolShortcut(key: .delete, isEnabled: model.canSignal && !searchFocused) {
                model.requestSignal(.term)
            },
        ])
        .task(id: model.autoRefresh) {
            await model.refresh()
            while model.autoRefresh, !Task.isCancelled {
                try? await Task.sleep(for: VPhoneProcessesModel.autoRefreshInterval)
                guard !Task.isCancelled else { return }
                await model.refresh(automatic: true)
            }
        }
        .confirmationDialog(
            model.pendingSignal?.title ?? "",
            isPresented: Binding(
                get: { model.pendingSignal != nil },
                set: {
                    if !$0 {
                        model.pendingSignal = nil
                    }
                },
            ),
            presenting: model.pendingSignal,
        ) { request in
            Button(request.confirmTitle, role: request.signal.isDestructive ? .destructive : nil) {
                Task { await model.send(request) }
            }
            Button("Cancel", role: .cancel) { model.pendingSignal = nil }
        } message: { request in
            Text(request.message)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.autoRefresh) {
                Label("Auto Refresh", systemImage: "timer")
            }
            .toggleStyle(.button)
            .help("Refresh every 3 seconds while this window is open")

            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("Reload the process list (⌘R)")
                .disabled(model.isBusy)

            Button("Terminate", systemImage: "xmark.octagon") { model.requestSignal(.term) }
                .help("Send SIGTERM to the selected processes (⌘⌫)")
                .disabled(!model.canSignal)

            Menu {
                ForEach(VPhoneProcessSignal.menuSignals) { signal in
                    Button(signal.menuTitle) { model.requestSignal(signal) }
                }
            } label: {
                Label("Signal", systemImage: "bolt")
            }
            .help("Send another signal to the selected processes")
            .disabled(!model.canSignal)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            if model.isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.control.isConnected {
                VPhonePanelEmptyState(
                    title: "Guest Not Connected",
                    systemImage: "cpu",
                    message: "Processes appear here once vphoned is running in the guest.",
                )
            } else {
                VPhonePanelEmptyState(
                    title: "No Processes Loaded",
                    systemImage: "cpu",
                    message: "Choose Refresh to list the guest's processes.",
                )
            }
        } else if model.visibleRows.isEmpty {
            if model.trimmedSearch.isEmpty {
                VPhonePanelEmptyState(title: "No Processes", systemImage: "cpu")
            } else {
                VPhonePanelEmptyState(
                    title: "No Matching Processes",
                    systemImage: "magnifyingglass",
                    message: "No process name, bundle ID, path or PID matches the search.",
                )
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(model.visibleRows, selection: $model.selection, sortOrder: $model.sortOrder) {
            identityColumns
            usageColumns
        }
        .contextMenu(forSelectionType: VPhoneProcessRow.ID.self) { pids in
            if !pids.isEmpty {
                Button("Copy PID") { model.copy({ String($0.pid) }, pids: pids) }
                Button("Copy Name") { model.copy(\.displayName, pids: pids) }
                Button("Copy Executable Path") { model.copy(\.executable, pids: pids) }
                Button("Copy Bundle ID") { model.copy(\.bundleID, pids: pids) }
                Divider()
                Button("Terminate…") { model.requestSignal(.term, pids: pids) }
                    .disabled(model.isBusy)
                Button("Kill…") { model.requestSignal(.kill, pids: pids) }
                    .disabled(model.isBusy)
            }
        }
        .accessibilityLabel("Guest processes")
    }

    // MARK: - Columns

    typealias Comparator = KeyPathComparator<VPhoneProcessRow>

    @TableColumnBuilder<VPhoneProcessRow, Comparator>
    private var identityColumns: some TableColumnContent<VPhoneProcessRow, Comparator> {
        TableColumn("PID", value: \VPhoneProcessRow.pid) { row in
            number(String(row.pid))
        }
        .width(min: 44, ideal: 44, max: 80)

        TableColumn("Name", value: \VPhoneProcessRow.nameSortKey) { row in
            VPhonePanelMonoText(row.displayName)
        }
        .width(min: 90, ideal: 150)

        TableColumn("Bundle ID", value: \VPhoneProcessRow.bundleSortKey) { row in
            VPhonePanelMonoText(row.bundleTitle, secondary: row.bundleID == nil)
        }
        .width(min: 70, ideal: 160)

        TableColumn("User", value: \VPhoneProcessRow.uidSortKey) { row in
            VPhonePanelMonoText(row.userTitle)
        }
        .width(min: 40, ideal: 48, max: 90)

        TableColumn("PPID", value: \VPhoneProcessRow.ppidSortKey) { row in
            number(row.ppidTitle, secondary: true)
        }
        .width(min: 36, ideal: 36, max: 80)

        TableColumn("Memory", value: \VPhoneProcessRow.footprintSortKey) { row in
            number(row.footprintTitle)
        }
        .width(min: 60, ideal: 64, max: 120)
    }

    @TableColumnBuilder<VPhoneProcessRow, Comparator>
    private var usageColumns: some TableColumnContent<VPhoneProcessRow, Comparator> {
        TableColumn("Resident", value: \VPhoneProcessRow.residentSortKey) { row in
            number(row.residentTitle, secondary: true)
        }
        .width(min: 52, ideal: 60, max: 120)

        TableColumn("CPU Time", value: \VPhoneProcessRow.cpuSortKey) { row in
            number(row.cpuTitle)
        }
        .width(min: 56, ideal: 64, max: 120)

        TableColumn("Jetsam Priority", value: \VPhoneProcessRow.jetsamPrioritySortKey) { row in
            number(row.jetsamPriorityTitle)
        }
        .width(min: 44, ideal: 84, max: 110)

        TableColumn("Limit", value: \VPhoneProcessRow.jetsamLimitSortKey) { row in
            number(row.jetsamLimitTitle, secondary: true)
        }
        .width(min: 44, ideal: 60, max: 110)

        TableColumn("Started", value: \VPhoneProcessRow.startSortKey) { row in
            VPhonePanelMonoText(row.startedTitle, secondary: true)
                .help(row.startedHelp)
        }
        .width(min: 44, ideal: 72, max: 140)

        TableColumn("Executable", value: \VPhoneProcessRow.executableSortKey) { row in
            VPhonePanelMonoText(row.executableTitle, secondary: true)
        }
        .width(min: 120, ideal: 180)
    }

    /// A right-aligned monospaced number cell.
    private func number(_ value: String, secondary: Bool = false) -> some View {
        VPhonePanelMonoText(value, secondary: secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
