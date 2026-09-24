import Foundation

/// Special keys `input.key` accepts.
enum VPhoneControlsKey: String, CaseIterable, Identifiable {
    case `return`
    case delete
    case tab
    case escape
    case left
    case up
    case down
    case right

    var id: Self {
        self
    }

    var name: String {
        rawValue
    }

    var isArrow: Bool {
        [.left, .up, .down, .right].contains(self)
    }

    var title: String {
        switch self {
        case .return: String(localized: "Return", bundle: VPhoneLocalization.bundle)
        case .delete: String(localized: "Delete", bundle: VPhoneLocalization.bundle)
        case .tab: String(localized: "Tab", bundle: VPhoneLocalization.bundle)
        case .escape: String(localized: "Escape", bundle: VPhoneLocalization.bundle)
        case .left: String(localized: "Left Arrow", bundle: VPhoneLocalization.bundle)
        case .up: String(localized: "Up Arrow", bundle: VPhoneLocalization.bundle)
        case .down: String(localized: "Down Arrow", bundle: VPhoneLocalization.bundle)
        case .right: String(localized: "Right Arrow", bundle: VPhoneLocalization.bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .return: "return"
        case .delete: "delete.left"
        case .tab: "arrow.right.to.line"
        case .escape: "escape"
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        }
    }
}
