import ArgumentParser
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

struct VPhoneVirtualMachineCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM end-to-end (prepare → patch → restore → CFW → first boot)",
        discussion: "Runs the full jailbreak pipeline for a new VM. Requires an internet connection to download IPSWs, a macOS host that is not itself a VM, and sudo to install custom firmware.",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "new VM name") var name: String
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(help: "GPU driver bundle from the same cloudOS build, for offline AEA recovery")
    var gpuDriverBundle: String?
    @Option(help: "Directory for downloaded IPSWs, shared by every VM (default: ~/.vphone/ipsws or $VPHONE_ROOT/ipsws)")
    var ipswCache: String?
    @Option(name: .shortAndLong, help: "Disk size (GB)") var diskSize: UInt64 = 64
    @Option(
        name: .customLong("preset"),
        help: "Patch preset for the new VM. Defaults to standard; run `fw patches` to see what each one applies.",
    )
    var preset: String = VPhonePatchPreset.standardIdentifier
    @Flag(
        name: .customLong("keep-artifacts"),
        help: "Keep the prepared restore tree after installation. Downloaded IPSWs always stay in the IPSW cache.",
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
            ipswCacheDirectory: ipswCache.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
            } ?? VPhoneResources.ipswCacheDirectory(),
            patchPreset: preset,
            diskSizeGB: diskSize,
            verbosity: VPhoneVerbosity(count: verboseCount),
            keepArtifacts: keepArtifacts,
        ))
    }
}
