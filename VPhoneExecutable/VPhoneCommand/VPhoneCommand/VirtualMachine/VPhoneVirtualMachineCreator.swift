import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhoneRestore

// MARK: - VPhoneVirtualMachineCreationError

/// Failure points across the native `vm create` pipeline.
private enum VPhoneVirtualMachineCreationError: Error, CustomStringConvertible {
    case nestedVirtualization
    case identityTimedOut(URL)
    case invalidUDID(String)
    case invalidECID(String)
    case udidECIDMismatch(udid: String, ecid: String)
    case recoveryTimeout
    case restoreUpdateFailed(String)
    case cfwInstallFailed(Int32)
    case bootAnalysisPanic
    case bootAnalysisExited(Int32)
    case bootAnalysisTimeout
    case bootstrapFailed(String)
    case bootstrapTimeout

    var description: String {
        switch self {
        case .nestedVirtualization:
            "Guest boot is unavailable inside a VM. Run vm create on a macOS 15 or later host that is not itself a VM."
        case let .identityTimedOut(path):
            "Device identity file not found: \(path.path). Run vm create again to regenerate it."
        case let .invalidUDID(v):
            "Invalid UDID in the device identity file: '\(v)'. Run vm create again to regenerate it."
        case let .invalidECID(v):
            "Invalid ECID in the device identity file: '\(v)'. Run vm create again to regenerate it."
        case let .udidECIDMismatch(udid, ecid):
            "The UDID and ECID in the device identity file do not match (\(udid), 0x\(ecid)). Run vm create again to regenerate it."
        case .recoveryTimeout:
            "The device did not enter recovery mode in time. Run vm create again."
        // No exit code any more: the restore backend is in this process, so
        // what a failure carries is the reason it gave.
        case let .restoreUpdateFailed(reason):
            "Device restore failed: \(reason)"
        case let .cfwInstallFailed(code):
            "Custom firmware installation failed (exit code \(code))."
        case .bootAnalysisPanic:
            "Boot check failed: the guest panicked. Run vm create again."
        case let .bootAnalysisExited(code):
            "Boot check ended before the guest connected (exit code \(code)). Run vm create again."
        case .bootAnalysisTimeout:
            "Boot check timed out waiting for the guest. Run vm create again."
        case let .bootstrapFailed(reason):
            "Bootstrap installation failed: \(reason). The machine is kept."
        case .bootstrapTimeout:
            "Bootstrap installation did not finish in time. The machine is kept."
        }
    }
}

extension VPhoneVirtualMachineCreationError: LocalizedError {
    var errorDescription: String? {
        description
    }
}

// MARK: - VPhoneVirtualMachineCreator

/// Native `vm create` pipeline: prepare, patch, restore, install JB system
/// files, and verify that the guest daemon connects on first boot.
///
/// Lives in the EXECUTABLE target rather than VPhoneCoreKit because it composes
/// `FirmwarePatcher.FirmwarePipeline`, and `FirmwarePatcher` already depends on
/// `VPhoneCoreKit` (Package.swift) — VPhoneCoreKit importing FirmwarePatcher back
/// would be a package dependency cycle. The regex/ECID primitives this type
/// needs to be independently unit-testable live in VPhoneCoreKit instead, as
/// `VPhoneBootPatterns`, where `VPhoneCoreTests` (which depends only on
/// VPhoneCoreKit) can reach them.
public struct VPhoneVirtualMachineCreator {
    private let library: VPhoneLibrary
    private let resources: VPhoneResources
    /// How to start the guest. A create boots in DFU and once for verification,
    /// so the AMFI probe runs once before the multi-stage create pipeline. Nil
    /// only for a clone from a named template whose first boot is skipped,
    /// which starts no guest.
    private let launcher: VPhoneGuestLaunchPlanner?

    public init(
        library: VPhoneLibrary,
        resources: VPhoneResources,
        launcher: VPhoneGuestLaunchPlanner?,
    ) {
        self.library = library
        self.resources = resources
        self.launcher = launcher
    }

    // MARK: - run

    /// Creates the machine one of three ways (`Options.template`): the full
    /// pipeline into the machine itself (`--no-template`); a clone of the
    /// template the options resolve to, built first into `.templates` when
    /// there is none (the default); or a clone of a template named by its
    /// identifier. A clone takes a fraction of a second and needs neither
    /// root nor an IPSW.
    public func run(_ options: Options) throws {
        // Fail fast on a nested-VM host — PV=3 guest boot can't nest, and the whole
        // create pipeline (download + patch + restore) is wasted otherwise. Mirrors
        // the host preflight that precedes VM launch.
        let startsGuest: Bool = switch options.template {
        case .identifier: !options.skipsFirstBoot
        case .none, .automatic: true
        }
        if startsGuest, Self.isNestedVMHost() {
            throw VPhoneVirtualMachineCreationError.nestedVirtualization
        }

        try VPhoneBundleOperations.requireValidName(options.name)
        let bundleURL = library.url(forName: options.name)
        // Check before the fixup below is armed: an existing directory, possibly
        // planted by another account, must never be walked as root.
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw VPhoneLibraryError.alreadyExists(name: options.name)
        }
        let outputs = VPhoneCreatedOutputs(library: library)
        defer { outputs.finishBestEffort() }

