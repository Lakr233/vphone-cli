import Foundation

// MARK: - Login shell rule

/// Which seeded accounts move to the bootstrap's shell.
///
/// vphoned seeds the bootstrap's `/etc` from the system's, where every
/// interactive account is `/bin/sh`, and it does so before Irisin has unpacked
/// a shell. The bootstrap's own `master.passwd` names zsh for root and mobile,
/// but it never lands on a seeded `/etc`, so the guest would log in to dash:
/// no line editing, and `/etc/profile`'s bash-style `PS1` printed literally.
enum GuestLoginShellRule {
    /// What the system's interactive accounts carry.
    static let seededShell = "/bin/sh"

    /// What the bootstrap's own `master.passwd` names for root and mobile.
    static let bootstrapShell = "/usr/bin/zsh"

    /// Rewrites every `master.passwd` entry still on ``seededShell``, and
    /// names the accounts it changed.
    ///
    /// A line is an entry only when it has all ten fields
    /// (`name:password:uid:gid:class:change:expire:gecos:home:shell`), so
    /// comments, blank lines and a trailing newline are carried through
    /// untouched. Accounts that ship `false` or `nologin` keep them, and so
    /// does an account whose shell the user has already changed: both differ
    /// from ``seededShell``. With nothing to change the text is returned as it
    /// came in, so a later refresh rewrites no file.
    static func rewritingLoginShells(_ text: String) -> (text: String, changed: [String]) {
        var changed: [String] = []
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var fields = line.components(separatedBy: ":")
            guard fields.count == 10, fields[9] == seededShell else { return line }
            fields[9] = bootstrapShell
            changed.append(fields[0])
            return fields.joined(separator: ":")
        }
        guard !changed.isEmpty else { return (text, []) }
        return (lines.joined(separator: "\n"), changed)
    }
}
