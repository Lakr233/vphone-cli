import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Install Menu

extension VPhoneMenuController {
    func buildInstallMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Install")
        menu.addItem(makeItem("Install IPA...", action: #selector(installIPAFromDisk)))
        item.submenu = menu
        return item
    }

    @objc func installIPAFromDisk() {
        guard control.isConnected else {
            showAlert(title: "Install IPA", message: "Guest is not connected.", style: .warning)
            return
        }

        guard control.guestCaps.contains("tslite_install") else {
            showAlert(
                title: "Install IPA",
                message: "TrollStore Lite helper is not available in the guest.",
                style: .warning
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "ipa") ?? .data,
        ]
        panel.prompt = "Install"
        panel.message = "Choose an IPA to install through TrollStore Lite."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        Task {
            do {
                let result = try await control.installIPAWithTrollStoreLite(localURL: url)
                showAlert(title: "Install IPA", message: result, style: .informational)
            } catch {
                showAlert(title: "Install IPA", message: "\(error)", style: .warning)
            }
        }
    }
}
