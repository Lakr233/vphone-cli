import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit

struct VPhoneFirmwareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fw",
        abstract: "Firmware pipeline: prepare (download/merge IPSWs) and patch",
        subcommands: [
            VPhoneFirmwareCatalogCommand.self,
            VPhoneFirmwareInspectCommand.self,
            VPhoneFirmwareOTAStageCommand.self,
            VPhoneFirmwareOTAPreflightCommand.self,
            VPhoneFirmwareOTACommand.self,
            VPhoneFirmwarePrepareCommand.self,
            VPhoneFirmwarePatchCommand.self,
            VPhoneFirmwareKernelcacheCommand.self,
            VPhoneFirmwarePatchesCommand.self,
            VPhoneFirmwareSetPatchesCommand.self,
            VPhoneFirmwareExportPresetCommand.self,
            VPhoneFirmwareManifestCommand.self,
            VPhoneFirmwareListCommand.self,
            VPhoneFirmwareResolveCommand.self,
            VPhoneFirmwareAEAKeyCommand.self,
            VPhoneFirmwareIM4PCreateCommand.self,
            VPhoneFirmwareIM4PExtractCommand.self,
            VPhoneFirmwareURLsCommand.self,
            VPhoneFirmwareSealToolCommand.self,
        ],
    )
}

/// Check a PCC IPSW's build identities using HTTP ranges before committing
/// space to a full download. The hybrid restore requires both device classes.
struct VPhoneFirmwareInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect a remote IPSW manifest without downloading the archive",
    )

    @Argument(help: "Remote IPSW URL") var source: String

    func run() throws {
        guard let url = URL(string: source), ["https", "http"].contains(url.scheme ?? "") else {
            throw ValidationError("Expected an HTTP(S) IPSW URL")
        }
        let data = try vphoneRunBlocking {
            let zip = try await VPhoneRemoteZip.open(url)
            return try await zip.read(zip.entry(endingWith: "BuildManifest.plist"))
        }
        guard let manifest = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
            let identities = manifest["BuildIdentities"] as? [[String: Any]]
        else {
            throw VPhoneRemoteZip.Error.malformed("BuildManifest.plist has no BuildIdentities")
        }
        print("\(manifest["ProductVersion"] ?? "unknown") (\(manifest["ProductBuildVersion"] ?? "unknown"))")
        for deviceClass in ["vresearch101ap", "vphone600ap"] {
            let matches = identities.filter {
                ($0["Info"] as? [String: Any])?["DeviceClass"] as? String == deviceClass
            }
            let variants = matches.compactMap {
                ($0["Info"] as? [String: Any])?["Variant"] as? String
            }
            print("\(deviceClass): \(variants.isEmpty ? "missing" : variants.joined(separator: ", "))")
        }
    }
}

// MARK: - firmware support matrix

/// Lists the available firmware using the URLs supplied by AppleDB.
///
/// Neither writes through `print`: `list` styles stdout and `resolve` styles
/// stderr, and colour is only right if each descriptor is asked separately.
struct VPhoneFirmwareListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Print the downloadable-firmware support matrix for a device",
    )

    @Option(help: "Device identifier, e.g. iPhone17,3") var device: String
    @Option(help: "Compatibility Markdown holding the 'Tested Environments' table") var readme: String

    func run() throws {
        let code = VPhoneFirmwareMatrixCommandLine.list(
            device: device,
            readmePath: readme,
            downloadURLs: ProcessInfo.processInfo.environment["DOWNLOADABLE_IPSW_URLS"] ?? "",
        )
        if code != 0 {
            throw ExitCode(code)
        }
    }
}

struct VPhoneFirmwareResolveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Resolve a version/build selector to a downloadable IPSW URL",
        discussion: """
        Prints version<TAB>build<TAB>url<TAB>status on stdout.

        Exits 2 — not 1 — when a bare version matches more than one build, so a
        caller can tell "pick a build" from "there is no such firmware". An empty
        --version or --build means unconstrained.
        """,
    )

    @Option(help: "Device identifier, e.g. iPhone17,3") var device: String
    @Option(help: "iOS version to match; empty matches any") var version: String = ""
    @Option(help: "Build to match; empty matches any") var build: String = ""
    @Option(help: "Compatibility Markdown holding the 'Tested Environments' table") var readme: String

    func run() throws {
        let code = VPhoneFirmwareMatrixCommandLine.resolve(
            device: device,
            version: version,
            build: build,
            readmePath: readme,
            downloadURLs: ProcessInfo.processInfo.environment["DOWNLOADABLE_IPSW_URLS"] ?? "",
        )
        if code != 0 {
            throw ExitCode(code)
        }
    }
}

// MARK: - manifest

/// Generates the hybrid manifest after both IPSWs are extracted and merged.
struct VPhoneFirmwareManifestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Write the hybrid BuildManifest.plist and Restore.plist into the iPhone directory",
        discussion: """
        Merges the cloudOS boot chain (vresearch101ap, which is what the VM
        identifies as in DFU) with vphone600 runtime components and the iPhone
        OS images into a single DFU erase-install build identity.

        Both files are written into <iphone-dir>, replacing what is there.
        `fw prepare` keeps the original as iPhone-BuildManifest.plist first.
        """,
    )

    @Argument(
        help: "Extracted iPhone IPSW directory — also where the output is written",
        transform: URL.init(fileURLWithPath:),
    )
    var iPhoneDirectory: URL

    @Argument(
        help: "Extracted cloudOS IPSW directory",
        transform: URL.init(fileURLWithPath:),
    )
    var cloudOSDirectory: URL

    @Flag(name: .shortAndLong, help: "Print which identities were selected")
    var verbose = false

    func run() throws {
        try FirmwareManifest.generate(
            iPhoneDir: iPhoneDirectory,
            cloudOSDir: cloudOSDirectory,
            verbose: true,
        )
    }
}

// MARK: - catalog

struct VPhoneFirmwareCatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "Show the known iOS/iPadOS/tvOS ↔ cloudOS firmware pairings (recommended per build)",
    )

    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false
    @Option(help: ArgumentHelp("Show only this guest device's pairings, e.g. iPad16,1", valueName: "product-type"))
    var device: String?

    func run() throws {
        let report = VPhoneFirmwareCatalog.report
        if json {
            try print(String(decoding: JSONEncoder().encode(report), as: UTF8.self))
            return
        }
        var devices = report.devices
        if let device {
            guard let guest = VPhoneGuestDevice.named(device) else {
                throw ValidationError("vphone runs \(VPhoneGuestDevice.known.map(\.productType).joined(separator: ", ")) guests, not \(device).")
            }
            devices = devices.filter { $0.productType == guest.productType }
        }
        for (index, entry) in devices.enumerated() {
            if index > 0 {
                print("")
            }
            print("Firmware catalog (\(entry.productType), \(entry.name))")
            let os = VPhoneGuestDevice.Family(rawValue: entry.family)?.osName ?? "iOS"
            let width = max(os.count, entry.pairings.map(\.ios.name.count).max() ?? 0)
            let recommendedWidth = max(19, entry.pairings.map(\.recommendedCloudOS.name.count).max() ?? 0)
            let ownColumn = entry.pairings.contains { $0.matchingCloudOS != nil }
            print("\(os.padding(toLength: width, withPad: " ", startingAt: 0))  "
                + "recommended cloudOS".padding(toLength: recommendedWidth, withPad: " ", startingAt: 0)
                + (ownColumn ? "  own cloudOS (research board: root for link)" : ""))
            for e in entry.pairings {
                let ios = e.ios.name.padding(toLength: width, withPad: " ", startingAt: 0)
                if let own = e.matchingCloudOS {
                    print("\(ios)  \(e.recommendedCloudOS.name.padding(toLength: recommendedWidth, withPad: " ", startingAt: 0))  \(own.name)")
                } else {
                    print("\(ios)  \(e.recommendedCloudOS.name)")
                }
            }
        }
    }
}

