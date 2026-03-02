import AppKit

// MARK: - Connect Menu

extension VPhoneMenuController {
    func buildConnectMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Connect")
        menu.addItem(makeItem("File Browser", action: #selector(openFiles)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Developer Mode Status", action: #selector(devModeStatus)))
        menu.addItem(makeItem("Enable Developer Mode", action: #selector(devModeEnable)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Ping", action: #selector(sendPing)))
        menu.addItem(makeItem("Guest Version", action: #selector(queryGuestVersion)))
        item.submenu = menu
        return item
    }

    @objc func openFiles() {
        onFilesPressed?()
    }

    @objc func devModeStatus() {
        Task {
            do {
                let status = try await control.sendDevModeStatus()
                showAlert(
                    title: "Developer Mode",
                    message: status.enabled ? "Developer Mode is enabled." : "Developer Mode is disabled.",
                    style: .informational
                )
            } catch {
                showAlert(title: "Developer Mode", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func devModeEnable() {
        Task {
            do {
                let result = try await control.sendDevModeEnable()
                showAlert(
                    title: "Developer Mode",
                    message: result.message.isEmpty
                        ? (result.alreadyEnabled ? "Developer Mode already enabled." : "Developer Mode enabled.")
                        : result.message,
                    style: .informational
                )
            } catch {
                showAlert(title: "Developer Mode", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func sendPing() {
        Task {
            do {
                try await control.sendPing()
                showAlert(title: "Ping", message: "pong", style: .informational)
            } catch {
                showAlert(title: "Ping", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func queryGuestVersion() {
        Task {
            do {
                let hash = try await control.sendVersion()
                showAlert(title: "Guest Version", message: "build: \(hash)", style: .informational)
            } catch {
                showAlert(title: "Guest Version", message: "\(error)", style: .warning)
            }
        }
    }

    // MARK: - Alert

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