        switch options.template {
        case .none:
            try createIndependent(options, outputs: outputs)
        case let .identifier(identifier):
            let template = try VPhoneMachineTemplates.template(identifier, in: library)
            let conflicts = options.templateRequest.conflicts(with: template.key)
            guard conflicts.isEmpty else {
                throw VPhoneMachineTemplateError.conflicts(identifier: template.identifier, options: conflicts)
            }
            // Named on purpose, so used; but not silently.
            for reason in VPhoneMachineTemplateKeys.staleReasons(template) {
                print("warning: template \(template.identifier) is stale: \(reason)")
            }
            try cloneFromTemplate(template, options: options, outputs: outputs)
        case .automatic:
            if options.keepArtifacts {
                // A template never keeps it: ~11 GB pinned for the template's
                // whole life, which no clone can use.
                print("warning: --keep-artifacts keeps the restore tree only with --no-template; "
                    + "a template build always removes it")
            }
            let template = try templateForCreate(options, outputs: outputs)
            try cloneFromTemplate(template, options: options, outputs: outputs)
        }

        try outputs.finish()
        print("\n=== Done ===")
        if options.skipsFirstBoot {
            print("CFW VM created; its first boot was skipped. Guest user environment is untouched.")
        } else {
            print(options.bootstrapLayout == nil
                ? "CFW VM created; vphoned connected. Guest user environment is untouched."
                : "CFW VM created; vphoned connected and the \(options.bootstrapLayout!) bootstrap and its packages installed.")
        }
    }

    // MARK: - Without a template

    /// The full pipeline into the machine itself: `vm new`, firmware, restore,
    /// CFW and the first boot check. What `vm create` always did.
    private func createIndependent(_ options: Options, outputs: VPhoneCreatedOutputs) throws {
        print("\n=== vm new ===")
        let spec = VPhoneBundleOperations.NewBundleConfiguration(
            name: options.name,
            cpuCount: options.cpuCount,
            memoryMB: options.memoryMB,
            diskSizeGB: options.diskSizeGB,
            romSource: VPhoneBundleOperations.defaultROMSource(),
            sepromSource: VPhoneBundleOperations.defaultSEPROMSource(),
        )
        let bundle = try VPhoneBundleOperations.create(spec, in: library)
        outputs.add(bundle.url)
        print("created \(bundle.url.path)")

        try buildGuest(at: bundle.url, options: options, keepsRestoreTree: options.keepArtifacts, outputs: outputs)
        try applySettings(options)
        if !options.skipsFirstBoot {
            print("\n=== First boot check ===")
            try runBootAnalysis(bundleURL: bundle.url, bootstrapLayout: options.bootstrapLayout, verbosity: options.verbosity)
        }
    }

    /// `fw prepare`, `fw patch`, the restore and `cfw install` into the machine
    /// folder at `bundleURL`, which `vm new` made. Removes the restore tree
    /// afterwards unless `keepsRestoreTree`. Starts the guest only in DFU.
    private func buildGuest(
        at bundleURL: URL,
        options: Options,
        keepsRestoreTree: Bool,
        outputs: VPhoneCreatedOutputs,
    ) throws {
        let v = options.verbosity
        // `fw prepare` stages what the selection needs (the GPU driver, the seal
        // tool), so the preset has to be on record before it runs.
        try VPhonePatchPresetStore.writePresetFile(options.patchPresetFile, forVM: bundleURL)
        try VPhonePatchPresetStore.write(
            VPhoneVirtualMachinePatchSelection(presetIdentifier: options.patchPreset),
            forVM: bundleURL,
        )
        print("\n=== fw prepare ===")
        try runFWPrepare(options: options, bundleURL: bundleURL)

        print("\n=== fw patch ===")
        try runFWPatch(presetIdentifier: options.patchPreset, bundleURL: bundleURL, verbosity: v)

        print("\n=== Restore phase ===")
        try runRestorePhase(bundleURL: bundleURL, verbosity: v)

        print("[*] Waiting 5s for cleanup before CFW install...")
        Thread.sleep(forTimeInterval: 5)
        // Under sudo the steps above created the bundle as root, but the CFW
        // installer only accepts a VM folder, Disk.img and restore tree owned
        // by the invoking user. Hand this run's own bundle back first (the
        // same descriptor-relative walk as the final fixup).
        try outputs.handBack(bundleURL)
        print("\n=== CFW install (host-mount) ===")
        try runCustomFirmwareInstall(
            options: options,
            bundleURL: bundleURL,
        )

        // CFW install is the last consumer of the built restore tree (it copies
        // the SystemOS/AppOS cryptexes from it onto Disk.img); reclaim it now.
        if !keepsRestoreTree, let bundle = try? VPhoneBundle.load(at: bundleURL),
           let removed = try? VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: bundle)
        {
            print("[+] Removed built firmware \(removed)/ to save space (--keep-artifacts to keep)")
        }
    }

    /// The settings `vm config` would set, on the new machine.
    private func applySettings(_ options: Options) throws {
        let bundle = try VPhoneBundleOperations.updateConfig(
            bundleNamed: options.name,
            in: library,
            cpuCount: options.cpuCount,
            memoryMB: options.memoryMB,
            networkMode: options.networkMode,
            unlocksAtStartup: options.unlocksAtStartup,
        )
        let manifest = bundle.manifest
        print("[+] \(bundle.name): \(manifest.cpuCount) CPU, \(manifest.memorySize / (1024 * 1024)) MB, "
            + "network \(manifest.networkConfig.mode.rawValue), unlock at startup \(manifest.unlocksScreenAtStartup ? "on" : "off")")
    }

    // MARK: - Templates

    /// The template a create with these options clones from: the one their
    /// key names, or a new one built into `.templates` first. A second create
    /// with the same key waits for a build in progress instead of restoring
    /// a second copy.
    private func templateForCreate(_ options: Options, outputs: VPhoneCreatedOutputs) throws -> VPhoneMachineTemplate {
        guard let phoneSource = options.iphoneSource, let cloudSource = options.cloudosSource else {
            throw ValidationError("Specify both iPhone and cloudOS IPSW sources when running without a terminal.")
        }
        print("\n=== Template ===")
        let slimming = Self.templateSlimming(options)
        guard slimming.problems.isEmpty else {
            throw ValidationError("Cannot build this template: \(slimming.problems.joined(separator: "; ")). Pass --trim none.")
        }
        let preset = try options.patchPresetFile ?? VPhonePatchPresetStore.resolve(options.patchPreset).preset
        // Resolved as vm template find resolves it: from the IPSWs when they
        // are local or cached, else from a template recorded with the same
        // sources. Nothing is downloaded unless no template matches and one
        // has to be built.
        let builds = try VPhoneMachineTemplateKeys.resolveBuilds(
            iPhoneSource: phoneSource,
            cloudOSSource: cloudSource,
            cache: options.ipswCacheDirectory,
            device: options.device,
            in: library,
        )
        if let builds {
            let key = try VPhoneMachineTemplateKeys.key(
                device: builds.device,
                ios: builds.ios,
                cloudOS: builds.cloudOS,
                preset: preset,
                diskSizeGB: options.diskSizeGB,
                slimming: slimming,
            )
            if let found = try VPhoneMachineTemplates.template(for: key, in: library) {
                print("[*] Template key \(key.identifier): \(key.summary)")
                if builds.origin == .template, let source = builds.template {
                    print("[*] Builds from template \(source), recorded with the same IPSW sources; nothing downloaded")
                }
                return try requireCurrent(found)
            }
        }

        // A build: it needs the IPSWs, so they are downloaded now when they
        // are not here, and the key is taken from them.
        let sources = try VPhoneFirmwarePreparer.resolveSources(
            iPhoneSource: phoneSource,
            cloudOSSource: cloudSource,
            ipswCacheDirectory: options.ipswCacheDirectory,
            device: options.device,
        )
        let key = try VPhoneMachineTemplateKeys.key(
            device: sources.device.productType,
            ios: .init(version: sources.phone.version, build: sources.phone.build),
            cloudOS: .init(version: sources.cloud.version, build: sources.cloud.build),
            preset: preset,
            diskSizeGB: options.diskSizeGB,
            slimming: slimming,
        )
        print("[*] Template key \(key.identifier): \(key.summary)")

        if let found = try VPhoneMachineTemplates.template(for: key, in: library) {
            return try requireCurrent(found)
        }
        let lock: VPhoneMachineTemplateLock
        do {
            lock = try VPhoneMachineTemplates.lock(key.identifier, in: library, wait: false)
        } catch VPhoneMachineTemplateError.busy {
            print("[*] Another create is building template \(key.identifier); waiting for it...")
            lock = try VPhoneMachineTemplates.lock(key.identifier, in: library, wait: true)
        }
        defer { lock.release() }
        outputs.addDirectory(VPhoneMachineTemplates.directory(in: library))
        // Built by the create that held the lock before this one.
        if let found = try VPhoneMachineTemplates.template(for: key, in: library) {
            return try requireCurrent(found)
        }
        return try buildTemplate(key, options: options, outputs: outputs)
    }

    /// What a template built for these options is slimmed by, part of its
    /// key: the switches `VPhoneTemplateSlimmingRequest` resolved. `--slim off`
    /// resolves to trim none. A trim without the setup boot is refused before
    /// the build (`slimming.problems`): nothing else deletes the guest's
    /// orig-fs snapshot, and without that a trim frees nothing.
    static func templateSlimming(_ options: Options) -> VPhoneMachineTemplateSlimming {
        options.slimming
    }

    private func requireCurrent(_ template: VPhoneMachineTemplate) throws -> VPhoneMachineTemplate {
        let reasons = VPhoneMachineTemplateKeys.staleReasons(template)
        guard reasons.isEmpty else {
            throw VPhoneMachineTemplateError.stale(identifier: template.identifier, reasons: reasons)
        }
        print("[+] Using template \(template.identifier), built \(template.record.created.formatted(.iso8601))")
        return template
    }

    /// Builds the template for `key` in a staging folder in `.templates` and
    /// freezes it into place. After `cfw install` the template boots once, its
    /// setup boot, and never again once frozen. A failed build is left in its
    /// staging folder for inspection; `vm template list` shows it,
    /// `vm template setup` finishes one whose setup boot failed, and
    /// `vm template delete` removes it.
    private func buildTemplate(
        _ key: VPhoneMachineTemplateKey,
        options: Options,
        outputs: VPhoneCreatedOutputs,
    ) throws -> VPhoneMachineTemplate {
        print("\n=== Template build \(key.identifier) ===")
        let build = try VPhoneMachineTemplates.beginBuild(key, in: library)
        outputs.add(build.stagingURL)
        do {
            // The template keeps the default hardware; the machine cloned from
            // it gets the requested CPU, memory and network.
            let spec = VPhoneBundleOperations.NewBundleConfiguration(
                name: key.identifier,
                cpuCount: 8,
                memoryMB: 8192,
                diskSizeGB: options.diskSizeGB,
                romSource: VPhoneBundleOperations.defaultROMSource(),
                sepromSource: VPhoneBundleOperations.defaultSEPROMSource(),
            )
            let bundle = try VPhoneBundleOperations.create(spec, in: build.library)
            print("created \(bundle.url.path)")
            let bundleVersion = VPhoneBundleVersion.current()
            try VPhoneMachineTemplates.writeRecord(
                VPhoneMachineTemplateRecord(
                    key: key,
                    builtWithBundleVersion: bundleVersion,
                    bootChainBundleVersion: bundleVersion,
                    sourceMachine: options.name,
                    // So `vm template find` keys a later request without the
                    // IPSWs, once they are deleted.
                    sources: options.iphoneSource.flatMap { phone in
                        options.cloudosSource.map { VPhoneMachineTemplateSources(iPhone: phone, cloudOS: $0) }
                    },
                ),
                inBundle: bundle.url,
            )

            try buildGuest(at: bundle.url, options: options, keepsRestoreTree: false, outputs: outputs)
            // A template never keeps the restore tree, whatever
            // --keep-artifacts says; freeze removes it too, this says so.
            if let tree = try VPhoneMachineTemplates.removeRestoreTree(of: VPhoneBundle.load(at: bundle.url)) {
                print("[+] Removed built firmware \(tree)/ (a template never keeps it)")
            }

            // Offline trim of the System volume, after cfw install. Each
            // stage records its work with VPhoneMachineTemplates.recordSteps
            // before the freeze; freeze refuses steps that do not match the
            // key, and a trim whose orig-fs snapshot was not deleted.
            let trim = try VPhoneSystemTrimSpec(keyValue: key.slimming.trimTier)
            if trim.tier != .none {
                print("\n=== Offline trim ===")
                try VPhoneMachineTemplateTrimmer.trim(
                    VPhoneBundle.load(at: bundle.url),
                    label: key.identifier,
                    spec: trim,
                    newRecord: nil,
                )
            }

            // The setup boot deletes the orig-fs snapshot first, which frees
            // what the trim removed, then records snapshotDeleted, setupDone,
            // the service profile and the removed apps. It leaves trimTier
            // as the trim recorded it.
            if key.slimming.setupBoot {
                print("\n=== Template setup boot ===")
                // With a window, as the first-boot check: this is the guest's
                // first boot (see runBootAnalysis).
                try VPhoneTemplateSetupRun.run(
                    bundleURL: bundle.url,
                    plan: VPhoneTemplateSetupPlan(slimming: key.slimming, requiresEveryApp: true),
                    launcher: requireLauncher(),
                    resources: resources,
                    headless: false,
                    verbosity: options.verbosity,
                )
            }

            // freeze refuses steps that do not match the key.
            try VPhoneTemplateBuildFinisher.requireRecordedKey(build, key: key)
            try outputs.handBack(build.stagingURL)
            let template = try VPhoneMachineTemplates.freeze(build)
            outputs.replace(build.stagingURL, with: template.url)
            print("[+] Template \(template.identifier) frozen at \(template.url.path)")
            return template
        } catch {
            print("[-] Template build failed; left at \(build.stagingURL.path).")
            if error is VPhoneTemplateSetupFailure {
                print("    Retry its setup boot with: vphone-cli vm template setup \(build.stagingURL.lastPathComponent)")
            }
            print("    Remove it with: vphone-cli vm template delete \(build.stagingURL.lastPathComponent)")
            throw error
        }
    }

    /// The new machine, cloned from `template` with a new identity, given the
    /// requested settings and booted once to check vphoned answers.
    private func cloneFromTemplate(_ template: VPhoneMachineTemplate, options: Options, outputs: VPhoneCreatedOutputs) throws {
        print("\n=== Clone from template \(template.identifier) ===")
        let clone = try VPhoneMachineTemplates.cloneMachine(from: template, to: options.name, in: library)
        outputs.add(clone.url)
        do {
            // The ROMs are not part of a template's key: they change without a
            // restore. A template built before OpenAVB or OpenSEP still starts
            // Apple's, so the machine gets this bundle's ROMs, as a `vm new`
            // would.
            let booted = try VPhoneBundleOperations.installBootROM(from: VPhoneBundleOperations.defaultROMSource(), in: clone)
            try VPhoneBundleOperations.installSEPROM(from: VPhoneBundleOperations.defaultSEPROMSource(), in: booted)
            try applySettings(options)
        } catch {
            try? FileManager.default.removeItem(at: clone.url)
            throw error
        }
        print("[+] \(clone.name) cloned from template \(template.identifier) with a new identity "
            + "(it shares SEP and Data volume keys with every machine from this template)")
        if !options.skipsFirstBoot {
            print("\n=== First boot check ===")
            try runBootAnalysis(bundleURL: clone.url, bootstrapLayout: options.bootstrapLayout, verbosity: options.verbosity)
        }
    }

    private func requireLauncher() throws -> VPhoneGuestLaunchPlanner {
        guard let launcher else {
            throw ValidationError("This create starts the guest, but vphone-vm was not resolved.")
        }
        return launcher
    }

    // MARK: - trace

    /// Internal spawn/outcome trace, gated on `.trace` (`-vvv`). Never prints
    /// secret environment values — callers pass only key names.
    private func trace(_ msg: String, _ v: VPhoneVerbosity) {
        guard v.tracesInternals else { return }
        print("[trace] \(msg)")
    }

    // MARK: - nested-VM preflight

    /// True when running inside an Apple VM (`kern.hv_vmm_present == 1`),
    /// where Virtualization.framework PV=3 guest boot is unavailable.
    ///
    /// Read with `sysctlbyname`. It used to spawn `/usr/sbin/sysctl -n` and
    /// match its stdout against "1" — a process and a string parser for one int
    /// the kernel hands over directly. An unreadable sysctl reads as "not
    /// nested", which is what the string parse did with an empty stdout.
    static func isNestedVMHost() -> Bool {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 else {
            return false
        }
        return present != 0
    }

    // MARK: - fw prepare / fw patch

    private func runFWPrepare(options: Options, bundleURL: URL) throws {
        guard let phone = options.iphoneSource, let cloud = options.cloudosSource else {
            throw ValidationError("Specify both iPhone and cloudOS IPSW sources when running without a terminal.")
        }
        let bundle = try VPhoneBundle.load(at: bundleURL)
        try VPhoneFirmwarePreparer.prepare(
            iPhoneSource: phone, cloudOSSource: cloud,
            gpuDriverBundle: options.gpuDriverBundle,
            ipswCacheDirectory: options.ipswCacheDirectory,
            device: options.device,
            otaSource: options.otaSource,
            otaKey: options.otaKey,
            checksKernelcacheMix: true,
            bundle: bundle, resources: resources,
        )
        print("[+] Firmware prepared (iPhone + cloudOS merged into bundle).")
    }

    private func runFWPatch(
        presetIdentifier: String,
        bundleURL: URL,
        verbosity v: VPhoneVerbosity,
    ) throws {
        trace("in-process FirmwarePipeline.patchAll variant=jb preset=\(presetIdentifier)", v)
        guard let preset = VPhonePatchPresetStore.preset(named: presetIdentifier, forVM: bundleURL) else {
            let available = VPhonePatchPresetStore.availablePresets().map(\.identifier)
            throw ValidationError(
                "Unknown patch preset '\(presetIdentifier)'. Available: \(available.joined(separator: ", "))",
            )
        }
        let pipeline = FirmwarePipeline(
            vmDirectory: bundleURL,
            variant: .jb,
            verbose: v.showsToolDetail,
            noBinpack: true,
            preset: preset,
        )
        let records = try pipeline.patchAll()

        // A new VM records its choice and its plan, so `cfw install` and any later
        // re-patch agree without the preset being named again.
        if let plan = pipeline.resolvedPlan {
            try VPhonePatchPresetStore.write(
                VPhoneVirtualMachinePatchSelection(presetIdentifier: presetIdentifier),
                forVM: bundleURL,
            )
            try VPhonePatchPresetStore.write(
                VPhoneVirtualMachinePatchPlan(
                    plan: plan,
                    iOSBase: pipeline.baseProductVersion,
                    cloudOS: pipeline.cloudOSProductVersion,
                    notApplicablePatches: pipeline.notApplicablePatches,
                ),
                forVM: bundleURL,
            )
        }
        print("[fw patch] applied \(records.count) CFW patches (preset \(presetIdentifier))")
    }

    // MARK: - restore phase

    private func runRestorePhase(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        print("[*] Starting DFU boot in background...")
        // Guest serial is never teed during `vm create` (echo: false); the
        // managed process still reads it internally for panic/prompt matching.
        let (dfuExe, dfuArgs) = try requireLauncher().plan(["--config", configURL.path, "--dfu"])
        trace("spawn \(dfuExe.path) \(dfuArgs.joined(separator: " ")) (guest serial: off)", v)
        let dfu = VPhoneManagedProcess(dfuExe, dfuArgs, cwd: bundleURL, echo: false)
        try dfu.start()
        defer { dfu.terminate() }

        let (udid, ecid) = try loadDeviceIdentity(bundleURL: bundleURL)
        print("[+] Device identity loaded: UDID=\(udid) ECID=0x\(ecid)")
        // `loadDeviceIdentity` has already held this to ^[0-9A-F]{16}$, so the
        // parse cannot fail; it is here because the backend takes the number.
        let ecidValue = try VPhoneRestoreIdentity.parseECID(ecid)

        try waitForRecovery(ecid: ecidValue, verbosity: v)

        // Online restore fetches its own signing ticket. Running a separate
        // SHSH request first would initialize and tear down libirecovery twice
        // in this process; the second device discovery can then fail. The
        // standalone `restore --get-shsh` command remains available when a
        // ticket file is needed for an offline restore.
        let onEvent = VPhoneRestoreConsole.handler(level: v.restoreLogLevel)
        print("[*] Restoring...")
        trace("in-process VPhoneRestoreService.restore udid=\(udid) ecid=0x\(ecid) erase=true", v)
        do {
            try VPhoneRestoreService.restore(
                vmDir: bundleURL,
                ecid: ecidValue,
                udid: udid,
                erase: true,
                ticketPath: nil,
                debugLevel: v.restoreDebugLevel,
                onEvent: onEvent,
            )
        } catch {
            throw VPhoneVirtualMachineCreationError.restoreUpdateFailed("\(error)")
        }

        recordRestoreVersions(bundleURL: bundleURL)

        // wait_for_post_restore_reboot: a plain case-insensitive 'panic' grep —
        // distinct from (narrower than) BOOT_PANIC_REGEX used elsewhere.
        print("[*] Restore complete; waiting up to 30s for reboot/panic before stopping DFU...")
        let dfuOutcome = dfu.waitForOutput(matching: "(?i)panic|kernel panic", timeout: 30)
        trace("DFU managed-process outcome: \(dfuOutcome)", v)
        switch dfuOutcome {
        case .matched:
            print("[+] Panic marker observed; stopping DFU now.")
        case .exited:
            print("[*] DFU process exited during post-restore reboot window.")
        case .timedOut:
            print("[*] No panic marker observed in 30s; stopping DFU anyway.")
        }
        // `defer` above terminates the DFU process on every exit path.
    }

    /// Snapshot the just-restored iOS + cloudOS versions to `restore-info.json`,
    /// read host-side from the bundle's restore-dir plists. Best-effort: the
    /// restore already succeeded, so a metadata miss is a warning, not a failure.
    private func recordRestoreVersions(bundleURL: URL) {
        guard let bundle = try? VPhoneBundle.load(at: bundleURL),
              let info = VPhoneRestoreInfo.derive(fromBundle: bundle)
        else {
            print("[!] Could not record restore versions (metadata not found)")
            return
        }
        do {
            try info.write(toBundle: bundle)
            print(
                "[+] Recorded versions: iOS \(info.ios.version) (\(info.ios.build)), "
                    + "cloudOS \(info.cloudOS.version) (\(info.cloudOS.build))",
            )
        } catch {
            print("[!] Could not write restore-info.json: \(error)")
        }
    }

    private func loadDeviceIdentity(bundleURL: URL) throws -> (udid: String, ecid: String) {
        let predictionFile = bundleURL.appendingPathComponent("udid-prediction.txt")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: predictionFile.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        guard FileManager.default.fileExists(atPath: predictionFile.path) else {
            throw VPhoneVirtualMachineCreationError.identityTimedOut(predictionFile)
        }

        let text = (try? String(contentsOf: predictionFile, encoding: .utf8)) ?? ""
        var udid = ""
        var ecid = ""
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< eq]
            let value = String(line[line.index(after: eq)...])
            if key == "UDID" {
                udid = value.uppercased()
            }
            if key == "ECID" {
                ecid = VPhoneBootPatterns.normalizeECID(value) ?? ""
            }
        }

        guard udid.range(of: "^[0-9A-F]{8}-[0-9A-F]{16}$", options: .regularExpression) != nil else {
            throw VPhoneVirtualMachineCreationError.invalidUDID(udid)
        }
        if ecid.isEmpty {
            ecid = udid.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        }
        guard ecid.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil else {
            throw VPhoneVirtualMachineCreationError.invalidECID(ecid)
        }
        let udidSuffix = udid.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        guard udidSuffix == ecid else {
            throw VPhoneVirtualMachineCreationError.udidECIDMismatch(udid: udid, ecid: ecid)
        }
        return (udid, ecid)
    }

    /// 90 attempts, each waiting up to 2 seconds for an endpoint and sleeping 2
    /// between — the cadence `setup_machine.sh`'s `wait_for_recovery` set, kept
    /// to the attempt. What is gone is the python process per attempt: the same
    /// wait is now one `irecv_open_with_ecid_and_attempts` poll per round.
    private func waitForRecovery(ecid: UInt64?, verbosity v: VPhoneVerbosity) throws {
        print("[*] Waiting for recovery/DFU endpoint...")
        for _ in 1 ... 90 {
            if let device = try? VPhoneRestoreService.recoveryProbe(ecid: ecid, timeout: 2) {
                print("[+] Device endpoint is reachable")
                trace("recovery-probe: \(device.productType ?? "device") in \(device.mode)", v)
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        trace("recovery-probe: exhausted 90 retries", v)
        throw VPhoneVirtualMachineCreationError.recoveryTimeout
    }

    // MARK: - CFW install

    private func runCustomFirmwareInstall(
        options: Options,
        bundleURL: URL,
    ) throws {
        let v = options.verbosity
        trace("native CFW install for \(bundleURL.path)", v)
        let code = try VPhoneCustomFirmwareInstaller.elevate(bundle: bundleURL, resources: resources)
        guard code == 0 else { throw VPhoneVirtualMachineCreationError.cfwInstallFailed(code) }
        print("[+] CFW installed.")
        if let bundle = try? VPhoneBundle.load(at: bundleURL),
           let info = try? VPhoneRestoreInfo.recordVariant("jb", toBundle: bundle), info.variant != nil
        {
            print("[+] Recorded variant jb, device \(info.device ?? "?")")
        }
    }

    // MARK: - first boot check

    private func runBootAnalysis(bundleURL: URL, bootstrapLayout: String?, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        // A newly restored guest may need its first graphical session to
        // finish setup before vphoned accepts a connection. A headless first
        // boot timed out on 26.6.2, while the same disk reached vphoned in
        // GUI mode; later headless boots then connected normally.
        // A clone carries the template's vphoned; boot this bundle's, as vm launch does.
        _ = try VPhoneLaunchLayout(resources: resources).stageVphoned(into: VPhoneBundle.load(at: bundleURL))
        let (vmExe, vmArgs) = try requireLauncher().plan(["--config", configURL.path])
        trace("spawn \(vmExe.path) \(vmArgs.joined(separator: " ")) (guest serial: off)", v)
        let vm = VPhoneManagedProcess(vmExe, vmArgs, cwd: bundleURL, echo: false)
        try vm.start()
        defer { vm.terminate() }

        let socketPath = bundleURL.appendingPathComponent("vphone.sock").path
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            switch vm.waitForOutput(matching: "(?i:\(VPhoneBootPatterns.panicRegex))", timeout: 0) {
            case .matched:
                print("[-] Boot analysis: panic detected, stopping VM.")
                throw VPhoneVirtualMachineCreationError.bootAnalysisPanic
            case let .exited(code):
                print("[-] Boot analysis: VM process exited before success marker.")
                throw VPhoneVirtualMachineCreationError.bootAnalysisExited(code)
            case .timedOut:
                break
            }
            if VPhoneHostAutomationProbe.ping(socketPath: socketPath) {
                print("[+] First boot: vphoned ping succeeded.")
                if let bootstrapLayout {
                    try installBootstrap(layout: bootstrapLayout, socketPath: socketPath)
                    if !vm.interrupt(waitingUpTo: 30) {
                        print("warning: the guest did not shut down within 30 s; stopping it")
                    }
                }
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        print("[-] Boot analysis timeout (300s); stopping VM.")
        throw VPhoneVirtualMachineCreationError.bootAnalysisTimeout
    }

    /// vphoned's `bootstrap.install`, then `bootstrap.packages`: Irisin, then
    /// the first packages through irisin-cli's Bootstrap Install.
    private func installBootstrap(layout: String, socketPath: String) throws {
        print("\n=== Bootstrap (\(layout)) ===")
        let irisin = try followBootstrap("bootstrap.install", params: ["layout": layout], socketPath: socketPath, within: 900) {
            $0["packages"] == nil
        }
        print("[+] Irisin \(irisin["version"] as? String ?? "") installed in \(irisin["jbroot"] as? String ?? "")")
        if let warning = irisin["service_start_warning"] as? String {
            print("warning: \(warning)")
        }

        print("\n=== Bootstrap packages ===")
        let packages = try followBootstrap("bootstrap.packages", params: [:], socketPath: socketPath, within: 1800) {
            $0["packages"] != nil
        }
        if let skipped = packages["skipped"] as? String {
            print("note: no packages installed: \(skipped)")
        } else {
            print("[+] Installed \((packages["packages"] as? [String] ?? []).joined(separator: ", ")) with Bootstrap Install")
        }
    }

    /// One bootstrap call. The VM gives up relaying a request after 180 s
    /// while the guest carries on, so a lost reply is followed by
    /// `bootstrap.status` until a status `isThisCall` recognizes ends.
    private func followBootstrap(
        _ method: String,
        params: [String: Any],
        socketPath: String,
        within seconds: Int,
        isThisCall: ([String: Any]) -> Bool,
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        do {
            return try VPhoneHostAutomationProbe.rpc(method, params: params, socketPath: socketPath, timeout: seconds)
        } catch let error as VPhoneGuestCallError where error.kind == .refused {
            throw VPhoneVirtualMachineCreationError.bootstrapFailed(error.message)
        } catch let error as VPhoneGuestCallError {
            print("    \(error.message); following it")
        }
        while Date() < deadline {
            if let status = try? VPhoneHostAutomationProbe.rpc("bootstrap.status", params: [:], socketPath: socketPath, timeout: 10),
               isThisCall(status)
            {
                switch status["phase"] as? String {
                case "completed":
                    return status
                case "failed":
                    throw VPhoneVirtualMachineCreationError.bootstrapFailed(status["error"] as? String ?? "unknown error")
                default:
                    break
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw VPhoneVirtualMachineCreationError.bootstrapTimeout
    }
}

// MARK: - VPhoneCreatedOutputs

/// The folders a create made, handed back to the invoking user (under sudo)
/// and made accessible like every other host VM artifact, on every way out.
///
/// Only folders this run created are listed, so an existing directory,
/// possibly planted by another account, is never walked as root. `finish()`
/// is the strict pass at the end; `finishBestEffort()` runs from a `defer`
/// and warns instead, for whatever `finish()` did not get to.
private final class VPhoneCreatedOutputs {
    private let invokingUser = VPhoneInvokingUser.current
    private var outputs: [URL] = []
    private var directories: [URL]
    private var ownershipRestored = false
    private var permissionsRestored = false

    init(library: VPhoneLibrary) {
        directories = [library.root, VPhoneResources.userDataRoot()]
    }

    func add(_ url: URL) {
        outputs.append(url)
    }

    /// A folder that moved: a template build renamed into place.
    func replace(_ old: URL, with new: URL) {
        outputs = outputs.map { $0 == old ? new : $0 }
    }

    /// A shared directory this run may have created, such as `.templates`.
    func addDirectory(_ url: URL) {
        if !directories.contains(url) {
            directories.insert(url, at: directories.count - 1)
        }
    }

    /// Gives one output back to the invoking user now, ahead of the CFW
    /// install, which accepts only a folder its caller owns.
    func handBack(_ url: URL) throws {
        try invokingUser?.restoreOwnership(at: url)
    }

    func finish() throws {
        if let invokingUser {
            for output in outputs {
                try invokingUser.restoreOwnership(at: output)
            }
            for directory in directories {
                try invokingUser.restoreOwnerOfDirectory(at: directory)
            }
        }
        ownershipRestored = true
        for output in outputs {
            try VPhoneHostFilePermissions.makeAccessible(at: output)
        }
        for directory in directories {
            try VPhoneHostFilePermissions.makeDirectoryAccessible(at: directory)
        }
        permissionsRestored = true
    }

    func finishBestEffort() {
        if let invokingUser, !ownershipRestored {
            for output in outputs {
                do { try invokingUser.restoreOwnership(at: output) } catch {
                    fputs("warning: could not restore ownership of \(output.path): \(error)\n", stderr)
                }
            }
            for directory in directories {
                try? invokingUser.restoreOwnerOfDirectory(at: directory)
            }
        }
        if !permissionsRestored {
            for output in outputs {
                do { try VPhoneHostFilePermissions.makeAccessible(at: output) } catch {
                    fputs("warning: could not set permissions on \(output.path): \(error)\n", stderr)
                }
            }
            for directory in directories {
                try? VPhoneHostFilePermissions.makeDirectoryAccessible(at: directory)
            }
        }
    }
}
