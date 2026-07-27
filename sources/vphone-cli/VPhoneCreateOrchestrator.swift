import FirmwarePatcher
import Foundation
import VPhoneCore

// MARK: - VPhoneCreateError

/// Failure points across the native `vm create` pipeline — the `die()` call
/// sites of `scripts/setup_machine.sh`'s `main()` / `load_device_identity` /
/// `wait_for_recovery` / `wait_for_first_boot_prompt_auto` / `run_boot_analysis`.
private enum VPhoneCreateError: Error, CustomStringConvertible {
    case nestedVirtualization
    case unknownVariant(String)
    case lessRequiresRoot
    case fwPrepareFailed(Int32)
    case identityTimedOut(URL)
    case invalidUDID(String)
    case invalidECID(String)
    case udidECIDMismatch(udid: String, ecid: String)
    case recoveryTimeout
    case restoreGetSHSHFailed(Int32)
    case restoreUpdateFailed(Int32)
    case cfwInstallFailed(Int32)
    case firstBootPanic
    case firstBootExitedBeforePrompt(Int32)
    case bootAnalysisPanic
    case bootAnalysisExited(Int32)
    case bootAnalysisTimeout
    case lessBootFailed(Int32)

    var description: String {
        switch self {
        case .nestedVirtualization:
            "Virtualization.framework guest boot is unavailable inside a VM — run vm create on a non-nested macOS 15+ host"
        case let .unknownVariant(v):
            "unknown variant '\(v)' (regular|dev|jb|exp|less)"
        case .lessRequiresRoot:
            "fw patch for 'less' must be run as root (matches Makefile's `fw_patch_less must be run via sudo`)"
        case let .fwPrepareFailed(code):
            "fw prepare failed (exit \(code))"
        case let .identityTimedOut(path):
            "missing \(path.path); rebuild and retry to regenerate it"
        case let .invalidUDID(v):
            "invalid UDID in udid-prediction.txt: '\(v)'"
        case let .invalidECID(v):
            "invalid ECID in udid-prediction.txt: '\(v)'"
        case let .udidECIDMismatch(udid, ecid):
            "UDID/ECID mismatch in udid-prediction.txt: \(udid) vs 0x\(ecid)"
        case .recoveryTimeout:
            "timed out waiting for the recovery/DFU endpoint"
        case let .restoreGetSHSHFailed(code):
            "restore-get-shsh failed (exit \(code))"
        case let .restoreUpdateFailed(code):
            "restore-update failed (exit \(code))"
        case let .cfwInstallFailed(code):
            "CFW install failed (exit \(code))"
        case .firstBootPanic:
            "first boot panicked before command injection"
        case let .firstBootExitedBeforePrompt(code):
            "first boot exited before command injection (exit \(code))"
        case .bootAnalysisPanic:
            "boot analysis: panic detected"
        case let .bootAnalysisExited(code):
            "boot analysis: process exited before success marker (exit \(code))"
        case .bootAnalysisTimeout:
            "boot analysis timed out"
        case let .lessBootFailed(code):
            "start VM (less) failed (exit \(code))"
        }
    }
}

extension VPhoneCreateError: LocalizedError {
    var errorDescription: String? { description }
}

// MARK: - VPhoneCreateOrchestrator

/// Native port of `scripts/setup_machine.sh`'s `main()` — runs the full
/// `vm create` pipeline (prepare → patch → restore → CFW → first boot → boot
/// analysis) with no `make`/`setup_machine.sh` shell-out.
///
/// Lives in the EXECUTABLE target rather than VPhoneCore because it composes
/// `FirmwarePatcher.FirmwarePipeline`, and `FirmwarePatcher` already depends on
/// `VPhoneCore` (Package.swift) — VPhoneCore importing FirmwarePatcher back
/// would be a package dependency cycle. The regex/ECID primitives this type
/// needs to be independently unit-testable live in VPhoneCore instead, as
/// `VPhoneBootPatterns`, where `VPhoneCoreTests` (which depends only on
/// VPhoneCore) can reach them.
public struct VPhoneCreateOrchestrator {
    public struct Options {
        public var name: String
        public var variant: String
        public var iphoneSource: String?
        public var cloudosSource: String?
        public var sudoPassword: String?
        public var spoofBuild: String?
        public var forceDSCMaxSlide: Bool
        public var interactive: Bool
        public var cpuCount: UInt
        public var memoryMB: UInt64
        public var diskSizeGB: UInt64
        public var verbosity: VPhoneVerbosity

