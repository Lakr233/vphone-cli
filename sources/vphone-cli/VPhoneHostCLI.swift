import ArgumentParser
import FirmwarePatcher
import Foundation

extension VPhoneVirtualMachineManifest.PlatformFusing: ExpressibleByArgument {}

struct GenerateVMManifestCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-vm-manifest",
        abstract: "Generate config.plist for a VM directory"
    )

    @Option(name: .customLong("vm-dir"), help: "VM directory path.", transform: URL.init(fileURLWithPath:))
    var vmDirectory: URL = URL(fileURLWithPath: "vm", isDirectory: true)

    @Option(help: "CPU core count.")
    var cpu: Int = 8

    @Option(help: "Memory size in MB.")
    var memory: Int = 8192

    @Option(name: .customLong("platform-fusing"), help: "Platform fusing mode.")
    var platformFusing: VPhoneVirtualMachineManifest.PlatformFusing?

    mutating func run() throws {
        guard cpu > 0 else {
            throw ValidationError("CPU must be > 0")
        }
        guard memory > 0 else {
            throw ValidationError("Memory must be > 0")
        }

        let manifest = VPhoneVirtualMachineManifest(
            platformFusing: platformFusing,
            cpuCount: UInt(cpu),
            memorySize: UInt64(memory) * 1024 * 1024,
            romImages: .init(
                avpBooter: "AVPBooter.vresearch1.bin",
                avpSEPBooter: "AVPSEPBooter.vresearch1.bin"
            )
        )
        try manifest.write(to: vmDirectory.appendingPathComponent("config.plist"))
        print("[vm-manifest] wrote \(vmDirectory.appendingPathComponent("config.plist").path)")
    }
}

struct VMCreateCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm-create",
        abstract: "Create a new VM directory with disk, ROM copies, and config.plist"
    )

    @Option(name: .customLong("dir"), help: "VM directory path.", transform: URL.init(fileURLWithPath:))
    var directory: URL = URL(fileURLWithPath: "vm", isDirectory: true)

    @Option(name: .customLong("disk-size"), help: "Disk image size in GB.")
    var diskSizeGB: Int = 64

    @Option(help: "CPU core count.")
    var cpu: Int = 8

    @Option(help: "Memory size in MB.")
    var memory: Int = 8192

    @Option(help: "Path to AVPBooter ROM.", transform: URL.init(fileURLWithPath:))
    var rom: URL?

    @Option(help: "Path to AVPSEPBooter ROM.", transform: URL.init(fileURLWithPath:))
    var seprom: URL?

    @Option(name: .customLong("platform-fusing"), help: "Platform fusing mode.")
    var platformFusing: VPhoneVirtualMachineManifest.PlatformFusing?

    mutating func run() async throws {
        guard diskSizeGB > 0 else {
            throw ValidationError("disk-size must be > 0")
        }
        guard cpu > 0 else {
            throw ValidationError("cpu must be > 0")
        }
        guard memory > 0 else {
            throw ValidationError("memory must be > 0")
        }

        let frameworkROMDirectory = URL(fileURLWithPath: "/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources", isDirectory: true)
        let romSource = rom ?? frameworkROMDirectory.appendingPathComponent("AVPBooter.vresearch1.bin")
        let sepromSource = seprom ?? frameworkROMDirectory.appendingPathComponent("AVPSEPBooter.vresearch1.bin")

        try VPhoneHost.requireFile(romSource)
        try VPhoneHost.requireFile(sepromSource)

        let diskSizeBytes = UInt64(diskSizeGB) * 1024 * 1024 * 1024
        let sepStorageSize = 512 * 1024
        let fileManager = FileManager.default

        print("=== vphone create_vm ===")
        print("Directory : \(directory.path)")
        print("Disk size : \(diskSizeGB) GB")
        print("AVPBooter : \(romSource.path)")
        print("AVPSEPBooter: \(sepromSource.path)")
        print("")

        let existedBefore = fileManager.fileExists(atPath: directory.path)
        if !existedBefore {
            print("[1/5] Creating \(directory.path)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            print("WARNING: \(directory.path) already exists")
        }

        let diskURL = directory.appendingPathComponent("Disk.img")
        if !fileManager.fileExists(atPath: diskURL.path) {
            print("[2/5] Creating sparse disk image (\(diskSizeGB) GB)")
            try VPhoneHost.createSparseFile(at: diskURL, size: diskSizeBytes)
            let values = try diskURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize {
                print("  -> \(diskURL.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)))")
            }
        } else {
            print("[2/5] Disk.img exists — skipping")
        }

        let sepStorageURL = directory.appendingPathComponent("SEPStorage")
        if !fileManager.fileExists(atPath: sepStorageURL.path) {
            print("[3/5] Creating SEP storage (512 KB)")
            try VPhoneHost.createZeroFilledFile(at: sepStorageURL, size: sepStorageSize)
        } else {
            print("[3/5] SEPStorage exists — skipping")
        }

        print("[4/5] Copying ROMs")
        let romDestination = directory.appendingPathComponent("AVPBooter.vresearch1.bin")
        let sepromDestination = directory.appendingPathComponent("AVPSEPBooter.vresearch1.bin")
        if try VPhoneHost.copyIfDifferent(from: romSource, to: romDestination) {
            let values = try romDestination.resourceValues(forKeys: [.fileSizeKey])
            print("  \(romDestination.lastPathComponent) — copied (\(values.fileSize ?? 0) bytes)")
        } else {
            print("  \(romDestination.lastPathComponent) — up to date")
        }
        if try VPhoneHost.copyIfDifferent(from: sepromSource, to: sepromDestination) {
            let values = try sepromDestination.resourceValues(forKeys: [.fileSizeKey])
            print("  \(sepromDestination.lastPathComponent) — copied (\(values.fileSize ?? 0) bytes)")
        } else {
            print("  \(sepromDestination.lastPathComponent) — up to date")
        }

        print("[5/5] Generating VM manifest (config.plist)")
        let manifest = VPhoneVirtualMachineManifest(
            platformFusing: platformFusing,
            cpuCount: UInt(cpu),
            memorySize: UInt64(memory) * 1024 * 1024,
            romImages: .init(
                avpBooter: romDestination.lastPathComponent,
                avpSEPBooter: sepromDestination.lastPathComponent
            )
        )
        try manifest.write(to: directory.appendingPathComponent("config.plist"))
        try VPhoneHost.writeEmptyFile(at: directory.appendingPathComponent(".gitkeep"))

        print("")
        print("=== VM created at \(directory.path) ===")
        print("Next steps:")
        print("  1. Prepare firmware:  make fw_prepare")
        print("  2. Patch firmware:    make fw_patch")
        print("  3. Boot DFU:          make boot_dfu")
        print("  4. Boot normal:       make boot")
    }
}

struct GenerateFirmwareManifestCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-firmware-manifest",
        abstract: "Generate the hybrid BuildManifest.plist and Restore.plist"
    )

    @Option(name: .customLong("iphone-dir"), help: "Path to the extracted iPhone IPSW directory.", transform: URL.init(fileURLWithPath:))
    var iPhoneDirectory: URL

    @Option(name: .customLong("cloudos-dir"), help: "Path to the extracted cloudOS IPSW directory.", transform: URL.init(fileURLWithPath:))
    var cloudOSDirectory: URL

    @Flag(name: .customLong("quiet"), help: "Suppress progress output.")
    var quiet: Bool = false

    mutating func run() throws {
        try FirmwareManifest.generate(
            iPhoneDir: iPhoneDirectory,
            cloudOSDir: cloudOSDirectory,
            verbose: !quiet
        )
    }
}

struct BootHostPreflightCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot-host-preflight",
        abstract: "Diagnose whether the host can launch the signed PV=3 binary"
    )

    @Flag(name: .customLong("assert-bootable"), help: "Fail if the signed release binary is not launchable.")
    var assertBootable: Bool = false

    @Flag(name: .customLong("quiet"), help: "Reduce output.")
    var quiet: Bool = false

    @Option(name: .customLong("project-root"), help: "Project root path.", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    mutating func run() async throws {
        let root = projectRoot
        let releaseBinary = root.appendingPathComponent(".build/release/vphone-cli")
        let debugBinary = root.appendingPathComponent(".build/debug/vphone-cli")
        let entitlements = root.appendingPathComponent("sources/vphone.entitlements")
        let tempDirectory = try VPhoneHost.tempDirectory(prefix: "vphone-preflight")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let signedDebug = tempDirectory.appendingPathComponent("vphone-cli.debug.signed")

        func printSection(_ title: String) {
            guard !quiet else { return }
            print("")
            print("=== \(title) ===")
        }

        func printResult(_ label: String, _ result: VPhoneCommandResult) {
            guard !quiet else { return }
            print("[\(label)] exit=\(VPhoneHost.exitCode(from: result.terminationStatus))")
            for line in VPhoneHost.outputLines(result) {
                print(line)
            }
        }

        let modelName = try VPhoneSystem.sysctlString("hw.model").trimmingCharacters(in: .whitespacesAndNewlines)
        let hvVmmPresent = try VPhoneSystem.sysctlString("kern.hv_vmm_present").trimmingCharacters(in: .whitespacesAndNewlines)
        let sipStatus = VPhoneHost.stringValue(try await VPhoneHost.runCommand("/usr/bin/csrutil", arguments: ["status"]))
        let researchGuestStatus = VPhoneHost.stringValue(try await VPhoneHost.runCommand("/usr/bin/csrutil", arguments: ["allow-research-guests", "status"]))
        let currentBootArgs = try VPhoneSystem.sysctlString("kern.bootargs").trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBootArgs = VPhoneHost.stringValue(try await VPhoneHost.runCommand("/usr/sbin/nvram", arguments: ["boot-args"]))
            .replacingOccurrences(of: "boot-args", with: "")
            .trimmingCharacters(in: .whitespaces)
        let assessmentStatus = VPhoneHost.stringValue(try await VPhoneHost.runCommand("/usr/sbin/spctl", arguments: ["--status"]))

        printSection("Host")
        if !quiet {
            print(try VPhoneSystem.operatingSystemSummary())
            print("model: \(modelName)")
            print("kern.hv_vmm_present: \(hvVmmPresent)")
            print("SIP: \(sipStatus)")
            print("allow-research-guests: \(researchGuestStatus)")
            print("current kern.bootargs: \(currentBootArgs)")
            print("next-boot nvram boot-args: \(nextBootArgs)")
            print("assessment: \(assessmentStatus)")
        }

        if assertBootable, (hvVmmPresent == "1" || modelName == "Apple Virtual Machine 1") {
            throw ExitCode(3)
        }

        printSection("Entitlements")
        if FileManager.default.fileExists(atPath: releaseBinary.path) {
            do {
                let output = try VPhoneCodeSignature.entitlementsXML(for: releaseBinary)
                printResult("release_entitlements", VPhoneCommandResult(
                    terminationStatus: .exited(0),
                    standardOutput: output,
                    standardError: ""
                ))
            } catch {
                printResult("release_entitlements", VPhoneCommandResult(
                    terminationStatus: .exited(1),
                    standardOutput: "",
                    standardError: String(describing: error)
                ))
            }
        } else if !quiet {
            print("missing release binary: \(releaseBinary.path)")
        }

        printSection("Policy")
        if FileManager.default.fileExists(atPath: releaseBinary.path) {
            let result = try await VPhoneHost.runCommand("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "--verbose=4", releaseBinary.path])
            printResult("spctl", result)
        }

        printSection("Unsigned Debug Binary")
        try VPhoneHost.requireFile(debugBinary)
        let debugHelp = try await VPhoneHost.runCommand(debugBinary.path, arguments: ["--help"])
        printResult("debug_help", debugHelp)

        printSection("Signed Release Binary")
        try VPhoneHost.requireFile(releaseBinary)
        let releaseHelp = try await VPhoneHost.runCommand(releaseBinary.path, arguments: ["--help"])
        printResult("release_help", releaseHelp)

        printSection("Signed Debug Control")
        try FileManager.default.copyItem(at: debugBinary, to: signedDebug)
        try await VPhoneCodeSignature.signAdHoc(binaryURL: signedDebug, entitlementsURL: entitlements)
        let signedDebugHelp = try await VPhoneHost.runCommand(signedDebug.path, arguments: ["--help"])
        printResult("signed_debug_help", signedDebugHelp)

        printSection("Result")
        if !quiet {
            print("If unsigned debug runs but either signed binary exits 137 / signal 9,")
            print("the host is not currently permitting the required private virtualization entitlements.")
            print("If the signed release binary exits 0 but the signed debug control still exits 137,")
            print("a path/CDHash-scoped AMFI bypass may already be active for this repo.")
        }

        if assertBootable, !releaseHelp.terminationStatus.isSuccess {
            throw ExitCode(Int32(VPhoneHost.exitCode(from: releaseHelp.terminationStatus)))
        }
    }
}
