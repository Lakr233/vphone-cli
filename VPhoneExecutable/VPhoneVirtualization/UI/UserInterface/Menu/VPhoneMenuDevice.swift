import AppKit
import LocalAuthentication

// MARK: - Device Menu

/// Hardware the guest thinks it has: buttons, keyboard, sensors and the
/// host-side overrides that feed them.
extension VPhoneMenuController {
    func buildDeviceMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Device", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Device")
        menu.autoenablesItems = false
        menu.addItem(makeItem(
            "Home Screen",
            action: #selector(sendHome),
            keyEquivalent: "h",
            modifiers: [.command, .shift],
            symbol: "house",
        ))
        menu.addItem(makeItem("Power", action: #selector(sendPower), symbol: "power"))
        menu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp), symbol: "speaker.plus"))
        menu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown), symbol: "speaker.minus"))
        menu.addItem(NSMenuItem.separator())
        let restart = makeItem("Restart Guest…", action: #selector(restartGuest), symbol: "arrow.clockwise")
        restart.isEnabled = false
        restartGuestItem = restart
        menu.addItem(restart)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Open Guest Spotlight", action: #selector(sendSpotlight), symbol: "magnifyingglass"))
        menu.addItem(makeItem(
            "Type ASCII from Mac Clipboard",
            action: #selector(typeFromClipboard),
            symbol: "keyboard",
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makePanelItem(.controls, "Controls", keyEquivalent: "k", symbol: "slider.horizontal.3"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(buildLocationSubmenu())
        menu.addItem(buildBatterySubmenu())
        menu.addItem(buildCameraSubmenu())
        menu.addItem(NSMenuItem.separator())
        let tidItem = makeItem("Touch ID Home Forwarding", action: #selector(toggleTouchIDForwarding))
        if hasTouchID {
            let tidEnabled = !UserDefaults.standard.bool(forKey: "touchIDForwardingDisabled")
            tidItem.state = tidEnabled ? .on : .off
        } else {
            tidItem.isEnabled = false
            tidItem.state = .off
        }
        touchIDMenuItem = tidItem
        menu.addItem(tidItem)
        item.submenu = menu
        return item
    }

    @objc func sendHome() {
        keySender.sendHome()
    }

    @objc func sendPower() {
        keySender.sendPower()
    }

    @objc func sendVolumeUp() {
        keySender.sendVolumeUp()
    }

    @objc func sendVolumeDown() {
        keySender.sendVolumeDown()
    }

    @objc func sendSpotlight() {
        keySender.sendSpotlight()
    }

    @objc func typeFromClipboard() {
        keySender.typeFromClipboard()
    }

    // MARK: - Restart

    func updateRestartAvailability(available: Bool) {
        restartGuestItem?.isEnabled = available
    }

    @objc func restartGuest() {
        VPhoneAlert.present(
            title: "Restart the guest?",
            message: "Apps in the guest quit. The guest agent reconnects after the guest starts up.",
            style: .warning,
            buttons: ["Restart Guest", "Cancel"],
        ) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await self.control.restartGuest()
                } catch let VPhoneGuestControl.ControlError.guestError(message) {
                    print("[restart] guest refused: \(message)")
                    VPhoneAlert.present(
                        title: "Unable to Restart Guest",
                        message: "The guest refused the restart request.",
                        style: .warning,
                    )
                } catch {
                    // The guest restarts before it replies, so the connection
                    // drops. onDisconnect updates the menus.
                }
            }
        }
    }

    @objc func toggleTouchIDForwarding() {
        guard let monitor = touchIDMonitor, let item = touchIDMenuItem else { return }
        monitor.isEnabled.toggle()
        item.state = monitor.isEnabled ? .on : .off
        UserDefaults.standard.set(!monitor.isEnabled, forKey: "touchIDForwardingDisabled")
    }
}

private extension VPhoneMenuController {
    var hasTouchID: Bool {
        let ctx = LAContext()
        ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType == .touchID
    }
}
