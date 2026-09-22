import ArgumentParser
import Foundation

// MARK: - VPhoneVariant

/// Which firmware variant a guest is running.
///
/// This used to be nested inside `VPhoneVirtualMachine`, which put it on the
/// far side of the Virtualization framework. It is a five-case string enum with
/// no VM in it, and both binaries need it — `vphone-cli` to accept `--variant`,
/// `vphone-vm` to configure the machine — so it belongs down here. The kit
/// keeps a `VPhoneVirtualMachine.Variant` typealias so existing call sites read
/// the same as before.
public enum VPhoneVariant: String, Sendable, CaseIterable, ExpressibleByArgument {
    case less
    case regular
    case dev
    case jb
    case exp
}

// MARK: - VPhoneBootCLI

/// The options for booting a guest.
///
/// Both binaries parse this same declaration. `vphone-vm` runs it: it builds
/// the machine and becomes the NSApplication. `vphone-cli` only *forwards* it,
/// re-rendering itself through `bootArguments` and spawning `vphone-vm`.
///
/// Keeping one declaration is what makes the two agree about what `--dfu` or
/// `--variant jb` mean, and it means `vphone-cli boot --help` and
/// `vphone-vm --help` cannot drift apart.
///
/// Note it has no `run()` that boots. `vphone-cli`'s entry point recognises
/// this command type and spawns instead, so `run()` here would only ever be a
/// trap for whoever calls it directly.
public struct VPhoneBootCLI: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a virtual iPhone (PV=3)",
        discussion: """
        Creates a Virtualization.framework VM with platform version 3 (vphone)
        and boots it from a manifest plist that describes all paths and hardware.

        The VM itself runs in the companion `vphone-vm` binary, which is the only
        one signed with the private virtualization entitlements. `vphone-cli`
        carries none, so it launches normally and starts `vphone-vm` for you.

        Requires:
          - macOS 15+ (Sequoia or later)
          - SIP/AMFI disabled

        Example:
          vphone-cli --config ./config.plist
        """
    )

    @Option(
        name: .shortAndLong,
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:)
    )
    public var config: URL

    @Flag(name: .shortAndLong, help: "Boot into DFU mode")
    public var dfu: Bool = false

    @Flag(name: .customLong("headless"), help: "Boot without a VM window or menu bar")
    public var headless: Bool = false

    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned port; valid: 6000...65535)")
    public var kernelDebugPort: Int?

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    public var vphonedBin: String = ".vphoned.signed"

    @Option(name: [.customShort("V"), .long], help: "Firmware variant to execute.")
    public var variant: VPhoneVariant = .regular

    @Option(
        help: "Automatically install the given IPA/TIPA after the guest control channel connects. Unavailable with --dfu.",
        transform: URL.init(fileURLWithPath:)
    )
    public var installIPA: URL?

    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned usage (patchless-only).")
    public var noVphoned: Bool = false

    public init() {}

    /// DFU mode is always headless.
    public var noGraphics: Bool {
        dfu || headless
    }

    public var installPackageURL: URL? {
        installIPA?.standardizedFileURL
    }

    public mutating func validate() throws {
        if dfu, let packageURL = installPackageURL {
            throw ValidationError(
                "`--install-ipa` is unavailable with `--dfu` because DFU mode does not start the guest control channel: \(packageURL.path)"
            )
        }

        guard let packageURL = installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ValidationError("`--install-ipa` file does not exist: \(packageURL.path)")
        }

        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            throw ValidationError(
                "`--install-ipa` only supports .ipa or .tipa packages: \(packageURL.lastPathComponent)"
            )
        }
    }

    // MARK: - Forwarding

    /// This command rendered back into arguments for `vphone-vm`.
    ///
    /// Several callers used to hand-build this list — the launch command, and
    /// four sites in the create orchestrator — each spelling the flags out
    /// again and each free to forget one. Rendering from the parsed value keeps
    /// the spelling in the same file as the declaration, so adding an option
    /// cannot silently fail to reach the guest.
    ///
    /// The subcommand name is deliberately omitted: `vphone-vm` *is* the boot
    /// command, so its arguments start at the first option.
    public var bootArguments: [String] {
        var args = ["--config", config.path]
        if dfu { args.append("--dfu") }
        if headless { args.append("--headless") }
        if noVphoned { args.append("--no-vphoned") }
        if variant != .regular { args += ["--variant", variant.rawValue] }
        if vphonedBin != ".vphoned.signed" { args += ["--vphoned-bin", vphonedBin] }
        if let port = kernelDebugPort { args += ["--kernel-debug-port", String(port)] }
        if let ipa = installIPA { args += ["--install-ipa", ipa.path] }
        return args
    }
}
