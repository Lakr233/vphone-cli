import AppKit
import SwiftUI

struct VPhoneLaunchpadMachinesView: View {
    typealias MachinePath = VPhoneLaunchpadMachinePath

    enum Sheet: Identifiable {
        case newMachine
        case creation(MachinePath)
        case settings(VPhoneLaunchpadMachine)
        case rename(MachinePath)
        case clone(MachinePath)
        case export(MachinePath)
        case console(MachinePath)

        var id: String {
            switch self {
            case .newMachine: "new"
            case let .creation(machine): "creation-\(machine.url.path)"
            case let .settings(machine): "settings-\(machine.path.url.path)"
            case let .rename(machine): "rename-\(machine.url.path)"
            case let .clone(machine): "clone-\(machine.url.path)"
            case let .export(machine): "export-\(machine.url.path)"
            case let .console(machine): "console-\(machine.url.path)"
            }
        }
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var sheet: Sheet?
    @State private var deletion: MachinePath?
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
                    VPhoneLaunchpadMachineInspector(
                        machine: machine,
                        onShowProgress: { path in sheet = .creation(path) },
                        onOpenConsole: { path in sheet = .console(path) },
                    )
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
                "Delete \(deletion?.name ?? "")?",
                isPresented: Binding(get: { deletion != nil }, set: {
                    if !$0 {
                        deletion = nil
                    }
                }),
            ) {
                Button("Delete", role: .destructive) {
                    if let machine = deletion {
                        Task { await library.delete(machine) }
                    }
                }
            } message: {
                Text("The machine's disk, firmware and settings are removed. This cannot be undone.")
            }
            .alert(
                library.actionError?.message ?? "",
                isPresented: Binding(get: { library.actionError != nil }, set: {
                    if !$0 {
                        library.actionError = nil
                    }
                }),
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
        let state = selected.map { library.state(of: $0.path) }
        ToolbarItemGroup(placement: .primaryAction) {
            if state == .running, let selected {
                Button {
                    Task { await library.stop(selected.path) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop \(selected.name)")
            } else {
                Button {
                    if let selected {
                        library.start(selected.path)
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
            let isStopped = library.state(of: machine.path) == .stopped
            Button("Start Headless") { library.start(machine.path, headless: true) }
                .disabled(!isStopped)
            Divider()
            Button("Settings…") { sheet = .settings(machine) }
                .disabled(!isStopped)
            Button("Rename…") { sheet = .rename(machine.path) }
                .disabled(!isStopped)
            Button("Clone…") { sheet = .clone(machine.path) }
                .disabled(!isStopped)
            Button("Export…") { sheet = .export(machine.path) }
                .disabled(!isStopped)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([machine.path.url])
            }
            Button("Open Console") { sheet = .console(machine.path) }
            Button("Show Console Log") {
                NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.path))
            }
            Divider()
            Button("Delete…", role: .destructive) { deletion = machine.path }
                .disabled(!isStopped)
        }
    }

    // MARK: - Table

    private func table(selection: Binding<MachinePath?>) -> some View {
        Table(library.machines, selection: selection) {
            TableColumn("Name", value: \.name)
                .width(min: 90, ideal: 110)
            if library.spansLibraries {
                TableColumn("Location") { machine in
                    Text(verbatim: VPhoneLaunchpadMachineLocations.volumeName(machine.libraryRoot))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(VPhoneLaunchpadHostSetup.abbreviated(URL(fileURLWithPath: machine.libraryRoot, isDirectory: true)))
                }
                .width(min: 80, ideal: 110)
            }
            TableColumn("iOS") { machine in
                Text(verbatim: machine.restoreInfo.map { "\($0.ios.version) (\($0.ios.build))" } ?? "—")
            }
            .width(min: 110, ideal: 120)
            TableColumn("State") { machine in
                VPhoneLaunchpadMachineStateLabel(state: library.state(of: machine.path))
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
        .contextMenu(forSelectionType: MachinePath.self) { paths in
            machineActions(library.machines.first { paths.contains($0.path) })
        } primaryAction: { paths in
            if let path = paths.first, library.state(of: path) == .stopped {
                library.start(path)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Machines", systemImage: "iphone")
        } description: {
            Text(library.listError ?? String(localized: "Machines in \(VPhoneLaunchpadHostSetup.abbreviated(URL(fileURLWithPath: library.libraryRoot, isDirectory: true))) appear here."))
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
            VPhoneLaunchpadNewMachineView { path in
                self.sheet = .creation(path)
            }
        case let .creation(path):
            if let creation = library.creations[path] {
                VPhoneLaunchpadCreationView(creation: creation)
            }
        case let .settings(machine):
            VPhoneLaunchpadMachineSettingsView(machine: machine)
        case let .rename(path):
            VPhoneLaunchpadNameSheet(title: "Rename \(path.name)", action: "Rename", initial: path.name, machine: path) { newName in
                Task { await library.rename(path, to: newName) }
            }
        case let .clone(path):
            VPhoneLaunchpadNameSheet(
                title: "Clone \(path.name)",
                action: "Clone",
                initial: "\(path.name)-clone",
                machine: path,
            ) { newName in
                Task { await library.clone(path, as: newName) }
            }
        case let .export(path):
            VPhoneLaunchpadExportView(machine: path)
        case let .console(path):
            VPhoneLaunchpadConsoleView(title: "\(path.name) Console", url: VPhoneLaunchpadMachineLibrary.consoleLog(path))
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
