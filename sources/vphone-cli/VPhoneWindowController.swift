import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController: NSObject, NSToolbarDelegate {
    private var windowController: NSWindowController?
    private var statusTimer: Timer?
    private weak var control: VPhoneControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var ecid: String?

    private nonisolated static let homeItemID = NSToolbarItem.Identifier("home")

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    func showWindow(
        for vm: VZVirtualMachine, screenWidth: Int, screenHeight: Int, screenScale: Double,
        keyHelper: VPhoneKeyHelper, control: VPhoneControl, ecid: String?, headless: Bool = false
    ) {
        self.control = control
        self.ecid = ecid

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keyHelper = keyHelper
        view.control = control
        virtualMachineView = view
        let vmView: NSView = view

        let scale = CGFloat(screenScale)
        let windowSize = NSSize(
            width: CGFloat(screenWidth) / scale, height: CGFloat(screenHeight) / scale
        )

        let window = VPhoneVMWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // In headless mode the window lives off-screen; bypass AppKit's frame
        // constraint that would otherwise pull it back onto a visible display.
        window.bypassConstrain = headless

        window.isReleasedWhenClosed = false
        window.contentAspectRatio = windowSize
        window.title = "VPHONE [loading]"
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
        windowController = controller
        keyHelper.window = window

        if headless {
            // The web console / VNC is the only display. Keep the window (and its
            // VZ view) alive off-screen so the control socket and capture keep
            // working, but never show it on any display.
            window.setFrame(
                NSRect(x: -30000, y: -30000, width: windowSize.width, height: windowSize.height),
                display: false)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
            print("[vphone] Headless: host window hidden — use the web console / VNC")
        } else {
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }

        let monitor = VPhoneTouchIDMonitor()
        monitor.start(control: control, window: window)
        touchIDMonitor = monitor

        // Poll vphoned status for title indicator
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let control = self.control else { return }
                window.title = control.isConnected ? "VPHONE [connected]" : "VPHONE [disconnected]"
                window.subtitle = self.makeSubtitle(ip: control.isConnected ? control.guestIP : nil)
            }
        }
    }

    private func makeSubtitle(ip: String?) -> String {
        switch (ecid, ip) {
        case let (ecid?, ip?): "\(ecid) — \(ip)"
        case let (ecid?, nil): ecid
        case let (nil, ip?): ip
        case (nil, nil): ""
        }
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(
        _: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if itemIdentifier == Self.homeItemID {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Home"
                item.toolTip = "Home Button"
                item.image = NSImage(
                    systemSymbolName: "circle.circle", accessibilityDescription: "Home"
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

/// An NSWindow that can opt out of AppKit's on-screen frame constraint so it can
/// live fully off-screen in headless mode (the web console / VNC is the display).
final class VPhoneVMWindow: NSWindow {
    var bypassConstrain = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        bypassConstrain ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
