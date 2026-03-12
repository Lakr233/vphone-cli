import AppKit
import Foundation

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController {
    let keyHelper: VPhoneKeyHelper
    let control: VPhoneControl
    weak var vm: VPhoneVirtualMachine?

    var onFilesPressed: (() -> Void)?
    var onKeychainPressed: (() -> Void)?
    var onAppsPressed: (() -> Void)?
    var connectFileBrowserItem: NSMenuItem?
    var connectKeychainBrowserItem: NSMenuItem?
    var connectDevModeStatusItem: NSMenuItem?
    var connectPingItem: NSMenuItem?
    var connectGuestVersionItem: NSMenuItem?
    var installPackageItem: NSMenuItem?
    var clipboardGetItem: NSMenuItem?
    var clipboardSetItem: NSMenuItem?
    var appsListItem: NSMenuItem?
    var appsOpenURLItem: NSMenuItem?
    var settingsGetItem: NSMenuItem?
    var settingsSetItem: NSMenuItem?
    var touchIDMonitor: VPhoneTouchIDMonitor? {
        didSet { touchIDMonitor?.isEnabled = touchIDMenuItem?.state == .on }
    }
    var touchIDMenuItem: NSMenuItem?
    var locationProvider: VPhoneLocationProvider?
    var locationMenuItem: NSMenuItem?
    var locationPresetMenuItem: NSMenuItem?
    var locationReplayStartItem: NSMenuItem?
    var locationReplayStopItem: NSMenuItem?
    var screenRecorder: VPhoneScreenRecorder?
    var recordingItem: NSMenuItem?
    weak var captureView: VPhoneVirtualMachineView?

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
        #if canImport(VPhoneBuildInfo)
            let buildItem = NSMenuItem(
                title: "Build: \(VPhoneBuildInfo.commitHash)", action: nil, keyEquivalent: ""
            )
        #else
            let buildItem = NSMenuItem(title: "Build: unknown", action: nil, keyEquivalent: "")
        #endif
        buildItem.isEnabled = false
        appMenu.addItem(buildItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit vphone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        mainMenu.addItem(buildConnectMenu())
        mainMenu.addItem(buildKeysMenu())
        mainMenu.addItem(buildAppsMenu())
        mainMenu.addItem(buildRecordMenu())

        // Window menu — provides Cmd+W (close) and Cmd+M (minimize) for any key window
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
