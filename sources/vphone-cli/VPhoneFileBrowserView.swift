import SwiftUI
import UniformTypeIdentifiers

struct VPhoneFileBrowserView: View {
    @Bindable var model: VPhoneFileBrowserModel

    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private let controlBarHeight: CGFloat = 24

    var body: some View {
        ZStack {
            tableView
                .padding(.bottom, controlBarHeight)
                .overlay(controlBar.frame(maxHeight: .infinity, alignment: .bottom))
                .opacity(model.isTransferring ? 0.25 : 1)
                .searchable(text: $model.searchText, prompt: "Filter files")
                .onDrop(of: [.fileURL], isTargeted: nil, perform: dropFiles)
                .disabled(model.isTransferring)
                .toolbar { toolbarContent }
            if model.isTransferring {
                progressOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thickMaterial)
                    .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.refresh() }
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
        .sheet(isPresented: $showNewFolder) {
            newFolderSheet
        }
    }

    // MARK: - Table

    var tableView: some View {
        Table(of: VPhoneRemoteFile.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("", value: \.name) { file in
                Image(systemName: file.icon)
                    .foregroundStyle(file.isDirectory ? .blue : .secondary)
                    .frame(width: 20)
            }
            .width(28)

            TableColumn("Name", value: \.name) { file in
                Text(file.name)
                    .lineLimit(1)
                    .help(file.name)
            }
            .width(min: 100, ideal: 200, max: .infinity)

            TableColumn("Permissions", value: \.permissions) { file in
                Text(file.permissions)
                    .font(.system(.body, design: .monospaced))
            }
            .width(80)

            TableColumn("Size", value: \.size) { file in
                Text(file.displaySize)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(file.isDirectory ? .secondary : .primary)
            }
            .width(min: 50, ideal: 80, max: .infinity)

            TableColumn("Modified", value: \.modified) { file in
                Text(file.displayDate)
            }
            .width(min: 80, ideal: 140, max: .infinity)
        } rows: {
            ForEach(model.filteredFiles) { file in
                TableRow(file)
            }
        }
        .contextMenu(forSelectionType: VPhoneRemoteFile.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            primaryAction(for: ids)
        }
    }

    // MARK: - Control Bar

    var controlBar: some View {
        HStack(spacing: 6) {
            // Status dot
            Circle()
                .fill(model.control.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Divider()

            // Breadcrumbs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { _, crumb in
                        if crumb.path != "/" || model.breadcrumbs.count == 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) {
                            model.goToBreadcrumb(crumb.path)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            Divider()

            // Item count
            Text(model.statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 60)
        }
        .padding(.horizontal, 8)
        .frame(height: controlBarHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Progress Overlay

    var progressOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            if model.transferTotal > 0 {
                ProgressView(value: Double(model.transferCurrent), total: Double(model.transferTotal))
                    .progressViewStyle(.linear)
            }
            HStack {
                Text(model.transferName ?? "Transferring...")
                    .lineLimit(1)
                Spacer()
                if model.transferTotal > 0 {
                    Text("\(formatBytes(model.transferCurrent)) / \(formatBytes(model.transferTotal))")
                }
            }
            .font(.system(.footnote, design: .monospaced))
        }
        .frame(maxWidth: 300)
        .padding(24)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut(.leftArrow, modifiers: .command)
        }
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
                newFolderName = ""
                showNewFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        ToolbarItem {
            Button {
                uploadAction()
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
        }
        ToolbarItem {
            Button {
                downloadAction()
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selection.isEmpty)
        }
        ToolbarItem {
            Button {
                Task { await model.deleteSelected() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    func contextMenu(for ids: Set<VPhoneRemoteFile.ID>) -> some View {
        Button("Open") { primaryAction(for: ids) }
        Button("Download") {
            model.selection = ids
            downloadAction()
        }
        Button("Delete") {
            model.selection = ids
            Task { await model.deleteSelected() }
        }
        Divider()
        Button("Refresh") { Task { await model.refresh() } }
        Divider()
        Button("Copy Name") { copyNames(ids: ids) }
        Button("Copy Path") { copyPaths(ids: ids) }
        Divider()
        Button("Upload...") { uploadAction() }
        Button("New Folder...") {
            newFolderName = ""
            showNewFolder = true
        }
    }

    // MARK: - New Folder Sheet

    var newFolderSheet: some View {
        VStack(spacing: 16) {
            Text("New Folder").font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createFolder() }
            HStack {
                Button("Cancel") { showNewFolder = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { createFolder() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    // MARK: - Actions

    func primaryAction(for ids: Set<VPhoneRemoteFile.ID>) {
        guard let id = ids.first,
              let file = model.filteredFiles.first(where: { $0.id == id })
        else { return }
        model.openItem(file)
    }

    func uploadAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        Task { await model.uploadFiles(urls: panel.urls) }
    }

    func downloadAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.downloadSelected(to: url) }
    }

    func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showNewFolder = false
        Task { await model.createNewFolder(name: name) }
    }

    func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        let validProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !validProviders.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in validProviders {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                    as? URL
                {
                    urls.append(url)
                } else if let data = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                await model.uploadFiles(urls: urls)
            }
        }
        return true
    }

    func copyNames(ids: Set<VPhoneRemoteFile.ID>) {
        let names = model.filteredFiles
            .filter { ids.contains($0.id) }
            .map(\.name)
            .joined(separator: "\n")
        NSPasteboard.general.prepareForNewContents()
        NSPasteboard.general.setString(names, forType: .string)
    }

    func copyPaths(ids: Set<VPhoneRemoteFile.ID>) {
        let paths = model.filteredFiles
            .filter { ids.contains($0.id) }
            .map(\.path)
            .joined(separator: "\n")
        NSPasteboard.general.prepareForNewContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
