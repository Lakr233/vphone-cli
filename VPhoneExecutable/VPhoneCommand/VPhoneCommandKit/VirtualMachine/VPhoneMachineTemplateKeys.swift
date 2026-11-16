import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit

/// Resolves template keys: for a create, from the requested options and the
/// IPSWs before anything is restored; for a machine, from its own records.
/// Both go through ``key(device:ios:cloudOS:preset:blocked:allowed:diskSizeGB:series:slimming:)``,
/// so the same machine gets the same key either way.
///
/// Lives here rather than in VPhoneCoreKit because the boot-chain part needs
/// the patch catalog and the plan resolver (`FirmwarePatcher`).
public enum VPhoneMachineTemplateKeys {
    /// The series of this `vphone-cli`'s bundle, or `unbundled` for a build
    /// outside `VPhone.bundle`.
    public static var currentSeries: String {
        VPhoneBundleVersion.current().flatMap(VPhoneMachineTemplateKey.series(ofBundleVersion:)) ?? "unbundled"
    }

    // MARK: Boot chain

    /// The patches of a plan that only a restore (or `fw patch`, or
    /// `cfw update-kernel`) can change: every patch the catalog declares on a
    /// boot-chain component, and every patch it does not know at all (one
    /// from an external set, counted to be safe). Guest patches are left out:
    /// `cfw update-environment` applies them to a clone either way.
    static func bootChainPatches(_ enabled: some Sequence<String>) -> [String] {
        let targets = Dictionary(
            FirmwarePatchSetCatalog.allDeclarations.map { ($0.identifier, $0.target) },
            uniquingKeysWith: { first, _ in first },
        )
        return enabled.filter { identifier in
            guard let target = targets[identifier] else { return true }
            if case .firmware = target {
                return true
            }
            return false
        }.sorted()
    }

    /// The patches a key digests. A shipped preset's identifier fixes its
    /// guest patches within a series, so the boot chain is enough. Any other
    /// preset, a user's or a preset file's, can change them under the same
    /// identifier, and a clone keeps its template's guest and preset copy, so
    /// every patch counts.
    static func keyedPatches(_ enabled: some Sequence<String>, preset identifier: String) -> [String] {
        VPhonePatchPresetStore.isShipped(identifier) ? bootChainPatches(enabled) : Set(enabled).sorted()
    }

    /// Resolves the preset against the two versions the way `fw patch` will.
    static func plan(
        preset: VPhonePatchPreset,
        iOSVersion: String,
        cloudOSVersion: String,
        blocked: [String] = [],
        allowed: [String] = [],
    ) throws -> VPhonePatchPlan {
        let pipeline = FirmwarePipeline(
            vmDirectory: FileManager.default.temporaryDirectory,
            variant: .jb,
            verbose: false,
            preset: preset,
            blockedPatches: Set(blocked),
            allowedPatches: Set(allowed),
        )
        guard let plan = try pipeline.resolvePlan(iOSBase: VPhoneVersion(iOSVersion), cloudOS: VPhoneVersion(cloudOSVersion)) else {
            throw ValidationError("Patch preset '\(preset.identifier)' did not resolve.")
        }
        return plan
    }

    public static func key(
        device: String,
        ios: VPhoneRestoreInfo.OSVersion,
        cloudOS: VPhoneRestoreInfo.OSVersion,
        preset: VPhonePatchPreset,
        blocked: [String] = [],
        allowed: [String] = [],
        diskSizeGB: UInt64,
        series: String = currentSeries,
        slimming: VPhoneMachineTemplateSlimming = .none,
    ) throws -> VPhoneMachineTemplateKey {
        let plan = try plan(
            preset: preset,
            iOSVersion: ios.version,
            cloudOSVersion: cloudOS.version,
            blocked: blocked,
            allowed: allowed,
        )
        // The slimming this iOS can take: `trimmed` is `none` where vphoned
        // has no service list (VPhoneMachineTemplateSlimming.fitted).
        let fitted = try self.fitted(slimming, toIOSVersion: ios.version)
        return VPhoneMachineTemplateKey(
            device: device,
            iOSVersion: ios.version,
            iOSBuild: ios.build,
            cloudOSVersion: cloudOS.version,
            cloudOSBuild: cloudOS.build,
            patchPreset: plan.presetIdentifier,
            bootChainPlanDigest: VPhoneMachineTemplateKey.planDigest(
                bootChainPatches: keyedPatches(plan.enabled, preset: plan.presetIdentifier),
                parameters: plan.parameters,
            ),
            bundleSeries: series,
            diskSizeGB: diskSizeGB,
            slimming: fitted,
        )
    }

