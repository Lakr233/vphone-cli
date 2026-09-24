import AppKit

/// Presents alerts and open panels as sheets on the window they belong to:
/// the window passed in, or the VM display window for menu actions. When
/// neither is available, for example with --no-graphics, they run app-modal.
@MainActor
enum VPhoneAlert {
    /// The VM display window. Set when it is created.
    static weak var hostWindow: NSWindow?

    static func present(
        title: String,
        message: String,
        style: NSAlert.Style,
        buttons: [String] = ["OK"],
        on window: NSWindow? = nil,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil,
    ) {
        present(makeAlert(title: title, message: message, style: style, buttons: buttons), on: window, completion: completion)
    }

    static func present(
        _ alert: NSAlert,
        on window: NSWindow? = nil,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil,
    ) {
        if let window = presentingWindow(window) {
            // AppKit queues the sheet if another one is already showing.
            alert.beginSheetModal(for: window) { response in completion?(response) }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }

    static func present(
        _ panel: NSSavePanel,
        on window: NSWindow? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
    ) {
        if let window = presentingWindow(window) {
            panel.beginSheetModal(for: window) { response in completion(response) }
        } else {
            completion(panel.runModal())
        }
    }

    private static func presentingWindow(_ preferred: NSWindow?) -> NSWindow? {
        guard let window = preferred ?? hostWindow, window.isVisible || window.isMiniaturized else { return nil }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func makeAlert(
        title: String,
        message: String,
        style: NSAlert.Style,
        buttons: [String],
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text(title)
        alert.informativeText = VPhoneLocalization.text(message)
        alert.alertStyle = style
        for button in buttons {
            alert.addButton(withTitle: VPhoneLocalization.text(button))
        }
        return alert
    }
}
