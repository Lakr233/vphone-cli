import ArgumentParser
import Darwin
import Foundation

struct SetupMachineCLI: AsyncParsableCommand {
    enum Variant: String, ExpressibleByArgument {
        case regular
        case dev
        case jb
    }

    static let configuration = CommandConfiguration(
        commandName: "setup-machine",
        abstract: "Run the first-boot automation pipeline through Swift subcommands"
    )

    @Option(help: "Project root", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    @Option(help: "VM directory")
    var vmDirectory: String = ProcessInfo.processInfo.environment["VM_DIR"] ?? "vm"

    @Option(help: "CPU core count for vm-create")
    var cpu: Int = Int(ProcessInfo.processInfo.environment["CPU"] ?? "8") ?? 8

    @Option(help: "Memory size in MB for vm-create")
    var memory: Int = Int(ProcessInfo.processInfo.environment["MEMORY"] ?? "8192") ?? 8192

    @Option(name: .customLong("disk-size"), help: "Disk size in GB for vm-create")
    var diskSize: Int = Int(ProcessInfo.processInfo.environment["DISK_SIZE"] ?? "64") ?? 64

    @Option(name: .customLong("iphone-device"), help: "Device identifier passed to prepare-firmware")
    var iPhoneDevice: String?

    @Option(name: .customLong("iphone-version"), help: "Version selector passed to prepare-firmware")
    var iPhoneVersion: String?

    @Option(name: .customLong("iphone-build"), help: "Build selector passed to prepare-firmware")
    var iPhoneBuild: String?

    @Option(name: .customLong("iphone-source"), help: "Direct iPhone IPSW URL or local path passed to prepare-firmware")
    var iPhoneSource: String?

    @Option(name: .customLong("cloudos-source"), help: "Direct cloudOS IPSW URL or local path passed to prepare-firmware")
    var cloudOSSource: String?

    @Option(name: .customLong("ipsw-dir"), help: "IPSW cache directory passed to prepare-firmware", transform: URL.init(fileURLWithPath:))
    var ipswDirectory: URL?

    @Option(help: "Automation variant")
    var variant: Variant = {
        let env = ProcessInfo.processInfo.environment
        if ["1", "true", "yes"].contains(env["JB"]?.lowercased() ?? "") { return .jb }
        if ["1", "true", "yes"].contains(env["DEV"]?.lowercased() ?? "") { return .dev }
        return .regular
    }()

    @Flag(help: "Skip setup_tools/build stage")
    var skipProjectSetup: Bool = {
        ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment["SKIP_PROJECT_SETUP"]?.lowercased() ?? "")
    }()

    @Flag(help: "Auto-continue first boot and final boot analysis")
    var nonInteractive: Bool = {
        ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment["NONE_INTERACTIVE"]?.lowercased() ?? "")
    }()

    mutating func run() async throws {
        let runner = try SetupMachineRunner(
            projectRoot: projectRoot.standardizedFileURL,
            vmDirectoryName: vmDirectory,
            cpu: cpu,
            memory: memory,
            diskSize: diskSize,
            iPhoneDevice: iPhoneDevice,
            iPhoneVersion: iPhoneVersion,
            iPhoneBuild: iPhoneBuild,
            iPhoneSource: iPhoneSource,
            cloudOSSource: cloudOSSource,
            ipswDirectory: ipswDirectory?.standardizedFileURL,
            variant: variant,
            skipProjectSetup: skipProjectSetup,
            nonInteractive: nonInteractive
        )
        try await runner.run()
    }
}

private struct SetupMachineRunner {
    let projectRoot: URL
    let vmDirectoryName: String
    let cpu: Int
    let memory: Int
    let diskSize: Int
    let iPhoneDevice: String?
    let iPhoneVersion: String?
    let iPhoneBuild: String?
    let iPhoneSource: String?
    let cloudOSSource: String?
    let ipswDirectory: URL?
    let variant: SetupMachineCLI.Variant
    let skipProjectSetup: Bool
    let nonInteractive: Bool

    let logDirectory: URL
    let bootDFULog: URL
    let bootLog: URL

