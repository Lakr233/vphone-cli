import SwiftUI

struct VPhoneAppBrowserView: View {
    @Bindable var model: VPhoneAppBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if model.isLoading, model.apps.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredApps.isEmpty {
                ContentUnavailableView(
                    "No Apps",
                    systemImage: "app.dashed",
                    description: Text(model.searchText.isEmpty ? "No apps found." : "No matching apps.")
                )
            } else {
                appTable
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter by name or bundle ID")
        .task { await model.refresh() }
        .onChange(of: model.control.isConnected) { _, connected in
            if connected {
                Task { await model.refresh() }
            }
        }
        .alert(
            "Error",
            isPresented: .init(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )
        ) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $model.filter) {
                ForEach(VPhoneAppBrowserModel.AppFilter.allCases, id: \.self) { f in
                    Text(f.rawValue.capitalized).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            Spacer()

            Text("\(model.filteredApps.count) apps")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.filter) {
            Task { await model.refresh() }
        }
    }

    // MARK: - Table

    private var appTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.filteredApps.enumerated()), id: \.element.bundleId) { index, app in
                    appRow(app)
                        .background(index % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                }
            }
        }
    }

    private func appRow(_ app: VPhoneControl.AppInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name.isEmpty ? app.bundleId : app.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if !app.version.isEmpty {
                        Text("v\(app.version)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text(app.type)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            app.type == "system"
                                ? Color.blue.opacity(0.15) : Color.green.opacity(0.15)
                        )
                        .cornerRadius(3)
                }

                Text(app.bundleId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            if app.pid > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("pid \(app.pid)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
