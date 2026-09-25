import ArgumentParser
import FirmwarePatcher
import Foundation
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
            "Timed out waiting for the device to enter recovery mode."
        // No exit code any more: the restore backend is in this process, so
        // what a failure carries is the reason it gave.
        case let .restoreUpdateFailed(reason):
            "Device restore failed: \(reason)"
        case let .cfwInstallFailed(code):
            "Custom firmware installation failed (exit code \(code))."
        case .bootAnalysisPanic:
            "Boot check failed: the guest panicked. Run vm create again."
        case let .bootAnalysisExited(code):
            "Boot check ended before vphoned connected (exit code \(code))."
        case .bootAnalysisTimeout:
            "Boot check timed out waiting for vphoned."
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
    /// so the AMFI probe runs once before the multi-stage create pipeline.
    private let launcher: VPhoneGuestLaunchPlanner

    public init(
        library: VPhoneLibrary,
        resources: VPhoneResources,
        launcher: VPhoneGuestLaunchPlanner,
    ) {
        self.library = library
        self.resources = resources
        self.launcher = launcher
    }

    // MARK: - run

    public func run(_ options: Options) throws {
        let v = options.verbosity
        let invokingUser = VPhoneInvokingUser.current
        // Fail fast on a nested-VM host — PV=3 guest boot can't nest, and the whole
        // create pipeline (download + patch + restore) is wasted otherwise. Mirrors
        // the host preflight that precedes VM launch.
        if Self.isNestedVMHost() {
            throw VPhoneVirtualMachineCreationError.nestedVirtualization
        }

        let bundleURL = library.url(forName: options.name)
        // Check before the fixup below is armed: an existing directory, possibly
        // planted by another account, must never be walked as root.
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw VPhoneLibraryError.alreadyExists(name: options.name)
        }
        let ownedOutputs = [bundleURL]
        // Set only once this run has created the bundle directory itself.
        var createdBundle = false
        var ownershipRestored = false
        var permissionsRestored = false
        defer {
            if let invokingUser, !ownershipRestored {
                for output in ownedOutputs where createdBundle {
                    do { try invokingUser.restoreOwnership(at: output) } catch {
                        fputs("warning: could not restore ownership of \(output.path): \(error)\n", stderr)
                    }
                }
                try? invokingUser.restoreOwnerOfDirectory(at: library.root)
                try? invokingUser.restoreOwnerOfDirectory(at: VPhoneResources.userDataRoot())
            }
            if !permissionsRestored {
                for output in ownedOutputs where createdBundle {
                    do { try VPhoneHostFilePermissions.makeAccessible(at: output) } catch {
                        fputs("warning: could not set permissions on \(output.path): \(error)\n", stderr)
                    }
                }
                try? VPhoneHostFilePermissions.makeDirectoryAccessible(at: library.root)
                try? VPhoneHostFilePermissions.makeDirectoryAccessible(at: VPhoneResources.userDataRoot())
            }
        }

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
        createdBundle = true
        print("created \(bundle.url.path)")

        print("\n=== fw prepare ===")
        try runFWPrepare(options: options, bundleURL: bundleURL)

        print("\n=== fw patch ===")
        try runFWPatch(enableFrida: options.enableFrida, bundleURL: bundleURL, verbosity: v)

        print("\n=== Restore phase ===")
        try runRestorePhase(bundleURL: bundleURL, verbosity: v)

        print("[*] Waiting 5s for cleanup before CFW install...")
        Thread.sleep(forTimeInterval: 5)
        // Under sudo the steps above created the bundle as root, but the CFW
        // installer only accepts a VM folder, Disk.img and restore tree owned
        // by the invoking user. Hand this run's own bundle back first (the
        // same descriptor-relative walk as the final fixup).
        if let invokingUser {
            try invokingUser.restoreOwnership(at: bundleURL)
        }
        print("\n=== CFW install (host-mount) ===")
        try runCustomFirmwareInstall(
            options: options,
            bundleURL: bundleURL,
        )

        // CFW install is the last consumer of the built restore tree (it copies
        // the SystemOS/AppOS cryptexes from it onto Disk.img); reclaim it now.
        if !options.keepArtifacts, let bundle = try? VPhoneBundle.load(at: bundleURL),
           let removed = try? VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: bundle)
        {
            print("[+] Removed built firmware \(removed)/ to save space (--keep-artifacts to keep)")
        }

        print("\n=== First boot check ===")
        try runBootAnalysis(bundleURL: bundleURL, verbosity: v)
        if let invokingUser {
            for output in ownedOutputs {
                try invokingUser.restoreOwnership(at: output)
            }
            try invokingUser.restoreOwnerOfDirectory(at: library.root)
            try invokingUser.restoreOwnerOfDirectory(at: VPhoneResources.userDataRoot())
        }
        ownershipRestored = true
        for output in ownedOutputs {
            try VPhoneHostFilePermissions.makeAccessible(at: output)
        }
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: library.root)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: VPhoneResources.userDataRoot())
        permissionsRestored = true
        print("\n=== Done ===")
        print("JB VM created; vphoned connected. Guest user environment is untouched.")
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
            bundle: bundle, resources: resources,
        )
        print("[+] Firmware prepared (iPhone + cloudOS merged into bundle).")
    }

    private func runFWPatch(
        enableFrida: Bool,
        bundleURL: URL,
        verbosity v: VPhoneVerbosity,
    ) throws {
        trace("in-process FirmwarePipeline.patchAll variant=jb", v)
        let pipeline = FirmwarePipeline(
            vmDirectory: bundleURL,
            variant: .jb,
            verbose: v.showsToolDetail,
            noBinpack: true,
            forceExcGuard: false,
            enableFrida: enableFrida,
        )
        let records = try pipeline.patchAll()
        print("[fw patch] applied \(records.count) JB patches")
    }

    // MARK: - restore phase

    private func runRestorePhase(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        print("[*] Starting DFU boot in background...")
        // Guest serial is never teed during `vm create` (echo: false); the
        // managed process still reads it internally for panic/prompt matching.
        let (dfuExe, dfuArgs) = launcher.plan(["--config", configURL.path, "--dfu"])
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
        trace("native JB CFW install for \(bundleURL.path)", v)
        let code = try VPhoneCustomFirmwareInstaller.elevate(
            bundle: bundleURL, resources: resources,
            forceDyldSharedCacheMaxSlide: options.forceDyldSharedCacheMaxSlide,
        )
        guard code == 0 else { throw VPhoneVirtualMachineCreationError.cfwInstallFailed(code) }
        print("[+] JB CFW installed.")
        if let bundle = try? VPhoneBundle.load(at: bundleURL),
           let info = try? VPhoneRestoreInfo.recordVariant("jb", toBundle: bundle), info.variant != nil
        {
            print("[+] Recorded variant jb, device \(info.device ?? "?")")
        }
    }

    // MARK: - first boot check

    private func runBootAnalysis(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        // A newly restored guest may need its first graphical session to
        // finish setup before vphoned accepts a connection. A headless first
        // boot timed out on 26.6.2, while the same disk reached vphoned in
        // GUI mode; later headless boots then connected normally.
        let (vmExe, vmArgs) = launcher.plan(["--config", configURL.path])
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
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        print("[-] Boot analysis timeout (300s); stopping VM.")
        throw VPhoneVirtualMachineCreationError.bootAnalysisTimeout
    }
}
