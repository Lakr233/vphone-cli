import AppKit
import SwiftUI

struct VPhoneLaunchpadMachinesView: View {
    typealias MachinePath = VPhoneLaunchpadMachinePath

    enum Sheet: Identifiable {
        case newMachine
        case creation(MachinePath)
        case settings([VPhoneLaunchpadMachine])
        case changeBundle([VPhoneLaunchpadMachine])
        case rename(MachinePath)
        case clone(MachinePath)
        case snapshots(MachinePath)
        case console(MachinePath)
        case guestSystem(MachinePath)
        case commands

        var id: String {
            switch self {
            case .newMachine: "new"
            case let .creation(machine): "creation-\(machine.url.path)"
            case let .settings(machines): "settings-\(machines.map(\.path.url.path).joined(separator: "|"))"
            case let .changeBundle(machines): "bundle-\(machines.map(\.path.url.path).joined(separator: "|"))"
            case let .rename(machine): "rename-\(machine.url.path)"
            case let .clone(machine): "clone-\(machine.url.path)"
            case let .snapshots(machine): "snapshots-\(machine.url.path)"
            case let .console(machine): "console-\(machine.url.path)"
            case let .guestSystem(machine): "guest-system-\(machine.url.path)"
            case .commands: "commands"
            }
        }
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var sheet: Sheet?
    /// The sheet to open once the current one has closed: New Machine's
    /// creation progress, after New Machine itself is gone.
    @State private var nextSheet: Sheet?
    /// The machines the delete confirmation is for; empty when it is closed.
    @State private var deletion: [MachinePath] = []
    /// Empty keeps the order `vm list` returns; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadMachineRow>] = []
    /// The table appears only once `vm list` returns, after the window has
    /// picked its first responder, so nothing focuses it by itself. Unfocused,
    /// AppKit draws the library's automatic selection in gray, not in the
    /// accent color.
    @FocusState private var tableIsFocused: Bool

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    /// The machines in the header's order, then the imports, which have no
    /// machine yet, in the order they were queued.
    private var rows: [VPhoneLaunchpadMachineRow] {
        let machines = library.machines.map { machine in
            let state = switch library.state(of: machine.path) {
            case .running: 0
            case .busy: 1
            case .stopped: 2
            }
            return VPhoneLaunchpadMachineRow(
                machine: machine,
                bundle: library.bundleVersion(for: machine.path) ?? "",
                state: state,
                exclusive: library.diskUsage[machine.path]?.exclusive ?? -1,
            )
        }
        .sorted(using: sortOrder)
        return machines + library.imports.map(VPhoneLaunchpadMachineRow.init(importing:))
    }

