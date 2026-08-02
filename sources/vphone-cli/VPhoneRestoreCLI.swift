import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - restore

struct VPhoneRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "DFU-restore firmware into a VM bundle (requires a running DFU boot)")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Only fetch the SHSH blob, do not restore") var getShsh = false
    @Flag(name: .shortAndLong, help: "Offline restore (decrypt AEA images in place, use the cached .shsh)") var offline = false
    @Option(name: .shortAndLong, help: "Device UDID (optional)") var udid: String?
    @Option(name: .shortAndLong, help: "Device ECID (default: read from the bundle's udid-prediction.txt)") var ecid: String?
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        guard let ecidValue = VPhoneRestoreOps.resolveECID(explicit: ecid, bundle: bundle) else {
            throw VPhoneRestoreError.ecidUnresolved
        }

        func pmd3(_ subcommand: String, extra: [String]) throws -> Int32 {
            var args = [resources.pmd3Bridge.path, subcommand, "--vm-dir", "."]
            if let udid { args += ["--udid", udid] }
            args += ["--ecid", ecidValue] + extra
            // -v (.info) → pmd3 INFO (its colorful log level), -vv/-vvv → DEBUG.
            args += Array(repeating: "-v", count: min(v.rawValue, 2))
            let python = try resources.pythonExecutable()
            if v.tracesInternals {
                print("[trace] spawning: \(python.path) \(args.joined(separator: " "))")
            }
            return try VPhoneProcessRunner.runStreaming(python, args, cwd: bundle.url, echo: v.showsToolDetail)
        }

        if getShsh {
            throw ExitCode(try pmd3("restore-get-shsh", extra: []))
        }

        let code: Int32
        if offline {
            let fm = FileManager.default
            let shshes = ((try? fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "shsh" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let shsh = shshes.first else { throw VPhoneRestoreError.noSHSH }
            let restoreDir = ((try? fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("iPhone") && $0.lastPathComponent.hasSuffix("_Restore") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
            guard let restoreDir else { throw VPhoneRestoreError.noRestoreDir }
            print("[restore] decrypting AEA images in \(restoreDir.lastPathComponent)...")
            try VPhoneRestoreOps.decryptAEAImages(inRestoreDir: restoreDir)
            code = try pmd3("restore-update", extra: ["--tss", shsh.path])
        } else {
            code = try pmd3("restore-update", extra: [])
        }

        if code == 0 { recordRestoreVersions(bundle: bundle) }
        throw ExitCode(code)
    }

    /// Snapshot the just-restored iOS + cloudOS versions to `restore-info.json`,
    /// read host-side from the bundle's restore-dir plists. Best-effort: the
    /// restore already succeeded, so a metadata miss is only a warning.
    private func recordRestoreVersions(bundle: VPhoneBundle) {
        guard let info = VPhoneRestoreInfo.derive(fromBundle: bundle) else {
            FileHandle.standardError.write(Data("warning: could not record restore versions (metadata not found)\n".utf8))
            return
        }
        do {
            try info.write(toBundle: bundle)
            print("[restore] recorded iOS \(info.ios.version) (\(info.ios.build)) / "
                + "cloudOS \(info.cloudOS.version) (\(info.cloudOS.build))")
        } catch {
            FileHandle.standardError.write(Data("warning: could not write restore-info.json: \(error)\n".utf8))
        }
    }
}

// MARK: - cfw

struct VPhoneCFWCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cfw",
        abstract: "Custom-firmware install (host-mount; VM must be off; re-execs sudo)",
        subcommands: [VPhoneCFWInstallCommand.self])
}

struct VPhoneCFWInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install CFW into a VM bundle via host mount")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp") var variant: String = "exp"
    @Option(name: [.customShort("b"), .long], help: "(exp only) rewrite ProductBuildVersion to this build id") var spoofBuild: String?
    @Flag(name: .customLong("force-dsc-maxslide"), help: "Zero the dyld cache maxSlide on non-27 bases (opt-in DSC-map fit)") var forceDSCMaxSlide = false
    @Flag(name: .customLong("root-popup"), help: "Elevate via macOS's native authentication dialog (osascript) instead of the sudo re-exec") var rootPopup = false
    @Flag(name: .customLong("keep-artifacts"), help: "Keep the extracted CFW input dirs (cfw_input/, cfw_jb_input/) after install (default: removed to save space)") var keepArtifacts = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        guard ["regular", "dev", "jb", "exp"].contains(variant) else {
            throw ValidationError("unknown cfw variant '\(variant)' (regular|dev|jb|exp)")
        }
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()

        // Env the bundled scripts read: rides along via `sudo -E` by default;
        // --root-popup forwards it inline (do shell script's bare env).
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.debsCacheDir, withIntermediateDirectories: true)
        var scriptEnv: [String: String] = [
            "VPHONE_PYTHON": try resources.pythonExecutable().path,
            "IPSW_DIR": resources.ipswCacheDir.path,
            "VPHONE_SEAL_DIR": resources.sealVolumeCacheDir.path,
            "VPHONE_DEBS_DIR": resources.debsCacheDir.path,
        ]
        if let spoofBuild { scriptEnv["SPOOF_BUILD"] = spoofBuild }
        if forceDSCMaxSlide { scriptEnv["FORCE_DSC_MAXSLIDE"] = "1" }
        if keepArtifacts { scriptEnv["VPHONE_KEEP_ARTIFACTS"] = "1" }

        let args = [resources.cfwInstallHostScript.path, "--variant", variant, bundle.url.path]
        let code: Int32
        if rootPopup {
            // Forward SUDO_USER (sudo would set it) so the script's chown-back runs.
            scriptEnv["SUDO_USER"] = NSUserName()
            code = try VPhoneProcessRunner.runWithAdminPrivileges(
                URL(fileURLWithPath: "/bin/zsh"), args, env: scriptEnv, echo: v.showsToolDetail)
        } else {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in scriptEnv { env[key] = value }
            if v.tracesInternals {
                print("[trace] spawning: /bin/zsh \(args.joined(separator: " ")) (env keys: VPHONE_PYTHON, IPSW_DIR, VPHONE_SEAL_DIR)")
            }
            code = try VPhoneProcessRunner.runStreaming(
                URL(fileURLWithPath: "/bin/zsh"), args, env: env, echo: v.showsToolDetail)
        }
        if code == 0 {
            if let info = try? VPhoneRestoreInfo.recordVariant(variant, toBundle: bundle), info.variant != nil {
                print("[cfw] recorded variant \(variant), device \(info.device ?? "?")")
            }
            if !keepArtifacts, let removed = try? VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: bundle) {
                print("[cfw] removed built firmware \(removed)/ to save space (--keep-artifacts to keep)")
            }
        }
        throw ExitCode(code)
    }
}
