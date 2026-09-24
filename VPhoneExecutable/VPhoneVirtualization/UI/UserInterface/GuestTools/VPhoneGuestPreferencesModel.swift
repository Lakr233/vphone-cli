import AppKit
import Foundation

@MainActor
@Observable
final class VPhoneGuestPreferencesModel {
    enum Activity {
        case reading
        case writing

        var title: String {
            switch self {
            case .reading: String(localized: "Reading preference…", bundle: VPhoneLocalization.bundle)
            case .writing: String(localized: "Writing preference…", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    enum Field: Hashable {
        case domain
        case readKey
        case writeKey
        case value
    }

    enum ResultStyle: String, CaseIterable, Identifiable {
        case outline
        case json

        var id: Self {
            self
        }

        var title: String {
            self == .outline ? String(localized: "Outline", bundle: VPhoneLocalization.bundle) : String(localized: "JSON", bundle: VPhoneLocalization.bundle)
        }

        var symbol: String {
            self == .outline ? "list.bullet.indent" : "curlybraces"
        }
    }

    static let suggestedDomains = [
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.UIKit",
        ".GlobalPreferences",
        "com.apple.mobilesafari",
    ]

    let control: VPhoneGuestControl
    var mode: VPhoneGuestToolMode = .read
    /// A field the view should focus the next time it updates.
    var focusRequest: Field?
    private(set) var activity: Activity?
    private(set) var status: VPhoneGuestToolStatus?

    var domain = ""
    var readKey = ""
    var resultStyle: ResultStyle = .outline
    private(set) var readResult: VPhoneGuestPreferenceReadResult?
    var writeKey = ""
    var writeType: VPhoneGuestPreferenceType = .string
    var writeValue = ""

    var isBusy: Bool {
        activity != nil
    }

    var trimmedDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedWriteKey: String {
        writeKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canRead: Bool {
        !trimmedDomain.isEmpty && !isBusy
    }

    var canWrite: Bool {
        !trimmedDomain.isEmpty && !trimmedWriteKey.isEmpty && !isBusy
    }

    var canCopyResult: Bool {
        !(readResult?.text.isEmpty ?? true)
    }

    /// The last value read for the key in the write form, if any.
    var currentWriteValue: VPhoneGuestPreferenceEntry? {
        guard let readResult, readResult.domain == trimmedDomain else { return nil }
        return readResult.entries.first { $0.key == trimmedWriteKey }
    }

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Read

    func read() async {
        let domain = trimmedDomain
        let key = readKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, activity == nil else { return }
        activity = .reading
        defer { activity = nil }
        do {
            let value = try await control.settingsGet(domain: domain, key: key.isEmpty ? nil : key)
            let result = VPhoneGuestPreferenceReadResult(domain: domain, key: key.isEmpty ? nil : key, value: value)
            readResult = result
            if result.entries.isEmpty, result.text.isEmpty {
                succeed(
                    key.isEmpty
                        ? String(localized: "\(domain) has no values.", bundle: VPhoneLocalization.bundle)
                        : String(localized: "\(key) is not set in \(domain).", bundle: VPhoneLocalization.bundle),
                )
            } else {
                status = nil
            }
        } catch {
            fail(String(localized: "Unable to read that preference. Check the domain and key, then try again.", bundle: VPhoneLocalization.bundle))
        }
    }

    func copyResult() {
        guard let text = readResult?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        succeed(String(localized: "Copied the result as JSON.", bundle: VPhoneLocalization.bundle))
    }

    /// Whether an entry is a top-level scalar the write form can round-trip.
    func canEdit(_ entry: VPhoneGuestPreferenceEntry) -> Bool {
        entry.writableType != nil && readResult?.entries.contains { $0.id == entry.id } == true
    }

    /// Loads a top-level scalar into the write form. With `switchToWrite`,
    /// the window also moves to Write mode with the value focused.
    func edit(_ entry: VPhoneGuestPreferenceEntry, switchToWrite: Bool) {
        guard canEdit(entry), let type = entry.writableType else { return }
        writeKey = entry.key
        writeType = type
        writeValue = entry.summary
        if switchToWrite {
            mode = .write
            focusRequest = .value
        }
    }

    // MARK: - Write

    func write() async {
        let domain = trimmedDomain
        let key = trimmedWriteKey
        guard !domain.isEmpty, !key.isEmpty else {
            fail(String(localized: "Enter a domain and key.", bundle: VPhoneLocalization.bundle))
            return
        }
        let value: Any
        switch writeType.parse(writeValue) {
        case let .success(parsed): value = parsed
        case let .failure(error):
            fail(error.message)
            return
        }

        guard activity == nil else { return }
        activity = .writing
        do {
            try await control.settingsSet(domain: domain, key: key, value: value, type: writeType.rawValue)
        } catch {
            activity = nil
            fail(String(localized: "Unable to write that preference. Check the connection, then try again.", bundle: VPhoneLocalization.bundle))
            return
        }
        activity = nil

        // Read the domain back so Read mode shows what the guest stored.
        if readResult?.domain == domain {
            await read()
        }
        succeed(String(localized: "Wrote \(key) to \(domain).", bundle: VPhoneLocalization.bundle))
    }

    // MARK: - Status

    private func succeed(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: false)
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
    }
}
