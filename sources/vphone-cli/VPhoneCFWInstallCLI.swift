import ArgumentParser
import Foundation

struct CFWInstallCLI: AsyncParsableCommand {
    enum Variant: String, ExpressibleByArgument {
        case regular
        case dev
        case jb
    }

    static let configuration = CommandConfiguration(
        commandName: "cfw-install",
        abstract: "Install CFW payloads from the host through the Swift workflow"
    )

    @Argument(help: "VM directory", transform: URL.init(fileURLWithPath:))
    var vmDirectory: URL = URL(fileURLWithPath: ".")

    @Option(help: "Project root", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    @Option(help: "CFW variant")
    var variant: Variant = .regular

    @Option(help: "SSH port")
    var sshPort: Int = Int(ProcessInfo.processInfo.environment["SSH_PORT"] ?? "2222") ?? 2222

    @Flag(help: "Skip halting the ramdisk after install")
    var skipHalt: Bool = ProcessInfo.processInfo.environment["CFW_SKIP_HALT"] == "1"

    mutating func run() async throws {
        let installer = try VPhoneCFWInstaller(
            vmDirectory: vmDirectory.standardizedFileURL,
            projectRoot: projectRoot.standardizedFileURL,
            variant: variant,
            sshPort: sshPort,
            skipHalt: skipHalt
        )
        try await installer.run()
    }
}

private struct VPhoneCFWInstaller {
    let vmDirectory: URL
    let projectRoot: URL
    let variant: CFWInstallCLI.Variant
    let sshPort: Int
    let skipHalt: Bool

    let sshPassword = "alpine"
    let sshUser = "root"
    let sshHost = "localhost"
    let sshRetry = 3
    let scriptDirectory: URL
    let temporaryDirectory: URL
    let cfwInputDirectory: URL
    let jbInputDirectory: URL
    let patcherBinary: String

    init(vmDirectory: URL, projectRoot: URL, variant: CFWInstallCLI.Variant, sshPort: Int, skipHalt: Bool) throws {
        self.vmDirectory = vmDirectory
        self.projectRoot = projectRoot
        self.variant = variant
        self.sshPort = sshPort
        self.skipHalt = skipHalt
        scriptDirectory = projectRoot.appendingPathComponent("scripts", isDirectory: true)
        temporaryDirectory = vmDirectory.appendingPathComponent(".cfw_temp", isDirectory: true)
        cfwInputDirectory = vmDirectory.appendingPathComponent("cfw_input", isDirectory: true)
        jbInputDirectory = vmDirectory.appendingPathComponent("cfw_jb_input", isDirectory: true)
        let candidate = projectRoot.appendingPathComponent(".build/debug/vphone-cli").path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            patcherBinary = candidate
        } else {
            patcherBinary = "vphone-cli"
        }
    }

    func run() async throws {
        print("[*] Installing CFW variant: \(variant.rawValue)")
        try await checkPrerequisites()
        try setupInputs()
        try await waitForSSHReady()
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        switch variant {
        case .regular:
            try await installBaseCFW(applyDevOverlay: false)
        case .dev:
            try await installBaseCFW(applyDevOverlay: true)
            try await applyDevExtras()
        case .jb:
            try await installBaseCFW(applyDevOverlay: false)
            try await applyJBExtras()
        }

        if skipHalt {
            print("[*] CFW_SKIP_HALT=1, skipping halt.")
        } else {
            _ = try? await ssh("/sbin/halt")
        }
    }

    func checkPrerequisites() async throws {
        var commands = ["ipsw", "aea", "ldid", patcherBinary, "ssh", "scp"]
        if variant == .jb {
            commands += ["zstd", "xcrun"]
        }
        for command in commands {
            guard resolveCommand(command) != nil else {
                throw ValidationError("Missing required tool: \(command)")
            }
        }
    }

    func resolveCommand(_ command: String) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    func setupInputs() throws {
        try ensureInputDirectory(name: "cfw_input", archiveName: "cfw_input.tar.zst")
        if variant == .jb {
            try ensureInputDirectory(name: "cfw_jb_input", archiveName: "cfw_jb_input.tar.zst")
        }
    }

    func ensureInputDirectory(name: String, archiveName: String) throws {
        let directory = vmDirectory.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            return
        }

