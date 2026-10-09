import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The actions for one or more machines, shared by the toolbar's Actions
/// menu, the table's context menu and each machine's menu in the menu bar.
/// Several machines get the batch actions: one settings edit, export and
/// delete, which need every machine stopped, then start and stop.
///
/// Sheets and the delete confirmation belong to the machine list, so those
/// items leave a request on the model that the list presents. The menu bar
/// passes `willRequest` to open the window first.
struct VPhoneLaunchpadMachineActions: View {
    let machines: [VPhoneLaunchpadMachine]
    var willRequest: () -> Void = {}
    @Environment(VPhoneLaunchpadModel.self) private var model

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
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
            Button("Settings…") { request(.settings(machines)) }
                .disabled(!allStopped)
            changeBundleButton
            Button("Export…") { request(.export(machines.map(\.path))) }
                .disabled(!allStopped)
            Button("Delete…", role: .destructive) { requestDeletion(machines.map(\.path)) }
                .disabled(!allStopped)
            Divider()
            Button("Start") { library.start(stopped) }
                .disabled(stopped.isEmpty)
            Button("Start Headless") { library.start(stopped, headless: true) }
                .disabled(stopped.isEmpty)
            Button("Stop") { library.stop(running) }
                .disabled(running.isEmpty)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(machines.map(\.path.url))
            }
        } else if let machine = machines.first {
            let state = library.state(of: machine.path)
            let isStopped = state == .stopped
            switch state {
            case .running:
                Button("Stop") { library.stop([machine]) }
            case .stopped:
                Button("Start") { library.start([machine]) }
                Button("Start Headless") { library.start([machine], headless: true) }
            case let .busy(activity):
                Text(activity)
            }
            Divider()
            Button("Settings…") { request(.settings([machine])) }
                .disabled(!isStopped)
            // It works on the running guest, and says so when it is not.
            Button("Guest System…") { request(.guestSystem(machine.path)) }
                .disabled(library.creation(for: machine.path)?.isRunning == true)
            changeBundleButton
            Button("Rename…") { request(.rename(machine.path)) }
                .disabled(!isStopped)
            Button("Clone…") { request(.clone(machine.path)) }
                .disabled(!isStopped)
            Button("Export…") { request(.export([machine.path])) }
                .disabled(!isStopped)
            // Open while the machine runs too, to read the list; taking,
            // reverting and deleting wait for it to stop.
            Button("Snapshots…") { request(.snapshots(machine.path)) }
                .disabled(library.creation(for: machine.path)?.isRunning == true)
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
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([machine.path.url])
            }
            Button("Open Console") { request(.console(machine.path)) }
            Button("Recent Commands") { request(.commands) }
            Button("Show Console Log") {
                NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.path))
            }
            Button("Show Patch Log") {
                NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine.path, suffix: "-patch"))
            }
            .disabled(!FileManager.default.fileExists(atPath: VPhoneLaunchpadMachineLibrary.consoleLog(machine.path, suffix: "-patch").path))
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
        guard !archives.isEmpty, globalActivity == nil else {
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
