import AppKit
import SwiftUI

struct VPhoneLaunchpadMachinesView: View {
    typealias MachinePath = VPhoneLaunchpadMachinePath

    enum Sheet: Identifiable {
        case newMachine
        case creation(MachinePath)
        case settings([VPhoneLaunchpadMachine])
        case rename(MachinePath)
        case clone(MachinePath)
        case export([MachinePath])
        case console(MachinePath)

        var id: String {
            switch self {
            case .newMachine: "new"
            case let .creation(machine): "creation-\(machine.url.path)"
            case let .settings(machines): "settings-\(machines.map(\.path.url.path).joined(separator: "|"))"
            case let .rename(machine): "rename-\(machine.url.path)"
            case let .clone(machine): "clone-\(machine.url.path)"
            case let .export(machines): "export-\(machines.map(\.url.path).joined(separator: "|"))"
            case let .console(machine): "console-\(machine.url.path)"
            }
        }
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var sheet: Sheet?
    /// The machines the delete confirmation is for; empty when it is closed.
    @State private var deletion: [MachinePath] = []
    @State private var filter = ""
    /// Empty keeps the order `vm list` returns; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadMachine>] = []
    /// The table appears only once `vm list` returns, after the window has
    /// picked its first responder, so nothing focuses it by itself. Unfocused,
    /// AppKit draws the library's automatic selection in gray, not in the
    /// accent color.
    @FocusState private var tableIsFocused: Bool

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    /// The machines the table shows: those matching the search, in the
    /// header's order.
    private var rows: [VPhoneLaunchpadMachine] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let matching = needle.isEmpty ? library.machines : library.machines.filter { Self.matches($0, needle) }
        return matching.sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var library = library
        @Bindable var model = model
        Group {
            if library.machines.isEmpty {
                emptyState
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                table(selection: $library.selection)
            }
        }
        // A hidden machine stays out of the selection, so Start, Delete and
        // the inspector act only on rows the table shows.
        .onChange(of: filter) {
            let visible = Set(rows.map(\.path))
            library.selection.formIntersection(visible)
        }
        .inspector(isPresented: $model.showsInspector) {
            Group {
                if let machine = library.selected {
                    VPhoneLaunchpadMachineInspector(
                        machine: machine,
                        onShowProgress: { path in sheet = .creation(path) },
                        onOpenConsole: { path in sheet = .console(path) },
                    )
                } else if library.selection.count > 1 {
                    ContentUnavailableView("\(library.selection.count) Machines Selected", systemImage: "iphone")
                } else {
                    ContentUnavailableView("No Selection", systemImage: "iphone")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            // The toggle belongs to the inspector's own toolbar section. Put in
            // the content's toolbar, the section and its background were set up
            // at launch but not again after the inspector was hidden and shown.
            .toolbar { inspectorToolbar }
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
                deletion.count == 1 ? "Delete \(deletion[0].name)?" : "Delete \(deletion.count) Machines?",
                isPresented: Binding(get: { !deletion.isEmpty }, set: {
                    if !$0 {
                        deletion = []
                    }
                }),
            ) {
                Button("Delete", role: .destructive) {
                    let machines = deletion
                    Task {
                        for machine in machines {
                            await library.delete(machine)
                        }
                    }
                }
            } message: {
                if deletion.count == 1 {
                    Text("The machine's disk, firmware and settings are removed. This cannot be undone.")
                } else {
                    Text("Their disks, firmware and settings are removed. This cannot be undone.")
                }
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

    /// The machine list's own tools. Host Setup and Core Bundle hold the
    /// leading edge; the space pushes New Machine and the search field to the
    /// list's trailing edge. What acts on the selection is in the inspector.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Spacer()
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("New Machine…") { sheet = .newMachine }
                Button("Import…") { chooseImport() }
                    .disabled(library.globalActivity != nil)
            } label: {
                Label("New Machine", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .help("Create a machine")
            .disabled(model.bundles.activeVersion == nil)
        }
        // Without it, macOS 26 draws New Machine and the search field in
        // one glass capsule.
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
        ToolbarItem(placement: .automatic) {
            VPhoneLaunchpadSearchField(text: $filter, prompt: String(localized: "Search machines"))
                .frame(width: 200)
        }
    }

    /// The inspector toggle, then Start or Stop for the selection beside the
    /// actions menu at the window's trailing edge. Those two go away with the
    /// inspector; the context menu and a double-click still reach them.
    @ToolbarContentBuilder
    private var inspectorToolbar: some ToolbarContent {
        let selected = library.selectedMachines
        let stopped = selected.filter { library.state(of: $0.path) == .stopped }
        let running = selected.filter { library.state(of: $0.path) == .running }
        ToolbarItem(placement: .automatic) {
            inspectorToggle
        }
        if model.showsInspector {
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
            ToolbarItemGroup(placement: .automatic) {
                if stopped.isEmpty, !running.isEmpty {
                    Button {
                        stop(running)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop \(running.map(\.name).joined(separator: ", "))")
                } else {
                    Button {
                        start(stopped)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .help("Start the selected machine")
                    .disabled(stopped.isEmpty)
                }
                Menu {
                    machineActions(selected)
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
                .disabled(selected.isEmpty)
                // A menu with its arrow gets a capsule of its own; without it
                // the menu shares Start's.
                .menuIndicator(.hidden)
            }
        }
    }

    private func start(_ machines: [VPhoneLaunchpadMachine], headless: Bool = false) {
        for machine in machines {
            library.start(machine.path, headless: headless)
        }
    }

    private func stop(_ machines: [VPhoneLaunchpadMachine]) {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for machine in machines {
                    group.addTask { await library.stop(machine.path) }
                }
            }
        }
    }

    private var inspectorToggle: some View {
        Button {
            model.showsInspector.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(model.showsInspector ? "Hide the inspector" : "Show the inspector")
    }

    /// The same actions in the toolbar menu and the table's context menu.
    /// Several machines get the batch actions: one settings edit, export and
    /// delete, which need every machine stopped, then start and stop.
    @ViewBuilder
    private func machineActions(_ machines: [VPhoneLaunchpadMachine]) -> some View {
        // Only while one of them is exporting or waiting to.
        let exporting = machines.filter { library.exports[$0.path] != nil }
        if !exporting.isEmpty {
            Button("Cancel Export") {
                for machine in exporting {
                    library.cancelExport(machine.path)
                }
            }
            Divider()
        }
        if machines.count > 1 {
            let stopped = machines.filter { library.state(of: $0.path) == .stopped }
            let running = machines.filter { library.state(of: $0.path) == .running }
            let allStopped = stopped.count == machines.count
            Button("Settings…") { sheet = .settings(machines) }
                .disabled(!allStopped)
            Button("Export…") { sheet = .export(machines.map(\.path)) }
                .disabled(!allStopped)
            Button("Delete…", role: .destructive) { deletion = machines.map(\.path) }
                .disabled(!allStopped)
            Divider()
            Button("Start") { start(stopped) }
                .disabled(stopped.isEmpty)
            Button("Start Headless") { start(stopped, headless: true) }
                .disabled(stopped.isEmpty)
            Button("Stop") { stop(running) }
                .disabled(running.isEmpty)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(machines.map(\.path.url))
            }
        } else if let machine = machines.first {
            let isStopped = library.state(of: machine.path) == .stopped
            Button("Start Headless") { library.start(machine.path, headless: true) }
                .disabled(!isStopped)
            Divider()
            Button("Settings…") { sheet = .settings([machine]) }
                .disabled(!isStopped)
            Button("Rename…") { sheet = .rename(machine.path) }
                .disabled(!isStopped)
            Button("Clone…") { sheet = .clone(machine.path) }
                .disabled(!isStopped)
            Button("Export…") { sheet = .export([machine.path]) }
                .disabled(!isStopped)
            Button("Install Custom Firmware") {
                Task { await library.installCustomFirmware(machine.path) }
            }
            // Only for an unfinished install: that is when the restore tree it
            // reads is still there. A finished one removes it.
            .disabled(!isStopped || machine.customFirmwareInstalled != false)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([machine.path.url])
            }
            Button("Open Console") { sheet = .console(machine.path) }
            Button("Show Console Log") {
                NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.path))
            }
            Button("Show Patch Log") {
                NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.path, suffix: "-patch"))
            }
            .disabled(!FileManager.default.fileExists(atPath: VPhoneLaunchpadMachineLibrary.consoleLog(machine.path, suffix: "-patch").path))
            Divider()
            Button("Delete…", role: .destructive) { deletion = [machine.path] }
                .disabled(!isStopped)
        }
    }

    // MARK: - Table

    private func table(selection: Binding<Set<MachinePath>>) -> some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
                .width(min: 90, ideal: 110)
            if library.spansLibraries {
                TableColumn("Location", value: \.libraryRoot) { machine in
                    Text(verbatim: VPhoneLaunchpadMachineLocations.volumeName(machine.libraryRoot))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(VPhoneLaunchpadHostSetup.abbreviated(URL(fileURLWithPath: machine.libraryRoot, isDirectory: true)))
                }
                .width(min: 80, ideal: 110)
            }
            // Standard comparison orders 18.10 after 18.9.
            TableColumn("iOS", value: \.iosVersion) { machine in
                Text(verbatim: machine.restoreInfo.map { "\($0.ios.version) (\($0.ios.build))" } ?? "—")
            }
            .width(min: 110, ideal: 120)
            TableColumn("State") { machine in
                VPhoneLaunchpadMachineStateLabel(
                    state: library.state(of: machine.path),
                    progress: library.exports[machine.path]?.fraction,
                )
            }
            .width(min: 150, ideal: 160)
            TableColumn("CPU", value: \.cpuCount) { machine in
                Text(verbatim: "\(machine.cpuCount)").monospacedDigit()
            }
            .width(40)
            TableColumn("Memory", value: \.memoryMB) { machine in
                Text(Self.memory(machine.memoryMB)).monospacedDigit()
            }
            .width(64)
            TableColumn("Disk", value: \.diskSizeBytes) { machine in
                Text(Self.disk(machine.diskSizeBytes)).monospacedDigit()
            }
            .width(64)
        }
        .contextMenu(forSelectionType: MachinePath.self) { paths in
            machineActions(library.machines.filter { paths.contains($0.path) })
        } primaryAction: { paths in
            start(library.machines.filter { paths.contains($0.path) && library.state(of: $0.path) == .stopped })
        }
        .focused($tableIsFocused)
        .onAppear {
            // The table comes back when a search matches again; the search
            // field keeps the keyboard then.
            if !(NSApp.keyWindow?.firstResponder is NSText) {
                tableIsFocused = true
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.bundles.activeVersion == nil {
            ContentUnavailableView {
                Label("No Core Bundle", systemImage: "shippingbox")
            } description: {
                Text("Install a VPhone.bundle to create and run machines.")
            } actions: {
                Button("Set Up…") { model.present(model.host.requiredPassed ? .coreBundle : .hostSetup) }
                    .buttonStyle(.borderedProminent)
            }
        } else if !library.hasListed {
            Color.clear
        } else {
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
        case let .settings(machines):
            VPhoneLaunchpadMachineSettingsView(machines: machines)
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
        case let .export(paths):
            VPhoneLaunchpadExportView(machines: paths)
        case let .console(path):
            VPhoneLaunchpadConsoleView(title: "\(path.name) Console", url: VPhoneLaunchpadMachineLibrary.consoleLog(path))
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Machine")
        panel.message = String(localized: "Choose an exported machine archive (.tzst or .txz).")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.present { url in
            Task { await library.importArchive(url) }
        }
    }

    // MARK: - Search

    private static func matches(_ machine: VPhoneLaunchpadMachine, _ needle: String) -> Bool {
        [
            machine.name,
            machine.restoreInfo?.ios.version,
            machine.restoreInfo?.ios.build,
            machine.udid,
            VPhoneLaunchpadMachineLocations.volumeName(machine.libraryRoot),
        ]
        .compactMap(\.self)
        .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    // MARK: - Formatting

    static func memory(_ megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    static func disk(_ bytes: Int64) -> String {
        // Decimal, as iOS and the creation stepper count it.
        "\(bytes / 1_000_000_000) GB"
    }
}
