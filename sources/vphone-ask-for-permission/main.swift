import AppKit
import Foundation

// vphone-ask-for-permission — the one place this project asks for a password.
//
// It is a SUDO_ASKPASS program. `sudo -A` runs it, passes its own prompt as
// argv[1], and reads the password from stdout; nothing else in the pipeline
// ever holds it. That matters, because the thing this replaces wrote a shell
// script to a temp file that echoed $SUDO_PASSWORD, which put the password in
// a spawned process's environment where `ps -E` shows it to any process of the
// same user.
//
// It is also the probe: `--probe` reports how privilege can be obtained on
// this host, so the caller knows whether to run plain `sudo` (Touch ID or a
// live timestamp will handle it) or `sudo -A` (this program will).
//
// Note on Touch ID: authenticating the user here, with LocalAuthentication,
// would prove who is at the keyboard and grant nothing — LAContext does not
// hand out privilege. The only Touch ID that helps is pam_tid inside sudo's
// own PAM stack, so that is what `--probe` looks for.

// MARK: - Touch ID for sudo

enum VPhoneSudoTouchID {
    /// The two files sudo's PAM stack reads. `sudo_local` is the supported
    /// place since Sonoma — `/etc/pam.d/sudo` itself is replaced on update,
    /// which is why Apple added the include.
    static let configurationFiles = ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"]

    /// Whether any of them enables `pam_tid.so` on a line that is not
    /// commented out. sudo's PAM files comment with `#`.
    static var isConfigured: Bool {
        configurationFiles.contains { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("#") && trimmed.contains("pam_tid.so")
            }
        }
    }
}

// MARK: - A live sudo timestamp

enum VPhoneSudoTimestamp {
    /// `sudo -n true` succeeds when a timestamp is still valid, and fails
    /// without prompting when it is not. It is the only way to ask "would
    /// sudo prompt?" without risking a prompt.
    static var isValid: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - The dialog

enum VPhonePasswordPrompt {
    /// A modal password dialog, or nil if the user cancelled.
    ///
    /// Runs on an NSApplication with an accessory activation policy: no Dock
    /// tile, no menu bar, but the panel still comes to the front, which a bare
    /// `runModal` from a command-line tool does not.
    @MainActor
    static func ask(prompt: String) -> String? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "vphone needs administrator privileges"
        alert.informativeText = prompt
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Authenticate")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

// MARK: - Entry point

/// What sudo shows when it asks. sudo hands its own prompt in argv[1]; this is
/// only the fallback for a direct run.
let defaultPrompt = "Enter the password for \(NSUserName()) to continue."

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--probe" {
    // Three routes, most to least convenient. The caller reads the first word.
    if VPhoneSudoTimestamp.isValid {
        print("timestamp")
    } else if VPhoneSudoTouchID.isConfigured {
        print("touchid")
    } else {
        print("askpass")
    }
    exit(0)
}

if arguments.first == "--help" || arguments.first == "-h" {
    print("""
    usage:
      vphone-ask-for-permission [prompt]   Ask for a password, print it on stdout.
                                           This is the SUDO_ASKPASS interface:
                                           sudo -A runs it and passes its prompt.
      vphone-ask-for-permission --probe    Print how privilege can be obtained
                                           here: timestamp | touchid | askpass.
    """)
    exit(0)
}

let prompt = arguments.first.map { $0.isEmpty ? defaultPrompt : $0 } ?? defaultPrompt

let password = MainActor.assumeIsolated { VPhonePasswordPrompt.ask(prompt: prompt) }
guard let password else {
    // sudo reads a non-zero exit as "the user declined" and stops asking.
    exit(1)
}

// sudo wants the password and a newline, and nothing else on stdout.
FileHandle.standardOutput.write(Data((password + "\n").utf8))
exit(0)
