import Foundation

/// Modifier prefixes `input.key` accepts, in the order they are pressed.
enum VPhoneControlsModifier: String, CaseIterable, Identifiable {
    case control
    case option
    case shift
    case command

    var id: Self {
        self
    }

    var name: String {
        switch self {
        case .control: "ctrl"
        case .option: "alt"
        case .shift: "shift"
        case .command: "cmd"
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    var help: String {
        switch self {
        case .control: String(localized: "Hold Control while sending a special key", bundle: VPhoneLocalization.bundle)
        case .option: String(localized: "Hold Option while sending a special key", bundle: VPhoneLocalization.bundle)
        case .shift: String(localized: "Hold Shift while sending a special key", bundle: VPhoneLocalization.bundle)
        case .command: String(localized: "Hold Command while sending a special key", bundle: VPhoneLocalization.bundle)
        }
    }
}
