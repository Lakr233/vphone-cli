import AppKit
import SwiftUI

struct VPhoneCrashLogsView: View {
    @Bindable var model: VPhoneCrashLogsModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                listPane
                    .frame(minWidth: 470, maxHeight: .infinity)
                detailPane
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.control.isConnected,
                activity: model.activity?.title,
                status: model.status,
            )
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Filter by process or name"))
        .guestToolShortcuts([
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isBusy) {
                Task { await model.refresh() }
            },
            VPhoneGuestToolShortcut(key: "c", modifiers: [.command, .shift], isEnabled: model.canCopy) {
                model.copyFocusedReport()
            },
            VPhoneGuestToolShortcut(key: "s", isEnabled: model.canExport) {
                export(model.selection)
            },
        ])
        .task { await model.refresh() }
        .onChange(of: model.selection) { _, _ in model.loadSelection() }
        .onChange(of: model.control.isConnected) { _, connected in
            guard connected, !model.hasLoaded else { return }
            Task { await model.refresh() }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Copy", systemImage: "doc.on.doc") { model.copyFocusedReport() }
                .help("Copy the full report text (⇧⌘C)")
                .disabled(!model.canCopy)
            Button("Export…", systemImage: "square.and.arrow.up") { export(model.selection) }
                .help("Save the selected reports to the Mac (⌘S)")
                .disabled(!model.canExport)
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("Reload the list of crash reports (⌘R)")
                .disabled(model.isBusy)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listPane: some View {
        let rows = model.visibleReports
        if !model.hasLoaded {
            if model.activity == .listing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.control.isConnected {
                VPhonePanelEmptyState(
                    title: "Guest Not Connected",
                    systemImage: "network.slash",
                    message: "Crash reports appear here once the guest connects.",
                )
            } else {
                VPhonePanelEmptyState(
                    title: "No Crash Reports Loaded",
                    systemImage: "exclamationmark.octagon",
                    message: "Choose Refresh to list the guest's crash reports.",
                )
            }
        } else if model.reports.isEmpty {
            VPhonePanelEmptyState(
                title: "No Crash Reports",
                systemImage: "checkmark.seal",
                message: "The guest has no reports in CrashReporter or DiagnosticReports.",
            )
        } else if rows.isEmpty {
            VPhonePanelEmptyState(
                title: "No Matching Reports",
                systemImage: "magnifyingglass",
                message: "No process or file name contains that text.",
            )
        } else {
            table(rows)
        }
    }

    private func table(_ rows: [VPhoneCrashReport]) -> some View {
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Date", value: \.mtime) { report in
                VPhonePanelMonoText(report.dateText)
            }
            .width(134)

            TableColumn("Process", value: \.process) { report in
                VPhonePanelMonoText(report.process)
            }
            .width(min: 72, ideal: 88)

            TableColumn("Type", value: \.kindTitle) { report in
                Text(report.kindTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(report.name)
            }
            .width(min: 76, ideal: 80, max: 130)

            TableColumn("Size", value: \.size) { report in
                VPhonePanelMonoText(report.sizeText, secondary: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: VPhoneCrashReport.ID.self) { ids in
            if !ids.isEmpty {
                let reports = model.reports(for: ids)
                Button("Copy Path") { model.copy(reports.map(\.path)) }
                Button("Copy Name") { model.copy(reports.map(\.name)) }
                Divider()
                Button("Export…") { export(ids) }
                    .disabled(model.isBusy)
            }
        }
        .accessibilityLabel("Crash reports")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let report = model.focusedReport {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(report, content: model.contents[report.path])
                Divider()
                detailBody(report)
            }
        } else if model.selection.count > 1 {
            VPhonePanelEmptyState(
                title: "\(model.selection.count) Reports Selected",
                systemImage: "doc.on.doc",
                message: "Choose Export to save each report to a folder.",
            )
        } else {
            VPhonePanelEmptyState(
                title: "No Report Selected",
                systemImage: "doc.text.magnifyingglass",
                message: "Select a report to read it.",
            )
        }
    }

    private func detailHeader(_ report: VPhoneCrashReport, content: VPhoneCrashReportContent?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(report.name)
                    Text(report.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .help(report.path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Toggle("Wrap Lines", isOn: $model.wrapLines)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Wrap long lines to the width of the pane")
            }

            if let header = content?.header {
                summary(header)
            }

            if content?.truncated == true {
                Label("The guest sent only part of this report.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private func summary(_ header: VPhoneCrashReportContent.Header) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
            if let value = header.appName {
                summaryRow("App", value)
            }
            if let value = header.bugType {
                summaryRow("Bug Type", value)
            }
            if let value = header.osVersion {
                summaryRow("OS Version", value)
            }
            if let value = header.timestamp {
                summaryRow("Timestamp", value)
            }
            if let value = header.incidentID {
                summaryRow("Incident ID", value)
            }
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title, bundle: VPhoneLocalization.bundle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func detailBody(_ report: VPhoneCrashReport) -> some View {
        if let content = model.contents[report.path] {
            VPhoneCrashReportTextView(identity: content.path, text: content.displayText, wrapLines: model.wrapLines)
        } else if let message = model.loadErrors[report.path], !model.loadingPaths.contains(report.path) {
            ContentUnavailableView {
                Label("Unable to Load Report", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retryFocusedReport() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading report…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Export

    /// One report goes through a save panel under its guest file name;
    /// several go into a folder the user picks.
    private func export(_ ids: Set<VPhoneCrashReport.ID>) {
        let reports = model.reports(for: ids)
        guard !reports.isEmpty, !model.isBusy else { return }
        if reports.count == 1, let report = reports.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = report.name
            panel.canCreateDirectories = true
            VPhoneAlert.present(panel, on: NSApp.keyWindow) { response in
                guard response == .OK, let url = panel.url else { return }
                Task { await model.export(report, to: url) }
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = VPhoneLocalization.text("Export Here")
            panel.message = VPhoneLocalization.text("Choose a folder for the selected reports.")
            VPhoneAlert.present(panel, on: NSApp.keyWindow) { response in
                guard response == .OK, let url = panel.url else { return }
                Task { await model.export(reports, toDirectory: url) }
            }
        }
    }
}
