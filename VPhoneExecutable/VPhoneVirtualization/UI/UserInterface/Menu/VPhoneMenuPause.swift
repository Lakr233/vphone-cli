import AppKit

// MARK: - Pause

/// Device > Pause Guest / Resume Guest: stops the guest where it is and lets
/// it run on later (`VPhoneVirtualMachine.pause()`).
extension VPhoneMenuController {
    func buildPauseItem() -> NSMenuItem {
        let item = makeItem("Pause Guest", action: #selector(togglePause), symbol: "pause.circle")
        item.toolTip = VPhoneLocalization.text(
            "Stop the guest where it is, with its apps and clock, until you resume it.",
        )
        item.isEnabled = false
        pauseItem = item
        return item
    }

    /// Follows `isPaused`; enabled while a VM exists and no memory dump of it
    /// is being saved.
    func updatePauseItem() {
        guard let item = pauseItem else { return }
        let paused = vm?.isPaused == true
        item.title = VPhoneLocalization.text(paused ? "Resume Guest" : "Pause Guest")
        item.image = menuSymbol(paused ? "play.circle" : "pause.circle")
        item.isEnabled = vm != nil && !isSavingMemoryDump
    }

    @objc func togglePause() {
        guard let vm else { return }
        Task { @MainActor in
            do {
                if vm.isPaused {
                    try await vm.resume()
                } else {
                    try await vm.pause()
                }
            } catch {
                VPhoneAlert.present(
                    title: vm.isPaused ? "Unable to Resume Guest" : "Unable to Pause Guest",
                    message: error.localizedDescription,
                    style: .warning,
                )
            }
        }
    }

    /// Restart and Shut Down need the guest to answer, so a paused guest runs
    /// on first, once a pause or memory dump on its way has finished.
    func resumeIfPaused() async throws {
        try await vm?.resumeWhenSettled()
    }
}
