import ArgumentParser
import Foundation
import FirmwarePatcher
import VPhoneCore

struct VPhoneFWCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fw",
        abstract: "Firmware pipeline: prepare (download/merge IPSWs) and patch",
        subcommands: [VPhoneFWCatalogCommand.self, VPhoneFWPrepareCommand.self, VPhoneFWPatchCommand.self])
}

// MARK: - catalog

struct VPhoneFWCatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "Show the known iOS ↔ cloudOS firmware pairings (recommended per iOS build)")

    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let report = VPhoneFirmwareCatalog.report
        if json {
            print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            return
        }
        print("Firmware catalog (\(report.device))")
        let width = report.pairings.map(\.ios.name.count).max() ?? 0
        let header = "iOS".padding(toLength: width, withPad: " ", startingAt: 0)
        print("\(header)  recommended cloudOS")
        for e in report.pairings {
            let ios = e.ios.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(ios)  \(e.recommendedCloudOS.name)")
        }
    }
}

// MARK: - prepare

struct VPhoneFWPrepareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare", abstract: "Download + merge IPSWs into a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(help: "iPhone version to resolve to an IPSW") var iphoneVersion: String?
    @Option(help: "iPhone build to resolve to an IPSW") var iphoneBuild: String?
    @Flag(help: "List downloadable IPSWs and exit") var list = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()

        var env = ProcessInfo.processInfo.environment
        if let iphoneSource { env["IPHONE_SOURCE"] = iphoneSource }
        if let cloudosSource { env["CLOUDOS_SOURCE"] = cloudosSource }
        if let iphoneVersion { env["IPHONE_VERSION"] = iphoneVersion }
        if let iphoneBuild { env["IPHONE_BUILD"] = iphoneBuild }
        if list { env["LIST_FIRMWARES"] = "1" }

        // Redirect the three things a read-only bundle can't provide (python,
        // IPSW cache, extracted apfs_sealvolume) to the writable user cache.
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        env["VPHONE_PYTHON"] = try resources.pythonExecutable().path
        env["IPSW_DIR"] = resources.ipswCacheDir.path
        env["VPHONE_SEAL_DIR"] = resources.sealVolumeCacheDir.path

        if v.tracesInternals {
            print("[trace] spawning: /bin/bash \(resources.fwPrepareScript.path) (env keys: VPHONE_PYTHON, IPSW_DIR, VPHONE_SEAL_DIR)")
        }
        let code = try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/bash"), [resources.fwPrepareScript.path], cwd: bundle.url, env: env,
            echo: v.showsToolDetail)
        throw ExitCode(code)
    }
}

// MARK: - patch

struct VPhoneFWPatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch", abstract: "Patch the boot chain (native Swift FirmwarePipeline)")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp | less") var variant: PatchFirmwareCLI.VariantOption = .regular
    @Flag(name: .customLong("force-exc-guard"), help: "Force the EXC_GUARD disable patch") var forceExcGuard = false
    @Flag(name: .customLong("frida"), help: "Opt in to Frida Stalker kernel relaxations (jb/exp only)") var frida = false
    @Flag(name: .shortAndLong, help: "Suppress per-component progress") var quiet = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)

        // In-process pipeline (no subprocess) — CryptexFilesystemPatcher's
        // apfs_sealvolume read honors VPHONE_SEAL_DIR from *this* process's
        // environment, so set it here to agree with `fw prepare`'s write.
        let resources = VPhoneResources.resolve()
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        setenv("VPHONE_SEAL_DIR", resources.sealVolumeCacheDir.path, 1)

        let pipeline = FirmwarePipeline(
            vmDirectory: bundle.url,
            variant: variant.pipelineVariant,
            verbose: !quiet,
            noBinpack: false,
            noVphoned: false,
            forceExcGuard: forceExcGuard,
            enableFrida: frida)
        let records = try pipeline.patchAll()
        print("[fw patch] applied \(records.count) patches for \(variant.rawValue)")
    }
}
