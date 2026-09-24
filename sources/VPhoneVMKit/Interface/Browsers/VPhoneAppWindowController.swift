import AppKit
import SwiftUI

@MainActor
class VPhoneAppWindowController {
    private var window: NSWindow?
    private var model: VPhoneAppBrowserModel?

    func showWindow(control: VPhoneControl) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = VPhoneAppBrowserModel(control: control)
        self.model = model

        let view = VPhoneAppBrowserView(model: model)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Apps"
        window.subtitle = "vphone"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 450, height: 300)
        window.center()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "vphone-apps-toolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        window.makeKeyAndOrderFront(nil)
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                self?.model = nil
            }
        }
    }
}
