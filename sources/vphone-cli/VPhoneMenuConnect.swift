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
        control.sendDevModeStatus()
    }

    @objc func devModeEnable() {
        control.sendDevModeEnable()
    }

    @objc func sendPing() {
        control.sendPing()
    }

    @objc func queryGuestVersion() {
        control.sendVersion()
    }
}
