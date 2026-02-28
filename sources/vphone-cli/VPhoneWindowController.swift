import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController {
    private var windowController: NSWindowController?

    func showWindow(for vm: VZVirtualMachine) {
        let vmView: NSView
        if #available(macOS 16.0, *) {
            let view = VZVirtualMachineView()
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            vmView = view
        } else {
            let view = VPhoneVMView()
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            vmView = view
        }

        let pixelWidth: CGFloat = 1179
        let pixelHeight: CGFloat = 2556
        let windowSize = NSSize(width: pixelWidth, height: pixelHeight)

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
