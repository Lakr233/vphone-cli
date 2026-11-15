// FirmwarePipeline.swift — Orchestrates full boot-chain firmware patching.
//
// Historical note: this file replaces the old Python firmware patcher implementation.
//
// Pipeline order: AVPBooter → iBSS → iBEC → LLB → TXM → Kernel → DeviceTree
//
// Internal variant selection:
//   .regular — base patchers only
//   .dev     — TXMDevPatcher instead of TXMPatcher
//   .jb      — TXMDevPatcher + IBootCustomFirmwarePatcher (iBSS) + KernelCustomFirmwarePatcher
//              + former EXP kernel and DeviceTree patches. The case keeps its old
//              spelling because its raw value is recorded in every VM's RestoreInfo.
//   .exp     — historical internal variant, currently equivalent to CFW for
//              the boot-chain patcher catalogue. Only CFW is public.
//
// The component catalogue lives in FirmwarePipelineComponents.swift and the
// Restore-directory/firmware-file lookup in FirmwarePipelineDiscovery.swift.

import Darwin
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

/// Orchestrates firmware patching for all boot-chain components.
///
/// The pipeline discovers firmware files inside the VM directory (mirroring
/// `find_restore_dir` + `find_file` in the Python source), loads each file,
/// delegates to the appropriate ``Patcher``, and writes the patched data back.
///
/// The default loader mirrors the Python flow: it loads IM4P containers when
/// present, patches the extracted payload, and re-packages them on save.
public final class FirmwarePipeline {
    // MARK: - Variant

    public enum Variant: String, Sendable {
        case regular
        case dev
        case jb
        case exp
    }

    // MARK: - Firmware Loader (pluggable IM4P support)

    /// Abstraction over IM4P vs raw firmware loading.
    ///
    /// Provide a conforming type to override the default IM4P/raw handling.
    public protocol FirmwareLoader {
        /// Load firmware from `url`, returning the mutable payload data.
        func load(from url: URL) throws -> Data
        /// Save patched `data` back to `url`, repackaging as needed.
        func save(_ data: Data, to url: URL) throws
    }

    /// Default loader: transparently handles IM4P containers and raw payloads.
    public struct ContainerFirmwareLoader: FirmwareLoader {
        public init() {}
        public func load(from url: URL) throws -> Data {
            try IM4PHandler.load(contentsOf: url).payload
        }

        public func save(_ data: Data, to url: URL) throws {
            let original = try IM4PHandler.load(contentsOf: url).im4p
            try IM4PHandler.save(patchedData: data, originalIM4P: original, to: url)
        }
    }

    // MARK: - Component Descriptor

    /// Describes a single firmware component in the pipeline.
    struct ComponentDescriptor {
        let name: String
        /// If true, search paths are relative to the Restore directory.
        /// If false, relative to the VM directory root.
        let inRestoreDir: Bool
        /// Glob patterns used to locate the file (tried in order).
        let searchPatterns: [String]
        /// Factories that create patchers to run in sequence for the loaded data.
        ///
        /// Throwing, because a loaded `.vphonepatchset` builds its patcher here: a
        /// set that declares a patch for this component but builds no patcher for
        /// it has to say so rather than leave the component untouched.
        let patcherFactories: [(Data, Bool) throws -> any Patcher]

        /// Whether the pipeline keeps this component's untouched bytes aside and
        /// re-patches those on every run — see FirmwarePipelineOriginals.swift.
        ///
        /// False for the two restore image components, and only for them. `Filesystem`
        /// and `Manifest` both name `BuildManifest.plist`, but neither is a patcher
        /// over that one file: `CryptexFilesystemPatcher` rewrites cryptex images
        /// across the restore tree, and `ManifestHashPatcher` rewrites hashes to
        /// match files other steps produced. Putting the manifest back on its own
        /// would describe a tree that no longer exists, so they keep the old
        /// in-place behaviour and opt out here.
        var restorable: Bool = true

