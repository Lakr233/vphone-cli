import AppKit

// MARK: - Memory Dump

/// Diagnostics > Save Memory Dump…: asks for a folder, then saves the guest's
/// memory cores into a new folder named for the machine and the time. A
/// checkbox in the panel asks for a physical memory image instead. The
/// Processes window saves one process's memory through `dumpProcessMemory`.
extension VPhoneMenuController {
    private static let memoryDumpFolderKey = "MemoryDumpFolder"
    private static let physicalDumpKey = "MemoryDumpPhysical"

    func buildMemoryDumpItem() -> NSMenuItem {
        let item = makeItem("Save Memory Dump…", action: #selector(saveMemoryDump), symbol: "memorychip")
        item.toolTip = VPhoneLocalization.text(
            "Save the guest's memory and every vCPU's registers as Mach-O cores that LLDB opens.",
        )
        item.isEnabled = false
        memoryDumpItem = item
        return item
    }

    /// Enabled while a VM exists whose macOS offers the core writer, and no
    /// dump of it is being saved.
    func updateMemoryDumpItem() {
        guard let item = memoryDumpItem else { return }
        item.title = VPhoneLocalization.text(isSavingMemoryDump ? "Saving Memory Dump…" : "Save Memory Dump…")
        item.isEnabled = !isSavingMemoryDump
            && vm.map { VPhoneMemoryDump.isSupported(by: $0.virtualMachine) } == true
    }

    @objc func saveMemoryDump() {
        guard vm != nil, !isSavingMemoryDump else { return }
        let panel = Self.memoryDumpPanel(message: VPhoneLocalization.format(
            "Saves into a new folder here, up to %@. The guest pauses for 10–20 seconds.",
            VPhoneMemoryDump.Failure.gigabytes(VPhoneMemoryDump.spaceNeeded(memorySize: vm?.memorySize ?? 0)),
        ))
        let defaults = UserDefaults.standard
        let physical = NSButton(
            checkboxWithTitle: VPhoneLocalization.text("Physical memory image"),
            target: nil,
            action: nil,
        )
        physical.state = defaults.bool(forKey: Self.physicalDumpKey) ? .on : .off
        physical.toolTip = VPhoneLocalization.text(
            "Save all of the guest's RAM, kernel and every process, at its physical addresses, instead of "
                + "the cores of the kernel and the vCPUs.",
        )
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: physical.fittingSize.width + 40, height: 36))
        physical.frame.origin = NSPoint(x: 20, y: (36 - physical.fittingSize.height) / 2)
        physical.frame.size = physical.fittingSize
        accessory.addSubview(physical)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        VPhoneAlert.present(panel) { [weak self] response in
            guard let self, response == .OK, let parent = panel.url else { return }
            defaults.set(parent, forKey: Self.memoryDumpFolderKey)
            defaults.set(physical.state == .on, forKey: Self.physicalDumpKey)
            startMemoryDump(in: parent, physical: physical.state == .on)
        }
    }

    /// Saves the resident memory of guest process `pid`, read from the host
    /// through the guest kernel's page tables. `name` is the process's
    /// `p_comm` as the Processes window last saw it; a different process
    /// under that pid is refused.
    func dumpProcessMemory(pid: Int32, name: String) {
        guard vm != nil else { return }
        guard !isSavingMemoryDump else {
            VPhoneAlert.present(
                title: "Memory Dump",
                message: VPhoneMemoryDump.Failure.busy.localizedDescription,
                style: .warning,
            )
            return
        }
        let panel = Self.memoryDumpPanel(message: VPhoneLocalization.format(
            "Saves the memory of %@ (pid %d) into a new folder here. The guest pauses for a few seconds.",
            name.isEmpty ? VPhoneLocalization.text("the process") : name,
            pid,
        ))
        VPhoneAlert.present(panel) { [weak self] response in
            guard let self, response == .OK, let parent = panel.url else { return }
            UserDefaults.standard.set(parent, forKey: Self.memoryDumpFolderKey)
            startProcessDump(in: parent, pid: pid, name: name)
        }
    }

    private static func memoryDumpPanel(message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = VPhoneLocalization.text("Save Here")
        panel.message = message
        panel.directoryURL = UserDefaults.standard.url(forKey: memoryDumpFolderKey)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel
    }

    private func startMemoryDump(in parent: URL, physical: Bool) {
        guard let vm else { return }
        let name = machine.lastPathComponent
        let folder = parent.appendingPathComponent(VPhoneMemoryDump.folderName(machine: name, date: Date()))
        runMemoryDump {
            if physical {
                let dump = try await VPhonePhysicalMemoryDump.save(from: vm, machineName: name, to: folder)
                return (dump.folder, dump.resumeFailure)
            } else {
                return try await (VPhoneMemoryDump.save(from: vm, machineName: name, to: folder).folder, nil)
            }
        }
    }

    private func startProcessDump(in parent: URL, pid: Int32, name: String) {
        guard let vm else { return }
        let machineName = machine.lastPathComponent
        let folder = parent.appendingPathComponent(VPhoneProcessMemoryDump.folderName(
            machine: machineName, process: name.isEmpty ? "pid" : name, pid: pid, date: Date(),
        ))
        runMemoryDump {
            let dump = try await VPhoneProcessMemoryDump.save(
                from: vm, machineName: machineName, pid: pid, expectedName: name.isEmpty ? nil : name, to: folder,
            )
            return (dump.folder, dump.resumeFailure)
        }
    }

    /// Runs one dump at a time, then says where it went or why it failed,
    /// and whether the guest is still paused.
    private func runMemoryDump(_ save: @escaping @MainActor () async throws -> (URL, String?)) {
        isSavingMemoryDump = true
        updateMemoryDumpItem()
        updatePauseItem()
        Task { @MainActor in
            defer {
                isSavingMemoryDump = false
                updateMemoryDumpItem()
                updatePauseItem()
            }
            do {
                let (folder, resumeFailure) = try await save()
                let saved = VPhoneLocalization.format("Saved to %@", folder.path)
                VPhoneAlert.present(
                    title: "Memory Dump",
                    message: resumeFailure.map { saved + "\n\n" + $0 } ?? saved,
                    style: resumeFailure == nil ? .informational : .warning,
                    buttons: ["OK", "Reveal in Finder"],
                ) { response in
                    if response == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            } catch {
                VPhoneAlert.present(title: "Memory Dump", message: error.localizedDescription, style: .warning)
            }
        }
    }
}
