import SwiftUI

struct VPhoneConsoleView: View {
    @Bindable var model: VPhoneConsoleModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.visibleEntries.isEmpty {
                emptyState
            } else {
                VSplitView {
                    table
                        .frame(minHeight: 120, idealHeight: 420, maxHeight: .infinity)
                        .layoutPriority(1)
                    detail
                        .frame(minHeight: 64, idealHeight: 120, maxHeight: 360)
                }
            }
            Divider()
            statusBar
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search"))
        .searchFocused($searchFocused)
        .guestToolShortcuts([
            VPhoneGuestToolShortcut(key: "p") { model.toggleRunning() },
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isRunning && !model.isCapturing && model.control.isConnected) {
                Task { await model.captureOnce() }
            },
            VPhoneGuestToolShortcut(key: "k", isEnabled: !model.entries.isEmpty) { model.clear() },
            VPhoneGuestToolShortcut(key: "s", isEnabled: !model.visibleEntries.isEmpty) { model.save() },
            VPhoneGuestToolShortcut(key: "f") { searchFocused = true },
        ])
        .task { await model.run() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.toggleRunning()
            } label: {
                if model.isRunning {
                    Label("Pause", systemImage: "pause.fill")
                } else {
                    Label("Start", systemImage: "play.fill")
                }
            }
            .help(model.isRunning ? "Pause streaming (⌘P)" : "Start streaming (⌘P)")

            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.captureOnce() }
            }
            .help("Capture 2 seconds of log while paused (⌘R)")
            .disabled(model.isRunning || model.isCapturing || !model.control.isConnected)

            Button("Clear", systemImage: "trash") { model.clear() }
                .help("Clear all loaded entries (⌘K)")
                .disabled(model.entries.isEmpty)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            TextField("Process", text: $model.processFilter, prompt: Text("Process"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 104)
                .help("Capture only processes whose name contains this text. Applies to the next capture.")

            Picker("Level", selection: $model.levelFilter) {
                ForEach(VPhoneConsoleLevelFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show all levels, errors and faults, or faults only")

            Toggle(isOn: $model.autoScroll) {
                Label("Auto-Scroll", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Keep the newest entry visible")

            Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                .help("Save the shown entries as a plain-text log (⌘S)")
                .disabled(model.visibleEntries.isEmpty)
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var emptyState: some View {
        if !model.entries.isEmpty {
            VPhonePanelEmptyState(
                title: "No Matching Entries",
                systemImage: "line.3.horizontal.decrease.circle",
                message: "No loaded entry matches the search or level filter.",
            )
        } else if !model.control.isConnected {
            VPhonePanelEmptyState(
                title: "Guest Not Connected",
                systemImage: "bolt.horizontal.circle",
                message: "The log streams once the guest connects.",
            )
        } else if model.isRunning {
            VPhonePanelEmptyState(
                title: "Waiting for Log Entries",
                systemImage: "text.alignleft",
                message: "Entries appear here as the guest logs them.",
            )
        } else {
            VPhonePanelEmptyState(
                title: "Streaming Paused",
                systemImage: "pause.circle",
                message: "Choose Start to stream the guest unified log.",
            )
        }
    }

    private var table: some View {
        ScrollViewReader { proxy in
            Table(model.visibleEntries, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("Time", value: \.id) { entry in
                    VPhonePanelMonoText(entry.time, secondary: true)
                }
                .width(min: 88, ideal: 92, max: 120)

                TableColumn("Level", value: \.level) { entry in
                    VPhoneConsoleLevelLabel(level: entry.level)
                }
                .width(min: 56, ideal: 60, max: 84)

                TableColumn("Process", value: \.process) { entry in
                    VPhonePanelMonoText(entry.process)
                }
                .width(min: 72, ideal: 100, max: 240)

                TableColumn("PID", value: \.pid) { entry in
                    Text(verbatim: "\(entry.pid)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 40, ideal: 48, max: 72)

                TableColumn("Subsystem", value: \.subsystem) { entry in
                    VPhonePanelMonoText(entry.subsystem, secondary: true)
                }
                .width(min: 72, ideal: 116, max: 320)

                TableColumn("Category", value: \.category) { entry in
                    VPhonePanelMonoText(entry.category, secondary: true)
                }
                .width(min: 56, ideal: 72, max: 200)

                TableColumn("Message", value: \.message) { entry in
                    Text(entry.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.message.count > 2000 ? String(entry.message.prefix(2000)) + "…" : entry.message)
                }
                .width(min: 140)
            }
            .contextMenu(forSelectionType: VPhoneConsoleEntry.ID.self) { ids in
                contextMenu(ids)
            }
            .onChange(of: model.newestVisibleID) { _, _ in scrollToNewest(proxy) }
            .onChange(of: model.autoScroll) { _, _ in scrollToNewest(proxy) }
            .onAppear { scrollToNewest(proxy) }
            .accessibilityLabel("Guest log entries")
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<VPhoneConsoleEntry.ID>) -> some View {
        let rows = model.selectedEntries(ids)
        if !rows.isEmpty {
            if rows.count == 1, let entry = rows.first {
                Button("Copy Message") { model.copy(entry.message) }
            }
            Button(rows.count == 1 ? "Copy Line" : "Copy Lines") { model.copy(model.logText(rows)) }
            if rows.count == 1, let entry = rows.first, !entry.process.isEmpty {
                Divider()
                Button("Capture Only \(entry.process)") { model.showOnlyProcess(of: entry) }
            }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard model.autoScroll, let id = model.newestVisibleID else { return }
        proxy.scrollTo(id, anchor: .bottomLeading)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    VPhoneConsoleLevelLabel(level: entry.level)
                    Text(verbatim: model.fullDate(entry))
                    Text(verbatim: "\(entry.process)[\(entry.pid)]")
                    if let origin = entry.origin {
                        Text(verbatim: origin)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    Text(entry.message)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            Text(model.selection.count > 1 ? "\(model.selection.count) entries selected." : "Select an entry to see its full message.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 0) {
            VPhoneGuestToolStatusBar(
                isConnected: model.control.isConnected,
                activity: model.isRunning && model.control.isConnected && model.status == nil
                    ? String(localized: "Streaming…", bundle: VPhoneLocalization.bundle)
                    : nil,
                status: model.status,
            )
            HStack(spacing: 8) {
                if model.lastCaptureTruncated {
                    Text("Truncated")
                        .foregroundStyle(.orange)
                        .help("The last capture reached \(VPhoneConsoleModel.captureMaxLines) entries; the guest dropped the rest.")
                }
                Text(countText)
                    .foregroundStyle(.secondary)
                Text(model.isRunning ? "Running" : "Paused")
                    .foregroundStyle(model.isRunning ? .green : .secondary)
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.bar)
        }
    }

    private var countText: String {
        let loaded = model.entries.count
        if model.isFiltered {
            return String(localized: "\(model.visibleEntries.count) of \(loaded) entries", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "\(loaded) entries", bundle: VPhoneLocalization.bundle)
    }
}

// MARK: - Level Label

/// A colored dot and the level name: fault red, error orange, others secondary.
struct VPhoneConsoleLevelLabel: View {
    let level: VPhoneConsoleLevel

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(level.color)
                .frame(width: 6, height: 6)
            Text(level.title)
                .foregroundStyle(level >= .error ? level.color : .secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
    }
}
