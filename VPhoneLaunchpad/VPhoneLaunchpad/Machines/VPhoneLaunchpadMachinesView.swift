import AppKit
import SwiftUI

struct VPhoneLaunchpadMachinesView: View {
    enum Sheet: Identifiable {
        case newMachine
        case creation(String)
        case settings(VPhoneLaunchpadMachine)
        case rename(String)
        case clone(String)
        case export(String)

        var id: String {
            switch self {
            case .newMachine: "new"
            case let .creation(name): "creation-\(name)"
            case let .settings(machine): "settings-\(machine.name)"
            case let .rename(name): "rename-\(name)"
            case let .clone(name): "clone-\(name)"
            case let .export(name): "export-\(name)"
            }
        }
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var sheet: Sheet?
    @State private var deletion: String?
    @State private var showsInspector = true

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        @Bindable var library = library
        Group {
            if library.machines.isEmpty {
                emptyState
            } else {
                table(selection: $library.selection)
            }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let machine = library.selected {
                    VPhoneLaunchpadMachineInspector(machine: machine) { name in sheet = .creation(name) }
                } else {
                    ContentUnavailableView("No Selection", systemImage: "iphone")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .toolbar { toolbar }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: VPhoneLaunchpadPreview.sheetNotification)) { note in
                sheet = note.object as? Sheet
            }
        #endif
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
                .environment(model)
        }
        .confirmationDialog(
            "Delete \(deletion ?? "")?",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
        ) {
            Button("Delete", role: .destructive) {
                if let name = deletion {
                    Task { await library.delete(name) }
                }
            }
        } message: {
            Text("The machine's disk, firmware and settings are removed. This cannot be undone.")
        }
        .alert(
            library.actionError?.message ?? "",
            isPresented: Binding(get: { library.actionError != nil }, set: { if !$0 { library.actionError = nil } }),
            presenting: library.actionError,
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.detail ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let selected = library.selected
        let state = selected.map { library.state(of: $0.name) }
        ToolbarItemGroup(placement: .primaryAction) {
            if state == .running, let selected {
                Button {
                    Task { await library.stop(selected.name) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop \(selected.name)")
            } else {
                Button {
                    if let selected {
                        library.start(selected.name)
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .help("Start the selected machine")
                .disabled(state != .stopped)
            }
            Menu {
                machineActions(selected)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .disabled(selected == nil)
            Button {
                chooseImport()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import an exported machine")
            .disabled(library.globalActivity != nil)
            Button {
                sheet = .newMachine
            } label: {
                Label("New Machine", systemImage: "plus")
            }
            .help("Create a machine")
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    /// The same actions in the toolbar menu and the table's context menu.
    @ViewBuilder
    private func machineActions(_ machine: VPhoneLaunchpadMachine?) -> some View {
        if let machine {
            let isStopped = library.state(of: machine.name) == .stopped
            Button("Start Headless") { library.start(machine.name, headless: true) }
                .disabled(!isStopped)
            Divider()
            Button("Settings…") { sheet = .settings(machine) }
                .disabled(!isStopped)
            Button("Rename…") { sheet = .rename(machine.name) }
                .disabled(!isStopped)
            Button("Clone…") { sheet = .clone(machine.name) }
                .disabled(!isStopped)
            Button("Export…") { sheet = .export(machine.name) }
                .disabled(!isStopped)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.libraryRoot.appendingPathComponent(machine.name)])
            }
            Button("Show Console Log") {
                NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.name))
            }
            Divider()
            Button("Delete…", role: .destructive) { deletion = machine.name }
                .disabled(!isStopped)
        }
    }

    // MARK: - Table

    private func table(selection: Binding<String?>) -> some View {
        Table(library.machines, selection: selection) {
            TableColumn("Name", value: \.name)
                .width(min: 90, ideal: 110)
            TableColumn("iOS") { machine in
                Text(verbatim: machine.restoreInfo.map { "\($0.ios.version) (\($0.ios.build))" } ?? "—")
            }
            .width(min: 110, ideal: 120)
            TableColumn("State") { machine in
                VPhoneLaunchpadMachineStateLabel(state: library.state(of: machine.name))
            }
            .width(min: 150, ideal: 160)
            TableColumn("CPU") { machine in
                Text(verbatim: "\(machine.cpuCount)").monospacedDigit()
            }
            .width(40)
            TableColumn("Memory") { machine in
                Text(Self.memory(machine.memoryMB)).monospacedDigit()
            }
            .width(64)
            TableColumn("Disk") { machine in
                Text(Self.disk(machine.diskSizeBytes)).monospacedDigit()
            }
            .width(64)
        }
        .contextMenu(forSelectionType: String.self) { names in
            machineActions(library.machines.first { names.contains($0.name) })
        } primaryAction: { names in
            if let name = names.first, library.state(of: name) == .stopped {
                library.start(name)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Machines", systemImage: "iphone")
        } description: {
            Text(library.listError ?? String(localized: "Machines in \(VPhoneLaunchpadHostSetup.abbreviated(library.libraryRoot)) appear here."))
        } actions: {
            Button("New Machine…") { sheet = .newMachine }
                .buttonStyle(.borderedProminent)
            Button("Import…") { chooseImport() }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .newMachine:
            VPhoneLaunchpadNewMachineView { name in
                self.sheet = .creation(name)
            }
        case let .creation(name):
            if let creation = library.creations[name] {
                VPhoneLaunchpadCreationView(creation: creation)
            }
        case let .settings(machine):
            VPhoneLaunchpadMachineSettingsView(machine: machine)
        case let .rename(name):
            VPhoneLaunchpadNameSheet(title: "Rename \(name)", action: "Rename", initial: name) { newName in
                Task { await library.rename(name, to: newName) }
            }
        case let .clone(name):
            VPhoneLaunchpadNameSheet(
                title: "Clone \(name)",
                action: "Clone",
                initial: "\(name)-clone",
                note: "The clone boots as a new device. SEP storage is copied as is, so a restored machine may need restoring again.",
            ) { newName in
                Task { await library.clone(name, as: newName) }
            }
        case let .export(name):
            VPhoneLaunchpadExportView(name: name)
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Machine")
        panel.message = String(localized: "Choose a .tzst or .txz archive made by Export.")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task { await library.importArchive(url) }
    }

    // MARK: - Formatting

    static func memory(_ megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    static func disk(_ bytes: Int64) -> String {
        "\(bytes / 1_073_741_824) GB"
    }
}