    var body: some View {
        @Bindable var library = library
        @Bindable var model = model
        HStack(spacing: 0) {
            Group {
                if library.machines.isEmpty, library.imports.isEmpty {
                    emptyState
                } else {
                    table(selection: $library.selection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Up through the toolbar, as a split view's divider runs.
            Divider()
                .ignoresSafeArea(.container, edges: .top)
            Group {
                if library.selection.count == 1, let item = library.selection.first.flatMap(library.importItem) {
                    VPhoneLaunchpadImportInspector(item: item)
                } else if let machine = library.selected {
                    VPhoneLaunchpadMachineInspector(
                        machine: machine,
                        onShowProgress: { path in sheet = .creation(path) },
                    )
                } else if library.selection.count > 1 {
                    ContentUnavailableView("\(library.selection.count) Machines Selected", systemImage: "iphone")
                } else {
                    ContentUnavailableView("No Selection", systemImage: "iphone")
                }
            }
            .frame(width: 360)
            .frame(maxHeight: .infinity)
        }
        .toolbar { toolbar }
        // An exported machine dropped on the window is imported, as Import…
        // does; an IPSW is added to the IPSW cache.
        .dropDestination(for: URL.self) { urls, _ in
            let ipsws = urls.filter(VPhoneLaunchpadIPSWImport.isIPSW)
            model.ipswImport.register(ipsws, model: model)
            return library.importDropped(urls) || !ipsws.isEmpty
        }
        // Sheets and deletions asked for by the shared actions menu, here or
        // from the menu bar.
        .onChange(of: model.machineSheetRequest?.id, initial: true) {
            if let request = model.machineSheetRequest {
                model.machineSheetRequest = nil
                sheet = request
            }
        }
        // So New Machine opens on the catalog rather than loading it.
        .task(id: model.bundles.defaultVersion) { await VPhoneLaunchpadNewMachineView.prefetchCatalog(model) }
        .onChange(of: model.deletionRequest, initial: true) {
            if !model.deletionRequest.isEmpty {
                deletion = model.deletionRequest
                model.deletionRequest = []
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: VPhoneLaunchpadPreview.sheetNotification)) { note in
            sheet = note.object as? Sheet
        }
        #endif
        .sheet(item: $sheet, onDismiss: {
            if let next = nextSheet {
                nextSheet = nil
                sheet = next
            }
        }) { sheet in
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
        // `vm delete` of the last machine cloned from a template keeps
        // the template and says so; so does this.
        .alert(
            String(localized: "Template No Longer Used"),
            isPresented: Binding(get: { library.templateNotice != nil && library.actionError == nil }, set: {
                if !$0 {
                    library.templateNotice = nil
                }
            }),
            presenting: library.templateNotice,
        ) { _ in
            Button("Show Templates") { model.present(.templates) }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text("No machine uses template \(notice.id) any more. It stays, taking about \(notice.size), so the next machine with its options is created in seconds. Delete it in Templates once it is no longer needed.")
        }
    }

    // MARK: - Toolbar

    /// The machine list's own tools. New Machine leads, in one group with
    /// Host Setup while a check fails (the app menu opens it otherwise); Core
    /// Bundle and Downloaded Firmware follow in a second group. The space
    /// pushes Start or Stop and the actions menu
    /// for the selection to the trailing edge.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                sheet = .newMachine
            } label: {
                Label("New Machine", systemImage: "plus")
            }
            .help("Create a machine")
            .disabled(model.bundles.defaultVersion == nil)
            if model.hostNeedsAttention {
                panelButton(.hostSetup, systemImage: "checklist", needsAttention: true)
            }
        }
        // Without it, macOS 26 draws both groups in one glass capsule.
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
        ToolbarItemGroup(placement: .automatic) {
            panelButton(.coreBundle, systemImage: "shippingbox", needsAttention: model.bundleNeedsAttention)
            panelButton(.ipswCache, systemImage: "briefcase", needsAttention: false)
        }
        flexibleSpace
        selectionToolbar
    }

    private func panelButton(_ panel: VPhoneLaunchpadModel.Panel, systemImage: String, needsAttention: Bool) -> some View {
        Button {
            model.present(panel)
        } label: {
            Label {
                Text(panel.title)
            } icon: {
                if needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Image(systemName: systemImage)
                }
            }
        }
        .help(needsAttention ? "\(panel.title) needs attention" : panel.title)
    }

