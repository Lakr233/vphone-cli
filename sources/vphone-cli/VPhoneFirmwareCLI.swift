import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

struct VPhoneFirmwareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fw",
        abstract: "Firmware pipeline: prepare (download/merge IPSWs) and patch",
        subcommands: [
            VPhoneFirmwareCatalogCommand.self,
            VPhoneFirmwareInspectCommand.self,
            VPhoneFirmwarePrepareCommand.self,
            VPhoneFirmwarePatchCommand.self,
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
        abstract: "Show the known iOS ↔ cloudOS firmware pairings (recommended per iOS build)",
    )

    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let report = VPhoneFirmwareCatalog.report
        if json {
            try print(String(decoding: JSONEncoder().encode(report), as: UTF8.self))
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
    @Option(help: "iPhone version to resolve to an IPSW") var iphoneVersion: String?
    @Option(help: "iPhone build to resolve to an IPSW") var iphoneBuild: String?
    @Flag(help: "List downloadable IPSWs and exit") var list = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let readme = resources.base.appendingPathComponent("docs/guides/compatibility.md").path
        let needsCatalog = list || iphoneVersion != nil || iphoneBuild != nil
        let urls = if needsCatalog {
            try vphoneRunBlocking {
                try await VPhoneFirmwareIndex.restoreURLs(forDevice: "iPhone17,3")
            }.joined(separator: "\n")
        } else {
            ""
        }

        if list {
            let code = VPhoneFirmwareMatrixCommandLine.list(
                device: "iPhone17,3", readmePath: readme, downloadURLs: urls,
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
            let selection = VPhoneFirmwareMatrix.selection(
                device: "iPhone17,3", version: iphoneVersion ?? "", build: iphoneBuild ?? "",
                readme: try? String(contentsOfFile: readme, encoding: .utf8),
                downloadURLs: urls,
                style: .forStream(FileHandle.standardError.fileDescriptor),
            )
            switch selection {
            case let .selected(release, _): source = release.url
            case let .ambiguous(message), let .unmatched(message):
                throw ValidationError(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let selected = try VPhoneFirmwareSourceSelection.resolve(iphone: source, cloudos: cloudosSource)
        guard let phone = selected.iphoneSource, let cloud = selected.cloudosSource else {
            throw ValidationError("Specify both --iphone-source and --cloudos-source when running without a terminal.")
        }
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        try VPhoneFirmwarePreparer.prepare(
            iPhoneSource: phone, cloudOSSource: cloud,
            gpuDriverBundle: gpuDriverBundle.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            bundle: bundle, resources: resources,
        )
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
    @Flag(name: .customLong("force-exc-guard"), help: "Force the EXC_GUARD disable patch") var forceExcGuard = false
    @Flag(name: .customLong("frida"), help: "Opt in to Frida Stalker kernel relaxations (jb/exp only)")
    var frida = false
    @Flag(name: .shortAndLong, help: "Suppress per-component progress") var quiet = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
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
            enableFrida: frida,
        )
        let records = try pipeline.patchAll()
        print("[fw patch] applied \(records.count) JB patches")
    }
}
