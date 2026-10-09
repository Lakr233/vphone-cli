import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The actions for one or more machines, shared by the toolbar's Actions
/// menu, the table's context menu, each machine's menu in the menu bar and
/// the main menu, where they carry keyboard shortcuts: Machine holds most,
/// Edit holds Rename and Clone (Delete is Edit's own, from the table).
/// Several machines get the batch actions: start and stop, one settings
/// edit, export and delete, which need every machine stopped.
///
/// Sheets and the delete confirmation belong to the machine list, so those
/// items leave a request on the model that the list presents. The menu bar
/// passes `willRequest` to open the window first.
struct VPhoneLaunchpadMachineActions: View {
    enum Placement {
        /// Every action, without shortcuts: the Actions menu, the context
        /// menu and the menu bar.
        case full
        /// The main menu's Machine menu: all but Rename, Clone and Delete.
        case machineMenu
        /// The main menu's Edit menu: Rename and Clone.
        case editMenu
    }

    let machines: [VPhoneLaunchpadMachine]
    var placement = Placement.full
    var willRequest: () -> Void = {}
    @Environment(VPhoneLaunchpadModel.self) private var model

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var showsRunItems: Bool {
        placement != .editMenu
    }

    private var showsEditItems: Bool {
        placement != .machineMenu
    }

    var body: some View {
        if machines.isEmpty, placement == .machineMenu {
            Text("No Machine Selected")
        }
        // Only while one of them is exporting or waiting to.
        let exporting = machines.filter { library.exports[$0.path] != nil }
        if !exporting.isEmpty, showsRunItems {
            Button("Cancel Export") {
                for machine in exporting {
                    library.cancelExport(machine.path)
                }
            }
            Divider()
        }
        if machines.count > 1 {
            if showsRunItems {
                multipleActions
            }
        } else if let machine = machines.first {
            singleActions(machine)
        }
    }

    // MARK: - Several machines

    @ViewBuilder
    private var multipleActions: some View {
        let stopped = machines.filter { library.state(of: $0.path) == .stopped }
        let running = machines.filter { library.state(of: $0.path) == .running }
        let allStopped = stopped.count == machines.count
        // The order of one machine's menu, with what applies to several.
        Button("Start") { library.start(stopped) }
            .disabled(stopped.isEmpty)
            .menuShortcut(.return, in: placement)
        Button("Start Headless") { library.start(stopped, headless: true) }
            .disabled(stopped.isEmpty)
            .menuShortcut(.return, [.command, .option], in: placement)
        Button("Stop") { library.stop(running) }
            .disabled(running.isEmpty)
            .menuShortcut(".", [.command, .shift], in: placement)
        Button("Terminate") {
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for machine in running {
                        group.addTask { await library.forceStop(machine.path) }
                    }
                }
            }
        }
        .disabled(running.isEmpty)
        Divider()
        Button("Settings…") { request(.settings(machines)) }
            .disabled(!allStopped)
            .menuShortcut("i", in: placement)
        changeBundleButton
        Divider()
        Button("Export…") { library.chooseExport(machines.map(\.path)) }
            .disabled(!allStopped)
            .menuShortcut("e", in: placement)
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(machines.map(\.path.url))
        }
        .menuShortcut("r", [.command, .shift], in: placement)
        if placement == .full {
            Divider()
            Button("Delete…", role: .destructive) { requestDeletion(machines.map(\.path)) }
                .disabled(!allStopped)
        }
    }

    // MARK: - One machine

    /// Run, configure, the machine's files, maintenance and logs, then
    /// Delete.
    @ViewBuilder
    private func singleActions(_ machine: VPhoneLaunchpadMachine) -> some View {
        let state = library.state(of: machine.path)
        let isStopped = state == .stopped
        if showsRunItems {
            switch state {
            case .running:
                Button("Stop") { library.stop([machine]) }
                    .menuShortcut(".", [.command, .shift], in: placement)
                // For a guest that hangs or ignores Stop.
                Button("Terminate") { Task { await library.forceStop(machine.path) } }
            case .stopped:
                Button("Start") { library.start([machine]) }
                    .menuShortcut(.return, in: placement)
                Button("Start Headless") { library.start([machine], headless: true) }
                    .menuShortcut(.return, [.command, .option], in: placement)
            case let .busy(activity):
                Text(activity)
            }
            Divider()
            Button("Settings…") { request(.settings([machine])) }
                .disabled(!isStopped)
                .menuShortcut("i", in: placement)
            // It works on the running guest, and says so when it is not.
            Button("Guest System…") { request(.guestSystem(machine.path)) }
                .disabled(library.creation(for: machine.path)?.isRunning == true)
            changeBundleButton
            Divider()
        }
        if showsEditItems {
            Button("Rename…") { request(.rename(machine.path)) }
                .disabled(!isStopped)
            Button("Clone…") { request(.clone(machine.path)) }
                .disabled(!isStopped)
                .menuShortcut("d", in: placement)
        }
        if showsRunItems {
            // Open while the machine runs too, to read the list; taking,
            // reverting and deleting wait for it to stop.
            Button("Snapshots…") { request(.snapshots(machine.path)) }
                .disabled(library.creation(for: machine.path)?.isRunning == true)
                .menuShortcut("s", [.command, .shift], in: placement)
            Button("Export…") { library.chooseExport([machine.path]) }
                .disabled(!isStopped)
                .menuShortcut("e", in: placement)
            Divider()
            Menu("Maintenance") {
                Button("Install Custom Firmware") {
                    Task { await library.installCustomFirmware(machine.path) }
                }
                // Only for an unfinished install: that is when the restore tree it
                // reads is still there. A finished one removes it.
                .disabled(!isStopped || machine.customFirmwareInstalled != false)
                // The finished-install counterpart: redeploys the machine's own
                // bundle's guest resources without the restore tree.
                Button("Update Guest Environment") {
                    Task { await library.updateGuestEnvironment(machine.path) }
                }
                .disabled(!isStopped || machine.restoreInfo == nil || machine.customFirmwareInstalled == false)
            }
            Menu("Logs") {
                Button("Open Console") { request(.console(machine.path)) }
                    .menuShortcut("l", [.command, .option], in: placement)
                Button("Show Console Log") {
                    NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.path))
                }
                Button("Show Patch Log") {
                    NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.path, suffix: "-patch"))
                }
                .disabled(!FileManager.default.fileExists(atPath: VPhoneLaunchpadMachineLibrary.consoleLog(machine.path, suffix: "-patch").path))
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([machine.path.url])
            }
            .menuShortcut("r", [.command, .shift], in: placement)
        }
        if placement == .full {
            Divider()
            Button("Delete…", role: .destructive) { requestDeletion([machine.path]) }
                .disabled(!isStopped)
        }
    }

    /// Rebinding applies at the next start, so running machines may change
    /// too. A machine still being created gets its bundle from the pipeline.
    private var changeBundleButton: some View {
        Button("Change Core Bundle…") { request(.changeBundle(machines)) }
            .disabled(model.bundles.selectableVersions.isEmpty
                || machines.contains { library.creation(for: $0.path)?.isRunning == true })
    }

    private func request(_ sheet: VPhoneLaunchpadMachinesView.Sheet) {
        willRequest()
        model.machineSheetRequest = sheet
    }

    private func requestDeletion(_ paths: [VPhoneLaunchpadMachinePath]) {
        willRequest()
        model.deletionRequest = paths
    }
}

