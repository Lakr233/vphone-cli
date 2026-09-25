import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhoneSign

/// Host-side JB system installation. The VM must be off: all writes go to its
/// mounted Disk.img, while the source IPSWs and any other VM stay untouched.
///
/// This runs as root, under sudo or from the Launchpad helper, against a VM
/// folder the caller controls (0777 by workstation policy) and a Disk.img
/// whose volumes hold whatever the guest or an import left there. So:
/// - the bundle is pinned once by descriptor and never rebuilt from its path;
/// - Disk.img, the restore tree and the Cryptex images must be regular,
///   single-link files owned by the caller, and only private copies of them
///   in a root-only work folder are attached;
/// - the guest volumes are mounted inside that 0700 folder, and every guest
///   read and write is descriptor relative (`VPhoneConfinedDirectory`), so a
///   symbolic link inside the guest can never point root at a host path;
/// - root hands back only the files it created, by descriptor. It never walks
///   the caller's folder to chown or chmod it.
struct VPhoneCustomFirmwareInstaller {
    let bundle: URL
    let resources: VPhoneResources
    let forceDyldSharedCacheMaxSlide: Bool

    /// Guest system files belong to root:wheel.
    private static let guestOwner: (uid: uid_t, gid: gid_t) = (0, 0)

    /// Root-owned and sticky, outside every user's tree. The work folder is
    /// made here with `mkdtemp`, so its name cannot be predicted or claimed.
    private static let workParent = "/private/var/tmp"

    private var executable: URL {
        VPhoneResources.runningExecutable()
    }

    private var fm: FileManager {
        .default
    }

    private var spoofBuild: String? {
        guard let build = ProcessInfo.processInfo.environment["SPOOF_BUILD"], !build.isEmpty else {
            return nil
        }
        return build
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

    // MARK: - Work folder

    /// Root-only scratch space. The guest volumes are mounted here, so no
    /// other account can reach them while they are mounted, and staged copies
    /// can be handed to patch tools by path: nobody else can change a
    /// component of a path under it.
    private struct WorkDirectory {
        let name: String
        let url: URL
        let directory: VPhoneConfinedDirectory

        func file(_ name: String) -> URL {
            url.appendingPathComponent(name)
        }
    }

    // MARK: - Install

    func run() throws {
        guard geteuid() == 0 else { throw ValidationError("CFW installation needs root. Run this command with sudo.") }
        // Ownership checks apply when the caller is known (SUDO_UID, which
        // the Launchpad helper also sets). Plain root trusts its own files.
        let invokingUser = VPhoneInvokingUser.current
        let callerUID = invokingUser?.uid

        let bundleDirectory = try pinBundle(owner: callerUID)
        let bundlePath = try bundleDirectory.path
        let disk = try openDiskImage(in: bundleDirectory, path: bundlePath, owner: callerUID)
        let diskPath = (bundlePath as NSString).appendingPathComponent("Disk.img")
        let busy = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/lsof"), [diskPath],
        )
        guard busy.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("The VM disk is in use. Stop the VM, then install CFW again.")
        }
        let restore = try restoreTree(in: bundleDirectory, path: bundlePath, owner: callerUID)

        let work = try makeWorkDirectory()
        defer {
            do {
                try removeWorkDirectory(work)
            } catch {
                fputs("warning: left CFW work directory at \(work.url.path): \(error)\n", stderr)
            }
        }
        try requireFreeSpace(at: [bundlePath, work.url.path])

        // Work on an APFS clone of Disk.img in the private folder, then rename
        // it over the original: nothing is attached from the caller's folder,
        // and a failed install leaves the original untouched.
        let image: URL
        let cloned = try work.directory.clone(disk, to: "Disk.img")
        if cloned {
            image = work.file("Disk.img")
        } else {
            // Another volume, or no clone support: attach the caller's file
            // in place. Confirm the name still refers to the inode verified
            // above immediately before hdiutil opens it. A swap in the moment
            // between this check and hdiutil's own open remains possible;
            // the clone path, the normal case on APFS, has no such window.
            guard try bundleDirectory.refersTo("Disk.img", file: disk) else {
                throw ValidationError("The VM disk image changed during the install. Try again.")
            }
            image = try URL(fileURLWithPath: bundleDirectory.path).appendingPathComponent("Disk.img")
        }

