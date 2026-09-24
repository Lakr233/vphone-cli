import Foundation
import VPhoneCore
import VPhoneRestore

/// Restores the selected cloudOS firmware with this project's own VM and
/// idevicerestore backend when Apple's public AEA key is unavailable.
enum VPhonePCCGPURecovery {
    enum Error: Swift.Error, LocalizedError {
        case identityTimedOut
        case recoveryTimedOut
        case toolFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .identityTimedOut:
                "Temporary PCC VM did not report its ECID"
            case .recoveryTimedOut:
                "Temporary PCC VM did not enter DFU/recovery mode"
            case let .toolFailed(tool, detail):
                "\(tool) failed while reading the restored PCC System volume: \(detail)"
            }
        }
    }

    static func stage(
        cloudOSDirectory: URL,
        into restoreDirectory: URL,
        expectedPlatformVersion: String,
    ) throws {
        let fm = FileManager.default
        let temporaryLibrary = restoreDirectory.deletingLastPathComponent()
            .appending(path: ".pcc-restoration")
        let library = VPhoneLibrary(root: temporaryLibrary)
        let name = "pcc-\(UUID().uuidString.lowercased())"
        let vm = try VPhoneBundleOperations.create(.init(
            name: name, cpuCount: 8, memoryMB: 8192, diskSizeGB: 64,
            romSource: VPhoneBundleOperations.defaultROMSource(),
            sepromSource: VPhoneBundleOperations.defaultSEPROMSource(),
        ), in: library)
        defer { try? fm.removeItem(at: temporaryLibrary) }

        // The restore backend accepts a linked directory. Reuse the already
        // extracted cloudOS tree instead of writing a second copy of its OS image.
        try fm.createSymbolicLink(
            at: vm.url.appending(path: "iPhonePCC_Restore"),
            withDestinationURL: cloudOSDirectory,
        )
        let launcher = try VPhoneGuestLaunchPlanner()
        let (executable, arguments) = launcher.plan(["--config", vm.configURL.path, "--dfu"])
        let dfu = VPhoneManagedProcess(executable, arguments, cwd: vm.url, echo: false)
        try dfu.start()
        defer { dfu.terminate(); _ = dfu.waitUntilExit() }

        let deadline = Date().addingTimeInterval(30)
        var ecid: UInt64?
        while Date() < deadline {
            if let value = VPhoneRestoreOperations.resolveECID(explicit: nil, bundle: vm),
               let parsed = try VPhoneRestoreIdentity.parseECID(value) {
                ecid = parsed
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        guard let ecid else { throw Error.identityTimedOut }
        var reachable = false
        for _ in 1 ... 90 {
            if (try? VPhoneRestoreService.recoveryProbe(ecid: ecid, timeout: 2)) != nil {
                reachable = true
                break
            }
            Thread.sleep(forTimeInterval: 2)
        }
        guard reachable else { throw Error.recoveryTimedOut }

        print("[*] Restoring cloudOS to temporary vphone VM (ECID 0x\(VPhoneRestoreIdentity.formatECID(ecid)))...")
        try VPhoneRestoreService.restore(
            vmDir: vm.url, ecid: ecid, udid: VPhoneRestoreOperations.resolveUDID(bundle: vm),
            erase: true, ticketPath: nil,
            onEvent: VPhoneRestoreConsole.handler(level: .info),
        )
        dfu.terminate()
        _ = dfu.waitUntilExit()

        try stageFromSystemDisk(
            vm.url.appending(path: "Disk.img"),
            into: restoreDirectory, expectedPlatformVersion: expectedPlatformVersion,
        )
    }

    private static func stageFromSystemDisk(
        _ diskImage: URL,
        into restoreDirectory: URL,
        expectedPlatformVersion: String,
    ) throws {
        let fm = FileManager.default
        let attached = try run("/usr/bin/hdiutil", [
            "attach", "-readonly", "-nomount", "-imagekey",
            "diskimage-class=CRawDiskImage", diskImage.path,
        ])
        guard let baseDisk = attached.split(whereSeparator: \.isNewline).first?
            .split(whereSeparator: \.isWhitespace).first.map(String.init),
            baseDisk.hasPrefix("/dev/disk")
        else { throw Error.toolFailed("hdiutil", "attached no disk device") }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", baseDisk]) }

        let info = try run("/usr/sbin/diskutil", ["info", "-plist", "\(baseDisk)s1"])
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(info.utf8), format: nil,
        ) as? [String: Any],
            let container = plist["APFSContainerReference"] as? String,
            container.hasPrefix("disk")
        else { throw Error.toolFailed("diskutil", "could not locate the restored APFS container") }

        let mount = restoreDirectory.deletingLastPathComponent()
            .appending(path: ".pcc-system-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        try run("/sbin/mount_apfs", ["-o", "rdonly", "/dev/\(container)s1", mount.path])
        defer { _ = try? run("/sbin/umount", [mount.path]) }

        let source = mount.appending(
            path: "System/Library/Extensions/\(VPhonePCCGPUDriver.name)",
        )
        try VPhonePCCGPUDriver.stage(
            from: source, into: restoreDirectory,
            expectedPlatformVersion: expectedPlatformVersion,
        )
        print("[+] GPU driver staged from cloudOS restored by vphone-cli")
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: executable), arguments,
        )
        guard result.succeeded else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw Error.toolFailed(URL(fileURLWithPath: executable).lastPathComponent,
                                   detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }
}
