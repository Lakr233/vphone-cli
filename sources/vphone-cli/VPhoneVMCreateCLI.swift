import ArgumentParser
import Foundation
import VPhoneCore

struct VPhoneVMCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM end-to-end (prepare → patch → restore → CFW → first boot)",
        discussion: "Runs the full pipeline for a fresh VM. Needs an internet connection "
            + "(IPSW download), a non-nested macOS host, and sudo (CFW host-mount). "
            + "The 'less' (patchless) variant must itself be run with sudo — the whole "
            + "create runs as root, not just the fw-patch stage.")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "new VM name") var name: String
    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp | less") var variant: String = "regular"
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(name: .shortAndLong, help: "sudo password for the CFW host-mount install (via askpass; never logged)")
    var sudoPassword: String?
    @Option(name: [.customShort("b"), .long], help: "(exp only) rewrite ProductBuildVersion to this build id") var spoofBuild: String?
    @Flag(name: .customLong("force-dsc-maxslide"), help: "Zero the dyld cache maxSlide on non-27 bases (opt-in DSC-map fit)") var forceDSCMaxSlide = false
    @Flag(help: "Prompt at first-boot stages instead of running non-interactively") var interactive = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let selfExe = VPhoneResources.runningExecutable()
        // Prompt for any firmware component not supplied on the command line.
        let sources = try VPhoneFirmwareSelection.resolve(iphone: iphoneSource, cloudos: cloudosSource)
        let orchestrator = VPhoneCreateOrchestrator(
            library: lib.library, resources: resources, selfExecutable: selfExe)
        try orchestrator.run(.init(
            name: name, variant: variant,
            iphoneSource: sources.iphoneSource, cloudosSource: sources.cloudosSource,
            sudoPassword: sudoPassword, spoofBuild: spoofBuild, forceDSCMaxSlide: forceDSCMaxSlide,
            interactive: interactive, verbosity: VPhoneVerbosity(count: verboseCount)))
    }
}
