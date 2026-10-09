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
        case export([MachinePath])
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
            case let .export(machines): "export-\(machines.map(\.url.path).joined(separator: "|"))"
            case let .snapshots(machine): "snapshots-\(machine.url.path)"
            case let .console(machine): "console-\(machine.url.path)"
            case let .guestSystem(machine): "guest-system-\(machine.url.path)"
            case .commands: "commands"
            }
        }
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var sheet: Sheet?
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

    /// The machines in the header's order.
    private var rows: [VPhoneLaunchpadMachineRow] {
        library.machines.map { machine in
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
    }

    var body: some View {
        @Bindable var library = library
        @Bindable var model = model
        HStack(spacing: 0) {
            Group {
                if library.machines.isEmpty {
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
            TableColumn("Name", value: \.machine.name)
                .width(min: 90, ideal: 140)
            if library.spansLibraries {
                TableColumn("Location", value: \.machine.libraryRoot) { row in
                    let machine = row.machine
                    Text(verbatim: VPhoneLaunchpadMachineLocations.volumeName(machine.libraryRoot))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(VPhoneLaunchpadHostSetup.abbreviated(URL(fileURLWithPath: machine.libraryRoot, isDirectory: true)))
                }
                .width(min: 80, ideal: 110)
            }
            // Standard comparison orders 18.10 after 18.9.
            TableColumn("OS", value: \.machine.iosVersion) { row in
                let machine = row.machine
                Text(verbatim: machine.restoreInfo.map { "\(machine.osName) \($0.ios.version) (\($0.ios.build))" } ?? "—")
            }
            .width(min: 130, ideal: 150)
            TableColumn("Core Bundle", value: \.bundle) { row in
                let machine = row.machine
                // Each cell is a hosting view of its own. When its row leaves
                // the table, the cell is updated once more with an empty
                // environment, where reading the model is a fatal error.
                VPhoneLaunchpadMachineBundleLabel(machine: machine.path)
                    .environment(model)
            }
            .width(min: 60, ideal: 70)
            TableColumn("State", value: \.state) { row in
                let machine = row.machine
                VPhoneLaunchpadMachineStateLabel(
                    state: library.state(of: machine.path),
                    progress: library.progress(of: machine.path),
                    isDamaged: library.isDamaged(machine.path),
                )
            }
            .width(min: 100, ideal: 120)
            // What deleting the machine frees: a clone of a template
            // shares the rest.
            TableColumn("Exclusive", value: \.exclusive) { row in
                let machine = row.machine
                let usage = library.diskUsage[machine.path]
                Text(verbatim: usage?.exclusive.map { VPhoneLaunchpadDiskUsage.format($0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(usage?.exclusive == nil ? .secondary : .primary)
                    .help(usage.map { String(localized: "\(VPhoneLaunchpadDiskUsage.format($0.allocated)) allocated; the rest is shared with its template or clones.") } ?? "")
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: MachinePath.self) { paths in
            VPhoneLaunchpadMachineActions(machines: library.machines.filter { paths.contains($0.path) })
        } primaryAction: { paths in
            library.start(library.machines.filter { paths.contains($0.path) && library.state(of: $0.path) == .stopped })
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
                self.sheet = .creation(path)
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
        case let .export(paths):
            VPhoneLaunchpadExportView(machines: paths)
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

/// One row of the machine table: the machine, with the values its other
/// columns show, so every column sorts.
struct VPhoneLaunchpadMachineRow: Identifiable {
    let machine: VPhoneLaunchpadMachine
    /// The Core Bundle version it runs with.
    let bundle: String
    /// Running, then busy, then stopped.
    let state: Int
    /// Bytes only it holds; -1 while unknown.
    let exclusive: Int64

    var id: VPhoneLaunchpadMachinePath {
        machine.path
    }
}