    /// Space that pushes what follows to the trailing edge. On macOS 26 a
    /// `Spacer` in a `ToolbarItem` is an item like any other: it joins the
    /// next item's glass capsule and stretches it, leaving the icon at the
    /// capsule's far end. `ToolbarSpacer` is space between capsules.
    @ToolbarContentBuilder
    private var flexibleSpace: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
        }
    }

    /// Start or Stop for the selection beside the actions menu.
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        let selected = library.selectedMachines
        let stopped = selected.filter { library.state(of: $0.path) == .stopped }
        let running = selected.filter { library.state(of: $0.path) == .running }
        ToolbarItemGroup(placement: .automatic) {
            if stopped.isEmpty, !running.isEmpty {
                Button {
                    library.stop(running)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop \(running.map(\.name).joined(separator: ", ")). Hold Option to force stop.")
            } else {
                Button {
                    library.start(stopped)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .help("Start the selected machine")
                .disabled(stopped.isEmpty)
            }
            Menu {
                VPhoneLaunchpadMachineActions(machines: selected)
            } label: {
                Label("Actions", systemImage: "ellipsis")
            }
            .disabled(selected.isEmpty)
            // A menu with its arrow gets a capsule of its own; without it
            // the menu shares Start's.
            .menuIndicator(.hidden)
        }
    }

    // MARK: - Table

    private func table(selection: Binding<Set<MachinePath>>) -> some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Text(verbatim: row.name)
                    .foregroundStyle(row.machine == nil ? .secondary : .primary)
            }
            .width(min: 90, ideal: 140)
            if library.spansLibraries {
                TableColumn("Location", value: \.libraryRoot) { row in
                    Text(verbatim: VPhoneLaunchpadMachineLocations.volumeName(row.libraryRoot))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(VPhoneLaunchpadHostSetup.abbreviated(URL(fileURLWithPath: row.libraryRoot, isDirectory: true)))
                }
                .width(min: 80, ideal: 110)
            }
            // Standard comparison orders 18.10 after 18.9.
            TableColumn("OS", value: \.iosVersion) { row in
                let restore = row.machine.flatMap { machine in
                    machine.restoreInfo.map { "\(machine.osName) \($0.ios.version) (\($0.ios.build))" }
                }
                Text(verbatim: restore ?? "—")
            }
            .width(min: 130, ideal: 150)
            TableColumn("Core Bundle", value: \.bundle) { row in
                if let machine = row.machine {
                    // Each cell is a hosting view of its own. When its row leaves
                    // the table, the cell is updated once more with an empty
                    // environment, where reading the model is a fatal error.
                    VPhoneLaunchpadMachineBundleLabel(machine: machine.path)
                        .environment(model)
                } else {
                    Text(verbatim: "—")
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("State", value: \.state) { row in
                if let machine = row.machine {
                    VPhoneLaunchpadMachineStateLabel(
                        state: library.state(of: machine.path),
                        progress: library.progress(of: machine.path),
                        isDamaged: library.isDamaged(machine.path),
                    )
                } else if let item = library.importItem(row.id) {
                    VPhoneLaunchpadImportStateLabel(item: item)
                }
            }
            .width(min: 100, ideal: 120)
            // What deleting the machine frees: a clone of a template
            // shares the rest.
            TableColumn("Exclusive", value: \.exclusive) { row in
                let usage = row.machine.flatMap { library.diskUsage[$0.path] }
                Text(verbatim: usage?.exclusive.map { VPhoneLaunchpadDiskUsage.format($0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(usage?.exclusive == nil ? .secondary : .primary)
                    .help(usage.map { String(localized: "\(VPhoneLaunchpadDiskUsage.format($0.allocated)) allocated; the rest is shared with its template or clones.") } ?? "")
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: MachinePath.self) { paths in
            let importing = library.imports.filter { paths.contains($0.row) }
            if importing.isEmpty {
                VPhoneLaunchpadMachineActions(machines: library.machines.filter { paths.contains($0.path) })
            } else {
                Button(importing.count == 1 ? LocalizedStringKey("Stop Importing") : LocalizedStringKey("Stop \(importing.count) Imports")) {
                    for item in importing {
                        library.cancelImport(item.id)
                    }
                }
            }
        } primaryAction: { paths in
            library.start(library.machines.filter { paths.contains($0.path) && library.state(of: $0.path) == .stopped })
        }
        // Edit > Delete and the Delete key, for the stopped selection.
        .onDeleteCommand {
            let paths = library.selectedMachines.map(\.path)
            if !paths.isEmpty, paths.allSatisfy({ library.state(of: $0) == .stopped }) {
                deletion = paths
            }
        }
        .focused($tableIsFocused)
        .onAppear {
            tableIsFocused = true
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.bundles.defaultVersion == nil {
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
                Button("Import…") { library.chooseImport() }
            }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .newMachine:
            VPhoneLaunchpadNewMachineView { path in
                nextSheet = .creation(path)
                self.sheet = nil
            }
        case let .creation(path):
            if let creation = library.creation(for: path) {
                VPhoneLaunchpadCreationView(creation: creation)
            }
        case let .settings(machines):
            VPhoneLaunchpadMachineSettingsView(machines: machines)
        case let .changeBundle(machines):
            VPhoneLaunchpadChangeBundleView(machines: machines)
        case let .rename(path):
            VPhoneLaunchpadNameSheet(title: "Rename \(path.name)", action: "Rename", initial: path.name, machine: path) { newName in
                Task { await library.rename(path, to: newName) }
            }
        case let .clone(path):
            VPhoneLaunchpadCloneSheet(machine: path) { newName, newIdentity in
                Task { await library.clone(path, as: newName, newIdentity: newIdentity) }
            }
        case let .snapshots(path):
            VPhoneLaunchpadSnapshotsView(machine: path)
        case let .console(path):
            VPhoneLaunchpadConsoleView(title: "\(path.name) Console", url: VPhoneLaunchpadMachineLibrary.consoleLog(path))
        case let .guestSystem(path):
            VPhoneLaunchpadGuestSystemView(machine: path)
        case .commands:
            VPhoneLaunchpadCommandHistoryView()
        }
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

/// One row of the machine table: a machine, or an import that has none yet,
/// with the values its columns show, so every column sorts.
struct VPhoneLaunchpadMachineRow: Identifiable {
    let id: VPhoneLaunchpadMachinePath
    /// Nil for an import.
    let machine: VPhoneLaunchpadMachine?
    let name: String
    let libraryRoot: String
    /// The iOS sort key; empty for a machine not yet restored, or an import.
    let iosVersion: String
    /// The Core Bundle version it runs with.
    let bundle: String
    /// Running, then busy, then stopped.
    let state: Int
    /// Bytes only it holds; -1 while unknown.
    let exclusive: Int64

    init(machine: VPhoneLaunchpadMachine, bundle: String, state: Int, exclusive: Int64) {
        id = machine.path
        self.machine = machine
        name = machine.name
        libraryRoot = machine.libraryRoot
        iosVersion = machine.iosVersion
        self.bundle = bundle
        self.state = state
        self.exclusive = exclusive
    }

    init(importing item: VPhoneLaunchpadMachineLibrary.Import) {
        id = item.row
        machine = nil
        name = item.name
        libraryRoot = item.libraryRoot
        iosVersion = ""
        bundle = ""
        state = 1
        exclusive = -1
    }
}

// MARK: - Import

/// An import's state: its progress once `vm import` reports it.
struct VPhoneLaunchpadImportStateLabel: View {
    let item: VPhoneLaunchpadMachineLibrary.Import
    var namesActivity = false

    var body: some View {
        VPhoneLaunchpadMachineStateLabel(
            state: .busy(item.isWaiting ? String(localized: "Waiting to import…") : String(localized: "Importing…")),
            progress: item.isWaiting ? nil : item.fraction ?? 0,
            namesActivity: namesActivity,
        )
    }
}

/// The inspector for an import's row: what is being imported, how far it has
/// got, and a way to stop it.
struct VPhoneLaunchpadImportInspector: View {
    let item: VPhoneLaunchpadMachineLibrary.Import
    @Environment(VPhoneLaunchpadModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("State") {
                    VPhoneLaunchpadImportStateLabel(item: item, namesActivity: true)
                }
                LabeledContent("Archive") {
                    Text(verbatim: item.archive.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(VPhoneLaunchpadHostSetup.abbreviated(item.archive))
                }
                LabeledContent("Location") {
                    Text(verbatim: VPhoneLaunchpadHostSetup.abbreviated(URL(fileURLWithPath: item.libraryRoot, isDirectory: true)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text(verbatim: item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
            }
            Section {
                Button(item.isWaiting ? LocalizedStringKey("Remove from Queue") : LocalizedStringKey("Stop Importing"), role: .destructive) {
                    model.machines.cancelImport(item.id)
                }
            } footer: {
                Text("The machine appears in the list once its files are unpacked and checked. Stopping removes what was unpacked.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, 0, for: .scrollContent)
    }
}
