import AppKit
import SwiftUI

@MainActor
class VPhoneFileWindowController {
    private var window: NSWindow?
    private var model: VPhoneFileBrowserModel?
    private let quickLookController = VPhoneQuickLookController()

    func showWindow(control: VPhoneControl) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = VPhoneFileBrowserModel(control: control, quickLookController: quickLookController)
        self.model = model

        let view = VPhoneFileBrowserView(model: model)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Files"
        window.subtitle = "vphone"
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 500, height: 300)
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        // Insert quickLookController at the window level so AppKit finds it
        // when walking the responder chain for QLPreviewPanel panel control.
        quickLookController.nextResponder = window.nextResponder
        window.nextResponder = quickLookController

        window.makeKeyAndOrderFront(nil)
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model?.closeQuickLook()
                self?.window = nil
                self?.model = nil
            }
        }
    }
}