    init(projectRoot: URL, vmDirectoryName: String, cpu: Int, memory: Int, diskSize: Int, iPhoneDevice: String?, iPhoneVersion: String?, iPhoneBuild: String?, iPhoneSource: String?, cloudOSSource: String?, ipswDirectory: URL?, variant: SetupMachineCLI.Variant, skipProjectSetup: Bool, nonInteractive: Bool) throws {
        self.projectRoot = projectRoot
        self.vmDirectoryName = vmDirectoryName
        self.cpu = cpu
        self.memory = memory
        self.diskSize = diskSize
        self.iPhoneDevice = iPhoneDevice
        self.iPhoneVersion = iPhoneVersion
        self.iPhoneBuild = iPhoneBuild
        self.iPhoneSource = iPhoneSource
        self.cloudOSSource = cloudOSSource
        self.ipswDirectory = ipswDirectory
        self.variant = variant
        self.skipProjectSetup = skipProjectSetup
        self.nonInteractive = nonInteractive
        logDirectory = projectRoot.appendingPathComponent("setup_logs", isDirectory: true)
        bootDFULog = logDirectory.appendingPathComponent("boot_dfu.log")
        bootLog = logDirectory.appendingPathComponent("boot.log")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    var fwPatchTarget: String {
        switch variant {
        case .regular: "fw_patch"
        case .dev: "fw_patch_dev"
        case .jb: "fw_patch_jb"
        }
    }

    var cfwInstallTarget: String {
        switch variant {
        case .regular: "cfw_install"
        case .dev: "cfw_install_dev"
        case .jb: "cfw_install_jb"
        }
    }

    var patcherExecutable: String {
        VPhoneHost.currentExecutablePath()
    }

    var releaseBinary: URL {
        HostBuildSupport.releaseBinaryURL(projectRoot: projectRoot)
    }

    var vmDirectoryURL: URL {
        projectRoot.appendingPathComponent(vmDirectoryName, isDirectory: true)
    }

    var configURL: URL {
        vmDirectoryURL.appendingPathComponent("config.plist")
    }

    func run() async throws {
        print("[*] setup-machine variant=\(variant.rawValue) cpu=\(cpu) memory=\(memory) disk=\(diskSize)GB skipProjectSetup=\(skipProjectSetup) nonInteractive=\(nonInteractive)")

        if !skipProjectSetup {
            try await runCLI("Project setup", args: ["setup-tools", "--project-root", projectRoot.path])
            try await buildHostBinary()
        } else {
            print("[*] Skipping setup_tools/build")
        }

        try await runCLI("Host preflight", args: ["boot-host-preflight", "--project-root", projectRoot.path, "--assert-bootable"])
        try await runCLI("Firmware prep", args: [
            "vm-create",
            "--dir", vmDirectoryURL.path,
            "--disk-size", "\(diskSize)",
            "--cpu", "\(cpu)",
            "--memory", "\(memory)",
        ])
        try await runCLI("Firmware prep", args: prepareFirmwareArguments())
        try await runCLI("Firmware patch", args: [
            "patch-firmware",
            "--vm-directory", vmDirectoryURL.path,
            "--variant", variant.rawValue,
        ])

        let dfu = try startBackgroundBoot(dfu: true, logURL: bootDFULog)
        defer { dfu.terminate() }

        let identity = try await waitForIdentity()
        try await runCLI("Restore", args: [
            "restore-get-shsh",
            vmDirectoryURL.path,
            "--udid", identity.udid,
            "--ecid", "0x\(identity.ecid)",
        ])
        try await runCLI("Restore", args: [
            "restore-device",
            vmDirectoryURL.path,
            "--udid", identity.udid,
            "--ecid", "0x\(identity.ecid)",
        ])

        dfu.terminate()
        try await Task.sleep(for: .seconds(5))

        let ramdiskDFU = try startBackgroundBoot(dfu: true, logURL: bootDFULog)
        defer { ramdiskDFU.terminate() }

        let ramdiskIdentity = try await waitForIdentity()
        try await runCLI("Ramdisk", args: ["build-ramdisk", vmDirectoryURL.path])
        try await runCLI("Ramdisk", args: [
            "send-ramdisk",
            "--ramdisk-dir", vmDirectoryURL.appendingPathComponent("Ramdisk").path,
            "--udid", ramdiskIdentity.udid,
            "--ecid", "0x\(ramdiskIdentity.ecid)",
        ])

        let forwardedPort = try chooseRandomPort()
        let usbmux = try startUSBMuxForward(localPort: forwardedPort, serial: ramdiskIdentity.udid)
        defer { usbmux.terminate() }

        try await waitForSSH(port: forwardedPort)
        try await runCLI("CFW install", args: [
            "cfw-install",
            vmDirectoryURL.path,
            "--project-root", projectRoot.path,
            "--variant", variant.rawValue,
            "--ssh-port", "\(forwardedPort)",
        ])

        ramdiskDFU.terminate()
        usbmux.terminate()

        if nonInteractive {
            try await runNonInteractiveFirstBoot()
            try await runBootAnalysis()
        }

        if variant == .jb {
            print("[*] JB finalization will run automatically on first normal boot via /cores/vphone_jb_setup.sh.")
        }
        print("[+] setup-machine complete")
    }

    func runCLI(_ label: String, args: [String]) async throws {
        print("")
        print("=== \(label) ===")
        let result = try await VPhoneHost.runCommand(patcherExecutable, arguments: args, requireSuccess: true)
        if !result.standardOutput.isEmpty { print(result.standardOutput) }
        if !result.standardError.isEmpty { print(result.standardError) }
    }

    func buildHostBinary() async throws {
        print("")
        print("=== Project build ===")
        _ = try await HostBuildSupport.buildHostBinary(projectRoot: projectRoot, configuration: .release)
    }

    func waitForIdentity(timeout: TimeInterval = 30) async throws -> (udid: String, ecid: String) {
        let predictionFile = projectRoot.appendingPathComponent(vmDirectoryName, isDirectory: true).appendingPathComponent("udid-prediction.txt")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: predictionFile.path) {
                let text = try String(contentsOf: predictionFile, encoding: .utf8)
                var udid = ""
                var ecid = ""
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "UDID": udid = parts[1].uppercased()
                    case "ECID": ecid = parts[1].replacingOccurrences(of: "0x", with: "").uppercased()
                    default: break
                    }
                }
                if !udid.isEmpty && !ecid.isEmpty {
                    print("[+] Device identity loaded: UDID=\(udid) ECID=0x\(ecid)")
                    return (udid, ecid)
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ValidationError("Timed out waiting for udid-prediction.txt")
    }