        /// A container standing in for the shipped file, and the record of the
        /// swap: the patchers run over its payload and are saved into it. The
        /// research board's kernelcache is replaced by its mix this way
        /// (KernelCacheMixer), whose container carries kmutil's layout
        /// properties rather than the shipped kernel's.
        var replacement: (() throws -> (container: Data, record: PatchRecord))? = nil

        /// The same descriptor with more patchers appended after the existing ones.
        func appending(_ factories: [(Data, Bool) throws -> any Patcher]) -> ComponentDescriptor {
            guard !factories.isEmpty else { return self }
            return ComponentDescriptor(
                name: name,
                inRestoreDir: inRestoreDir,
                searchPatterns: searchPatterns,
                patcherFactories: patcherFactories + factories,
                restorable: restorable,
                replacement: replacement,
            )
        }
    }

    // MARK: - Properties

    let vmDirectory: URL
    let variant: Variant
    let verbose: Bool
    let noBinpack: Bool
    let loader: any FirmwareLoader

    /// The preset to resolve, or nil to apply every patch the variant's patchers
    /// find. Nil is what the tests use, and what keeps a directly built pipeline
    /// behaving as it did before presets existed.
    let preset: VPhonePatchPreset?
    /// The manifests `preset` resolves against.
    let patchSets: [VPhonePatchSetManifest]
    /// Per-VM patches to turn off on top of the preset.
    let blockedPatches: Set<String>
    /// Per-VM patches to turn on that the preset leaves off.
    let allowedPatches: Set<String>

    /// The `.vphonepatchset` bundles `resolvePlan` opened for this run. Empty for a
    /// preset that names only bundled sets, which is every shipped preset.
    let loadedPatchSets = FirmwareExternalPatchSets()

    /// The plan `patchAll()` resolved, once the OS versions were known. Nil until
    /// then, and nil for the whole run when no preset was given.
    public private(set) var resolvedPlan: VPhonePatchPlan?

    /// The iPhone base `ProductVersion` `patchAll()` read, if it found one.
    public private(set) var baseProductVersion: VPhoneVersion?

    /// The cloudOS `ProductVersion` `patchAll()` read, if it found one.
    public private(set) var cloudOSProductVersion: VPhoneVersion?

    public private(set) var notApplicablePatches: Set<String> = []

    // MARK: - Init

    public init(
        vmDirectory: URL,
        variant: Variant = .regular,
        verbose: Bool = true,
        noBinpack: Bool = false,
        preset: VPhonePatchPreset? = nil,
        patchSets: [VPhonePatchSetManifest] = FirmwarePatchSetCatalog.bundled,
        blockedPatches: Set<String> = [],
        allowedPatches: Set<String> = [],
        loader: (any FirmwareLoader)? = nil,
    ) {
        self.vmDirectory = vmDirectory
        self.variant = variant
        self.verbose = verbose
        self.noBinpack = noBinpack
        self.preset = preset
        self.patchSets = patchSets
        self.blockedPatches = blockedPatches
        self.allowedPatches = allowedPatches
        self.loader = loader ?? ContainerFirmwareLoader()
        VPhonePatchLog.write = { VPhoneConsole.shared.line($0) }
    }

    // MARK: - Pipeline Execution

