import AppKit
import Foundation

// MARK: - Install Menu

extension VPhoneMenuController {
    func buildInstallMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Install")
        menu.addItem(makeItem("Install IPA/TIPA...", action: #selector(installIPAFromDisk)))
        item.submenu = menu
        return item
    }

    @objc func installIPAFromDisk() {
        guard control.isConnected else {
            showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VPhoneInstallPackage.allowedContentTypes
        panel.prompt = "Install"
        panel.message = "Choose an IPA or TIPA package to install in the guest."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        Task {
            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                showAlert(
                    title: "Install App Package",
                    message: VPhoneInstallPackage.successMessage(
                        for: url.lastPathComponent,
                        detail: result
                    ),
                    style: .informational
                )
            } catch {
                showAlert(title: "Install App Package", message: "\(error)", style: .warning)
            }
        }
    }
}
