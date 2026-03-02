import AppKit

// MARK: - Location Menu

extension VPhoneMenuController {
    func buildLocationMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Location")
        let toggle = makeItem("Sync Host Location", action: #selector(toggleLocationSync))
        toggle.state = .off
        toggle.isEnabled = false
        locationMenuItem = toggle
        menu.addItem(toggle)
        item.submenu = menu
        return item
    }

    /// Enable or disable the location toggle based on guest capability.
    /// Preserves the user's checkmark state across connect/disconnect cycles.
    func updateLocationCapability(available: Bool) {
        locationMenuItem?.isEnabled = available
    }

    @objc func toggleLocationSync() {
        guard let item = locationMenuItem else { return }
        if item.state == .on {
            locationProvider?.stopForwarding()
            control.sendLocationStop()
            item.state = .off
            print("[location] sync toggled off by user")
        } else {
            locationProvider?.startForwarding()
            item.state = .on
            print("[location] sync toggled on by user")
        }
    }
}
