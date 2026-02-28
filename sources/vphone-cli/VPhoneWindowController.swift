import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController {
    private var windowController: NSWindowController?

    func showWindow(for vm: VZVirtualMachine) {
        let view = VPhoneVMView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        let vmView: NSView = view

        // Native VM display: 1290x2796 @ 460 PPI (iPhone 15 Pro Max).
        // Scale to ~1/3 for a reasonable window size on macOS.
        let scale: CGFloat = 3.0
        let windowSize = NSSize(width: 1290 / scale, height: 2796 / scale)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.contentAspectRatio = windowSize
        window.title = "vphone"
        window.contentView = vmView
        window.center()

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