        public init(
            name: String,
            variant: String,
            iphoneSource: String? = nil,
            cloudosSource: String? = nil,
            sudoPassword: String? = nil,
            spoofBuild: String? = nil,
            forceDSCMaxSlide: Bool = false,
            interactive: Bool = false,
            cpuCount: UInt = 8,
            memoryMB: UInt64 = 8192,
            diskSizeGB: UInt64 = 64,
            verbosity: VPhoneVerbosity = .quiet
        ) {
            self.name = name
            self.variant = variant
            self.iphoneSource = iphoneSource
            self.cloudosSource = cloudosSource
            self.sudoPassword = sudoPassword
            self.spoofBuild = spoofBuild
            self.forceDSCMaxSlide = forceDSCMaxSlide
            self.interactive = interactive
            self.cpuCount = cpuCount
            self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB
            self.verbosity = verbosity
        }
    }

    private let library: VPhoneLibrary
    private let resources: VPhoneResources
    private let selfExecutable: URL

    public init(library: VPhoneLibrary, resources: VPhoneResources, selfExecutable: URL) {
        self.library = library
        self.resources = resources
        self.selfExecutable = selfExecutable
    }

    // MARK: - run

    public func run(_ options: Options) throws {
        let v = options.verbosity
        // Fail fast on a nested-VM host — PV=3 guest boot can't nest, and the whole
        // create pipeline (download + patch + restore) is wasted otherwise. Mirrors
        // the boot_host_preflight gate that `make boot` applied.
        if try Self.isNestedVMHost() {
            throw VPhoneCreateError.nestedVirtualization
        }

        guard let variantOption = PatchFirmwareCLI.VariantOption(rawValue: options.variant) else {
            throw VPhoneCreateError.unknownVariant(options.variant)
        }
        let isLess = variantOption == .less

        let bundleURL = library.url(forName: options.name)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw VPhoneLibraryError.alreadyExists(name: options.name)
        }

        // setup_sudo_noninteractive: preload an askpass helper so CFW install's
        // internal `sudo -A` re-exec can run unattended.
        var sudoEnvExtras: [String: String] = [:]
        var askpassScript: URL?
        defer { if let askpassScript { try? FileManager.default.removeItem(at: askpassScript) } }
        if let password = options.sudoPassword, !password.isEmpty {
            let script = try makeSudoAskpassScript(password: password)
            askpassScript = script
            sudoEnvExtras = ["SUDO_ASKPASS": script.path, "SUDO_PASSWORD": password]
            preloadSudoCredential(env: sudoEnvExtras, verbosity: v)
        }

        print("\n=== vm new ===")
        let spec = VPhoneBundleOps.NewBundleSpec(
            name: options.name, cpuCount: options.cpuCount, memoryMB: options.memoryMB,
            diskSizeGB: options.diskSizeGB,
            romSource: VPhoneBundleOps.defaultROMSource(), sepromSource: VPhoneBundleOps.defaultSEPROMSource())
        let bundle = try VPhoneBundleOps.create(spec, in: library)
        print("created \(bundle.url.path)")

        print("\n=== fw prepare ===")
        try runFWPrepare(options: options, isLess: isLess, bundleURL: bundleURL)

        print("\n=== fw patch ===")
        try runFWPatch(variant: variantOption, isLess: isLess, bundleURL: bundleURL, verbosity: v)

        print("\n=== Restore phase ===")
        try runRestorePhase(bundleURL: bundleURL, verbosity: v)

        if !isLess {
            print("[*] Waiting 5s for cleanup before CFW install...")
            Thread.sleep(forTimeInterval: 5)
            print("\n=== CFW install (host-mount) ===")
            try runCFWInstall(options: options, bundleURL: bundleURL, sudoEnvExtras: sudoEnvExtras)
        }

        print("\n=== First boot ===")
        try runFirstBoot(options: options, isLess: isLess, bundleURL: bundleURL)

        if variantOption == .jb || variantOption == .exp {
            print("\n=== JB Finalize ===")
            print("[*] JB finalization will run automatically on first normal boot")
            print("    via /cores/vphone_jb_setup.sh (LaunchDaemon).")
            print("    Monitor progress via vphoned file browser: /var/log/vphone_jb_setup.log")
        }

        print("\n=== Done ===")
        print("Setup completed.")

