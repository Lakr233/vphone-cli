import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController {
    private var windowController: NSWindowController?

    func showWindow(for vm: VZVirtualMachine, screenWidth: Int, screenHeight: Int, screenScale: Double) {
        let view = VPhoneVMView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
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
        window.contentView = vmView
        window.center()

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
