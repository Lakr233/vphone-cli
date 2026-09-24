import AppKit

@MainActor
enum VPhoneAlert {
    @discardableResult
    static func run(
        title: String,
        message: String,
        style: NSAlert.Style,
        buttons: [String] = ["OK"],
    ) -> NSApplication.ModalResponse {
        makeAlert(title: title, message: message, style: style, buttons: buttons).runModal()
    }

    static func present(
        title: String,
        message: String,
        style: NSAlert.Style,
        attachedTo window: NSWindow?,
        buttons: [String] = ["OK"],
        completion: ((NSApplication.ModalResponse) -> Void)? = nil,
    ) {
        let alert = makeAlert(title: title, message: message, style: style, buttons: buttons)
        if let window {
            alert.beginSheetModal(for: window) { response in completion?(response) }
        } else {
            completion?(alert.runModal())
        }
    }

    private static func makeAlert(
        title: String,
        message: String,
        style: NSAlert.Style,
        buttons: [String],
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        return alert
    }
}
