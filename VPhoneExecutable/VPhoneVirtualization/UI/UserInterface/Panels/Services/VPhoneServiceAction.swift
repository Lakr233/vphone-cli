import Foundation

// MARK: - Signal

/// The signals the Services window offers, sent to vphoned by name.
enum VPhoneServiceSignal: String, CaseIterable, Identifiable {
    case term = "TERM"
    case kill = "KILL"
    case hup = "HUP"
    case usr1 = "USR1"
    case usr2 = "USR2"

    var id: Self {
        self
    }

    var title: String {
        "SIG" + rawValue
    }
}

// MARK: - Action

/// A launchd operation on one service label.
enum VPhoneServiceAction: Hashable {
    case start
    case stop
    case restart
    case enable
    case disable
    case signal(VPhoneServiceSignal)
    case remove

    /// Destructive actions ask first and send `force: true`.
    var needsConfirmation: Bool {
        switch self {
        case .start, .enable: false
        case .stop, .restart, .disable, .signal, .remove: true
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.triangle.2.circlepath"
        case .enable: "checkmark.circle"
        case .disable: "nosign"
        case .signal: "bolt"
        case .remove: "trash"
        }
    }

    func progressTitle(_ label: String) -> String {
        switch self {
        case .start: String(localized: "Starting \(label)…", bundle: VPhoneLocalization.bundle)
        case .stop: String(localized: "Stopping \(label)…", bundle: VPhoneLocalization.bundle)
        case .restart: String(localized: "Restarting \(label)…", bundle: VPhoneLocalization.bundle)
        case .enable: String(localized: "Enabling \(label)…", bundle: VPhoneLocalization.bundle)
        case .disable: String(localized: "Disabling \(label)…", bundle: VPhoneLocalization.bundle)
        case let .signal(signal): String(localized: "Sending \(signal.title) to \(label)…", bundle: VPhoneLocalization.bundle)
        case .remove: String(localized: "Removing \(label)…", bundle: VPhoneLocalization.bundle)
        }
    }

    func failureMessage(_ label: String, reason: String) -> String {
        switch self {
        case .start: String(localized: "Unable to start \(label). \(reason)", bundle: VPhoneLocalization.bundle)
        case .stop: String(localized: "Unable to stop \(label). \(reason)", bundle: VPhoneLocalization.bundle)
        case .restart: String(localized: "Unable to restart \(label). \(reason)", bundle: VPhoneLocalization.bundle)
        case .enable: String(localized: "Unable to enable \(label). \(reason)", bundle: VPhoneLocalization.bundle)
        case .disable: String(localized: "Unable to disable \(label). \(reason)", bundle: VPhoneLocalization.bundle)
        case let .signal(signal): String(localized: "Unable to send \(signal.title) to \(label). \(reason)", bundle: VPhoneLocalization.bundle)
        case .remove: String(localized: "Unable to remove \(label). \(reason)", bundle: VPhoneLocalization.bundle)
        }
    }

    // MARK: - Confirmation

    func confirmationTitle(_ label: String) -> String {
        switch self {
        case .start: String(localized: "Start \(label)?", bundle: VPhoneLocalization.bundle)
        case .stop: String(localized: "Stop \(label)?", bundle: VPhoneLocalization.bundle)
        case .restart: String(localized: "Restart \(label)?", bundle: VPhoneLocalization.bundle)
        case .enable: String(localized: "Enable \(label)?", bundle: VPhoneLocalization.bundle)
        case .disable: String(localized: "Disable \(label)?", bundle: VPhoneLocalization.bundle)
        case let .signal(signal): String(localized: "Send \(signal.title) to \(label)?", bundle: VPhoneLocalization.bundle)
        case .remove: String(localized: "Remove \(label)?", bundle: VPhoneLocalization.bundle)
        }
    }

    var confirmationMessage: String {
        switch self {
        case .start, .enable:
            ""
        case .stop:
            String(localized: "launchd stops the service. A service with KeepAlive may start again.", bundle: VPhoneLocalization.bundle)
        case .restart:
            String(localized: "launchd stops the service, then starts it again.", bundle: VPhoneLocalization.bundle)
        case .disable:
            String(localized: "launchd records a persistent override so the service does not load at the next boot. A running instance keeps running.", bundle: VPhoneLocalization.bundle)
        case .signal:
            String(localized: "launchd delivers the signal to the service's process.", bundle: VPhoneLocalization.bundle)
        case .remove:
            String(localized: "launchd unloads the service from its domain until it is loaded again or the guest restarts.", bundle: VPhoneLocalization.bundle)
        }
    }

    var confirmationButton: String {
        switch self {
        case .start: String(localized: "Start", bundle: VPhoneLocalization.bundle)
        case .stop: String(localized: "Stop", bundle: VPhoneLocalization.bundle)
        case .restart: String(localized: "Restart", bundle: VPhoneLocalization.bundle)
        case .enable: String(localized: "Enable", bundle: VPhoneLocalization.bundle)
        case .disable: String(localized: "Disable", bundle: VPhoneLocalization.bundle)
        case let .signal(signal): String(localized: "Send \(signal.title)", bundle: VPhoneLocalization.bundle)
        case .remove: String(localized: "Remove", bundle: VPhoneLocalization.bundle)
        }
    }
}

/// An action waiting for the user to confirm it.
struct VPhoneServicePendingAction: Identifiable {
    let action: VPhoneServiceAction
    let label: String

    var id: String {
        "\(label)|\(action)"
    }
}
