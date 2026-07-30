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
            throw ExitCode(try pmd3("restore-update", extra: ["--tss", shsh.path]))
        }
        throw ExitCode(try pmd3("restore-update", extra: []))
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

        var env = ProcessInfo.processInfo.environment
        if let spoofBuild { env["SPOOF_BUILD"] = spoofBuild }
        if forceDSCMaxSlide { env["FORCE_DSC_MAXSLIDE"] = "1" }

        // Same redirect as `fw prepare`: VPHONE_PYTHON/IPSW_DIR/VPHONE_SEAL_DIR are
        // exported for the bundled scripts (cfw_install_host.sh's PY/P lines honor
        // VPHONE_PYTHON); the apfs_sealvolume read itself only happens on the
        // `fw patch` path (CryptexFilesystemPatcher).
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.debsCacheDir, withIntermediateDirectories: true)
        env["VPHONE_PYTHON"] = try resources.pythonExecutable().path
        env["IPSW_DIR"] = resources.ipswCacheDir.path
        env["VPHONE_SEAL_DIR"] = resources.sealVolumeCacheDir.path
        env["VPHONE_DEBS_DIR"] = resources.debsCacheDir.path

        let args = [resources.cfwInstallHostScript.path, "--variant", variant, bundle.url.path]
        if v.tracesInternals {
            print("[trace] spawning: /bin/zsh \(args.joined(separator: " ")) (env keys: VPHONE_PYTHON, IPSW_DIR, VPHONE_SEAL_DIR)")
        }
        let code = try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/zsh"), args, env: env, echo: v.showsToolDetail)
        throw ExitCode(code)
    }
}
