import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneVirtualMachineWindowController: NSObject, NSToolbarDelegate {
    private var windowController: NSWindowController?
    private weak var control: VPhoneGuestControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var ecid: String?
    private var menuKeyMonitor: Any?

    private nonisolated static let homeItemID = NSToolbarItem.Identifier("home")

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    func showWindow(
        for vm: VZVirtualMachine,
        screenWidth: Int,
        screenHeight: Int,
        screenScale: Double,
        keySender: VPhoneVirtualMachineKeySender,
        control: VPhoneGuestControl,
        ecid: String?,
    ) {
        self.control = control
        self.ecid = ecid

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keySender = keySender
        view.control = control
        virtualMachineView = view
        let vmView: NSView = view

        let scale = CGFloat(screenScale)
        let windowSize = NSSize(
            width: CGFloat(screenWidth) / scale,
            height: CGFloat(screenHeight) / scale,
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )

        window.isReleasedWhenClosed = false
        window.level = .normal
        VPhoneAlert.hostWindow = window
        window.contentAspectRatio = windowSize
        window.title = VPhoneLocalization.text("vphone — Starting…")
        window.subtitle = makeSubtitle(ip: nil)
        window.contentView = vmView
        if let ecid {
            if !window.setFrameAutosaveName("vphone-\(ecid)") {
                window.center()
            }
        } else {
            window.center()
        }

        // Toolbar with unified style for two-line title
        let toolbar = NSToolbar(identifier: "vphone-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        // capturesSystemKeys lets the VM view take every shortcut before the menu
        // bar sees it. Offer each key press to the menu first; the guest gets
        // only what no enabled menu item handles.
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            let handledByMenu = MainActor.assumeIsolated {
                guard let window, event.window === window else { return false }
                return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            }
            return handledByMenu ? nil : event
        }

        keySender.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        let monitor = VPhoneTouchIDMonitor()
        monitor.start(control: control, window: window)
        touchIDMonitor = monitor

        // Poll vphoned status for title indicator
        _ = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let control = self.control else { return }
                window.title = VPhoneLocalization.text(
                    control.isConnected ? "vphone — Connected" : "vphone — Disconnected",
                )
                window.subtitle = self.makeSubtitle(ip: control.isConnected ? control.guestIPAddress : nil)
            }
        }
    }

    private func makeSubtitle(ip: String?) -> String {
        switch (ecid, ip) {
        case let (ecid?, ip?): "\(ecid) — \(ip)"
        case (let ecid?, nil): ecid
        case (nil, let ip?): ip
        case (nil, nil): ""
        }
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(
        _: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool,
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if itemIdentifier == Self.homeItemID {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = VPhoneLocalization.text("Home")
                item.toolTip = VPhoneLocalization.text("Home Button")
                item.image = NSImage(
                    systemSymbolName: "circle.circle",
                    accessibilityDescription: VPhoneLocalization.text("Home"),
                )
                item.target = self
                item.action = #selector(homePressed)
                return item
            }
            return nil
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.homeItemID]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.homeItemID, .flexibleSpace, .space]
    }

    // MARK: - Actions

    @objc private func homePressed() {
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }
}
