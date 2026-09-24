import AppKit
import SwiftUI

/// The App Browser window. The SwiftUI content supplies the toolbar and the
/// search field, which the hosting controller bridges into the window.
@MainActor
final class VPhoneAppWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 1040, height: 600)
    static let minimumSize = NSSize(width: 860, height: 420)

    /// Opens the File Browser at a guest path, such as an app's data container.
    var onRevealPath: ((String) -> Void)?

    private var window: NSWindow?
    private var model: VPhoneAppBrowserModel?

    var isKeyWindow: Bool {
        window?.isKeyWindow == true
    }

    func showWindow(control: VPhoneGuestControl) {
        let window = window ?? makeWindow(control: control)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func focusSearch() {
        model?.isSearchFocusRequested = true
    }

    private func makeWindow(control: VPhoneGuestControl) -> NSWindow {
        let model = VPhoneAppBrowserModel(control: control)
        model.onRevealPath = { [weak self] path in self?.onRevealPath?(path) }
        self.model = model

        let hostingController = NSHostingController(rootView: VPhoneAppBrowserView(model: model))
        hostingController.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = String(localized: "Apps", bundle: VPhoneLocalization.bundle)
        window.subtitle = String(localized: "Guest", bundle: VPhoneLocalization.bundle)
        window.contentViewController = hostingController
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.defaultSize)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.delegate = self
        window.setFrameAutosaveName("vphone-guest-apps")
        if window.frame.origin == .zero {
            window.center()
        }
        self.window = window
        return window
    }

    nonisolated func windowWillClose(_: Notification) {
        MainActor.assumeIsolated {
            window = nil
            model = nil
        }
    }
}
