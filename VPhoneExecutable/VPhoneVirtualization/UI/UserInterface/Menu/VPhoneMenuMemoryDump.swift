import AppKit

// MARK: - Memory Dump

/// Diagnostics > Save Memory Dump…: asks for a folder, then saves the guest's
/// memory cores into a new folder named for the machine and the time.
extension VPhoneMenuController {
    private static let memoryDumpFolderKey = "MemoryDumpFolder"

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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = VPhoneLocalization.text("Save Here")
        panel.message = VPhoneLocalization.format(
            "A folder for this dump is created in the folder you choose. It can take up to %@. "
                + "The guest pauses while its memory is copied, usually 10 to 20 seconds, then carries on.",
            VPhoneMemoryDump.Failure.gigabytes(VPhoneMemoryDump.spaceNeeded(memorySize: vm?.memorySize ?? 0)),
        )
        let defaults = UserDefaults.standard
        panel.directoryURL = defaults.url(forKey: Self.memoryDumpFolderKey)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        VPhoneAlert.present(panel) { [weak self] response in
            guard let self, response == .OK, let parent = panel.url else { return }
            defaults.set(parent, forKey: Self.memoryDumpFolderKey)
            startMemoryDump(in: parent)
        }
    }

    private func startMemoryDump(in parent: URL) {
        guard let vm else { return }
        let name = machine.lastPathComponent
        let folder = parent.appendingPathComponent(VPhoneMemoryDump.folderName(machine: name, date: Date()))
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
                let dump = try await VPhoneMemoryDump.save(from: vm, machineName: name, to: folder)
                VPhoneAlert.present(
                    title: "Memory Dump",
                    message: VPhoneLocalization.format("Saved to %@", dump.folder.path),
                    style: .informational,
                    buttons: ["OK", "Reveal in Finder"],
                ) { response in
                    if response == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([dump.folder])
                    }
                }
            } catch {
                VPhoneAlert.present(title: "Memory Dump", message: error.localizedDescription, style: .warning)
            }
        }
    }
}
