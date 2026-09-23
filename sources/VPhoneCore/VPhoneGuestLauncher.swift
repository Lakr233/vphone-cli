import ArgumentParser
import Foundation

// MARK: - VPhoneLetMeInPolicy

/// Whether to open an AMFI window before starting the guest.
public enum VPhoneLetMeInPolicy: String, Sendable, CaseIterable, ExpressibleByArgument {
    /// Start `vphone-vm` directly; only reach for `vphone-letmein`, and the
    /// sudo prompt that comes with it, if amfid actually refuses the launch.
    case auto
    /// Always go through `vphone-letmein`.
    case always
    /// Never. If amfid refuses, the launch fails and says so.
    case never

    /// The policy for this run.
    ///
    /// `VPHONE_LETMEIN` exists because only some commands are worth spending a
    /// flag on. `vphone vm launch` takes `--let-me-in` explicitly; everything
    /// else that starts a guest just wants the default, and an environment
    /// variable covers the rare case without adding an option to every command
    /// — including to `VPhoneBootCLI`, which `vphone-vm` also parses and where
    /// such an option would be inert.
    ///
    /// An unrecognised value falls back to `.auto` rather than failing: a typo
    /// in an environment variable should not be able to stop a boot.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> VPhoneLetMeInPolicy {
        env["VPHONE_LETMEIN"].flatMap(VPhoneLetMeInPolicy.init(rawValue:)) ?? .auto
    }
}

// MARK: - VPhoneGuestLaunchError

public enum VPhoneGuestLaunchError: Error, CustomStringConvertible {
    case missingCompanion(name: String, expectedAt: URL)
    case blockedByAMFI
    case blockedByCodeSigningEnforcement
    case probeFailed(exitCode: Int32, output: String)

    public var description: String {
        switch self {
        case let .missingCompanion(name, url):
            """
            \(name) is missing — expected it next to this binary at:
              \(url.path)
            The install looks incomplete. Rebuild with `make build`.
            """
        case .blockedByAMFI:
            """
            amfid refused to launch vphone-vm, and --let-me-in=never forbids \
            opening a window for it.
            Re-run with --let-me-in=auto, or open one yourself:
              sudo vphone-letmein on
            """
        case .blockedByCodeSigningEnforcement:
            """
            amfid refused to launch vphone-vm, and this host cannot be given an \
            AMFI window: `sysctl vm.cs_system_enforcement` reads 1.

            vphone-letmein opens its window by writing into amfid's __TEXT. That \
            makes the page private, dirty and unsigned, and under system-wide \
            enforcement the kernel kills amfid for it (CODESIGNING / "Invalid \
            Page") before it can answer — so the guest dies too and the machine \
            loses its amfid. No sudo prompt was shown, because there is nothing \
            a password would buy here; the sysctl is read-only.

            Relax AMFI instead — see "SIP/AMFI Relaxation", Option A, in \
            README.md. With AMFI relaxed vphone-vm launches on its own and \
            vphone-letmein is not involved at all.
            """
        case let .probeFailed(code, output):
            """
            vphone-vm could not start (exit \(code)). This is not the signature \
            of an amfid refusal, so no AMFI window was opened.
            \(output.isEmpty ? "It produced no output." : output)
            """
        }
    }
}

// MARK: - VPhoneGuestLaunchPlanner

/// Decides, once, how a guest has to be started, then hands out the concrete
/// command for each boot.
///
/// The two binaries are split precisely so this indirection can exist:
/// `vphone-vm` carries the private virtualization entitlements and therefore
/// cannot launch unless amfid is willing, while `vphone-cli` carries none and
/// always launches. That makes `vphone-cli` the natural place to notice the
/// refusal and open a window just wide enough to get past it.
///
/// It is a value rather than a set of static calls because `vm create` boots
/// the guest four times. Probing amfid — and prompting for sudo — once per
/// boot would be both wasteful and, for the prompt, rude.
public struct VPhoneGuestLaunchPlanner: Sendable {
    /// How long the AMFI window stays open, in seconds.
    ///
    /// amfid takes its verdict when the image is exec'd, so this only has to
    /// cover process start-up and dyld's work, not the guest's lifetime — and
    /// the window closing does not disturb a guest that is already running.
    /// Ten seconds is a deliberately loose first guess; it has not yet been
    /// measured against a real launch on a loaded machine.
    public static let defaultWindowSeconds = 10

    private let executable: URL
    private let prefix: [String]

