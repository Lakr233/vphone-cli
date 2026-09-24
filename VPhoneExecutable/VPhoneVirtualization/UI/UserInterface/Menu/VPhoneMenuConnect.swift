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

        let installBootstrap = makeItem("Install Bootstrap…", action: #selector(installBootstrap))
        installBootstrap.isEnabled = false
        installBootstrapItem = installBootstrap
        menu.addItem(installBootstrap)

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

    func updateBootstrapAvailability(available: Bool) {
        installBootstrapItem?.isEnabled = available && !isInstallingBootstrap
    }

    @objc func installBootstrap() {
        VPhoneAlert.present(
            title: "Install Bootstrap",
            message: "Choose the bootstrap layout. This installs the latest Irisin release once in the guest.",
            style: .informational,
            buttons: ["Rootless", "RootHide", "Cancel"],
        ) { [weak self] response in
            let layout: String
            switch response {
            case .alertFirstButtonReturn: layout = "rootless"
            case .alertSecondButtonReturn: layout = "roothide"
            default: return
            }
            self?.performBootstrapInstallation(layout: layout)
        }
    }

    private func performBootstrapInstallation(layout: String) {
        isInstallingBootstrap = true
        installBootstrapItem?.isEnabled = false
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Install Bootstrap")
        alert.informativeText = VPhoneLocalization.text("Installing the latest Irisin release in the guest.")
        let close = alert.addButton(withTitle: VPhoneLocalization.text("Close"))
        close.isEnabled = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        let statusLabel = NSTextField(labelWithString: VPhoneLocalization.text("Preparing bootstrap…"))
        statusLabel.frame = NSRect(x: 0, y: 26, width: 360, height: 22)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        accessory.addSubview(statusLabel)
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 4, width: 360, height: 16))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        accessory.addSubview(indicator)
        alert.accessoryView = accessory
        VPhoneAlert.present(alert)

        Task {
            defer {
                isInstallingBootstrap = false
                updateBootstrapAvailability(
                    available: control.isConnected && control.guestCapabilities.contains("bootstrap_install"),
                )
                indicator.stopAnimation(nil)
                close.isEnabled = true
            }
            let poller = Task {
                while !Task.isCancelled {
                    if let status = try? await control.bootstrapStatus() {
                        updateBootstrapProgress(status, label: statusLabel, indicator: indicator)
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            do {
                let result = try await control.installBootstrap(layout: layout)
                poller.cancel()
                let version = result["version"] as? String ?? ""
                let root = result["jbroot"] as? String ?? ""
                indicator.isIndeterminate = false
                indicator.doubleValue = 100
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installed")
                var message = VPhoneLocalization.format("Installed Irisin %@ in %@.", version, root)
                if let warning = result["service_start_warning"] as? String {
                    message += "\n\n" + VPhoneLocalization.format("Daemon start: %@", warning)
                }
                alert.informativeText = message
            } catch {
                poller.cancel()
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installation failed")
                alert.alertStyle = .warning
                alert.informativeText = String(describing: error)
            }
        }
    }

    private func updateBootstrapProgress(
        _ status: [String: Any], label: NSTextField, indicator: NSProgressIndicator
    ) {
        switch status["phase"] as? String {
        case "downloading":
            let received = status["downloaded_bytes"] as? Int64 ?? 0
            let total = status["total_bytes"] as? Int64 ?? 0
            if total > 0 {
                indicator.isIndeterminate = false
                indicator.minValue = 0
                indicator.maxValue = Double(total)
                indicator.doubleValue = Double(received)
                let current = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                let expected = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                label.stringValue = VPhoneLocalization.format("Downloading Irisin: %@ of %@", current, expected)
            } else {
                label.stringValue = VPhoneLocalization.text("Downloading Irisin…")
            }
        case "extracting":
            label.stringValue = VPhoneLocalization.text("Extracting Irisin…")
        case "installing":
            label.stringValue = VPhoneLocalization.text("Registering Irisin…")
        default: break
        }
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
