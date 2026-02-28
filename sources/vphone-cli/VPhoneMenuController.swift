import AppKit
import Foundation

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController {
    private let keyHelper: VPhoneKeyHelper

    init(keyHelper: VPhoneKeyHelper) {
        self.keyHelper = keyHelper
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

        // Keys menu — NO key equivalents to avoid intercepting VM keyboard input
        let keysMenuItem = NSMenuItem()
        let keysMenu = NSMenu(title: "Keys")

        // iOS hardware keyboard shortcuts
        keysMenu.addItem(makeItem("Home Screen (Cmd+H)", action: #selector(sendHome)))
        keysMenu.addItem(makeItem("Spotlight (Cmd+Space)", action: #selector(sendSpotlight)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Return", action: #selector(sendReturn)))
        keysMenu.addItem(makeItem("Escape", action: #selector(sendEscape)))
        keysMenu.addItem(makeItem("Space", action: #selector(sendSpace)))
        keysMenu.addItem(makeItem("Tab", action: #selector(sendTab)))
        keysMenu.addItem(makeItem("Delete", action: #selector(sendDeleteKey)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Arrow Up", action: #selector(sendArrowUp)))
        keysMenu.addItem(makeItem("Arrow Down", action: #selector(sendArrowDown)))
        keysMenu.addItem(makeItem("Arrow Left", action: #selector(sendArrowLeft)))
        keysMenu.addItem(makeItem("Arrow Right", action: #selector(sendArrowRight)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Power", action: #selector(sendPower)))
        keysMenu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp)))
        keysMenu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Shift (tap)", action: #selector(sendShift)))
        keysMenu.addItem(makeItem("Command (tap)", action: #selector(sendCommand)))

        keysMenuItem.submenu = keysMenu
        mainMenu.addItem(keysMenuItem)

        // Type menu
        let typeMenuItem = NSMenuItem()
        let typeMenu = NSMenu(title: "Type")
        typeMenu.addItem(makeItem("Type ASCII from Clipboard", action: #selector(typeFromClipboard)))
        typeMenuItem.submenu = typeMenu
        mainMenu.addItem(typeMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Menu Actions (delegate to helper)

    @objc private func sendHome() {
        keyHelper.sendHome()
    }

    @objc private func sendSpotlight() {
        keyHelper.sendSpotlight()
    }

    @objc private func sendReturn() {
        keyHelper.sendReturn()
    }

    @objc private func sendEscape() {
        keyHelper.sendEscape()
    }

    @objc private func sendSpace() {
        keyHelper.sendSpace()
    }

    @objc private func sendTab() {
        keyHelper.sendTab()
    }

    @objc private func sendDeleteKey() {
        keyHelper.sendDeleteKey()
    }

    @objc private func sendArrowUp() {
        keyHelper.sendArrowUp()
    }

    @objc private func sendArrowDown() {
        keyHelper.sendArrowDown()
    }

    @objc private func sendArrowLeft() {
        keyHelper.sendArrowLeft()
    }

    @objc private func sendArrowRight() {
        keyHelper.sendArrowRight()
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

    @objc private func sendShift() {
        keyHelper.sendShift()
    }

    @objc private func sendCommand() {
        keyHelper.sendCommand()
    }

    @objc private func typeFromClipboard() {
        keyHelper.typeFromClipboard()
    }
}