    /// The guest binary itself, whether or not it ends up being launched
    /// directly. Host preflight checks this, because this is the binary that
    /// actually has to satisfy amfid.
    public let guestExecutable: URL

    public init(
        letMeIn: VPhoneLetMeInPolicy? = nil,
        windowSeconds: Int = defaultWindowSeconds,
        announce: Bool = true
    ) throws {
        let policy = letMeIn ?? .fromEnvironment()

        let vm = VPhoneResources.siblingExecutable("vphone-vm")
        guard FileManager.default.isExecutableFile(atPath: vm.path) else {
            throw VPhoneGuestLaunchError.missingCompanion(name: "vphone-vm", expectedAt: vm)
        }
        guestExecutable = vm

        // `never` still probes. Skipping the probe would launch straight into a
        // SIGKILL and leave the caller with a bare exit 9 and no explanation —
        // which is the confusing failure this whole path exists to remove.
        // `never` means "do not open a window", not "do not tell me why".
        let refused = switch policy {
        case .always: true  // taken as read; don't spend a probe to confirm it
        case .auto, .never: try Self.amfidRefuses(vm)
        }

        guard refused else {
            executable = vm
            prefix = []
            return
        }

        if policy == .never {
            throw VPhoneGuestLaunchError.blockedByAMFI
        }

        // Ask before prompting for a password. vphone-letmein refuses on an
        // enforcing host anyway (exit 3), but it can only say so after sudo has
        // already taken the user's password — and a password that buys nothing
        // is worse than an early, specific refusal.
        if Self.codeSigningIsEnforced() {
            throw VPhoneGuestLaunchError.blockedByCodeSigningEnforcement
        }

        let letmein = VPhoneResources.siblingExecutable("vphone-letmein")
        guard FileManager.default.isExecutableFile(atPath: letmein.path) else {
            throw VPhoneGuestLaunchError.missingCompanion(name: "vphone-letmein", expectedAt: letmein)
        }

        if announce {
            print("""
            [vphone] amfid will not let vphone-vm start on its own.
            [vphone] Opening an AMFI window for \(windowSeconds)s to get it launched — this needs sudo.
            [vphone] While that window is open, every signature amfid checks is reported valid.
            """)
        }

        executable = URL(fileURLWithPath: "/usr/bin/sudo")
        prefix = [letmein.path, "exec", "--hold", String(windowSeconds), "--", vm.path]
    }

    /// Does this host kill a process for running a modified page?
    ///
    /// `vm.cs_system_enforcement` is the flag behind the
    /// `CODESIGNING / "Invalid Page"` kill. It is read-only, so this is a
    /// report about the host, not something any caller can change. A missing
    /// sysctl is treated as "not enforcing": on a host old enough not to have
    /// it, letting vphone-letmein try and report for itself beats refusing on a
    /// guess.
    static func codeSigningIsEnforced() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("vm.cs_system_enforcement", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value != 0
    }

    /// The command to spawn for one boot.
    public func plan(_ arguments: [String]) -> (executable: URL, arguments: [String]) {
        (executable, prefix + arguments)
    }

    /// Run a guest to completion and return its exit status.
    ///
    /// stdio is inherited so the guest's serial output streams straight to the
    /// terminal, and the child is placed in the terminal's foreground group so
    /// that both Ctrl-C and an interactive sudo prompt behave normally.
    @discardableResult
    public func run(_ arguments: [String], cwd: URL? = nil) throws -> Int32 {
        let (exe, args) = plan(arguments)
        return try VPhoneProcessRunner.runForeground(exe, args, cwd: cwd)
    }

    // MARK: - Probe

    /// Ask amfid the question cheaply, by running `vphone-vm --help`.
    ///
    /// amfid decides at exec, before any of the target's own code runs, so a
    /// `--help` that never prints is the same refusal the real launch would
    /// hit — and it costs nothing and touches no VM state. A refused process is
    /// killed with SIGKILL, which Foundation reports as termination status 9.
    ///
    /// Anything else non-zero is somebody else's problem, and is raised rather
    /// than quietly escalated into a sudo prompt.
    private static func amfidRefuses(_ vm: URL) throws -> Bool {
        let probe = try VPhoneProcessRunner.runCapturing(vm, ["--help"])
        if probe.succeeded { return false }
        if probe.exitCode == SIGKILL { return true }
        throw VPhoneGuestLaunchError.probeFailed(
            exitCode: probe.exitCode,
            output: (probe.stderr + probe.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
