import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
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
        /// Only the Preboot kernelcache: replace its IM4P with one re-patched
        /// from the VM's selection, keeping the original IM4M, so iBoot boots a
        /// re-patched kernel (the image4 bypass accepts a modified payload under
        /// the signed manifest, as it does for the Preboot device tree). No
        /// volume is reformatted and the Data volume is untouched — the one
        /// boot-chain change that reaches an installed guest without the erasing
        /// restore. The kernelcache is re-patched from the pristine copy in
        /// FirmwareOriginals, so no restore tree or prior `fw patch` is needed.
        case kernelUpdate

        var summary: String {
            switch self {
            case .full: "CFW system install"
            case .environmentOnly: "guest environment update"
            case .kernelUpdate: "guest kernel update"
            }
        }
    }

    let bundle: URL
    let resources: VPhoneResources
    var mode: Mode = .full
    let workParent: String

    /// Guest system files belong to root:wheel.
    private static let guestOwner: (uid: uid_t, gid: gid_t) = (0, 0)

    /// The dyld shared cache directory on the guest system volume, and the undo
    /// log the cache verbs write beside it so a later run can revert a cache
    /// patch by putting its original bytes back. The log sits inside the cache
    /// directory because that is where the only cache it describes lives: on a
    /// full install Disk.img is cloned and the clone swapped in, so a log kept
    /// in the VM folder would describe the pre-clone cache, while one beside the
    /// cache travels with it. `verifiedDyldCacheDirectory` admits it — it is a
    /// plain single-link file, and `enumerateChunks` never mistakes a dotfile
    /// for a `dyld_shared_cache_arm64e*` chunk.
    private static let dscUndoLogLeaf = ".vphone-dsc-undo.json"

    /// Root-owned and sticky, outside every user's tree. The work folder is
    /// made here with `mkdtemp`, so its name cannot be predicted or claimed.
    static let defaultWorkParent = "/private/var/tmp"

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
        workParent: String = defaultWorkParent,
    ) throws -> Int32 {
        if geteuid() == 0 {
            try VPhoneCustomFirmwareInstaller(
                bundle: bundle,
                resources: resources,
                mode: mode,
                workParent: workParent,
            ).run()
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
        // Launchpad's helper reads this through a pipe, where stdout would
        // otherwise be block buffered: a warning printed early in the run
        // would reach the machine's log only with the burst at exit. One line
        // at a time, as in a terminal.
        fflush(stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
        if mode == .kernelUpdate {
            try runKernelUpdate()
            return
        }
        // Ownership checks apply when the caller is known (SUDO_UID, which
        // the Launchpad helper also sets). Plain root trusts its own files.
        let invokingUser = VPhoneInvokingUser.current
        let callerUID = invokingUser?.uid

        let bundleDirectory = try pinBundle(owner: callerUID)
        let bundlePath = try bundleDirectory.path
        // Which guest patches to apply. The boot chain follows the plan `fw
        // patch` resolved; the guest half follows the VM's current selection,
        // both ways. Read through the pinned descriptor so root never follows a
        // link out of the bundle.
        let rawPlan = readPatchPlan(in: bundleDirectory)
        if Self.restoredCustomisedSystem(rawPlan) {
            // The restore installed the finished system (the restore image
            // patches): there is nothing to add, and writing the System volume
            // would break the seal its stock boot chain checks.
            guard mode == .full else {
                throw Self.restoreImageRefusal(mode)
            }
            print("[cfw] The restore installed this VM's customised system; nothing to install.")
            recordGuestReceipt(live: [], notApplicable: [], in: bundleDirectory, owner: invokingUser.map { ($0.uid, $0.gid) })
            return
        }
        let plan = resolveGuestSelection(rawPlan, in: bundleDirectory)
        // What was live in the guest before this run, so a now-off patch this run
        // cannot revert (no backup, no undo record) stays honestly recorded.
        // The receipt's `Guest` part is the truth when it was recorded; without
        // it, the best evidence is what the old install followed — the plan's
        // guest-target patches plus the late guest patches the old
        // `withLateGuestPatches` added from the current selection. A VM that was
        // never installed has an empty prior set (its guest is pristine); that
        // is decided below, where the mounted volume says whether it was.
        let receipt = (try? bundleDirectory.readData(VPhonePatchPresetStore.receiptFileName))
            .flatMap { try? VPhoneVirtualMachinePatchReceipt.decode($0) }
        let receiptGuest = receipt?.parts[VPhoneVirtualMachinePatchReceipt.guestPart]
            .map { Set($0.patches) }
        // The kernel patches the restore or the last `cfw update-kernel` put in
        // this VM's kernelcache, which decide the shared region size below.
        var receiptKernel = receipt?.parts[VPhoneVirtualMachinePatchReceipt.part(for: .firmware(.kernelcache))]
            .map { Set($0.patches) }
        let guestTargets = FirmwareGuestPatchResolution.guestTargetIdentifiers
        let effectiveEnabled = Set(plan?.enabledPatches ?? [])
        let priorFallback = Set(rawPlan?.enabledPatches ?? []).intersection(guestTargets)
            .union(Set(Self.lateGuestPatches).intersection(effectiveEnabled))
        let disk = try openDiskImage(in: bundleDirectory, path: bundlePath, owner: callerUID)
        let diskPath = (bundlePath as NSString).appendingPathComponent("Disk.img")
        let busy = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", diskPath],
        )
        // openDiskImage holds our verified descriptor throughout the install,
        // so lsof always lists this process even when the VM is stopped.
        try Self.requireDiskUnused(lsofOutput: busy.stdout, rerun: "run \(mode.summary) again")
        // An environment update is exactly the case where there is no restore
        // tree left: it is deleted once the VM has booted.
        let restore = mode == .full
            ? try restoreTree(in: bundleDirectory, path: bundlePath, owner: callerUID)
            : nil
        let device = configuredGuestDevice(in: bundleDirectory) ?? guestDevice(of: restore)
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.tvLegacySetup), device.family != .appleTV {
            throw ValidationError("The TV setup compatibility patch is supported only for an Apple TV guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.tvSetupDisplayLookup), device.family != .appleTV {
            throw ValidationError("The TV setup display-connection patch is supported only for an Apple TV guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.tvLocalActivation), device.family != .appleTV {
            throw ValidationError("The TV local-activation patch is supported only for an Apple TV guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.tvSetupFocus), device.family != .appleTV {
            throw ValidationError("The TV setup focus adapter is supported only for an Apple TV guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homeViewProfileLookup), device.family != .homeView {
            throw ValidationError("HomeView guest-profile keybag access requires a HomeView guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homeViewDisplayLookups), device.family != .homeView {
            throw ValidationError("BreadBoard display access is supported only for a HomeView guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homeViewSetupBypass), device.family != .homeView {
            throw ValidationError("The HomeView setup bypass is supported only for a HomeView guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homeViewEnvironmentService), device.family != .homeView {
            throw ValidationError("The HomeView environment simulation service requires a HomeView guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodTopCap), device.family != .homePod {
            throw ValidationError("The HomePod top-cap patch is supported only for a HomePod guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodSetupBypass), device.family != .homePod {
            throw ValidationError("The HomePod setup-completion patch is supported only for a HomePod guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodAirPlayVM), device.family != .homePod {
            throw ValidationError("The HomePod AirPlay patch is supported only for a HomePod guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodAudioProduct), device.family != .homePod {
            throw ValidationError("The HomePod audio-product patch is supported only for a HomePod guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodWelcome), device.family != .homePod {
            throw ValidationError("The HomePod welcome patch is supported only for a HomePod guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodSiriSpeech), device.family != .homePod {
            throw ValidationError("The HomePod Siri-speech patch is supported only for a HomePod guest.")
        }
        if !effectiveEnabled.isDisjoint(with: [FirmwareGuestSystemPatchSet.homePodCryptexStaging, FirmwareGuestSystemPatchSet.homePodCryptexClass, FirmwareGuestSystemPatchSet.homePodAdHocInstall]), device.family != .homePod {
            throw ValidationError("The HomePod cryptex staging patch is supported only for a HomePod guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodSoundGlow), device.family != .homePod {
            throw ValidationError("The HomePod Sound Glow patch is supported only for a HomePod guest.")
        }
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodOTAUserland), device.family != .homePod {
            throw ValidationError("The HomePod OTA userland patch is supported only for a HomePod guest.")
        }
        let missingGlowDependencies = FirmwareGuestPatchResolution.missingHomePodSoundGlowDependencies(enabled: effectiveEnabled)
        guard missingGlowDependencies.isEmpty else {
            throw ValidationError("The HomePod Sound Glow patch requires these selected guest patches: \(missingGlowDependencies.joined(separator: ", ")).")
        }
        let missingSpeechDependencies = FirmwareGuestPatchResolution.missingHomePodSiriSpeechDependencies(enabled: effectiveEnabled)
        guard missingSpeechDependencies.isEmpty else {
            throw ValidationError("The HomePod Siri-speech patch requires these selected guest patches: \(missingSpeechDependencies.joined(separator: ", ")).")
        }
        let missingWelcomeDependencies = FirmwareGuestPatchResolution.missingHomePodWelcomeDependencies(enabled: effectiveEnabled)
        guard missingWelcomeDependencies.isEmpty else {
            throw ValidationError("The HomePod welcome patch requires these selected guest patches: \(missingWelcomeDependencies.joined(separator: ", ")).")
        }
        // Research: an Apple TV 4K userland staged from its OTA, which
        // `system-tv-exp-ota_userland` puts in place of the restored one.
        let hasOTAUserland = (try? bundleDirectory.isDirectory(VPhoneOTAArchive.userlandDirectoryName)) == true
        let isOTAUpdate = !device.usesTVOS && mode == .full && hasOTAUserland
            && effectiveEnabled.contains(FirmwareGuestSystemPatchSet.otaUserland)
        let otaUserland = (device.usesTVOS || isOTAUpdate) && hasOTAUserland
            ? try bundleDirectory.directory(VPhoneOTAArchive.userlandDirectoryName)
            : nil
        if isOTAUpdate {
            guard let otaUserland, let restore, let plan else {
                throw ValidationError("A full OTA update needs staged userland and a target firmware plan.")
            }
            try requireOTAUpdate(ota: otaUserland, restore: restore, plan: plan, device: device)
            // System, kernel and TXM are published together on the same private
            // clone. Never require a separately bootable half-updated disk.
            receiptKernel = Set(plan.enabledPatches)
            let snapshots = try bundleDirectory.directory(VPhoneMachineSnapshots.directoryName)
            let saved = try snapshots.entries().contains { name in
                guard (try? snapshots.isDirectory(name)) == true,
                      let data = try? snapshots.readData("\(name)/Snapshot.plist"),
                      let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let files = metadata["Files"] as? [String] else { return false }
                return ["Disk.img", "SEPStorage", "nvram.bin"].allSatisfy {
                    files.contains($0) && (try? snapshots.isRegularFile("\(name)/\($0)")) == true
                }
            }
            guard saved else { throw ValidationError("OTA update needs a stopped disk/SEP/NVRAM snapshot.") }
        }
        if device.usesTVOS {
            guard let plan else {
                throw ValidationError("tvOS installation needs an explicit patch plan. Resolve a TV selection with `fw set-patches` and `fw patch` first.")
            }
            let unvalidated = device.family == .homeView
                ? FirmwareGuestPatchResolution.unvalidatedHomeViewGuestPatches(enabled: Set(plan.enabledPatches))
                : device.family == .homePod
                ? FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: Set(plan.enabledPatches))
                : FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(
                    enabled: Set(plan.enabledPatches),
                    arm64eUserland: !device.hasPlainArm64Userland,
                )
            guard unvalidated.isEmpty else {
                throw ValidationError("These guest patches have not been validated for tvOS. Block them with `fw set-patches` before installation: \(unvalidated.joined(separator: ", "))")
            }
            // Without the swap the base device's userland would boot on this
            // one, which panics at first boot.
            if mode == .full, let base = device.restoreBase, !plan.enabledPatches.contains(FirmwareGuestSystemPatchSet.tvOTAUserland) {
                throw ValidationError("\(device.productType) has no IPSW of its own, and \(FirmwareGuestSystemPatchSet.tvOTAUserland) is not in its patch plan, so the \(base.productType) userland would boot on it. Allow it with `fw set-patches`, then run `fw patch` again.")
            }
        }
        // Before any disk work, so what it says is not buried under it.
        recoverBoardDeviceTree(in: bundleDirectory, restore: restore, plan: plan, invokingUser: invokingUser)

        let work = try makeWorkDirectory()
        defer {
            do {
                try removeWorkDirectory(work)
            } catch {
                fputs("warning: left CFW work directory at \(work.url.path): \(error)\n", stderr)
            }
        }
        try requireFreeSpace(at: [bundlePath, work.url.path])
        let boardDeviceTree = try stageBoardDeviceTree(in: bundleDirectory, work: work, device: device)
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodAudioProduct) {
            guard let boardDeviceTree else {
                throw ValidationError("HomePod audio identity needs the original board device tree in FirmwareOriginals. Recover it from this VM's IPSW before updating the environment.")
            }
            // Validate the exact donor model and token before cloning or
            // writing any guest filesystem, including malformed/placeholder data.
            _ = try DeviceTreePatcher.homePodAudioProductID(from: Data(contentsOf: boardDeviceTree))
        }
        let homePodDisplay: Data?
        if effectiveEnabled.contains(FirmwareGuestSystemPatchSet.homePodTopCap) {
            guard let boardDeviceTree else {
                throw ValidationError("HomePod top-cap emulation needs the original board device tree in FirmwareOriginals. Recover it from this VM's IPSW before updating the environment.")
            }
            let properties = try DeviceTreePatcher.homePodDisplayProperties(from: Data(contentsOf: boardDeviceTree))
            homePodDisplay = try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
        } else {
            homePodDisplay = nil
        }

        // Work on an APFS clone of Disk.img in the private folder, then rename
        // it over the original: nothing is attached from the caller's folder,
        // and a failed install leaves the original untouched.
        let image: URL
        let cloned = try work.directory.clone(disk, to: "Disk.img")
        if isOTAUpdate, !cloned {
            throw ValidationError("The OTA update needs a private APFS disk clone; the original disk was left untouched.")
        }
        if device.usesTVOS {
            // A paired dyld edit must never fall back to mutating the live disk.
            // Its errors propagate below, so this clone is committed only after
            // the whole install succeeds.
            try CustomFirmwareTVTPROInstallation.requirePrivateClone(cloned)
        }
        if cloned {
            image = work.file("Disk.img")
        } else {
            // Another volume, or no clone support: attach the caller's file
            // in place. Confirm the name still refers to the inode verified
            // above immediately before diskutil opens it. A swap in the moment
            // between this check and diskutil's own open remains possible,
            // and diskutil then works on the caller's own replacement. The
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
            "/usr/sbin/diskutil",
            [
                "image", "attach", "-noMount", image.path,
            ],
        )
        // `diskutil image attach` prints the image's own disk and, on macOS 27, the APFS
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
                _ = try? tool("/usr/sbin/diskutil", ["unmountDisk", "force", String(attached[range])], quiet: true)
                _ = try? tool("/usr/sbin/diskutil", ["eject", String(attached[range])], quiet: true)
            }
            throw ValidationError("Unable to attach the VM disk image. Try again.")
        }
        var diskAttached = true
        defer {
            if diskAttached,
               (try? tool("/usr/sbin/diskutil", ["eject", baseDisk], quiet: true)) == nil
            {
                _ = try? tool("/usr/sbin/diskutil", ["unmountDisk", "force", baseDisk], quiet: true)
                _ = try? tool("/usr/sbin/diskutil", ["eject", baseDisk], quiet: true)
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
        // The identifiers whose bytes are live in the guest after this run, for
        // the receipt. Each step that applies or reverts a guest patch adds to
        // it, so what it holds at the end is exactly the `Guest` part.
        var liveGuest = Set<String>()
        // Resolved once the system volume is mounted (it needs the "was
        // installed" signal there), then used again by the Preboot pass.
        var priorGuest = Set<String>()
        var installedOTAUserland: VPhoneRestoreInfo.OSVersion?
        do {
            // Every descriptor on a guest volume lives in this scope, so none
            // is left open to hold the volume busy when it is unmounted.
            let systemRoot = try openGuestVolume("system", device: "\(container)s1", in: work)
            let xartRoot = try openGuestVolume("xart", device: "\(container)s3", in: work)
            // `launchd.plist.bak` exists only after a full install's first
            // `installVphoned`, so it is the signal that the guest is not
            // pristine. A VM that was never installed has nothing applied, so
            // its prior set is empty whatever a stale plan might say.
            let hasLaunchdBackup = (try? systemRoot.exists("System/Library/xpc/launchd.plist.bak")) ?? false
            // TV installs deliberately omit vphoned and its launchd backup.
            let wasInstalled = hasLaunchdBackup || (device.usesTVOS && receiptGuest != nil)
            priorGuest = receiptGuest ?? (wasInstalled ? priorFallback : [])
            if isOTAUpdate {
                guard wasInstalled, let otaUserland else {
                    throw ValidationError("An OTA update needs an installed guest and staged userland.")
                }
                // All original System bytes disappear. Old receipts and .bak files
                // must not make the new cache skip patches shared with the old OS.
                try replaceOTAUserland(system: systemRoot, ota: otaUserland, work: work)
                guard let restore else { throw ValidationError("OTA target restore tree is missing.") }
                try stageOTASystemApps(restore: restore, system: systemRoot, work: work, owner: callerUID)
                priorGuest = []
            }
            switch mode {
            case .kernelUpdate:
                break // handled by runKernelUpdate, never reached here
            case .full:
                guard let restore else {
                    throw ValidationError("A full CFW install needs a prepared restore tree.")
                }
                liveGuest = try applyGuestPatches(
                    guestDevice: device,
                    system: systemRoot,
                    xart: xartRoot,
                    restore: restore,
                    work: work,
                    owner: callerUID,
                    otaUserland: otaUserland,
                    homePodDisplay: homePodDisplay,
                    plan: plan,
                    priorGuest: priorGuest,
                    kernelPatches: receiptKernel,
                    environmentOnly: false,
                    strict: isOTAUpdate,
                )
                if isOTAUpdate { liveGuest.insert(FirmwareGuestSystemPatchSet.otaUserland) }
            case .environmentOnly:
                // Evidence a full install ran: nothing to update over otherwise.
                guard wasInstalled else {
                    throw ValidationError(
                        "This VM has no CFW install to update. Run `vphone-cli cfw install` first.",
                    )
                }
                liveGuest = try applyGuestPatches(
                    guestDevice: device,
                    system: systemRoot,
                    xart: nil,
                    restore: nil,
                    work: work,
                    owner: nil,
                    otaUserland: otaUserland,
                    homePodDisplay: homePodDisplay,
                    plan: plan,
                    priorGuest: priorGuest,
                    kernelPatches: receiptKernel,
                    environmentOnly: true,
                )
            }
            if liveGuest.contains(FirmwareGuestSystemPatchSet.homePodOTAUserland)
                || liveGuest.contains(FirmwareGuestSystemPatchSet.tvOTAUserland) {
                // Read the installed bytes while the private System is still
                // mounted. Preparation/base restore must never promote this
                // host label before a successful OTA System installation.
                let data = try systemRoot.readData("System/Library/CoreServices/SystemVersion.plist")
                guard let version = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let product = version["ProductVersion"] as? String,
                      let build = version["ProductBuildVersion"] as? String else {
                    throw ValidationError("Installed OTA userland has no SystemVersion identity.")
                }
                installedOTAUserland = .init(version: product, build: build)
            }
        }
        // The selected Preboot identity can also reach an installed guest through
        // an environment update, using its installed tree without a restore.
        // A guest that has booted keeps the MobileGestalt answers it cached from
        // the old tree on its Data volume, which the host cannot reach. vphoned
        // drops that cache at startup when it is older than the tree; see
        // VPhoneDaemon/Daemon/GuestMobileGestaltCache.swift.
        let buildVersion = plan?.parameters[FirmwareGuestSystemPatchSet.buildVersionParameter] ?? spoofBuild
        // An environment update has no restore tree to read the device from;
        // the VM's configuration says which board repair its tree takes.
        try liveGuest.formUnion(patchPreboot(
            volumes: volumes,
            work: work,
            plan: plan,
            priorGuest: priorGuest,
            guestDevice: device,
            includeIdentity: mode == .full
                || plan?.isEnabled(FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity) == true,
            buildVersion: buildVersion,
            boardDeviceTree: boardDeviceTree,
            otaRestore: isOTAUpdate ? restore : nil,
        ))
        // Selected patches this guest has nothing for, so the receipt does not
        // report them as missing forever: the board audio repair on an
        // iPhone XS Max, which is not presented as its own board, the iPhone
        // product repair on a non-iPhone, and the build spoof with no value set. A
        // guest whose board tree could not be recovered is not among them: its
        // repair is missing, and drift should keep saying so.
        var notApplicableGuest = Set<String>()
        if !device.presentsBoard {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootBoardAudio)
        }
        if device.family != .iPhone {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootIPhoneProduct)
        }
        if device.family != .homePod {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.homePodAudioProduct)
        }
        if !Self.isFoldable(device) {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootFoldableVMSubtype)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootFoldableProductId)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.prebootFoldableDisplays)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.hinge)
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.foldGuard)
        }
        if !device.usesTVOS {
            notApplicableGuest.insert(FirmwareGuestSystemPatchSet.tvTPRO)
        }
        if buildVersion?.isEmpty ?? true {
            notApplicableGuest.insert("system-systemversion-cfw-build_version")
        }
        notApplicableGuest.subtract(liveGuest)
        // The snapshot rename is a full install's alone: it has already been
        // done on any VM an environment update is allowed to run against, and
        // this run creates no new snapshot to flip.
        _ = try tool("/sbin/umount", [xart.path])
        xartMounted = false
        _ = try tool("/sbin/umount", [system.path])
        systemMounted = false
        _ = try tool("/usr/sbin/diskutil", ["eject", baseDisk], quiet: true)
        diskAttached = false
        if mode == .full, !isOTAUpdate {
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
        if isOTAUpdate {
            recordKernelcacheReceipt(enabled: effectiveEnabled, in: bundleDirectory,
                                     owner: invokingUser.map { ($0.uid, $0.gid) })
            recordKernelcacheReceipt(enabled: effectiveEnabled, in: bundleDirectory,
                                     owner: invokingUser.map { ($0.uid, $0.gid) }, component: .txm)
        }
        // A serial-only research selection can leave vphoned off. Its host
        // copy exists only after installVphoned staged it successfully.
        if try work.directory.isRegularFile("vphoned") {
            try installSignedDaemonCopy(
                in: bundleDirectory,
                work: work,
                owner: invokingUser.map { ($0.uid, $0.gid) },
            )
        }
        // Record what is live in the guest now. Written through the pinned
        // bundle descriptor as the caller, 0777 like every other host VM
        // artifact, replacing only the `Guest` part so a boot-chain part a
        // restore or `fw patch` wrote stays. A failure here must not fail a
        // finished install: the guest already carries the bytes.
        recordGuestReceipt(
            live: liveGuest,
            notApplicable: notApplicableGuest,
            in: bundleDirectory,
            owner: invokingUser.map { ($0.uid, $0.gid) },
        )
        if let installedOTAUserland {
            let installedBundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
            let record: () throws -> Void = {
                let vm = try VPhoneBundle.load(at: installedBundle)
                let variant = VPhoneRestoreInfo.load(fromBundle: vm)?.variant ?? "jb"
                _ = try VPhoneRestoreInfo.recordVariant(variant, toBundle: vm,
                                                        installedUserland: installedOTAUserland)
            }
            do {
                if let invokingUser { try invokingUser.withUserCredentials(record) }
                else { try record() }
            } catch {
                fputs("warning: could not record installed OTA userland: \(error)\n", stderr)
            }
        }
        switch mode {
        case .full:
            if liveGuest.contains("system-vphoned-boot-install") {
                print("[+] CFW system install complete; vphoned is installed, no package bootstrap was staged")
            } else {
                print("[+] CFW system install complete; vphoned is not installed")
            }
        case .environmentOnly:
            print("[+] Guest environment updated; start the VM to pick it up")
        case .kernelUpdate:
            break // handled by runKernelUpdate
        }
    }

    /// Refuses unless no process but this one holds the disk. Any other
    /// holder refuses, whatever it is: the install rewrites the disk under
    /// it. The refusal names each holder's executable, so a process that
    /// only reads the image (Launchpad measuring it, a backup tool) is not
    /// taken for a running VM.
    static func requireDiskUnused(lsofOutput: String, rerun: String) throws {
        let holders = VPhoneLsof.parsePIDs(lsofOutput).filter { $0 != getpid() }.map { VPhoneProcessHolder(pid: $0) }
        if let refusal = VPhoneProcessHolder.diskRefusal(holders, rerun: rerun) {
            throw ValidationError(refusal)
        }
    }

    /// Replace only the Preboot kernelcache, keeping every volume.
    ///
    /// The booting kernel lives in Preboot as an IMG4. `fw patch` has already
    /// rebuilt `kernelcache.research.vphone600` in the restore tree with the
    /// current selection; this swaps that IM4P into the Preboot IMG4 under its
    /// signed IM4M (the image4 bypass accepts it, as for the device tree) and
    /// nothing else. No volume is reformatted, so the guest's data survives —
    /// the one boot-chain change that reaches an installed guest without the
    /// erasing restore.
    ///
    /// The disk plumbing (clone, attach, find the container, swap the clone
    /// back) mirrors `run()`; it is kept separate so this cannot affect the
    /// full install or the environment update, and does not mount the System or
    /// xART volumes or touch the root snapshot — iBoot reads the kernelcache
    /// from Preboot directly.
    private func runKernelUpdate() throws {
        let invokingUser = VPhoneInvokingUser.current
        let callerUID = invokingUser?.uid
        let bundleDirectory = try pinBundle(owner: callerUID)
        let bundlePath = try bundleDirectory.path
        let recordedPlan = readPatchPlan(in: bundleDirectory)
        if Self.restoredCustomisedSystem(recordedPlan) {
            throw Self.restoreImageRefusal(mode)
        }
        // Its originals hold the research board's kernel, not the mix.
        if recordedPlan?.isEnabled(FirmwareResearchBoardPatchSet.kernelMix) == true {
            throw ValidationError(
                "This VM boots a kernelcache rebuilt from the research board's (its cloudOS has no vphone600 components), "
                    + "which a kernel update cannot rebuild. Change its kernel patches with `fw patch` and a restore instead.",
            )
        }

        let disk = try openDiskImage(in: bundleDirectory, path: bundlePath, owner: callerUID)
        let diskPath = (bundlePath as NSString).appendingPathComponent("Disk.img")
        let busy = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", diskPath],
        )
        try Self.requireDiskUnused(lsofOutput: busy.stdout, rerun: "run the kernel update again")

        let work = try makeWorkDirectory()
        defer {
            do { try removeWorkDirectory(work) } catch {
                fputs("warning: left CFW work directory at \(work.url.path): \(error)\n", stderr)
            }
        }
        try requireFreeSpace(at: [bundlePath, work.url.path])

        let (patched, enabledKernelPatches) = try patchedKernelcacheForUpdate(
            in: bundleDirectory, path: bundlePath, owner: callerUID, work: work,
        )

        let image: URL
        let cloned = try work.directory.clone(disk, to: "Disk.img")
        if cloned {
            image = work.file("Disk.img")
        } else {
            guard try bundleDirectory.refersTo("Disk.img", file: disk) else {
                throw ValidationError("The VM disk image changed during the kernel update. Try again.")
            }
            image = try URL(fileURLWithPath: bundleDirectory.path).appendingPathComponent("Disk.img")
        }

        let attached = try tool(
            "/usr/sbin/diskutil",
            ["image", "attach", "-noMount", image.path],
        )
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
                _ = try? tool("/usr/sbin/diskutil", ["unmountDisk", "force", String(attached[range])], quiet: true)
                _ = try? tool("/usr/sbin/diskutil", ["eject", String(attached[range])], quiet: true)
            }
            throw ValidationError("Unable to attach the VM disk image. Try again.")
        }
        var diskAttached = true
        defer {
            if diskAttached,
               (try? tool("/usr/sbin/diskutil", ["eject", baseDisk], quiet: true)) == nil
            {
                _ = try? tool("/usr/sbin/diskutil", ["unmountDisk", "force", baseDisk], quiet: true)
                _ = try? tool("/usr/sbin/diskutil", ["eject", baseDisk], quiet: true)
            }
        }

        let info = try tool("/usr/sbin/diskutil", ["info", "-plist", "\(baseDisk)s1"], quiet: true)
        guard
            let plist = try PropertyListSerialization.propertyList(from: Data(info.utf8), format: nil) as? [String: Any],
            let container = plist["APFSContainerReference"] as? String,
            container.hasPrefix("disk")
        else {
            throw ValidationError("Unable to read the VM disk image. Try again.")
        }
        let volumes = try containerVolumes(container, physicalStore: "\(baseDisk.dropFirst("/dev/".count))s1")
        guard
            let preboot = volumes.first(where: { ($0["Roles"] as? [String])?.contains("Preboot") == true }),
            let device = preboot["DeviceIdentifier"] as? String
        else {
            throw ValidationError("Unable to find the VM's Preboot volume. Restore the VM, then install CFW again.")
        }

        print("[*] \(mode.summary.capitalized): \(bundle.lastPathComponent)")
        let mount = work.file("preboot")
        _ = try work.directory.directory("preboot", create: true, mode: 0o700)
        var prebootMounted = false
        defer {
            if prebootMounted,
               (try? tool("/sbin/umount", [mount.path], quiet: true)) == nil
            {
                _ = try? tool("/sbin/umount", ["-f", mount.path], quiet: true)
            }
        }
        prebootMounted = true
        try mountGuestVolume(device, at: mount)
        let changed: Bool = try {
            let root = try openGuestVolume("preboot", device: device, in: work)
            // The one kernelcache, reached without a link anywhere on the way.
            let candidates = try root.entries().compactMap { name -> String? in
                let path = "\(name)/System/Library/Caches/com.apple.kernelcaches/kernelcache"
                guard (try? root.isDirectory(name)) == true, (try? root.isRegularFile(path)) == true else {
                    return nil
                }
                return path
            }
            guard candidates.count == 1, let kernelcache = candidates.first else {
                throw ValidationError("Expected one kernelcache in the Preboot volume but found \(candidates.count). Restore the VM, then install CFW again.")
            }
            guard let meta = try root.status(kernelcache), meta.st_mode & S_IFMT == S_IFREG else {
                throw ValidationError("The Preboot kernelcache is missing or not a regular file. Restore the VM again.")
            }
            let current = try root.readData(kernelcache)
            guard let newBytes = try CustomFirmwarePostRestoreDeviceTree.kernelcacheReplacingPayload(
                prebootIMG4: current, patchedKernelcache: patched,
            ) else {
                print("  [.] Preboot kernelcache already matches the patched one — no change")
                return false
            }
            let staged = work.file("kernelcache.new")
            try newBytes.write(to: staged)
            try root.replaceFile(kernelcache, fromFileAt: staged, mode: meta.st_mode & 0o7777, owner: (meta.st_uid, meta.st_gid))
            print("  [+] Preboot kernelcache replaced (\(current.count) -> \(newBytes.count) bytes), manifest kept")
            return true
        }()

        _ = try tool("/sbin/umount", [mount.path])
        prebootMounted = false
        _ = try tool("/usr/sbin/diskutil", ["eject", baseDisk], quiet: true)
        diskAttached = false
        // No snapshot rename: the kernelcache is read from Preboot, not from the
        // System volume's root snapshot, so nothing on System changed.
        if cloned, changed {
            try work.directory.setOwner("Disk.img", uid: disk.owner, gid: disk.group)
            try work.directory.setMode("Disk.img", disk.mode & 0o777)
            try work.directory.rename("Disk.img", to: "Disk.img", in: bundleDirectory)
        }
        // Record the selected identifiers even when the bytes were already present.
        recordKernelcacheReceipt(
            enabled: enabledKernelPatches,
            in: bundleDirectory,
            owner: invokingUser.map { ($0.uid, $0.gid) },
        )
        print("[+] Guest kernel updated; start the VM to boot the re-patched kernelcache")
    }

    /// The patched kernelcache (a bare IM4P) to install into Preboot, for the
    /// VM's current selection.
    ///
    /// Preferred source: the pristine kernelcache in `FirmwareOriginals`,
    /// re-patched here with the selection. This needs no restore tree, so it
    /// works on a VM in normal use, and reflects a `fw set-patches` made since
    /// the last `fw patch`. Root re-patches only for a bundled preset; a preset
    /// naming an external `.vphonepatchset` is not loaded here (root loads no
    /// external set), and falls back to the restore tree `fw patch` wrote as the
    /// user. A VM with neither is refused.
    private func patchedKernelcacheForUpdate(
        in bundleDirectory: VPhoneConfinedDirectory,
        path bundlePath: String,
        owner: uid_t?,
        work: WorkDirectory,
    ) throws -> (payload: Data, enabledKernelPatches: Set<String>) {
        let selection = (try? bundleDirectory.readData(VPhonePatchPresetStore.selectionFileName))
            .flatMap { try? PropertyListDecoder().decode(VPhoneVirtualMachinePatchSelection.self, from: $0) }
            ?? VPhoneVirtualMachinePatchSelection()
        let plan = readPatchPlan(in: bundleDirectory)
        if let pristine = try firmwareOriginalsKernelcache(in: bundleDirectory),
           let preset = VPhonePatchPresetStore.preset(
               named: selection.presetIdentifier,
               vmCopy: try? bundleDirectory.readData(VPhonePatchPresetStore.vmPresetFileName),
           ),
           !preset.patchSets.contains(where: {
               if case .external = $0 {
                   true
               } else {
                   false
               }
           })
        {
            try pristine.directory.copyFile(from: pristine.name, to: "kernelcache.im4p", in: work.directory)
            let copy = work.file("kernelcache.im4p")
            let pipeline = FirmwarePipeline(
                vmDirectory: URL(fileURLWithPath: bundlePath, isDirectory: true),
                // The public firmware mode is JB; .regular would leave out the
                // AMFI and other custom-firmware kernel patches and CS_KILL launchd.
                variant: .jb,
                verbose: true,
                preset: preset,
                blockedPatches: Set(selection.blockedPatches),
                allowedPatches: Set(selection.allowedPatches),
            )
            let changed = try pipeline.patchKernelcacheFile(
                at: copy,
                iOSBase: plan?.iOSBaseVersion.flatMap(VPhoneVersion.init),
                cloudOS: plan?.cloudOSVersion.flatMap(VPhoneVersion.init),
            )
            print("  [*] kernelcache re-patched from \(VPhoneBundleOperations.firmwareOriginalsDirectoryName)"
                + (changed ? "" : " (preset leaves every kernel patch off)"))
            return try (Data(contentsOf: copy), Set(pipeline.resolvedPlan?.enabled ?? []))
        }
        // No originals, or an external-set preset: the restore tree's kernelcache
        // was patched by `fw patch` running as the user.
        if let restore = try? restoreTree(in: bundleDirectory, path: bundlePath, owner: owner),
           let data = try? restore.readData("kernelcache.research.vphone600")
        {
            print("  [*] kernelcache taken from the restore tree")
            return (data, Set(plan?.enabledPatches ?? []))
        }
        throw ValidationError(
            "No kernelcache to install: this VM has no \(VPhoneBundleOperations.firmwareOriginalsDirectoryName) and no restore tree. Remove the restore tree and run `fw prepare` + `fw patch`, or recreate the VM.",
        )
    }

    /// The pristine kernelcache kept in `FirmwareOriginals/<tree>/`, or nil when
    /// the VM was patched by a build that kept no originals. Reached without a
    /// link anywhere on the way.
    private func firmwareOriginalsKernelcache(
        in bundleDirectory: VPhoneConfinedDirectory,
    ) throws -> (directory: VPhoneConfinedDirectory, name: String)? {
        let originalsName = VPhoneBundleOperations.firmwareOriginalsDirectoryName
        guard (try? bundleDirectory.isDirectory(originalsName)) == true,
              let originals = try? bundleDirectory.directory(originalsName)
        else { return nil }
        for tree in (try? originals.entries()) ?? [] {
            guard (try? originals.isDirectory(tree)) == true,
                  let treeDir = try? originals.directory(tree),
                  (try? treeDir.isRegularFile("kernelcache.research.vphone600")) == true
            else { continue }
            return (treeDir, "kernelcache.research.vphone600")
        }
        return nil
    }

    /// Record the kernelcache part of the receipt with the kernel patches the
    /// plan `fw patch` resolved. Best-effort, like `recordGuestReceipt`.
    private func recordKernelcacheReceipt(
        enabled: Set<String>,
        in bundleDirectory: VPhoneConfinedDirectory,
        owner: (uid: uid_t, gid: gid_t)?,
        component: VPhoneFirmwareComponent = .kernelcache,
    ) {
        let kernelPatches = FirmwarePatchSetCatalog.allDeclarations
            .filter { $0.target == .firmware(component) && enabled.contains($0.identifier) }
            .map(\.identifier)
        do {
            var receipt = (try? bundleDirectory.readData(VPhonePatchPresetStore.receiptFileName))
                .flatMap { try? VPhoneVirtualMachinePatchReceipt.decode($0) }
                ?? VPhoneVirtualMachinePatchReceipt()
            receipt.record(
                component.rawValue,
                patches: kernelPatches,
                writer: component == .kernelcache ? "cfw update-kernel" : "cfw install (full OTA)",
                bundleVersion: bundleVersion,
            )
            try bundleDirectory.writeFile(
                VPhonePatchPresetStore.receiptFileName,
                contents: receipt.encoded(),
                mode: 0o777,
                owner: owner,
            )
        } catch {
            fputs("warning: could not record the kernelcache receipt: \(error)\n", stderr)
        }
    }

    /// Whether the VM's restore installed a system customised by `fw patch`
    /// (``FirmwareRestoreImagePatchSet``), which nothing may write afterwards.
    static func restoredCustomisedSystem(_ plan: VPhoneVirtualMachinePatchPlan?) -> Bool {
        plan?.enabledPatches.contains(FirmwareRestoreImagePatchSet.cryptexMerge) == true
    }

    static func restoreImageRefusal(_ mode: Mode) -> ValidationError {
        ValidationError(
            "This VM's system was customised before its restore (the \(VPhonePatchPreset.minimalIdentifier) preset), "
                + "and a \(mode.summary) would break its seal. Patch and restore the VM again instead.",
        )
    }

    /// The verb to credit a receipt write to.
    private var receiptWriter: String {
        mode == .full ? "cfw install" : "cfw update-environment"
    }

    /// Replace the receipt's `Guest` part with the identifiers live in the
    /// guest, keeping every other part. Read-modify-write through the pinned
    /// bundle descriptor so a planted link cannot redirect the write, and left
    /// 0777 and owned by the caller like Disk.img and the signed daemon copy.
    private func recordGuestReceipt(
        live: Set<String>,
        notApplicable: Set<String>,
        in bundleDirectory: VPhoneConfinedDirectory,
        owner: (uid: uid_t, gid: gid_t)?,
    ) {
        do {
            var receipt = (try? bundleDirectory.readData(VPhonePatchPresetStore.receiptFileName))
                .flatMap { try? VPhoneVirtualMachinePatchReceipt.decode($0) }
                ?? VPhoneVirtualMachinePatchReceipt()
            receipt.record(
                VPhoneVirtualMachinePatchReceipt.guestPart,
                patches: live,
                writer: receiptWriter,
                bundleVersion: bundleVersion,
                notApplicable: notApplicable,
            )
            try bundleDirectory.writeFile(
                VPhonePatchPresetStore.receiptFileName,
                contents: receipt.encoded(),
                mode: 0o777,
                owner: owner,
            )
        } catch {
            fputs("warning: could not record the guest patch receipt: \(error)\n", stderr)
        }
    }

    /// This `VPhone.bundle`'s version, for the receipt, or nil for a plain
    /// `swift build` of `vphone-cli` with no bundle Info.plist beside it.
    private var bundleVersion: String? {
        let info = executable
            .deletingLastPathComponent() // Contents/MacOS
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    // MARK: - Environment update

    /// Guest patches declared after most VMs' plans were written, so a plan
    /// reads them as off even when the VM's selection has them on. They need no
    /// firmware change, so the guest half applies them from the selection. Kept
    /// only to reconstruct what the old `withLateGuestPatches` would have
    /// applied, for a VM that was installed but carries no receipt yet (see the
    /// prior-live fallback in `run()`).
    private static let lateGuestPatches = [
        FirmwareGuestSystemPatchSet.virtioSoundDriver,
        FirmwareGuestSystemPatchSet.prebootBoardAudio,
        FirmwareGuestSystemPatchSet.prebootHaptics,
        FirmwareGuestSystemPatchSet.prebootMicrophoneArray,
        FirmwareGuestSystemPatchSet.virtualAudioSpeakerRouteThrows,
        FirmwareGuestSystemPatchSet.virtualAudioMuteSetThrow,
        FirmwareGuestSystemPatchSet.virtualAudioSpeakerProtectionGate,
        FirmwareGuestSystemPatchSet.virtualAudioVolumeModePrecondition,
        FirmwareGuestSystemPatchSet.virtualAudioGraphConfigurations,
        FirmwareGuestSystemPatchSet.virtualAudioSpeakerRawChains,
        FirmwareGuestSystemPatchSet.virtualAudioMicrophoneChains,
    ]

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

    /// The free space a run needs before it touches the disk. A full install
    /// unpacks cryptexes and the GPU bundle from a prepared restore tree into
    /// an APFS clone of Disk.img, which takes tens of GiB. An environment or
    /// kernel update writes only this bundle's guest files or one kernelcache
    /// into that clone, so asking it for the same 50 GiB refused the update on
    /// any Mac with a few VMs on it, while the update itself needed a small
    /// fraction of that. 10 GiB still stops it on a volume that is close to
    /// full.
    static func requiredFreeSpaceGiB(for mode: Mode) -> Int64 {
        switch mode {
        case .full: 50
        case .environmentOnly, .kernelUpdate: 10
        }
    }

    private func requireFreeSpace(at paths: [String]) throws {
        let requiredGiB = Self.requiredFreeSpaceGiB(for: mode)
        var seen = Set<dev_t>()
        for path in paths {
            var metadata = stat()
            guard stat(path, &metadata) == 0, seen.insert(metadata.st_dev).inserted else { continue }
            var capacity =
                try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
            // Fallback: Some external volumes return 0 for volumeAvailableCapacityForImportantUsageKey.
            // Use statfs as a fallback to get actual available space.
            if capacity == 0 {
                var fs = statfs()
                if statfs(path, &fs) == 0 {
                    capacity = Int64(fs.f_bavail) * Int64(fs.f_bsize)
                    fputs("warning: Volume at \(path) reported 0 available space via resource keys, using statfs fallback: \(capacity / (1024 * 1024 * 1024)) GiB\n", stderr)
                }
            }
            guard capacity > requiredGiB * 1024 * 1024 * 1024 else {
                throw ValidationError("Less than \(requiredGiB) GiB of disk space is available on the volume holding \(path). Free up space, then run the \(mode.summary) again.")
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

    /// Apply the guest half of an install, both directions: every guest patch
    /// the plan turns on is written, and every one it leaves off is reverted
    /// where a backup or undo record exists. Returns the identifiers live in the
    /// guest afterwards, for the receipt — the ones applied, plus any a now-off
    /// patch could not be reverted (no backup, no undo record) that was live
    /// before, which stay in place and stay recorded.
    ///
    /// `restore` is the prepared restore tree, or nil for an environment update:
    /// the cryptexes and the GPU bundle come from it, so those steps are skipped
    /// with a note when it is absent (an installed guest already carries them).
    /// `xart` is the gigalocker volume, or nil when it was not mounted. With
    /// `environmentOnly`, the vphoned/library redeploy keeps its old narrow rule
    /// (a library absent from the VM stays absent, no `/vh` alias is created) and
    /// no restore-tree step runs.
    ///
    /// Paired TV dyld updates abort on failure and discard the private disk
    /// clone, preserving the original disk and receipt. Selected X1 bootstrap
    /// patches also abort on failure: continuing would boot an incompatible
    /// cache or executable. Other patches run in isolation: one patch failing — a verb rejecting an
    /// unexpected prologue on an older VM, say — is reported and the patch is
    /// left in its prior state, but the run continues and the vphoned redeploy,
    /// done first, is never blocked. Non-patch failures (a volume that will not
    /// mount, the cryptex copy) still abort. The run exits 0 even with patch
    /// failures; they are printed as `[!]` lines and summarised at the end.
    @discardableResult
    private func applyGuestPatches(
        guestDevice: VPhoneGuestDevice,
        system: VPhoneConfinedDirectory,
        xart: VPhoneConfinedDirectory?,
        restore: VPhoneConfinedDirectory?,
        work: WorkDirectory,
        owner: uid_t?,
        otaUserland: VPhoneConfinedDirectory?,
        homePodDisplay: Data?,
        plan: VPhoneVirtualMachinePatchPlan?,
        priorGuest: Set<String>,
        kernelPatches: Set<String>?,
        environmentOnly: Bool,
        strict: Bool = false,
    ) throws -> Set<String> {
        var live = Set<String>()
        var failures: [String] = []

        // Whether the VM's plan (its guest half re-resolved from the current
        // selection) turned this guest patch on. A VM with no plan gets every
        // legacy patch, which is what it was restored with. New Settings-row
        // preferences and motion sensors still require an explicit plan.
        func on(_ identifier: String) -> Bool {
            guard let plan else {
                return !FirmwareGuestSystemPatchSet.settingsRowPatches.contains(identifier)
                    && identifier != FirmwareGuestSystemPatchSet.gyroscope
                    && identifier != FirmwareGuestSystemPatchSet.accelerometer
                    && identifier != FirmwareGuestSystemPatchSet.attitude
                    && identifier != FirmwareGuestSystemPatchSet.hinge
                    && identifier != FirmwareGuestSystemPatchSet.foldGuard
            }
            guard plan.isEnabled(identifier) else {
                print("  [·] \(identifier): off in preset \(plan.presetIdentifier)")
                return false
            }
            return true
        }

        // A first backup of a file is safe only when no patch that touches the
        // file was live before this run: otherwise the "original" we would
        // snapshot already carries a patch, and a later revert to it would be a
        // lie. When it is not safe the file's patches are not revertible.
        func backupSafe(_ ids: String...) -> Bool {
            ids.allSatisfy { !priorGuest.contains($0) }
        }

        // Run a patch step so a throw does not abort the run: report it, keep
        // each covered patch's prior-live state in the receipt, and carry on.
        func isolate(_ ids: [String], _ body: () throws -> Void) {
            do {
                try body()
            } catch {
                failures.append(contentsOf: ids)
                print("  [!] \(ids.joined(separator: ", ")): patch step failed, left in its prior state: \(error)")
                for id in ids where priorGuest.contains(id) {
                    live.insert(id)
                }
            }
        }

        // A Mach-O patch: apply from the pristine backup when on, restore the
        // backup when off. A binary off with no `.bak` (patched before backups
        // were kept) is left as it is and, if it was live before, stays
        // recorded as live — nothing here can put Apple's original back without
        // the restore tree.
        func machO(
            _ identifier: String,
            path: String,
            verbs: [String] = [],
            codeIdentifier: String? = nil,
            preserveEntitlements: Bool = false,
            injectedDylibPath: String? = nil,
            bundle: String? = nil,
        ) {
            isolate([identifier]) {
                if on(identifier) {
                    try patchMachO(
                        system: system, work: work, path: path, verbs: verbs,
                        identifier: codeIdentifier, preserveEntitlements: preserveEntitlements,
                        injectedDylibPath: injectedDylibPath,
                    )
                    if let bundle {
                        try sealGuestBundle(system: system, bundle: bundle)
                    }
                    live.insert(identifier)
                } else if try revertMachO(system: system, work: work, path: path, bundle: bundle) {
                    print("  [+] \(identifier): restored \(path) from backup")
                } else if priorGuest.contains(identifier) {
                    print("  [!] \(identifier): off now but no backup to revert; leaving the patched binary (not revertible)")
                    live.insert(identifier)
                }
            }
        }

        // First, so every later step patches the userland that will boot.
        if guestDevice.usesTVOS {
            let identifier = guestDevice.family == .homePod
                ? FirmwareGuestSystemPatchSet.homePodOTAUserland : FirmwareGuestSystemPatchSet.tvOTAUserland
            if on(identifier) {
                guard let otaUserland else {
                    throw ValidationError("\(identifier) is on, but the VM has no OTAUserland folder with the staged payload chunks.")
                }
                if guestDevice.family == .homePod {
                    try replaceHomePodUserland(system: system, ota: otaUserland, work: work, plan: plan, device: guestDevice)
                } else {
                    try replaceTVUserland(system: system, ota: otaUserland, work: work)
                }
                live.insert(identifier)
            } else if priorGuest.contains(identifier) {
                print("  [!] \(identifier): off now, but the swapped userland cannot be reverted without a restore")
                live.insert(identifier)
            }
        }
        if priorGuest.contains(FirmwareGuestSystemPatchSet.otaUserland) {
            // A checkbox cannot put a previous OS back. Only the stopped
            // disk/SEP/NVRAM snapshot can reverse a completed system update.
            live.insert(FirmwareGuestSystemPatchSet.otaUserland)
            if !on(FirmwareGuestSystemPatchSet.otaUserland) {
                print("  [!] full OTA System update is not reverted by deselection; restore the stopped machine snapshot to roll back")
            }
        }

        if let restore {
            try installCryptexes(restore: restore, system: system, work: work, owner: owner, replaceExisting: strict)
        }
        let version = try productVersion(system: system)

        func requireX1Bootstrap() throws {
            let required: Set<String> = [
                FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap,
                FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap,
                FirmwareGuestSystemPatchSet.arm64eX1LaunchdBootstrap,
                FirmwareGuestSystemPatchSet.arm64eX1FsckBootstrap,
                FirmwareGuestSystemPatchSet.arm64eX1MountBootstrap,
            ]
            let failed = Set(failures).intersection(required).filter {
                plan?.isEnabled($0) ?? version.hasPrefix("27.")
            }.sorted()
            guard failed.isEmpty else {
                throw ValidationError("Required X1 boot patches failed; installation stopped before setup boot: \(failed.joined(separator: ", ")). See the patch error above.")
            }
        }

        if version.hasPrefix("27.") || priorGuest.contains(FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap) {
            machO(FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap, path: "usr/lib/dyld",
                  verbs: ["patch-arm64e-x1"], preserveEntitlements: true)
            try requireX1Bootstrap()
        }
        if version.hasPrefix("27.") || priorGuest.contains(FirmwareGuestSystemPatchSet.arm64eX1FsckBootstrap) {
            machO(FirmwareGuestSystemPatchSet.arm64eX1FsckBootstrap, path: "sbin/fsck",
                  verbs: ["patch-arm64e-x1"], preserveEntitlements: true)
            try requireX1Bootstrap()
        }
        if version.hasPrefix("27.") || priorGuest.contains(FirmwareGuestSystemPatchSet.arm64eX1MountBootstrap) {
            machO(FirmwareGuestSystemPatchSet.arm64eX1MountBootstrap, path: "sbin/mount",
                  verbs: ["patch-arm64e-x1"], preserveEntitlements: true)
            try requireX1Bootstrap()
        }

        // CIBarcode is a standalone Core Image plug-in, outside the shared cache.
        // Lower it ahead of time rather than relying on an application's inherited
        // exception handler to translate these instructions at runtime.
        // The normal Mach-O path keeps a pristine backup and re-seals the bundle;
        // deselecting the declaration restores it on the next environment update.
        if version.hasPrefix("27.1.") || version == "27.1"
            || priorGuest.contains(FirmwareGuestSystemPatchSet.arm64eX1CIBarcode)
        {
            machO(
                FirmwareGuestSystemPatchSet.arm64eX1CIBarcode,
                path: FirmwareGuestSystemPatchSet.ciBarcodeExecutablePath,
                verbs: ["patch-arm64e-x1"],
                preserveEntitlements: true,
                bundle: FirmwareGuestSystemPatchSet.ciBarcodeBundlePath,
            )
        }

        // 0. A cache whose span alone overruns the guest kernel's shared region
        //    maps at no slide, and the guest panics on first boot. Refuse before
        //    the redeploy and the cache patches. A header this check cannot read
        //    is left to the dyld patches below, as it was before the check.
        //
        //    The region is the widened 0x1C0000000 only when this VM's kernel
        //    carries `kernel-boot-shared_region_size`, as its receipt records:
        //    a 27.x VM restored by an older bundle, or with the patch unticked,
        //    still has the stock 6 GiB and must still be refused. A VM with no
        //    kernelcache receipt falls back to the patch's applicability, the
        //    27.x base.
        // The selected TV donor has a native arm64 cache. Keep its directory
        // intact; cryptex symlinks would point into images it does not ship.
        let cacheRelative = guestDevice.usesTVOS
            ? "System/Library/Caches/com.apple.dyld"
            : "System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
        let cacheArchitecture = guestDevice.hasPlainArm64Userland ? "arm64" : "arm64e"
        let dsc = try verifiedDyldCacheDirectory(system: system, relative: cacheRelative)
        let widenedRegion = kernelPatches.map { $0.contains("kernel-boot-shared_region_size") }
            ?? version.hasPrefix("27.")
        let kernelRegionSize = widenedRegion
            ? DyldSharedCacheMaxSlidePatcher.patchedKernelSharedRegionSize
            : DyldSharedCacheMaxSlidePatcher.kernelSharedRegionSize
        do {
            try DyldSharedCacheMaxSlidePatcher.requireFitsAtSlideZero(
                chunksDirectory: URL(fileURLWithPath: dsc),
                architecture: cacheArchitecture,
                kernelRegionSize: kernelRegionSize,
            )
        } catch let overflow as DyldSharedCacheMaxSlidePatcher.RegionOverflow {
            throw overflow
        } catch {
            // Expected: the preflight looks for the plain arm64e cache file,
            // and every iOS 27 guest ships a chunked X1 cache the later cache
            // stage measures directly. Nothing to report.
            print("  [·] shared region check skipped: the cache is not a plain \(cacheArchitecture) file")
        }

        if guestDevice.hasPlainArm64Userland {
            let identifier = FirmwareGuestSystemPatchSet.tvTPRO
            let enabled = on(identifier)
            // Unlike independent optional patches, dyld's two copies form a
            // boot-critical pair. Abort on any error; never commit a partial
            // pair or describe it as unchanged via isolate's catch-and-continue.
            let applied = try updateTVDyld(
                identifier: identifier, enabled: enabled, system: system, work: work,
                cacheDirectory: URL(fileURLWithPath: dsc), cacheRelative: cacheRelative,
                priorApplied: priorGuest.contains(identifier),
            )
            if applied { live.insert(identifier) }
        }

        // 1. The redeploy first, so no later patch failure can block it. vphoned
        //    and the environment are boot-essential (always on). The environment
        //    keeps its old narrow rule under `environmentOnly`.
        isolate(["system-vphoned-boot-install"]) {
            if on("system-vphoned-boot-install") {
                try installVphoned(guestDevice: guestDevice, system: system, work: work)
                live.insert("system-vphoned-boot-install")
            }
        }
        isolate(["system-launchdaemons-boot-environment"]) {
            if on("system-launchdaemons-boot-environment") {
                try installEnvironment(system: system, work: work, guestDevice: guestDevice,
                                       environmentOnly: environmentOnly)
                live.insert("system-launchdaemons-boot-environment")
            } else if guestDevice.family == .appleTV {
                // Optional on TV, unlike on iOS: take it out again.
                try removeTVEnvironment(system: system)
            }
        }
        // HomePod deliberately excludes the iPhone environment. Inject only the
        // cryptex staging compatibility, directly into its platform executable.
        let staging = FirmwareGuestSystemPatchSet.homePodCryptexStaging
        isolate([staging]) {
            let library = FirmwareGuestSystemPatchSet.homePodCryptexStagingLibrary
            let libraryPath = String(library.dropFirst())
            let executable = "usr/libexec/cryptexd"
            if plan?.isEnabled(staging) == true {
                guard guestDevice.family == .homePod else {
                    throw ValidationError("HomePod cryptex staging requires a HomePod guest.")
                }
                let payload = try VPhoneGuestBinaries.resolve((library as NSString).lastPathComponent)
                try system.replaceFile(libraryPath, fromFileAt: payload, mode: 0o755, owner: Self.guestOwner)
                try patchMachO(system: system, work: work, path: executable,
                               preserveEntitlements: true, injectedDylibPath: library)
                live.insert(staging)
            } else if guestDevice.family == .homePod || priorGuest.contains(staging) {
                if try revertMachO(system: system, work: work, path: executable) {
                    print("  [+] \(staging): restored cryptexd from backup")
                } else if priorGuest.contains(staging) {
                    // Keep the dependency while a patched daemon still needs it.
                    live.insert(staging)
                    throw ValidationError("HomePod cryptex staging has no cryptexd backup; cannot safely remove its library.")
                }
                try system.removeItem(libraryPath)
            }
        }
        // Geometry and its SoundBoard-only identity shim belong to one patch:
        // the daemon still exchanges every LED frame through the native HID.
        let topCap = FirmwareGuestSystemPatchSet.homePodTopCap
        let topCapPath = String(FirmwareGuestSystemPatchSet.homePodDisplayPath.dropFirst())
        if plan?.isEnabled(topCap) == true {
            guard guestDevice.family == .homePod, let homePodDisplay else {
                throw ValidationError("Selected HomePod top-cap emulation has no validated donor display geometry.")
            }
            _ = try system.directory("usr/share/vphone", create: true, mode: 0o755)
            try system.writeFile(topCapPath, contents: homePodDisplay, mode: 0o644, owner: Self.guestOwner)
            try updateHomePodSoundBoard(system: system, work: work, enabled: true)
            live.insert(topCap)
        } else {
            if guestDevice.family == .homePod || priorGuest.contains(topCap) {
                try updateHomePodSoundBoard(system: system, work: work, enabled: false)
            }
            try system.removeItem(topCapPath)
        }
        // Data is encrypted on the host. The mobile boot helper applies this
        // marker through the donor's preferences/sentinel APIs, or restores its
        // key-level journal when the marker is absent. Its runtime is staged
        // with vphoned even when off, so deselection has a path back on boot.
        let setup = FirmwareGuestSystemPatchSet.homePodSetupBypass
        let setupPath = String(FirmwareGuestSystemPatchSet.homePodSetupPath.dropFirst())
        if guestDevice.family == .homePod {
            try installHomePodSetupRuntime(system: system, work: work)
        }
        if plan?.isEnabled(setup) == true {
            guard guestDevice.family == .homePod else {
                throw ValidationError("HomePod setup completion requires a HomePod guest.")
            }
            _ = try system.directory("usr/share/vphone", create: true, mode: 0o755)
            let policy = try PropertyListSerialization.data(fromPropertyList: ["Enabled": true], format: .binary, options: 0)
            try system.writeFile(setupPath, contents: policy, mode: 0o644, owner: Self.guestOwner)
            live.insert(setup)
        } else {
            try system.removeItem(setupPath)
        }
        let homeViewSetup = FirmwareGuestSystemPatchSet.homeViewSetupBypass
        let homeViewSetupPath = String(FirmwareGuestSystemPatchSet.homeViewSetupPath.dropFirst())
        if guestDevice.family == .homeView {
            // Keep the runtime when off so the next boot can restore the saved key.
            try installHomePodSetupRuntime(system: system, work: work, homeView: true)
        }
        if plan?.isEnabled(homeViewSetup) == true {
            guard guestDevice.family == .homeView else {
                throw ValidationError("HomeView setup bypass requires a HomeView guest.")
            }
            _ = try system.directory("usr/share/vphone", create: true, mode: 0o755)
            let policy = try PropertyListSerialization.data(fromPropertyList: ["Enabled": true], format: .binary, options: 0)
            try system.writeFile(homeViewSetupPath, contents: policy, mode: 0o644, owner: Self.guestOwner)
            live.insert(homeViewSetup)
        } else {
            try system.removeItem(homeViewSetupPath)
        }
        // The same helper sets AirPlay's VM override as mobile and restarts the
        // AirPlay daemons when the value changed; removing the marker restores it.
        let airPlay = FirmwareGuestSystemPatchSet.homePodAirPlayVM
        let airPlayPath = String(FirmwareGuestSystemPatchSet.homePodAirPlayVMPath.dropFirst())
        if plan?.isEnabled(airPlay) == true {
            guard guestDevice.family == .homePod else {
                throw ValidationError("HomePod AirPlay on a VM requires a HomePod guest.")
            }
            _ = try system.directory("usr/share/vphone", create: true, mode: 0o755)
            let policy = try PropertyListSerialization.data(fromPropertyList: ["Enabled": true], format: .binary, options: 0)
            try system.writeFile(airPlayPath, contents: policy, mode: 0o644, owner: Self.guestOwner)
            live.insert(airPlay)
        } else {
            try system.removeItem(airPlayPath)
        }
        let speech = FirmwareGuestSystemPatchSet.homePodSiriSpeech
        let speechPath = String(FirmwareGuestSystemPatchSet.homePodSiriSpeechPath.dropFirst())
        if plan?.isEnabled(speech) == true {
            guard guestDevice.family == .homePod else {
                throw ValidationError("HomePod Siri speech requires a HomePod guest.")
            }
            _ = try system.directory("usr/share/vphone", create: true, mode: 0o755)
            let policy = try PropertyListSerialization.data(fromPropertyList: ["Enabled": true], format: .binary, options: 0)
            try system.writeFile(speechPath, contents: policy, mode: 0o644, owner: Self.guestOwner)
            live.insert(speech)
        } else {
            try system.removeItem(speechPath)
        }
        let welcome = FirmwareGuestSystemPatchSet.homePodWelcome
        let welcomePath = String(FirmwareGuestSystemPatchSet.homePodWelcomePath.dropFirst())
        if plan?.isEnabled(welcome) == true {
            guard guestDevice.family == .homePod else {
                throw ValidationError("HomePod welcome requires a HomePod guest.")
            }
            _ = try system.directory("usr/share/vphone", create: true, mode: 0o755)
            let policy = try PropertyListSerialization.data(fromPropertyList: ["Enabled": true], format: .binary, options: 0)
            try system.writeFile(welcomePath, contents: policy, mode: 0o644, owner: Self.guestOwner)
            live.insert(welcome)
        } else {
            // Once-only state belongs to the guest's writable Data volume and
            // survives opt-out, re-enabling and bundle/environment updates.
            try system.removeItem(welcomePath)
        }
        let glow = FirmwareGuestSystemPatchSet.homePodSoundGlow
        let glowPath = String(FirmwareGuestSystemPatchSet.homePodSoundGlowPath.dropFirst())
        if plan?.isEnabled(glow) == true {
            guard guestDevice.family == .homePod else {
                throw ValidationError("HomePod Sound Glow requires a HomePod guest.")
            }
            _ = try system.directory("usr/share/vphone", create: true, mode: 0o755)
            let policy = try PropertyListSerialization.data(fromPropertyList: ["Enabled": true], format: .binary, options: 0)
            try updateHomePodNowPlaying(system: system, work: work, enabled: true)
            try system.writeFile(glowPath, contents: policy, mode: 0o644, owner: Self.guestOwner)
            live.insert(glow)
        } else {
            if guestDevice.family == .homePod || priorGuest.contains(glow) {
                try updateHomePodNowPlaying(system: system, work: work, enabled: false)
            }
            try system.removeItem(glowPath)
        }
        for (identifier, library) in [
            (FirmwareGuestSystemPatchSet.followUpGroups, "libprefsfix.dylib"),
            (FirmwareGuestSystemPatchSet.signInSheets, "libsigninfix.dylib"),
            (FirmwareGuestSystemPatchSet.gyroscope, "libvphonegyro.dylib"),
            (FirmwareGuestSystemPatchSet.accelerometer, "libvphoneaccelerometer.dylib"),
            (FirmwareGuestSystemPatchSet.attitude, "libvphoneattitude.dylib"),
            (FirmwareGuestSystemPatchSet.hinge, "libvphonehinge.dylib"),
            (FirmwareGuestSystemPatchSet.foldGuard, "libvphonefoldguard.dylib"),
            (FirmwareGuestSystemPatchSet.foldDisplay, "libvphonefolddisplay.dylib"),
        ] {
            isolate([identifier]) {
                let path = "usr/lib/" + library
                // The hinge serves a foldable guest's CoreMotion, the guard
                // exists only beside the foldable identity, and the display
                // pad answers the fold layouts' two-display gate; on any other
                // guest they would publish hooks nobody reads or a no-op that
                // is not installed at all.
                let foldOnly = identifier == FirmwareGuestSystemPatchSet.hinge
                    || identifier == FirmwareGuestSystemPatchSet.foldGuard
                    || identifier == FirmwareGuestSystemPatchSet.foldDisplay
                let wanted = on(identifier)
                    && (!foldOnly || Self.isFoldable(guestDevice))
                if wanted {
                    try system.replaceFile(path, fromFileAt: VPhoneGuestBinaries.resolve(library),
                                           mode: 0o755, owner: Self.guestOwner)
                    live.insert(identifier)
                } else {
                    // Removing vphone's added library reverts its injection.
                    try system.removeItem(path)
                }
            }
        }

        // 2. The dyld shared cache. The version branches and the declarations'
        //    applicability say the same thing; this is what a VM with no plan
        //    still follows.
        var dyld: [(id: String, verb: String, args: [String])] = []
        if version.hasPrefix("27.") {
            dyld += [
                (FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap, "patch-arm64e-x1-bootstrap-cache", [dsc]),
                (FirmwareGuestSystemPatchSet.arm64eX1CacheRemaining, "patch-arm64e-x1-cache", [dsc]),
                ("dyld-boot-iomfb_force_kern", "patch-iomfb-force-kern", [dsc]),
                ("dyld-boot-maxslide", "patch-dsc-maxslide", [dsc]),
                ("dyld-boot-lsd_embedded_reg", "patch-lsd-embedded-reg", [dsc]),
                ("dyld-boot-xpc_lwcr", "patch-xpc-lwcr", [dsc]),
                ("dyld-boot-lockdown_mode", "patch-lockdown-mode", [dsc]),
            ]
        } else if version.hasPrefix("26.0") || version.hasPrefix("18.") {
            dyld.append(("dyld-boot-iomfb_swapend", "patch-iomfb-swapend", [dsc, "--target-size", "0x560"]))
        }
        dyld += [
            (FirmwareGuestSystemPatchSet.homeViewEnvironmentService, "patch-homeview-environment", [dsc]),
            (FirmwareGuestSystemPatchSet.settingsSoftwareUpdate, "patch-settings-software-update", [dsc]),
            (FirmwarePatchSetCatalog.misTrustAuthPatch, "patch-mis-trust-auth", [dsc]),
            ("dyld-exp-hv_vmm", "patch-hv-vmm-dsc", [dsc]),
            ("dyld-cfw-camera", "patch-camera-dsc", [dsc, DyldSharedCacheChunkSet.mainCacheURL(in: URL(fileURLWithPath: dsc)).path]),
        ]
        try applyDyldPatches(
            dyld, dsc: dsc, cacheRelative: cacheRelative, system: system, plan: plan, priorGuest: priorGuest,
            live: &live, failures: &failures,
        )
        try requireX1Bootstrap()

        // The feature plist exists from iOS 26. Turning the patch off restores
        // the original.
        let bluetoothID = FirmwareGuestSystemPatchSet.virtualBluetooth
        let bluetoothPath = CustomFirmwareBluetoothVirtualController.relativePath
        isolate([bluetoothID]) {
            if !version.hasPrefix("1"), on(bluetoothID) {
                try patchCopy(
                    of: bluetoothPath, in: system, work: work,
                    verb: "patch-virtual-bluetooth", backupSafe: backupSafe(bluetoothID),
                )
                live.insert(bluetoothID)
            } else if try revertCopy(of: bluetoothPath, in: system) {
                print("  [+] \(bluetoothID): restored the Bluetooth feature flags")
            } else if priorGuest.contains(bluetoothID) {
                print("  [!] \(bluetoothID): no backup to revert (not revertible)")
                live.insert(bluetoothID)
            }
        }

        // A missing legacy plan must not apply this iOS-27-only change to
        // other bases. Turning it off restores the original feature plist.
        let locationdID = FirmwareGuestSystemPatchSet.locationdCohorting
        let locationdPath = CustomFirmwareLocationdCohorting.relativePath
        isolate([locationdID]) {
            if version.hasPrefix("27."), on(locationdID) {
                try patchCopy(
                    of: locationdPath, in: system, work: work,
                    verb: "patch-locationd-cohorting", backupSafe: backupSafe(locationdID),
                )
                live.insert(locationdID)
            } else if try revertCopy(of: locationdPath, in: system) {
                print("  [+] \(locationdID): restored CoreLocation feature flags")
            } else if priorGuest.contains(locationdID) {
                print("  [!] \(locationdID): no backup to revert (not revertible)")
                live.insert(locationdID)
            }
        }

        // The jetsam properties of every board the image serves: launchd
        // reads the one the guest's device tree names. Like the locationd
        // change this is for iOS 27 only, where DisableAllowed first appears.
        let jetsamID = FirmwareGuestSystemPatchSet.jetsamDisableAllowed
        let jetsamDirectory = CustomFirmwareJetsamDisableAllowed.directory
        isolate([jetsamID]) {
            let names = try system.directory(jetsamDirectory).entries().sorted()
            if version.hasPrefix("27."), on(jetsamID) {
                for name in names where CustomFirmwareJetsamDisableAllowed.isJetsamProperties(name) {
                    let path = "\(jetsamDirectory)/\(name)"
                    guard try system.isRegularFile(path) else { continue }
                    try patchCopy(
                        of: path, in: system, work: work,
                        verb: "patch-jetsam-disable-allowed", backupSafe: backupSafe(jetsamID),
                    )
                }
                live.insert(jetsamID)
            } else {
                var reverted = false
                for name in names where name.hasSuffix(".bak") {
                    let original = String(name.dropLast(4))
                    guard CustomFirmwareJetsamDisableAllowed.isJetsamProperties(original) else { continue }
                    if try revertCopy(of: "\(jetsamDirectory)/\(original)", in: system) {
                        reverted = true
                    }
                }
                if reverted {
                    print("  [+] \(jetsamID): restored the jetsam properties")
                } else if priorGuest.contains(jetsamID) {
                    print("  [!] \(jetsamID): no backup to revert (not revertible)")
                    live.insert(jetsamID)
                }
            }
        }

        // 3. The build-version spoof. Off by default (needs a preset parameter
        //    or SPOOF_BUILD). Backed up only when it was not already applied.
        let buildVersion = plan?.parameters[FirmwareGuestSystemPatchSet.buildVersionParameter] ?? spoofBuild
        let buildID = "system-systemversion-cfw-build_version"
        let buildPaths = [
            "System/Library/CoreServices/SystemVersion.plist",
            "System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist",
        ]
        isolate([buildID]) {
            if let build = buildVersion, !build.isEmpty, on(buildID) {
                var applied = false
                for path in buildPaths where try system.isRegularFile(path) {
                    try patchCopy(of: path, in: system, work: work, verb: "patch-build-version", arguments: [build], backupSafe: backupSafe(buildID))
                    applied = true
                }
                if applied {
                    live.insert(buildID)
                }
            } else if !on(buildID) {
                var reverted = false
                for path in buildPaths where try revertCopy(of: path, in: system) {
                    reverted = true
                }
                if !reverted, priorGuest.contains(buildID) {
                    print("  [!] \(buildID): off now but no backup to revert (not revertible)")
                    live.insert(buildID)
                }
            }
        }

        machO("system-seputil-boot-gigalocker_uuid", path: "usr/libexec/seputil", verbs: ["patch-seputil"], codeIdentifier: "com.apple.seputil")
        machO(
            FirmwareGuestSystemPatchSet.settingsRootRows,
            path: "Applications/Preferences.app/Preferences",
            verbs: ["patch-settings-root-rows"],
            codeIdentifier: "com.apple.Preferences",
            preserveEntitlements: true,
        )

        if version.hasPrefix("27.") {
            machO("system-diskimagesiod-cfw-is_mount_complete", path: "usr/libexec/diskimagesiod", verbs: ["patch-diskimagesiod"], preserveEntitlements: true)
        }

        // The gigalocker rename pairs with seputil, a boot-essential first-install
        // step on the xART volume only a full install mounts. On an installed
        // guest it is already renamed, so record it live when on and leave it.
        if on("system-gigalocker-boot-rename") {
            isolate(["system-gigalocker-boot-rename"]) {
                if let xart {
                    try renameGigalocker(xart: xart)
                } else {
                    print("  [·] system-gigalocker-boot-rename: xART not mounted; left as installed")
                }
                live.insert("system-gigalocker-boot-rename")
            }
        }

        // The paravirtual GPU bundle comes from the restore tree, so an
        // environment update cannot (re)install it; an installed guest already
        // carries it, so record it live when on and skip with a note.
        var gpuBundleReinstalled = false
        if on("system-extensions-boot-gpu_bundle") {
            isolate(["system-extensions-boot-gpu_bundle"]) {
                if let restore {
                    try installGPUBundle(restore: restore, system: system, owner: owner)
                    if guestDevice.usesTVOS {
                        try retargetGPUBundleToTVOS(system: system, work: work)
                    }
                    gpuBundleReinstalled = true
                } else {
                    print("  [·] system-extensions-boot-gpu_bundle: no restore tree; GPU bundle left as installed")
                }
                live.insert("system-extensions-boot-gpu_bundle")
            }
        }

        // The driver's compact indexed-draw commands truncate a heap index
        // buffer's offset to 16 bits. After the bundle step on purpose:
        // `installGPUBundle` replaces the whole bundle, `.bak` included, so the
        // backup taken here is always the staged driver — and a bundle it just
        // reinstalled is already pristine, which is what "off" means.
        let gpuIndexOffset = FirmwareGuestSystemPatchSet.paravirtGPUIndexOffset
        let gpuDriver = FirmwareGuestSystemPatchSet.paravirtGPUDriverPath
        let gpuBundle = "System/Library/Extensions/\(VPhonePCCGPUDriver.name)"
        isolate([gpuIndexOffset]) {
            if on(gpuIndexOffset) {
                try patchMachO(
                    system: system, work: work, path: gpuDriver,
                    verbs: ["patch-paravirt-gpu-index-offset"],
                    identifier: "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily",
                )
                try sealGuestBundle(system: system, bundle: gpuBundle)
                live.insert(gpuIndexOffset)
            } else if try revertMachO(system: system, work: work, path: gpuDriver, bundle: gpuBundle) {
                print("  [+] \(gpuIndexOffset): restored \(gpuDriver) from backup")
            } else if priorGuest.contains(gpuIndexOffset), !gpuBundleReinstalled {
                print("  [!] \(gpuIndexOffset): off now but no backup to revert; leaving the patched driver (not revertible)")
                live.insert(gpuIndexOffset)
            }
        }

        machO("system-launchd_cache_loader-boot-unsecure_cache_gate", path: "usr/libexec/launchd_cache_loader", verbs: ["patch-launchd-cache-loader"], codeIdentifier: "com.apple.launchd_cache_loader")
        // The TV declaration has its own 27.2 gate and preset selection; the
        // implementation and reversible backup are shared with iPhone.
        let activation = guestDevice.family == .appleTV
            ? FirmwareGuestSystemPatchSet.tvLocalActivation : "system-mobileactivationd-boot-should_hactivate"
        machO(activation, path: "usr/libexec/mobileactivationd", verbs: ["patch-mobileactivationd"])

        isolate(["system-watchdogd-exp-hv_vmm_cache"]) {
            if on("system-watchdogd-exp-hv_vmm_cache") {
                try patchWatchdog(system: system, work: work)
                live.insert("system-watchdogd-exp-hv_vmm_cache")
            } else if try revertMachO(system: system, work: work, path: "usr/libexec/watchdogd") {
                print("  [+] system-watchdogd-exp-hv_vmm_cache: restored watchdogd from backup")
            } else if priorGuest.contains("system-watchdogd-exp-hv_vmm_cache") {
                print("  [!] system-watchdogd-exp-hv_vmm_cache: off now but no backup to revert (not revertible)")
                live.insert("system-watchdogd-exp-hv_vmm_cache")
            }
        }

        if on(FirmwareGuestSystemPatchSet.virtioSoundDriver) {
            isolate([FirmwareGuestSystemPatchSet.virtioSoundDriver]) {
                try installVirtioSoundDriver(system: system, work: work, guestDevice: guestDevice)
                live.insert(FirmwareGuestSystemPatchSet.virtioSoundDriver)
            }
        } else {
            isolate([FirmwareGuestSystemPatchSet.virtioSoundDriver]) {
                if try revertVirtioSoundDriver(system: system) {
                    print("  [+] \(FirmwareGuestSystemPatchSet.virtioSoundDriver): removed the virtio sound driver")
                }
            }
        }

        // The VirtualAudio HAL plugin: five sub-patches ride one staged copy
        // (`patchMachO` stages from the pristine backup, so two calls would not
        // compose). On when any is on; reverted from `.bak` when all are off.
        // The device-state early publish reports "nothing to do" on the non-X1
        // plugins, so sharing the stage costs them nothing.
        let virtualAudio: [(id: String, verb: String)] = [
            (FirmwareGuestSystemPatchSet.virtualAudioSpeakerRouteThrows, "patch-virtualaudio"),
            (FirmwareGuestSystemPatchSet.virtualAudioMuteSetThrow, "patch-virtualaudio-mute"),
            (FirmwareGuestSystemPatchSet.virtualAudioSpeakerProtectionGate, "patch-virtualaudio-sp-gate"),
            (FirmwareGuestSystemPatchSet.virtualAudioVolumeModePrecondition, "patch-virtualaudio-volume-gate"),
            (FirmwareGuestSystemPatchSet.virtualAudioDeviceStateNullGate, "patch-virtualaudio-device-state-null-gate"),
        ]
        let virtualAudioBundle = "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin"
        let virtualAudioBinary = "\(virtualAudioBundle)/VirtualAudio"
        let virtualAudioOn = virtualAudio.filter { on($0.id) }
        isolate(virtualAudio.map(\.id)) {
            if !virtualAudioOn.isEmpty {
                guard try system.isRegularFile(virtualAudioBinary) else {
                    print("  [·] VirtualAudio: not on this VM, left out")
                    return
                }
                try patchMachO(
                    system: system, work: work, path: virtualAudioBinary,
                    verbs: virtualAudioOn.map(\.verb), preserveEntitlements: true,
                )
                try sealGuestBundle(system: system, bundle: virtualAudioBundle)
                for patch in virtualAudioOn {
                    live.insert(patch.id)
                }
            } else if try revertMachO(system: system, work: work, path: virtualAudioBinary, bundle: virtualAudioBundle) {
                print("  [+] VirtualAudio restored from backup (all speaker/mute patches off)")
            } else {
                for patch in virtualAudio where priorGuest.contains(patch.id) {
                    print("  [!] \(patch.id): off now but no VirtualAudio backup to revert (not revertible)")
                    live.insert(patch.id)
                }
            }
        }

        // The three VirtualAudio tuning patches share one
        // `graph_configurations.plist`, so there is no per-edit inverse. Restore
        // the tuning files to pristine from their backups, then re-apply
        // whichever of the three are on — which lands exactly the enabled set.
        // Backed up only when none of the three was live before.
        let graphGroup: [(id: String, verb: String)] = [
            (FirmwareGuestSystemPatchSet.virtualAudioGraphConfigurations, "patch-virtualaudio-graph-configurations"),
            (FirmwareGuestSystemPatchSet.virtualAudioSpeakerRawChains, "patch-virtualaudio-speaker-raw"),
            (FirmwareGuestSystemPatchSet.virtualAudioMicrophoneChains, "patch-virtualaudio-microphone-chains"),
        ]
        let graphOn = graphGroup.filter { on($0.id) }
        let graphBackupSafe = backupSafe(graphGroup[0].id, graphGroup[1].id, graphGroup[2].id)
        isolate(graphGroup.map(\.id)) {
            let hadGraphBackup = try restoreVirtualAudioTunings(system: system)
            if !graphOn.isEmpty {
                for entry in graphOn {
                    let patched = try patchVirtualAudioGraphConfigurations(
                        system: system, work: work, verb: entry.verb, backupSafe: graphBackupSafe,
                    )
                    if patched {
                        live.insert(entry.id)
                    }
                }
            } else if !hadGraphBackup {
                for entry in graphGroup where priorGuest.contains(entry.id) {
                    print("  [!] \(entry.id): off now but no tuning-plist backup to revert (not revertible)")
                    live.insert(entry.id)
                }
            }
        }

        let launchdJetsam = "system-launchd-boot-jetsam_panic_guard_bypass"
        let launchdX1 = FirmwareGuestSystemPatchSet.arm64eX1LaunchdBootstrap
        let personaPatch = FirmwareGuestSystemPatchSet.installCoordinationPersona
        let personaMarker = String(FirmwareGuestSystemPatchSet.installCoordinationPersonaMarker.dropFirst())
        let isHomePod = guestDevice.family == .homePod
        isolate([launchdJetsam, launchdX1] + (isHomePod ? [personaPatch] : [])) {
            if isHomePod {
                let library = FirmwareGuestSystemPatchSet.homePodInstallPersonaLibrary
                let path = String(library.dropFirst())
                if on(personaPatch) {
                    let payload = try VPhoneGuestBinaries.resolve((library as NSString).lastPathComponent)
                    try system.replaceFile(path, fromFileAt: payload, mode: 0o755, owner: Self.guestOwner)
                    // launchd needs a short load command; this alias is owned
                    // only by HomePod's isolated installation compatibility.
                    try installLibraryAlias(system: system, alias: "vp", target: library)
                    try patchMachO(system: system, work: work, path: "sbin/launchd",
                                   preserveEntitlements: true, injectedDylibPath: "/vp")
                    try system.writeFile(personaMarker, contents: Data("1\n".utf8), mode: 0o644, owner: Self.guestOwner)
                    live.insert(personaPatch)
                    print("  [+] \(personaPatch): installed scoped HomePod UserManager adapter")
                } else {
                    if try revertMachO(system: system, work: work, path: "sbin/launchd") {
                        print("  [+] \(personaPatch): restored HomePod launchd from backup")
                    } else if priorGuest.contains(personaPatch) {
                        live.insert(personaPatch)
                        throw ValidationError("HomePod persona compatibility has no launchd backup; cannot safely remove its library.")
                    }
                    try system.removeItem(personaMarker)
                    if try system.exists("vp") {
                        guard try system.readLink("vp") == library else {
                            throw ValidationError("Another file uses /vp; leaving it intact.")
                        }
                        try system.removeItem("vp")
                    }
                    try system.removeItem(path)
                }
                return
            }
            let enabled = [launchdJetsam, launchdX1].filter(on)
            if !enabled.isEmpty {
                var verbs: [String] = []
                if enabled.contains(launchdJetsam) { verbs.append("patch-launchd-jetsam") }
                if enabled.contains(launchdX1) { verbs.append("patch-arm64e-x1") }
                try patchMachO(
                    system: system,
                    work: work,
                    path: "sbin/launchd",
                    verbs: verbs,
                    preserveEntitlements: true,
                    injectedDylibPath: "/vh",
                )
                live.formUnion(enabled)
            } else if try revertMachO(system: system, work: work, path: "sbin/launchd") {
                print("  [+] launchd patches: restored sbin/launchd from backup")
            } else {
                for identifier in [launchdJetsam, launchdX1] where priorGuest.contains(identifier) {
                    print("  [!] \(identifier): off now but no backup to revert; leaving launchd patched (not revertible)")
                    live.insert(identifier)
                }
            }
        }

        try requireX1Bootstrap()
        if !isHomePod {
            isolate([]) { try restoreMISFixTargets(system: system) }
        }

        // HomePod has no misagent/provisioning service. Its research SDK signs
        // apps ad hoc; load only the existing MIS signature-option adapter in
        // installd, without iPhone identity, profile or spawn hooks.
        let adHocInstall = FirmwareGuestSystemPatchSet.homePodAdHocInstall
        isolate([adHocInstall]) {
            let library = FirmwareGuestSystemPatchSet.homePodMISFixLibrary
            let path = String(library.dropFirst())
            let executable = "usr/libexec/installd"
            if on(adHocInstall) {
                guard isHomePod else {
                    throw ValidationError("HomePod ad-hoc installation requires a HomePod guest.")
                }
                let payload = try VPhoneGuestBinaries.resolve((library as NSString).lastPathComponent)
                try system.replaceFile(path, fromFileAt: payload, mode: 0o755, owner: Self.guestOwner)
                try installLibraryAlias(system: system, alias: "hm", target: library)
                try patchMachO(system: system, work: work, path: executable,
                               preserveEntitlements: true, injectedDylibPath: "/hm")
                live.insert(adHocInstall)
            } else if isHomePod || priorGuest.contains(adHocInstall) {
                if try revertMachO(system: system, work: work, path: executable) {
                    print("  [+] \(adHocInstall): restored installd from backup")
                } else if priorGuest.contains(adHocInstall) {
                    live.insert(adHocInstall)
                    throw ValidationError("HomePod ad-hoc installation has no installd backup; cannot safely remove its library.")
                }
                if try system.exists("hm") {
                    guard try system.readLink("hm") == library else {
                        throw ValidationError("Another file uses /hm; leaving it intact.")
                    }
                    try system.removeItem("hm")
                }
                try system.removeItem(path)
            }
        }

        isolate(["system-debugserver-cfw-install"]) {
            if on("system-debugserver-cfw-install") {
                if try patchDebugserver(system: system, work: work, backupSafe: backupSafe("system-debugserver-cfw-install")) {
                    live.insert("system-debugserver-cfw-install")
                }
            } else if try revertMachO(system: system, work: work, path: "usr/libexec/debugserver") {
                print("  [+] system-debugserver-cfw-install: restored debugserver from backup")
            } else if priorGuest.contains("system-debugserver-cfw-install") {
                print("  [!] system-debugserver-cfw-install: off now but no backup to revert (not revertible)")
                live.insert("system-debugserver-cfw-install")
            }
        }

        if version.hasPrefix("27.") {
            isolate(["system-campo-cfw-entitlements"]) {
                if on("system-campo-cfw-entitlements") {
                    if try patchCampo(system: system, work: work, backupSafe: backupSafe("system-campo-cfw-entitlements")) {
                        live.insert("system-campo-cfw-entitlements")
                    }
                } else if try revertMachO(system: system, work: work, path: "Applications/Campo.app/Campo") {
                    print("  [+] system-campo-cfw-entitlements: restored Campo from backup")
                } else if priorGuest.contains("system-campo-cfw-entitlements") {
                    print("  [!] system-campo-cfw-entitlements: off now but no backup to revert (not revertible)")
                    live.insert("system-campo-cfw-entitlements")
                }
            }
        }

        let homeViewDisplay = FirmwareGuestSystemPatchSet.homeViewDisplayLookups
        isolate([homeViewDisplay]) {
            let bundle = "System/Library/CoreServices/BreadBoard.app"
            let executable = "\(bundle)/BreadBoard"
            if on(homeViewDisplay), guestDevice.family == .homeView {
                try patchHomeViewMachLookups(system: system, work: work, target: executable,
                    services: CustomFirmwareMachLookupExceptions.homeViewServices, backupSafe: backupSafe(homeViewDisplay))
                try sealGuestBundle(system: system, bundle: bundle, preserveEntitlements: true)
                live.insert(homeViewDisplay)
            } else if priorGuest.contains(homeViewDisplay) {
                guard try revertMachO(system: system, work: work, path: executable, bundle: bundle, preserveEntitlements: true) else {
                    live.insert(homeViewDisplay)
                    throw ValidationError("BreadBoard has no executable backup; cannot restore its original entitlements.")
                }
                print("  [+] \(homeViewDisplay): restored BreadBoard from backup")
            }
        }

        let homeViewProfile = FirmwareGuestSystemPatchSet.homeViewProfileLookup
        isolate([homeViewProfile]) {
            let executable = "System/Library/PrivateFrameworks/UserProfilesDaemon.framework/Support/userprofilesd"
            if on(homeViewProfile), guestDevice.family == .homeView {
                try patchHomeViewMachLookups(system: system, work: work, target: executable,
                    services: ["com.apple.mobile.keybagd.UserManager.xpc"], backupSafe: backupSafe(homeViewProfile))
                live.insert(homeViewProfile)
            } else if priorGuest.contains(homeViewProfile) {
                guard try revertMachO(system: system, work: work, path: executable) else {
                    live.insert(homeViewProfile)
                    throw ValidationError("userprofilesd has no executable backup; cannot restore its original entitlements.")
                }
                print("  [+] \(homeViewProfile): restored userprofilesd from backup")
            }
        }

        let tvLegacySetup = FirmwareGuestSystemPatchSet.tvLegacySetup
        let tvSetupFlags = CustomFirmwareTVSetup.relativePath
        isolate([tvLegacySetup]) {
            if (version == "27.2" || version.hasPrefix("27.2.")), on(tvLegacySetup), guestDevice.family == .appleTV {
                try patchCopy(
                    of: tvSetupFlags, in: system, work: work,
                    verb: "patch-tv-setup", backupSafe: backupSafe(tvLegacySetup),
                )
                live.insert(tvLegacySetup)
            } else if try revertCopy(of: tvSetupFlags, in: system) {
                print("  [+] \(tvLegacySetup): restored CompanionServices feature flags")
            } else if priorGuest.contains(tvLegacySetup) {
                print("  [!] \(tvLegacySetup): no backup to revert (not revertible)")
                live.insert(tvLegacySetup)
            }
        }

        let tvSetupFocus = FirmwareGuestSystemPatchSet.tvSetupFocus
        isolate([tvSetupFocus]) {
            let executable = "Applications/Setup.app/Setup"
            let library = FirmwareGuestSystemPatchSet.tvSetupFocusLibrary
            let path = String(library.dropFirst())
            if on(tvSetupFocus), guestDevice.family == .appleTV,
               version == "27.2" || version.hasPrefix("27.2.") {
                let payload = try VPhoneGuestBinaries.resolve((library as NSString).lastPathComponent)
                try system.replaceFile(path, fromFileAt: payload, mode: 0o755, owner: Self.guestOwner)
                try installLibraryAlias(system: system, alias: "tf", target: library)
                try patchMachO(system: system, work: work, path: executable,
                               preserveEntitlements: true, injectedDylibPath: "/tf")
                try sealGuestBundle(system: system, bundle: "Applications/Setup.app", preserveEntitlements: true)
                live.insert(tvSetupFocus)
            } else {
                if try revertMachO(system: system, work: work, path: executable, bundle: "Applications/Setup.app", preserveEntitlements: true) {
                    print("  [+] \(tvSetupFocus): restored Setup from backup")
                } else if priorGuest.contains(tvSetupFocus) {
                    live.insert(tvSetupFocus)
                    throw ValidationError("TV setup focus adapter has no Setup backup; cannot safely remove its library.")
                }
                if try system.exists("tf") {
                    guard try system.readLink("tf") == library else {
                        throw ValidationError("Another file uses /tf; leaving it intact.")
                    }
                    try system.removeItem("tf")
                }
                try system.removeItem(path)
            }
        }

        let tvSetupLookup = FirmwareGuestSystemPatchSet.tvSetupDisplayLookup
        let tvSetupBackground = "Applications/SetupBackground.app/SetupBackground"
        isolate([tvSetupLookup]) {
            if on(tvSetupLookup), guestDevice.family == .appleTV {
                if try patchTVSetupDisplayLookup(system: system, work: work, backupSafe: backupSafe(tvSetupLookup)) {
                    live.insert(tvSetupLookup)
                }
            } else if try revertMachO(system: system, work: work, path: tvSetupBackground) {
                print("  [+] \(tvSetupLookup): restored SetupBackground from backup")
            } else if priorGuest.contains(tvSetupLookup) {
                print("  [!] \(tvSetupLookup): off now but no backup to revert (not revertible)")
                live.insert(tvSetupLookup)
            }
        }

        if !isHomePod { isolate([personaPatch]) {
            // Undo the experimental entitlement-only patch if this machine
            // received it. Platform Protobox profiles ignore that exception.
            let proxy = "System/Library/PrivateFrameworks/InstallCoordination.framework/Support/installcoordination_proxy"
            if priorGuest.contains(personaPatch), try revertMachO(system: system, work: work, path: proxy) {
                print("  [+] \(personaPatch): restored proxy before enabling launchd compatibility")
            }
            if version.hasPrefix("27."), on(personaPatch) {
                try system.writeFile(personaMarker, contents: Data("1\n".utf8), mode: 0o644, owner: Self.guestOwner)
                live.insert(personaPatch)
                print("  [+] \(personaPatch): enabled scoped UserManager lookup")
            } else {
                try system.removeItem(personaMarker)
            }
        } }

        // SystemHook sets FS_CACHE_REUSE_ON_REBOOT while this marker exists.
        let metalCachePatch = FirmwareGuestSystemPatchSet.metalCacheReuse
        let metalCacheMarker = String(FirmwareGuestSystemPatchSet.metalCacheReuseMarker.dropFirst())
        isolate([metalCachePatch]) {
            if on(metalCachePatch) {
                try system.writeFile(metalCacheMarker, contents: Data("1\n".utf8), mode: 0o644, owner: Self.guestOwner)
                live.insert(metalCachePatch)
            } else {
                try system.removeItem(metalCacheMarker)
            }
        }

        if !failures.isEmpty {
            print("[!] \(failures.count) guest patch(es) failed and were left in their prior state: \(Set(failures).sorted().joined(separator: ", "))")
            if strict {
                throw ValidationError("OTA compatibility patches failed; the private disk clone was discarded: \(Set(failures).sorted().joined(separator: ", "))")
            }
        }
        return live
    }

    /// A guest whose board has an Apple VM sub-type for its fold pose.
    static func isFoldable(_ device: VPhoneGuestDevice) -> Bool {
        CustomFirmwarePostRestoreDeviceTree.foldableVMSubtypes.keys.contains(device.deviceClass.uppercased())
    }

    /// Idempotent dyld patches whose receipts cannot identify stale implementations.
    private static let dyldPatchesRerunWhenLive: Set<String> = [
        "dyld-boot-maxslide",
        FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap,
    ]

    /// Apply the enabled dyld cache patches whose state differs from what was
    /// live before, and revert the disabled ones from the undo log the earlier
    /// install wrote. A patch already in the prior-live set is left alone — no
    /// multi-gigabyte scan when nothing changed. A disabled patch with no undo
    /// record was either never applied (nothing to do) or applied before the
    /// undo log existed; the latter is told apart by the prior-live set and
    /// reported as not revertible, staying live. The selected X1 bootstrap
    /// patch must succeed; optional cache patches still run in isolation.
    private func applyDyldPatches(
        _ dyld: [(id: String, verb: String, args: [String])],
        dsc: String,
        cacheRelative: String,
        system: VPhoneConfinedDirectory,
        plan: VPhoneVirtualMachinePatchPlan?,
        priorGuest: Set<String>,
        live: inout Set<String>,
        failures: inout [String],
    ) throws {
        func enabled(_ id: String) -> Bool {
            if id == FirmwareGuestSystemPatchSet.homeViewEnvironmentService { return plan?.isEnabled(id) == true }
            return plan?.isEnabled(id) ?? !FirmwareGuestSystemPatchSet.settingsRowPatches.contains(id)
        }
        func requireBootstrap(_ id: String, error: any Error) throws {
            if id == FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap {
                throw ValidationError("Required X1 boot patch \(id) failed; installation stopped before setup boot: \(error)")
            }
        }
        let undoAbsolute = (dsc as NSString).appendingPathComponent(Self.dscUndoLogLeaf)
        let undoRelative = "\(cacheRelative)/\(Self.dscUndoLogLeaf)"
        let undoLog = (try? system.readData(undoRelative)).flatMap { try? DyldSharedCacheUndoLog.decode($0) }
        let recorded = undoLog?.patchIDs ?? []

        var revertable: [String] = []
        for entry in dyld {
            let want = enabled(entry.id)
            let had = priorGuest.contains(entry.id)
            switch (want, had) {
            case (true, true):
                // Already applied; leave it, no scan — unless the bytes on disk
                // are an earlier implementation of the same identifier. Then put
                // the originals back and apply the current one, in this run.
                if Self.dyldPatchesRerunWhenLive.contains(entry.id) {
                    do {
                        try patch(entry.verb, entry.args + ["--undo-log", undoAbsolute, "--undo-id", entry.id])
                    } catch {
                        failures.append(entry.id)
                        print("  [!] \(entry.id): re-running the applied patch failed, left as it was: \(error)")
                        try requireBootstrap(entry.id, error: error)
                    }
                } else if let undoLog, undoLog.hasOutdatedImplementation(of: entry.id) {
                    print("  [*] \(entry.id): an earlier implementation is applied; reverting it and applying the current one")
                    do {
                        try patch("patch-dsc-revert", [dsc, "--undo-log", undoAbsolute, "--patch", entry.id])
                    } catch {
                        failures.append(entry.id)
                        live.insert(entry.id)
                        print("  [!] \(entry.id): reverting the earlier implementation failed, left as it was: \(error)")
                        try requireBootstrap(entry.id, error: error)
                        continue
                    }
                    do {
                        try patch(entry.verb, entry.args + ["--undo-log", undoAbsolute, "--undo-id", entry.id])
                    } catch {
                        failures.append(entry.id)
                        print("  [!] \(entry.id): the earlier implementation was reverted but the current one failed; the cache is unpatched for it: \(error)")
                        try requireBootstrap(entry.id, error: error)
                        continue
                    }
                }
                live.insert(entry.id)
            case (true, false):
                do {
                    try patch(entry.verb, entry.args + ["--undo-log", undoAbsolute, "--undo-id", entry.id])
                    live.insert(entry.id)
                } catch {
                    failures.append(entry.id)
                    print("  [!] \(entry.id): dyld patch failed, left in its prior state: \(error)")
                    try requireBootstrap(entry.id, error: error)
                }
            case (false, true):
                if recorded.contains(entry.id) {
                    revertable.append(entry.id)
                } else {
                    print("  [!] \(entry.id): off now but the dyld undo log has no record (patched before the undo log existed); not revertible")
                    live.insert(entry.id)
                }
            case (false, false):
                break
            }
        }
        if !revertable.isEmpty {
            do {
                try patch("patch-dsc-revert", [dsc, "--undo-log", undoAbsolute] + revertable.flatMap { ["--patch", $0] })
            } catch {
                failures.append(contentsOf: revertable)
                print("  [!] dyld revert failed, left in prior state: \(error)")
                for id in revertable {
                    live.insert(id)
                }
            }
        }
    }

    /// Restore a guest Mach-O from its `.bak`, re-sealing the bundle it lives in
    /// when one is given. Returns false when there is no backup — a binary
    /// patched before backups were kept.
    @discardableResult
    private func revertMachO(
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        path: String,
        bundle: String? = nil,
        preserveEntitlements: Bool = false,
    ) throws -> Bool {
        let backup = "\(path).bak"
        guard try system.exists(backup) else { return false }
        let name = (path as NSString).lastPathComponent
        try work.directory.removeItem(name)
        try system.copyFile(from: backup, to: name, in: work.directory)
        try system.replaceFile(path, fromFileAt: work.file(name), mode: 0o755, owner: Self.guestOwner)
        try system.removeItem(backup)
        if let bundle {
            try sealGuestBundle(system: system, bundle: bundle, preserveEntitlements: preserveEntitlements)
        }
        return true
    }

    /// Remove the virtio sound driver bundle. iOS ships no plugin for its
    /// kernel driver, so the pristine state is the bundle's absence — there is
    /// no backup to restore, the revert is the removal. Returns whether it was
    /// there to remove.
    @discardableResult
    private func revertVirtioSoundDriver(system: VPhoneConfinedDirectory) throws -> Bool {
        let target = "System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver"
        guard try system.exists(target) else { return false }
        try system.removeItem(target)
        return true
    }

    /// `plan`, with its guest-patch half re-resolved from the VM's current
    /// selection — both directions. The boot-chain patches stay exactly as the
    /// plan recorded them (they were built into the restore tree and the
    /// originals when `fw patch` ran, and this run cannot change them); every
    /// guest-target patch is replaced by what the preset and the VM's own block
    /// and allow choices select today. So a guest patch the owner has since
    /// turned off drops out of the plan the guest half reads, and one they have
    /// turned on comes in — which is what makes `fw set-patches` reach an
    /// installed VM at the next `cfw install` or `cfw update-environment`.
    ///
    /// A preset that cannot be resolved from the bundled sets — one naming an
    /// external `.vphonepatchset` — leaves the plan as it is: root loads no
    /// external set, so it cannot re-resolve such a selection and must not guess.
    /// A VM with no plan at all stays nil (every guest patch applies, which is
    /// what it was restored with).
    private func resolveGuestSelection(
        _ plan: VPhoneVirtualMachinePatchPlan?,
        in bundleDirectory: VPhoneConfinedDirectory,
    ) -> VPhoneVirtualMachinePatchPlan? {
        guard var plan else { return nil }
        let selection = (try? bundleDirectory.readData(VPhonePatchPresetStore.selectionFileName))
            .flatMap { try? PropertyListDecoder().decode(VPhoneVirtualMachinePatchSelection.self, from: $0) }
            ?? VPhoneVirtualMachinePatchSelection()
        guard
            let preset = VPhonePatchPresetStore.preset(
                named: plan.presetIdentifier,
                vmCopy: try? bundleDirectory.readData(VPhonePatchPresetStore.vmPresetFileName),
            ),
            let resolved = try? VPhonePatchPlan.resolve(
                preset: preset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(plan.iOSBaseVersion),
                cloudOS: VPhoneVersion(plan.cloudOSVersion),
                blocked: Set(selection.blockedPatches),
                allowed: Set(selection.allowedPatches),
            )
        else {
            print("[!] Preset \(plan.presetIdentifier) does not resolve from bundled sets; applying the plan as recorded")
            return plan
        }
        let planEnabled = Set(plan.enabledPatches)
        let effective = FirmwareGuestPatchResolution.effectiveEnabled(
            planEnabled: planEnabled,
            selectionEnabled: resolved.enabled,
        )
        for added in effective.subtracting(planEnabled).sorted() {
            print("[*] \(added): on in the current selection, newer than this VM's patch plan")
        }
        for dropped in planEnabled.subtracting(effective).sorted() {
            print("[*] \(dropped): off in the current selection; the guest half will revert it")
        }
        plan.enabledPatches = effective.sorted()
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
    private func verifiedDyldCacheDirectory(system: VPhoneConfinedDirectory, relative: String) throws -> String {
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
        replaceExisting: Bool = false,
    ) throws {
        let os = "System/Cryptexes/OS"
        let app = "System/Cryptexes/App"
        func populated(_ path: String) -> Bool {
            (try? system.directory(path).entries().isEmpty) == false
        }
        if replaceExisting || !(populated(os) && populated(app)) {
            let manifest = work.file("iPhone-BuildManifest.plist")
            try restore.readData("iPhone-BuildManifest.plist").write(to: manifest)
            guard case let .cryptex(paths) = try CustomFirmwareDaemons.filesystemLayout(buildManifest: manifest) else {
                print("[*] Monolithic tvOS system image: no cryptex files to install")
                return
            }
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

    /// Full OTA chunks contain placeholders, not the removable apps retained
    /// on encrypted Data. Stage target programs from the pinned IPSW's OS
    /// image; vphoned reconciles only already-installed Apple apps after boot.
    private func stageOTASystemApps(
        restore: VPhoneConfinedDirectory, system: VPhoneConfinedDirectory,
        work: WorkDirectory, owner: uid_t?
    ) throws {
        guard let manifest = try PropertyListSerialization.propertyList(
            from: restore.readData("iPhone-BuildManifest.plist"), format: nil) as? [String: Any],
              let identities = manifest["BuildIdentities"] as? [[String: Any]] else {
            throw ValidationError("OTA target OS manifest is invalid.")
        }
        let updatePaths = identities.compactMap { identity -> String? in
            guard (identity["Info"] as? [String: Any])?["RestoreBehavior"] as? String == "Update" else { return nil }
            let os = (identity["Manifest"] as? [String: Any])?["OS"] as? [String: Any]
            return (os?["Info"] as? [String: Any])?["Path"] as? String
        }
        let paths = Set(updatePaths)
        guard paths.count == 1, let path = paths.first else {
            throw ValidationError("OTA target has no unique OS image for system-app migration.")
        }
        let image = try stageCryptexImage(path, from: restore, as: "OTA-OS-source.dmg", work: work, owner: owner)
        var plain = image
        if try VPhoneRestoreOperations.isAEAEncrypted(image) {
            plain = work.file("OTA-OS.dmg")
            let key = try vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: image) }
            try tool("/usr/bin/aea", ["decrypt", "-i", image.path, "-o", plain.path, "-key-value", key], quiet: true)
        }
        let mount = work.file("mnt-ota-apps")
        _ = try work.directory.directory("mnt-ota-apps", create: true, mode: 0o700)
        try attachCryptex(plain, at: mount)
        var attached = true
        defer { if attached { try? detachImage(at: mount) } }
        // Scoped so the volume's directory descriptors close before detach.
        do {
            let root = try work.directory.mountedVolume("mnt-ota-apps")
            let apps = try root.directory("private/var/staged_system_apps")
            guard !(try apps.entries()).isEmpty else { throw ValidationError("Target OS has no staged system apps.") }
            let destination = "usr/local/share/vphone-ota/apps"
            try system.removeItem(destination)
            try system.copyTree(from: apps, to: destination, owner: Self.guestOwner, clearSetID: false)
            try system.writeFile("usr/local/share/vphone-ota/Upgrade.plist",
                                 contents: system.readData(".vphone-ota-upgrade.plist"), mode: 0o644, owner: Self.guestOwner)
        }
        try detachImage(at: mount)
        attached = false
        print("  [+] OTA target system-app programs staged; encrypted Data was not mounted")
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

    /// Cryptex images are only read from. Keep noowners and nosuid mount
    /// options, the read-only attach, the mount point inside the root-only
    /// work folder, and `copyTree`, which never follows a link and refuses
    /// device nodes.
    private func attachCryptex(_ image: URL, at mountPoint: URL) throws {
        try tool(
            "/usr/sbin/diskutil",
            [
                "image", "attach", "-readOnly", "-nobrowse", "-mountOptions", "noowners,nosuid",
                "-mountPoint", mountPoint.path, image.path,
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

    /// The staged OTA, the configured device and the patched target firmware
    /// must all name the same 27.x build before System is replaced.
    private func requireOTAUpdate(
        ota: VPhoneConfinedDirectory,
        restore: VPhoneConfinedDirectory,
        plan: VPhoneVirtualMachinePatchPlan,
        device: VPhoneGuestDevice
    ) throws {
        guard let metadata = try PropertyListSerialization.propertyList(from: ota.readData("Upgrade.plist"), format: nil) as? [String: String],
              metadata["Device"] == device.productType,
              metadata["Version"] == plan.iOSBaseVersion,
              metadata["Version"]?.hasPrefix("27.") == true,
              let target = try PropertyListSerialization.propertyList(from: restore.readData("iPhone-BuildManifest.plist"), format: nil) as? [String: Any],
              metadata["Build"] == target["ProductBuildVersion"] as? String else {
            throw ValidationError("The staged OTA, configured device and target IPSW/patch plan disagree. Run fw ota-stage with the matching full OTA.")
        }
        guard try restore.isRegularFile("kernelcache.research.vphone600") else {
            throw ValidationError("The target has no patched kernelcache. Run fw patch before installing the OTA.")
        }
    }

    /// Host-driven full OTA payload installation. The container, Data, User,
    /// xART, SEPStorage, NVRAM and Preboot identity stay with this guest.
    private func replaceOTAUserland(
        system: VPhoneConfinedDirectory,
        ota: VPhoneConfinedDirectory,
        work: WorkDirectory
    ) throws {
        let metadata = try ota.readData("Upgrade.plist")
        // The existing installer treats this as a per-machine preference.
        // Carry it across System replacement; never reuse patched binaries or
        // their backups from the previous OS.
        let misfix = try system.isRegularFile("usr/lib/libmisfix.plist")
            ? try system.readData("usr/lib/libmisfix.plist") : nil
        try replaceTVUserland(system: system, ota: ota, work: work,
                              identifier: FirmwareGuestSystemPatchSet.otaUserland)
        guard let expected = try PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String: String],
              let actual = try PropertyListSerialization.propertyList(from: system.readData("System/Library/CoreServices/SystemVersion.plist"), format: nil) as? [String: Any],
              expected["Build"] == actual["ProductBuildVersion"] as? String,
              expected["Version"] == actual["ProductVersion"] as? String else {
            throw ValidationError("The extracted OTA SystemVersion does not match the staged update. The private disk clone was discarded.")
        }
        if let misfix {
            try system.writeFile("usr/lib/libmisfix.plist", contents: misfix, mode: 0o644, owner: Self.guestOwner)
        }
        try system.writeFile(".vphone-ota-upgrade.plist", contents: metadata, mode: 0o644, owner: Self.guestOwner)
    }

    /// Research: put an Apple TV 4K userland in place of the restored Apple TV
    /// HD one. `ota` holds the OTA's raw `payloadv2/payload.NNN` chunks and
    /// `payload_chunks.txt`; each chunk is an Apple Archive, which `aa` extracts
    /// as root with the owners, modes, BSD flags and APFS compression the OTA
    /// records. The chunk list is kept on the volume so an environment update
    /// does not extract the same userland again. A full iOS OTA update reuses
    /// this extraction under its own `identifier`, adding `links.txt`.
    private func replaceTVUserland(
        system: VPhoneConfinedDirectory,
        ota: VPhoneConfinedDirectory,
        work: WorkDirectory,
        identifier: String = FirmwareGuestSystemPatchSet.tvOTAUserland,
    ) throws {
        let marker = ".vphone-ota-userland"
        let chunkList = try ota.readData(VPhoneOTAArchive.chunkListName)
        if [FirmwareGuestSystemPatchSet.tvOTAUserland, FirmwareGuestSystemPatchSet.homePodOTAUserland].contains(identifier),
           try system.isRegularFile(marker), try system.readData(marker) == chunkList {
            print("  [·] \(identifier): userland already in place")
            return
        }
        let chunks = try ota.entries()
            .filter { $0.hasPrefix("payload.") && Int($0.dropFirst("payload.".count)) != nil }
            .sorted()
        guard !chunks.isEmpty else {
            throw ValidationError("\(identifier): OTAUserland has no payload.NNN chunks.")
        }
        // Private copies, so the archives root reads are the caller's files as
        // they were when copied, not whatever the folder holds later.
        for chunk in chunks {
            try work.directory.removeItem(chunk)
            try ota.copyFile(from: chunk, to: chunk, in: work.directory)
        }
        let linkList: Data?
        if try ota.isRegularFile(VPhoneOTAArchive.hardLinkListName) {
            try ota.copyFile(from: VPhoneOTAArchive.hardLinkListName,
                             to: VPhoneOTAArchive.hardLinkListName, in: work.directory)
            linkList = try work.directory.readData(VPhoneOTAArchive.hardLinkListName)
        } else {
            linkList = nil
        }
        if identifier == FirmwareGuestSystemPatchSet.otaUserland || identifier == FirmwareGuestSystemPatchSet.homePodOTAUserland {
            // Root extracts only pinned private copies. Reject traversal and
            // any later member beneath an archive-created symlink first.
            guard let linkList else {
                throw ValidationError("The full OTA has no links.txt. Stage the complete OTA before installing.")
            }
            try VPhoneOTAArchive.validatePayloadPaths(chunks.map { work.file($0) }, hardLinks: linkList)
        }
        print("  [*] \(identifier): replacing the System volume with \(chunks.count) OTA payload chunks")
        for entry in try system.entries() {
            _ = try system.removeItem(entry)
        }
        let root = try system.path
        for chunk in chunks {
            _ = try tool("/usr/bin/aa", ["extract", "-d", root, "-i", work.file(chunk).path])
            try work.directory.removeItem(chunk)
        }
        if let linkList {
            let count = try VPhoneOTAArchive.installHardLinks(linkList, in: system)
            print("  [+] \(identifier): installed \(count) OTA hard links")
            try work.directory.removeItem(VPhoneOTAArchive.hardLinkListName)
        }
        try system.writeFile(marker, contents: chunkList, mode: 0o644, owner: Self.guestOwner)
        print("  [+] \(identifier): userland extracted")
    }

    /// The OTA supplies the complete HomePod System; its original 27.0 IPSW
    /// still supplies the restore identity. Verify the target independently of
    /// that base manifest, including on an idempotent environment redeploy.
    private func replaceHomePodUserland(
        system: VPhoneConfinedDirectory,
        ota: VPhoneConfinedDirectory,
        work: WorkDirectory,
        plan: VPhoneVirtualMachinePatchPlan?,
        device: VPhoneGuestDevice
    ) throws {
        guard let metadata = try PropertyListSerialization.propertyList(from: ota.readData("Version.plist"), format: nil) as? [String: String],
              metadata["Device"] == device.productType,
              let version = metadata["Version"], version == plan?.iOSBaseVersion,
              let parsed = VPhoneVersion(version), parsed >= VPhoneVersion("27.2")!,
              let build = metadata["Build"], !build.isEmpty else {
            throw ValidationError("The HomePod OTA device/version does not match the patch plan. Prepare the matching full HomePod OTA before installation.")
        }
        // Chunk names alone can be identical across releases. A prior marker
        // may skip extraction only when the actual System has this identity.
        let marker = ".vphone-ota-userland"
        if try system.isRegularFile(marker),
           let actual = try? PropertyListSerialization.propertyList(from: system.readData("System/Library/CoreServices/SystemVersion.plist"), format: nil) as? [String: Any],
           actual["ProductVersion"] as? String != version || actual["ProductBuildVersion"] as? String != build {
            try system.removeItem(marker)
        }
        try replaceTVUserland(system: system, ota: ota, work: work,
                              identifier: FirmwareGuestSystemPatchSet.homePodOTAUserland)
        guard let actual = try PropertyListSerialization.propertyList(from: system.readData("System/Library/CoreServices/SystemVersion.plist"), format: nil) as? [String: Any],
              actual["ProductVersion"] as? String == version,
              actual["ProductBuildVersion"] as? String == build else {
            throw ValidationError("The extracted HomePod SystemVersion does not match its staged OTA. The private disk clone was discarded.")
        }
    }

    private func updateHomePodNowPlaying(system: VPhoneConfinedDirectory, work: WorkDirectory, enabled: Bool) throws {
        let app = "Applications/NowPlayingCap.app"
        let executable = "\(app)/NowPlayingCap"
        if enabled {
            guard try system.isRegularFile(executable) else {
                throw ValidationError("HomePod Sound Glow requires the native 27.2 NowPlayingCap app.")
            }
            try patchMachO(system: system, work: work, path: executable,
                           preserveEntitlements: true, injectedDylibPath: "/usr/lib/libvphonehomepoddisplay.dylib")
            try sealGuestBundle(system: system, bundle: app, preserveEntitlements: true)
        } else if try revertMachO(system: system, work: work, path: executable) {
            try sealGuestBundle(system: system, bundle: app, preserveEntitlements: true)
        }
    }

    /// The paravirtual GPU driver and its compiler plugin are built for iOS.
    /// An arm64e tvOS process loads them once they say tvOS: dyld refuses a
    /// library whose platform is not the process's. Each is re-signed after
    /// the edit, then the bundle is sealed again.
    private func retargetGPUBundleToTVOS(system: VPhoneConfinedDirectory, work: WorkDirectory) throws {
        let gpu = "System/Library/Extensions/\(VPhonePCCGPUDriver.name)"
        for name in ["AppleParavirtGPUMetalIOGPUFamily", "libAppleParavirtCompilerPluginIOGPUFamily.dylib"] {
            let path = "\(gpu)/\(name)"
            let staged = work.file(name)
            try work.directory.removeItem(name)
            try system.copyFile(from: path, to: name, in: work.directory)
            var data = try Data(contentsOf: staged)
            try MachOBuildPlatform.set(MachOBuildPlatform.tvOS, in: &data)
            try data.write(to: staged)
            try VPhoneSigner.sign(
                fileAt: staged,
                options: .init(identifier: nil, entitlements: nil, mergesExisting: true, style: .appleAdHoc),
            )
            try system.replaceFile(path, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
        }
        try sealGuestBundle(system: system, bundle: gpu)
        print("  [+] GPU driver retargeted to tvOS")
    }

    /// IOHIDUserDevice reserves IOClass. The shim supplies MiniDisplay's class
    /// identity only for our physical ID, inside SoundBoard. Load it through
    /// SoundBoard's Mach-O: launchd strips DYLD environment variables from this
    /// platform process. Also remove this patch's earlier environment route.
    private func updateHomePodSoundBoard(system: VPhoneConfinedDirectory, work: WorkDirectory, enabled: Bool) throws {
        let daemon = "System/Library/LaunchDaemons/com.apple.SoundBoard.plist"
        let cache = "System/Library/xpc/launchd.plist"
        let library = "/usr/lib/libvphonehomepoddisplay.dylib"
        let libraryPath = String(library.dropFirst())
        let app = "System/Library/CoreServices/SoundBoard.app"
        let executable = "\(app)/SoundBoard"

        func read(_ path: String) throws -> (dictionary: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: system.readData(path), options: [], format: &format,
            ) as? [String: Any] else {
                throw ValidationError("HomePod top cap needs a valid \(path).")
            }
            return (dictionary, format)
        }

        func rewrite(_ dictionary: [String: Any]) throws -> [String: Any] {
            var updated = dictionary
            guard updated["Label"] as? String == "com.apple.SoundBoard",
                  (updated["ProgramArguments"] as? [String])?.first
                    == "/System/Library/CoreServices/SoundBoard.app/SoundBoard"
            else {
                throw ValidationError("HomePod top cap refuses a daemon that is not SoundBoard.")
            }
            guard updated["EnvironmentVariables"] == nil || updated["EnvironmentVariables"] is [String: Any] else {
                throw ValidationError("SoundBoard has invalid launchd EnvironmentVariables.")
            }
            var environment = updated["EnvironmentVariables"] as? [String: Any] ?? [:]
            guard environment["DYLD_INSERT_LIBRARIES"] == nil || environment["DYLD_INSERT_LIBRARIES"] is String else {
                throw ValidationError("SoundBoard has invalid DYLD_INSERT_LIBRARIES.")
            }
            let libraries = (environment["DYLD_INSERT_LIBRARIES"] as? String ?? "")
                .split(separator: ":", omittingEmptySubsequences: true).map(String.init)
                .filter { $0 != library }
            if libraries.isEmpty {
                environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            } else {
                environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
            }
            if environment.isEmpty {
                updated.removeValue(forKey: "EnvironmentVariables")
            } else {
                updated["EnvironmentVariables"] = environment
            }
            return updated
        }

        // Validate the complete pair before writing either half. A missing
        // cache entry is not a reason to silently install an inert shim.
        guard try system.isRegularFile(daemon), try system.isRegularFile(cache) else {
            if !enabled {
                if try revertMachO(system: system, work: work, path: executable) {
                    try sealGuestBundle(system: system, bundle: app, preserveEntitlements: true)
                }
                try system.removeItem(libraryPath)
                return
            }
            throw ValidationError("HomePod top cap needs SoundBoard's launch daemon and launchd cache.")
        }
        let original = try read(daemon)
        var cached = try read(cache)
        let key = "/" + daemon
        guard var entries = cached.dictionary["LaunchDaemons"] as? [String: Any],
              let entry = entries[key] as? [String: Any]
        else {
            throw ValidationError("HomePod top cap cannot find SoundBoard in the launchd cache.")
        }
        let changedDaemon = try rewrite(original.dictionary)
        entries[key] = try rewrite(entry)
        cached.dictionary["LaunchDaemons"] = entries

        if enabled {
            let shim = try VPhoneGuestBinaries.resolve("libvphonehomepoddisplay.dylib")
            try system.replaceFile(libraryPath, fromFileAt: shim, mode: 0o755, owner: Self.guestOwner)
            try patchMachO(
                system: system, work: work, path: executable,
                preserveEntitlements: true, injectedDylibPath: library,
            )
            try sealGuestBundle(system: system, bundle: app, preserveEntitlements: true)
        } else {
            if try revertMachO(system: system, work: work, path: executable) {
                try sealGuestBundle(system: system, bundle: app, preserveEntitlements: true)
            }
            try system.removeItem(libraryPath)
        }
        // This is an exact inverse of the prototype's environment insertion,
        // keeping changes users made to other daemon keys in the meantime.
        try system.writeFile(daemon, contents: PropertyListSerialization.data(
            fromPropertyList: changedDaemon, format: original.format, options: 0,
        ), mode: 0o644, owner: Self.guestOwner)
        try system.removeItem("\(daemon).bak")
        try system.writeFile(cache, contents: PropertyListSerialization.data(
            fromPropertyList: cached.dictionary, format: cached.format, options: 0,
        ), mode: 0o644, owner: Self.guestOwner)
    }

    private func installVphoned(guestDevice: VPhoneGuestDevice, system: VPhoneConfinedDirectory, work: WorkDirectory) throws {
        // Install the same signed bytes that vm launch uses for auto-update.
        // Re-signing here changes the binary hash and forces an upload and
        // daemon restart on the VM's first boot.
        let vphoned = try VPhoneGuestBinaries.resolve(VPhoneResources.vphonedName(for: guestDevice.family))
        let staged = work.file("vphoned")
        try fm.copyItem(at: vphoned, to: staged)
        if guestDevice.family == .iPhone || guestDevice.family == .iPad {
            // Install on both full and environment-only updates, before the
            // daemon that needs it. The payload is already signed in the bundle.
            _ = try system.directory("usr/lib/vphone", create: true)
            try system.replaceFile("usr/lib/vphone/libswiftCompatibilitySpan.dylib",
                                   fromFileAt: VPhoneGuestBinaries.resolve("libswiftCompatibilitySpan.dylib"),
                                   mode: 0o755, owner: Self.guestOwner)
        }
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

    /// Keep rollback available even when the owner also deselects vphoned.
    /// This helper is inert when no setup marker or original-key journal exists.
    private func installHomePodSetupRuntime(system: VPhoneConfinedDirectory, work: WorkDirectory, homeView: Bool = false) throws {
        let helper = try VPhoneGuestBinaries.resolve("vphone-homepod-setup")
        _ = try system.directory("usr/local/libexec", create: true, mode: 0o755)
        try system.replaceFile("usr/local/libexec/vphone-homepod-setup", fromFileAt: helper,
                               mode: 0o755, owner: Self.guestOwner)
        let originalDaemon = resources.guestResources.appendingPathComponent("com.vphone.homepod-setup.plist")
        let name = homeView ? "com.vphone.homeview-setup" : "com.vphone.homepod-setup"
        let daemon: URL
        if homeView {
            guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: originalDaemon), format: nil) as? [String: Any] else {
                throw ValidationError("The bundled setup maintenance launch daemon is not a dictionary.")
            }
            plist["Label"] = name
            plist["ProgramArguments"] = ["/usr/local/libexec/vphone-homepod-setup", "--homeview"]
            daemon = work.file("homeview-setup-daemon.plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: daemon)
        } else {
            daemon = originalDaemon
        }
        try system.replaceFile("System/Library/LaunchDaemons/\(name).plist", fromFileAt: daemon,
                               mode: 0o644, owner: Self.guestOwner)
        let cache = "System/Library/xpc/launchd.plist"
        let staged = "homepod-setup-launchd.plist"
        try system.copyFile(from: cache, to: staged, in: work.directory)
        try CustomFirmwareDaemons.injectDaemon(into: work.file(staged), name: name, from: daemon)
        try system.replaceFile(cache, fromFileAt: work.file(staged), mode: 0o644, owner: Self.guestOwner)
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
    ///
    /// `environmentOnly` keeps the old environment-update rule: a library the VM
    /// does not already have stays absent (its absence means the VM's plan never
    /// selected it), and the `/vh` alias is not created — an installed VM
    /// already has it, and an environment update does not add load-command
    /// infrastructure. A full install writes every library and creates `/vh`.
    ///
    /// An Apple TV takes `VPhoneGuestEnvironment.tvLibraries` alone, marked
    /// tvOS. No TV guest had an environment before, so the narrow rule does
    /// not apply there: both libraries and `/vh` are always written.
    private func installEnvironment(
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        guestDevice: VPhoneGuestDevice,
        environmentOnly: Bool = false,
    ) throws {
        let tvOS = guestDevice.usesTVOS
        let narrow = environmentOnly && !tvOS
        for name in tvOS ? VPhoneGuestEnvironment.tvLibraries : VPhoneGuestEnvironment.libraries {
            if VPhoneGuestEnvironment.selectedLibraries.contains(name) {
                continue
            }
            let path = "usr/lib/\(name)"
            if narrow, try !system.exists(path) {
                print("  [·] \(path): not on this VM, left out")
                continue
            }
            let shipped = try VPhoneGuestBinaries.resolve(name)
            let source = tvOS ? try tvOSCopy(of: shipped, work: work) : shipped
            try system.replaceFile(path, fromFileAt: source, mode: 0o755, owner: Self.guestOwner)
        }
        if !narrow {
            // launchd has little free header space for another load command.
            // /vh fits the same 32-byte command as the old /b without reusing it.
            try installLibraryAlias(system: system, alias: "vh", target: "/usr/lib/launchdhook-vphone.dylib")
        }
        if tvOS {
            print("  [+] Environment hooks retargeted to tvOS: \(VPhoneGuestEnvironment.tvLibraries.joined(separator: ", "))")
        } else {
            try installMISFixDefaults(system: system)
        }
    }

    /// A bundle-shipped iOS library, marked tvOS and signed again in the work
    /// directory. dyld refuses to load a library of another platform, and an
    /// Apple TV guest's processes, launchd among them, are tvOS.
    private func tvOSCopy(of source: URL, work: WorkDirectory) throws -> URL {
        let name = "tvos-\(source.lastPathComponent)"
        try work.directory.removeItem(name)
        let staged = work.file(name)
        var data = try Data(contentsOf: source)
        try MachOBuildPlatform.set(MachOBuildPlatform.tvOS, in: &data)
        try data.write(to: staged)
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(identifier: nil, entitlements: nil, mergesExisting: true, style: .appleAdHoc),
        )
        return staged
    }

    /// The TV environment's libraries and `/vh`, when the environment is off.
    /// A launchd still patched to load `/vh` loads nothing: the command is weak.
    private func removeTVEnvironment(system: VPhoneConfinedDirectory) throws {
        var removed = false
        for name in VPhoneGuestEnvironment.tvLibraries where try system.exists("usr/lib/\(name)") {
            try system.removeItem("usr/lib/\(name)")
            removed = true
        }
        if try system.isSymlink("vh"), try system.readLink("vh") == "/usr/lib/launchdhook-vphone.dylib" {
            try system.removeItem("vh")
            removed = true
        }
        if removed {
            print("  [+] system-launchdaemons-boot-environment: removed the TV environment hooks")
        }
    }

    /// The CoreAudio HAL plugin for the VM's virtio sound device. iOS ships
    /// the kernel driver, AppleVirtIOSound, but no plugin for it, so audiomxd
    /// has nothing to play through. The bundle is replaced whole; its
    /// signature seals the binary and Info.plist together.
    private func installVirtioSoundDriver(system: VPhoneConfinedDirectory, work: WorkDirectory, guestDevice: VPhoneGuestDevice) throws {
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
        if guestDevice.family == .homePod {
            // The shared driver is built for iOS. HomePod's arm64e TVOS ASD
            // has the same verified interfaces, but dyld requires its platform
            // and CFBundle metadata to agree with the loading process.
            let name = "VPhoneVirtIOSound-tvos"
            try work.directory.removeItem(name)
            try system.copyFile(from: "\(target)/VPhoneVirtIOSound", to: name, in: work.directory)
            let staged = work.file(name)
            var data = try Data(contentsOf: staged)
            try MachOBuildPlatform.set(MachOBuildPlatform.tvOS, in: &data)
            try data.write(to: staged)
            try VPhoneSigner.sign(
                fileAt: staged,
                options: .init(identifier: nil, entitlements: nil, mergesExisting: true, style: .appleAdHoc),
            )
            try system.replaceFile("\(target)/VPhoneVirtIOSound", fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
            let infoPath = "\(target)/Info.plist"
            guard var info = try PropertyListSerialization.propertyList(from: system.readData(infoPath), format: nil) as? [String: Any] else {
                throw ValidationError("The virtio sound driver has no valid bundle metadata.")
            }
            info["CFBundleSupportedPlatforms"] = ["AppleTVOS"]
            try system.writeFile(infoPath, contents: PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), mode: 0o644, owner: Self.guestOwner)
            try sealGuestBundle(system: system, bundle: target)
            print("  [+] Virtio sound driver retargeted to tvOS")
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

    /// `includeIdentity` also enables an environment update's selected identity.
    /// The device tree repairs include the board repair, which needs `boardDeviceTree`
    /// (a board-presenting guest's audio node, an iPhone17,3's product
    /// description), the haptics removal and the microphone-array repair.
    /// `boardDeviceTree` is the guest's own board tree (`DeviceTree.<board>.im4p`),
    /// staged from the VM's `FirmwareOriginals`, or nil when none is kept there.
    ///
    /// Returns the Preboot device-tree identifiers live afterwards, for the
    /// receipt. The repairs share one personalized `devicetree.img4`, so there
    /// is no per-repair inverse; instead the final tree is built in staging and
    /// written only if it differs from what is on disk, so an unchanged result
    /// never bumps the mtime (vphoned drops its MobileGestalt cache when the
    /// tree is newer than it). The backup kept beside the tree is its state
    /// *after* the identity rewrite and *before* the repairs:
    ///
    ///  - full install: restore that backup to a clean base, apply identity,
    ///    re-take the backup from the post-identity bytes, then apply the
    ///    enabled repairs;
    ///  - environment update: restore the backup, apply identity when selected,
    ///    then apply the enabled repairs.
    ///
    /// A backup is taken only when the base is known clean — a backup already
    /// existed, or no repair was live before. A tree repaired before backups
    /// were kept has none, and an off repair on it is reported not revertible
    /// and left in place.
    @discardableResult
    private func patchPreboot(
        volumes: [[String: Any]],
        work: WorkDirectory,
        plan: VPhoneVirtualMachinePatchPlan?,
        priorGuest: Set<String>,
        guestDevice: VPhoneGuestDevice,
        includeIdentity: Bool,
        buildVersion: String?,
        boardDeviceTree: URL?,
        otaRestore: VPhoneConfinedDirectory? = nil,
    ) throws -> Set<String> {
        var live = Set<String>()
        // Whether a device-tree patch is enabled. A VM with no plan gets every
        // one, which is what it was restored with.
        func enabled(_ identifier: String) -> Bool {
            plan?.isEnabled(identifier) ?? true
        }

        let identity = FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity
        var rewriteIdentity = false
        if includeIdentity {
            if guestDevice.presentsBoard {
                print("  [·] \(identity): skipped, the device tree already presents \(guestDevice.productType)")
            } else {
                rewriteIdentity = enabled(identity)
                if !rewriteIdentity {
                    print("  [·] \(identity): off in the current selection")
                }
            }
        } else if priorGuest.contains(identity) {
            // With identity off, an environment update preserves the installed
            // identity: the repair backup is already post-identity.
            live.insert(identity)
        }

        // The repairs, which share the one devicetree.img4.
        var repairGroup: [(id: String, verb: String, arguments: [String])] = []
        if let boardDeviceTree {
            if guestDevice.presentsBoard {
                repairGroup.append((FirmwareGuestSystemPatchSet.prebootBoardAudio, "patch-dt-board-audio", [boardDeviceTree.path]))
            }
            // A board-presenting iPhone's restored tree takes the board's
            // values only where vphone600 has a placeholder; Camera Control
            // and the Action Button are added here.
            if guestDevice.family == .iPhone {
                repairGroup.append((FirmwareGuestSystemPatchSet.prebootIPhoneProduct, "patch-dt-iphone-product", [boardDeviceTree.path]))
            }
        }
        if guestDevice.family == .homePod {
            // Keep the repair in the inverse composition even with no donor
            // when it is off: restoring the clean backup needs no source tree.
            if enabled(FirmwareGuestSystemPatchSet.homePodAudioProduct), boardDeviceTree == nil {
                throw ValidationError("HomePod audio identity needs its original donor device tree.")
            }
            if plan != nil || priorGuest.contains(FirmwareGuestSystemPatchSet.homePodCryptexClass) {
                repairGroup.append((FirmwareGuestSystemPatchSet.homePodCryptexClass, "patch-dt-homepod-cryptex-class", []))
            }
            repairGroup.append((FirmwareGuestSystemPatchSet.homePodAudioProduct, "patch-dt-homepod-audio-product",
                                boardDeviceTree.map { [$0.path] } ?? []))
        }
        if Self.isFoldable(guestDevice) {
            // Keep the repair in the inverse composition even with no donor
            // when it is off: restoring the clean backup needs no source tree.
            if enabled(FirmwareGuestSystemPatchSet.prebootFoldableProductId), boardDeviceTree == nil {
                throw ValidationError("Foldable product identity needs the board's own device tree.")
            }
            if enabled(FirmwareGuestSystemPatchSet.prebootFoldableDisplays), boardDeviceTree == nil {
                throw ValidationError("Foldable panel nodes need the board's own device tree.")
            }
            repairGroup.append((FirmwareGuestSystemPatchSet.prebootFoldableVMSubtype, "patch-dt-foldable-vm-subtype", []))
            repairGroup.append((FirmwareGuestSystemPatchSet.prebootFoldableProductId, "patch-dt-foldable-product-id",
                                boardDeviceTree.map { [$0.path] } ?? []))
            repairGroup.append((FirmwareGuestSystemPatchSet.prebootFoldableDisplays, "patch-dt-foldable-displays",
                                boardDeviceTree.map { [$0.path] } ?? []))
        }
        repairGroup.append((FirmwareGuestSystemPatchSet.prebootHaptics, "patch-dt-haptics", []))
        repairGroup.append((FirmwareGuestSystemPatchSet.prebootMicrophoneArray, "patch-dt-microphone-array", []))
        let repairsOn = repairGroup.filter { enabled($0.id) }
        for off in repairGroup where !enabled(off.id) {
            print("  [·] \(off.id): off in the current selection")
        }

        let buildID = "system-systemversion-cfw-build_version"

        // Mount only when there is device-tree work to do, a repair to revert,
        // or a build spoof to apply or revert.
        let mayRevertRepair = repairGroup.contains { !enabled($0.id) && priorGuest.contains($0.id) }
        let wantsBuild = (buildVersion.map { !$0.isEmpty } ?? false) && enabled(buildID)
        let touchesBuild = wantsBuild || priorGuest.contains(buildID)
        guard otaRestore != nil || rewriteIdentity || !repairsOn.isEmpty || mayRevertRepair || touchesBuild else { return live }

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
        // Every descriptor on the Preboot volume lives in this scope, so none
        // is left open to hold it busy when the deferred unmount runs.
        do {
            let root = try openGuestVolume("preboot", device: device, in: work)
            // Each candidate must be reached without a link anywhere on the way;
            // one behind a link is not counted.
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

            if let otaRestore {
                /// Swap only the IM4P inside a personalized Preboot IMG4,
                /// keeping its manifest, mode and owner.
                func replacePayload(_ path: String, _ meta: stat, patched: Data, fourcc: String, label: String) throws {
                    guard let updated = try CustomFirmwarePostRestoreDeviceTree.firmwareReplacingPayload(
                        prebootIMG4: root.readData(path), patchedComponent: patched, expectedFourcc: fourcc
                    ) else { return }
                    let staged = work.file("\(fourcc).new")
                    try updated.write(to: staged)
                    try root.replaceFile(path, fromFileAt: staged, mode: meta.st_mode & 0o7777, owner: (meta.st_uid, meta.st_gid))
                    print("  [+] OTA Preboot \(label) updated; personalized manifest retained")
                }
                let kernels = try root.entries().compactMap { name -> String? in
                    let path = "\(name)/System/Library/Caches/com.apple.kernelcaches/kernelcache"
                    return (try? root.isDirectory(name)) == true && (try? root.isRegularFile(path)) == true ? path : nil
                }
                guard kernels.count == 1, let kernelPath = kernels.first,
                      let meta = try root.status(kernelPath), meta.st_mode & S_IFMT == S_IFREG else {
                    throw ValidationError("OTA guest has no unique regular Preboot kernelcache.")
                }
                try replacePayload(kernelPath, meta, patched: otaRestore.readData("kernelcache.research.vphone600"),
                                   fourcc: "krnl", label: "kernelcache")
                // iOS 27 needs TXM's pre-check admission in addition to its
                // kernel changes. Keep the original personalized container.
                let component = "Ap,TrustedExecutionMonitor"
                guard let manifest = try PropertyListSerialization.propertyList(from: otaRestore.readData("BuildManifest.plist"), format: nil) as? [String: Any],
                      let identities = manifest["BuildIdentities"] as? [[String: Any]] else {
                    throw ValidationError("OTA target has no boot manifest.")
                }
                let sources = Set(identities.compactMap { identity -> String? in
                    let entry = (identity["Manifest"] as? [String: Any])?[component] as? [String: Any]
                    return (entry?["Info"] as? [String: Any])?["Path"] as? String
                })
                guard sources.count == 1, let source = sources.first else {
                    throw ValidationError("OTA target has no unique TXM component.")
                }
                let bootFolder = String(deviceTree.prefix { $0 != "/" })
                let path = "\(bootFolder)/usr/standalone/firmware/FUD/\(component).img4"
                guard let meta = try root.status(path), meta.st_mode & S_IFMT == S_IFREG else {
                    throw ValidationError("OTA guest has no regular Preboot TXM.")
                }
                try replacePayload(path, meta, patched: otaRestore.readData(source), fourcc: "trxm", label: "TXM")
            }

            try buildDeviceTree(
                deviceTree, in: root, work: work,
                rewriteIdentity: rewriteIdentity, identity: identity,
                includeIdentity: includeIdentity, repairGroup: repairGroup, repairsOn: repairsOn,
                priorGuest: priorGuest, live: &live,
            )

            // The build-version spoof on the Preboot SystemVersion, its own file
            // and its own backup. The identifier is shared with the system-volume
            // copy, which the guest-patch pass already recorded; this keeps the
            // two copies in step and does not record again. It follows the same
            // preset parameter / SPOOF_BUILD the system-volume copy does.
            let version = "Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist"
            if try root.isRegularFile(version) {
                if wantsBuild, let build = buildVersion {
                    try patchCopy(of: version, in: root, work: work, verb: "patch-build-version", arguments: [build], backupSafe: !priorGuest.contains(buildID))
                } else if !enabled(buildID) {
                    try revertCopy(of: version, in: root)
                }
            }
        }

        return live
    }

    /// Build the final device tree in staging and write it only if it differs
    /// from what is on disk, so an unchanged result does not bump the mtime. See
    /// `patchPreboot` for the ordering and backup rules this implements.
    private func buildDeviceTree(
        _ deviceTree: String,
        in root: VPhoneConfinedDirectory,
        work: WorkDirectory,
        rewriteIdentity: Bool,
        identity: String,
        includeIdentity _: Bool,
        repairGroup: [(id: String, verb: String, arguments: [String])],
        repairsOn: [(id: String, verb: String, arguments: [String])],
        priorGuest: Set<String>,
        live: inout Set<String>,
    ) throws {
        guard let meta = try root.status(deviceTree), meta.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError("\(deviceTree) on the VM is missing or is not a regular file. Restore the VM, then install CFW again.")
        }
        let currentBytes = try root.readData(deviceTree)
        let backup = "\(deviceTree).bak"
        let hadRepairBackup = try root.exists(backup)
        // A backup is trustworthy only when the base it will describe is clean:
        // one already existed, or no repair was live before this run.
        let backupSafe = hadRepairBackup || repairGroup.allSatisfy { !priorGuest.contains($0.id) }

        // Stage the base: the clean backup when there is one, else the tree as
        // it stands now.
        let folder = "dt-\(UUID().uuidString)"
        _ = try work.directory.directory(folder, create: true, mode: 0o700)
        defer { _ = try? work.directory.removeItem(folder) }
        let staged = work.file(folder).appendingPathComponent("devicetree.img4")
        try (hadRepairBackup ? root.readData(backup) : currentBytes).write(to: staged)

        // Identity first when selected, so the post-identity snapshot and
        // a later repair revert never undo it.
        if rewriteIdentity {
            try patch("patch-post-restore-dt", [staged.path])
            live.insert(identity)
        }
        let postIdentity = try Data(contentsOf: staged)

        // Then the enabled repairs.
        if !repairsOn.isEmpty {
            for repair in repairsOn {
                try patch(repair.verb, [staged.path] + repair.arguments)
                live.insert(repair.id)
            }
        } else if !backupSafe {
            for repair in repairGroup where priorGuest.contains(repair.id) {
                print("  [!] \(repair.id): off now but no device-tree backup to revert (not revertible)")
                live.insert(repair.id)
            }
        }

        let finalBytes = try Data(contentsOf: staged)
        // Write the tree only if it actually changed.
        if finalBytes != currentBytes {
            try root.replaceFile(
                deviceTree, fromFileAt: staged,
                mode: meta.st_mode & 0o7777, owner: (meta.st_uid, meta.st_gid),
            )
        }
        // (Re)take the post-identity, pre-repair backup when the base was clean,
        // and only when it changed, so a no-op run leaves it untouched.
        if backupSafe {
            if try !root.exists(backup) || root.readData(backup) != postIdentity {
                try root.writeFile(backup, contents: postIdentity, mode: meta.st_mode & 0o7777, owner: (meta.st_uid, meta.st_gid))
            }
        }
    }

    /// The iPad's own device tree, `DeviceTree.<board>.im4p`, which `fw patch`
    /// keeps in the VM's `FirmwareOriginals` beside the vphone600 trees,
    /// copied into the work folder by descriptor. Nil when there is none: an
    /// iPhone guest, or a VM patched by a build that did not keep it and
    /// whose IPSW `recoverBoardDeviceTree` could not find.
    ///
    /// The folder is the caller's, so the copy goes through the pinned bundle
    /// descriptor like every other read here. Of several candidates, the
    /// guest device's own is taken (an Apple TV 4K keeps J255's beside the
    /// Apple TV HD base it is restored from); any other ambiguity is refused
    /// rather than guessed between.
    private func stageBoardDeviceTree(
        in bundleDirectory: VPhoneConfinedDirectory,
        work: WorkDirectory,
        device: VPhoneGuestDevice,
    ) throws -> URL? {
        var found = try VPhoneBoardDeviceTree.kept(in: bundleDirectory)
        guard !found.isEmpty else { return nil }
        if found.count > 1 {
            let own = (device.boardDeviceTreePath as NSString).lastPathComponent
            let matching = found.filter { $0.name == own }
            if matching.count == 1 { found = matching }
        }
        guard found.count == 1, let board = found.first else {
            throw ValidationError(
                "Found \(found.count) board device trees in \(VPhoneBundleOperations.firmwareOriginalsDirectoryName): \(found.map(\.path).joined(separator: ", ")). Keep one.",
            )
        }
        try board.directory.copyFile(from: board.name, to: board.name, in: work.directory)
        print("[*] Board device tree: \(board.path)")
        return work.file(board.name)
    }

    /// Make sure a VM's `FirmwareOriginals` holds the board tree that
    /// `stageBoardDeviceTree` stages, recovering it from the IPSW the VM was
    /// made from when it has none. A board-presenting VM patched before `fw
    /// patch` kept it needs it for the board audio repair, without which
    /// VirtualAudio looks for the iPhone's tunings and the guest has no sound.
    /// An iPhone XS Max VM needs it for the product description repair, without
    /// which MobileGestalt reads Siri, Camera Control, the Action Button and the
    /// model name as absent; `fw patch` does not keep its board tree, so it
    /// always comes from here.
    /// A HomePod mini also needs its donor's native product-id token for audio
    /// routing; its selected repair refuses to proceed without a valid donor.
    ///
    /// The IPSW cache and the VM folder are the caller's, so the search and
    /// the write run with the caller's credentials, as `cfw install` records
    /// its variant: the kernel applies the caller's permissions to every read
    /// and to the write, and the file left in the VM folder is the caller's.
    /// The write still goes through the pinned VM folder, and the tree is then
    /// staged from there like one `fw patch` kept.
    ///
    /// Recovery itself never fails the run: it reports the missing source and
    /// fix. Selected repairs that require validated donor data check it before
    /// guest filesystem writes.
    private func recoverBoardDeviceTree(
        in bundleDirectory: VPhoneConfinedDirectory,
        restore: VPhoneConfinedDirectory?,
        plan: VPhoneVirtualMachinePatchPlan?,
        invokingUser: VPhoneInvokingUser?,
    ) {
        let device = configuredGuestDevice(in: bundleDirectory) ?? guestDevice(of: restore)
        let repairs = device.family == .homePod
            ? [FirmwareGuestSystemPatchSet.prebootBoardAudio, FirmwareGuestSystemPatchSet.homePodAudioProduct]
            : [device.presentsBoard ? FirmwareGuestSystemPatchSet.prebootBoardAudio : FirmwareGuestSystemPatchSet.prebootIPhoneProduct]
        guard repairs.contains(where: { plan?.isEnabled($0) ?? true }) else { return }
        let tree = (device.boardDeviceTreePath as NSString).lastPathComponent
        let originals = VPhoneBundleOperations.firmwareOriginalsDirectoryName
        let skipped = device.family == .homePod
            ? "[!] HomePod audio identity repair skipped, so native audio routing may not initialize:"
            : device.presentsBoard
            ? "[!] Board audio repair skipped, so this \(device.productType) guest will have no sound:"
            : "[!] iPhone product repair skipped, so this \(device.productType) guest will have no Siri, Camera Control, Action Button or Model Name:"
        do {
            let need = try VPhoneBoardDeviceTree.need(
                device: device,
                in: bundleDirectory,
                recorded: recordedOSVersion(in: bundleDirectory),
            )
            let firmware: VPhoneBoardDeviceTree.Firmware
            switch need {
            case .none, .kept:
                return
            case .unidentified:
                print("\(skipped) \(originals) has no \(tree), and the VM folder does not say which IPSW it was made from. Copy \(device.boardDeviceTreePath) from that IPSW into \(bundle.path)/\(originals)/<restore tree>/Firmware/all_flash/, then run this again.")
                return
            case let .recover(found):
                firmware = found
            }
            let directories = VPhoneBoardDeviceTree.searchDirectories(forVirtualMachineAt: bundle)
            let fix = "Put that IPSW in \(directories[0].path), or copy its \(device.boardDeviceTreePath) to \(bundle.path)/\(firmware.keptPath), then run this again."
            print("[*] \(originals) has no \(tree); looking for the \(device.productType) \(firmware.version) (\(firmware.build)) IPSW in \(directories.map(\.path).joined(separator: ", "))")
            let recover = { () throws -> (source: VPhoneBoardDeviceTree.Source, path: String)? in
                guard let source = VPhoneBoardDeviceTree.find(firmware, in: directories) else { return nil }
                return try (source, VPhoneBoardDeviceTree.store(source, for: firmware, in: bundleDirectory))
            }
            do {
                guard let recovered = try invokingUser.map({ try $0.withUserCredentials(recover) }) ?? recover() else {
                    print("\(skipped) no IPSW for \(device.productType) \(firmware.version) (\(firmware.build)) was found, and \(originals) has no \(tree). \(fix)")
                    return
                }
                print("[+] Board device tree recovered: \(recovered.source.member) from \(recovered.source.archive.path), kept as \(recovered.path)")
            } catch {
                print("\(skipped) \(tree) could not be kept in \(originals): \(error). \(fix)")
            }
        } catch {
            print("\(skipped) \(bundle.path)/\(originals) could not be read: \(error). Copy \(device.boardDeviceTreePath) from the VM's IPSW into \(originals)/<restore tree>/Firmware/all_flash/, then run this again.")
        }
    }

    /// The guest device `fw prepare` recorded in `config.plist`, read through
    /// the pinned folder. Nil when it names none, as on a VM older than iPad
    /// guests.
    private func configuredGuestDevice(in bundleDirectory: VPhoneConfinedDirectory) -> VPhoneGuestDevice? {
        guard let data = try? bundleDirectory.readData("config.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return VPhoneGuestDevice.named(plist["guestProductType"] as? String)
    }

    /// The iOS version and build `restore-info.json` records.
    private func recordedOSVersion(in bundleDirectory: VPhoneConfinedDirectory) -> VPhoneRestoreInfo.OSVersion? {
        guard let data = try? bundleDirectory.readData("restore-info.json") else { return nil }
        return (try? JSONDecoder().decode(VPhoneRestoreInfo.self, from: data))?.ios
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
    /// `backup` keeps the pre-patch bytes beside the file as `<relative>.bak`,
    /// written the instant a verb first changes it and never overwritten after,
    /// so a later run can put the original back for a patch now turned off. It
    /// is captured from the staged pre-patch copy — not the live file — so it is
    /// the true inverse of this one edit even when the file already carried
    /// another patch, and it is created only when the verb actually changes
    /// something, so a no-op on an already-patched file never snapshots patched
    /// bytes as if they were pristine. A file patched before this existed has no
    /// `.bak` and is reported not revertible rather than guessed at.
    private func patchCopy(
        of relative: String,
        in root: VPhoneConfinedDirectory,
        work: WorkDirectory,
        verb: String,
        arguments: [String] = [],
        backupSafe: Bool = false,
    ) throws {
        guard let original = try root.status(relative), original.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError("\(relative) on the VM is missing or is not a regular file. Restore the VM, then install CFW again.")
        }
        // A folder of its own keeps the file's name, extension included.
        let folder = "stage-\(UUID().uuidString)"
        let stage = try work.directory.directory(folder, create: true, mode: 0o700)
        defer { _ = try? work.directory.removeItem(folder) }
        let leaf = (relative as NSString).lastPathComponent
        try root.copyFile(from: relative, to: leaf, in: stage)
        let staged = work.file(folder).appendingPathComponent(leaf)
        let before = try Data(contentsOf: staged)
        try patch(verb, [staged.path] + arguments)
        guard try Data(contentsOf: staged) != before else { return }
        // Only snapshot the pre-patch bytes as the backup when no patch that
        // touches this file was live before this run: otherwise `before`
        // already carries a patch and is not a pristine original.
        if backupSafe, try !root.exists("\(relative).bak") {
            try root.writeFile(
                "\(relative).bak",
                contents: before,
                mode: original.st_mode & 0o7777,
                owner: (original.st_uid, original.st_gid),
            )
        }
        try root.replaceFile(
            relative,
            fromFileAt: staged,
            mode: original.st_mode & 0o7777,
            owner: (original.st_uid, original.st_gid),
        )
    }

    /// Put `<relative>.bak` back over `relative` and remove the backup, the
    /// inverse of a `backup: true` `patchCopy`. Returns false when there is no
    /// backup — a file patched before backups were kept, which the caller
    /// reports as not revertible.
    @discardableResult
    private func revertCopy(of relative: String, in root: VPhoneConfinedDirectory) throws -> Bool {
        let backup = "\(relative).bak"
        guard try root.exists(backup) else { return false }
        try root.rename(backup, to: relative)
        return true
    }

    /// Run `verb` on every tuning set's graph_configurations.plist: by default
    /// the one that flips the speaker chains onto the generic graph path. The plist lives under the acoustic ID the
    /// image ships for (`Library/Audio/Tunings/<AID>/VAD/`), which varies by
    /// board, so the directory is walked rather than named. An image with no
    /// tuning sets — iOS 27's VirtualAudio reads no such plist — is left
    /// alone, quietly: there is nothing this patch could act on.
    /// Returns whether any tuning plist was present to act on — false when the
    /// VM has no `Library/Audio/Tunings`, so the caller does not record the
    /// patch live on an image that never had it.
    @discardableResult
    private func patchVirtualAudioGraphConfigurations(
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        verb: String = "patch-virtualaudio-graph-configurations",
        backupSafe: Bool = false,
    ) throws -> Bool {
        let tunings = "Library/Audio/Tunings"
        guard try system.exists(tunings), try system.isDirectory(tunings) else {
            print("  [·] \(tunings): not on this VM, left out")
            return false
        }
        var patched = 0
        for acousticID in try system.directory(tunings).entries().sorted() {
            let plist = "\(tunings)/\(acousticID)/VAD/graph_configurations.plist"
            guard try system.isRegularFile(plist) else { continue }
            try patchCopy(of: plist, in: system, work: work, verb: verb, backupSafe: backupSafe)
            patched += 1
            guard verb == "patch-virtualaudio-microphone-chains" else { continue }
            // The strips those chains now record through, without the gain
            // of the board's own microphone.
            let strips = "\(tunings)/\(acousticID)/VAD"
            for name in try system.directory(strips).entries().sorted()
                where name.contains("_mic") && name.hasSuffix("_measurement.austrip")
            {
                guard try system.isRegularFile("\(strips)/\(name)") else { continue }
                try patchCopy(of: "\(strips)/\(name)", in: system, work: work, verb: "patch-virtualaudio-microphone-gain", backupSafe: backupSafe)
            }
        }
        if patched == 0 {
            print("  [·] \(tunings): no graph_configurations.plist under any tuning set, left out")
            return false
        }
        return true
    }

    /// Restore every VirtualAudio tuning file that carries a `.bak` to pristine,
    /// the inverse of a `backup: true` run of
    /// `patchVirtualAudioGraphConfigurations`. The three tuning patches share
    /// one `graph_configurations.plist`, so there is no per-edit inverse: the
    /// caller restores pristine with this and then re-applies whichever of the
    /// three are still on, which lands exactly the enabled set. Returns whether
    /// any backup was found (false means the files were patched before backups
    /// were kept, and the caller reports them not revertible).
    @discardableResult
    private func restoreVirtualAudioTunings(system: VPhoneConfinedDirectory) throws -> Bool {
        let tunings = "Library/Audio/Tunings"
        guard try system.exists(tunings), try system.isDirectory(tunings) else { return false }
        var restored = false
        for acousticID in try system.directory(tunings).entries().sorted() {
            let vad = "\(tunings)/\(acousticID)/VAD"
            guard try system.exists(vad), try system.isDirectory(vad) else { continue }
            for name in try system.directory(vad).entries().sorted() where name.hasSuffix(".bak") {
                let backup = "\(vad)/\(name)"
                guard try system.isRegularFile(backup) else { continue }
                try system.rename(backup, to: "\(vad)/\(String(name.dropLast(4)))")
                restored = true
            }
        }
        return restored
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
        // Preserve the original CodeDirectory identifier unless explicitly overridden.
        let signingIdentifier: String?
        if let identifier {
            signingIdentifier = identifier
        } else {
            signingIdentifier = try VPhoneSigner.identifier(ofFileAt: staged)
        }
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
        // The ad-hoc shape, not ldid's: TXM 187.100.3 routes a CodeDirectory
        // without the CS_ADHOC flag into a selector-24 branch that demands a
        // CMS wrapper no ad-hoc re-sign carries, and iOS 27.0.1's launchd is
        // the first binary to fall through to it (Research/Firmware/
        // txm_selector24_cms_gate.md). Apple's own platform binaries and the
        // bundle-shipped guest dylibs all carry the flag; match them.
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(
                identifier: signingIdentifier,
                entitlements: entitlements,
                mergesExisting: true,
                style: .appleAdHoc,
            ),
        )
        try system.replaceFile(path, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
    }

    private func updateTVDyld(
        identifier: String,
        enabled: Bool,
        system: VPhoneConfinedDirectory,
        work: WorkDirectory,
        cacheDirectory: URL,
        cacheRelative: String,
        priorApplied: Bool,
    ) throws -> Bool {
        let path = "usr/lib/dyld"
        let backup = "\(path).bak"
        let undoPath = "\(cacheRelative)/\(Self.dscUndoLogLeaf)"
        // A corrupt or unreadable undo record is not an absent record: never
        // overwrite it and lose the only original cache bytes.
        let undo = try system.exists(undoPath)
            ? DyldSharedCacheUndoLog.decode(system.readData(undoPath))
            : nil
        let hasUndo = undo?.patchIDs.contains(identifier) == true
        if !enabled, !priorApplied, !hasUndo { return false }
        try CustomFirmwareTVTPROInstallation.validateBackup(
            priorApplied: priorApplied, hasUndo: hasUndo,
            backupExists: system.exists(backup), backupIsRegular: system.isRegularFile(backup),
        )
        let chunks = try DyldSharedCacheChunkSet(directory: cacheDirectory, architecture: "arm64", captureUndo: enabled)
        func patchStandalone(_ staged: URL) throws {
            try CustomFirmwareTVTPRO.patchStandalone(fileAt: staged, log: { print($0) })
        }
        func patchCache(dryRun: Bool = false) throws -> Bool {
            return try CustomFirmwareTVTPRO.patchCache(in: chunks, dryRun: dryRun, log: { print($0) }).outcome == .alreadyPatched
        }
        if enabled {
            if try !system.exists(backup) { try system.copyFile(from: path, to: backup) }
            let staged = work.file("dyld-tv")
            try work.directory.removeItem("dyld-tv")
            try system.copyFile(from: backup, to: "dyld-tv", in: work.directory)
            if try patchCache(dryRun: true), !hasUndo {
                throw ValidationError("\(identifier): cached dyld is already modified but has no undo record.")
            }
            // Fully validate and re-attest the private standalone copy before
            // changing the cache; a bad signature must not leave half a pair.
            try patchStandalone(staged)
            _ = try patchCache()
            if let captured = chunks.takeUndoLog(),
               let merged = DyldSharedCacheUndoLog.updated(existing: undo, captured: captured, patchID: identifier)
            {
                try system.writeFile(undoPath, contents: merged.encoded(), mode: 0o644, owner: Self.guestOwner)
            }
            try system.replaceFile(path, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
            return true
        }
        try CustomFirmwareTVTPROInstallation.restorePair {
            guard let undo, hasUndo else { return }
            let spans = try undo.restore(patchIDs: [identifier], in: cacheDirectory, log: { print($0) })
            let attestation = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: { print($0) })
            guard attestation.isFullyAttested else {
                throw ValidationError("\(identifier): restored cache pages could not be fully re-attested; keeping the undo record.")
            }
        } restoreStandalone: {
            try system.copyFile(from: backup, to: "dyld-tv-original", in: work.directory)
            try system.replaceFile(path, fromFileAt: work.file("dyld-tv-original"), mode: 0o755, owner: Self.guestOwner)
        } retireUndo: {
            guard let undo, hasUndo else { return }
            try system.writeFile(undoPath, contents: undo.removing(patchIDs: [identifier]).encoded(), mode: 0o644, owner: Self.guestOwner)
        }
        print("  [+] \(identifier): restored standalone and cached dyld")
        return false
    }

    /// Re-seal a code-signed bundle on the mounted guest system volume.
    ///
    /// `patchMachO` re-signs the Mach-O it replaces, but a bundle's outer
    /// `_CodeSignature/CodeResources` seals the whole directory, and a guest
    /// built with the code-signing monitor kills the process that loads a
    /// bundle whose seal no longer matches its contents. Ad hoc, like every
    /// other guest binary this pipeline writes; the identifier is kept so the
    /// plugin still answers to the name it always had.
    private func sealGuestBundle(system: VPhoneConfinedDirectory, bundle: String, preserveEntitlements: Bool = false) throws {
        // No --identifier: codesign keeps the one the bundle already carries.
        var arguments = ["-f", "-s", "-", "--timestamp=none"]
        if preserveEntitlements { arguments.append("--preserve-metadata=entitlements") }
        arguments.append(try system.directory(bundle).path)
        _ = try tool("/usr/bin/codesign", arguments)
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

    /// Take `<target>.bak` from the guest's current binary before the first
    /// entitlement patch, so `revertMachO` can put the original back later. Only
    /// when `backupSafe` — no patch touching this binary was live before — so a
    /// binary that already carries the patch is never snapshotted as pristine.
    private func backupEntitlementTarget(_ target: String, in system: VPhoneConfinedDirectory, backupSafe: Bool) throws {
        guard backupSafe, try !system.exists("\(target).bak") else { return }
        try system.copyFile(from: target, to: "\(target).bak")
    }

    /// Returns whether the patch was applied (false when the binary or its
    /// entitlements are absent, so the caller does not record it live).
    @discardableResult
    private func patchDebugserver(system: VPhoneConfinedDirectory, work: WorkDirectory, backupSafe: Bool) throws -> Bool {
        let target = "usr/libexec/debugserver"
        guard let staged = try stageOptional(target, from: system, work: work, label: "debugserver") else { return false }
        guard
            let source = try VPhoneSigner.entitlements(ofFileAt: staged)
            .first(where: { !$0.isEmpty }),
            var plist = try PropertyListSerialization.propertyList(
                from: source, format: nil,
            ) as? [String: Any]
        else {
            print("[!] debugserver has no readable entitlements; patch skipped")
            return false
        }
        plist.removeValue(forKey: "seatbelt-profiles")
        plist["task_for_pid-allow"] = true
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml, options: 0,
        )
        try backupEntitlementTarget(target, in: system, backupSafe: backupSafe)
        // Replacement, not merge: `plist` is already the complete set we want,
        // and merging it back over the file's own entitlements would re-add the
        // `seatbelt-profiles` removed above — merge updates and appends keys, it
        // cannot delete one.
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(entitlements: data, style: .appleAdHoc),
        )
        try system.replaceFile(target, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
        return true
    }

    /// Returns whether the patch was applied (false when Campo or its
    /// entitlements are absent, so the caller does not record it live).
    @discardableResult
    /// BreadBoard 27.2 traps in BKSDisplayServicesStart under the 26.4
    /// temporary-sandbox profile; userprofilesd also lacks its keybag lookup.
    /// Merge only the selected service names and retain donor entitlements.
    private func patchHomeViewMachLookups(system: VPhoneConfinedDirectory, work: WorkDirectory, target: String, services: [String], backupSafe: Bool) throws {
        let name = (target as NSString).lastPathComponent
        guard let staged = try stageOptional(target, from: system, work: work, label: name),
              let source = try VPhoneSigner.entitlements(ofFileAt: staged).first(where: { !$0.isEmpty }) else {
            throw ValidationError("HomeView service access requires \(name) and its original entitlements.")
        }
        let entitlements = work.file("\(name).entitlements")
        try source.write(to: entitlements)
        try CustomFirmwareMachLookupExceptions.merge(at: entitlements, services: services)
        try backupEntitlementTarget(target, in: system, backupSafe: backupSafe)
        try VPhoneSigner.sign(fileAt: staged, options: .init(entitlements: Data(contentsOf: entitlements), style: .appleAdHoc))
        try system.replaceFile(target, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
    }

    private func patchCampo(system: VPhoneConfinedDirectory, work: WorkDirectory, backupSafe: Bool) throws -> Bool {
        let target = "Applications/Campo.app/Campo"
        guard let staged = try stageOptional(target, from: system, work: work, label: "Campo") else { return false }
        guard
            let source = try VPhoneSigner.entitlements(ofFileAt: staged)
            .first(where: { !$0.isEmpty })
        else {
            print("[!] Campo has no readable entitlements; patch skipped")
            return false
        }
        let ent = work.file("Campo.entitlements")
        try source.write(to: ent)
        try patch("patch-campo-entitlements", [ent.path])
        try backupEntitlementTarget(target, in: system, backupSafe: backupSafe)
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(
                entitlements: Data(contentsOf: ent, options: .mappedIfSafe),
                mergesExisting: true,
                style: .appleAdHoc,
            ),
        )
        try system.replaceFile(target, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
        return true
    }

    /// The cloudOS application sandbox does not include the TV service name.
    /// SetupBackground's only other entitlements are its identity, container
    /// requirement and platform bit; keep them and add just this lookup.
    private func patchTVSetupDisplayLookup(system: VPhoneConfinedDirectory, work: WorkDirectory, backupSafe: Bool) throws -> Bool {
        let target = "Applications/SetupBackground.app/SetupBackground"
        guard let staged = try stageOptional(target, from: system, work: work, label: "SetupBackground") else { return false }
        guard let source = try VPhoneSigner.entitlements(ofFileAt: staged).first(where: { !$0.isEmpty }) else {
            throw ValidationError("SetupBackground has no readable entitlements")
        }
        let ent = work.file("SetupBackground.entitlements")
        try source.write(to: ent)
        try CustomFirmwareMachLookupExceptions.merge(at: ent, services: ["com.apple.PineBoardServices"])
        try backupEntitlementTarget(target, in: system, backupSafe: backupSafe)
        try VPhoneSigner.sign(
            fileAt: staged,
            options: .init(entitlements: Data(contentsOf: ent), style: .appleAdHoc),
        )
        try system.replaceFile(target, fromFileAt: staged, mode: 0o755, owner: Self.guestOwner)
        return true
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
        let parent = try VPhoneConfinedDirectory.pin(absolutePath: workParent, requireOwner: 0)
        let parentMode = try parent.metadata().st_mode & 0o7777
        let privateDirectory = parentMode & 0o077 == 0
        let stickySharedDirectory = parentMode & 0o1777 == 0o1777
        guard privateDirectory || stickySharedDirectory else {
            throw ValidationError("The CFW work folder parent \(workParent) must be root-owned and private or sticky.")
        }
        var template = Array("\(workParent)/vphone-cfw.XXXXXXXX".utf8CString)
        // mkdtemp returns a pointer into the template. `&template` lends only a
        // temporary buffer that ends with the call, and the array is dead after
        // it, so read the name while the buffer is still pinned.
        let created = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let path = created else {
            throw ValidationError("Unable to create a private work folder in \(workParent): \(String(cString: strerror(errno)))")
        }
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
        try VPhoneConfinedDirectory.pin(absolutePath: workParent).removeItem(work.name)
    }

    private func detachImage(at mount: URL) throws {
        do {
            _ = try tool("/usr/sbin/diskutil", ["eject", mount.path], quiet: true)
        } catch {
            _ = try tool("/usr/sbin/diskutil", ["unmountDisk", "force", mount.path], quiet: true)
            _ = try tool("/usr/sbin/diskutil", ["eject", mount.path], quiet: true)
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
    @Option(name: .customLong("work-parent"), help: "Root-owned private CFW temporary directory")
    var workParent = VPhoneCustomFirmwareInstaller.defaultWorkParent

    func run() throws {
        try VPhoneCustomFirmwareInstaller(
            bundle: URL(fileURLWithPath: bundle),
            resources: VPhoneResources(base: URL(fileURLWithPath: resources)),
            workParent: workParent,
        ).run()
    }
}
