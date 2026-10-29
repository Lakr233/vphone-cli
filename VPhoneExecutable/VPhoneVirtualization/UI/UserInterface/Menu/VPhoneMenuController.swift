import AppKit
import Dynamic
import Foundation

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController {
    let keySender: VPhoneVirtualMachineKeySender
    let control: VPhoneGuestControl
    let guestToolsWindowController: VPhoneGuestToolsWindowController
    let guestPanelsWindowController: VPhoneGuestPanelsWindowController
    weak var vm: VPhoneVirtualMachine? {
        didSet {
            hardwareKeyboardItem?.state = vm?.usesHardwareKeyboard == true ? .on : .off
            hardwareKeyboardItem?.isEnabled = vm != nil
            if let vm, let item = hardwareKeyboardItem {
                let count = (Dynamic(vm.virtualMachine)._keyboards.asObject as? NSArray)?.count
                print("[keyboard] Menu checked: \(item.state == .on), active keyboards: \(count.map(String.init) ?? "unknown")")
            }
        }
    }

    var hardwareKeyboardItem: NSMenuItem?
    var softwareKeyboardItem: NSMenuItem?
    var tvControlCenterItem: NSMenuItem?
    var tvRemoteItem: NSMenuItem?
    lazy var tvRemoteWindowController = VPhoneTVRemoteWindowController(control: control)

    /// An Apple TV guest has a TV button that opens Control Center when held.
    var showsTVControls = false {
        didSet {
            tvControlCenterItem?.isHidden = !showsTVControls
            tvRemoteItem?.isHidden = !showsTVControls
            if oldValue && !showsTVControls { tvRemoteWindowController.close() }
        }
    }
    var watchSideButtonItem: NSMenuItem?

    /// An Apple Watch guest has a side button beside the Digital Crown.
    var showsWatchControls = false {
        didSet { watchSideButtonItem?.isHidden = !showsWatchControls }
    }
    var onHardwareKeyboardChange: ((Bool) async throws -> Void)?
    var onFrameRateDisplayChange: ((Bool) -> Void)?
    /// Saves the unlock-at-startup setting to this machine's config.plist.
    var onUnlockAtStartupChange: ((Bool) throws -> Void)?
    var unlockAtStartupItem: NSMenuItem?
    /// Saves the Sync Host Location setting to this machine's config.plist.
    var onHostLocationSyncChange: ((Bool) throws -> Void)?

    var onSessionPressed: (() -> Void)?
    var onFilesPressed: (() -> Void)?
    var onKeychainPressed: (() -> Void)?
    var onFindPressed: (() -> Void)?
    var onAppsPressed: (() -> Void)?
    var connectSessionItem: NSMenuItem?
    var connectFileBrowserItem: NSMenuItem?
    var connectKeychainBrowserItem: NSMenuItem?
    var connectDevModeStatusItem: NSMenuItem?
    var connectPingItem: NSMenuItem?
    var connectGuestHashItem: NSMenuItem?
    var installBootstrapItem: NSMenuItem?
    var installBootstrapFromFileItem: NSMenuItem?
    var uninstallBootstrapItem: NSMenuItem?
    var uninstallBootstrapNoRestartItem: NSMenuItem?
    var rebuildAppRegistrationsItem: NSMenuItem?
    var isInstallingBootstrap = false
    var isUninstallingBootstrap = false
    var isRebuildingAppRegistrations = false
    var installPackageItem: NSMenuItem?
    var clipboardGetItem: NSMenuItem?
    var clipboardSetItem: NSMenuItem?
    var appsListItem: NSMenuItem?
    var appsOpenURLItem: NSMenuItem?
    var settingsGetItem: NSMenuItem?
    var settingsSetItem: NSMenuItem?
    var restartGuestItem: NSMenuItem?
    var shutDownGuestItem: NSMenuItem?
    var setUDIDItem: NSMenuItem?
    var resetUDIDItem: NSMenuItem?
    var skipSetupAssistantItem: NSMenuItem?
    var panelMenuItems: [VPhoneGuestPanel: NSMenuItem] = [:]
    var rotateMenuItems: [NSMenuItem] = []
    var touchIDMonitor: VPhoneTouchIDMonitor? {
        didSet { touchIDMonitor?.isEnabled = touchIDMenuItem?.state == .on }
    }

    var touchIDMenuItem: NSMenuItem?
    var trackpadGesturesItem: NSMenuItem?
    var mouseCaptureItem: NSMenuItem?
    lazy var externalDisplayWindow = VPhoneExternalDisplayWindowController(control: control)
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
    var cameraSourceSystemCameraItem: NSMenuItem?
    var cameraStartStopItem: NSMenuItem?
    weak var captureView: VPhoneVirtualMachineView? {
        didSet {
            captureView?.onMouseCaptureChange = { [weak self] captured in
                self?.mouseCaptureItem?.state = captured ? .on : .off
            }
        }
    }
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
        guestPanelsWindowController = VPhoneGuestPanelsWindowController(control: control)
        setupMenuBar()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "VPhone")
        let buildItem = NSMenuItem(
            title: VPhoneLocalization.format("Build: %@", Self.buildDescription()),
            action: nil,
            keyEquivalent: "",
        )
        buildItem.isEnabled = false
        appMenu.addItem(buildItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit VPhone",
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

        // The phone, its simulated sensors, the guest's data and apps, then
        // inspection and capture.
        mainMenu.addItem(buildDeviceMenu())
        mainMenu.addItem(buildFeaturesMenu())
        mainMenu.addItem(buildDataMenu())
        mainMenu.addItem(buildAppsMenu())
        mainMenu.addItem(buildDiagnosticsMenu())
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
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "",
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        VPhoneLocalization.menu(mainMenu)
        NSApp.mainMenu = mainMenu
    }

    /// "2.3.2 (26, 735927f)": the bundle version, its build number and the
    /// commit `StageBundle.sh` stamped into the Info.plist. vphone-vm runs from
    /// `VPhone.bundle/Contents/MacOS`, so `Bundle.main` is that bundle.
    static func buildDescription() -> String {
        func value(_ key: String) -> String? {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let details = [value("CFBundleVersion"), value("VPhoneBuildHash")].compactMap(\.self)
        let detail = details.isEmpty ? nil : details.joined(separator: ", ")
        switch (value("CFBundleShortVersionString"), detail) {
        case let (version?, detail?): return "\(version) (\(detail))"
        case let (version?, nil): return version
        case let (nil, detail?): return detail
        case (nil, nil): return VPhoneLocalization.text("unknown")
        }
    }

    func makeItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        symbol: String? = nil,
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.image = symbol.flatMap(menuSymbol)
        return item
    }

    /// An SF Symbol for a menu item. Checkable items, value lists and status
    /// rows have none, so the icons mark actions, windows and submenus.
    func menuSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func findKeychain() {
        onFindPressed?()
    }
}