// MARK: - prepare

struct VPhoneFirmwarePrepareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Download + merge IPSWs into a VM bundle",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(help: "GPU driver bundle from the same cloudOS build, for offline AEA recovery")
    var gpuDriverBundle: String?
    @Option(help: "Directory for downloaded IPSWs, shared by every VM (default: ~/.vphone/ipsws or $VPHONE_ROOT/ipsws)")
    var ipswCache: String?
    @Option(help: "Connections each IPSW downloads over when its server answers range requests; 1 downloads it as one stream")
    var downloadConnections = VPhoneIPSWCache.defaultDownloadConnections
    @Option(help: "iPhone version to resolve to an IPSW") var iphoneVersion: String?
    @Option(help: "iPhone build to resolve to an IPSW") var iphoneBuild: String?
    @Option(help: ArgumentHelp(
        "Guest device: picks the model from an IPSW that covers several (iPad15,5 from the iPad Air IPSW), and the device --list, --iphone-version and --iphone-build look up (default: iPhone17,3)",
        valueName: "product-type",
    ))
    var device: String?
    @Option(help: ArgumentHelp(
        "Full OTA (.aea or .zip) URL or local path for an OTA userland guest, including Apple TV 4K and HomePod mini (default: the catalog's OTA when required)",
        valueName: "ota",
    ))
    var otaSource: String?
    @Option(help: ArgumentHelp(
        "The OTA's AEA key in base64, as AppleDB lists it (default: the catalog's key for that build)",
        valueName: "base64",
    ))
    var otaKey: String?
    @Flag(help: "List downloadable IPSWs and exit") var list = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let readme = VPhoneFirmwareSourceSelection.compatibilityGuide(resources)
        let needsCatalog = list || iphoneVersion != nil || iphoneBuild != nil
        if let device, VPhoneGuestDevice.named(device) == nil {
            throw ValidationError("vphone runs \(VPhoneGuestDevice.known.map(\.productType).joined(separator: ", ")) guests, not \(device).")
        }
        if otaSource != nil || otaKey != nil,
           VPhoneGuestDevice.named(device)?.restoreBase == nil,
           VPhoneGuestDevice.named(device)?.family != .homePod {
            throw ValidationError("--ota-source and --ota-key require an OTA userland device, such as --device AppleTV14,1 or AudioAccessory5,1.")
        }
        guard (1 ... 16).contains(downloadConnections) else {
            throw ValidationError("--download-connections takes 1 to 16, not \(downloadConnections).")
        }
        let chosenDevice = device
        let device = VPhoneFirmwareSourceSelection.lookupDevice(device)
        let urls = needsCatalog ? try VPhoneFirmwareSourceSelection.restoreURLs(forDevice: device) : ""

        if list {
            let code = VPhoneFirmwareMatrixCommandLine.list(
                device: device,
                readmePath: readme,
                downloadURLs: urls,
            )
            if code != 0 {
                throw ExitCode(code)
            }
            return
        }

        var source = iphoneSource
        if iphoneVersion != nil || iphoneBuild != nil {
            guard source == nil else {
                throw ValidationError("Use either --iphone-source or --iphone-version/--iphone-build.")
            }
            source = try VPhoneFirmwareSourceSelection.release(
                device: device,
                version: iphoneVersion,
                build: iphoneBuild,
                readme: readme,
                downloadURLs: urls,
            ).url
        }

        let selected = try VPhoneFirmwareSourceSelection.resolve(iphone: source, cloudos: cloudosSource, device: chosenDevice)
        guard let phone = selected.iphoneSource, let cloud = selected.cloudosSource else {
            throw ValidationError("Specify both --iphone-source and --cloudos-source when running without a terminal.")
        }
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        defer {
            try? VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        }
        try VPhoneFirmwarePreparer.prepare(
            iPhoneSource: phone,
            cloudOSSource: cloud,
            gpuDriverBundle: gpuDriverBundle.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            ipswCacheDirectory: ipswCache.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
            } ?? VPhoneResources.ipswCacheDirectory(),
            downloadConnections: downloadConnections,
            device: chosenDevice,
            otaSource: otaSource,
            otaKey: otaKey,
            bundle: bundle,
            resources: resources,
        )
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
    }
}

