import AppKit

// MARK: - Connect Menu

extension VPhoneMenuController {
    func buildConnectMenu() -> NSMenuItem {
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

        let keychainBrowser = makeItem("Keychain Browser", action: #selector(openKeychain))
        keychainBrowser.isEnabled = false
        connectKeychainBrowserItem = keychainBrowser
        menu.addItem(keychainBrowser)

        menu.addItem(NSMenuItem.separator())

        let clipboardMenu = NSMenu(title: "Clipboard")
        clipboardMenu.autoenablesItems = false
        let clipGet = makeItem(
            "Get Clipboard",
            action: #selector(getClipboard),
            keyEquivalent: "c",
            modifiers: [.command, .shift],
        )
        clipGet.isEnabled = false
        clipboardGetItem = clipGet
        clipboardMenu.addItem(clipGet)

        let clipSet = makeItem("Set Clipboard Text…", action: #selector(setClipboardText))
        clipSet.isEnabled = false
        clipboardSetItem = clipSet
        clipboardMenu.addItem(clipSet)
        let clipboardItem = NSMenuItem(title: "Clipboard", action: nil, keyEquivalent: "")
        clipboardItem.submenu = clipboardMenu
        menu.addItem(clipboardItem)

        let settingsMenu = NSMenu(title: "Settings")
        settingsMenu.autoenablesItems = false
        let settingsGet = makeItem("Read Setting…", action: #selector(readSetting))
        settingsGet.isEnabled = false
        settingsGetItem = settingsGet
        settingsMenu.addItem(settingsGet)

        let settingsSet = makeItem("Write Setting…", action: #selector(writeSetting))
        settingsSet.isEnabled = false
        settingsSetItem = settingsSet
        settingsMenu.addItem(settingsSet)
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let diagnosticsMenu = NSMenu(title: "Diagnostics")
        diagnosticsMenu.autoenablesItems = false
        let devModeStatus = makeItem("Developer Mode Status", action: #selector(devModeStatus))
        devModeStatus.isEnabled = false
        connectDevModeStatusItem = devModeStatus
        diagnosticsMenu.addItem(devModeStatus)

        let ping = makeItem("Ping", action: #selector(sendPing))
        ping.isEnabled = false
        connectPingItem = ping
        diagnosticsMenu.addItem(ping)

        let guestHash = makeItem("Guest Agent Hash", action: #selector(queryGuestHash))
        guestHash.isEnabled = false
        connectGuestHashItem = guestHash
        diagnosticsMenu.addItem(guestHash)
        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)

        menu.addItem(NSMenuItem.separator())

        let deviceMenu = NSMenu(title: "Device Overrides")
        deviceMenu.addItem(buildLocationSubmenu())
        deviceMenu.addItem(buildBatterySubmenu())
        deviceMenu.addItem(buildCameraSubmenu())
        let deviceItem = NSMenuItem(title: "Device Overrides", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)

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

    @objc func openFiles() {
        onFilesPressed?()
    }

    @objc func openKeychain() {
        onKeychainPressed?()
    }

    @objc func devModeStatus() {
        Task {
            do {
                let enabled = try await control.isDeveloperModeEnabled()
                VPhoneAlert.present(
                    title: "Developer Mode",
                    message: enabled ? "Developer Mode is enabled." : "Developer Mode is disabled.",
                    style: .informational,
                )
            } catch {
                VPhoneAlert.present(
                    title: "Developer Mode",
                    message: "Unable to read Developer Mode status. Check that the guest agent is connected, "
                        + "then try again.",
                    style: .warning,
                )
            }
        }
    }

    @objc func sendPing() {
        Task {
            do {
                try await control.sendPing()
                VPhoneAlert.present(title: "Ping", message: "The guest responded.", style: .informational)
            } catch {
                VPhoneAlert.present(
                    title: "Ping",
                    message: "The guest did not respond. Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
            }
        }
    }

    @objc func queryGuestHash() {
        Task {
            do {
                let hash = try await control.guestBinaryHash()
                VPhoneAlert.present(title: "Guest Agent Hash", message: "SHA-256: \(hash)", style: .informational)
            } catch {
                VPhoneAlert.present(
                    title: "Guest Agent Hash",
                    message: "Unable to read the guest agent hash. Check that the guest agent is connected, "
                        + "then try again.",
                    style: .warning,
                )
            }
        }
    }

    func updateClipboardAvailability(available: Bool) {
        clipboardGetItem?.isEnabled = available
        clipboardSetItem?.isEnabled = available
    }

    // MARK: - Clipboard & Settings

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