        let searchDirectories = [
            scriptDirectory.appendingPathComponent("resources", isDirectory: true),
            scriptDirectory,
            vmDirectory,
        ]
        for searchDirectory in searchDirectories {
            let archiveURL = searchDirectory.appendingPathComponent(archiveName)
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: resolveCommand("tar") ?? "/usr/bin/tar")
                task.arguments = ["--zstd", "-xf", archiveURL.path, "-C", vmDirectory.path]
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    return
                }
                throw ValidationError("Failed to extract \(archiveName)")
            }
        }

        throw ValidationError("Neither \(name)/ nor \(archiveName) found")
    }

    func waitForSSHReady() async throws {
        print("[*] Waiting for ramdisk SSH on \(sshUser)@\(sshHost):\(sshPort)...")
        var elapsed = 0
        while elapsed < 60 {
            let result = try await ssh("echo ready", requireSuccess: false)
            if result.terminationStatus.isSuccess {
                print("[+] Ramdisk SSH is reachable")
                return
            }
            try await Task.sleep(for: .seconds(2))
            elapsed += 2
        }
        throw ValidationError("Ramdisk SSH is not reachable on \(sshHost):\(sshPort)")
    }

    func installBaseCFW(applyDevOverlay: Bool) async throws {
        if applyDevOverlay {
            try await applyDevOverlayToIosbinpack()
        }

        let restoreDirectory = try findRestoreDirectory()
        let cryptexPaths = try await VPhoneHost.runCommand(
            patcherBinary,
            arguments: ["cfw-cryptex-paths", restoreDirectory.appendingPathComponent("BuildManifest-iPhone.plist").path],
            requireSuccess: true
        )
        let lines = VPhoneHost.outputLines(cryptexPaths, limit: 2)
        guard lines.count == 2 else {
            throw ValidationError("Unable to resolve Cryptex paths from BuildManifest-iPhone.plist")
        }
        let systemOSRelativePath = lines[0]
        let appOSRelativePath = lines[1]

        try await mountRootFS()
        try await renameSnapshotIfNeeded()
        try await installCryptexesIfNeeded(
            restoreDirectory: restoreDirectory,
            systemOSRelativePath: systemOSRelativePath,
            appOSRelativePath: appOSRelativePath
        )

        try await patchSeputil()
        try await installGPUDriver()
        try await installIosbinpack()
        try await patchLaunchdCacheLoader()
        try await patchMobileactivationd()
        try await installLaunchDaemons()
        try await unmount(paths: ["/mnt1", "/mnt3"])
        try cleanupTemporaryFiles([
            "seputil",
            "launchd_cache_loader",
            "mobileactivationd",
            "vphoned",
            "launchd.plist",
        ])

        print("[+] Base CFW installation complete")
    }

    func applyDevOverlayToIosbinpack() async throws {
        let candidates = [
            scriptDirectory.appendingPathComponent("resources/cfw_dev/rpcserver_ios"),
            scriptDirectory.appendingPathComponent("cfw_dev/rpcserver_ios"),
        ]
        guard let rpcserver = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ValidationError("Dev overlay not found (cfw_dev/rpcserver_ios)")
        }

        let iosbinpack = cfwInputDirectory.appendingPathComponent("jb/iosbinpack64.tar")
        let unpackDirectory = vmDirectory.appendingPathComponent(".iosbinpack_tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: unpackDirectory)
        try FileManager.default.createDirectory(at: unpackDirectory, withIntermediateDirectories: true)

        _ = try await VPhoneHost.runCommand("tar", arguments: ["-xf", iosbinpack.path, "-C", unpackDirectory.path], requireSuccess: true)
        let destination = unpackDirectory.appendingPathComponent("iosbinpack64/usr/local/bin/rpcserver_ios")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: rpcserver, to: destination)
        let process = Process()
        process.currentDirectoryURL = unpackDirectory
        process.executableURL = URL(fileURLWithPath: resolveCommand("tar") ?? "/usr/bin/tar")
        process.arguments = ["-cf", iosbinpack.path, "iosbinpack64"]
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: unpackDirectory)
        guard process.terminationStatus == 0 else {
            throw ValidationError("Failed to rebuild iosbinpack64.tar with dev overlay")
        }
    }

    func applyDevExtras() async throws {
        try await mountRootFS()
        try await patchLaunchdForJetsam(injectShortAlias: false)
        try await patchDebugserverEntitlements()
        try await unmount(paths: ["/mnt1", "/mnt3"])
        print("[+] Dev extras applied")
    }

    func applyJBExtras() async throws {
        try await mountRootFS()
        try await patchLaunchdForJetsam(injectShortAlias: true)
        try await patchDebugserverEntitlements()
        try await installJBBootstrap()
        try await deployBaseBin()
        try await installTweakLoader()
        try await deployFirstBootJBSetup()
        try await unmount(paths: ["/mnt1", "/mnt3", "/mnt5"])
        try cleanupTemporaryFiles(["launchd", "bootstrap-iphoneos-arm64.tar", "b"])
        print("[+] JB extras applied")
    }

    func findRestoreDirectory() throws -> URL {
        let candidates = try FileManager.default.contentsOfDirectory(at: vmDirectory, includingPropertiesForKeys: nil)
        guard let directory = candidates.first(where: {
            $0.lastPathComponent.hasPrefix("iPhone") &&
            $0.lastPathComponent.hasSuffix("_Restore") &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("BuildManifest.plist").path)
        }) else {
            throw ValidationError("No restore directory found in \(vmDirectory.path)")
        }
        return directory
    }

    func sshBaseArguments() -> [String] {
        [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PreferredAuthentications=password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=30",
            "-q",
            "-p", "\(sshPort)",
            "\(sshUser)@\(sshHost)",
        ]
    }

    func scpBaseArguments() -> [String] {
        [
            "-q",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PreferredAuthentications=password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=30",
            "-P", "\(sshPort)",
        ]
    }

    func ssh(_ command: String, requireSuccess: Bool = true) async throws -> VPhoneCommandResult {
        var lastError: Error?
        for _ in 0 ..< sshRetry {
            do {
                let result = try await VPhoneHost.runCommand(
                    "ssh",
                    arguments: sshBaseArguments() + [command],
                    environment: VPhoneHost.sshAskpassEnvironment(password: sshPassword, executablePath: patcherBinary),
                    requireSuccess: requireSuccess
                )
                if !requireSuccess || result.terminationStatus.isSuccess || VPhoneHost.exitCode(from: result.terminationStatus) != 255 {
                    return result
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw lastError ?? ValidationError("SSH command failed: \(command)")
    }

    func scpTo(_ localPath: String, remotePath: String, recursive: Bool = false) async throws {
        var arguments = scpBaseArguments()
        if recursive {
            arguments.append("-r")
        }
        arguments += [localPath, "\(sshUser)@\(sshHost):\(remotePath)"]
        _ = try await VPhoneHost.runCommand(
            "scp",
            arguments: arguments,
            environment: VPhoneHost.sshAskpassEnvironment(password: sshPassword, executablePath: patcherBinary),
            requireSuccess: true
        )
    }

    func scpFrom(_ remotePath: String, localPath: String) async throws {
        let arguments = scpBaseArguments() + ["\(sshUser)@\(sshHost):\(remotePath)", localPath]
        _ = try await VPhoneHost.runCommand(
            "scp",
            arguments: arguments,
            environment: VPhoneHost.sshAskpassEnvironment(password: sshPassword, executablePath: patcherBinary),
            requireSuccess: true
        )
    }

    func remoteFileExists(_ path: String) async throws -> Bool {
        let result = try await ssh("test -f '\(path)'", requireSuccess: false)
        return result.terminationStatus.isSuccess
    }

    func mountRootFS() async throws {
        try await remoteMount("/dev/disk1s1", at: "/mnt1", options: "rw")
    }

    func remoteMount(_ device: String, at mountpoint: String, options: String) async throws {
        _ = try await ssh("/bin/mkdir -p \(mountpoint)")
        let mounted = try await ssh("/sbin/mount | /usr/bin/grep -q ' on \(mountpoint) '", requireSuccess: false)
        if mounted.terminationStatus.isSuccess {
            return
        }
        _ = try await ssh("/sbin/mount_apfs -o \(options) \(device) \(mountpoint) 2>/dev/null || true")
        let verify = try await ssh("/sbin/mount | /usr/bin/grep -q ' on \(mountpoint) '", requireSuccess: false)
        guard verify.terminationStatus.isSuccess else {
            throw ValidationError("Failed to mount \(device) at \(mountpoint)")
        }
    }

    func renameSnapshotIfNeeded() async throws {
        let list = try await ssh("snaputil -l /mnt1 2>/dev/null", requireSuccess: false)
        let output = list.standardOutput
        if output.split(separator: "\n").contains("orig-fs") {
            return
        }
        guard let updateSnapshot = output.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("com.apple.os.update-") }) else {
            return
        }
        _ = try await ssh("snaputil -n '\(updateSnapshot)' orig-fs /mnt1")
        _ = try await ssh("/sbin/umount /mnt1")
        try await mountRootFS()
    }

    func installCryptexesIfNeeded(restoreDirectory: URL, systemOSRelativePath: String, appOSRelativePath: String) async throws {
        let osCount = try await ssh("/bin/ls /mnt1/System/Cryptexes/OS/ 2>/dev/null | /usr/bin/wc -l", requireSuccess: false)
        let appCount = try await ssh("/bin/ls /mnt1/System/Cryptexes/App/ 2>/dev/null | /usr/bin/wc -l", requireSuccess: false)
        let installed = (Int(osCount.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 &&
            (Int(appCount.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

        if installed {
            try await ensureDyldSymlinks()
            return
        }

        let systemDMG = temporaryDirectory.appendingPathComponent("CryptexSystemOS.dmg")
        let appDMG = temporaryDirectory.appendingPathComponent("CryptexAppOS.dmg")
        let mountSystem = temporaryDirectory.appendingPathComponent("mnt_sysos", isDirectory: true)
        let mountApp = temporaryDirectory.appendingPathComponent("mnt_appos", isDirectory: true)

        if !FileManager.default.fileExists(atPath: systemDMG.path) {
            let key = VPhoneHost.stringValue(try await VPhoneHost.runCommand("ipsw", arguments: ["fw", "aea", "--key", restoreDirectory.appendingPathComponent(systemOSRelativePath).path], requireSuccess: true))
            _ = try await VPhoneHost.runCommand("aea", arguments: ["decrypt", "-i", restoreDirectory.appendingPathComponent(systemOSRelativePath).path, "-o", systemDMG.path, "-key-value", key], requireSuccess: true)
        }
        if !FileManager.default.fileExists(atPath: appDMG.path) {
            try? FileManager.default.removeItem(at: appDMG)
            try FileManager.default.copyItem(at: restoreDirectory.appendingPathComponent(appOSRelativePath), to: appDMG)
        }

        try FileManager.default.createDirectory(at: mountSystem, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mountApp, withIntermediateDirectories: true)
        try await safeDetach(mountSystem)
        try await safeDetach(mountApp)
        _ = try await VPhoneHost.runPrivileged("hdiutil", arguments: ["attach", "-mountpoint", mountSystem.path, systemDMG.path, "-nobrowse", "-owners", "off"], requireSuccess: true)
        _ = try await VPhoneHost.runPrivileged("hdiutil", arguments: ["attach", "-mountpoint", mountApp.path, appDMG.path, "-nobrowse", "-owners", "off"], requireSuccess: true)

        _ = try await ssh("/bin/rm -rf /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS")
        _ = try await ssh("/bin/mkdir -p /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS")
        _ = try await ssh("/bin/chmod 0755 /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS")
        try await scpTo(mountSystem.appendingPathComponent(".").path, remotePath: "/mnt1/System/Cryptexes/OS", recursive: true)
        try await scpTo(mountApp.appendingPathComponent(".").path, remotePath: "/mnt1/System/Cryptexes/App", recursive: true)
        try await ensureDyldSymlinks()
        try await safeDetach(mountSystem)
        try await safeDetach(mountApp)
    }

    func ensureDyldSymlinks() async throws {
        _ = try await ssh("/bin/ln -sf ../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld /mnt1/System/Library/Caches/com.apple.dyld")
        _ = try await ssh("/bin/ln -sf ../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld /mnt1/System/DriverKit/System/Library/dyld")
    }

    func safeDetach(_ mountpoint: URL) async throws {
        let mounts = try await VPhoneHost.runCommand("mount")
        if mounts.combinedOutput.contains(" on \(mountpoint.path) ") {
            _ = try? await VPhoneHost.runPrivileged("hdiutil", arguments: ["detach", "-force", mountpoint.path], requireSuccess: true)
        }
    }

    func patchSeputil() async throws {
        if !(try await remoteFileExists("/mnt1/usr/libexec/seputil.bak")) {
            _ = try await ssh("/bin/cp /mnt1/usr/libexec/seputil /mnt1/usr/libexec/seputil.bak")
        }
        let localPath = temporaryDirectory.appendingPathComponent("seputil")
        try await scpFrom("/mnt1/usr/libexec/seputil.bak", localPath: localPath.path)
        var patcher = try VPhoneCFWPatcher(binaryURL: localPath)
        try patcher.patchSeputil()
        try patcher.writeBack()
        try await ldidSign(localPath, bundleID: "com.apple.seputil")
        try await scpTo(localPath.path, remotePath: "/mnt1/usr/libexec/seputil")
        _ = try await ssh("/bin/chmod 0755 /mnt1/usr/libexec/seputil")
        try await remoteMount("/dev/disk1s3", at: "/mnt3", options: "rw")
        _ = try await ssh("/bin/mv /mnt3/*.gl /mnt3/AA.gl 2>/dev/null || true")
    }

    func installGPUDriver() async throws {
        let archive = cfwInputDirectory.appendingPathComponent("custom/AppleParavirtGPUMetalIOGPUFamily.tar")
        try await scpTo(archive.path, remotePath: "/mnt1")
        _ = try await ssh("/usr/bin/tar --preserve-permissions --no-overwrite-dir -xf /mnt1/AppleParavirtGPUMetalIOGPUFamily.tar -C /mnt1")
        let bundle = "/mnt1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
        _ = try await ssh("find \(bundle) -name '._*' -delete 2>/dev/null || true")
        _ = try await ssh("/usr/sbin/chown -R 0:0 \(bundle)")
        _ = try await ssh("/bin/chmod 0755 \(bundle)")
        _ = try await ssh("/bin/chmod 0755 \(bundle)/libAppleParavirtCompilerPluginIOGPUFamily.dylib")
        _ = try await ssh("/bin/chmod 0755 \(bundle)/AppleParavirtGPUMetalIOGPUFamily")
        _ = try await ssh("/bin/chmod 0755 \(bundle)/_CodeSignature")
        _ = try await ssh("/bin/chmod 0644 \(bundle)/_CodeSignature/CodeResources")
        _ = try await ssh("/bin/chmod 0644 \(bundle)/Info.plist")
        _ = try await ssh("/bin/rm -f /mnt1/AppleParavirtGPUMetalIOGPUFamily.tar")
    }

    func installIosbinpack() async throws {
        let archive = cfwInputDirectory.appendingPathComponent("jb/iosbinpack64.tar")
        try await scpTo(archive.path, remotePath: "/mnt1")
        _ = try await ssh("/usr/bin/tar --preserve-permissions --no-overwrite-dir -xf /mnt1/iosbinpack64.tar -C /mnt1")
        _ = try await ssh("/bin/rm -f /mnt1/iosbinpack64.tar")
    }

    func patchLaunchdCacheLoader() async throws {
        if !(try await remoteFileExists("/mnt1/usr/libexec/launchd_cache_loader.bak")) {
            _ = try await ssh("/bin/cp /mnt1/usr/libexec/launchd_cache_loader /mnt1/usr/libexec/launchd_cache_loader.bak")
        }
        let localPath = temporaryDirectory.appendingPathComponent("launchd_cache_loader")
        try await scpFrom("/mnt1/usr/libexec/launchd_cache_loader.bak", localPath: localPath.path)
        var patcher = try VPhoneCFWPatcher(binaryURL: localPath)
        try patcher.patchLaunchdCacheLoader()
        try patcher.writeBack()
        try await ldidSign(localPath, bundleID: "com.apple.launchd_cache_loader")
        try await scpTo(localPath.path, remotePath: "/mnt1/usr/libexec/launchd_cache_loader")
        _ = try await ssh("/bin/chmod 0755 /mnt1/usr/libexec/launchd_cache_loader")
    }

    func patchMobileactivationd() async throws {
        if !(try await remoteFileExists("/mnt1/usr/libexec/mobileactivationd.bak")) {
            _ = try await ssh("/bin/cp /mnt1/usr/libexec/mobileactivationd /mnt1/usr/libexec/mobileactivationd.bak")
        }
        let localPath = temporaryDirectory.appendingPathComponent("mobileactivationd")
        try await scpFrom("/mnt1/usr/libexec/mobileactivationd.bak", localPath: localPath.path)
        var patcher = try VPhoneCFWPatcher(binaryURL: localPath)
        try patcher.patchMobileactivationd()
        try patcher.writeBack()
        try await ldidSign(localPath, bundleID: nil)
        try await scpTo(localPath.path, remotePath: "/mnt1/usr/libexec/mobileactivationd")
        _ = try await ssh("/bin/chmod 0755 /mnt1/usr/libexec/mobileactivationd")
    }

    func installLaunchDaemons() async throws {
        try await buildAndInstallVphoned()

        let daemonNames = ["bash.plist", "dropbear.plist", "trollvnc.plist", "rpcserver_ios.plist"]
        for name in daemonNames {
            let source = cfwInputDirectory.appendingPathComponent("jb/LaunchDaemons/\(name)")
            try await scpTo(source.path, remotePath: "/mnt1/System/Library/LaunchDaemons/")
            _ = try await ssh("/bin/chmod 0644 /mnt1/System/Library/LaunchDaemons/\(name)")
        }

        let vphonedPlist = scriptDirectory.appendingPathComponent("vphoned/vphoned.plist")
        try await scpTo(vphonedPlist.path, remotePath: "/mnt1/System/Library/LaunchDaemons/")
        _ = try await ssh("/bin/chmod 0644 /mnt1/System/Library/LaunchDaemons/vphoned.plist")

        if !(try await remoteFileExists("/mnt1/System/Library/xpc/launchd.plist.bak")) {
            _ = try await ssh("/bin/cp /mnt1/System/Library/xpc/launchd.plist /mnt1/System/Library/xpc/launchd.plist.bak")
        }

        let localPath = temporaryDirectory.appendingPathComponent("launchd.plist")
        try await scpFrom("/mnt1/System/Library/xpc/launchd.plist.bak", localPath: localPath.path)
        let daemonDirectory = cfwInputDirectory.appendingPathComponent("jb/LaunchDaemons", isDirectory: true)
        let vphonedLocalPlist = daemonDirectory.appendingPathComponent("vphoned.plist")
        if FileManager.default.fileExists(atPath: vphonedLocalPlist.path) {
            try FileManager.default.removeItem(at: vphonedLocalPlist)
        }
        try FileManager.default.copyItem(at: vphonedPlist, to: vphonedLocalPlist)
        try injectDaemons(into: localPath, directory: daemonDirectory)
        try await scpTo(localPath.path, remotePath: "/mnt1/System/Library/xpc/launchd.plist")
        _ = try await ssh("/bin/chmod 0644 /mnt1/System/Library/xpc/launchd.plist")
    }

    func buildAndInstallVphoned() async throws {
        let builder = VphonedBuilder(projectRoot: projectRoot)
        let builtBinary = try await builder.build(
            signedCopyURL: nil,
            gitHash: try await builder.currentGitHash()
        ).binaryURL
        let localBinary = temporaryDirectory.appendingPathComponent("vphoned")
        try? FileManager.default.removeItem(at: localBinary)
        try FileManager.default.copyItem(at: builtBinary, to: localBinary)
        try await ldidSign(localBinary, entitlements: builder.entitlementsURL, bundleID: nil)
        try await scpTo(localBinary.path, remotePath: "/mnt1/usr/bin/vphoned")
        _ = try await ssh("/bin/chmod 0755 /mnt1/usr/bin/vphoned")

        let signedCopy = vmDirectory.appendingPathComponent(".vphoned.signed")
        if FileManager.default.fileExists(atPath: signedCopy.path) {
            try FileManager.default.removeItem(at: signedCopy)
        }
        try FileManager.default.copyItem(at: localBinary, to: signedCopy)
    }

    func ldidSign(_ binaryURL: URL, entitlements: URL? = nil, bundleID: String?) async throws {
        var arguments: [String] = []
        if let entitlements {
            arguments.append("-S\(entitlements.path)")
        } else {
            arguments.append("-S")
            arguments.append("-M")
        }
        arguments.append("-K\(cfwInputDirectory.appendingPathComponent("signcert.p12").path)")
        if let bundleID {
            arguments.append("-I\(bundleID)")
        }
        arguments.append(binaryURL.path)
        _ = try await VPhoneHost.runCommand("ldid", arguments: arguments, requireSuccess: true)
    }

    func patchLaunchdForJetsam(injectShortAlias: Bool) async throws {
        if !(try await remoteFileExists("/mnt1/sbin/launchd.bak")) {
            _ = try await ssh("/bin/cp /mnt1/sbin/launchd /mnt1/sbin/launchd.bak")
        }
        let localPath = temporaryDirectory.appendingPathComponent("launchd")
        try await scpFrom("/mnt1/sbin/launchd.bak", localPath: localPath.path)

        let entitlementsPath = temporaryDirectory.appendingPathComponent("launchd.entitlements")
        let ldidExtract = try await VPhoneHost.runCommand("ldid", arguments: ["-e", localPath.path], requireSuccess: false)
        if ldidExtract.terminationStatus.isSuccess, !ldidExtract.standardOutput.isEmpty {
            try ldidExtract.standardOutput.write(to: entitlementsPath, atomically: true, encoding: .utf8)
        }

        if injectShortAlias, FileManager.default.fileExists(atPath: jbInputDirectory.appendingPathComponent("basebin").path) {
            _ = try await VPhoneHost.runCommand(patcherBinary, arguments: ["cfw-inject-dylib", localPath.path, "/b"], requireSuccess: true)
        }

        var patcher = try VPhoneCFWPatcher(binaryURL: localPath)
        try patcher.patchLaunchdJetsam()
        try patcher.writeBack()

        if FileManager.default.fileExists(atPath: entitlementsPath.path) {
            try await ldidSign(localPath, entitlements: entitlementsPath, bundleID: nil)
        } else {
            try await ldidSign(localPath, entitlements: nil, bundleID: nil)
        }
        try await scpTo(localPath.path, remotePath: "/mnt1/sbin/launchd")
        _ = try await ssh("/bin/chmod 0755 /mnt1/sbin/launchd")
    }

    func patchDebugserverEntitlements() async throws {
        let localBinary = temporaryDirectory.appendingPathComponent("debugserver")
        let entitlements = temporaryDirectory.appendingPathComponent("debugserver-entitlements.plist")
        try await scpFrom("/mnt1/usr/libexec/debugserver", localPath: localBinary.path)
        _ = try await VPhoneHost.runCommand("ldid", arguments: ["-e", localBinary.path], requireSuccess: true)
        let extracted = try await VPhoneHost.runCommand("ldid", arguments: ["-e", localBinary.path], requireSuccess: true)
        try extracted.standardOutput.write(to: entitlements, atomically: true, encoding: .utf8)
        _ = try await VPhoneHost.runCommand("plutil", arguments: ["-remove", "seatbelt-profiles", entitlements.path], requireSuccess: false)
        _ = try await VPhoneHost.runCommand("plutil", arguments: ["-insert", "task_for_pid-allow", "-bool", "YES", entitlements.path], requireSuccess: false)
        try await ldidSign(localBinary, entitlements: entitlements, bundleID: nil)
        try await scpTo(localBinary.path, remotePath: "/mnt1/usr/libexec/debugserver")
        _ = try await ssh("/bin/chmod 0755 /mnt1/usr/libexec/debugserver")
    }

    func installJBBootstrap() async throws {
        try await remoteMount("/dev/disk1s5", at: "/mnt5", options: "rw")
        let hashResult = try await ssh("/bin/ls /mnt5 2>/dev/null | awk 'length($0)==96{print; exit}'")
        let bootHash = hashResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bootHash.isEmpty else { throw ValidationError("Could not find boot manifest hash in /mnt5") }

        let bootstrapArchive = jbInputDirectory.appendingPathComponent("jb/bootstrap-iphoneos-arm64.tar.zst")
        let sileoDeb = jbInputDirectory.appendingPathComponent("jb/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb")
        let bootstrapTar = temporaryDirectory.appendingPathComponent("bootstrap-iphoneos-arm64.tar")

        _ = try await VPhoneHost.runCommand("zstd", arguments: ["-d", "-f", bootstrapArchive.path, "-o", bootstrapTar.path], requireSuccess: true)
        try await scpTo(bootstrapTar.path, remotePath: "/mnt5/\(bootHash)/bootstrap-iphoneos-arm64.tar")
        if FileManager.default.fileExists(atPath: sileoDeb.path) {
            try await scpTo(sileoDeb.path, remotePath: "/mnt5/\(bootHash)/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb")
        }

        let jbName = "jb-vphone"
        _ = try await ssh("/bin/rm -rf /mnt5/\(bootHash)/jb")
        _ = try await ssh("/bin/rm -rf /mnt5/\(bootHash)/\(jbName)")
        _ = try await ssh("/bin/mkdir -p /mnt5/\(bootHash)/\(jbName)")
        _ = try await ssh("/bin/chmod 0755 /mnt5/\(bootHash)/\(jbName)")
        _ = try await ssh("/usr/sbin/chown 0:0 /mnt5/\(bootHash)/\(jbName)")
        _ = try await ssh("/usr/bin/tar --preserve-permissions -xf /mnt5/\(bootHash)/bootstrap-iphoneos-arm64.tar -C /mnt5/\(bootHash)/\(jbName)/")
        _ = try await ssh("/bin/mv /mnt5/\(bootHash)/\(jbName)/var /mnt5/\(bootHash)/\(jbName)/procursus")
        _ = try await ssh("/bin/mv /mnt5/\(bootHash)/\(jbName)/procursus/jb/* /mnt5/\(bootHash)/\(jbName)/procursus 2>/dev/null || true")
        _ = try await ssh("/bin/rm -rf /mnt5/\(bootHash)/\(jbName)/procursus/jb")
        _ = try await ssh("/bin/rm -f /mnt5/\(bootHash)/bootstrap-iphoneos-arm64.tar")
    }

    func deployBaseBin() async throws {
        let basebin = jbInputDirectory.appendingPathComponent("basebin", isDirectory: true)
        guard FileManager.default.fileExists(atPath: basebin.path) else { return }
        _ = try await ssh("/bin/rm -rf /mnt1/cores")
        _ = try await ssh("/bin/mkdir -p /mnt1/cores")
        _ = try await ssh("/bin/chmod 0755 /mnt1/cores")

        let dylibs = try FileManager.default.contentsOfDirectory(at: basebin, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dylib" }
        for dylib in dylibs {
            try await ldidSign(dylib, entitlements: nil, bundleID: nil)
            try await scpTo(dylib.path, remotePath: "/mnt1/cores/\(dylib.lastPathComponent)")
            _ = try await ssh("/bin/chmod 0755 /mnt1/cores/\(dylib.lastPathComponent)")
        }

        let hook = basebin.appendingPathComponent("launchdhook.dylib")
        if FileManager.default.fileExists(atPath: hook.path) {
            let shortAlias = temporaryDirectory.appendingPathComponent("b")
            try? FileManager.default.removeItem(at: shortAlias)
            try FileManager.default.copyItem(at: hook, to: shortAlias)
            try await ldidSign(shortAlias, entitlements: nil, bundleID: nil)
            _ = try await ssh("/bin/rm -f /mnt1/b")
            try await scpTo(shortAlias.path, remotePath: "/mnt1/b")
            _ = try await ssh("/bin/chmod 0755 /mnt1/b")
        }
    }

    func installTweakLoader() async throws {
        let source = scriptDirectory.appendingPathComponent("tweakloader/TweakLoader.m")
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let sdk = VPhoneHost.stringValue(try await VPhoneHost.runCommand("xcrun", arguments: ["--sdk", "iphoneos", "--show-sdk-path"], requireSuccess: true))
        let clang = VPhoneHost.stringValue(try await VPhoneHost.runCommand("xcrun", arguments: ["--sdk", "iphoneos", "-f", "clang"], requireSuccess: true))
        let output = temporaryDirectory.appendingPathComponent("TweakLoader.dylib")
        _ = try await VPhoneHost.runCommand(
            clang,
            arguments: [
                "-isysroot", sdk,
                "-arch", "arm64",
                "-arch", "arm64e",
                "-miphoneos-version-min=15.0",
                "-dynamiclib",
                "-fobjc-arc",
                "-O3",
                "-framework", "Foundation",
                "-o", output.path,
                source.path,
            ],
            requireSuccess: true
        )
        try await ldidSign(output, entitlements: nil, bundleID: nil)

        let bootHash = VPhoneHost.stringValue(try await ssh("/bin/ls /mnt5 2>/dev/null | awk 'length($0)==96{print; exit}'"))
        _ = try await ssh("/bin/mkdir -p /mnt5/\(bootHash)/jb-vphone/procursus/usr/lib")
        try await scpTo(output.path, remotePath: "/mnt5/\(bootHash)/jb-vphone/procursus/usr/lib/TweakLoader.dylib")
        _ = try await ssh("/usr/sbin/chown 0:0 /mnt5/\(bootHash)/jb-vphone/procursus/usr/lib/TweakLoader.dylib")
        _ = try await ssh("/bin/chmod 0755 /mnt5/\(bootHash)/jb-vphone/procursus/usr/lib/TweakLoader.dylib")
    }

    func deployFirstBootJBSetup() async throws {
        let setupScript = scriptDirectory.appendingPathComponent("vphone_jb_setup.sh")
        let setupPlist = scriptDirectory.appendingPathComponent("vphone_jb_setup.plist")

        if FileManager.default.fileExists(atPath: setupScript.path) {
            try await scpTo(setupScript.path, remotePath: "/mnt1/cores/vphone_jb_setup.sh")
            _ = try await ssh("/bin/chmod 0755 /mnt1/cores/vphone_jb_setup.sh")
        }
        if FileManager.default.fileExists(atPath: setupPlist.path) {
            try await scpTo(setupPlist.path, remotePath: "/mnt1/System/Library/LaunchDaemons/com.vphone.jb-setup.plist")
            _ = try await ssh("/bin/chmod 0644 /mnt1/System/Library/LaunchDaemons/com.vphone.jb-setup.plist")
            let localLaunchd = temporaryDirectory.appendingPathComponent("launchd.plist")
            try await scpFrom("/mnt1/System/Library/xpc/launchd.plist", localPath: localLaunchd.path)
            try injectLaunchDaemon(
                into: localLaunchd,
                daemonPlist: setupPlist,
                daemonKey: "/System/Library/LaunchDaemons/com.vphone.jb-setup.plist"
            )
            try await scpTo(localLaunchd.path, remotePath: "/mnt1/System/Library/xpc/launchd.plist")
            _ = try await ssh("/bin/chmod 0644 /mnt1/System/Library/xpc/launchd.plist")
        }
    }

    func injectDaemons(into launchdPlist: URL, directory: URL) throws {
        var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: launchdPlist), options: [], format: nil) as? [String: Any] ?? [:]
        var launchDaemons = plist["LaunchDaemons"] as? [String: Any] ?? [:]
        for name in ["bash", "dropbear", "trollvnc", "vphoned", "rpcserver_ios"] {
            let daemonURL = directory.appendingPathComponent("\(name).plist")
            guard FileManager.default.fileExists(atPath: daemonURL.path) else { continue }
            let daemon = try PropertyListSerialization.propertyList(from: Data(contentsOf: daemonURL), options: [], format: nil)
            launchDaemons["/System/Library/LaunchDaemons/\(name).plist"] = daemon
        }
        plist["LaunchDaemons"] = launchDaemons
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchdPlist)
    }

    func injectLaunchDaemon(into launchdPlist: URL, daemonPlist: URL, daemonKey: String) throws {
        var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: launchdPlist), options: [], format: nil) as? [String: Any] ?? [:]
        let daemon = try PropertyListSerialization.propertyList(from: Data(contentsOf: daemonPlist), options: [], format: nil)
        var launchDaemons = plist["LaunchDaemons"] as? [String: Any] ?? [:]
        launchDaemons[daemonKey] = daemon
        plist["LaunchDaemons"] = launchDaemons
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchdPlist)
    }

    func unmount(paths: [String]) async throws {
        for path in paths {
            _ = try await ssh("/sbin/umount \(path) 2>/dev/null || true", requireSuccess: false)
        }
    }

    func cleanupTemporaryFiles(_ names: [String]) throws {
        for name in names {
            let url = temporaryDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
