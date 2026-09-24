import Foundation

/// The names `input.button` accepts.
enum VPhoneControlsButton: String, CaseIterable, Identifiable {
    case home
    case lock
    case wake
    case volumeUp
    case volumeDown
    case mute

    var id: Self {
        self
    }

    var name: String {
        switch self {
        case .home: "home"
        case .lock: "power"
        case .wake: "wake"
        case .volumeUp: "volume-up"
        case .volumeDown: "volume-down"
        case .mute: "mute"
        }
    }

    /// Audio buttons answer with the active audio state.
    var isAudio: Bool {
        [.volumeUp, .volumeDown, .mute].contains(self)
    }

    var title: String {
        switch self {
        case .home: String(localized: "Home", bundle: VPhoneLocalization.bundle)
        case .lock: String(localized: "Lock", bundle: VPhoneLocalization.bundle)
        case .wake: String(localized: "Wake", bundle: VPhoneLocalization.bundle)
        case .volumeUp: String(localized: "Volume Up", bundle: VPhoneLocalization.bundle)
        case .volumeDown: String(localized: "Volume Down", bundle: VPhoneLocalization.bundle)
        case .mute: String(localized: "Mute", bundle: VPhoneLocalization.bundle)
        }
    }

    var help: String {
        switch self {
        case .home: String(localized: "Press the Home button", bundle: VPhoneLocalization.bundle)
        case .lock: String(localized: "Press the side button to lock or unlock the screen", bundle: VPhoneLocalization.bundle)
        case .wake: String(localized: "Wake the screen without unlocking", bundle: VPhoneLocalization.bundle)
        case .volumeUp: String(localized: "Press the volume up button", bundle: VPhoneLocalization.bundle)
        case .volumeDown: String(localized: "Press the volume down button", bundle: VPhoneLocalization.bundle)
        case .mute: String(localized: "Toggle mute for the active audio category", bundle: VPhoneLocalization.bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .lock: "lock"
        case .wake: "sun.max"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .mute: "speaker.slash"
        }
    }
}
