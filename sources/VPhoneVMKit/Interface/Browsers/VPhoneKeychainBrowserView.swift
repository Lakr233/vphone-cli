import SwiftUI

struct VPhoneKeychainBrowserView: View {
    @Bindable var model: VPhoneKeychainBrowserModel

    private let controlBarHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            tableView
                .padding(.bottom, controlBarHeight)
                .overlay(controlBar.frame(maxHeight: .infinity, alignment: .bottom))
                .searchable(text: $model.searchText, prompt: "Filter keychain items")
                .toolbar { toolbarContent }

            if model.showDiagnostics {
                Divider()
                diagnosticsPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.refresh() }
        .onChange(of: model.control.isConnected) { _, connected in
            if connected, model.items.isEmpty {
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

    // MARK: - Table

    var tableView: some View {
        Table(of: VPhoneKeychainItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("", value: \.itemClass) { item in
                Image(systemName: item.classIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help(item.displayClass)
            }
            .width(28)

            TableColumn("Class", value: \.itemClass) { item in
                Text(item.displayClass)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, ideal: 80, max: 100)

            TableColumn("Account", value: \.account) { item in
                Text(item.account.isEmpty ? "-" : item.account)
                    .lineLimit(1)
                    .help(item.account)
            }
            .width(min: 80, ideal: 150, max: .infinity)

            TableColumn("Service", value: \.service) { item in
                Text(item.service.isEmpty ? "-" : item.service)
                    .lineLimit(1)
                    .help(item.service)
            }
            .width(min: 80, ideal: 150, max: .infinity)

            TableColumn("Access Group", value: \.accessGroup) { item in
                Text(item.accessGroup.isEmpty ? "-" : item.accessGroup)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(item.accessGroup)
            }
            .width(min: 80, ideal: 160, max: .infinity)

            TableColumn("Protection", value: \.protection) { item in
                Text(item.protection.isEmpty ? "-" : item.protection)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(item.protectionDescription)
            }
            .width(min: 40, ideal: 60, max: 80)

            TableColumn("Value", value: \.value) { item in
                Text(item.displayValue)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(item.displayValue)
            }
            .width(min: 60, ideal: 120, max: .infinity)

            TableColumn("Modified", value: \.displayName) { item in
                Text(item.displayDate)
            }
            .width(min: 80, ideal: 120, max: .infinity)
        } rows: {
            ForEach(model.filteredItems) { item in
                TableRow(item)
            }
        }
        .contextMenu(forSelectionType: VPhoneKeychainItem.ID.self) { ids in
            contextMenu(for: ids)
        }
    }

    // MARK: - Control Bar

    var controlBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.control.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Divider()

            Picker("Class", selection: $model.filterClass) {
                ForEach(VPhoneKeychainBrowserModel.classFilters, id: \.value) { filter in
                    Text(filter.label).tag(filter.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 120)

            Divider()

            Text(model.statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 60)

            Spacer()

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: controlBarHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Diagnostics Panel

    var diagnosticsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(model.diagnostics.count) entries")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button {
                    let text = model.diagnostics.joined(separator: "\n")
                    if !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Copy diagnostics to clipboard")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                                .id(index)
                        }
                    }
                }
                .onChange(of: model.diagnostics.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem {
            Button {
                Task { await model.addTestItem() }
            } label: {
                Label("Add Test", systemImage: "plus.circle")
            }
            .help("Add a test keychain item (debug)")
        }
        ToolbarItem {
            Button {
                copySelected()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(model.selection.isEmpty)
        }
        ToolbarItem {
            Button {
                model.showDiagnostics.toggle()
            } label: {
                Label("Diagnostics", systemImage: model.showDiagnostics ? "ladybug.fill" : "ladybug")
            }
            .help("Toggle diagnostics log panel")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    func contextMenu(for ids: Set<VPhoneKeychainItem.ID>) -> some View {
        Button("Copy Account") { copyField(ids: ids, keyPath: \.account) }
        Button("Copy Service") { copyField(ids: ids, keyPath: \.service) }
        Button("Copy Value") { copyField(ids: ids, keyPath: \.value) }
        Button("Copy Access Group") { copyField(ids: ids, keyPath: \.accessGroup) }
        Button("Copy Protection") { copyField(ids: ids, keyPath: \.protection) }
        Divider()
        Button("Copy Row (TSV)") { copyRows(ids: ids) }
        Divider()
        Button("Refresh") { Task { await model.refresh() } }
    }

    // MARK: - Copy Actions

    func copySelected() {
        let selected = model.filteredItems.filter { model.selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        let header = "Class\tAccount\tService\tAccess Group\tProtection\tValue"
        let rows = selected.map { item in
            "\(item.displayClass)\t\(item.account)\t\(item.service)\t\(item.accessGroup)\t\(item.protection)\t\(item.displayValue)"
        }
        let text = ([header] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyRows(ids: Set<VPhoneKeychainItem.ID>) {
        let selected = model.filteredItems.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let header = "Class\tAccount\tService\tAccess Group\tProtection\tValue"
        let rows = selected.map { item in
            "\(item.displayClass)\t\(item.account)\t\(item.service)\t\(item.accessGroup)\t\(item.protection)\t\(item.displayValue)"
        }
        let text = ([header] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyField(ids: Set<VPhoneKeychainItem.ID>, keyPath: KeyPath<VPhoneKeychainItem, String>) {
        let values = model.filteredItems
            .filter { ids.contains($0.id) }
            .map { $0[keyPath: keyPath] }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values, forType: .string)
    }
}