    /// Run the full patching pipeline.
    ///
    /// Returns combined ``PatchRecord`` arrays from every component, in order.
    /// Throws on the first component that fails to patch.
    public func patchAll() throws -> [PatchRecord] {
        let restoreDir = try findRestoreDirectory()

        log("[*] VM directory:      \(vmDirectory.path)")
        log("[*] Restore directory: \(restoreDir.path)")

        // Detect the iPhone base iOS version (from the pre-hybrid manifest that
        // fw_prepare preserves — the live BuildManifest.plist reads the cloudOS
        // version, not the base). iOS 18 bases need the skywalk-netagent boot-arg.
        let baseVersion = VPhoneVersion(Self.readBaseProductVersion(restoreDir))
        baseProductVersion = baseVersion
        log("[*] iPhone base iOS:   \(baseVersion?.description ?? "unknown")")

        // Frida Stalker kernel patches only apply on cloudOS 26.4+ (where the shapes
        // were validated); older kernels are left untouched. The Frida deb install is
        // separate and version-independent.
        let cloudOSVersion = VPhoneVersion(Self.readCloudOSProductVersion(restoreDir))
        cloudOSProductVersion = cloudOSVersion
        log("[*] cloudOS kernel:    \(cloudOSVersion?.description ?? "unknown")")
        if VPhoneBootROM.kind(ofMachineAt: vmDirectory) == .openAVB {
            log("[*] Boot ROM:          OpenAVB, which needs no ROM patch")
        }

        // The preset resolves here rather than in init: its version gates need the
        // two ProductVersions that were just read, and a conflict or a misnamed
        // patch must stop the run before a single byte is written.
        let plan = try resolvePlan(iOSBase: baseVersion, cloudOS: cloudOSVersion)
        // fw prepare refuses the pairing too; this catches a preset changed since.
        if let plan,
           let family = VPhoneGuestDevice.Family(rawValue: Self.guestFamily(restoreDir: restoreDir)),
           let refusal = FirmwareRestoreImagePatchSet.cloudOSRefusal(
               plan: plan, family: family, iOSBase: baseVersion, cloudOS: cloudOSVersion,
           ) {
            throw PatcherError.patchVerificationFailed(refusal)
        }
        try resolveFirmwareApplicability(
            restoreDir: restoreDir,
            iOSBase: baseVersion,
            cloudOS: cloudOSVersion,
            plan: plan,
        )
        resolvedPlan = plan
        let gate = plan.map { VPhonePatchGate(plan: $0) } ?? .unrestricted

        let components = try buildComponentList(
            restoreDir: restoreDir,
            iOSBase: baseVersion,
            plan: plan,
            gate: gate,
        )
        log("[*] Patching \(components.count) boot-chain components ...")

        let allRecords = try patchComponents(components, restoreDir: restoreDir, plan: plan)

        log("\n\(String(repeating: "=", count: 60))")
        log("  All \(components.count) components processed successfully! (\(allRecords.count) total patches)")
        log(String(repeating: "=", count: 60))

        return allRecords
    }

    /// Whether the restore tree boots the research board's device tree, which
    /// `FirmwareManifest` takes when the cloudOS has no vphone600ap.
    public static func researchBoardStandsIn(restoreDir: URL) -> Bool {
        (try? manifestComponentPath("RestoreDeviceTree", in: restoreDir))?.contains(".vresearch101") ?? false
    }

    func resolveFirmwareApplicability(
        restoreDir: URL,
        iOSBase: VPhoneVersion?,
        cloudOS: VPhoneVersion?,
        plan: VPhonePatchPlan?,
    ) throws {
        notApplicablePatches = []
        // The research board patches convert what a cloudOS without vphone600
        // components supplies; any other restore tree has nothing for them.
        if !Self.researchBoardStandsIn(restoreDir: restoreDir) {
            let researchBoard = FirmwareResearchBoardPatchSet.manifest.patches.map(\.identifier)
            notApplicablePatches.formUnion(researchBoard.filter { plan?.isEnabled($0) ?? true })
        }
        let sealPatch = RestoreRamDiskSealPatcher.patchIdentifier
        let sealSelected = plan?.isEnabled(sealPatch)
            ?? (iOSBase?.major == 27 && cloudOS?.major == 26 && cloudOS?.minor == 4)
        guard sealSelected else { return }
        let hashType = try RestoreRamDiskSealPatcher.systemVolumeHashType(in: restoreDir)
        if hashType == RestoreRamDiskSealPatcher.sha256Type {
            notApplicablePatches.insert(sealPatch)
            log("[=] \(sealPatch): SystemVolume root hash uses SHA-256; restore tools stay pristine")
        }
    }

