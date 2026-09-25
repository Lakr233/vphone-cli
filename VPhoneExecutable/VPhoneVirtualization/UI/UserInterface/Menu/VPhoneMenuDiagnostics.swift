import AppKit

// MARK: - Diagnostics Menu

/// Read-mostly inspection of the running guest. Each panel item opens its
/// own window; the last three items answer in an alert.
extension VPhoneMenuController {
    func buildDiagnosticsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Diagnostics")
        menu.autoenablesItems = false

        menu.addItem(makePanelItem(.deviceInfo, "Device Info", keyEquivalent: "i"))
        menu.addItem(makePanelItem(.processes, "Processes", keyEquivalent: "p"))
        menu.addItem(makePanelItem(.services, "Services", keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makePanelItem(.console, "Console", keyEquivalent: "l"))
        menu.addItem(makePanelItem(.crashLogs, "Crash Logs", keyEquivalent: "c"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makePanelItem(.uiInspector, "UI Inspector", keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())

        let devModeStatus = makeItem("Developer Mode Status", action: #selector(devModeStatus))
        devModeStatus.isEnabled = false
        connectDevModeStatusItem = devModeStatus
        menu.addItem(devModeStatus)

        let ping = makeItem("Ping", action: #selector(sendPing))
        ping.isEnabled = false
        connectPingItem = ping
        menu.addItem(ping)

        let guestHash = makeItem("Guest Agent Hash", action: #selector(queryGuestHash))
        guestHash.isEnabled = false
        connectGuestHashItem = guestHash
        menu.addItem(guestHash)

        item.submenu = menu
        return item
    }

    /// A menu item that opens one guest panel with ⌥⌘ plus the given key.
    func makePanelItem(_ panel: VPhoneGuestPanel, _ title: String, keyEquivalent: String) -> NSMenuItem {
        let item = makeItem(
            title,
            action: #selector(openPanel(_:)),
            keyEquivalent: keyEquivalent,
            modifiers: [.command, .option],
        )
        item.representedObject = panel
        item.isEnabled = false
        panelMenuItems[panel] = item
        return item
    }

    /// Enables the panels the connected agent can serve. An empty list, as on
    /// disconnect, disables them all.
    func updatePanelAvailability(capabilities: [String]) {
        for (panel, item) in panelMenuItems {
            item.isEnabled = capabilities.contains(panel.capability)
        }
    }

    @objc func openPanel(_ sender: NSMenuItem) {
        guard let panel = sender.representedObject as? VPhoneGuestPanel else { return }
        guestPanelsWindowController.show(panel)
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
                    message: "Unable to read Developer Mode status. Check that the guest agent is connected, then try again.",
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
                    message: "Unable to read the guest agent hash. Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
            }
        }
    }
}
