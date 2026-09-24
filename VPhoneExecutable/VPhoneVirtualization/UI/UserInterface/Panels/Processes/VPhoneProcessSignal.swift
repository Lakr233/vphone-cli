import Foundation

/// The signals `processes.kill` accepts. The raw value is the wire name.
enum VPhoneProcessSignal: String, CaseIterable, Identifiable {
    case term = "TERM"
    case kill = "KILL"
    case stop = "STOP"
    case cont = "CONT"
    case hup = "HUP"
    case int = "INT"
    case usr1 = "USR1"
    case usr2 = "USR2"

    /// The signals the toolbar Signal menu offers; Terminate has its own button.
    static let menuSignals: [VPhoneProcessSignal] = [.kill, .stop, .cont, .hup, .int, .usr1, .usr2]

    var id: Self {
        self
    }

    /// `SIGTERM`, `SIGKILL`, … — never localized.
    var name: String {
        "SIG\(rawValue)"
    }

    /// The menu item title.
    var title: String {
        switch self {
        case .term: String(localized: "Terminate", bundle: VPhoneLocalization.bundle)
        case .kill: String(localized: "Kill", bundle: VPhoneLocalization.bundle)
        case .stop: String(localized: "Stop", bundle: VPhoneLocalization.bundle)
        case .cont: String(localized: "Continue", bundle: VPhoneLocalization.bundle)
        case .hup: String(localized: "Hang Up", bundle: VPhoneLocalization.bundle)
        case .int: String(localized: "Interrupt", bundle: VPhoneLocalization.bundle)
        case .usr1: String(localized: "User Signal 1", bundle: VPhoneLocalization.bundle)
        case .usr2: String(localized: "User Signal 2", bundle: VPhoneLocalization.bundle)
        }
    }

    /// `Kill (SIGKILL)`.
    var menuTitle: String {
        "\(title) (\(name))"
    }

    /// One sentence on what the signal does, shown in the confirmation dialog.
    var explanation: String {
        switch self {
        case .term:
            String(localized: "SIGTERM asks the process to exit. launchd may relaunch it.", bundle: VPhoneLocalization.bundle)
        case .kill:
            String(localized: "SIGKILL ends the process immediately without cleanup. launchd may relaunch it.", bundle: VPhoneLocalization.bundle)
        case .stop:
            String(localized: "SIGSTOP suspends the process until it receives SIGCONT.", bundle: VPhoneLocalization.bundle)
        case .cont:
            String(localized: "SIGCONT resumes a stopped process.", bundle: VPhoneLocalization.bundle)
        case .hup:
            String(localized: "SIGHUP usually asks a daemon to reload or exit.", bundle: VPhoneLocalization.bundle)
        case .int:
            String(localized: "SIGINT interrupts the process, like Control-C in a terminal.", bundle: VPhoneLocalization.bundle)
        case .usr1, .usr2:
            String(localized: "The process defines what \(name) does.", bundle: VPhoneLocalization.bundle)
        }
    }

    var isDestructive: Bool {
        self != .cont
    }
}

/// A signal waiting for the user to confirm it.
struct VPhoneProcessSignalRequest: Identifiable {
    let id = UUID()
    let signal: VPhoneProcessSignal
    let targets: [VPhoneProcessRow]

    var title: String {
        if targets.count == 1, let target = targets.first {
            return String(localized: "Send \(signal.name) to \(target.displayName) (pid \(target.pid))?", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "Send \(signal.name) to \(targets.count) processes?", bundle: VPhoneLocalization.bundle)
    }

    var message: String {
        guard targets.count > 1 else { return signal.explanation }
        let shown = targets.prefix(6).map(\.reference).joined(separator: ", ")
        let list = targets.count > 6
            ? String(localized: "\(shown), and \(targets.count - 6) more.", bundle: VPhoneLocalization.bundle)
            : shown
        return "\(list)\n\n\(signal.explanation)"
    }

    var confirmTitle: String {
        switch signal {
        case .term, .kill, .stop, .cont: signal.title
        default: String(localized: "Send \(signal.name)", bundle: VPhoneLocalization.bundle)
        }
    }
}
