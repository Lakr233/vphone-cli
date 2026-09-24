import ArgumentParser
import Foundation

// MARK: - Manifest values the Command can take as arguments

/// Kept here, with the other ArgumentParser conformances, rather than beside
/// the type: the manifest is a data model and has no other reason to know that
/// a command line exists.
extension VPhoneVirtualMachineManifest.PlatformFusing: ExpressibleByArgument {}

// MARK: - VPhoneBootCommand

/// The options for booting a guest.
///
/// Both binaries parse this same declaration. `vphone-vm` runs it: it builds
/// the machine and becomes the NSApplication. `vphone-cli` only *forwards* it,
/// re-rendering itself through `bootArguments` and spawning `vphone-vm`.
///
/// Keeping one declaration is what makes the two agree about `--dfu`, and
/// means `vphone-cli boot --help` and
/// `vphone-vm --help` cannot drift apart.
///
/// Note it has no `run()` that boots. `vphone-cli`'s entry point recognises
/// this command type and spawns instead, so `run()` here would only ever be a
/// trap for whoever calls it directly.
public struct VPhoneBootCommand: ParsableCommand {
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
        """,
    )

    @Option(
        name: .shortAndLong,
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:),
    )
    public var config: URL

    @Flag(name: .shortAndLong, help: "Boot into DFU mode")
    public var dfu: Bool = false

    @Flag(name: .customLong("headless"), help: "Boot without a VM window or menu bar")
    public var headless: Bool = false

    @Option(help: "Expose the guest HTTP/WebSocket API on the host, for example 127.0.0.1:8765")
    public var apiListen: String?

    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned port; valid: 6000...65535)")
    public var kernelDebugPort: Int?

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    public var vphonedBin: String = ".vphoned.signed"

    @Option(
        help: "Automatically install the given IPA/TIPA after the guest control channel connects. Unavailable with --dfu.",
        transform: URL.init(fileURLWithPath:),
    )
    public var installIPA: URL?

    public init() {}

    /// Construct a forwarding command without leaving any ArgumentParser
    /// property wrapper in its undecoded definition state.
    public init(
        config: URL,
        dfu: Bool = false,
        headless: Bool = false,
        apiListen: String? = nil,
        kernelDebugPort: Int? = nil,
        vphonedBin: String = ".vphoned.signed",
        installIPA: URL? = nil,
    ) {
        self.config = config
        self.dfu = dfu
        self.headless = headless
        self.apiListen = apiListen
        self.kernelDebugPort = kernelDebugPort
        self.vphonedBin = vphonedBin
        self.installIPA = installIPA
    }

    /// DFU mode is always headless.
    public var noGraphics: Bool {
        dfu || headless
    }

    public var installPackageURL: URL? {
        installIPA?.standardizedFileURL
    }

    public mutating func validate() throws {
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        let bundle = VPhoneBundle(url: config.deletingLastPathComponent(), manifest: manifest)
        if !dfu,
           let existingVariant = VPhoneRestoreInfo.load(fromBundle: bundle)?.variant,
           existingVariant != "jb"
        {
            throw ValidationError(
                "This VM was created as '\(existingVariant)'. Only JB VMs are supported by this build.",
            )
        }

        if dfu, let packageURL = installPackageURL {
            throw ValidationError(
                "`--install-ipa` is unavailable with `--dfu` because DFU mode does not start the guest control channel: \(packageURL.path)",
            )
        }

        if dfu, apiListen != nil {
            throw ValidationError("`--api-listen` is unavailable with `--dfu`.")
        }
        if let apiListen {
            let address = URLComponents(string: "tcp://\(apiListen)")
            guard let address, let host = address.host, !host.isEmpty,
                  let port = address.port, (0 ... 65535).contains(port),
                  address.path.isEmpty, address.query == nil, address.fragment == nil
            else {
                throw ValidationError("`--api-listen` requires host:port, for example 127.0.0.1:8765.")
            }
        }

        guard let packageURL = installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ValidationError("`--install-ipa` file does not exist: \(packageURL.path)")
        }

        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            throw ValidationError(
                "`--install-ipa` only supports .ipa or .tipa packages: \(packageURL.lastPathComponent)",
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
        if dfu {
            args.append("--dfu")
        }
        if headless {
            args.append("--headless")
        }
        if let apiListen {
            args += ["--api-listen", apiListen]
        }
        if vphonedBin != ".vphoned.signed" {
            args += ["--vphoned-bin", vphonedBin]
        }
        if let port = kernelDebugPort {
            args += ["--kernel-debug-port", String(port)]
        }
        if let ipa = installIPA {
            args += ["--install-ipa", ipa.path]
        }
        return args
    }
}