    /// Use manifest/restore-record versions, never a source filename. Keep
    /// notices off stdout so `vm template find --json` remains valid JSON.
    public static func fitted(_ slimming: VPhoneMachineTemplateSlimming, toIOSVersion version: String) throws -> VPhoneMachineTemplateSlimming {
        do {
            let fitted = try slimming.fitted(toIOSVersion: version)
            if fitted.serviceProfile != slimming.serviceProfile {
                let note = "note: skipping service trimming (including extra service groups): no trimmed service list for iOS \(version); keeping services\n"
                FileHandle.standardError.write(Data(note.utf8))
            }
            return fitted
        } catch let error as VPhoneTemplateSlimmingError {
            throw ValidationError(error.description)
        }
    }

    // MARK: Builds of a request

    /// The device and builds of the two IPSWs when both are local files or
    /// already in the IPSW cache, read without downloading; nil otherwise. A
    /// local path that no longer exists counts as not here.
    static func localBuilds(
        iPhoneSource: String,
        cloudOSSource: String,
        cache: URL,
        device: String?,
    ) throws -> VPhoneMachineTemplateBuilds? {
        guard let phone = try VPhoneIPSWCache.localArchive(iPhoneSource, in: cache),
              let cloud = try VPhoneIPSWCache.localArchive(cloudOSSource, in: cache)
        else {
            return nil
        }
        try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: cloud)
        let guest = VPhoneIPSWCache.guestDevice(for: phone, preferring: device) ?? .default
        if let device, VPhoneGuestDevice.named(device) != guest {
            throw ValidationError("The iPhone IPSW is for \(phone.productTypes.joined(separator: ", ")), not \(device).")
        }
        return VPhoneMachineTemplateBuilds(
            device: guest.productType,
            ios: .init(version: phone.version, build: phone.build),
            cloudOS: .init(version: cloud.version, build: cloud.build),
            origin: .ipsw,
        )
    }

    /// The builds a request names without downloading: from the IPSWs when
    /// they are here, else from a template recorded with the same sources
    /// (``VPhoneMachineTemplates/resolveBuilds(sources:device:in:local:)``).
    /// Nil when only a download would tell.
    public static func resolveBuilds(
        iPhoneSource: String,
        cloudOSSource: String,
        cache: URL,
        device: String?,
        in library: VPhoneLibrary,
    ) throws -> VPhoneMachineTemplateBuilds? {
        try VPhoneMachineTemplates.resolveBuilds(
            sources: VPhoneMachineTemplateSources(iPhone: iPhoneSource, cloudOS: cloudOSSource),
            device: device,
            in: library,
        ) {
            try localBuilds(iPhoneSource: iPhoneSource, cloudOSSource: cloudOSSource, cache: cache, device: device)
        }
    }

    // MARK: Recorded machine

    /// What a machine's records say about it, for adopting it.
    public struct Recorded {
        public var key: VPhoneMachineTemplateKey
        /// The bundle that built the boot chain, when any record names it.
        public var bootChainBundleVersion: String?
        /// Boot-chain patches whose receipt differs from the plan.
        public var drift: [String]
    }

    /// The key a machine's own records give: the restored versions, the
    /// guest device, the boot-chain plan `fw patch` recorded, the disk, and
    /// the series of the bundle that built the boot chain. `slimming` is
    /// what was done to it; nothing is, before the setup boot exists.
    public static func recorded(_ bundle: VPhoneBundle, slimming: VPhoneMachineTemplateSlimming = .none) throws -> Recorded {
        guard VPhoneRestoreInfo.customFirmwareInstalled(inBundle: bundle) == true else {
            throw ValidationError("VM '\(bundle.name)' has no completed CFW install, so it cannot be a template.")
        }
        guard let info = VPhoneRestoreInfo.load(fromBundle: bundle) else {
            throw ValidationError("VM '\(bundle.name)' records no restored iOS and cloudOS versions (restore-info.json).")
        }
        guard let plan = VPhonePatchPresetStore.plan(forVM: bundle.url) else {
            throw ValidationError("VM '\(bundle.name)' has no \(VPhonePatchPresetStore.planFileName): its boot chain is not described.")
        }
        let bootChainVersion = bootChainBundleVersion(of: bundle)
        let series = bootChainVersion.flatMap(VPhoneMachineTemplateKey.series(ofBundleVersion:)) ?? currentSeries
        let key = VPhoneMachineTemplateKey(
            device: bundle.manifest.guestDevice.productType,
            iOSVersion: info.ios.version,
            iOSBuild: info.ios.build,
            cloudOSVersion: info.cloudOS.version,
            cloudOSBuild: info.cloudOS.build,
            patchPreset: plan.presetIdentifier,
            bootChainPlanDigest: VPhoneMachineTemplateKey.planDigest(
                bootChainPatches: keyedPatches(plan.selectedPatches, preset: plan.presetIdentifier),
                parameters: plan.parameters,
            ),
            bundleSeries: series,
            diskSizeGB: diskSizeGB(of: bundle),
            slimming: slimming,
        )
        return Recorded(
            key: key,
            bootChainBundleVersion: bootChainVersion,
            drift: drift(of: bundle, wanted: Set(plan.enabledPatches), planned: Set(plan.enabledPatches)),
        )
    }

    /// The machine's disk in decimal GB, the unit `vm new --disk-size` takes.
    static func diskSizeGB(of bundle: VPhoneBundle) -> UInt64 {
        let bytes = max(bundle.diskSizeBytes, 0)
        return (UInt64(bytes) + 500_000_000) / 1_000_000_000
    }

    /// Launchpad's binding names the bundle that built the boot chain; without
    /// it, the `cfw install` that finished the machine is the best witness,
    /// as long as no environment update has rewritten that part since.
    static func bootChainBundleVersion(of bundle: VPhoneBundle) -> String? {
        let binding = bundle.url.appendingPathComponent("launchpad.json")
        if VPhoneVirtualMachineManifest.fileKind(at: binding) == .regularFile,
           let data = try? Data(contentsOf: binding),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let version = object["bootChain"] as? String, !version.isEmpty
        {
            return version
        }
        if let guest = VPhonePatchPresetStore.receipt(forVM: bundle.url)?.parts[VPhoneVirtualMachinePatchReceipt.guestPart],
           guest.writer == "cfw install"
        {
            return guest.bundleVersion
        }
        return nil
    }

    /// Boot-chain patches whose live state, by the receipt, is not what
    /// `wanted` asks for. A part the receipt does not record reads as the
    /// plan, so a machine without receipts shows no drift.
    static func drift(of bundle: VPhoneBundle, wanted: Set<String>, planned: Set<String>?) -> [String] {
        let receipt = VPhonePatchPresetStore.receipt(forVM: bundle.url)
        let applied = receipt.map { receipt in
            receipt.parts.mapValues { Set($0.patches) }
        }
        let notApplicable = Set(receipt?.parts.values.flatMap(\.notApplicable) ?? [])
        let declarations = FirmwarePatchSetCatalog.allDeclarations.filter {
            if case .firmware = $0.target {
                return true
            }
            return false
        }
        return FirmwarePatchDrift.states(
            declarations: declarations,
            wanted: wanted,
            planned: planned,
            applied: applied,
            notApplicable: notApplicable,
            part: VPhoneVirtualMachinePatchReceipt.part(for:),
        )
        .filter { $0.isPending == true }
        .map(\.identifier)
        .sorted()
    }

    // MARK: Staleness

    /// Why `template` would not serve a fresh create with its own options.
    public static func staleReasons(_ template: VPhoneMachineTemplate) -> [String] {
        let key = template.key
        let selection = VPhonePatchPresetStore.selection(forVM: template.url)
        guard let preset = VPhonePatchPresetStore.preset(named: key.patchPreset, forVM: template.url) else {
            return template.staleReasons(currentSeries: currentSeries, freshKey: nil)
        }
        let fresh = try? self.key(
            device: key.device,
            ios: .init(version: key.iOSVersion, build: key.iOSBuild),
            cloudOS: .init(version: key.cloudOSVersion, build: key.cloudOSBuild),
            preset: preset,
            blocked: selection.blockedPatches,
            allowed: selection.allowedPatches,
            diskSizeGB: key.diskSizeGB,
            series: key.bundleSeries,
            slimming: key.slimming,
        )
        var drifted: [String] = []
        if let bundle = try? template.bundle(),
           let wanted = try? plan(
               preset: preset,
               iOSVersion: key.iOSVersion,
               cloudOSVersion: key.cloudOSVersion,
               blocked: selection.blockedPatches,
               allowed: selection.allowedPatches,
           )
        {
            let recordedPlan = VPhonePatchPresetStore.plan(forVM: template.url)
            let notApplicable = Set(recordedPlan?.notApplicablePatches ?? [])
            let planned = recordedPlan.map { Set($0.enabledPatches) }
            drifted = drift(
                of: bundle,
                wanted: wanted.enabled.subtracting(notApplicable),
                planned: planned,
            )
        }
        return template.staleReasons(currentSeries: currentSeries, freshKey: fresh, driftedPatches: drifted)
    }
}
