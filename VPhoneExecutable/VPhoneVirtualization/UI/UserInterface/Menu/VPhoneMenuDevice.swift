import AppKit
import LocalAuthentication

// MARK: - Device Menu

/// Hardware the guest thinks it has: buttons, keyboard, sensors and the
/// host-side overrides that feed them.
extension VPhoneMenuController {
    func buildDeviceMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Device", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Device")
        menu.addItem(makeItem(
            "Home Screen",
            action: #selector(sendHome),
            keyEquivalent: "h",
            modifiers: [.command, .shift],
        ))
        menu.addItem(makeItem("Power", action: #selector(sendPower)))
        menu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp)))
        menu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Open Guest Spotlight", action: #selector(sendSpotlight)))
        menu.addItem(makeItem("Type ASCII from Mac Clipboard", action: #selector(typeFromClipboard)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makePanelItem(.controls, "Controls", keyEquivalent: "k"))
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
