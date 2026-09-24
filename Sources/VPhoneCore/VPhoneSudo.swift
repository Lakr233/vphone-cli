import Foundation

// MARK: - Asking for root, once, in one place

/// How this project becomes root.
///
/// Three things needed it and each had grown its own answer: the create
/// orchestrator wrote a throwaway askpass script that echoed `$SUDO_PASSWORD`
/// (which put the password in a spawned process's environment, where `ps -E`
/// shows it to anything running as the same user), `cfw install` re-execs
/// itself under sudo, and the AMFI allow step is a plain `sudo` line a human
/// was expected to paste. This is the one place now.
///
/// Nothing here holds a password. On a terminal sudo reads it from the tty
/// itself; in a window session `vphone-ask-for-permission` collects it and
/// writes it straight down sudo's askpass pipe. Neither path lets it reach
/// this process, a file, or an environment variable.
public enum VPhoneSudo {
    /// What this host will do when sudo is asked for a password.
    /// The raw values are the words `vphone-ask-for-permission --probe` prints;
    /// keep the two in step.
    public enum Route: String, Sendable {
        /// A previous sudo is still within its timestamp. Nothing will prompt.
        case timestamp
        /// `pam_tid.so` is in sudo's PAM stack: the prompt is Touch ID.
        case touchID = "touchid"
        /// Neither, so something has to ask for a password.
        case askpass
    }

    /// The helper that renders the password dialog. Resolved as a sibling of
    /// the running image, never through `PATH`, the same rule `vphone-vm`
    /// follows — a bypass planted earlier on `PATH` must not be able to answer
    /// a question about privilege.
    public static var helper: URL {
        VPhoneResources.siblingExecutable("vphone-ask-for-permission")
    }

    /// Which of the three applies right now.
    ///
    /// Asks the helper, so the detection lives in exactly one place. If the
    /// helper is missing or unreadable this reports `.askpass`, which is the
    /// answer that makes the caller do the most work rather than the least.
    public static func route() -> Route {
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              let result = try? VPhoneProcessRunner.runCapturing(helper, ["--probe"]),
              result.succeeded,
              let value = Route(rawValue: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .askpass }
        return value
    }

    /// Refresh the sudo timestamp, prompting however this host allows, so that
    /// the commands that follow do not each prompt again.
    ///
    /// `reason` is shown to the user. Say what is about to happen in terms of
    /// the thing they asked for, not in terms of sudo.
    @discardableResult
    public static func authorize(reason: String, echo: Bool = true) throws -> Route {
        let route = route()
        if route == .timestamp {
            return route
        }

        if echo {
            print("[sudo] \(reason)")
        }

        let sudo = URL(fileURLWithPath: "/usr/bin/sudo")

        // With Touch ID, or on a terminal, sudo does its own prompting and owns
        // the tty while it does — `runForeground` exists for exactly that, and
        // it is the better path because the password never leaves sudo.
        if route == .touchID || isatty(STDIN_FILENO) != 0 {
            let status = try VPhoneProcessRunner.runForeground(sudo, ["-v"])
            guard status == 0 else { throw VPhoneSudoError.declined }
            return route
        }

        // No tty — launched from a window session. sudo cannot prompt, so the
        // helper does, and hands the answer back down sudo's own askpass pipe.
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw VPhoneSudoError.helperMissing(path: helper.path)
        }
        var env = ProcessInfo.processInfo.environment
        env["SUDO_ASKPASS"] = helper.path
        let status = try VPhoneProcessRunner.runStreaming(sudo, ["-A", "-v"], env: env, echo: echo)
        guard status == 0 else { throw VPhoneSudoError.declined }
        return route
    }

    /// Run one command as root, prompting first if that is needed.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        reason: String,
        cwd: URL? = nil,
        echo: Bool = true,
    ) throws -> Int32 {
        try authorize(reason: reason, echo: echo)
        return try VPhoneProcessRunner.runForeground(
            URL(fileURLWithPath: "/usr/bin/sudo"),
            ["--", executable.path] + arguments,
            cwd: cwd,
        )
    }
}

// MARK: - Errors

public enum VPhoneSudoError: Error, CustomStringConvertible {
    case declined
    case helperMissing(path: String)

    public var description: String {
        switch self {
        case .declined:
            "Administrator authorisation was declined."
        case let .helperMissing(path):
            """
            vphone-ask-for-permission is not next to this binary (looked at \(path)).
            It is built by `Scripts/build.sh`; without it there is no way to ask for a \
            password from a window session with no terminal.
            """
        }
    }
}