// MARK: - patch

struct VPhoneFirmwarePatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch",
        abstract: "Patch the boot chain (native Swift FirmwarePipeline)",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(
        name: .customLong("preset"),
        help: "Patch preset name, or path to a preset plist, to apply. Defaults to the VM's recorded choice, or standard.",
    )
    var preset: String?
    @Flag(name: .shortAndLong, help: "Suppress per-component progress") var quiet = false
    @Flag(help: ArgumentHelp(
        "Refuse unless the selection merges the restore image (the Launchpad helper's root run)",
        visibility: .hidden,
    ))
    var restoreImageOnly = false

    @Option(name: .customLong("work-parent"), help: ArgumentHelp("Private firmware work directory", visibility: .hidden))
    var workParent = "/private/var/tmp"

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        if geteuid() == 0 {
            let workspace = try FirmwarePatchWorkspace(machine: bundle.url, workParent: workParent)
            defer {
                do { try workspace.remove() }
                catch { fputs("warning: firmware work files remain at \(workspace.root.path): \(error)\n", stderr) }
            }
            try patch(directory: workspace.machine, name: name)
            try workspace.publish()
        } else {
            try patch(directory: bundle.url, name: name)
            try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        }
    }

    private func patch(directory: URL, name: String) throws {
        // An explicit --preset wins and is remembered, so `cfw install` and a
        // later re-patch agree without the flag being repeated.
        var selection = VPhonePatchPresetStore.selection(forVM: directory)
        let (resolved, presetFile) = try VPhonePatchPresetStore.resolve(preset ?? selection.presetIdentifier, forVM: directory)
        selection.presetIdentifier = resolved.identifier

        // The restore image patches merge and reseal the system image, which
        // needs root; nothing else here does.
        let mergesRestoreImage = resolved.patchSets.contains { $0.identifier == FirmwareRestoreImagePatchSet.identifier }
            && !selection.blockedPatches.contains(FirmwareRestoreImagePatchSet.cryptexMerge)
        if restoreImageOnly, !mergesRestoreImage {
            throw ValidationError("\(name) is not set to a preset that customises its system before the restore.")
        }
        if mergesRestoreImage, geteuid() != 0 {
            throw ValidationError("The \(selection.presetIdentifier) preset rebuilds the system image, which needs root. Run this command with sudo.")
        }
        if mergesRestoreImage {
            // Never execute the caller's staged seal tool as root. Fetch it
            // again from Apple's CDN into this run's private snapshot.
            let restore = try FirmwarePipeline(vmDirectory: directory).findRestoreDirectory()
            let tools = restore.appendingPathComponent(".tools", isDirectory: true)
            try VPhoneFirmwareSealToolCommand.stage(
                version: try CryptexFilesystemPatcher(buildManiest: Data(), restoreDir: restore).getProductVersion(),
                into: tools,
            )
        }
        // A research board kernelcache is mixed beforehand (`fw kernelcache`),
        // since linking it needs root; root builds it here if need be.
        if geteuid() != 0, !selection.blockedPatches.contains(FirmwareResearchBoardPatchSet.kernelMix),
           let input = try FirmwarePipeline(vmDirectory: directory, variant: .jb).researchBoardKernelcache()
        {
            let state = try KernelCacheMixer(recipes: .locate()).state(for: input)
            if state != .mixed {
                throw ValidationError(KernelCacheMixer.linkInstructions(staged: state == .staged).replacingOccurrences(of: "<vm>", with: name))
            }
        }

        let pipeline = FirmwarePipeline(
            vmDirectory: directory,
            variant: .jb,
            verbose: !quiet,
            noBinpack: true,
            preset: resolved,
            blockedPatches: Set(selection.blockedPatches),
            allowedPatches: Set(selection.allowedPatches),
        )
        let records = try pipeline.patchAll()

        if let plan = pipeline.resolvedPlan {
            if preset != nil {
                try VPhonePatchPresetStore.writePresetFile(presetFile, forVM: directory)
            }
            try VPhonePatchPresetStore.write(selection, forVM: directory)
            try VPhonePatchPresetStore.write(
                VPhoneVirtualMachinePatchPlan(
                    plan: plan,
                    iOSBase: pipeline.baseProductVersion,
                    cloudOS: pipeline.cloudOSProductVersion,
                    notApplicablePatches: pipeline.notApplicablePatches,
                ),
                forVM: directory,
            )
        }

        print("[fw patch] applied \(records.count) CFW patches"
            + " (preset \(selection.presetIdentifier))")
    }
}

