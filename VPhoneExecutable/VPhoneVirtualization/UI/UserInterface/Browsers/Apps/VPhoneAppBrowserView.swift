import SwiftUI

struct VPhoneAppBrowserView: View {
    @Bindable var model: VPhoneAppBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading, model.apps.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                appTable
            }

            statusBar
        }
        .task { await model.refresh() }
        .onChange(of: model.control.isConnected) { _, connected in
            if connected {
                Task { await model.refresh() }
            }
        }
        .onChange(of: model.filter) { _, _ in model.selection.removeAll() }
        .onChange(of: model.searchText) { _, _ in model.selection.removeAll() }
        .alert(
            "Error",
            isPresented: .init(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } },
            ),
        ) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    // MARK: - Table

    private var appTable: some View {
        Table(of: VPhoneGuestControl.AppInfo.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { app in
                Text(app.name.isEmpty ? app.bundleId : app.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 190, max: .infinity)

            TableColumn("Bundle ID", value: \.bundleId) { app in
                Text(app.bundleId)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(app.bundleId)
            }
            .width(min: 170, ideal: 260, max: .infinity)

            TableColumn("Version", value: \.version) { app in
                Text(app.version.isEmpty ? "—" : app.version)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Type", value: \.type) { app in
                Text(app.type.capitalized)
            }
            .width(min: 60, ideal: 80, max: 100)

            TableColumn("Status", value: \.pid) { app in
                Text(app.pid > 0 ? "Running · PID \(app.pid)" : "Not running")
                    .foregroundStyle(app.pid > 0 ? .primary : .secondary)
            }
            .width(min: 120, ideal: 150, max: 180)
        } rows: {
            ForEach(model.filteredApps) { app in
                TableRow(app)
            }
        }
        .contextMenu(forSelectionType: VPhoneGuestControl.AppInfo.ID.self) { ids in
            Button("Copy Bundle ID") {
                let values = model.filteredApps
                    .filter { ids.contains($0.id) }
                    .map(\.bundleId)
                    .joined(separator: "\n")
                guard !values.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(values, forType: .string)
            }
        }
        .overlay {
            if model.filteredApps.isEmpty {
                ContentUnavailableView(
                    "No Apps",
                    systemImage: "app.dashed",
                    description: Text(
                        model.searchText.isEmpty
                            ? "No apps are available for this filter."
                            : "No apps match your search.",
                    ),
                )
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(model.control.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(model.filteredApps.count == 1 ? "1 app" : "\(model.filteredApps.count) apps")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.bar)
    }
}
