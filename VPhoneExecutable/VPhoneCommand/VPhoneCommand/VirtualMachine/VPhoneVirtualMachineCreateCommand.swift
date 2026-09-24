import ArgumentParser
import Foundation
import VPhoneCoreKit

struct VPhoneVirtualMachineCreateCommand: ParsableCommand {
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
    @Option(help: "GPU driver bundle from the same cloudOS build, for offline AEA recovery")
    var gpuDriverBundle: String?
    @Option(name: .shortAndLong, help: "Disk size (GB)") var diskSize: UInt64 = 64
    @Flag(
        name: .customLong("force-dsc-maxslide"),
        help: "Zero the dyld cache maxSlide on non-27 bases (opt-in DSC-map fit)",
    )
    var forceDyldSharedCacheMaxSlide = false
    @Flag(
        name: .customLong("frida"),
        help: "Opt in to Frida Stalker kernel relaxations",
    )
    var frida = false
    @Flag(
        name: .customLong("keep-artifacts"),
        help: "Keep the prepared restore tree after installation. Source IPSWs are always kept.",
    )
    var keepArtifacts = false
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let resources = VPhoneResources.resolve()
        // Resolved up front: a create boots the guest four times, and this is
        // also where a missing vphone-vm should be reported — before any of the
        // long-running download and patch work, not after it.
        let launcher = try VPhoneGuestLaunchPlanner()
        // Prompt for any firmware component not supplied on the command line.
        let sources = try VPhoneFirmwareSourceSelection.resolve(iphone: iphoneSource, cloudos: cloudosSource)
        guard sources.iphoneSource != nil, sources.cloudosSource != nil else {
            throw ValidationError("Specify both --iphone-source and --cloudos-source when running without a terminal.")
        }
        let orchestrator = VPhoneVirtualMachineCreator(
            library: lib.library,
            resources: resources,
            launcher: launcher,
        )
        try orchestrator.run(.init(
            name: name,
            iphoneSource: sources.iphoneSource,
            cloudosSource: sources.cloudosSource,
            gpuDriverBundle: gpuDriverBundle.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            forceDyldSharedCacheMaxSlide: forceDyldSharedCacheMaxSlide,
            enableFrida: frida,
            diskSizeGB: diskSize,
            verbosity: VPhoneVerbosity(count: verboseCount),
            keepArtifacts: keepArtifacts,
        ))
    }
}