    func startBackgroundBoot(dfu: Bool, logURL: URL) throws -> ManagedProcess {
        try Data().write(to: logURL)
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = releaseBinary
        process.arguments = ["--config", configURL.path] + (dfu ? ["--dfu"] : [])
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return ManagedProcess(process: process, logHandle: logHandle)
    }

    func prepareFirmwareArguments() -> [String] {
        var arguments = [
            "prepare-firmware",
            "--project-root", projectRoot.path,
            "--output-dir", vmDirectoryURL.path,
        ]
        if let iPhoneDevice {
            arguments += ["--device", iPhoneDevice]
        }
        if let iPhoneVersion {
            arguments += ["--version", iPhoneVersion]
        }
        if let iPhoneBuild {
            arguments += ["--build", iPhoneBuild]
        }
        if let iPhoneSource {
            arguments += ["--iphone-source", iPhoneSource]
        }
        if let cloudOSSource {
            arguments += ["--cloudos-source", cloudOSSource]
        }
        if let ipswDirectory {
            arguments += ["--ipsw-dir", ipswDirectory.path]
        }
        return arguments
    }

    func startUSBMuxForward(localPort: Int, serial: String) throws -> ManagedUSBMuxForward {
        guard let local = UInt16(exactly: localPort) else {
            throw ValidationError("Invalid local forward port: \(localPort)")
        }
        let service = try USBMuxForwarder.start(localPort: local, serial: serial, remotePort: 22)
        return ManagedUSBMuxForward(service: service)
    }

    func waitForSSH(port: Int, timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if VPhoneSSHClient.probe(host: "127.0.0.1", port: port, username: "root", password: "alpine") { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw ValidationError("Timed out waiting for ramdisk SSH on port \(port)")
    }

    func runNonInteractiveFirstBoot() async throws {
        try Data().write(to: bootLog)
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = releaseBinary
        process.arguments = ["--config", configURL.path]
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        let logHandle = try FileHandle(forWritingTo: bootLog)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        try await waitForBootPrompt(in: bootLog)
        let commands = [
            "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'",
            "cp /iosbinpack64/etc/profile /var/profile",
            "cp /iosbinpack64/etc/motd /var/motd",
            "mkdir -p /var/dropbear",
            "dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key",
            "dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key",
            "shutdown -h now",
        ]
        for command in commands {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        }
        process.waitUntilExit()
        try logHandle.close()
    }

    func runBootAnalysis() async throws {
        try Data().write(to: bootLog)
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = releaseBinary
        process.arguments = ["--config", configURL.path]
        let logHandle = try FileHandle(forWritingTo: bootLog)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? logHandle.close()
        }
        try await waitForBootPrompt(in: bootLog)
        process.terminate()
    }

    func waitForBootPrompt(in logURL: URL, timeout: TimeInterval = 300) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if text.range(of: "bash-", options: .regularExpression) != nil { return }
            if text.range(of: "panic|kernel panic|panic\\.apple\\.com|stackshot succeeded", options: .regularExpression) != nil {
                throw ValidationError("Panic detected during boot")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ValidationError("Timed out waiting for first boot prompt")
    }

    func chooseRandomPort() throws -> Int {
        for _ in 0 ..< 200 {
            let port = Int.random(in: 20_000 ... 60_000)
            if isPortFree(port) { return port }
        }
        throw ValidationError("Failed to allocate a random local SSH forward port")
    }

    func isPortFree(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

private final class ManagedProcess {
    let process: Process
    let logHandle: FileHandle?

    init(process: Process, logHandle: FileHandle?) {
        self.process = process
        self.logHandle = logHandle
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? logHandle?.close()
    }
}

private final class ManagedUSBMuxForward {
    let service: USBMuxForwardingService

    init(service: USBMuxForwardingService) {
        self.service = service
    }

    func terminate() {
        service.stop()
    }
}
