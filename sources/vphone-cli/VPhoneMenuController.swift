import AppKit
import Foundation

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController {
    private let keyHelper: VPhoneKeyHelper
    private let control: VPhoneControl

    var onFilesPressed: (() -> Void)?

    init(keyHelper: VPhoneKeyHelper, control: VPhoneControl) {
        self.keyHelper = keyHelper
        self.control = control
        setupMenuBar()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "vphone")
        appMenu.addItem(withTitle: "Quit vphone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Keys menu — hardware buttons that need vphoned HID injection
        let keysMenuItem = NSMenuItem()
        let keysMenu = NSMenu(title: "Keys")
        keysMenu.addItem(makeItem("Home Screen", action: #selector(sendHome)))
        keysMenu.addItem(makeItem("Power", action: #selector(sendPower)))
        keysMenu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp)))
        keysMenu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Spotlight (Cmd+Space)", action: #selector(sendSpotlight)))
        keysMenuItem.submenu = keysMenu
        mainMenu.addItem(keysMenuItem)

        // Type menu
        let typeMenuItem = NSMenuItem()
        let typeMenu = NSMenu(title: "Type")
        typeMenu.addItem(makeItem("Type ASCII from Clipboard", action: #selector(typeFromClipboard)))
        typeMenuItem.submenu = typeMenu
        mainMenu.addItem(typeMenuItem)

        // vphoned menu — guest agent commands
        let agentMenuItem = NSMenuItem()
        let agentMenu = NSMenu(title: "vphoned")
        agentMenu.addItem(makeItem("File Browser", action: #selector(openFiles)))
        agentMenu.addItem(NSMenuItem.separator())
        agentMenu.addItem(makeItem("Developer Mode Status", action: #selector(devModeStatus)))
        agentMenu.addItem(makeItem("Enable Developer Mode", action: #selector(devModeEnable)))
        agentMenu.addItem(NSMenuItem.separator())
        agentMenu.addItem(makeItem("Ping", action: #selector(sendPing)))
        agentMenuItem.submenu = agentMenu
        mainMenu.addItem(agentMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Keys (hardware buttons via vphoned HID)

    @objc private func sendHome() {
        keyHelper.sendHome()
    }

    @objc private func sendPower() {
        keyHelper.sendPower()
    }

    @objc private func sendVolumeUp() {
        keyHelper.sendVolumeUp()
    }

    @objc private func sendVolumeDown() {
        keyHelper.sendVolumeDown()
    }

    @objc private func sendSpotlight() {
        keyHelper.sendSpotlight()
    }

    @objc private func typeFromClipboard() {
        keyHelper.typeFromClipboard()
    }

    // MARK: - vphoned Agent Commands

    @objc private func openFiles() {
        onFilesPressed?()
    }

    @objc private func devModeStatus() {
        control.sendDevModeStatus()
    }

    @objc private func devModeEnable() {
        control.sendDevModeEnable()
    }

    @objc private func sendPing() {
        control.sendPing()
    }
}