// MARK: - patches

struct VPhoneFirmwarePatchesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patches",
        abstract: "List the patch sets, presets and individual patches this bundle can apply",
        discussion: """
        With a VM named, the report also compares the VM's choice with what its
        last `fw patch` planned (PatchPlan.plist) and what is recorded as applied
        in the guest (PatchReceipt.plist), and flags each patch whose wanted state
        has not reached the guest yet. A VM no receipt-writing step has touched
        reports its applied state as unknown.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name, to report what it is set to") var name: String?
    @Option(name: .customLong("preset"), help: "Report against this preset name or preset plist path instead of the VM's choice")
    var preset: String?
    @Flag(name: .customLong("json"), help: "Emit machine-readable output for a UI")
    var json = false

    func run() throws {
        // A VM is optional: without one, this reports what the bundle can do.
        var selection = VPhoneVirtualMachinePatchSelection()
        var vmName: String?
        var machine: VPhonePatchCatalogReport.MachineRecords?
        var directory: URL?
        if let name {
            let resolvedName = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
            let bundle = try lib.library.bundle(named: resolvedName)
            vmName = resolvedName
            directory = bundle.url
            selection = VPhonePatchPresetStore.selection(forVM: bundle.url)
            machine = .read(bundle)
        }
        let active = try VPhonePatchPresetStore.resolve(preset ?? selection.presetIdentifier, forVM: directory).preset
        selection.presetIdentifier = active.identifier

        // A VM's own preset is listed too, so a picker can show what it is set to.
        var presets = VPhonePatchPresetStore.availablePresets()
        if !presets.contains(where: { $0.identifier == active.identifier }) {
            presets.append(active)
        }

        let report = VPhonePatchCatalogReport(
            vmName: vmName,
            selection: selection,
            activePreset: active,
            presets: presets,
            machine: machine,
        )
        if json {
            try print(report.jsonText())
        } else {
            print(report.text(libraryArguments: lib.commandSuffix))
        }
    }
}

// MARK: - set-patches

/// Records what a VM applies, without patching anything.
///
/// This is the write half of `fw patches`: the Launchpad's patch editor reads the
/// JSON, composes the checkmarks onto the preset, and hands the difference back
/// here. Keeping it a verb of its own means the app never writes into a VM bundle
/// itself, and a person can make the same edit from a terminal.
struct VPhoneFirmwareSetPatchesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-patches",
        abstract: "Record which patches a VM applies",
        discussion: """
        Replaces the VM's PatchSelection.plist. Every run writes the whole record:
        --block and --allow name the complete lists, so a run naming neither drops
        the VM's overrides and it follows its preset again.

        Only differences from the preset are stored. An identifier the preset
        already agrees with is dropped, so a later preset revision still reaches a
        VM whose boxes were never touched.

        Nothing is patched here. On a VM that is not installed yet, the next
        `fw patch`, restore and `cfw install` build it with this choice.

        On an installed VM the choice is still recorded, and the command then
        lists each patch whose new state has not reached the guest, by where it
        lands and the step that delivers it:

          AVPBooter                     `fw patch`; read at the next boot. Needs
                                        the restore tree (`--keep-artifacts`).
                                        A machine booting OpenAVB has no
                                        AVPBooter to patch.
          kernelcache                   `cfw update-kernel` (root), which keeps the
                                        guest's data (no restore).
          Guest (system, dyld cache,    `cfw update-environment` (root), which
          Preboot device tree)          applies this choice both on and off.
          LLB, TXM, DeviceTree          only a restore, which erases the guest's data.
          iBSS, iBEC                    used only while restoring.

        `fw patches <vm>` shows the same comparison at any time.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(
        name: .customLong("preset"),
        help: "Preset name, or path to a preset plist, the choice composes onto. Defaults to the VM's recorded preset.",
    )
    var preset: String?
    @Option(
        name: .customLong("block"),
        help: ArgumentHelp("A patch the preset turns on that this VM leaves off", valueName: "patch"),
    )
    var block: [String] = []
    @Option(
        name: .customLong("allow"),
        help: ArgumentHelp("A patch the preset leaves off that this VM turns on", valueName: "patch"),
    )
    var allow: [String] = []

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)

        var selection = VPhonePatchPresetStore.selection(forVM: bundle.url)
        let (resolved, presetFile) = try VPhonePatchPresetStore.resolve(preset ?? selection.presetIdentifier, forVM: bundle.url)
        selection.presetIdentifier = resolved.identifier

        let declarations = FirmwarePatchSetCatalog.allDeclarations
        let declared = Set(declarations.map(\.identifier))
        // A typo would otherwise write a list that turns nothing on or off.
        let unknown = Set(block + allow).subtracting(declared).sorted()
        guard unknown.isEmpty else {
            throw ValidationError(
                "No patch declares \(unknown.joined(separator: ", ")). Run `fw patches` for the identifiers.",
            )
        }
        let contradictory = Set(block).intersection(allow).sorted()
        guard contradictory.isEmpty else {
            throw ValidationError(
                "\(contradictory.joined(separator: ", ")) cannot be both blocked and allowed.",
            )
        }

        // Only differences reach the plist, whatever the caller passed.
        let included = VPhonePatchCatalogReport.patchesInPreset(resolved)
        selection.blockedPatches = Set(block).intersection(included).sorted()
        selection.allowedPatches = Set(allow).subtracting(included).sorted()

        let essential = Set(declarations.filter(\.bootEssential).map(\.identifier))
        let essentialOff = Set(selection.blockedPatches).intersection(essential).sorted()
        if !essentialOff.isEmpty {
            FileHandle.standardError.write(Data(
                ("warning: \(essentialOff.count) boot-essential patch(es) are off — the VM may not boot: "
                    + "\(essentialOff.joined(separator: ", "))\n").utf8,
            ))
        }

        if preset != nil {
            try VPhonePatchPresetStore.writePresetFile(presetFile, forVM: bundle.url)
        }
        try VPhonePatchPresetStore.write(selection, forVM: bundle.url)
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        print("[fw set-patches] \(name): preset \(selection.presetIdentifier)"
            + ", \(selection.blockedPatches.count) off, \(selection.allowedPatches.count) on")
        reportPending(selection: selection, preset: resolved, bundle: bundle, name: name)
    }

    /// On an installed VM, a new choice reaches the guest only through the
    /// step that owns each part, so say which patches still differ from what
    /// the guest has (or, with no receipt, from the last plan) and how each
    /// gets there. A VM that is not installed yet needs no such note: the
    /// steps that build it read this choice.
    private func reportPending(
        selection: VPhoneVirtualMachinePatchSelection,
        preset: VPhonePatchPreset,
        bundle: VPhoneBundle,
        name: String,
    ) {
        let machine = VPhonePatchCatalogReport.MachineRecords.read(bundle)
        guard machine.installed == true else { return }
        let report = VPhonePatchCatalogReport(
            vmName: name,
            selection: selection,
            activePreset: preset,
            presets: [],
            machine: machine,
        )
        guard let states = report.states() else { return }
        let pending = states.filter { $0.isPending == true }
        if pending.isEmpty {
            if states.allSatisfy({ $0.isPending == nil }) {
                print("[fw set-patches] \(name) is installed, but neither a plan nor a receipt records"
                    + " what its guest has, so what this change still needs is unknown.")
            } else {
                print("[fw set-patches] \(name) is installed and already matches this choice.")
            }
            return
        }
        print("[fw set-patches] \(name) is installed. \(pending.count) patch(es) differ from what its guest has:")
        for line in VPhonePatchCatalogReport.pendingSteps(
            pending,
            vmName: name,
            libraryArguments: lib.commandSuffix,
        ) {
            print(line)
        }
    }
}

