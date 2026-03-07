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

        guard control.canInstallIPA else {
            showAlert(
                title: "Install IPA",
                message: VPhoneControl.ipaInstallUnavailableMessage,
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
        panel.message = "Choose an IPA to install in the guest."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        Task {
            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
            } catch {
                showAlert(title: "Install IPA", message: "\(error)", style: .warning)
            }
        }
    }
}
