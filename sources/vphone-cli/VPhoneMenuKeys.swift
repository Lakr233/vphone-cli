import AppKit

// MARK: - Keys Menu

extension VPhoneMenuController {
    func buildKeysMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Keys")
        menu.addItem(makeItem("Home Screen", action: #selector(sendHome)))
        menu.addItem(makeItem("Power", action: #selector(sendPower)))
        menu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp)))
        menu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Spotlight (Cmd+Space)", action: #selector(sendSpotlight)))
        item.submenu = menu
        return item
    }

    @objc func sendHome() {
        keyHelper.sendHome()
    }

    @objc func sendPower() {
        keyHelper.sendPower()
    }

    @objc func sendVolumeUp() {
        keyHelper.sendVolumeUp()
    }

    @objc func sendVolumeDown() {
        keyHelper.sendVolumeDown()
    }

    @objc func sendSpotlight() {
        keyHelper.sendSpotlight()
    }
}
