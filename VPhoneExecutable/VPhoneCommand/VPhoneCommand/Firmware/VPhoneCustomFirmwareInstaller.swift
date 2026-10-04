import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhonePatchKit
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
    /// What a run does to the guest.
    enum Mode: String, Sendable {
        /// The whole install: cryptexes, the GPU bundle, every shared-cache and
        /// Mach-O patch the VM's plan selects, and the guest payload. Needs a
        /// prepared restore tree.
        case full
        /// Only the files this bundle ships into the guest — vphoned, its
        /// launch daemon, the guest dylibs, the libmisfix defaults and the
        /// virtio sound driver — put back where a full install already placed
        /// them, plus the audio repair that driver needs on an older VM (see
        /// `updateEnvironmentMounted`).
        ///
        /// No patch runs, nothing is injected, no cryptex or GPU work happens
        /// and no restore tree is needed. That last part is the point: the
        /// restore tree is deleted after a VM first boots, so a machine in
        /// normal use cannot be given an updated guest dylib by any other
        /// route, and the alternative — replacing the files in a running guest
        /// over the API — cannot update a library that is already mapped by a
        /// daemon that will not restart.
        ///
        /// Refuses a VM that has never had a full install: with nothing to put
        /// files back *over*, this would be laying down half an install.
        case environmentOnly

        var summary: String {
            switch self {
            case .full: "CFW system install"
            case .environmentOnly: "guest environment update"
            }
        }
    }

    let bundle: URL
    let resources: VPhoneResources
    var mode: Mode = .full

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
        mode: Mode = .full,
    ) throws -> Int32 {
        if geteuid() == 0 {
            try VPhoneCustomFirmwareInstaller(bundle: bundle, resources: resources, mode: mode).run()
            return 0
        }
        throw ValidationError("\(mode.summary.capitalized) needs root. Run this command with sudo.")
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
        guard geteuid() == 0 else {
            throw ValidationError("\(mode.summary.capitalized) needs root. Run this command with sudo.")
        }
        // Ownership checks apply when the caller is known (SUDO_UID, which
        // the Launchpad helper also sets). Plain root trusts its own files.
        let invokingUser = VPhoneInvokingUser.current
        let callerUID = invokingUser?.uid

        let bundleDirectory = try pinBundle(owner: callerUID)
        let bundlePath = try bundleDirectory.path
        // Which guest patches to apply, as `fw patch` resolved them. Read through
        // the pinned descriptor so root never follows a link out of the bundle.
        let plan = withLateGuestPatches(readPatchPlan(in: bundleDirectory), in: bundleDirectory)
        let disk = try openDiskImage(in: bundleDirectory, path: bundlePath, owner: callerUID)
        let diskPath = (bundlePath as NSString).appendingPathComponent("Disk.img")
        let busy = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", diskPath],
        )
        // openDiskImage holds our verified descriptor throughout the install,
        // so lsof always lists this process even when the VM is stopped.
        guard !VPhoneLsof.parsePIDs(busy.stdout).contains(where: { $0 != getpid() }) else {
            throw ValidationError("The VM disk is in use. Stop the VM, then run \(mode.summary) again.")
        }
        // An environment update is exactly the case where there is no restore
        // tree left: it is deleted once the VM has booted.
        let restore = mode == .full
            ? try restoreTree(in: bundleDirectory, path: bundlePath, owner: callerUID)
            : nil

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
            // between this check and hdiutil's own open remains possible,
            // and hdiutil then works on the caller's own replacement. The
            // snapshot rename below writes only the verified inode. The clone
            // path, the normal case on APFS, has no such window.
            guard try bundleDirectory.refersTo("Disk.img", file: disk) else {
                throw ValidationError("The VM disk image changed during the install. Try again.")
            }
            image = try URL(fileURLWithPath: bundleDirectory.path).appendingPathComponent("Disk.img")
            // From here a failure leaves a half-written guest, so it must not
            // keep reading as installed. `cfw install` records it again on success.
            clearRecordedInstall(invokingUser: invokingUser)
        }

        let attached = try tool(
            "/usr/bin/hdiutil",
            [
                "attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", image.path,
            ],
        )
        // `hdiutil attach` prints the image's own disk and, on macOS 27, the APFS
        // container it synthesizes over it before that disk, so its first line is
        // no longer the image: the container's line carries the container's type
        // and taking it would make every later device reference point at the
        // container instead of the store it lives on. The image's disk is the one
        // whose `Apple_APFS` partition is the store, so take its parent.
        let devices = attached.split(whereSeparator: \.isNewline).compactMap { line -> (device: String, type: String)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].hasPrefix("/dev/disk") else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
        let store = devices.first(where: { $0.type == "Apple_APFS" })?.device
        let wholeDisk = devices.first(where: { $0.type == "GUID_partition_scheme" })?.device
        let baseDisk = store.flatMap { device in
            device.range(of: "s", options: .backwards).map { String(device[..<$0.lowerBound]) }
        } ?? wholeDisk ?? devices.first?.device
        guard let baseDisk, baseDisk.hasPrefix("/dev/disk") else {
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

        // s3 is the xART volume, which holds the gigalocker. The guest's Data
        // and User volumes are FileVault volumes locked to its SEP; the host
        // cannot mount them, so nothing here writes to them.
        let system = work.file("system")
        let xart = work.file("xart")
        _ = try work.directory.directory("system", create: true, mode: 0o700)
        _ = try work.directory.directory("xart", create: true, mode: 0o700)
        var systemMounted = false
        var xartMounted = false
        defer {
            if xartMounted,
               (try? tool("/sbin/umount", [xart.path], quiet: true)) == nil
            {
                _ = try? tool("/sbin/umount", ["-f", xart.path], quiet: true)
            }
            if systemMounted,
               (try? tool("/sbin/umount", [system.path], quiet: true)) == nil
            {
                _ = try? tool("/sbin/umount", ["-f", system.path], quiet: true)
            }
        }
        systemMounted = true
        try mountGuestVolume("\(container)s1", at: system)
        xartMounted = true
        try mountGuestVolume("\(container)s3", at: xart)
        print("[*] \(mode.summary.capitalized): \(bundle.lastPathComponent)")
        do {
            // Every descriptor on a guest volume lives in this scope, so none
            // is left open to hold the volume busy when it is unmounted.
            let systemRoot = try openGuestVolume("system", device: "\(container)s1", in: work)
            let xartRoot = try openGuestVolume("xart", device: "\(container)s3", in: work)
            switch mode {
            case .full:
                guard let restore else {
                    throw ValidationError("A full CFW install needs a prepared restore tree.")
                }
                try installMounted(
                    system: systemRoot,
                    xart: xartRoot,
                    restore: restore,
                    work: work,
                    owner: callerUID,
                    plan: plan,
                )
            case .environmentOnly:
                try updateEnvironmentMounted(system: systemRoot, work: work, plan: plan)
            }
        }
        // The Preboot identity patches go with the boot chain and belong to a
        // full install only. The device tree repairs are the exception: a VM
        // restored before the board audio repair or the haptics removal has no
        // other way to get them, since `fw patch` does not run again.
        // A guest that has booted keeps the MobileGestalt answers it cached from
        // the old tree on its Data volume, which the host cannot reach. vphoned
        // drops that cache at startup when it is older than the tree; see
        // VPhoneDaemon/Daemon/GuestMobileGestaltCache.swift.
        try patchPreboot(
            volumes: volumes,
            work: work,
            plan: plan,
            guestDevice: guestDevice(of: restore),
            includeIdentity: mode == .full,
            boardDeviceTree: stageBoardDeviceTree(in: bundleDirectory, work: work),
        )
        // The snapshot rename is a full install's alone: it has already been
        // done on any VM an environment update is allowed to run against, and
        // this run creates no new snapshot to flip.
        _ = try tool("/sbin/umount", [xart.path])
        xartMounted = false
        _ = try tool("/sbin/umount", [system.path])
        systemMounted = false
        _ = try tool("/usr/bin/hdiutil", ["detach", baseDisk], quiet: true)
        diskAttached = false
        if mode == .full {
            if cloned {
                try VPhoneAPFSSnapshot.rename(imageAt: image)
            } else {
                try renameSnapshot(in: bundleDirectory, verified: disk, label: image)
            }
        }
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
        switch mode {
        case .full:
            print("[+] CFW system install complete; vphoned is installed, no package bootstrap was staged")
        case .environmentOnly:
            print("[+] Guest environment updated; start the VM to pick it up")
        }
    }

    // MARK: - Environment update

    /// Put this bundle's guest payload back over the copies a full install
    /// already placed, and change nothing else.
    ///
    /// Every file written here is one `installVphoned` and `installEnvironment`
    /// write during a full install, through the same confined descriptors, with
    /// the same modes and owners. What is deliberately absent is everything
    /// that makes a guest a CFW guest in the first place: no shared-cache or
    /// Mach-O patch runs, no load command is injected, no cryptex or GPU work
    /// happens, and the recorded variant is untouched.
    ///
    /// A missing target is left missing. The libraries are not all
    /// unconditional — a VM whose plan left a patch out never received the
    /// library that goes with it — and an update is not the place to add one.
    ///
    /// The virtio sound driver is the exception, and follows the plan instead:
    /// it came after most VMs were installed, and this is the only route by
    /// which a VM in use can receive it. The board audio repair that goes
    /// with it touches the Preboot device tree, outside this function.
    private func updateEnvironmentMounted(
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        plan: VPhoneVirtualMachinePatchPlan?,
    ) throws {
        // Evidence that a full install ran. `launchd.plist.bak` is written by
        // the first `installVphoned` and by nothing else, so its absence means
        // this guest has never been installed and there is nothing to update.
        guard try system.exists("System/Library/xpc/launchd.plist.bak") else {
            throw ValidationError(
                "This VM has no CFW install to update. Run `vphone-cli cfw install` first.",
            )
        }

        try installVphoned(system: system, work: work)
        print("  [+] vphoned and its launch daemon")

        for name in VPhoneGuestEnvironment.libraries {
            let path = "usr/lib/\(name)"
            guard try system.exists(path) else {
                print("  [·] \(path): not on this VM, left out")
                continue
            }
            let source = try VPhoneGuestBinaries.resolve(name)
            try system.replaceFile(path, fromFileAt: source, mode: 0o755, owner: Self.guestOwner)
            print("  [+] \(path)")
        }

        // Only when the guest has none, exactly as a full install does: the
        // file carries a per-machine UDID choice and is not the bundle's to
        // overwrite.
        try installMISFixDefaults(system: system)

        if plan?.isEnabled(FirmwareGuestSystemPatchSet.virtioSoundDriver) ?? true {
            try installVirtioSoundDriver(system: system)
        }
        // Both patches ride one staged copy — `patchMachO` stages from the
        // pristine backup, so two calls would not compose. The restore below
        // fires only when every VirtualAudio patch is off.
        var virtualAudioVerbs: [String] = []
        if plan?.isEnabled(FirmwareGuestSystemPatchSet.virtualAudioSpeakerRouteThrows) ?? true {
            virtualAudioVerbs.append("patch-virtualaudio")
        }
        if plan?.isEnabled(FirmwareGuestSystemPatchSet.virtualAudioMuteSetThrow) ?? true {
            virtualAudioVerbs.append("patch-virtualaudio-mute")
        }
        if plan?.isEnabled(FirmwareGuestSystemPatchSet.virtualAudioSpeakerProtectionGate) ?? true {
            virtualAudioVerbs.append("patch-virtualaudio-sp-gate")
        }
        if plan?.isEnabled(FirmwareGuestSystemPatchSet.virtualAudioVolumeModePrecondition) ?? true {
            virtualAudioVerbs.append("patch-virtualaudio-volume-gate")
        }
        if !virtualAudioVerbs.isEmpty {
            try patchMachO(
                system: system,
                work: work,
                path: "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio",
                verbs: virtualAudioVerbs,
                preserveEntitlements: true,
            )
            try sealGuestBundle(system: system, bundle: "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin")
            print("  [+] VirtualAudio: \(virtualAudioVerbs.joined(separator: ", "))")
        } else if try system.exists("Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio.bak") {
            // The patch is off but a previous install left it applied; stage
            // the backup the same way `patchMachO` does and put the original
            // back, so the gate means what it says.
            let name = "VirtualAudio"
            try work.directory.removeItem(name)
            try system.copyFile(from: "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio.bak", to: name, in: work.directory)
            try system.replaceFile(
                "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio",
                fromFileAt: work.file(name),
                mode: 0o755,
                owner: Self.guestOwner,
            )
            try sealGuestBundle(system: system, bundle: "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin")
            print("  [+] VirtualAudio restored from backup (patch off)")
        }
        if plan?.isEnabled(FirmwareGuestSystemPatchSet.virtualAudioGraphConfigurations) ?? true {
            try patchVirtualAudioGraphConfigurations(system: system, work: work)
        }
    }

    /// Host bookkeeping in the caller's folder, written with the caller's
    /// credentials as `cfw install` records the variant, never as root.
    private func clearRecordedInstall(invokingUser: VPhoneInvokingUser?) {
        let bundle = bundle
        let clear: () throws -> Void = {
            guard let vm = try? VPhoneBundle.load(at: bundle) else { return }
            try VPhoneRestoreInfo.clearVariant(inBundle: vm)
        }
        do {
            if let invokingUser {
                try invokingUser.withUserCredentials(clear)
            } else {
                try clear()
            }
        } catch {
            fputs("warning: could not mark the install as in progress: \(error)\n", stderr)
        }
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

    /// Renames the root snapshot in the caller's Disk.img when it could not
    /// be cloned. The install runs for minutes after the image was checked,
    /// so the name is opened again without following links and must still be
    /// the same single-link inode before root writes to it.
    private func renameSnapshot(
        in bundle: VPhoneConfinedDirectory,
        verified disk: VPhoneConfinedFile,
        label: URL,
    ) throws {
        let writable = openat(bundle.descriptor, "Disk.img", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard writable >= 0 else {
            throw ValidationError("The VM disk image changed during the install. Try again.")
        }
        defer { close(writable) }
        var metadata = stat()
        guard fstat(writable, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_dev == disk.device,
              metadata.st_ino == disk.inode,
              metadata.st_nlink == 1
        else {
            throw ValidationError("The VM disk image changed during the install. Try again.")
        }
        try VPhoneAPFSSnapshot.rename(descriptor: writable, url: label)
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
            throw ValidationError("The VM disk image did not attach correctly. Try again.")
        }
        return root
    }

    // MARK: - System volume

    private func installMounted(
        system: VPhoneConfinedDirectory,
        xart: VPhoneConfinedDirectory,
        restore: VPhoneConfinedDirectory,
        work: WorkDirectory,
        owner: uid_t?,
        plan: VPhoneVirtualMachinePatchPlan?,
    ) throws {
        /// Whether the VM's patch plan turned this guest patch on.
        ///
        /// A VM with no plan — one created before presets, or patched by a build
        /// that had none — gets every patch, which is what it was restored with.
        func on(_ identifier: String) -> Bool {
            guard let plan else { return true }
            guard plan.isEnabled(identifier) else {
                print("  [·] \(identifier): off in preset \(plan.presetIdentifier)")
                return false
            }
            return true
        }

        try installCryptexes(restore: restore, system: system, work: work, owner: owner)
        let version = try productVersion(system: system)
        let dsc = try verifiedDyldCacheDirectory(system: system)
        // The version branches stay: they and the declarations' applicability say
        // the same thing, and this is what a VM with no plan still follows.
        if version.hasPrefix("27.") {
            if on("dyld-boot-iomfb_force_kern") {
                try patch("patch-iomfb-force-kern", [dsc])
            }
            if on("dyld-boot-maxslide") {
                try patch("patch-dsc-maxslide", [dsc])
            }
            if on("dyld-boot-lsd_embedded_reg") {
                try patch("patch-lsd-embedded-reg", [dsc])
            }
            if on("dyld-boot-xpc_lwcr") {
                try patch("patch-xpc-lwcr", [dsc])
            }
            if on("dyld-boot-lockdown_mode") {
                try patch("patch-lockdown-mode", [dsc])
            }
        } else if version.hasPrefix("26.0") || version.hasPrefix("18.") {
            if on("dyld-boot-iomfb_swapend") {
                try patch("patch-iomfb-swapend", [dsc, "--target-size", "0x560"])
            }
        }
        // Version-agnostic: the guest is hacktivated on every base, so the
        // profile check this opens fails on every base too. Off in `standard`,
        // because libmisfix declines the same check from userspace in installd,
        // misagent and SpringBoard without touching the cache — see
        // FirmwarePatchSetCatalog.misTrustAuthPatch for why editing the cache
        // is the worse trade on 27.
        if on(FirmwarePatchSetCatalog.misTrustAuthPatch) {
            try patch("patch-mis-trust-auth", [dsc])
        }
        // These former EXP patches pair with the kernel OID rename and the
        // camera DeviceTree additions in the public CFW firmware pipeline.
        if on("dyld-exp-hv_vmm") {
            try patch("patch-hv-vmm-dsc", [dsc])
        }
        if on("dyld-cfw-camera") {
            try patch("patch-camera-dsc", [dsc, (dsc as NSString).appendingPathComponent("dyld_shared_cache_arm64e")])
        }
        // The preset's own parameter first; `SPOOF_BUILD` still works for a VM
        // whose preset does not set one.
        let buildVersion = plan?.parameters[FirmwareGuestSystemPatchSet.buildVersionParameter] ?? spoofBuild
        if let build = buildVersion, !build.isEmpty, on("system-systemversion-cfw-build_version") {
            for path in [
                "System/Library/CoreServices/SystemVersion.plist",
                "System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist",
            ] {
                try patchCopy(of: path, in: system, work: work, verb: "patch-build-version", arguments: [build])
            }
        }
        if on("system-seputil-boot-gigalocker_uuid") {
            try patchMachO(
                system: system,
                work: work,
                path: "usr/libexec/seputil",
                verbs: ["patch-seputil"],
                identifier: "com.apple.seputil",
            )
        }
        if version.hasPrefix("27."), on("system-diskimagesiod-cfw-is_mount_complete") {
            try patchMachO(
                system: system,
                work: work,
                path: "usr/libexec/diskimagesiod",
                verbs: ["patch-diskimagesiod"],
                preserveEntitlements: true,
            )
        }
        if on("system-gigalocker-boot-rename") {
            try renameGigalocker(xart: xart)
        }
        if on("system-extensions-boot-gpu_bundle") {
            try installGPUBundle(restore: restore, system: system, owner: owner)
        }
        if on("system-launchd_cache_loader-boot-unsecure_cache_gate") {
            try patchMachO(
                system: system,
                work: work,
                path: "usr/libexec/launchd_cache_loader",
                verbs: ["patch-launchd-cache-loader"],
                identifier: "com.apple.launchd_cache_loader",
            )
        }
        if on("system-mobileactivationd-boot-should_hactivate") {
            try patchMachO(
                system: system,
                work: work,
                path: "usr/libexec/mobileactivationd",
                verbs: ["patch-mobileactivationd"],
            )
        }
        if on("system-watchdogd-exp-hv_vmm_cache") {
            try patchWatchdog(system: system, work: work)
        }
        if on("system-vphoned-boot-install") {
            try installVphoned(system: system, work: work)
        }
        if on("system-launchdaemons-boot-environment") {
            try installEnvironment(system: system)
        }
        if on(FirmwareGuestSystemPatchSet.virtioSoundDriver) {
            try installVirtioSoundDriver(system: system)
        }
        // Both patches ride one staged copy — `patchMachO` stages from the
        // pristine backup, so two calls would not compose.
        var virtualAudioVerbs: [String] = []
        if on(FirmwareGuestSystemPatchSet.virtualAudioSpeakerRouteThrows) {
            virtualAudioVerbs.append("patch-virtualaudio")
        }
        if on(FirmwareGuestSystemPatchSet.virtualAudioMuteSetThrow) {
            virtualAudioVerbs.append("patch-virtualaudio-mute")
        }
        if on(FirmwareGuestSystemPatchSet.virtualAudioSpeakerProtectionGate) {
            virtualAudioVerbs.append("patch-virtualaudio-sp-gate")
        }
        if on(FirmwareGuestSystemPatchSet.virtualAudioVolumeModePrecondition) {
            virtualAudioVerbs.append("patch-virtualaudio-volume-gate")
        }
        if !virtualAudioVerbs.isEmpty {
            try patchMachO(
                system: system,
                work: work,
                path: "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio",
                verbs: virtualAudioVerbs,
                preserveEntitlements: true,
            )
            try sealGuestBundle(system: system, bundle: "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin")
        }
        if on(FirmwareGuestSystemPatchSet.virtualAudioGraphConfigurations) {
            try patchVirtualAudioGraphConfigurations(system: system, work: work)
        }
        if on("system-launchd-boot-jetsam_panic_guard_bypass") {
            try patchMachO(
                system: system,
                work: work,
                path: "sbin/launchd",
                verbs: ["patch-launchd-jetsam"],
                preserveEntitlements: true,
                injectedDylibPath: "/vh",
            )
        }
        try restoreMISFixTargets(system: system)
        if on("system-debugserver-cfw-install") {
            try patchDebugserver(system: system, work: work)
        }
        if version.hasPrefix("27."), on("system-campo-cfw-entitlements") {
            try patchCampo(system: system, work: work)
        }
    }

    /// Guest patches declared after most VMs' plans were written. A plan is the
    /// list of what was on when `fw patch` ran, so it reads these as off on any
    /// VM patched before them. They need no firmware change, so they follow the
    /// VM's selection as it resolves now instead.
    private static let lateGuestPatches = [
        FirmwareGuestSystemPatchSet.virtioSoundDriver,
        FirmwareGuestSystemPatchSet.prebootBoardAudio,
        FirmwareGuestSystemPatchSet.prebootHaptics,
        FirmwareGuestSystemPatchSet.virtualAudioSpeakerRouteThrows,
        FirmwareGuestSystemPatchSet.virtualAudioMuteSetThrow,
        FirmwareGuestSystemPatchSet.virtualAudioSpeakerProtectionGate,
        FirmwareGuestSystemPatchSet.virtualAudioVolumeModePrecondition,
        FirmwareGuestSystemPatchSet.virtualAudioGraphConfigurations,
    ]

    /// `plan`, with each late guest patch it leaves out turned on when the
    /// VM's preset and its own block and allow choices select it today. A
    /// preset that cannot be resolved from the bundled sets (one naming an
    /// external set) leaves the plan as it is: root loads no external set.
    private func withLateGuestPatches(
        _ plan: VPhoneVirtualMachinePatchPlan?,
        in bundleDirectory: VPhoneConfinedDirectory,
    ) -> VPhoneVirtualMachinePatchPlan? {
        guard var plan else { return nil }
        let missing = Self.lateGuestPatches.filter { !plan.isEnabled($0) }
        guard !missing.isEmpty else { return plan }
        let selection = (try? bundleDirectory.readData(VPhonePatchPresetStore.selectionFileName))
            .flatMap { try? PropertyListDecoder().decode(VPhoneVirtualMachinePatchSelection.self, from: $0) }
            ?? VPhoneVirtualMachinePatchSelection()
        guard
            let preset = VPhonePatchPresetStore.preset(named: plan.presetIdentifier),
            let resolved = try? VPhonePatchPlan.resolve(
                preset: preset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(plan.iOSBaseVersion),
                cloudOS: VPhoneVersion(plan.cloudOSVersion),
                blocked: Set(selection.blockedPatches),
                allowed: Set(selection.allowedPatches),
            )
        else {
            return plan
        }
        for identifier in missing where resolved.enabled.contains(identifier) {
            plan.enabledPatches.append(identifier)
            print("[*] \(identifier): newer than this VM's patch plan, on in preset \(plan.presetIdentifier)")
        }
        return plan
    }

    /// The plan `fw patch` wrote into the VM, or nil when it never ran with one.
    private func readPatchPlan(in bundleDirectory: VPhoneConfinedDirectory) -> VPhoneVirtualMachinePatchPlan? {
        guard let data = try? bundleDirectory.readData(VPhonePatchPresetStore.planFileName) else {
            print("[*] No patch plan recorded; applying every guest patch")
            return nil
        }
        guard let plan = try? PropertyListDecoder().decode(
            VPhoneVirtualMachinePatchPlan.self,
            from: data,
        ) else {
            print("[!] \(VPhonePatchPresetStore.planFileName) is unreadable; applying every guest patch")
            return nil
        }
        print("[*] Patch preset: \(plan.presetIdentifier)  (\(plan.enabledPatches.count) patches on)")
        return plan
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
        try installLibraryAlias(system: system, alias: "vh", target: "/usr/lib/launchdhook-vphone.dylib")
        try installMISFixDefaults(system: system)
    }

    /// The CoreAudio HAL plugin for the VM's virtio sound device. iOS ships
    /// the kernel driver, AppleVirtIOSound, but no plugin for it, so audiomxd
    /// has nothing to play through. The bundle is replaced whole; its
    /// signature seals the binary and Info.plist together.
    private func installVirtioSoundDriver(system: VPhoneConfinedDirectory) throws {
        let name = "VPhoneVirtIOSound.driver"
        let source = try VPhoneConfinedDirectory(root: VPhoneGuestBinaries.resolve(name).path)
        let target = "System/Library/Audio/Plug-Ins/HAL/\(name)"
        try system.removeItem(target)
        try system.copyTree(from: source, to: target, owner: Self.guestOwner)
        for directory in [target, "\(target)/_CodeSignature"] {
            try system.setMode(directory, 0o755)
        }
        try system.setMode("\(target)/VPhoneVirtIOSound", 0o755)
        for file in ["\(target)/Info.plist", "\(target)/_CodeSignature/CodeResources"] {
            try system.setMode(file, 0o644)
        }
        print("  [+] /\(target)")
    }

    /// A symlink at the volume root, so a load command in a binary with little
    /// header space can name a library in seven bytes or fewer.
    private func installLibraryAlias(system: VPhoneConfinedDirectory, alias: String, target: String) throws {
        if try system.exists(alias) {
            guard try system.readLink(alias) == target else {
                throw ValidationError("Another file already uses /\(alias) on the VM system volume. Remove it, then install CFW again.")
            }
        } else {
            try system.createSymlink(target: target, at: alias)
        }
    }

    /// Put back the Apple binaries earlier installs linked libmisfix into.
    ///
    /// installd, misagent and SpringBoard now get the hook the way every other
    /// guest process gets SystemHook: the spawn hooks insert it (see
    /// `vpIsMISFixTarget` in `VPhoneGuestComponents/Shared/InjectionEnvironment.h`).
    /// A guest installed before that still carries a load command in each, and
    /// `patchMachO` left the original beside it as `.bak`. The `/mf` alias
    /// existed only for SpringBoard's.
    private func restoreMISFixTargets(system: VPhoneConfinedDirectory) throws {
        let targets = [
            "usr/libexec/installd",
            "usr/libexec/misagent",
            "System/Library/CoreServices/SpringBoard.app/SpringBoard",
        ]
        for path in targets where try system.isRegularFile("\(path).bak") {
            try system.rename("\(path).bak", to: path)
            print("  [+] \(path): restored the original, libmisfix is inserted at spawn")
        }
        if try system.isSymlink("mf"), try system.readLink("mf") == "/usr/lib/libmisfix.dylib" {
            try system.removeItem("mf")
        }
    }

    /// libmisfix's settings file, and only when the guest has none.
    ///
    /// Unlike the libraries above this is not the bundle's to own: it carries a
    /// per-machine choice, so re-running `cfw install` must not put the
    /// shipped, empty copy back over a UDID someone set.
    private func installMISFixDefaults(system: VPhoneConfinedDirectory) throws {
        let name = "libmisfix.plist"
        let path = "usr/lib/\(name)"
        guard try !system.exists(path) else {
            print("  [·] \(path): already present, left as it is")
            return
        }
        let source = try VPhoneGuestBinaries.resolve(name)
        try system.replaceFile(path, fromFileAt: source, mode: 0o644, owner: Self.guestOwner)
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

    /// The device whose IPSW the restore tree was prepared from.
    private func guestDevice(of restore: VPhoneConfinedDirectory?) -> VPhoneGuestDevice {
        guard let data = try? restore?.readData("iPhone-BuildManifest.plist"),
              let manifest = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return .default }
        return VPhoneGuestDevice.detect(buildManifest: manifest) ?? .default
    }

    /// `includeIdentity` is false for an environment update, which carries
    /// only the device tree repairs: the board audio repair, which needs
    /// `boardDeviceTree`, and the haptics removal, which every guest gets.
    /// `boardDeviceTree` is the iPad's own device tree, staged from the VM's
    /// `FirmwareOriginals`, or nil for an iPhone guest or a VM patched before
    /// `fw patch` kept it.
    private func patchPreboot(
        volumes: [[String: Any]],
        work: WorkDirectory,
        plan: VPhoneVirtualMachinePatchPlan?,
        guestDevice: VPhoneGuestDevice,
        includeIdentity: Bool,
        boardDeviceTree: URL?,
    ) throws {
        // Like every guest patch, a VM with no plan still gets it — except the
        // identity rewrite on an iPad guest, whose installed tree already
        // carries its own identity from `fw patch`; the rewrite would turn it
        // back into an iPhone17,3.
        func on(_ identifier: String) -> Bool {
            let enabled = plan?.isEnabled(identifier) ?? true
            if let plan, !enabled {
                print("  [·] \(identifier): off in preset \(plan.presetIdentifier)")
            }
            return enabled
        }
        let identity = FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity
        var rewriteIdentity = false
        if includeIdentity {
            if guestDevice.isPad {
                print("  [·] \(identity): skipped, the device tree already presents \(guestDevice.productType)")
            } else {
                rewriteIdentity = on(identity)
            }
        }
        let spoofBuild = includeIdentity ? self.spoofBuild : nil
        var repairs: [(verb: String, arguments: [String])] = []
        if let boardDeviceTree, on(FirmwareGuestSystemPatchSet.prebootBoardAudio) {
            repairs.append(("patch-dt-board-audio", [boardDeviceTree.path]))
        }
        if on(FirmwareGuestSystemPatchSet.prebootHaptics) {
            repairs.append(("patch-dt-haptics", []))
        }
        guard rewriteIdentity || !repairs.isEmpty || !(spoofBuild ?? "").isEmpty else { return }
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
            if rewriteIdentity {
                try patchCopy(of: deviceTree, in: root, work: work, verb: "patch-post-restore-dt")
            }
            for repair in repairs {
                try patchCopy(of: deviceTree, in: root, work: work, verb: repair.verb, arguments: repair.arguments)
            }
            if let build = spoofBuild {
                let version = "Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist"
                if try root.isRegularFile(version) {
                    try patchCopy(of: version, in: root, work: work, verb: "patch-build-version", arguments: [build])
                }
            }
        }
    }

    /// The iPad's own device tree, `DeviceTree.<board>.im4p`, which `fw patch`
    /// keeps in the VM's `FirmwareOriginals` beside the vphone600 trees,
    /// copied into the work folder by descriptor. Nil when there is none: an
    /// iPhone guest, or a VM patched by a build that did not keep it.
    ///
    /// The folder is the caller's, so the copy goes through the pinned bundle
    /// descriptor like every other read here, and more than one candidate is
    /// refused rather than guessed between.
    private func stageBoardDeviceTree(
        in bundleDirectory: VPhoneConfinedDirectory,
        work: WorkDirectory,
    ) throws -> URL? {
        let originals = VPhoneBundleOperations.firmwareOriginalsDirectoryName
        guard try bundleDirectory.isDirectory(originals) else { return nil }
        let stash = try bundleDirectory.directory(originals)
        var found: [(directory: VPhoneConfinedDirectory, name: String, path: String)] = []
        for tree in try stash.entries() where try stash.isDirectory(tree) {
            let flash = "\(tree)/Firmware/all_flash"
            guard try stash.isDirectory(flash) else { continue }
            let directory = try stash.directory(flash)
            for name in try directory.entries()
                where name.hasPrefix("DeviceTree.") && name.hasSuffix(".im4p")
                && !name.hasPrefix("DeviceTree.vphone600") && (try? directory.isRegularFile(name)) == true
            {
                found.append((directory, name, "\(originals)/\(flash)/\(name)"))
            }
        }
        guard !found.isEmpty else { return nil }
        guard found.count == 1, let board = found.first else {
            throw ValidationError(
                "Found \(found.count) board device trees in \(originals): \(found.map(\.path).joined(separator: ", ")). Keep one.",
            )
        }
        try board.directory.copyFile(from: board.name, to: board.name, in: work.directory)
        print("[*] Board device tree: \(board.path)")
        return work.file(board.name)
    }

    // MARK: - Guest file patches

    /// Run a patch verb that edits a guest file in place, on a private copy
    /// instead: copy it out by descriptor, patch the copy in the work folder,
    /// and install the result with its original owner and mode. The verb
    /// never sees a guest path, so it cannot be steered by a link in one.
    ///
    /// A verb that found the file already as it should be leaves the guest's
    /// copy untouched, modification time included: vphoned drops the guest's
    /// MobileGestalt cache when the Preboot device tree is newer than it, so a
    /// repeated environment update must not make an unchanged tree look new.
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
        let before = try Data(contentsOf: staged)
        try patch(verb, [staged.path] + arguments)
        guard try Data(contentsOf: staged) != before else { return }
        try root.replaceFile(
            relative,
            fromFileAt: staged,
            mode: original.st_mode & 0o7777,
            owner: (original.st_uid, original.st_gid),
        )
    }

    /// Flip the speaker chains in every tuning set's graph_configurations.plist
    /// onto the generic graph path. The plist lives under the acoustic ID the
    /// image ships for (`Library/Audio/Tunings/<AID>/VAD/`), which varies by
    /// board, so the directory is walked rather than named. An image with no
    /// tuning sets — iOS 27's VirtualAudio reads no such plist — is left
    /// alone, quietly: there is nothing this patch could act on.
    private func patchVirtualAudioGraphConfigurations(
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
    ) throws {
        let tunings = "Library/Audio/Tunings"
        guard try system.exists(tunings), try system.isDirectory(tunings) else {
            print("  [·] \(tunings): not on this VM, left out")
            return
        }
        var patched = 0
        for acousticID in try system.directory(tunings).entries().sorted() {
            let plist = "\(tunings)/\(acousticID)/VAD/graph_configurations.plist"
            guard try system.isRegularFile(plist) else { continue }
            try patchCopy(of: plist, in: system, work: work, verb: "patch-virtualaudio-graph-configurations")
            patched += 1
        }
        if patched == 0 {
            print("  [·] \(tunings): no graph_configurations.plist under any tuning set, left out")
        }
    }

    /// Stage a guest Mach-O, patch it, re-sign it and put it back.
    ///
    /// `verbs` runs in order against the one staged copy — the staging starts
    /// from the pristine backup, so two calls would not compose. Empty: a
    /// binary that only needs a library injected — as installd does for
    /// libmisfix — has no bytes of its own to change.
    private func patchMachO(
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        path: String,
        verbs: [String] = [],
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
        for verb in verbs {
            try patch(verb, [staged.path])
        }
        if let injectedDylibPath {
            try patch("inject-dylib", [staged.path, injectedDylibPath])
        }
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(identifier: identifier, entitlements: entitlements, mergesExisting: true),
        )
        try system.replaceFile(path, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
    }

    /// Re-seal a code-signed bundle on the mounted guest system volume.
    ///
    /// `patchMachO` re-signs the Mach-O it replaces, but a bundle's outer
    /// `_CodeSignature/CodeResources` seals the whole directory, and a guest
    /// built with the code-signing monitor kills the process that loads a
    /// bundle whose seal no longer matches its contents. Ad hoc, like every
    /// other guest binary this pipeline writes; the identifier is kept so the
    /// plugin still answers to the name it always had.
    private func sealGuestBundle(system: VPhoneConfinedDirectory, bundle: String) throws {
        // No --identifier: codesign keeps the one the bundle already carries.
        _ = try tool("/usr/bin/codesign", [
            "-f", "-s", "-", "--timestamp=none",
            try system.directory(bundle).path,
        ])
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
        // Replacement, not merge: `plist` is already the complete set we want,
        // and merging it back over the file's own entitlements would re-add the
        // `seatbelt-profiles` removed above — merge updates and appends keys, it
        // cannot delete one.
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(entitlements: data),
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

    // MARK: - xART volume

    /// The patched seputil looks for the gigalocker as `AA.gl` rather than
    /// under a UUID, so the one the restore wrote takes that name.
    private func renameGigalocker(xart: VPhoneConfinedDirectory) throws {
        let destination = "AA.gl"
        for source in try xart.entries() where (source as NSString).pathExtension == "gl" {
            if source == destination {
                continue
            }
            try xart.removeItem(destination)
            try xart.rename(source, to: destination)
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
        commandName: "install-root", abstract: "Internal privileged CFW disk install",
        shouldDisplay: false,
    )

    @Argument(help: "VM bundle path") var bundle: String
    @Option(help: "Resource base") var resources: String

    func run() throws {
        try VPhoneCustomFirmwareInstaller(
            bundle: URL(fileURLWithPath: bundle),
            resources: VPhoneResources(base: URL(fileURLWithPath: resources)),
        ).run()
    }
}
