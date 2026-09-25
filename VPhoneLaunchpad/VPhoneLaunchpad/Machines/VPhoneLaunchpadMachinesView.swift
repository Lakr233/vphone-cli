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

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        @Bindable var library = library
        Group {
            if library.machines.isEmpty {
                emptyState
            } else {
                VSplitView {
                    table(selection: $library.selection)
                        .frame(minHeight: 140, idealHeight: 200)
                    Group {
                        if let machine = library.selected {
                            detail(machine)
                        } else {
                            ContentUnavailableView("No Selection", systemImage: "iphone")
                        }
                    }
                    .frame(minHeight: 260)
                }
            }
        }
        .toolbar { toolbar }
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
            TableColumn("iOS") { machine in
                Text(machine.restoreInfo.map { "\($0.ios.version) (\($0.ios.build))" } ?? "—")
            }
            TableColumn("State") { machine in
                stateLabel(machine.name)
            }
            .width(min: 120, ideal: 180)
            TableColumn("CPU") { machine in
                Text("\(machine.cpuCount)").monospacedDigit()
            }
            .width(50)
            TableColumn("Memory") { machine in
                Text(Self.memory(machine.memoryMB)).monospacedDigit()
            }
            .width(70)
            TableColumn("Disk") { machine in
                Text(Self.disk(machine.diskSizeBytes)).monospacedDigit()
            }
            .width(70)
        }
        .contextMenu(forSelectionType: String.self) { names in
            machineActions(library.machines.first { names.contains($0.name) })
        } primaryAction: { names in
            if let name = names.first, library.state(of: name) == .stopped {
                library.start(name)
            }
        }
    }

    private func stateLabel(_ name: String) -> some View {
        let (status, text): (VPhoneLaunchpadStatus, String) = switch library.state(of: name) {
        case .running: (.passed, "Running")
        case .stopped: (.pending, "Stopped")
        case let .busy(activity): (.running, activity.prefix(1).uppercased() + activity.dropFirst())
        }
        return Label {
            Text(text).lineLimit(1)
        } icon: {
            VPhoneLaunchpadStatusIcon(status: status)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Machines", systemImage: "iphone")
        } description: {
            Text(library.listError ?? "Machines in \(VPhoneLaunchpadHostSetup.abbreviated(library.libraryRoot)) appear here.")
        } actions: {
            Button("New Machine…") { sheet = .newMachine }
                .buttonStyle(.borderedProminent)
            Button("Import…") { chooseImport() }
        }
    }

    // MARK: - Detail

    private func detail(_ machine: VPhoneLaunchpadMachine) -> some View {
        Form {
            Section {
                if let creation = library.creations[machine.name] {
                    creationSummary(creation)
                }
                LabeledContent("State") { stateLabel(machine.name) }
                if let started = library.startedAt[machine.name] {
                    LabeledContent("Started", value: started.formatted(date: .omitted, time: .shortened))
                }
                LabeledContent("Firmware", value: machine.restoreInfo.map {
                    "iOS \($0.ios.version) (\($0.ios.build)) on cloudOS \($0.cloudOS.version)"
                } ?? "Not restored")
                if let variant = machine.restoreInfo?.variant {
                    LabeledContent("Variant", value: variant)
                }
                LabeledContent(
                    "Hardware",
                    value: "\(machine.cpuCount) cores, \(Self.memory(machine.memoryMB)), \(Self.disk(machine.diskSizeBytes)) disk",
                )
                LabeledContent("Network", value: machine.networkDescription)
                if let udid = machine.udid {
                    LabeledContent("UDID") { Text(udid).textSelection(.enabled) }
                }
                LabeledContent(
                    "Location",
                    value: VPhoneLaunchpadHostSetup.abbreviated(library.libraryRoot.appendingPathComponent(machine.name)),
                )
            } header: {
                Text(machine.name)
            }

            Section("Console") {
                VPhoneLaunchpadLogView(lines: library.consoles[machine.name] ?? [])
                    .frame(minHeight: 160)
            }

            Section("Recent Commands") {
                commands
            }
        }
        .formStyle(.grouped)
        .onAppear { library.loadConsoleIfNeeded(machine.name) }
        .onChange(of: machine.name) { _, name in library.loadConsoleIfNeeded(name) }
    }

    private func creationSummary(_ creation: VPhoneLaunchpadCreationPipeline) -> some View {
        LabeledContent {
            Button("Show Progress") { sheet = .creation(creation.options.name) }
        } label: {
            if creation.isRunning {
                Label { Text("Creating: \(creation.current?.title ?? "")") } icon: { VPhoneLaunchpadStatusIcon(status: .running) }
            } else if creation.isFinished {
                Label { Text("Created") } icon: { VPhoneLaunchpadStatusIcon(status: .passed) }
            } else {
                Label { Text(creation.failure?.message ?? "Creation stopped") } icon: { VPhoneLaunchpadStatusIcon(status: .failed) }
            }
        }
    }

    @ViewBuilder
    private var commands: some View {
        let entries = Array(model.history.entries.suffix(12).reversed())
        if entries.isEmpty {
            Text("Commands Launchpad runs appear here.")
                .foregroundStyle(.secondary)
        }
        ForEach(entries) { entry in
            Label {
                Text(entry.text)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: entry.status.map { $0 == 0 ? .passed : .failed } ?? .running)
            }
            .contextMenu {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }
            }
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
        panel.title = "Import Machine"
        panel.message = "Choose a .tzst or .txz archive made by Export."
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
