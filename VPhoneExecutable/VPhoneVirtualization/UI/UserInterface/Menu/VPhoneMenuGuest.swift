import AppKit

// MARK: - Guest Menu

/// Guest data the Mac reads and writes: files, Keychain, clipboard and
/// preference domains.
extension VPhoneMenuController {
    func buildGuestMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Guest", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Guest")
        menu.autoenablesItems = false

        let fileBrowser = makeItem(
            "File Browser",
            action: #selector(openFiles),
            keyEquivalent: "f",
            modifiers: [.command, .shift],
        )
        fileBrowser.isEnabled = false
        connectFileBrowserItem = fileBrowser
        menu.addItem(fileBrowser)

        let keychainBrowser = makeItem(
            "Keychain Browser",
            action: #selector(openKeychain),
            keyEquivalent: "k",
            modifiers: [.command, .shift],
        )
        keychainBrowser.isEnabled = false
        connectKeychainBrowserItem = keychainBrowser
        menu.addItem(keychainBrowser)

        menu.addItem(NSMenuItem.separator())

        let clipGet = makeItem(
            "Clipboard",
            action: #selector(getClipboard),
            keyEquivalent: "c",
            modifiers: [.command, .shift],
        )
        clipGet.isEnabled = false
        clipboardGetItem = clipGet
        menu.addItem(clipGet)

        let clipSet = makeItem("Set Clipboard Text…", action: #selector(setClipboardText))
        clipSet.isEnabled = false
        clipboardSetItem = clipSet
        menu.addItem(clipSet)

        menu.addItem(NSMenuItem.separator())

        let settingsGet = makeItem(
            "Preferences",
            action: #selector(readSetting),
            keyEquivalent: "p",
            modifiers: [.command, .shift],
        )
        settingsGet.isEnabled = false
        settingsGetItem = settingsGet
        menu.addItem(settingsGet)

        let settingsSet = makeItem("Write Preference…", action: #selector(writeSetting))
        settingsSet.isEnabled = false
        settingsSetItem = settingsSet
        menu.addItem(settingsSet)

        item.submenu = menu
        return item
    }

    func updateSettingsAvailability(available: Bool) {
        settingsGetItem?.isEnabled = available
        settingsSetItem?.isEnabled = available
    }

    func updateConnectAvailability(available: Bool) {
        connectFileBrowserItem?.isEnabled = available
        connectKeychainBrowserItem?.isEnabled = available
        connectDevModeStatusItem?.isEnabled = available
        connectPingItem?.isEnabled = available
        connectGuestHashItem?.isEnabled = available
    }

    func updateClipboardAvailability(available: Bool) {
        clipboardGetItem?.isEnabled = available
        clipboardSetItem?.isEnabled = available
    }

    @objc func openFiles() {
        onFilesPressed?()
    }

    @objc func openKeychain() {
        onKeychainPressed?()
    }

    // MARK: - Clipboard & Preferences

    @objc func getClipboard() {
        guestToolsWindowController.show(.getClipboard)
    }

    @objc func setClipboardText() {
        guestToolsWindowController.show(.setClipboard)
    }

    @objc func readSetting() {
        guestToolsWindowController.show(.readSetting)
    }

    @objc func writeSetting() {
        guestToolsWindowController.show(.writeSetting)
    }
}
