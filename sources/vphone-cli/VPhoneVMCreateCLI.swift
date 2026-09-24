import ArgumentParser
import Foundation
import VPhoneCore

struct VPhoneVMCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM end-to-end (prepare → patch → restore → CFW → first boot)",
        discussion: "Runs the JB pipeline for a fresh VM. Needs an internet connection "
            + "(IPSW download), a non-nested macOS host, and sudo (CFW host-mount).",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "new VM name") var name: String
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(name: .shortAndLong, help: "Disk size (GB)") var diskSize: UInt64 = 64
    @Option(name: .shortAndLong, help: "sudo password for the CFW host-mount install (via askpass; never logged)")
    var sudoPassword: String?
    @Flag(
        name: .customLong("force-dsc-maxslide"),
        help: "Zero the dyld cache maxSlide on non-27 bases (opt-in DSC-map fit)",
    )
    var forceDSCMaxSlide = false
    @Flag(
        name: .customLong("frida"),
        help: "Opt in to Frida Stalker kernel relaxations",
    )
    var frida = false
    @Flag(
        name: .customLong("root-popup"),
        help: "Elevate the CFW host-mount via macOS's native authentication dialog (osascript) instead of a sudo prompt",
    )
    var rootPopup = false
    @Flag(
        name: .customLong("keep-artifacts"),
        help: "Keep the prepared restore tree after installation. Source IPSWs are always kept.",
    )
    var keepArtifacts = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        // Resolved up front: a create boots the guest four times, and this is
        // also where a missing vphone-vm should be reported — before any of the
        // long-running download and patch work, not after it.
        let launcher = try VPhoneGuestLaunchPlanner()
        // Prompt for any firmware component not supplied on the command line.
        let sources = try VPhoneFirmwareSelection.resolve(iphone: iphoneSource, cloudos: cloudosSource)
        guard sources.iphoneSource != nil, sources.cloudosSource != nil else {
            throw ValidationError("Specify both --iphone-source and --cloudos-source when running without a terminal.")
        }
        let orchestrator = VPhoneCreateOrchestrator(
            library: lib.library,
            resources: resources,
            launcher: launcher,
        )
        try orchestrator.run(.init(
            name: name,
            iphoneSource: sources.iphoneSource,
            cloudosSource: sources.cloudosSource,
            sudoPassword: sudoPassword,
            forceDSCMaxSlide: forceDSCMaxSlide,
            enableFrida: frida,
            rootPopup: rootPopup,
            diskSizeGB: diskSize,
            verbosity: VPhoneVerbosity(count: verboseCount),
            keepArtifacts: keepArtifacts,
        ))
    }
}