    /// Patch a kernelcache file in place with this VM's selection, without a
    /// restore tree. For `cfw update-kernel`: the pristine kernelcache is kept
    /// in `FirmwareOriginals`, and only the Preboot copy needs replacing, so the
    /// full restore-tree pipeline is not run — just the kernelcache component's
    /// patchers, resolved and gated exactly as `patchAll` would, over the one
    /// file. `url` is a writable copy of the pristine kernelcache (a bare IM4P);
    /// it is left patched and re-wrapped in its own container. The versions come
    /// from the plan `fw patch` recorded, since the live BuildManifest reads the
    /// cloudOS version, not the iOS base. Returns whether any patch applied.
    @discardableResult
    public func patchKernelcacheFile(at url: URL, iOSBase: VPhoneVersion?, cloudOS: VPhoneVersion?) throws -> Bool {
        baseProductVersion = iOSBase
        cloudOSProductVersion = cloudOS
        let plan = try resolvePlan(iOSBase: iOSBase, cloudOS: cloudOS)
        resolvedPlan = plan
        let gate = plan.map { VPhonePatchGate(plan: $0) } ?? .unrestricted
        // restoreDir is unused when building the kernelcache component's
        // patchers (they take the gate and versions, not files), so the VM
        // directory stands in for the parameter.
        let components = try buildComponentList(restoreDir: vmDirectory, iOSBase: iOSBase, plan: plan, gate: gate)
        guard let kernel = components.first(where: { $0.name == "kernelcache" }) else {
            throw PatcherError.invalidFormat("this build has no kernelcache component to patch")
        }
        guard !kernel.patcherFactories.isEmpty else {
            // The preset turns every kernel patch off: the pristine kernelcache
            // is already the wanted one.
            return false
        }
        let payload = try loader.load(from: url)
        let (patched, records) = try patchData(
            payload,
            componentName: "kernelcache",
            patcherFactories: kernel.patcherFactories,
            expectsPatches: expectsPatches(for: "kernelcache", plan: plan),
        )
        guard !records.isEmpty else { return false }
        try loader.save(patched, to: url)
        return true
    }

