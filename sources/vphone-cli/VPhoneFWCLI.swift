import ArgumentParser
import Foundation
import FirmwarePatcher
import VPhoneCore

struct VPhoneFWCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fw",
        abstract: "Firmware pipeline: prepare (download/merge IPSWs) and patch",
        subcommands: [
            VPhoneFWCatalogCommand.self,
            VPhoneFWPrepareCommand.self,
            VPhoneFWPatchCommand.self,
            VPhoneFWManifestCommand.self,
            VPhoneFWListCommand.self,
            VPhoneFWResolveCommand.self,
            VPhoneFWAEAKeyCommand.self,
            VPhoneFWIM4PCreateCommand.self,
            VPhoneFWIM4PExtractCommand.self,
            VPhoneFWURLsCommand.self,
            VPhoneFWSealToolCommand.self,
        ])
}

// MARK: - firmware support matrix

/// Replaces the two Python heredocs that used to live inside
/// `scripts/fw_prepare.sh`. Both read the `DOWNLOADABLE_IPSW_URLS` the shell
/// already sets, so only the language changed; the shell still runs `ipsw`.
///
/// Neither writes through `print`: `list` styles stdout and `resolve` styles
/// stderr, and colour is only right if each descriptor is asked separately.
struct VPhoneFWListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Print the downloadable-firmware support matrix for a device"
    )

    @Option(help: "Device identifier, e.g. iPhone17,3") var device: String
    @Option(help: "README.md holding the 'Tested Environments' table") var readme: String

    func run() throws {
        let code = VPhoneFirmwareMatrixCommandLine.list(
            device: device,
            readmePath: readme,
            downloadURLs: ProcessInfo.processInfo.environment["DOWNLOADABLE_IPSW_URLS"] ?? ""
        )
        if code != 0 { throw ExitCode(code) }
    }
}

struct VPhoneFWResolveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Resolve a version/build selector to a downloadable IPSW URL",
        discussion: """
        Prints version<TAB>build<TAB>url<TAB>status on stdout, which fw_prepare.sh
        reads back with `IFS=$'\\t' read -r`.

        Exits 2 — not 1 — when a bare version matches more than one build, so a
        caller can tell "pick a build" from "there is no such firmware". An empty
        --version or --build means unconstrained.
        """
    )

    @Option(help: "Device identifier, e.g. iPhone17,3") var device: String
    @Option(help: "iOS version to match; empty matches any") var version: String = ""
    @Option(help: "Build to match; empty matches any") var build: String = ""
    @Option(help: "README.md holding the 'Tested Environments' table") var readme: String

    func run() throws {
        let code = VPhoneFirmwareMatrixCommandLine.resolve(
            device: device,
            version: version,
            build: build,
            readmePath: readme,
            downloadURLs: ProcessInfo.processInfo.environment["DOWNLOADABLE_IPSW_URLS"] ?? ""
        )
        if code != 0 { throw ExitCode(code) }
    }
}

// MARK: - manifest

/// Replaces `scripts/fw_manifest.py`, called from `fw_prepare.sh` once both
/// IPSWs are extracted and merged.
struct VPhoneFWManifestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Write the hybrid BuildManifest.plist and Restore.plist into the iPhone directory",
        discussion: """
        Merges the cloudOS boot chain (vresearch101ap, which is what the VM
        identifies as in DFU) with vphone600 runtime components and the iPhone
        OS images into a single DFU erase-install build identity.

        Both files are written into <iphone-dir>, replacing what is there.
        fw_prepare.sh keeps the original as iPhone-BuildManifest.plist first.
        """
    )

    @Argument(
        help: "Extracted iPhone IPSW directory — also where the output is written",
        transform: URL.init(fileURLWithPath:)
    )
    var iPhoneDirectory: URL

    @Argument(
        help: "Extracted cloudOS IPSW directory",
        transform: URL.init(fileURLWithPath:)
    )
    var cloudOSDirectory: URL

    @Flag(name: .shortAndLong, help: "Print which identities were selected")
    var verbose = false

    func run() throws {
        try FirmwareManifest.generate(
            iPhoneDir: iPhoneDirectory,
            cloudOSDir: cloudOSDirectory,
            verbose: true
        )
    }
}

// MARK: - catalog

struct VPhoneFWCatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "Show the known iOS ↔ cloudOS firmware pairings (recommended per iOS build)"
    )

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
        commandName: "prepare",
        abstract: "Download + merge IPSWs into a VM bundle"
    )

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

        // Redirect the two things a read-only bundle can't provide (IPSW cache,
        // extracted apfs_sealvolume) to the writable user cache. No Python:
        // fw_prepare.sh's last heredocs moved into `fw list` / `fw resolve`.
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        env["IPSW_DIR"] = resources.ipswCacheDir.path
        env["VPHONE_SEAL_DIR"] = resources.sealVolumeCacheDir.path

        if v.tracesInternals {
            print("[trace] spawning: /bin/bash \(resources.fwPrepareScript.path) (env keys: IPSW_DIR, VPHONE_SEAL_DIR)")
        }
        let code = try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/bash"),
            [resources.fwPrepareScript.path],
            cwd: bundle.url,
            env: env,
            echo: v.showsToolDetail
        )
        throw ExitCode(code)
    }
}

// MARK: - patch

struct VPhoneFWPatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch",
        abstract: "Patch the boot chain (native Swift FirmwarePipeline)"
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .customLong("force-exc-guard"), help: "Force the EXC_GUARD disable patch") var forceExcGuard = false
    @Flag(name: .customLong("frida"), help: "Opt in to Frida Stalker kernel relaxations (jb/exp only)")
    var frida = false
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
            variant: .jb,
            verbose: !quiet,
            noBinpack: true,
            forceExcGuard: forceExcGuard,
            enableFrida: frida
        )
        let records = try pipeline.patchAll()
        print("[fw patch] applied \(records.count) JB patches")
    }
}
