import Foundation
import VPhoneCoreKit
import VPhoneRestore

/// Restores the selected cloudOS firmware with this project's own VM and
/// idevicerestore backend when Apple's public AEA key is unavailable, and
/// takes what the guest needs from cloudOS off the restored System volume:
/// the GPU driver, and cryptexctl for a trusted darwinOS guest. The restored
/// device obtains the OS image key itself, the way pccvre's VMs do; WKMS
/// refuses the public one for cloudOS images at times (403 on 2026-11-10 and
/// 11, while it served iOS 26.5's).
enum VPhonePCCGPURecovery {
    enum Error: Swift.Error, LocalizedError {
        case identityTimedOut
        case recoveryTimedOut
        case toolFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .identityTimedOut:
                "The temporary PCC VM did not report its ECID. Try again."
            case .recoveryTimedOut:
                "The temporary PCC VM did not enter DFU or recovery mode. Try again."
            case let .toolFailed(tool, detail):
                "\(tool) failed while reading the restored PCC System volume: \(detail)"
            }
        }
    }

    static func stage(
        cloudOSDirectory: URL,
        into restoreDirectory: URL,
        expectedPlatformVersion: String,
        gpuDriver: Bool = true,
    ) throws {
        let fm = FileManager.default
        let temporaryLibrary = restoreDirectory.deletingLastPathComponent()
            .appending(path: ".pcc-restoration-\(UUID().uuidString)")
        let library = VPhoneLibrary(root: temporaryLibrary)
        let name = "pcc-\(UUID().uuidString.lowercased())"
        // The restore runs over the virtual USB device, so the machine needs no
        // NIC. With the default nat one, the Mac's shared vmnet network and its
        // DHCP service came up between the end of the restore and the stop.
        // Apple's ROMs: this restores Apple-signed PCC firmware, which OpenAVB
        // and OpenSEP have not been tried with.
        let vm = try VPhoneBundleOperations.create(.init(
            name: name,
            cpuCount: restoreCPUCount(platformVersion: expectedPlatformVersion),
            memoryMB: 8192,
            diskSizeGB: 64,
            romSource: VPhoneBootROM.appleSource,
            sepromSource: VPhoneSEPROM.appleSource,
            networkConfig: .init(mode: .off, macAddress: ""),
        ), in: library)
        var diskMayBeAttached = false
        let temporaryRestore = vm.url.appending(path: "iPhonePCC_Restore")
        defer {
            if !diskMayBeAttached {
                try? fm.removeItem(at: temporaryLibrary)
            } else {
                fputs("warning: PCC disk image may still be attached; left \(temporaryLibrary.path)\n", stderr)
            }
        }

        // The manifest already consumed this tree. Move it into the temporary
        // machine so restore reads only from that machine's directory.
        try fm.moveItem(at: cloudOSDirectory, to: temporaryRestore)
        try acceptVirtualDevice(manifest: temporaryRestore.appending(path: "BuildManifest.plist"))
        let launcher = try VPhoneGuestLaunchPlanner()
        let (executable, arguments) = launcher.plan(["--config", vm.configURL.path, "--dfu"])
        let dfu = VPhoneManagedProcess(executable, arguments, cwd: vm.url, echo: false)
        try dfu.start()
        defer { dfu.terminate(); _ = dfu.waitUntilExit() }

        let deadline = Date().addingTimeInterval(30)
        var ecid: UInt64?
        while Date() < deadline {
            if let value = VPhoneRestoreOperations.resolveECID(explicit: nil, bundle: vm),
               let parsed = try VPhoneRestoreIdentity.parseECID(value)
            {
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
            vmDir: vm.url,
            ecid: ecid,
            udid: VPhoneRestoreOperations.resolveUDID(bundle: vm),
            erase: true,
            ticketPath: nil,
            onEvent: VPhoneRestoreConsole.handler(level: .info),
        )
        dfu.terminate()
        _ = dfu.waitUntilExit()

        try stageFromSystemDisk(
            vm.url.appending(path: "Disk.img"),
            into: restoreDirectory, expectedPlatformVersion: expectedPlatformVersion,
            gpuDriver: gpuDriver,
            diskMayBeAttached: &diskMayBeAttached,
        )
    }

    /// vCPUs of the temporary VM. cloudOS 18's restore kernel with several
    /// vCPUs stops Virtualization.framework 308 (macOS 27.2) with a trap on a
    /// vCPU thread right after it is sent, so the device never enters restore
    /// mode (issue #901: cloudOS 18.6 failed 2 of 2 with 8 vCPUs and passed 2
    /// of 2 with 1). cloudOS 26 restores with 8.
    static func restoreCPUCount(platformVersion: String) -> UInt {
        guard let major = Int(platformVersion.prefix { $0 != "." }), major < 26 else { return 8 }
        return 1
    }

    /// The temporary VM reports iPhone99,11, which cloudOS releases after the
    /// 26.4 beta drop from `SupportedProductTypes` while keeping the
    /// vresearch101ap identity it restores. idevicerestore refuses a manifest
    /// that does not list the device, so add it to this copy.
    static func acceptVirtualDevice(manifest url: URL) throws {
        let productType = "iPhone99,11"
        guard var manifest = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil,
        ) as? [String: Any] else { return }
        let types = manifest["SupportedProductTypes"] as? [String] ?? []
        guard !types.contains(productType) else { return }
        manifest["SupportedProductTypes"] = types + [productType]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: url, options: .atomic)
    }

    private static func stageFromSystemDisk(
        _ diskImage: URL,
        into restoreDirectory: URL,
        expectedPlatformVersion: String,
        gpuDriver: Bool,
        diskMayBeAttached: inout Bool,
    ) throws {
        let fm = FileManager.default
        // A failed attach can still leave a device. Only a successful eject
        // permits deleting the temporary VM library.
        diskMayBeAttached = true
        let attached = try run("/usr/sbin/diskutil", [
            "image", "attach", "-readOnly", "-noMount", diskImage.path,
        ])
        // The synthesized APFS container can precede the image disk. Take
        // the parent of the store partition, as the CFW installer does.
        let devices = attached.split(whereSeparator: \.isNewline).compactMap { line -> (device: String, type: String)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].hasPrefix("/dev/disk") else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
        let store = devices.first(where: { $0.type == "Apple_APFS" })?.device
        let baseDisk = store.flatMap { device in
            device.range(of: "s", options: .backwards).map { String(device[..<$0.lowerBound]) }
        } ?? devices.first(where: { $0.type == "GUID_partition_scheme" })?.device
            ?? devices.first?.device
        guard let baseDisk, baseDisk.hasPrefix("/dev/disk") else {
            if let range = attached.range(of: #"/dev/disk[0-9]+"#, options: .regularExpression) {
                _ = try? run("/usr/sbin/diskutil", ["unmountDisk", "force", String(attached[range])])
                if (try? run("/usr/sbin/diskutil", ["eject", String(attached[range])])) != nil {
                    diskMayBeAttached = false
                }
            }
            throw Error.toolFailed("diskutil", "could not attach the PCC disk image. Try again.")
        }
        var mountToClean: URL?
        var diskAttached = true
        defer {
            if diskAttached {
                if (try? run("/usr/sbin/diskutil", ["eject", baseDisk])) != nil {
                    diskMayBeAttached = false
                } else if (try? run("/usr/sbin/diskutil", ["unmountDisk", "force", baseDisk])) != nil,
                          (try? run("/usr/sbin/diskutil", ["eject", baseDisk])) != nil
                {
                    diskMayBeAttached = false
                }
            }
            if let mountToClean {
                do {
                    guard let mounts = fm.mountedVolumeURLs(
                        includingResourceValuesForKeys: nil, options: [],
                    ) else {
                        throw Error.toolFailed("diskutil", "could not verify detached volumes")
                    }
                    let root = mountToClean.resolvingSymlinksInPath().path
                    guard !mounts.contains(where: { $0.resolvingSymlinksInPath().path == root }) else {
                        throw Error.toolFailed("diskutil", "PCC volume is still mounted")
                    }
                    try fm.removeItem(at: mountToClean)
                } catch {
                    fputs("warning: left PCC mount directory at \(mountToClean.path): \(error)\n", stderr)
                }
            }
        }

        let info = try run("/usr/sbin/diskutil", ["info", "-plist", "\(baseDisk)s1"])
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(info.utf8),
            format: nil,
        ) as? [String: Any],
            let container = plist["APFSContainerReference"] as? String,
            container.hasPrefix("disk")
        else { throw Error.toolFailed("diskutil", "could not find the restored system volume. Try again.") }

        let mount = restoreDirectory.deletingLastPathComponent()
            .appending(path: ".pcc-system-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        mountToClean = mount
        var mounted = false
        defer {
            if mounted, (try? run("/sbin/umount", [mount.path])) == nil {
                _ = try? run("/sbin/umount", ["-f", mount.path])
            }
        }
        mounted = true
        try run("/sbin/mount_apfs", ["-o", "rdonly", "/dev/\(container)s1", mount.path])

        if gpuDriver {
            let source = mount.appending(
                path: "System/Library/Extensions/\(VPhonePCCGPUDriver.name)",
            )
            try VPhonePCCGPUDriver.stage(
                from: source,
                into: restoreDirectory,
                expectedPlatformVersion: expectedPlatformVersion,
            )
        }
        // Taken whenever the system has it: a restore costs minutes, and the
        // preparer caches it for a later trusted darwinOS guest.
        let cryptexctl = mount.appending(path: VPhonePCCCryptexctl.guestPath)
        if fm.fileExists(atPath: cryptexctl.path) {
            try VPhonePCCCryptexctl.stage(file: cryptexctl, into: restoreDirectory)
        } else if !gpuDriver {
            throw VPhonePCCCryptexctl.Error.notFound(mount)
        }
        do {
            try run("/sbin/umount", [mount.path])
        } catch {
            try run("/sbin/umount", ["-f", mount.path])
        }
        mounted = false
        do {
            try run("/usr/sbin/diskutil", ["eject", baseDisk])
        } catch {
            try run("/usr/sbin/diskutil", ["unmountDisk", "force", baseDisk])
            try run("/usr/sbin/diskutil", ["eject", baseDisk])
        }
        diskAttached = false
        diskMayBeAttached = false
        print(gpuDriver ? "[+] GPU driver staged from cloudOS restored by vphone-cli" : "[+] cryptexctl staged from cloudOS restored by vphone-cli")
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
