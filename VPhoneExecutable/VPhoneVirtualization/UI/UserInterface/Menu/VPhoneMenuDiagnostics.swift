import AppKit

// MARK: - Diagnostics Menu

/// Read-mostly inspection of the running guest. Each panel item opens its
/// own window; the last three items answer in an alert.
extension VPhoneMenuController {
    func buildDiagnosticsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Diagnostics")
        menu.autoenablesItems = false

        menu.addItem(makePanelItem(.deviceInfo, "Device Info", keyEquivalent: "i", symbol: "info.circle"))
        menu.addItem(makePanelItem(.processes, "Processes", keyEquivalent: "p", symbol: "cpu"))
        menu.addItem(makePanelItem(.services, "Services", keyEquivalent: "s", symbol: "gearshape.2"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makePanelItem(.console, "Console", keyEquivalent: "l", symbol: "terminal"))
        menu.addItem(makePanelItem(.crashLogs, "Crash Logs", keyEquivalent: "c", symbol: "exclamationmark.triangle"))
        menu.addItem(NSMenuItem.separator())

        // A guest has no shell of its own, and the tvos preset has no
        // debugger: this window is the only place to run code inside one, so
        // it is named for that rather than for the session kind it opens.
        let session = makeItem(
            "Debug Session",
            action: #selector(openSession),
            keyEquivalent: "t",
            modifiers: [.command, .option],
            symbol: "apple.terminal",
        )
        session.isEnabled = false
        connectSessionItem = session
        menu.addItem(session)
        menu.addItem(NSMenuItem.separator())

        let devModeStatus = makeItem(
            "Developer Mode Status",
            action: #selector(devModeStatus),
            symbol: "hammer",
        )
        devModeStatus.isEnabled = false
        connectDevModeStatusItem = devModeStatus
        menu.addItem(devModeStatus)

        // Saved to this machine and applied at once: Xcode and Instruments see
        // the guest online while vphone-vm holds its CoreDevice tunnel.
        let tunnel = makeItem("Keep Developer Tunnel Open", action: #selector(toggleDeveloperTunnel))
        tunnel.toolTip = VPhoneLocalization.text(
            "Hold the guest's CoreDevice tunnel open, so Xcode and Instruments list it as online.",
        )
        tunnel.isEnabled = false
        developerTunnelItem = tunnel
        menu.addItem(tunnel)

        socks5Menu.attach(to: menu)

        let agentItem = NSMenuItem(title: "Guest Agent", action: nil, keyEquivalent: "")
        agentItem.image = menuSymbol("antenna.radiowaves.left.and.right")
        let agentMenu = NSMenu(title: "Guest Agent")
        agentMenu.autoenablesItems = false

        let ping = makeItem("Ping", action: #selector(sendPing), symbol: "dot.radiowaves.left.and.right")
        ping.isEnabled = false
        connectPingItem = ping
        agentMenu.addItem(ping)

        let guestHash = makeItem("Guest Agent Hash", action: #selector(queryGuestHash), symbol: "number")
        guestHash.isEnabled = false
        connectGuestHashItem = guestHash
        agentMenu.addItem(guestHash)

        agentItem.submenu = agentMenu
        menu.addItem(agentItem)

        item.submenu = menu
        return item
    }

    /// A menu item that opens one guest panel with ⌥⌘ plus the given key.
    func makePanelItem(
        _ panel: VPhoneGuestPanel,
        _ title: String,
        keyEquivalent: String,
        symbol: String,
    ) -> NSMenuItem {
        let item = makeItem(
            title,
            action: #selector(openPanel(_:)),
            keyEquivalent: keyEquivalent,
            modifiers: [.command, .option],
            symbol: symbol,
        )
        item.representedObject = panel
        item.isEnabled = false
        panelMenuItems[panel] = item
        return item
    }

    /// Enables the panels the connected agent can serve. An empty list, as on
    /// disconnect, disables them all.
    func updatePanelAvailability(capabilities: [String]) {
        guestPanelsWindowController.attitudeConnectionChanged()
        if showsTVControls { tvRemoteWindowController.connectionChanged() }
        for (panel, item) in panelMenuItems {
            item.isEnabled = capabilities.contains(panel.capability)
        }
        for item in rotateMenuItems {
            item.isEnabled = capabilities.contains("display")
        }
    }

    @objc func openPanel(_ sender: NSMenuItem) {
        guard let panel = sender.representedObject as? VPhoneGuestPanel else { return }
        guestPanelsWindowController.show(panel)
    }

    /// Saved to this machine's config.plist, so the next start holds the
    /// tunnel, or does not, the same way.
    @objc func toggleDeveloperTunnel() {
        guard let developerTunnel else { return }
        let enabled = !developerTunnel.isEnabled
        do {
            try onDeveloperTunnelChange?(enabled)
        } catch {
            VPhoneAlert.present(
                title: "Unable to Change Developer Tunnel",
                message: error.localizedDescription,
                style: .warning,
            )
            return
        }
        developerTunnel.isEnabled = enabled
        developerTunnelItem?.state = enabled ? .on : .off
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