    /// Patch every component in order, against the files under `restoreDir` and the
    /// VM directory root.
    ///
    /// Each component is patched from the bytes the firmware shipped with rather
    /// than from whatever the last run left behind, so running this twice produces
    /// the same files as running it once — see FirmwarePipelineOriginals.swift for
    /// why that is not how it used to work.
    ///
    /// Split out of ``patchAll()`` so a test can drive the loop, and with it the
    /// originals behaviour, over a component whose patcher it controls. The real
    /// boot chain needs firmware fixtures that are not in the repository.
    func patchComponents(
        _ components: [ComponentDescriptor],
        restoreDir: URL,
        plan: VPhonePatchPlan?,
    ) throws -> [PatchRecord] {
        var allRecords: [PatchRecord] = []

        for component in components {
            let baseDir = component.inRestoreDir ? restoreDir : vmDirectory
            // A plan without the boot chain, kernel and TXM sets (the `minimal`
            // preset) leaves those components with no factories, and the pass
            // below puts back what an earlier preset patched: a stock boot chain
            // is what the restore image patches expect.
            let keepsOriginal = component.restorable

            guard !component.patcherFactories.isEmpty || component.replacement != nil else {
                log("  [=] \(component.name): no patches for \(variant.rawValue)")
                // The preset dropped this component's whole patch set. If an earlier
                // run patched it, the file on disk is now carrying patches nothing
                // selects any more, so it goes back to how the restore left it.
                if keepsOriginal,
                   let fileURL = try? findFile(
                       in: baseDir,
                       patterns: component.searchPatterns,
                       label: component.name,
                   ),
                   try restorePristine(to: fileURL)
                {
                    log("  [+] \(component.name): unpatched image restored")
                }
                continue
            }
            let fileURL = try findFile(in: baseDir, patterns: component.searchPatterns, label: component.name)

            log("\n\(String(repeating: "=", count: 60))")
            log("  \(component.name): \(fileURL.path)")
            log(String(repeating: "=", count: 60))

            // Load — from the copy of the shipped file, not from the bytes the last
            // run wrote. The first run is the one that puts it aside.
            var sourceURL = fileURL
            var stashedNow = false
            if keepsOriginal {
                (sourceURL, stashedNow) = try pristineInput(for: fileURL)
                if sourceURL != fileURL {
                    log(stashedNow
                        ? "  original: kept in \(Self.originalsDirectoryName)/"
                        : "  original: re-patching the copy in \(Self.originalsDirectoryName)/")
                }
            }
            var rawData = try loader.load(from: sourceURL)
            // The stand-in goes where the shipped file was, so `save` below
            // repackages into its container.
            var replacementRecord: PatchRecord?
            if let replacement = component.replacement {
                let (container, record) = try replacement()
                try container.write(to: fileURL)
                rawData = try loader.load(from: fileURL)
                replacementRecord = record
                log("  replaced by the stand-in for \(record.patchID)")
            }
            log("  format: \(rawData.count) bytes")

            let currentData: Data
            let componentRecords: [PatchRecord]
            do {
                (currentData, componentRecords) = try patchData(
                    rawData,
                    componentName: component.name,
                    patcherFactories: component.patcherFactories,
                    expectsPatches: expectsPatches(for: component.name, plan: plan),
                )
            } catch {
                // A copy made this run is the one thing here that was never proved
                // pristine, so it does not get to become the next run's baseline.
                guard stashedNow else { throw error }
                discardStash(for: fileURL)
                throw staleFirmwareError(component: component.name, underlying: error)
            }

            if let replacementRecord {
                // Already in place; the patchers' result, if any, is saved into it.
                if !componentRecords.isEmpty {
                    try loader.save(currentData, to: fileURL)
                }
                log("  [+] saved")
                allRecords.append(replacementRecord)
                allRecords.append(contentsOf: componentRecords)
                continue
            }

            if componentRecords.isEmpty {
                // Every patch for this component is off. Re-sealing an unmodified
                // payload would rewrite a signed image for no reason — but if an
                // earlier run did patch it, the file on disk still has to go back.
                if keepsOriginal, try restorePristine(to: fileURL) {
                    log("  [+] every patch is off, unpatched image restored")
                } else {
                    log("  [=] unchanged, not rewritten")
                }
            } else {
                // `save` repackages the container it finds at the destination, so
                // the shipped one goes back first. Otherwise the second run would
                // wrap its payload in the container the first run wrote, and two
                // runs of the same plan would not produce the same file.
                if keepsOriginal {
                    try restorePristine(to: fileURL)
                }
                try loader.save(currentData, to: fileURL)
                log("  [+] saved")
            }

            allRecords.append(contentsOf: componentRecords)
        }

        return allRecords
    }

    func patchData(
        _ rawData: Data,
        componentName: String,
        patcherFactories: [(Data, Bool) throws -> any Patcher],
        expectsPatches: Bool = true,
    ) throws -> (Data, [PatchRecord]) {
        var currentData = rawData
        var componentRecords: [PatchRecord] = []

        for makePatcher in patcherFactories {
            let patcher = try makePatcher(currentData, verbose)
            let records = try patcher.findAll()

            guard !records.isEmpty else {
                // A patcher that found nothing is a failure — unless the preset
                // turned this component's patches off, in which case finding
                // nothing is the whole point.
                guard !expectsPatches else {
                    throw PatcherError.patchSiteNotFound("\(componentName): no patches found")
                }
                log("  [=] \(componentName): every patch is off in this preset")
                continue
            }

            let count = try patcher.apply()
            log("  [+] \(count) \(componentName) patches applied")

            componentRecords.append(contentsOf: records)
            currentData = extractPatchedData(from: patcher, fallback: currentData, records: records)
        }

        return (currentData, componentRecords)
    }

    // MARK: - Preset Resolution

