import AppKit
import Foundation

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController {
    let keyHelper: VPhoneKeyHelper
    let control: VPhoneControl

    var onFilesPressed: (() -> Void)?
    var locationProvider: VPhoneLocationProvider?
    var locationMenuItem: NSMenuItem?

    init(keyHelper: VPhoneKeyHelper, control: VPhoneControl) {
        self.keyHelper = keyHelper
        self.control = control
        setupMenuBar()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "vphone")
        let buildItem = NSMenuItem(title: "Build: \(VPhoneBuildInfo.commitHash)", action: nil, keyEquivalent: "")
        buildItem.isEnabled = false
        appMenu.addItem(buildItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit vphone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        mainMenu.addItem(buildKeysMenu())
        mainMenu.addItem(buildTypeMenu())
        mainMenu.addItem(buildConnectMenu())
        mainMenu.addItem(buildLocationMenu())

        NSApp.mainMenu = mainMenu
    }

    func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
