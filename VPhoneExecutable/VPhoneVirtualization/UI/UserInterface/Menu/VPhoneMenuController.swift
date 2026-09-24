import AppKit
import Foundation

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController {
    let keySender: VPhoneVirtualMachineKeySender
    let control: VPhoneGuestControl
    let guestToolsWindowController: VPhoneGuestToolsWindowController
    weak var vm: VPhoneVirtualMachine?

    var onFilesPressed: (() -> Void)?
    var onKeychainPressed: (() -> Void)?
    var onFindPressed: (() -> Void)?
    var onAppsPressed: (() -> Void)?
    var connectFileBrowserItem: NSMenuItem?
    var connectKeychainBrowserItem: NSMenuItem?
    var connectDevModeStatusItem: NSMenuItem?
    var connectPingItem: NSMenuItem?
    var connectGuestHashItem: NSMenuItem?
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
    var cameraServer: VPhoneCameraServer?
    var cameraStatusItem: NSMenuItem?
    var cameraSourceOffItem: NSMenuItem?
    var cameraSourceTestPatternItem: NSMenuItem?
    var cameraSourceVideoFileItem: NSMenuItem?
    var cameraStartStopItem: NSMenuItem?
    weak var captureView: VPhoneVirtualMachineView?
    var batterySyncEnabled = false
    var batterySyncStatusItem: NSMenuItem?
    var batteryLevelMenuItems: [NSMenuItem] = []
    var batteryConnectivityMenuItems: [NSMenuItem] = []
    var powerSourceRunLoopSource: CFRunLoopSource?
    var powerSourceRetainedPtr: UnsafeMutableRawPointer?
    var lowPowerObserver: (any NSObjectProtocol)?

    init(keySender: VPhoneVirtualMachineKeySender, control: VPhoneGuestControl) {
        self.keySender = keySender
        self.control = control
        guestToolsWindowController = VPhoneGuestToolsWindowController(control: control)
        setupMenuBar()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "vphone")
        let buildHash = Bundle.main.object(forInfoDictionaryKey: "VPhoneBuildHash") as? String
        let buildTitle = buildHash.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let buildItem = NSMenuItem(title: "Build: \(buildTitle)", action: nil, keyEquivalent: "")
        buildItem.isEnabled = false
        appMenu.addItem(buildItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit vphone",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        let findItem = editMenu.addItem(
            withTitle: "Find…",
            action: #selector(findKeychain),
            keyEquivalent: "f",
        )
        findItem.target = self
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        mainMenu.addItem(buildConnectMenu())
        mainMenu.addItem(buildKeysMenu())
        mainMenu.addItem(buildAppsMenu())
        mainMenu.addItem(buildRecordMenu())

        // Window menu — provides Cmd+W (close) and Cmd+M (minimize) for any key window
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w",
        )
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m",
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func makeItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func findKeychain() {
        onFindPressed?()
    }
}
