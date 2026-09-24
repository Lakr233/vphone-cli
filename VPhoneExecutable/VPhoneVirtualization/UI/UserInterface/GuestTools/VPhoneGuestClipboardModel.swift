import AppKit
import Foundation

@MainActor
@Observable
final class VPhoneGuestClipboardModel {
    enum Activity {
        case reading
        case sending

        var title: String {
            switch self {
            case .reading: "Reading guest clipboard…"
            case .sending: "Sending text to guest…"
            }
        }
    }

    let control: VPhoneGuestControl
    var mode: VPhoneGuestToolMode = .read
    /// Set to move focus to the compose editor the next time the view updates.
    var focusComposeRequested = false
    private(set) var activity: Activity?
    private(set) var status: VPhoneGuestToolStatus?
    private(set) var clipboard: VPhoneGuestControl.ClipboardContent?
    private(set) var readDate: Date?
    var composeText = ""

    var isBusy: Bool { activity != nil }
    var canCopyText: Bool { clipboard?.text != nil }
    var canCopyImage: Bool { clipboard?.imageData != nil }
    var canSend: Bool { !composeText.isEmpty && !isBusy }

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Read

    func refresh() async {
        guard activity == nil else { return }
        activity = .reading
        defer { activity = nil }
        do {
            clipboard = try await control.clipboardGet()
            readDate = .now
            status = nil
        } catch {
            fail("Unable to read the guest clipboard. Check the connection, then try again.")
        }
    }

    func copyTextToMac() {
        guard let text = clipboard?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        succeed("Copied guest text to the Mac clipboard.")
    }

    func copyImageToMac() {
        guard let data = clipboard?.imageData, let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        succeed("Copied guest image to the Mac clipboard.")
    }

    // MARK: - Write

    func send() async {
        let text = composeText
        guard !text.isEmpty, activity == nil else { return }
        activity = .sending
        do {
            try await control.clipboardSet(text: text)
        } catch {
            activity = nil
            fail("Unable to set the guest clipboard. Check the connection, then try again.")
            return
        }
        activity = nil

        // Read it back so Read mode shows what the guest now holds.
        await refresh()
        succeed("Sent \(text.count == 1 ? "1 character" : "\(text.count) characters") to the guest clipboard.")
    }

    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            fail("The Mac clipboard has no text.")
            return
        }
        composeText = text
        status = nil
    }

    // MARK: - Status

    private func succeed(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: false)
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
    }
}
