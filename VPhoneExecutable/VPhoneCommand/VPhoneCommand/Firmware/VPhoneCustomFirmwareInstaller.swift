import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhoneSign

/// Host-side JB system installation. The VM must be off: all writes go to its
/// mounted Disk.img, while the source IPSWs and any other VM stay untouched.
struct VPhoneCustomFirmwareInstaller {
    let bundle: URL
    let resources: VPhoneResources
    let forceDyldSharedCacheMaxSlide: Bool

    private var executable: URL {
        VPhoneResources.runningExecutable()
    }

    private var fm: FileManager {
        .default
    }

    static func elevate(
        bundle: URL,
        resources: VPhoneResources,
        forceDyldSharedCacheMaxSlide: Bool,
    ) throws -> Int32 {
        if geteuid() == 0 {
            try VPhoneCustomFirmwareInstaller(
                bundle: bundle,
                resources: resources,
                forceDyldSharedCacheMaxSlide: forceDyldSharedCacheMaxSlide,
            ).run()
            return 0
        }
        throw ValidationError("CFW installation needs root. Run this command with sudo.")
    }

    func run() throws {
        guard geteuid() == 0 else { throw ValidationError("CFW install requires administrator privileges") }
        let invokingUser = VPhoneInvokingUser.current
        defer {
            if let invokingUser {
                do { try invokingUser.restoreOwnership(at: bundle) }
                catch { fputs("warning: could not restore VM ownership: \(error)\n", stderr) }
            }
            do { try VPhoneHostFilePermissions.makeAccessible(at: bundle) }
            catch { fputs("warning: could not set VM file permissions: \(error)\n", stderr) }
        }
        let diskImage = bundle.appendingPathComponent("Disk.img")
        guard fm.fileExists(atPath: diskImage.path) else {
            throw ValidationError("Disk.img is missing: \(diskImage.path)")
        }
        let busy = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/lsof"), [diskImage.path],
        )
        guard busy.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("VM disk is in use; stop the VM before installing CFW")
        }
        let capacity = try bundle.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity > 50 * 1024 * 1024 * 1024 else {
            throw ValidationError("Less than 50 GiB available; CFW install stopped before mounting")
        }

        let attached = try tool("/usr/bin/hdiutil", [
            "attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", diskImage.path,
        ])
        guard let baseDisk = attached.split(whereSeparator: \.isNewline).first?
            .split(whereSeparator: \.isWhitespace).first.map(String.init),
            baseDisk.hasPrefix("/dev/disk")
        else {
            if let range = attached.range(of: #"/dev/disk[0-9]+"#, options: .regularExpression) {
                _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", String(attached[range])], quiet: true)
            }
            throw ValidationError("hdiutil attached no disk device")
        }
        var diskAttached = true
        var workToClean: URL?
        defer {
            if diskAttached,
               (try? tool("/usr/bin/hdiutil", ["detach", baseDisk], quiet: true)) == nil
            {
                _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", baseDisk], quiet: true)
            }
            if let workToClean {
                do {
                    try removeWorkDirectory(workToClean)
                } catch {
                    fputs("warning: left CFW work directory at \(workToClean.path): \(error)\n", stderr)
                }
            }
        }

        let info = try tool("/usr/sbin/diskutil", ["info", "-plist", "\(baseDisk)s1"], quiet: true)
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(info.utf8),
            format: nil,
        ) as? [String: Any],
            let container = plist["APFSContainerReference"] as? String,
            container.hasPrefix("disk")
        else {
            throw ValidationError("Could not resolve the APFS container for \(baseDisk)")
        }
        let work = bundle.appendingPathComponent(".cfw-native-\(UUID().uuidString)")
        let system = work.appendingPathComponent("system")
        let data = work.appendingPathComponent("data")
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        workToClean = work
        var systemMounted = false
        var dataMounted = false
        defer {
            if dataMounted,
               (try? tool("/sbin/umount", [data.path], quiet: true)) == nil
            {
                _ = try? tool("/sbin/umount", ["-f", data.path], quiet: true)
            }
            if systemMounted,
               (try? tool("/sbin/umount", [system.path], quiet: true)) == nil
            {
                _ = try? tool("/sbin/umount", ["-f", system.path], quiet: true)
            }
        }
        try fm.createDirectory(at: system, withIntermediateDirectories: false)
        try fm.createDirectory(at: data, withIntermediateDirectories: false)
        try tool("/sbin/mount_apfs", ["-o", "rw", "/dev/\(container)s1", system.path])
        systemMounted = true
        try tool("/sbin/mount_apfs", ["-o", "rw", "/dev/\(container)s3", data.path])
        dataMounted = true
        print("[*] JB system install: \(bundle.lastPathComponent)")
        try installMounted(system: system, data: data, work: work)
        _ = try tool("/sbin/umount", [data.path])
        dataMounted = false
        _ = try tool("/sbin/umount", [system.path])
        systemMounted = false
        _ = try tool("/usr/bin/hdiutil", ["detach", baseDisk], quiet: true)
        diskAttached = false
        try VPhoneAPFSSnapshot.rename(imageAt: diskImage)
        print("[+] JB system install complete; vphoned is installed, no package bootstrap was staged")
    }

    private func installMounted(system: URL, data: URL, work: URL) throws {
        guard let restore = try fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.isDirectoryKey])
            .first(where: { $0.lastPathComponent.contains("Restore") &&
                    fm.fileExists(atPath: $0.appendingPathComponent("iPhone-BuildManifest.plist").path)
            })
        else {
            throw ValidationError("No prepared iPhone restore tree exists in \(bundle.path)")
        }
        try installCryptexes(restore: restore, system: system, work: work)
        let version = try productVersion(system: system)
        let dsc = system.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
        if version.hasPrefix("27.") {
            try patch("patch-iomfb-force-kern", [dsc.path])
            try patch("patch-dsc-maxslide", [dsc.path])
            try patch("patch-lsd-embedded-reg", [dsc.path])
            try patch("patch-xpc-lwcr", [dsc.path])
            try patch("patch-lockdown-mode", [dsc.path])
        } else if version.hasPrefix("26.0") || version.hasPrefix("18.") {
            try patch("patch-iomfb-swapend", [dsc.path, "--target-size", "0x560"])
        } else if forceDyldSharedCacheMaxSlide {
            try patch("patch-dsc-maxslide", [dsc.path, "--force"])
        }
        try patchMachO(
            system: system,
            work: work,
            path: "usr/libexec/seputil",
            verb: "patch-seputil",
            identifier: "com.apple.seputil",
        )
        if version.hasPrefix("27.") {
            try patchMachO(
                system: system,
                work: work,
                path: "usr/libexec/diskimagesiod",
                verb: "patch-diskimagesiod",
                preserveEntitlements: true,
            )
        }
        try renameGigalocker(data: data)
        let gpuSource = VPhonePCCGPUDriver.stagedBundle(in: restore)
        guard fm.fileExists(atPath: gpuSource.path) else {
            throw ValidationError("PCC GPU driver is missing: \(gpuSource.path). Re-run fw prepare with the PCC IPSW.")
        }
        let gpu = system.appendingPathComponent(
            "System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle",
        )
        if fm.fileExists(atPath: gpu.path) {
            try fm.removeItem(at: gpu)
        }
        try fm.copyItem(at: gpuSource, to: gpu)
        try tool("/usr/sbin/chown", ["-R", "0:0", gpu.path])
        for file in [gpu, gpu.appendingPathComponent("AppleParavirtGPUMetalIOGPUFamily"),
                     gpu.appendingPathComponent("_CodeSignature")]
        {
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        }
        let compilerPlugin = gpu.appendingPathComponent("libAppleParavirtCompilerPluginIOGPUFamily.dylib")
        guard fm.fileExists(atPath: compilerPlugin.path) else {
            throw ValidationError("PCC GPU compiler plugin is missing: \(compilerPlugin.path). Re-run fw prepare with a complete vphone-cli.app.")
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: compilerPlugin.path)
        for file in [gpu.appendingPathComponent("Info.plist"),
                     gpu.appendingPathComponent("_CodeSignature/CodeResources")]
        {
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)
        }
        try patchMachO(
            system: system,
            work: work,
            path: "usr/libexec/launchd_cache_loader",
            verb: "patch-launchd-cache-loader",
            identifier: "com.apple.launchd_cache_loader",
        )
        try patchMachO(
            system: system,
            work: work,
            path: "usr/libexec/mobileactivationd",
            verb: "patch-mobileactivationd",
        )
        try installVphoned(system: system, work: work)
        try patchMachO(
            system: system,
            work: work,
            path: "sbin/launchd",
            verb: "patch-launchd-jetsam",
            preserveEntitlements: true,
        )
        try patchDebugserver(system: system, work: work)
        if version.hasPrefix("27.") {
            try patchCampo(system: system, work: work)
        }
    }

    private func installCryptexes(restore: URL, system: URL, work: URL) throws {
        let os = system.appendingPathComponent("System/Cryptexes/OS")
        let app = system.appendingPathComponent("System/Cryptexes/App")
        if !((try? fm.contentsOfDirectory(atPath: os.path))?.isEmpty == false &&
            (try? fm.contentsOfDirectory(atPath: app.path))?.isEmpty == false)
        {
            let paths = try CustomFirmwareDaemons.cryptexPaths(
                buildManifest: restore.appendingPathComponent("iPhone-BuildManifest.plist"),
            )
            let encrypted = restore.appendingPathComponent(paths.systemOS)
            let appImage = restore.appendingPathComponent(paths.appOS)
            let plain = work.appendingPathComponent("SystemOS.dmg")
            let key = try vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: encrypted) }
            try tool(
                "/usr/bin/aea",
                ["decrypt", "-i", encrypted.path,
                 "-o", plain.path, "-key-value", key],
                quiet: true,
            )
            let osMount = work.appendingPathComponent("mnt-os")
            let appMount = work.appendingPathComponent("mnt-app")
            try fm.createDirectory(at: osMount, withIntermediateDirectories: true)
            try fm.createDirectory(at: appMount, withIntermediateDirectories: true)
            try tool(
                "/usr/bin/hdiutil",
                ["attach", "-mountpoint", osMount.path,
                 plain.path, "-nobrowse", "-owners", "off"],
                quiet: true,
            )
            defer { _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", osMount.path], quiet: true) }
            try tool(
                "/usr/bin/hdiutil",
                ["attach", "-mountpoint", appMount.path,
                 appImage.path,
                 "-nobrowse", "-owners", "off"],
                quiet: true,
            )
            defer { _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", appMount.path], quiet: true) }
            for (source, destination) in [(osMount, os), (appMount, app)] {
                // The restored rootfs has dangling Cryptex symlinks. fileExists
                // follows those links and reports false until Preboot is populated.
                if fm.fileExists(atPath: destination.path) ||
                    (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil
                {
                    try fm.removeItem(at: destination)
                }
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
                }
            }
        }
        try symlink("../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
                    at: system.appendingPathComponent("System/Library/Caches/com.apple.dyld"))
        try symlink("../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld",
                    at: system.appendingPathComponent("System/DriverKit/System/Library/dyld"))
    }

    private func installVphoned(system: URL, work: URL) throws {
        let vphoned = try VPhoneGuestBinaries.resolve("vphoned")
        let staged = work.appendingPathComponent("vphoned")
        try fm.copyItem(at: vphoned, to: staged)
        let entitlementsURL = resources.scriptsDir.appendingPathComponent("vphoned/VPhoneDaemon.entitlements")
        let entitlements = try Data(contentsOf: entitlementsURL, options: .mappedIfSafe)
        try VPhoneSigner.sign(fileAt: staged,
                              options: .init(entitlements: entitlements, mergesExisting: true))
        try replace(staged, at: system.appendingPathComponent("usr/bin/vphoned"), mode: 0o755)
        let signed = bundle.appendingPathComponent(".vphoned.signed")
        if fm.fileExists(atPath: signed.path) {
            try fm.removeItem(at: signed)
        }
        try fm.copyItem(at: staged, to: signed)
        let daemon = resources.scriptsDir.appendingPathComponent("vphoned/vphoned.plist")
        try replace(daemon, at: system.appendingPathComponent(
            "System/Library/LaunchDaemons/vphoned.plist",
        ), mode: 0o644)
        let launchd = system.appendingPathComponent("System/Library/xpc/launchd.plist")
        let backup = launchd.appendingPathExtension("bak")
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: launchd, to: backup)
        }
        let temp = work.appendingPathComponent("launchd.plist")
        try fm.copyItem(at: backup, to: temp)
        try CustomFirmwareDaemons.injectDaemon(into: temp, name: "vphoned", from: daemon)
        try replace(temp, at: launchd, mode: 0o644)
    }

    private func patchMachO(
        system: URL,
        work: URL,
        path: String,
        verb: String,
        identifier: String? = nil,
        preserveEntitlements: Bool = false,
    ) throws {
        let target = system.appendingPathComponent(path)
        let backup = target.appendingPathExtension("bak")
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: target, to: backup)
        }
        let staged = work.appendingPathComponent(target.lastPathComponent)
        if fm.fileExists(atPath: staged.path) {
            try fm.removeItem(at: staged)
        }
        try fm.copyItem(at: backup, to: staged)
        let entitlements = preserveEntitlements
            ? try VPhoneSigner.entitlements(ofFileAt: backup).first(where: { !$0.isEmpty })
            : nil
        try patch(verb, [staged.path])
        try VPhoneSigner.sign(fileAt: staged,
                              options: .init(identifier: identifier, entitlements: entitlements, mergesExisting: true))
        try replace(staged, at: target, mode: 0o755)
    }

    private func patchDebugserver(system: URL, work: URL) throws {
        let target = system.appendingPathComponent("usr/libexec/debugserver")
        guard fm.fileExists(atPath: target.path) else {
            print("[!] debugserver absent; entitlement patch skipped")
            return
        }
        guard let source = try VPhoneSigner.entitlements(ofFileAt: target)
            .first(where: { !$0.isEmpty }),
            var plist = try PropertyListSerialization.propertyList(
                from: source, format: nil,
            ) as? [String: Any]
        else {
            print("[!] debugserver has no readable entitlements; patch skipped")
            return
        }
        plist.removeValue(forKey: "seatbelt-profiles")
        plist["task_for_pid-allow"] = true
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        let staged = work.appendingPathComponent("debugserver")
        try fm.copyItem(at: target, to: staged)
        try VPhoneSigner.sign(fileAt: staged,
                              options: .init(entitlements: data, mergesExisting: true))
        try replace(staged, at: target, mode: 0o755)
    }

    private func patchCampo(system: URL, work: URL) throws {
        let target = system.appendingPathComponent("Applications/Campo.app/Campo")
        guard fm.fileExists(atPath: target.path) else {
            print("[!] Campo absent; entitlement patch skipped")
            return
        }
        guard let source = try VPhoneSigner.entitlements(ofFileAt: target)
            .first(where: { !$0.isEmpty })
        else {
            print("[!] Campo has no readable entitlements; patch skipped")
            return
        }
        let ent = work.appendingPathComponent("Campo.entitlements")
        try source.write(to: ent)
        try patch("patch-campo-entitlements", [ent.path])
        let staged = work.appendingPathComponent("Campo")
        try fm.copyItem(at: target, to: staged)
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(
                entitlements: Data(contentsOf: ent, options: .mappedIfSafe),
                mergesExisting: true,
            ),
        )
        try replace(staged, at: target, mode: 0o755)
    }

    private func renameGigalocker(data: URL) throws {
        let files = try fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)
        for source in files where source.pathExtension == "gl" {
            let destination = data.appendingPathComponent("AA.gl")
            if source == destination {
                continue
            }
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: source, to: destination)
        }
    }

    private func productVersion(system: URL) throws -> String {
        let plist = system.appendingPathComponent(
            "System/Library/CoreServices/SystemVersion.plist",
        )
        guard let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist, options: .mappedIfSafe),
            format: nil,
        ) as? [String: Any],
            let version = value["ProductVersion"] as? String
        else {
            throw ValidationError("SystemVersion.plist has no ProductVersion")
        }
        return version
    }

    private func symlink(_ destination: String, at path: URL) throws {
        if fm.fileExists(atPath: path.path)
            || (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        {
            try fm.removeItem(at: path)
        }
        try fm.createSymbolicLink(atPath: path.path, withDestinationPath: destination)
    }

    private func replace(_ source: URL, at destination: URL, mode: Int) throws {
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destination.path)
    }

    private func removeWorkDirectory(_ work: URL) throws {
        guard let mounts = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            throw ValidationError("Could not verify that CFW volumes are detached")
        }
        let root = work.resolvingSymlinksInPath().path
        guard !mounts.contains(where: {
            let path = $0.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }) else {
            throw ValidationError("CFW volume is still mounted under \(work.path)")
        }
        try fm.removeItem(at: work)
    }

    @discardableResult
    private func patch(_ verb: String, _ arguments: [String]) throws -> String {
        try tool(executable.path, ["cfw", verb] + arguments)
    }

    @discardableResult
    private func tool(_ path: String, _ arguments: [String], quiet: Bool = false) throws -> String {
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: path), arguments)
        if !quiet {
            if !result.stdout.isEmpty {
                print(result.stdout, terminator: "")
            }
            if !result.stderr.isEmpty {
                fputs(result.stderr, stderr)
            }
        }
        guard result.succeeded else {
            throw ValidationError("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(result.exitCode)): \(result.stderr)")
        }
        return result.stdout
    }
}

struct VPhoneCustomFirmwareInstallRootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-root", abstract: "Internal privileged JB disk install",
        shouldDisplay: false,
    )

    @Argument(help: "VM bundle path") var bundle: String
    @Option(help: "Resource base") var resources: String
    @Flag(name: .customLong("force-dsc-maxslide")) var forceDyldSharedCacheMaxSlide = false

    func run() throws {
        try VPhoneCustomFirmwareInstaller(
            bundle: URL(fileURLWithPath: bundle),
            resources: VPhoneResources(base: URL(fileURLWithPath: resources)),
            forceDyldSharedCacheMaxSlide: forceDyldSharedCacheMaxSlide,
        ).run()
    }
}
