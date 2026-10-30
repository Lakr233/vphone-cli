import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit

struct VPhoneVirtualMachineCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM end-to-end (prepare → patch → restore → CFW → first boot)",
        discussion: """
        Runs the full custom-firmware pipeline for a new VM. Requires an internet connection \
        to download IPSWs, a macOS host that is not itself a VM, and sudo to install custom \
        firmware.

        By default the pipeline builds a template instead of the VM: a machine in \
        <library>/.templates that never boots, keyed by the guest device, the iOS and cloudOS \
        builds, the preset and the disk size. The VM is then cloned from it with a new identity, \
        and every later create with the same key clones from the same template in a fraction \
        of a second, without root, an IPSW download or a restore, sharing every unchanged block \
        on disk. Such machines share the template's SEP root secret and Data volume keys; \
        --no-template builds the VM on its own, with keys of its own, as before. \
        --template <id> clones from a template listed by vm template list.

        After cfw install a new template's System volume is trimmed offline (--trim, standard \
        by default; vm template trim describes the tiers). It then boots once before it is \
        frozen (its setup boot): the orig-fs snapshot is deleted, which frees what the trim \
        removed, Setup Assistant skipped, first-boot work waited for, the default system apps \
        removed (App Store, Home, TV, News, FaceTime, iTunes Store, Messages, Games, Find My, \
        Wallet; never Phone or Camera) and the trimmed service profile applied, then it reboots, \
        is checked and shut down. Every clone starts at the Lock Screen with that state. \
        --slim off trims nothing and keeps every app and service (Setup is still skipped); \
        --trim, --keep-languages, --service-profile, --remove-apps, --keep-apps and \
        --accounts-off pick parts. Each choice is part of the key, so templates with different \
        slimming live side by side. A template never keeps the restore tree: --keep-artifacts \
        keeps it only with --no-template.

        --cpu, --memory, --network and --unlock-at-startup are set on the new VM, whichever way \
        it is made.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "new VM name") var name: String
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(help: "GPU driver bundle from the same cloudOS build, for offline AEA recovery")
    var gpuDriverBundle: String?
    @Option(help: "Directory for downloaded IPSWs, shared by every VM (default: ~/.vphone/ipsws or $VPHONE_ROOT/ipsws)")
    var ipswCache: String?
    @Option(help: ArgumentHelp(
        "Guest device, when the IPSW covers several models (iPad15,5 from the iPad Air IPSW)",
        valueName: "product-type",
    ))
    var device: String?
    @Option(help: ArgumentHelp(
        "Full OTA (.aea or .zip) URL or local path for an OTA userland guest, including Apple TV 4K and HomePod mini (default: the catalog's OTA when required)",
        valueName: "ota",
    ))
    var otaSource: String?
    @Option(help: ArgumentHelp("The OTA's AEA key in base64, as AppleDB lists it (default: the catalog's)", valueName: "base64"))
    var otaKey: String?
    @Option(name: .shortAndLong, help: "Disk size (GB, default 64)") var diskSize: UInt64?
    @Option(
        name: .customLong("preset"),
        help: "Patch preset name, or path to a preset plist, for the new VM. Defaults to standard; run `fw patches` to see what each one applies.",
    )
    var preset: String?
    @Option(name: .long, help: "CPU cores (default 8)") var cpu: UInt?
    @Option(name: .long, help: "Memory (MB, default 8192)") var memory: UInt64?
    @Option(name: [.customShort("n"), .long], help: "Network mode: nat (default) | bridged | tunnel | none")
    var network: String?
    @Option(name: .long, help: "Unlock the guest when it starts: on | off (default)")
    var unlockAtStartup: String?
    @Option(help: ArgumentHelp("Clone the VM from this template (vm template list)", valueName: "id"))
    var template: String?
    @Flag(help: "Build the VM on its own, with SEP and Data volume keys of its own, instead of from a template")
    var noTemplate = false
    @Flag(help: "Do not boot the new VM to check that vphoned answers")
    var skipFirstBoot = false
    @OptionGroup(title: "Template slimming") var slimming: VPhoneTemplateSlimmingOptions
    @Flag(
        name: .customLong("keep-artifacts"),
        help: "Keep the prepared restore tree after installation. Downloaded IPSWs always stay in the IPSW cache.",
    )
    var keepArtifacts = false
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    /// A local donor can identify the guest even when --device is omitted.
    /// Validation reads it once; explicit device selection always takes precedence.
    private var inferredProductType: String?

    private var selectedGuest: VPhoneGuestDevice? {
        VPhoneGuestDevice.named(device ?? inferredProductType)
    }

    private var selectedDevice: String? {
        device ?? inferredProductType
    }

    private var ipswCacheDirectory: URL {
        ipswCache.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? VPhoneResources.ipswCacheDirectory()
    }

    private var usesTVOS: Bool {
        selectedGuest?.usesTVOS == true
    }

    /// A preset that customises the system before the restore (`minimal`): the
    /// offline trim and the setup boot of a template write the System volume,
    /// which would break that system's seal.
    private var customisesRestoredSystem: Bool {
        (try? resolvedPreset().preset)?.patchSets
            .contains { $0.identifier == FirmwareRestoreImagePatchSet.identifier } ?? false
    }

    private func resolvedPreset() throws -> (preset: VPhonePatchPreset, file: VPhonePatchPreset?) {
        try VPhonePatchPresetStore.resolve(preset ?? defaultPreset)
    }

    /// An Apple TV takes the TV preset; one whose userland comes from an OTA
    /// takes the arm64e one, with the GPU driver and the userland swap. An
    /// Apple Watch takes the watch preset, an iPhone XS Max `minimal`: its iOS 18
    /// research board kernel boots no other.
    private var defaultPreset: String {
        switch selectedGuest {
        case let guest? where guest.family == .appleTV:
            guest.restoreBase == nil ? VPhonePatchPreset.tvOSIdentifier : VPhonePatchPreset.tvOS4KIdentifier
        case let guest? where guest.family == .homeView:
            VPhonePatchPreset.homeViewIdentifier
        case let guest? where guest.family == .homePod:
            VPhonePatchPreset.homePodMiniIdentifier
        case let guest? where guest.family == .watch:
            VPhonePatchPreset.watchOSIdentifier
        case let guest? where guest.notchedArtworkSubtype != nil:
            VPhonePatchPreset.minimalIdentifier
        default:
            VPhonePatchPreset.standardIdentifier
        }
    }

    mutating func validate() throws {
        // Named templates reject firmware options below and need no IPSW read.
        // localArchive also recognizes an existing cached remote source without
        // downloading or changing the cache.
        if template == nil, device == nil, let iphoneSource,
           let archive = try VPhoneIPSWCache.localArchive(iphoneSource, in: ipswCacheDirectory)
        {
            inferredProductType = VPhoneIPSWCache.guestDevice(for: archive)?.productType
        }

        if template != nil, noTemplate {
            throw ValidationError("--template and --no-template exclude each other.")
        }
        if noTemplate, try !slimming.request.isEmpty {
            throw ValidationError("The slimming switches shape a template; --no-template builds the VM without one.")
        }
        if otaSource != nil || otaKey != nil,
           VPhoneGuestDevice.named(device)?.restoreBase == nil,
           VPhoneGuestDevice.named(device)?.family != .homePod {
            throw ValidationError("--ota-source and --ota-key require an OTA userland device, such as --device AppleTV14,1 or AudioAccessory5,1.")
        }
        if usesTVOS {
            // Templates and their setup boot drive iOS Setup Assistant and its apps.
            if template != nil {
                throw ValidationError("A tvOS or HomePod guest is built without a template; --template cannot be used.")
            }
            if try !slimming.request.isEmpty {
                throw ValidationError("A tvOS or HomePod guest is built without a template; the slimming switches do not apply.")
            }
        }
        if customisesRestoredSystem {
            if template != nil {
                throw ValidationError("The \(preset ?? defaultPreset) preset builds a VM without a template; --template cannot be used.")
            }
            if try !slimming.request.isEmpty {
                throw ValidationError("The \(preset ?? defaultPreset) preset builds a VM without a template; the slimming switches do not apply.")
            }
        }
        _ = try slimming.resolve()
        if template != nil {
            let firmware = [
                ("--iphone-source", iphoneSource != nil),
                ("--cloudos-source", cloudosSource != nil),
                ("--gpu-driver-bundle", gpuDriverBundle != nil),
                ("--ipsw-cache", ipswCache != nil),
                ("--keep-artifacts", keepArtifacts),
            ].filter(\.1).map(\.0)
            if !firmware.isEmpty {
                throw ValidationError("\(firmware.joined(separator: ", ")) cannot be used with --template: the template's firmware is already installed.")
            }
        }
    }

    func run() throws {
        let resources = VPhoneResources.resolve()
        if let device, VPhoneGuestDevice.named(device) == nil {
            throw ValidationError("vphone runs \(VPhoneGuestDevice.known.map(\.productType).joined(separator: ", ")) guests, not \(device).")
        }
        let patchPreset = try resolvedPreset()
        let networkMode = try network.map(VPhoneVirtualMachineConfigCommand.parseMode)
        let unlocks = try unlockAtStartup.map { try VPhoneVirtualMachineConfigCommand.parseSwitch($0, option: "--unlock-at-startup") }
        let templateUse: VPhoneVirtualMachineCreator.TemplateUse = if let template {
            .identifier(template)
        } else if noTemplate || usesTVOS || customisesRestoredSystem {
            .none
        } else {
            .automatic
        }

        // Resolved up front: a create boots the guest four times, and this is
        // also where a missing vphone-vm should be reported — before any of the
        // long-running download and patch work, not after it. A clone from a
        // named template that skips its first boot starts no guest at all.
        let launcher: VPhoneGuestLaunchPlanner? = if case .identifier = templateUse, skipFirstBoot {
            nil
        } else {
            try VPhoneGuestLaunchPlanner()
        }

        var sources = VPhoneFirmwareSources(iphoneSource: nil, cloudosSource: nil)
        if templateUse == .none || templateUse == .automatic {
            // Prompt for any firmware component not supplied on the command line,
            // from the guest device's builds.
            sources = try VPhoneFirmwareSourceSelection.resolve(iphone: iphoneSource, cloudos: cloudosSource, device: selectedDevice)
            guard sources.iphoneSource != nil, sources.cloudosSource != nil else {
                throw ValidationError("Specify both --iphone-source and --cloudos-source when running without a terminal.")
            }
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
            ipswCacheDirectory: ipswCacheDirectory,
            device: selectedDevice,
            otaSource: otaSource,
            otaKey: otaKey,
            patchPreset: patchPreset.preset.identifier,
            patchPresetFile: patchPreset.file,
            cpuCount: cpu ?? 8,
            memoryMB: memory ?? 8192,
            diskSizeGB: diskSize ?? 64,
            networkMode: networkMode,
            unlocksAtStartup: unlocks,
            verbosity: VPhoneVerbosity(count: verboseCount),
            keepArtifacts: keepArtifacts,
            template: templateUse,
            templateRequest: VPhoneMachineTemplateRequest(
                device: device,
                patchPreset: preset == nil ? nil : patchPreset.preset.identifier,
                diskSizeGB: diskSize,
                slimming: slimming.request.isEmpty ? nil : slimming.resolve(),
            ),
            skipsFirstBoot: skipFirstBoot,
            slimming: slimming.resolve(),
        ))
    }
}
