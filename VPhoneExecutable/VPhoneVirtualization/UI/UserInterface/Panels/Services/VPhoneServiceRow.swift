import Foundation

/// One launchd service as `services.list` and `services.status` report it.
struct VPhoneServiceRow: Identifiable, Hashable {
    let label: String
    var domains: [String]
    var isRunning: Bool
    /// The running instance's pid; nil when launchd reports none.
    var pid: Int?
    /// launchd's `LastExitStatus`: a wait(2) status, not an exit code.
    var lastExitStatus: Int?
    var program: String?
    /// The system domain's override: true disabled, false explicitly
    /// enabled, nil when launchd has no override for the label.
    var disabled: Bool?

    var id: String {
        label
    }

    // MARK: - Parsing

    /// Reads a `services.list` row or a `services.status` payload. The list
    /// carries `disabled` only for overridden labels; status carries
    /// `enabled` and `override` instead.
    init?(_ object: [String: Any]) {
        guard let label = object.string("label"), !label.isEmpty else { return nil }
        self.label = label
        domains = object["domains"] as? [String] ?? []
        let pid = object.int("pid") ?? 0
        self.pid = pid > 0 ? pid : nil
        isRunning = object.bool("running") ?? (pid > 0)
        lastExitStatus = object.int("last_exit_status")
        program = object.string("program").flatMap { $0.isEmpty ? nil : $0 }
        if let disabled = object.bool("disabled") {
            self.disabled = disabled
        } else if object.bool("override") == true {
            disabled = !(object.bool("enabled") ?? true)
        } else {
            disabled = nil
        }
    }

    init(
        label: String,
        domains: [String] = ["system"],
        isRunning: Bool = false,
        pid: Int? = nil,
        lastExitStatus: Int? = nil,
        program: String? = nil,
        disabled: Bool? = nil,
    ) {
        self.label = label
        self.domains = domains
        self.isRunning = isRunning
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.program = program
        self.disabled = disabled
    }

    // MARK: - Sort Keys

    var stateRank: Int {
        isRunning ? 0 : 1
    }

    var pidValue: Int {
        pid ?? 0
    }

    var lastExitValue: Int {
        lastExitStatus ?? 0
    }

    var disabledRank: Int {
        switch disabled {
        case true: 0
        case false: 1
        case nil: 2
        }
    }

    var domainText: String {
        domains.joined(separator: ", ")
    }

    var programText: String {
        program ?? ""
    }

    // MARK: - Display

    var pidText: String {
        pid.map(String.init) ?? "—"
    }

    var disabledText: String {
        switch disabled {
        case true: String(localized: "Yes", bundle: VPhoneLocalization.bundle)
        case false: String(localized: "No", bundle: VPhoneLocalization.bundle)
        case nil: "—"
        }
    }

    var lastExit: VPhoneServiceExit {
        VPhoneServiceExit(status: lastExitStatus)
    }
}

// MARK: - Last Exit

/// Decodes launchd's `LastExitStatus` wait status into an exit code or the
/// signal that ended the process.
struct VPhoneServiceExit {
    let status: Int?

    /// `0`, an exit code such as `1`, or a signal such as `SIGKILL`.
    var text: String {
        guard let status else { return "—" }
        if status == 0 {
            return "0"
        }
        // launchctl prints a signalled exit as a negative number; accept it.
        if status < 0 {
            return Self.signalName(-status)
        }
        let signal = status & 0x7F
        if signal == 0 {
            return String((status >> 8) & 0xFF)
        }
        if signal != 0x7F {
            return Self.signalName(signal) + (status & 0x80 != 0 ? "+core" : "")
        }
        return String(status)
    }

    var isAbnormal: Bool {
        (status ?? 0) != 0
    }

    var help: String {
        guard let status else {
            return String(localized: "launchd has not reported an exit.", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "Wait status \(status)", bundle: VPhoneLocalization.bundle)
    }

    static func signalName(_ number: Int) -> String {
        let names = [
            1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
            7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS",
            13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM", 16: "SIGURG", 17: "SIGSTOP",
            18: "SIGTSTP", 19: "SIGCONT", 20: "SIGCHLD", 21: "SIGTTIN", 22: "SIGTTOU",
            23: "SIGIO", 24: "SIGXCPU", 25: "SIGXFSZ", 26: "SIGVTALRM", 27: "SIGPROF",
            28: "SIGWINCH", 29: "SIGINFO", 30: "SIGUSR1", 31: "SIGUSR2",
        ]
        return names[number] ?? "SIG\(number)"
    }
}