    /// Resolve the preset against the versions just read, and report what it did.
    ///
    /// Returns nil when no preset was given, which leaves every patcher
    /// unrestricted.
    ///
    /// Every `.vphonepatchset` the preset names is opened here, before the plan is
    /// resolved and so before a byte is written. Opening one means reading and
    /// checking its manifest, then mapping its executable — in that order, so a set
    /// that conflicts with another or needs a newer PatchKit is refused without its
    /// code ever running.
    ///
    /// Public so the tests and `vm create`'s template key can resolve a preset,
    /// external sets included, without a restore tree to patch.
    public func resolvePlan(iOSBase: VPhoneVersion?, cloudOS: VPhoneVersion?) throws -> VPhonePatchPlan? {
        guard let preset else { return nil }
        try Self.validateExecutionPrivilege(preset: preset, effectiveUID: geteuid())

        var available = patchSets
        for reference in preset.patchSets {
            guard case let .external(identifier, path) = reference else { continue }
            let set = try VPhonePatchSetBundle.inspect(at: URL(fileURLWithPath: path))
            try set.validate(expecting: identifier)
            try loadedPatchSets.add(set)
            available.append(set.manifest)
            log("[*] External set:      \(set.manifest.identifier) \(set.manifest.version)"
                + " (\(set.manifest.patches.count) patches) from \(set.url.path)")
        }

        let plan = try VPhonePatchPlan.resolve(
            preset: preset,
            patchSets: available,
            iOSBase: iOSBase,
            cloudOS: cloudOS,
            blocked: blockedPatches,
            allowed: allowedPatches,
        )

        log("[*] Patch preset:      \(preset.identifier)"
            + "  (\(plan.patchSets.count) sets, \(plan.enabled.count) patches on)")
        if !plan.skippedByVersion.isEmpty {
            log("[*] Not applicable:    \(plan.skippedByVersion.count) patches for other OS versions")
        }
        let blocked: [String] = plan.declarations
            .filter { !plan.enabled.contains($0.identifier) && !plan.skippedByVersion.contains($0.identifier) }
            .map(\.identifier)
            .sorted()
        if !blocked.isEmpty {
            log("[*] Turned off:        \(blocked.joined(separator: ", "))")
        }
        if !plan.droppedBootEssentials.isEmpty {
            // Allowed — an external set may be replacing them — but never quiet.
            log("[!] Boot-essential patches are off: "
                + plan.droppedBootEssentials.joined(separator: ", "))
        }
        return plan
    }

    /// A user preset is data, but an external patch set loads native code.
    /// Privileged runs must reject it before inspecting or loading any bundle.
    static func validateExecutionPrivilege(preset: VPhonePatchPreset, effectiveUID: uid_t) throws {
        guard effectiveUID == 0 else { return }
        for reference in preset.patchSets {
            if case .external = reference {
                throw PatcherError.invalidFormat("External patch sets cannot run as root. Use only bundled patch sets for privileged firmware operations.")
            }
        }
    }

    /// Whether `componentName` should still produce at least one patch record.
    private func expectsPatches(for componentName: String, plan: VPhonePatchPlan?) -> Bool {
        guard let plan else { return true }
        guard let component = VPhoneFirmwareComponent(rawValue: componentName) else { return true }
        return plan.hasEnabledPatches(target: .firmware(component))
    }

    // MARK: - Data Extraction

    /// Extract the patched data from a patcher's internal buffer.
    ///
    /// Every patcher in this project conforms to ``BufferedPatcher`` and hands its
    /// bytes back through it. Asking through the protocol rather than downcasting
    /// to each known type is also the only way a patcher from a loaded
    /// `.vphonepatchset` can contribute anything: the pipeline has never heard of
    /// its type, and bytes it could not read would be silently dropped.
    func extractPatchedData(from patcher: any Patcher, fallback: Data, records: [PatchRecord]) -> Data {
        if let buffered = patcher as? any BufferedPatcher {
            return buffered.patchedData
        }

        // Fallback: apply records manually to a copy of the original data.
        var data = fallback
        for record in records {
            let range = record.fileOffset ..< record.fileOffset + record.patchedBytes.count
            data.replaceSubrange(range, with: record.patchedBytes)
        }
        return data
    }

    // MARK: - Logging

    func log(_ message: String) {
        if verbose {
            VPhoneConsole.shared.line(message)
        }
    }
}