        let attached = try tool(
            "/usr/bin/hdiutil",
            [
                "attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", image.path,
            ],
        )
        guard
            let baseDisk = attached.split(whereSeparator: \.isNewline).first?
            .split(whereSeparator: \.isWhitespace).first.map(String.init),
            baseDisk.hasPrefix("/dev/disk")
        else {
            if let range = attached.range(of: #"/dev/disk[0-9]+"#, options: .regularExpression) {
                _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", String(attached[range])], quiet: true)
            }
            throw ValidationError("Unable to attach the VM disk image. Try again.")
        }
        var diskAttached = true
        defer {
            if diskAttached,
               (try? tool("/usr/bin/hdiutil", ["detach", baseDisk], quiet: true)) == nil
            {
                _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", baseDisk], quiet: true)
            }
        }

        let info = try tool("/usr/sbin/diskutil", ["info", "-plist", "\(baseDisk)s1"], quiet: true)
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: Data(info.utf8),
                format: nil,
            ) as? [String: Any],
            let container = plist["APFSContainerReference"] as? String,
            container.hasPrefix("disk")
        else {
            throw ValidationError("Unable to read the VM disk image. Try again.")
        }
        let volumes = try containerVolumes(
            container,
            physicalStore: "\(baseDisk.dropFirst("/dev/".count))s1",
        )

        let system = work.file("system")
        let data = work.file("data")
        _ = try work.directory.directory("system", create: true, mode: 0o700)
        _ = try work.directory.directory("data", create: true, mode: 0o700)
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
        systemMounted = true
        try mountGuestVolume("\(container)s1", at: system)
        dataMounted = true
        try mountGuestVolume("\(container)s3", at: data)
        print("[*] JB system install: \(bundle.lastPathComponent)")
        do {
            // Every descriptor on a guest volume lives in this scope, so none
            // is left open to hold the volume busy when it is unmounted.
            let systemRoot = try openGuestVolume("system", device: "\(container)s1", in: work)
            let dataRoot = try openGuestVolume("data", device: "\(container)s3", in: work)
            try installMounted(system: systemRoot, data: dataRoot, restore: restore, work: work, owner: callerUID)
        }
        try patchPreboot(volumes: volumes, work: work)
        _ = try tool("/sbin/umount", [data.path])
        dataMounted = false
        _ = try tool("/sbin/umount", [system.path])
        systemMounted = false
        _ = try tool("/usr/bin/hdiutil", ["detach", baseDisk], quiet: true)
        diskAttached = false
        try VPhoneAPFSSnapshot.rename(imageAt: image)
        if cloned {
            // Hand the clone back with the original's owner and mode, then
            // swap it in by rename through the pinned bundle descriptor.
            try work.directory.setOwner("Disk.img", uid: disk.owner, gid: disk.group)
            try work.directory.setMode("Disk.img", disk.mode & 0o777)
            try work.directory.rename("Disk.img", to: "Disk.img", in: bundleDirectory)
        }
        try installSignedDaemonCopy(
            in: bundleDirectory,
            work: work,
            owner: invokingUser.map { ($0.uid, $0.gid) },
        )
        print("[+] JB system install complete; vphoned is installed, no package bootstrap was staged")
    }

    // MARK: - Host inputs

    /// Resolve the bundle once, then hold it by descriptor. Every later
    /// bundle-relative access goes through this descriptor, so renaming a
    /// folder or planting a link after this point cannot redirect root.
    private func pinBundle(owner: uid_t?) throws -> VPhoneConfinedDirectory {
        guard let resolved = realpath(bundle.path, nil) else {
            throw ValidationError("The VM folder \(bundle.path) does not exist. Create the VM again, then install CFW.")
        }
        let path = String(cString: resolved)
        free(resolved)
        do {
            return try VPhoneConfinedDirectory.pin(absolutePath: path, requireOwner: owner)
        } catch {
            throw ValidationError("The VM folder \(path) cannot be used for a root install: \(error)")
        }
    }

    /// Disk.img must be a regular file with one link, owned by the caller:
    /// a hard link or a file swapped in by another account is refused.
    private func openDiskImage(
        in bundle: VPhoneConfinedDirectory,
        path: String,
        owner: uid_t?,
    ) throws -> VPhoneConfinedFile {
        do {
            return try bundle.openRegularFile("Disk.img", requireOwner: owner, requireSingleLink: true)
        } catch VPhoneConfinedDirectoryError.missing {
            throw ValidationError("The VM disk image is missing: \(path)/Disk.img. Create the VM again, then install CFW.")
        } catch {
            throw ValidationError("The VM disk image cannot be used for a root install: \(error)")
        }
    }

    /// The prepared restore tree: a real folder (not a link) owned by the
    /// caller, holding iPhone-BuildManifest.plist. `iPhone*_Restore` is what
    /// `fw prepare` writes; any other `*Restore*` folder is the older fallback.
    private func restoreTree(
        in bundle: VPhoneConfinedDirectory,
        path: String,
        owner: uid_t?,
    ) throws -> VPhoneConfinedDirectory {
        let entries = try bundle.entries()
        let preferred = entries.filter { $0.hasPrefix("iPhone") && $0.hasSuffix("_Restore") }.sorted(by: >)
        let fallback = entries.filter { $0.contains("Restore") && !preferred.contains($0) }
        var foreign: String?
        for name in preferred + fallback {
            guard try bundle.isDirectory(name),
                  let directory = try? bundle.directory(name),
                  (try? directory.isRegularFile("iPhone-BuildManifest.plist")) == true
            else { continue }
            if let owner, try directory.metadata().st_uid != owner {
                foreign = foreign ?? name
                continue
            }
            return directory
        }
        if let foreign {
            throw ValidationError("The restore tree \(path)/\(foreign) is not owned by your account. Run fw prepare as yourself, then install CFW again.")
        }
        throw ValidationError("No prepared iPhone restore tree was found in \(path). Run fw prepare, then install CFW again.")
    }

    private func requireFreeSpace(at paths: [String]) throws {
        var seen = Set<dev_t>()
        for path in paths {
            var metadata = stat()
            guard stat(path, &metadata) == 0, seen.insert(metadata.st_dev).inserted else { continue }
            let capacity =
                try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity > 50 * 1024 * 1024 * 1024 else {
                throw ValidationError("Less than 50 GiB of disk space is available on the volume holding \(path). Free up space, then install CFW again.")
            }
        }
    }

    // MARK: - Volumes

    /// The container's volumes, after confirming it sits on the disk just
    /// attached rather than some other container with the same number.
    private func containerVolumes(_ container: String, physicalStore: String) throws -> [[String: Any]] {
        let output = try tool("/usr/sbin/diskutil", ["apfs", "list", "-plist", container], quiet: true)
        guard
            let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil)
            as? [String: Any],
            let containers = plist["Containers"] as? [[String: Any]],
            let entry = containers.first(where: { $0["ContainerReference"] as? String == container }),
            let stores = entry["PhysicalStores"] as? [[String: Any]],
            stores.contains(where: { $0["DeviceIdentifier"] as? String == physicalStore }),
            let volumes = entry["Volumes"] as? [[String: Any]]
        else {
            throw ValidationError("The APFS container \(container) is not on the attached VM disk. Try again.")
        }
        return volumes
    }

    /// Guest volumes are untrusted: a restored or imported Disk.img can carry
    /// set-ID binaries and device nodes. nosuid and nodev keep them inert on
    /// the host while mounted, and nobrowse keeps the volumes out of Finder
    /// and Spotlight. Ownership stays honoured (no noowners): the guest's
    /// root:wheel and mobile ownership must survive the install.
    private func mountGuestVolume(_ device: String, at mountPoint: URL) throws {
        try tool("/sbin/mount_apfs", ["-o", "rw,nosuid,nodev,nobrowse", "/dev/\(device)", mountPoint.path])
    }

    /// Open a mounted guest volume's root and confirm the expected device is
    /// what is mounted there.
    private func openGuestVolume(_ name: String, device: String, in work: WorkDirectory) throws
        -> VPhoneConfinedDirectory
    {
        let root = try work.directory.mountedVolume(name)
        let source = try root.mountedFrom()
        guard source == "/dev/\(device)" else {
            throw ValidationError("Expected /dev/\(device) on \(work.file(name).path), found \(source). Try again.")
        }
        return root
    }

    // MARK: - System volume

    private func installMounted(
        system: VPhoneConfinedDirectory,
        data: VPhoneConfinedDirectory,
        restore: VPhoneConfinedDirectory,
        work: WorkDirectory,
        owner: uid_t?,
    ) throws {
        try installCryptexes(restore: restore, system: system, work: work, owner: owner)
        let version = try productVersion(system: system)
        let dsc = try verifiedDyldCacheDirectory(system: system)
        if version.hasPrefix("27.") {
            try patch("patch-iomfb-force-kern", [dsc])
            try patch("patch-dsc-maxslide", [dsc])
            try patch("patch-lsd-embedded-reg", [dsc])
            try patch("patch-xpc-lwcr", [dsc])
            try patch("patch-lockdown-mode", [dsc])
        } else if version.hasPrefix("26.0") || version.hasPrefix("18.") {
            try patch("patch-iomfb-swapend", [dsc, "--target-size", "0x560"])
        } else if forceDyldSharedCacheMaxSlide {
            try patch("patch-dsc-maxslide", [dsc, "--force"])
        }
        // These former EXP patches pair with the kernel OID rename and the
        // camera DeviceTree additions in the public JB firmware pipeline.
        try patch("patch-hv-vmm-dsc", [dsc])
        try patch("patch-camera-dsc", [dsc, (dsc as NSString).appendingPathComponent("dyld_shared_cache_arm64e")])
        if let build = spoofBuild {
            for path in [
                "System/Library/CoreServices/SystemVersion.plist",
                "System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist",
            ] {
                try patchCopy(of: path, in: system, work: work, verb: "patch-build-version", arguments: [build])
            }
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
        try installGPUBundle(restore: restore, system: system, owner: owner)
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
        try patchWatchdog(system: system, work: work)
        try installVphoned(system: system, work: work)
        try installEnvironment(system: system)
        try patchMachO(
            system: system,
            work: work,
            path: "sbin/launchd",
            verb: "patch-launchd-jetsam",
            preserveEntitlements: true,
            injectedDylibPath: "/vh",
        )
        try patchDebugserver(system: system, work: work)
        if version.hasPrefix("27.") {
            try patchCampo(system: system, work: work)
        }
    }

    /// The dsc verbs patch a multi-gigabyte folder in place, too large to
    /// stage. Open it without following any link, require plain single-link
    /// files in it, and hand the tools that verified path. The path is
    /// stable: the volume is mounted inside the root-only work folder and
    /// nothing else writes to it during the install.
    private func verifiedDyldCacheDirectory(system: VPhoneConfinedDirectory) throws -> String {
        let relative = "System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
        let directory = try system.directory(relative)
        for name in try directory.entries() {
            guard let metadata = try directory.status(name) else { continue }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG where metadata.st_nlink == 1:
                continue
            default:
                throw ValidationError("\(relative)/\(name) on the VM system volume is not a plain file. Restore the VM, then install CFW again.")
            }
        }
        return try directory.path
    }

    private func installCryptexes(
        restore: VPhoneConfinedDirectory,
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        owner: uid_t?,
    ) throws {
        let os = "System/Cryptexes/OS"
        let app = "System/Cryptexes/App"
        func populated(_ path: String) -> Bool {
            (try? system.directory(path).entries().isEmpty) == false
        }
        if !(populated(os) && populated(app)) {
            let manifest = work.file("iPhone-BuildManifest.plist")
            try restore.readData("iPhone-BuildManifest.plist").write(to: manifest)
            let paths = try CustomFirmwareDaemons.cryptexPaths(buildManifest: manifest)
            // Root attaches and decrypts only private copies of the images,
            // taken from descriptors verified to be the caller's own files.
            let systemImage = try stageCryptexImage(paths.systemOS, from: restore, as: "SystemOS-source.dmg", work: work, owner: owner)
            let appImage = try stageCryptexImage(paths.appOS, from: restore, as: "AppOS.dmg", work: work, owner: owner)
            // `restore --offline` decrypts the image in place and keeps its
            // .aea name, so the file may already be a plain disk image.
            var plain = systemImage
            if try VPhoneRestoreOperations.isAEAEncrypted(systemImage) {
                plain = work.file("SystemOS.dmg")
                let key = try vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: systemImage) }
                try tool(
                    "/usr/bin/aea",
                    [
                        "decrypt", "-i", systemImage.path,
                        "-o", plain.path, "-key-value", key,
                    ],
                    quiet: true,
                )
            }
            let osMount = work.file("mnt-os")
            let appMount = work.file("mnt-app")
            _ = try work.directory.directory("mnt-os", create: true, mode: 0o700)
            _ = try work.directory.directory("mnt-app", create: true, mode: 0o700)
            var osNeedsDetach = true
            defer {
                if osNeedsDetach {
                    try? detachImage(at: osMount)
                }
            }
            try attachCryptex(plain, at: osMount)
            var appNeedsDetach = true
            defer {
                if appNeedsDetach {
                    try? detachImage(at: appMount)
                }
            }
            try attachCryptex(appImage, at: appMount)
            do {
                for (mount, destination) in [("mnt-os", os), ("mnt-app", app)] {
                    let source = try work.directory.mountedVolume(mount)
                    // The restored rootfs has dangling Cryptex symlinks; they
                    // are removed as links. Set-ID bits are kept: this is
                    // Apple's content for the guest, the guest volume is
                    // mounted nosuid, and the copy never follows a link.
                    try system.removeItem(destination)
                    try system.copyTree(from: source, to: destination, clearSetID: false)
                }
            }
            try detachImage(at: appMount)
            appNeedsDetach = false
            try detachImage(at: osMount)
            osNeedsDetach = false
        }
        try system.createSymlink(
            target: "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
            at: "System/Library/Caches/com.apple.dyld",
        )
        try system.createSymlink(
            target: "../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld",
            at: "System/DriverKit/System/Library/dyld",
        )
    }

    /// Open a manifest-named image inside the restore tree without following
    /// a link, require a single-link regular file owned by the caller, and
    /// clone (or, across volumes, copy) that very descriptor into the work
    /// folder. Root never attaches a path the caller could swap.
    private func stageCryptexImage(
        _ relative: String,
        from restore: VPhoneConfinedDirectory,
        as name: String,
        work: WorkDirectory,
        owner: uid_t?,
    ) throws -> URL {
        let image: VPhoneConfinedFile
        do {
            image = try restore.openRegularFile(relative, requireOwner: owner, requireSingleLink: true)
        } catch {
            throw ValidationError("The Cryptex image \(relative) cannot be used for a root install: \(error). Run fw prepare, then install CFW again.")
        }
        if try !work.directory.clone(image, to: name) {
            try work.directory.copy(image, to: name)
        }
        return work.file(name)
    }

    /// Cryptex images are only read from. hdiutil applies nosuid to disk
    /// image mounts itself and does not take mount options, so the other
    /// guards are the read-only attach, the mount point inside the root-only
    /// work folder, and `copyTree`, which never follows a link and refuses
    /// device nodes.
    private func attachCryptex(_ image: URL, at mountPoint: URL) throws {
        try tool(
            "/usr/bin/hdiutil",
            [
                "attach", "-readonly", "-noautoopen", "-nobrowse", "-owners", "off",
                "-mountpoint", mountPoint.path, image.path,
            ],
            quiet: true,
        )
    }

    /// Replace the paravirtual GPU bundle with the one `fw prepare` staged in
    /// the restore tree. The source is the caller's: every entry must be
    /// theirs, no file may be hard linked, links are copied as links, and the
    /// copy is owned by root with set-ID bits cleared.
    private func installGPUBundle(
        restore: VPhoneConfinedDirectory,
        system: VPhoneConfinedDirectory,
        owner: uid_t?,
    ) throws {
        let staged = ".pcc-gpu/\(VPhonePCCGPUDriver.name)"
        guard try restore.isDirectory(staged) else {
            throw try ValidationError("PCC GPU driver is missing: \(restore.path)/\(staged). Re-run fw prepare with the PCC IPSW.")
        }
        let source = try restore.directory(staged)
        let gpu = "System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
        try system.removeItem(gpu)
        try system.copyTree(from: source, to: gpu, requireSourceOwner: owner, owner: Self.guestOwner)
        for file in [gpu, "\(gpu)/AppleParavirtGPUMetalIOGPUFamily", "\(gpu)/_CodeSignature"] {
            try system.setMode(file, 0o755)
        }
        let compilerPlugin = "\(gpu)/libAppleParavirtCompilerPluginIOGPUFamily.dylib"
        guard try system.exists(compilerPlugin) else {
            throw ValidationError(
                "PCC GPU compiler plugin is missing: \(compilerPlugin). Re-run fw prepare with a complete vphone-cli.app.",
            )
        }
        try system.setMode(compilerPlugin, 0o755)
        for file in ["\(gpu)/Info.plist", "\(gpu)/_CodeSignature/CodeResources"] {
            try system.setMode(file, 0o644)
        }
    }

    private func installVphoned(system: VPhoneConfinedDirectory, work: WorkDirectory) throws {
        // Install the same signed bytes that vm launch uses for auto-update.
        // Re-signing here changes the binary hash and forces an upload and
        // daemon restart on the VM's first boot.
        let vphoned = try VPhoneGuestBinaries.resolve("vphoned")
        let staged = work.file("vphoned")
        try fm.copyItem(at: vphoned, to: staged)
        try system.replaceFile("usr/bin/vphoned", fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
        let daemon = resources.guestResources.appendingPathComponent("vphoned.plist")
        try system.replaceFile(
            "System/Library/LaunchDaemons/vphoned.plist",
            fromFileAt: daemon,
            mode: 0o644,
            owner: Self.guestOwner,
        )
        let launchd = "System/Library/xpc/launchd.plist"
        let backup = "\(launchd).bak"
        if try !system.exists(backup) {
            try system.copyFile(from: launchd, to: backup)
        }
        let temp = work.file("launchd.plist")
        try system.copyFile(from: backup, to: "launchd.plist", in: work.directory)
        try CustomFirmwareDaemons.injectDaemon(into: temp, name: "vphoned", from: daemon)
        try system.replaceFile(launchd, fromFileAt: temp, mode: 0o644, owner: Self.guestOwner)
    }

    /// The host copy of the installed vphoned, for launch-time auto-update.
    /// Besides Disk.img, it is the one file root writes into the caller's
    /// folder: created beside the old one through the pinned descriptor,
    /// renamed over it (a planted link is replaced, not followed), and owned
    /// by the caller.
    private func installSignedDaemonCopy(
        in bundle: VPhoneConfinedDirectory,
        work: WorkDirectory,
        owner: (uid: uid_t, gid: gid_t)?,
    ) throws {
        try bundle.replaceFile(".vphoned.signed", fromFileAt: work.file("vphoned"), mode: 0o755, owner: owner)
    }

    /// The launchd hook, SystemHook and the camera hooks. SystemHook loads the
    /// camera hooks from /usr/lib without a bootstrap or tweak loader.
    private func installEnvironment(system: VPhoneConfinedDirectory) throws {
        for name in VPhoneGuestEnvironment.libraries {
            let source = try VPhoneGuestBinaries.resolve(name)
            try system.replaceFile("usr/lib/\(name)", fromFileAt: source, mode: 0o755, owner: Self.guestOwner)
        }
        // launchd has little free header space for another load command.
        // /vh fits the same 32-byte command as the old /b without reusing it.
        let alias = "vh"
        let target = "/usr/lib/launchdhook-vphone.dylib"
        if try system.exists(alias) {
            guard try system.readLink(alias) == target else {
                throw ValidationError("Another file already uses /vh on the VM system volume. Remove it, then install CFW again.")
            }
        } else {
            try system.createSymlink(target: target, at: alias)
        }
    }

    private func patchWatchdog(system: VPhoneConfinedDirectory, work: WorkDirectory) throws {
        let target = "usr/libexec/watchdogd"
        let backup = "\(target).bak"
        if try !system.exists(backup) {
            try system.copyFile(from: target, to: backup)
        }
        let staged = work.file("watchdogd")
        try work.directory.removeItem("watchdogd")
        try system.copyFile(from: backup, to: "watchdogd", in: work.directory)
        // The patcher re-attests watchdogd's original CodeDirectory pages.
        // Re-signing it would change Apple's identifier and break launchd's
        // boot-task identity check.
        try patch("patch-watchdogd", [staged.path])
        try system.replaceFile(target, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
    }

    // MARK: - Preboot

    private func patchPreboot(volumes: [[String: Any]], work: WorkDirectory) throws {
        guard
            let preboot = volumes.first(where: { ($0["Roles"] as? [String])?.contains("Preboot") == true }),
            let device = preboot["DeviceIdentifier"] as? String
        else {
            throw ValidationError("Unable to find the VM's Preboot volume. Restore the VM, then install CFW again.")
        }
        let mount = work.file("preboot")
        _ = try work.directory.directory("preboot", create: true, mode: 0o700)
        try mountGuestVolume(device, at: mount)
        defer { _ = try? tool("/sbin/umount", [mount.path], quiet: true) }
        do {
            let root = try openGuestVolume("preboot", device: device, in: work)
            // Each candidate must be reached without a link anywhere on the
            // way; one behind a link is not counted.
            let candidates = try root.entries().compactMap { name -> String? in
                let path = "\(name)/usr/standalone/firmware/devicetree.img4"
                guard (try? root.isDirectory(name)) == true, (try? root.isRegularFile(path)) == true else {
                    return nil
                }
                return path
            }
            guard candidates.count == 1, let deviceTree = candidates.first else {
                throw ValidationError("Expected one device tree in the Preboot volume but found \(candidates.count). Restore the VM, then install CFW again.")
            }
            try patchCopy(of: deviceTree, in: root, work: work, verb: "patch-post-restore-dt")
            if let build = spoofBuild {
                let version = "Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist"
                if try root.isRegularFile(version) {
                    try patchCopy(of: version, in: root, work: work, verb: "patch-build-version", arguments: [build])
                }
            }
        }
    }

    // MARK: - Guest file patches

    /// Run a patch verb that edits a guest file in place, on a private copy
    /// instead: copy it out by descriptor, patch the copy in the work folder,
    /// and install the result with its original owner and mode. The verb
    /// never sees a guest path, so it cannot be steered by a link in one.
    private func patchCopy(
        of relative: String,
        in root: VPhoneConfinedDirectory,
        work: WorkDirectory,
        verb: String,
        arguments: [String] = [],
    ) throws {
        guard let original = try root.status(relative), original.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError("\(relative) on the VM is missing or is not a regular file. Restore the VM, then install CFW again.")
        }
        // A folder of its own keeps the file's name, extension included.
        let folder = "stage-\(UUID().uuidString)"
        let stage = try work.directory.directory(folder, create: true, mode: 0o700)
        defer { try? work.directory.removeItem(folder) }
        let leaf = (relative as NSString).lastPathComponent
        try root.copyFile(from: relative, to: leaf, in: stage)
        let staged = work.file(folder).appendingPathComponent(leaf)
        try patch(verb, [staged.path] + arguments)
        try root.replaceFile(
            relative,
            fromFileAt: staged,
            mode: original.st_mode & 0o7777,
            owner: (original.st_uid, original.st_gid),
        )
    }

    private func patchMachO(
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        path: String,
        verb: String,
        identifier: String? = nil,
        preserveEntitlements: Bool = false,
        injectedDylibPath: String? = nil,
    ) throws {
        let backup = "\(path).bak"
        if try !system.exists(backup) {
            try system.copyFile(from: path, to: backup)
        }
        let name = (path as NSString).lastPathComponent
        let staged = work.file(name)
        try work.directory.removeItem(name)
        try system.copyFile(from: backup, to: name, in: work.directory)
        let entitlements =
            preserveEntitlements
                ? try VPhoneSigner.entitlements(ofFileAt: staged).first(where: { !$0.isEmpty })
                : nil
        try patch(verb, [staged.path])
        if let injectedDylibPath {
            try patch("inject-dylib", [staged.path, injectedDylibPath])
        }
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(identifier: identifier, entitlements: entitlements, mergesExisting: true),
        )
        try system.replaceFile(path, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
    }

    /// Copy an optional guest binary into the work folder, or nil (with a
    /// note) when it is absent or not a regular file.
    private func stageOptional(
        _ path: String,
        from system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        label: String,
    ) throws -> URL? {
        guard try system.isRegularFile(path) else {
            print("[!] \(label) absent; entitlement patch skipped")
            return nil
        }
        let name = (path as NSString).lastPathComponent
        try work.directory.removeItem(name)
        try system.copyFile(from: path, to: name, in: work.directory)
        return work.file(name)
    }

    private func patchDebugserver(system: VPhoneConfinedDirectory, work: WorkDirectory) throws {
        let target = "usr/libexec/debugserver"
        guard let staged = try stageOptional(target, from: system, work: work, label: "debugserver") else { return }
        guard
            let source = try VPhoneSigner.entitlements(ofFileAt: staged)
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
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml, options: 0,
        )
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(entitlements: data, mergesExisting: true),
        )
        try system.replaceFile(target, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
    }

    private func patchCampo(system: VPhoneConfinedDirectory, work: WorkDirectory) throws {
        let target = "Applications/Campo.app/Campo"
        guard let staged = try stageOptional(target, from: system, work: work, label: "Campo") else { return }
        guard
            let source = try VPhoneSigner.entitlements(ofFileAt: staged)
            .first(where: { !$0.isEmpty })
        else {
            print("[!] Campo has no readable entitlements; patch skipped")
            return
        }
        let ent = work.file("Campo.entitlements")
        try source.write(to: ent)
        try patch("patch-campo-entitlements", [ent.path])
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(
                entitlements: Data(contentsOf: ent, options: .mappedIfSafe),
                mergesExisting: true,
            ),
        )
        try system.replaceFile(target, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
    }

    // MARK: - Data volume

    private func renameGigalocker(data: VPhoneConfinedDirectory) throws {
        let destination = "AA.gl"
        for source in try data.entries() where (source as NSString).pathExtension == "gl" {
            if source == destination {
                continue
            }
            try data.removeItem(destination)
            try data.rename(source, to: destination)
        }
    }

    private func productVersion(system: VPhoneConfinedDirectory) throws -> String {
        guard
            let data = try? system.readData("System/Library/CoreServices/SystemVersion.plist"),
            let value = try PropertyListSerialization.propertyList(
                from: data,
                format: nil,
            ) as? [String: Any],
            let version = value["ProductVersion"] as? String
        else {
            throw ValidationError("Unable to read the iOS version from the VM system volume. Restore the VM, then install CFW again.")
        }
        return version
    }

    // MARK: - Cleanup

    private func makeWorkDirectory() throws -> WorkDirectory {
        var template = Array("\(Self.workParent)/vphone-cfw.XXXXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            throw ValidationError("Unable to create a private work folder in \(Self.workParent): \(String(cString: strerror(errno)))")
        }
        let path = String(cString: created)
        // mkdtemp creates the folder 0700 for its caller, root. Re-check it
        // through a no-follow walk before mounting anything under it.
        let directory = try VPhoneConfinedDirectory.pin(absolutePath: path, requireOwner: 0)
        guard try directory.metadata().st_mode & 0o077 == 0 else {
            throw ValidationError("The CFW work folder \(path) is accessible to other users. Try again.")
        }
        return WorkDirectory(
            name: (path as NSString).lastPathComponent,
            url: URL(fileURLWithPath: path, isDirectory: true),
            directory: directory,
        )
    }

    /// Remove the work folder by descriptor. The no-follow removal refuses to
    /// enter another volume, so a mount that failed to detach is reported,
    /// never emptied.
    private func removeWorkDirectory(_ work: WorkDirectory) throws {
        guard let mounts = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            throw ValidationError("Unable to confirm that the CFW volumes are detached. Eject them in Disk Utility, then try again.")
        }
        // Foundation drops the /private prefix when it resolves links, so
        // compare both spellings on each side.
        let roots = Set([work.url.path, work.url.resolvingSymlinksInPath().path])
        guard
            !mounts.contains(where: { mount in
                [mount.path, mount.resolvingSymlinksInPath().path].contains { path in
                    roots.contains { path == $0 || path.hasPrefix($0 + "/") }
                }
            })
        else {
            throw ValidationError("A CFW volume is still mounted under \(work.url.path). Eject it, then try again.")
        }
        try VPhoneConfinedDirectory.pin(absolutePath: Self.workParent).removeItem(work.name)
    }

    private func detachImage(at mount: URL) throws {
        do {
            _ = try tool("/usr/bin/hdiutil", ["detach", mount.path], quiet: true)
        } catch {
            _ = try tool("/usr/bin/hdiutil", ["detach", "-force", mount.path], quiet: true)
        }
    }

    // MARK: - Tools

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
            throw ValidationError(
                "\(URL(fileURLWithPath: path).lastPathComponent) failed (\(result.exitCode)): \(result.stderr)",
            )
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