// MARK: - Start and stop

extension VPhoneLaunchpadMachineLibrary {
    /// Starts the machines one after another, without waiting.
    func start(_ machines: [VPhoneLaunchpadMachine], headless: Bool = false) {
        Task {
            for machine in machines {
                await start(machine.path, headless: headless)
            }
        }
    }

    /// Stops the machines together, without waiting. With Option held at the
    /// click, every Stop button force stops instead.
    func stop(_ machines: [VPhoneLaunchpadMachine]) {
        let force = NSEvent.modifierFlags.contains(.option)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for machine in machines {
                    group.addTask { force ? await self.forceStop(machine.path) : await self.stop(machine.path) }
                }
            }
        }
    }
}

// MARK: - Export

extension VPhoneLaunchpadMachineLibrary {
    /// Export…: straight to the save panel, `<name>.vpea`; several machines
    /// go into one folder, one archive each. The restore IPSWs are never
    /// included: they belong to the IPSW cache, and a machine runs without
    /// them.
    func chooseExport(_ machines: [VPhoneLaunchpadMachinePath]) {
        if machines.count == 1 {
            let machine = machines[0]
            let panel = NSSavePanel()
            panel.title = String(localized: "Export \(machine.name)")
            panel.allowedContentTypes = [.vphoneExportedArchive]
            panel.nameFieldStringValue = Self.exportFileName(machine)
            // Saving as Mulberry.vpea, not Mulberry: the archive type is
            // what Import… and a double-click recognize.
            panel.isExtensionHidden = false
            panel.present { url in
                Task { await self.export([(machine, url)]) }
            }
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Export \(machines.count) Machines")
        panel.prompt = String(localized: "Export")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.present { folder in
            let items = machines.map { ($0, folder.appendingPathComponent(Self.exportFileName($0))) }
            Task { await self.export(items) }
        }
    }

    private static func exportFileName(_ machine: VPhoneLaunchpadMachinePath) -> String {
        "\(machine.name).vpea"
    }
}

// MARK: - Import

extension VPhoneLaunchpadMachineLibrary {
    /// File > Import… and the empty list's Import…: one archive at a time.
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Machine")
        panel.message = String(localized: "Choose an exported machine archive (.vpea).")
        panel.allowedContentTypes = Self.importableTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.present { url in
            Task { await self.importArchive(url) }
        }
    }

    /// Imports the dropped files Import… would accept, one after another.
    /// False when there are none, so the drop is refused.
    func importDropped(_ urls: [URL]) -> Bool {
        let archives = urls.filter { url in
            url.isFileURL && Self.importableTypes.contains { type in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
            }
        }
        guard !archives.isEmpty else {
            return false
        }
        Task {
            for archive in archives {
                await importArchive(archive)
            }
        }
        return true
    }
}

// MARK: - Shortcuts

private extension View {
    /// A keyboard shortcut only in the main menu: the same items in the
    /// context menu and the menu bar would claim it twice.
    @ViewBuilder
    func menuShortcut(
        _ key: KeyEquivalent,
        _ modifiers: EventModifiers = .command,
        in placement: VPhoneLaunchpadMachineActions.Placement,
    ) -> some View {
        if placement == .full {
            self
        } else {
            keyboardShortcut(key, modifiers: modifiers)
        }
    }
}
