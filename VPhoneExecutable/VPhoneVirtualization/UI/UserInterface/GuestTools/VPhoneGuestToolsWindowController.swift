import AppKit
import SwiftUI

// MARK: - Entry Points

/// The Guest menu items that open a guest tool window.
enum VPhoneGuestToolAction {
    case getClipboard
    case setClipboard
    case readSetting
    case writeSetting
}

// MARK: - Window Controller

/// Owns the Clipboard and Preferences windows. They are separate windows
/// with their own models; this type only routes the Guest menu to them.
@MainActor
final class VPhoneGuestToolsWindowController {
    let clipboardModel: VPhoneGuestClipboardModel
    let preferencesModel: VPhoneGuestPreferencesModel
    private let clipboardWindow: VPhoneGuestToolWindow
    private let preferencesWindow: VPhoneGuestToolWindow

    init(control: VPhoneGuestControl) {
        let clipboardModel = VPhoneGuestClipboardModel(control: control)
        let preferencesModel = VPhoneGuestPreferencesModel(control: control)
        self.clipboardModel = clipboardModel
        self.preferencesModel = preferencesModel
        clipboardWindow = VPhoneGuestToolWindow(
            title: String(localized: "Clipboard", bundle: VPhoneLocalization.bundle),
            autosaveName: "vphone-guest-clipboard",
            size: NSSize(width: 640, height: 480),
            minSize: NSSize(width: 480, height: 320),
        ) { VPhoneGuestClipboardView(model: clipboardModel) }
        preferencesWindow = VPhoneGuestToolWindow(
            title: String(localized: "Preferences", bundle: VPhoneLocalization.bundle),
            autosaveName: "vphone-guest-preferences",
            size: NSSize(width: 760, height: 540),
            minSize: NSSize(width: 560, height: 360),
        ) { VPhoneGuestPreferencesView(model: preferencesModel) }
    }

    func show(_ action: VPhoneGuestToolAction) {
        switch action {
        case .getClipboard:
            clipboardModel.mode = .read
            clipboardWindow.show()
            Task { await clipboardModel.refresh() }
        case .setClipboard:
            clipboardModel.mode = .write
            clipboardModel.focusComposeRequested = true
            clipboardWindow.show()
        case .readSetting:
            preferencesModel.mode = .read
            preferencesModel.focusRequest = .domain
            preferencesWindow.show()
        case .writeSetting:
            preferencesModel.mode = .write
            preferencesModel.focusRequest = preferencesModel.trimmedDomain.isEmpty ? .domain : .writeKey
            preferencesWindow.show()
        }
    }
}

// MARK: - Window

/// One guest tool window. The SwiftUI content supplies the toolbar, which
/// the hosting controller bridges into the window.
@MainActor
final class VPhoneGuestToolWindow: NSObject, NSWindowDelegate {
    private let title: String
    private let autosaveName: String
    private let size: NSSize
    private let minSize: NSSize
    private let makeContent: () -> AnyView
    private var window: NSWindow?

    init(
        title: String,
        autosaveName: String,
        size: NSSize,
        minSize: NSSize,
        @ViewBuilder content: @escaping () -> some View,
    ) {
        self.title = title
        self.autosaveName = autosaveName
        self.size = size
        self.minSize = minSize
        makeContent = { AnyView(content()) }
        super.init()
    }

    func show() {
        let window = window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: makeContent())
        hostingController.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = title
        window.subtitle = String(localized: "Guest", bundle: VPhoneLocalization.bundle)
        window.contentViewController = hostingController
        window.contentMinSize = minSize
        window.setContentSize(size)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.delegate = self
        window.setFrameAutosaveName(autosaveName)
        if window.frame.origin == .zero {
            window.center()
        }
        self.window = window
        return window
    }

    nonisolated func windowWillClose(_: Notification) {
        MainActor.assumeIsolated { window = nil }
    }
}
