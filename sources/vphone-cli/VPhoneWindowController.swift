import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController {
    private var windowController: NSWindowController?
    private var statusTimer: Timer?
    private weak var control: VPhoneControl?

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

        // Home button in title bar
        let homeButton = NSButton(title: "Home", target: self, action: #selector(homePressed))
        homeButton.bezelStyle = .recessed
        homeButton.controlSize = .small
        homeButton.setContentHuggingPriority(.required, for: .horizontal)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = homeButton
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

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
                if control.isConnected {
                    let caps = control.guestCaps.joined(separator: ", ")
                    window.subtitle = "vphoned: connected [\(caps)]"
                } else {
                    window.subtitle = "vphoned: connecting..."
                }
            }
        }
    }

    @objc private func homePressed() {
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }
}
