import Foundation
import Security

// MARK: - VPhoneGuestLaunchError

public enum VPhoneGuestLaunchError: Error, CustomStringConvertible {
    case missingCompanion(name: String, expectedAt: URL)
    /// amfid refused `vphone-vm`. Carries what the advice needs to be concrete:
    /// the binary that was refused and, when it could be read, its cdhash.
    case blockedByAMFI(guest: URL, cdHash: String?)
    case missingEntitlements(guest: URL)
    case probeFailed(exitCode: Int32, output: String)

    public var description: String {
        switch self {
        case let .missingCompanion(name, url):
            return """
            \(name) is missing — expected it next to this binary at:
              \(url.path)
            The install looks incomplete. Rebuild with `make build`.
            """

        case let .blockedByAMFI(guest, cdHash):
            let helper = guest.deletingLastPathComponent()
                .appendingPathComponent("vphone-amfi-allow")
            return """
            amfid refused to launch vphone-vm, so no guest could start.

            Binary: \(guest.path)
            CDHash: \(cdHash ?? "unavailable")

            Allow this build's signed VM binary with the bundled helper:
              sudo '\(helper.path)' allow '\(guest.path)'

            The allowlist is specific to this signature, so repeat after a
            rebuild. See https://github.com/Lakr233/vphone-cli/blob/main/docs/guides/host-setup.md
            for host settings.
            """

        case let .missingEntitlements(guest):
            return """
            vphone-vm is missing the private PV=3 entitlements: \(guest.path)
            Run `make build` to sign this binary, then allow the new signature
            through the host's AMFI policy before launching a VM.
            """

        case let .probeFailed(code, output):
            return """
            vphone-vm could not start (exit \(code)). This is not the signature \
            of an amfid refusal, so AMFI is not what to look at.
            \(output.isEmpty ? "It produced no output." : output)
            """
        }
    }
}

// MARK: - VPhoneGuestLaunchPlanner

/// Decides, once, whether a guest can be started at all, then hands out the
/// concrete command for each boot.
///
/// The two binaries are split precisely so this indirection can exist:
/// `vphone-vm` carries the private virtualization entitlements and therefore
/// cannot launch unless amfid is willing, while `vphone-cli` carries none and
/// always launches. That makes `vphone-cli` the one process that is still
/// running when the refusal happens, and so the only one that can explain it.
///
/// Explaining is now all it does. It used to open an AMFI window itself, by
/// running a root helper that patched amfid's `__TEXT` for the length of one
/// launch; a host with `vm.cs_system_enforcement` set kills amfid outright for
/// that dirty page, so the helper was removed. Getting past amfid is the
/// user's own business now, and `VPhoneGuestLaunchError.blockedByAMFI` is what
/// tells them how.
///
/// It is a value rather than a set of static calls because `vm create` boots
/// the guest more than once, and probing amfid once per boot would be wasteful.
public struct VPhoneGuestLaunchPlanner: Sendable {
    /// The guest binary. Host preflight checks this, because this is the
    /// binary that actually has to satisfy amfid.
    public let guestExecutable: URL

    public init() throws {
        let vm = VPhoneResources.siblingExecutable("vphone-vm")
        guard FileManager.default.isExecutableFile(atPath: vm.path) else {
            throw VPhoneGuestLaunchError.missingCompanion(name: "vphone-vm", expectedAt: vm)
        }
        guestExecutable = vm

        // `swift test -c release` can replace a signed release binary with
        // its linker-signed, unentitled build. That binary answers --help, but
        // PV=3 isSupported is false when the VM is created.
        guard try Self.hasRequiredEntitlements(vm) else {
            throw VPhoneGuestLaunchError.missingEntitlements(guest: vm)
        }

        // Probe before doing anything else. Launching straight into a SIGKILL
        // would leave the caller with a bare exit 9 and no explanation — which
        // is the confusing failure this whole path exists to remove.
        if try Self.amfidRefuses(vm) {
            throw VPhoneGuestLaunchError.blockedByAMFI(
                guest: vm,
                cdHash: Self.codeDirectoryHash(of: vm),
            )
        }
    }

    /// The command to spawn for one boot.
    public func plan(_ arguments: [String]) -> (executable: URL, arguments: [String]) {
        (guestExecutable, arguments)
    }

    /// Run a guest to completion and return its exit status.
    ///
    /// stdio is inherited so the guest's serial output streams straight to the
    /// terminal, and the child is placed in the terminal's foreground group so
    /// that Ctrl-C behaves normally.
    @discardableResult
    public func run(_ arguments: [String], cwd: URL? = nil) throws -> Int32 {
        let (exe, args) = plan(arguments)
        return try VPhoneProcessRunner.runForeground(exe, args, cwd: cwd)
    }

    // MARK: - Probe

    private static func hasRequiredEntitlements(_ vm: URL) throws -> Bool {
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["-d", "--entitlements", "-", "--xml", vm.path],
        )
        guard result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(result.stdout.utf8), format: nil,
              ) as? [String: Any]
        else { return false }
        return plist["com.apple.private.virtualization"] as? Bool == true &&
            plist["com.apple.private.virtualization.security-research"] as? Bool == true
    }

    /// Ask amfid the question cheaply, by running `vphone-vm --help`.
    ///
    /// amfid decides at exec, before any of the target's own code runs, so a
    /// `--help` that never prints is the same refusal the real launch would
    /// hit — and it costs nothing and touches no VM state. A refused process is
    /// killed with SIGKILL, which Foundation reports as termination status 9.
    ///
    /// Anything else non-zero is somebody else's problem, and is raised as
    /// itself rather than being mistaken for an AMFI refusal.
    private static func amfidRefuses(_ vm: URL) throws -> Bool {
        let probe = try VPhoneProcessRunner.runCapturing(vm, ["--help"])
        if probe.succeeded {
            return false
        }
        if probe.exitCode == SIGKILL {
            return true
        }
        throw VPhoneGuestLaunchError.probeFailed(
            exitCode: probe.exitCode,
            output: (probe.stderr + probe.stdout).trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    /// A binary's code-directory hash, in the hex form amfidont's `--cdhash`
    /// wants and `codesign -dv --verbose=4` prints.
    ///
    /// Read in-process through the Security framework rather than by spawning
    /// `codesign`: `kSecCodeInfoUnique` *is* the cdhash, straight from the
    /// code-signing machinery instead of scraped out of another tool's output.
    /// That means no subprocess on a path that is already failing, and no
    /// chance of picking up some other `codesign` from `PATH`. The two agree
    /// byte for byte — checked against `codesign -dv --verbose=4`.
    ///
    /// `nil` means the binary could not be read or is unsigned; the caller
    /// then tells the user how to obtain the hash instead of inventing one.
    static func codeDirectoryHash(of binary: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess,
              let code
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let entries = information as? [String: Any],
              let hash = entries[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