// MARK: - export-preset

/// Writes a preset that is a VM's choice, or a choice not yet made into a VM,
/// with its overrides folded into the selection: applied with none of its own,
/// it resolves to the same patches.
struct VPhoneFirmwareExportPresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-preset",
        abstract: "Write a preset plist from a VM's patch choice, or from a preset and overrides",
        discussion: """
        With a VM named and no other option, its recorded preset and overrides
        are exported. Otherwise --preset (default the VM's, or standard),
        --block and --allow name the whole choice, as for fw set-patches; with
        a VM named, a preset of its own resolves.

        The new preset keeps the original's patch sets, parameters and summary.
        Its identifier is the output file's name without .plist, and its title
        the original's with ", modified". Pass the file to --preset to use it.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name, to export its choice") var name: String?
    @Option(name: .customLong("preset"), help: "Preset name or preset plist path the choice composes onto")
    var preset: String?
    @Option(name: .customLong("block"), help: ArgumentHelp("A patch the preset turns on, turned off", valueName: "patch"))
    var block: [String] = []
    @Option(name: .customLong("allow"), help: ArgumentHelp("A patch the preset leaves off, turned on", valueName: "patch"))
    var allow: [String] = []
    @Option(name: [.customShort("o"), .customLong("output")], help: "The preset plist to write")
    var output: String

    func run() throws {
        var directory: URL?
        var record = VPhoneVirtualMachinePatchSelection()
        if let name {
            let bundle = try lib.library.bundle(named: VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library))
            directory = bundle.url
            record = VPhonePatchPresetStore.selection(forVM: bundle.url)
        }
        let original: VPhonePatchPreset
        let blocked: Set<String>
        let allowed: Set<String>
        if name != nil, preset == nil, block.isEmpty, allow.isEmpty {
            original = try VPhonePatchPresetStore.resolve(record.presetIdentifier, forVM: directory).preset
            blocked = Set(record.blockedPatches)
            allowed = Set(record.allowedPatches)
        } else {
            // As fw set-patches: the options name the whole choice, and a VM
            // named with them is where a preset of its own resolves.
            original = try VPhonePatchPresetStore.resolve(preset ?? record.presetIdentifier, forVM: directory).preset
            blocked = Set(block)
            allowed = Set(allow)
            // A typo would otherwise export a selection naming nothing.
            let unknown = blocked.union(allowed).subtracting(FirmwarePatchSetCatalog.allDeclarations.map(\.identifier)).sorted()
            guard unknown.isEmpty else {
                throw ValidationError("No patch declares \(unknown.joined(separator: ", ")). Run `fw patches` for the identifiers.")
            }
            let contradictory = blocked.intersection(allowed).sorted()
            guard contradictory.isEmpty else {
                throw ValidationError("\(contradictory.joined(separator: ", ")) cannot be both blocked and allowed.")
            }
        }

        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        let identifier = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "plist", !identifier.isEmpty, !VPhonePatchPresetStore.isPresetFile(identifier) else {
            throw ValidationError("The output is a .plist file whose name, without .plist, is the preset's identifier.")
        }
        guard !VPhonePatchPresetStore.isShipped(identifier) else {
            throw ValidationError("'\(identifier)' is a shipped preset's identifier; name the file something else.")
        }

        var exported = original
        exported.identifier = identifier
        exported.title = "\(original.title), modified"
        // As VPhonePatchPlan.resolve composes a VM's overrides.
        exported.selection = original.selection.allowing(allowed).blocking(blocked)
        try exported.encodedPlist().write(to: url, options: .atomic)
        print("[fw export-preset] wrote \(identifier) to \(url.path) (from \(original.identifier), \(blocked.count) off, \(allowed.count) on)")
    }
}

// MARK: - Library Arguments

extension VPhoneLibraryOption {
    /// ` --library-root <root>` when one was given, for a command printed back
    /// to the user, so it finds the same VM.
    var commandSuffix: String {
        guard let libraryRoot else { return "" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-~+@%:,="))
        let quoted = libraryRoot.unicodeScalars.allSatisfy(safe.contains)
            ? libraryRoot
            : "'" + libraryRoot.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return " --library-root \(quoted)"
    }
}

// MARK: - kernelcache

/// Builds the kernelcache mix of a VM on a cloudOS without vphone600
/// components, in two steps: native extraction stages the volume as the user
/// and linking runs kmutil as root. `fw patch`
/// then takes the mix from the cache. See KernelCacheMixer.
struct VPhoneFirmwareKernelcacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kernelcache",
        abstract: "Build a research board VM's kernelcache mix: stage it natively as yourself, link it with sudo",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(help: ArgumentHelp(
        "Only link a staged volume; never stage (the Launchpad helper's root run)",
        visibility: .hidden,
    ))
    var linkOnly = false
    @Option(help: ArgumentHelp("Legacy compatibility option; native extraction ignores this path", valueName: "path", visibility: .hidden))
    var ipsw: String?
    @Option(name: .customLong("work-parent"), help: ArgumentHelp("Private kernelcache work directory", visibility: .hidden))
    var workParent = "/private/var/tmp"

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let workspace = try geteuid() == 0 ? FirmwarePatchWorkspace(machine: bundle.url, workParent: workParent) : nil
        defer { try? workspace?.remove() }
        guard let input = try FirmwarePipeline(vmDirectory: workspace?.machine ?? bundle.url, variant: .jb).researchBoardKernelcache() else {
            print("[=] \(name)'s cloudOS has vphone600 components; its kernelcache needs no mix.")
            return
        }
        let mixer = try KernelCacheMixer(recipes: .locate())
        let state = try mixer.state(for: input)
        if state == .mixed {
            print("[+] The kernelcache mix is ready; `fw patch` takes it from the cache.")
            return
        }
        if geteuid() == 0 {
            if state == .missing {
                guard !linkOnly else {
                    throw ValidationError("\(name)'s kernelcache mix is not staged. Stage it first, as yourself: vphone-cli fw kernelcache \(name)")
                }
                try mixer.stage(input, ipsw: ipsw)
            }
            try mixer.link(input)
            print("[+] The kernelcache mix is ready; `fw patch` takes it from the cache.")
            return
        }
        // Another Mac's kmutil (VPHONE_KMUTIL_SSH) links as root there.
        let remote = try mixer.linksRemotely(input)
        guard !linkOnly || remote else {
            throw ValidationError("Linking the kernelcache mix needs root. Run this command with sudo.")
        }
        if state == .missing {
            guard !linkOnly else {
                throw ValidationError("\(name)'s kernelcache mix is not staged. Stage it first: vphone-cli fw kernelcache \(name)")
            }
            try mixer.stage(input, ipsw: ipsw)
        }
        guard remote else {
            print("[+] Staged. Link it with: sudo vphone-cli fw kernelcache \(name)")
            return
        }
        try mixer.link(input)
        print("[+] The kernelcache mix is ready; `fw patch` takes it from the cache.")
    }
}
