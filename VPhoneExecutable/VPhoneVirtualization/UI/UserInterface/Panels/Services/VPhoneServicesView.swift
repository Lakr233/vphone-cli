import SwiftUI

struct VPhoneServicesView: View {
    @Bindable var model: VPhoneServicesModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.isConnected,
                activity: model.activity,
                status: model.status,
            )
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Label or Program"))
        .toolbar { toolbar }
        .guestToolShortcuts(shortcuts)
        .confirmationDialog(
            model.pendingAction.map { $0.action.confirmationTitle($0.label) } ?? "",
            isPresented: isConfirming,
            titleVisibility: .visible,
            presenting: model.pendingAction,
        ) { pending in
            Button(pending.action.confirmationButton, role: .destructive) {
                Task { await model.perform(pending.action, on: pending.label) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.action.confirmationMessage)
        }
        .task { await model.monitorConnection() }
        .task(id: model.selection) { await model.loadDetail() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let row = model.selectedRow
            Button("Start", systemImage: VPhoneServiceAction.start.systemImage) { request(.start) }
                .help("Start the selected service")
                .disabled(!model.canPerform(.start, on: row))
            Button("Stop", systemImage: VPhoneServiceAction.stop.systemImage) { request(.stop) }
                .help("Stop the selected service")
                .disabled(!model.canPerform(.stop, on: row))
            Button("Restart", systemImage: VPhoneServiceAction.restart.systemImage) { request(.restart) }
                .help("Stop the selected service, then start it again")
                .disabled(!model.canPerform(.restart, on: row))
            Menu {
                if let row {
                    actionItems(for: row, includeStartStop: false)
                }
            } label: {
                Label("More Actions", systemImage: "ellipsis.circle")
            }
            .help("Enable, disable, signal, or remove the selected service")
            .disabled(row == nil || model.isBusy || !model.isConnected)
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("Reload the service list (⌘R)")
                .disabled(model.isBusy || !model.isConnected)
        }
    }

    private var shortcuts: [VPhoneGuestToolShortcut] {
        var shortcuts = [
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isBusy && model.isConnected) {
                Task { await model.refresh() }
            },
        ]
        for (index, filter) in VPhoneServicesModel.Filter.allCases.enumerated() {
            shortcuts.append(VPhoneGuestToolShortcut(key: KeyEquivalent(Character(String(index + 1)))) {
                model.filter = filter
            })
        }
        return shortcuts
    }

    // MARK: - Filter

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Filter", selection: $model.filter) {
                ForEach(VPhoneServicesModel.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show all, running, stopped, or disabled services (⌘1–⌘4)")

            Spacer(minLength: 8)

            if model.hasLoaded {
                Text("\(model.visibleRows.count) of \(model.rows.count) services, \(model.runningCount) running")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty {
            if model.isBusy, !model.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.isConnected {
                VPhonePanelEmptyState(
                    title: "Guest Not Connected",
                    systemImage: "bolt.horizontal.circle",
                    message: "The service list loads when vphoned connects.",
                )
            } else if model.hasLoaded {
                VPhonePanelEmptyState(
                    title: "No Services",
                    systemImage: "gearshape.2",
                    message: "launchd reported no services.",
                )
            } else {
                VPhonePanelEmptyState(
                    title: "Services Not Loaded",
                    systemImage: "gearshape.2",
                    message: "Choose Refresh to load the service list.",
                )
            }
        } else {
            VSplitView {
                table
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .layoutPriority(1)
                VPhoneServiceDetailView(model: model)
                    .frame(minHeight: 190, idealHeight: 230)
            }
        }
    }

    private var table: some View {
        Table(model.visibleRows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Label", value: \.label) { row in
                VPhonePanelMonoText(row.label)
            }
            .width(min: 160, ideal: 180)

            TableColumn("State", value: \.stateRank) { row in
                VPhoneServiceStateLabel(isRunning: row.isRunning)
                    .font(.system(size: 11, design: .monospaced))
            }
            .width(min: 72, ideal: 72, max: 88)

            TableColumn("PID", value: \.pidValue) { row in
                VPhonePanelMonoText(row.pidText, secondary: row.pid == nil)
            }
            .width(min: 44, ideal: 48, max: 64)

            TableColumn("Last Exit", value: \.lastExitValue) { row in
                let exit = row.lastExit
                Text(exit.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(exit.isAbnormal ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(exit.help)
            }
            .width(min: 56, ideal: 60, max: 84)

            TableColumn("Disabled", value: \.disabledRank) { row in
                Text(row.disabledText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(row.disabled == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .width(min: 56, ideal: 60, max: 72)

            TableColumn("Domains", value: \.domainText) { row in
                VPhonePanelMonoText(row.domainText, secondary: true)
            }
            .width(min: 64, ideal: 88, max: 110)

            TableColumn("Program", value: \.programText) { row in
                VPhonePanelMonoText(row.program ?? "—", secondary: row.program == nil)
            }
            .width(min: 100, ideal: 120)
        }
        .contextMenu(forSelectionType: VPhoneServiceRow.ID.self) { labels in
            if let label = labels.first, let row = model.row(label) {
                Button("Copy Label") { model.copy(row.label) }
                Button("Copy Program Path") { model.copy(row.program ?? "") }
                    .disabled(row.program == nil)
                Divider()
                actionItems(for: row, includeStartStop: true)
            }
        }
        .overlay {
            if model.visibleRows.isEmpty {
                VPhonePanelEmptyState(
                    title: "No Matching Services",
                    systemImage: "magnifyingglass",
                    message: "No service matches the filter and search.",
                )
            }
        }
        .accessibilityLabel("launchd services")
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionItems(for row: VPhoneServiceRow, includeStartStop: Bool) -> some View {
        if includeStartStop {
            Button("Start") { model.request(.start, on: row.label) }
                .disabled(!model.canPerform(.start, on: row))
            Button("Stop…") { model.request(.stop, on: row.label) }
                .disabled(!model.canPerform(.stop, on: row))
            Button("Restart…") { model.request(.restart, on: row.label) }
                .disabled(!model.canPerform(.restart, on: row))
            Divider()
        }
        Button("Enable") { model.request(.enable, on: row.label) }
            .disabled(!model.canPerform(.enable, on: row))
        Button("Disable…") { model.request(.disable, on: row.label) }
            .disabled(!model.canPerform(.disable, on: row))
        Menu("Send Signal") {
            ForEach(VPhoneServiceSignal.allCases) { signal in
                Button {
                    model.request(.signal(signal), on: row.label)
                } label: {
                    Text(verbatim: signal.title + "…")
                }
            }
        }
        .disabled(!model.canPerform(.signal(.term), on: row))
        Divider()
        Button("Remove…", role: .destructive) { model.request(.remove, on: row.label) }
            .disabled(!model.canPerform(.remove, on: row))
    }

    private func request(_ action: VPhoneServiceAction) {
        guard let label = model.selection else { return }
        model.request(action, on: label)
    }

    private var isConfirming: Binding<Bool> {
        Binding(
            get: { model.pendingAction != nil },
            set: {
                if !$0 {
                    model.pendingAction = nil
                }
            },
        )
    }
}

// MARK: - State Label

/// Running or Stopped with a small status dot.
struct VPhoneServiceStateLabel: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 6, height: 6)
            Text(isRunning ? "Running" : "Stopped")
                .foregroundStyle(isRunning ? .primary : .secondary)
                .lineLimit(1)
        }
    }
}