        print("\n=== Boot analysis ===")
        if isLess {
            try startVMForeground(bundleURL: bundleURL, verbosity: v)
        } else {
            try runBootAnalysis(bundleURL: bundleURL, verbosity: v)
        }
    }

    // MARK: - trace

    /// Internal spawn/outcome trace, gated on `.trace` (`-vvv`). Never prints
    /// secret env VALUES (e.g. SUDO_PASSWORD) — callers pass only key names.
    private func trace(_ msg: String, _ v: VPhoneVerbosity) {
        guard v.tracesInternals else { return }
        print("[trace] \(msg)")
    }

    /// `-v` repeated `min(v.rawValue, 2)` times, for the pmd3 bridge's own
    /// `--verbose`/`-v` count option (`.info`→1 INFO / pmd3's colorful default,
    /// `.debug`/`.trace`→2 DEBUG). `-v` on `vm create` thus surfaces the pmd3
    /// restore logs, which is the whole point of asking for verbosity.
    private func pmd3VerbosityArgs(_ v: VPhoneVerbosity) -> [String] {
        Array(repeating: "-v", count: min(v.rawValue, 2))
    }

    // MARK: - nested-VM preflight

    /// True when running inside an Apple VM (`kern.hv_vmm_present == 1`),
    /// where Virtualization.framework PV=3 guest boot is unavailable.
    static func isNestedVMHost() throws -> Bool {
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", "kern.hv_vmm_present"])
        return VPhoneBootPatterns.parseHVVmmPresent(r.stdout)
    }

    // MARK: - sudo askpass

    private func makeSudoAskpassScript(password: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-sudo-askpass-\(UUID().uuidString)")
        let script = "#!/bin/sh\nprintf '%s\\n' \"${SUDO_PASSWORD:-}\"\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func preloadSudoCredential(env extras: [String: String], verbosity v: VPhoneVerbosity) {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extras { env[key] = value }
        trace("spawn /usr/bin/sudo -A -v (env keys added: \(extras.keys.sorted().joined(separator: ", ")))", v)
        let result = try? VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/sudo"), ["-A", "-v"], env: env)
        if result?.succeeded == true {
            print("[+] sudo credential preloaded via SUDO_PASSWORD")
        } else {
            print("[!] SUDO_PASSWORD provided but sudo -A validation failed; continuing without preload")
        }
    }

    // MARK: - fw prepare / fw patch

    private func runFWPrepare(options: Options, isLess: Bool, bundleURL: URL) throws {
        let v = options.verbosity
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        if let iphoneSource = options.iphoneSource { env["IPHONE_SOURCE"] = iphoneSource }
        if let cloudosSource = options.cloudosSource { env["CLOUDOS_SOURCE"] = cloudosSource }
        env["VPHONE_PYTHON"] = try resources.pythonExecutable().path
        env["IPSW_DIR"] = resources.ipswCacheDir.path
        env["VPHONE_SEAL_DIR"] = resources.sealVolumeCacheDir.path
        if isLess { env["VARIANT"] = "less" }

        trace("spawn /bin/bash \(resources.fwPrepareScript.path) (env keys: VPHONE_PYTHON, IPSW_DIR, VPHONE_SEAL_DIR)", v)
        let code = try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/bash"), [resources.fwPrepareScript.path], cwd: bundleURL, env: env,
            echo: v.showsToolDetail)
        guard code == 0 else { throw VPhoneCreateError.fwPrepareFailed(code) }
        print("[+] Firmware prepared (iPhone + cloudOS merged into bundle).")
    }

    private func runFWPatch(
        variant: PatchFirmwareCLI.VariantOption, isLess: Bool, bundleURL: URL, verbosity v: VPhoneVerbosity
    ) throws {
        // Mirrors the Makefile's `ifeq ($(UID),0)` gate on `fw_patch_less` —
        // only the `less` variant requires root.
        if isLess, getuid() != 0 {
            throw VPhoneCreateError.lessRequiresRoot
        }

        // In-process pipeline (no subprocess) — CryptexFilesystemPatcher's
        // apfs_sealvolume read honors VPHONE_SEAL_DIR from *this* process's
        // environment, so set it here to agree with `fw prepare`'s write.
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        setenv("VPHONE_SEAL_DIR", resources.sealVolumeCacheDir.path, 1)

        trace("in-process FirmwarePipeline.patchAll variant=\(variant.rawValue)", v)
        let pipeline = FirmwarePipeline(
            vmDirectory: bundleURL, variant: variant.pipelineVariant, verbose: v.showsToolDetail,
            noBinpack: false, noVphoned: false, forceExcGuard: false)
        let records = try pipeline.patchAll()
        print("[fw patch] applied \(records.count) patches for \(variant.rawValue)")
    }

    // MARK: - restore phase

    private func runRestorePhase(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        print("[*] Starting DFU boot in background...")
        // Guest serial is never teed during `vm create` (echo: false); the
        // managed process still reads it internally for panic/prompt matching.
        trace("spawn \(selfExecutable.path) --config \(configURL.path) --dfu (guest serial: off)", v)
        let dfu = VPhoneManagedProcess(
            selfExecutable, ["--config", configURL.path, "--dfu"], cwd: bundleURL, echo: false)
        try dfu.start()
        defer { dfu.terminate() }

        let (udid, ecid) = try loadDeviceIdentity(bundleURL: bundleURL)
        print("[+] Device identity loaded: UDID=\(udid) ECID=0x\(ecid)")

        try waitForRecovery(ecid: ecid, verbosity: v)

        let python = try resources.pythonExecutable()
        let verbosityArgs = pmd3VerbosityArgs(v)
        print("[*] Fetching SHSH blob...")
        let shshArgs =
            [resources.pmd3Bridge.path, "restore-get-shsh", "--vm-dir", ".", "--udid", udid, "--ecid", "0x\(ecid)"]
            + verbosityArgs
        trace("spawn \(python.path) \(shshArgs.joined(separator: " "))", v)
        let shshCode = try VPhoneProcessRunner.runStreaming(python, shshArgs, cwd: bundleURL, echo: v.showsToolDetail)
        guard shshCode == 0 else { throw VPhoneCreateError.restoreGetSHSHFailed(shshCode) }

        print("[*] Restoring...")
        let restoreArgs =
            [resources.pmd3Bridge.path, "restore-update", "--vm-dir", ".", "--udid", udid, "--ecid", "0x\(ecid)"]
            + verbosityArgs
        trace("spawn \(python.path) \(restoreArgs.joined(separator: " "))", v)
        let restoreCode = try VPhoneProcessRunner.runStreaming(
            python, restoreArgs, cwd: bundleURL, echo: v.showsToolDetail)
        guard restoreCode == 0 else { throw VPhoneCreateError.restoreUpdateFailed(restoreCode) }

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

    private func loadDeviceIdentity(bundleURL: URL) throws -> (udid: String, ecid: String) {
        let predictionFile = bundleURL.appendingPathComponent("udid-prediction.txt")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: predictionFile.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        guard FileManager.default.fileExists(atPath: predictionFile.path) else {
            throw VPhoneCreateError.identityTimedOut(predictionFile)
        }

        let text = (try? String(contentsOf: predictionFile, encoding: .utf8)) ?? ""
        var udid = ""
        var ecid = ""
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq]
            let value = String(line[line.index(after: eq)...])
            if key == "UDID" { udid = value.uppercased() }
            if key == "ECID" { ecid = VPhoneBootPatterns.normalizeECID(value) ?? "" }
        }

        guard udid.range(of: "^[0-9A-F]{8}-[0-9A-F]{16}$", options: .regularExpression) != nil else {
            throw VPhoneCreateError.invalidUDID(udid)
        }
        if ecid.isEmpty {
            ecid = udid.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        }
        guard ecid.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil else {
            throw VPhoneCreateError.invalidECID(ecid)
        }
        let udidSuffix = udid.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        guard udidSuffix == ecid else {
            throw VPhoneCreateError.udidECIDMismatch(udid: udid, ecid: ecid)
        }
        return (udid, ecid)
    }

    private func waitForRecovery(ecid: String, verbosity v: VPhoneVerbosity) throws {
        print("[*] Waiting for recovery/DFU endpoint...")
        let python = try resources.pythonExecutable()
        for _ in 1...90 {
            let result = try? VPhoneProcessRunner.runCapturing(
                python, [resources.pmd3Bridge.path, "recovery-probe", "--ecid", "0x\(ecid)", "--timeout", "2"])
            if result?.succeeded == true {
                print("[+] Device endpoint is reachable")
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        trace("recovery-probe: exhausted 90 retries", v)
        throw VPhoneCreateError.recoveryTimeout
    }

    // MARK: - CFW install

    private func runCFWInstall(options: Options, bundleURL: URL, sudoEnvExtras: [String: String]) throws {
        let v = options.verbosity
        var env = ProcessInfo.processInfo.environment
        if let spoofBuild = options.spoofBuild { env["SPOOF_BUILD"] = spoofBuild }
        if options.forceDSCMaxSlide { env["FORCE_DSC_MAXSLIDE"] = "1" }
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        env["VPHONE_PYTHON"] = try resources.pythonExecutable().path
        env["IPSW_DIR"] = resources.ipswCacheDir.path
        env["VPHONE_SEAL_DIR"] = resources.sealVolumeCacheDir.path
        for (key, value) in sudoEnvExtras { env[key] = value }

        let args = [resources.cfwInstallHostScript.path, "--variant", options.variant, bundleURL.path]
        let envKeys = (["VPHONE_PYTHON", "IPSW_DIR", "VPHONE_SEAL_DIR"] + sudoEnvExtras.keys.sorted()).joined(separator: ", ")
        trace("spawn /bin/zsh \(args.joined(separator: " ")) (env keys: \(envKeys))", v)
        let code = try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/zsh"), args, env: env, echo: v.showsToolDetail)
        guard code == 0 else { throw VPhoneCreateError.cfwInstallFailed(code) }
        print("[+] CFW installed (\(options.variant)).")
    }

    // MARK: - first boot

    private func runFirstBoot(options: Options, isLess: Bool, bundleURL: URL) throws {
        let v = options.verbosity
        let configURL = bundleURL.appendingPathComponent("config.plist")
        var args = ["--config", configURL.path]
        if isLess { args += ["--variant", "less"] }

        if options.interactive {
            print("[*] press Enter to start VM, after the VM has finished booting, press Enter again to finish last stage")
            _ = readLine()
        } else {
            print("[*] non-interactive (default): auto-starting first boot")
        }

        trace("spawn \(selfExecutable.path) \(args.joined(separator: " ")) (guest serial: off)", v)
        let boot = VPhoneManagedProcess(selfExecutable, args, cwd: bundleURL, echo: false)
        try boot.start()
        defer { boot.terminate() }

        if options.interactive {
            print("[*] Press Enter once the VM is fully booted")
            _ = readLine()
        } else {
            let outcome = boot.waitForOutput(matching: VPhoneBootPatterns.panicOrPromptRegex, timeout: 60)
            trace("first-boot managed-process outcome: \(outcome)", v)
            switch outcome {
            case .matched:
                if case .matched = boot.waitForOutput(matching: "(?i:\(VPhoneBootPatterns.panicRegex))", timeout: 0) {
                    print("[-] Panic detected while waiting for first-boot shell prompt.")
                    throw VPhoneCreateError.firstBootPanic
                }
                print("[+] First-boot shell prompt detected")
            case let .exited(code):
                print("[-] make boot exited before first-boot command injection.")
                throw VPhoneCreateError.firstBootExitedBeforePrompt(code)
            case .timedOut:
                print("[!] Shell prompt not detected within 60s; fallback to timed continue.")
            }
        }

        for cmd in VPhoneBootPatterns.firstBootCommands {
            boot.send(cmd)
        }

        print("[*] Commands sent. Waiting for VM shutdown...")
        _ = boot.waitUntilExit()
    }

    // MARK: - boot analysis

    private func runBootAnalysis(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        trace("spawn \(selfExecutable.path) --config \(configURL.path) (guest serial: off)", v)
        let vm = VPhoneManagedProcess(
            selfExecutable, ["--config", configURL.path], cwd: bundleURL, echo: false)
        try vm.start()
        defer { vm.terminate() }

        let outcome = vm.waitForOutput(matching: VPhoneBootPatterns.panicOrPromptRegex, timeout: 300)
        trace("boot-analysis managed-process outcome: \(outcome)", v)
        switch outcome {
        case .matched:
            if case .matched = vm.waitForOutput(matching: "(?i:\(VPhoneBootPatterns.panicRegex))", timeout: 0) {
                print("[-] Boot analysis: panic detected, stopping VM.")
                throw VPhoneCreateError.bootAnalysisPanic
            }
            print("[+] Boot analysis: bash prompt detected, boot success.")
        case let .exited(code):
            print("[-] Boot analysis: VM process exited before success marker.")
            throw VPhoneCreateError.bootAnalysisExited(code)
        case .timedOut:
            print("[-] Boot analysis timeout (300s); stopping VM.")
            throw VPhoneCreateError.bootAnalysisTimeout
        }
    }

    /// `less` variant: `run_make "Start VM" boot_less` — a plain foreground
    /// boot, no panic/prompt analysis (patchless compat mode has no CFW-driven
    /// success marker to watch for).
    private func startVMForeground(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        print("\n=== Start VM ===")
        let args = ["--config", configURL.path, "--variant", "less"]
        trace("spawn \(selfExecutable.path) \(args.joined(separator: " ")) (echo=\(v.showsToolDetail))", v)
        let code = try VPhoneProcessRunner.runStreaming(
            selfExecutable, args, cwd: bundleURL, echo: v.showsToolDetail)
        guard code == 0 else { throw VPhoneCreateError.lessBootFailed(code) }
    }
}
