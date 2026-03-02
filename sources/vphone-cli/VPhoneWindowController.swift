import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController: NSObject, NSToolbarDelegate {
    private var windowController: NSWindowController?
    private var statusTimer: Timer?
    private weak var control: VPhoneControl?

    nonisolated private static let homeItemID = NSToolbarItem.Identifier("home")

    func showWindow(for vm: VZVirtualMachine, screenWidth: Int, screenHeight: Int, screenScale: Double, keyHelper: VPhoneKeyHelper, control: VPhoneControl) {
        self.control = control

        let view = VPhoneVMView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keyHelper = keyHelper
        let vmView: NSView = view

        let scale = CGFloat(screenScale)
        let windowSize = NSSize(width: CGFloat(screenWidth) / scale, height: CGFloat(screenHeight) / scale)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.contentAspectRatio = windowSize
        window.title = "vphone"
        window.subtitle = "vphoned: connecting..."
        window.contentView = vmView
        window.center()

        // Toolbar with unified style for two-line title
        let toolbar = NSToolbar(identifier: "vphone-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        keyHelper.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Poll vphoned status for subtitle
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let control = self.control else { return }
                window.subtitle = control.isConnected ? "vphoned connected" : "vphoned connecting..."
            }
        }
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if itemIdentifier == Self.homeItemID {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Home"
                item.toolTip = "Home Button"
                item.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Home")
                item.target = self
                item.action = #selector(homePressed)
                return item
            }
            return nil
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.homeItemID]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.homeItemID, .flexibleSpace, .space]
    }

    // MARK: - Actions

    @objc private func homePressed() {
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }
}
