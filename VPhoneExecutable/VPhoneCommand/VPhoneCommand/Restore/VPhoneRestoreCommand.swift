import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit
import VPhoneRestore

// MARK: - Verbosity → restore logging

extension VPhoneVerbosity {
    /// What `-v` meant when the restore ran as a Python subprocess: one `-v`
    /// for `.info` (pymobiledevice3's colorful INFO), two for `.debug` and
    /// `.trace`. In process that single count becomes two knobs, and both are
    /// needed — see `restoreDebugLevel`.
    var restoreLogLevel: VPhoneRestoreLogLevel {
        self >= .debug ? .debug : .info
    }

    /// idevicerestore's own level ceiling (`-d`). Raising the console sink
    /// without raising this one prints nothing extra, because the messages it
    /// would show are never emitted.
    var restoreDebugLevel: Int32 {
        self >= .debug ? 1 : 0
    }
}

// MARK: - restore

struct VPhoneRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "DFU-restore firmware into a VM bundle (requires a running DFU boot)",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Only fetch the SHSH blob, do not restore") var getShsh = false
    @Flag(name: .shortAndLong, help: "Offline restore (decrypt AEA images in place, use the cached .shsh)")
    var offline = false
    @Option(name: .shortAndLong, help: "Device UDID (optional)") var udid: String?
    @Option(name: .shortAndLong, help: "Device ECID (default: read from the bundle's udid-prediction.txt)")
    var ecid: String?
    /// Refused: an in-place restore cannot keep a vphone guest's data. Tried on
    /// a test VM (iPhone 27.0 24A435 + cloudOS 26.4, 2026-10-05), it fails
    /// three ways, see `Research/Restore/native_restore_architecture.md`: the
    /// hybrid manifest has no Upgrade identity, so restored fails after the
    /// system volume is written; with one, the cloudOS restore ramdisk, the
    /// only one a vphone guest boots, still creates the partition map and a
    /// new system key bag, which erases the Data volume; and the iPhone's
    /// update ramdisk panics (initproc exits) on the cloudOS restore kernel.
    /// The flag stays so a script using it gets this reason, not a usage error.
    @Flag(name: .customLong("no-erase"), help: ArgumentHelp(
        "Not supported: an in-place restore erases a vphone guest's data anyway",
        visibility: .hidden,
    ))
    var noErase = false
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    /// The restore runs here now, in this process: `VPhoneRestore` over
    /// libirecovery and idevicerestore, where a python spawned with an argv
    /// used to be. A failure therefore throws instead of returning an exit
    /// code — which keeps the two halves that mattered, the non-zero exit and
    /// `restore-info.json` staying unwritten.
    func validate() throws {
        if noErase {
            throw ValidationError(
                "An in-place restore cannot keep this guest's data: restored in the cloudOS restore ramdisk recreates the partition map whatever the host asks. To change the kernel on an installed VM without erasing it, use `cfw update-kernel`.",
            )
        }
    }

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        defer {
            do { try VPhoneHostFilePermissions.makeAccessible(at: bundle.url) }
            catch { fputs("warning: could not set VM file permissions: \(error)\n", stderr) }
        }
        guard let ecidText = VPhoneRestoreOperations.resolveECID(explicit: ecid, bundle: bundle) else {
            throw VPhoneRestoreError.ecidUnresolved
        }
        let ecidValue = try VPhoneRestoreIdentity.parseECID(ecidText)
        let onEvent = VPhoneRestoreConsole.handler(level: v.restoreLogLevel)
        if v.tracesInternals {
            let ecidLabel = ecidValue.map { "0x" + VPhoneRestoreIdentity.formatECID($0) } ?? "(any attached device)"
            print("[trace] restore backend: in-process, ECID \(ecidLabel), debug level \(v.restoreDebugLevel)")
        }

        if getShsh {
            try VPhoneRestoreService.fetchSHSH(
                vmDir: bundle.url,
                ecid: ecidValue,
                udid: udid,
                out: nil,
                debugLevel: v.restoreDebugLevel,
                onEvent: onEvent,
            )
            return
        }

        var ticket: URL?
        if offline {
            let fm = FileManager.default
            let shshes = ((try? fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "shsh" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let shsh = shshes.first else { throw VPhoneRestoreError.noSHSH }
            // `VPhoneRestoreLayout.findRestoreDirectory`, not a local glob that
            // sorts and takes the first. This path used to do the latter, which
            // is Python's rule and the one the port deliberately replaced —
            // and here it was worse than either: with two firmware trees side
            // by side it decrypted one of them IN PLACE, irreversibly, and only
            // then reached the bridge, which refuses two trees and aborted. The
            // refusal has to come before anything is written.
            let restoreDir = try VPhoneRestoreLayout.findRestoreDirectory(in: bundle.url)
            print("[restore] decrypting AEA images in \(restoreDir.lastPathComponent)...")
            try VPhoneRestoreOperations.decryptAEAImages(inRestoreDir: restoreDir)
            ticket = shsh
        }

        try VPhoneRestoreService.restore(
            vmDir: bundle.url,
            ecid: ecidValue,
            udid: udid,
            erase: true,
            ticketPath: ticket,
            debugLevel: v.restoreDebugLevel,
            onEvent: onEvent,
        )
        recordRestoreVersions(bundle: bundle)
        recordRestoredPatches(bundle: bundle)
    }

    /// Snapshot the just-restored iOS + cloudOS versions to `restore-info.json`,
    /// read host-side from the bundle's restore-dir plists. Best-effort: the
    /// restore already succeeded, so a metadata miss is only a warning.
    private func recordRestoreVersions(bundle: VPhoneBundle) {
        guard let info = VPhoneRestoreInfo.derive(fromBundle: bundle) else {
            FileHandle.standardError.write(
                Data("warning: could not record restore versions (metadata not found)\n".utf8),
            )
            return
        }
        do {
            try info.write(toBundle: bundle)
            print("[restore] recorded iOS \(info.ios.version) (\(info.ios.build)) / "
                + "cloudOS \(info.cloudOS.version) (\(info.cloudOS.build))")
        } catch {
            FileHandle.standardError.write(Data("warning: could not write restore-info.json: \(error)\n".utf8))
        }
    }

    /// Record in the VM's patch receipt what the restore just flashed: the
    /// boot-chain parts `fw patch` built into the restore tree, as its
    /// `PatchPlan.plist` lists them. Every restored part is recorded, empty
    /// ones included, so a part with everything off reads as empty rather
    /// than unknown. With no plan there is nothing to say what the restore
    /// tree carried, and the receipt is left alone.
    ///
    /// Best-effort like the versions above: the restore already succeeded.
    ///
    /// The `Guest` part is recorded empty whatever the plan says: erase and
    /// `--no-erase` both re-image the system volume, so nothing `cfw install`
    /// wrote survives a restore until the next install records it again.
    private func recordRestoredPatches(bundle: VPhoneBundle) {
        let plan = VPhonePatchPresetStore.plan(forVM: bundle.url)
        let parts = plan.map { FirmwarePatchDrift.restoredParts(enabledPatches: Set($0.enabledPatches)) } ?? [:]
        do {
            try VPhonePatchPresetStore.updateReceipt(forVM: bundle.url) { receipt in
                receipt.record(
                    VPhoneVirtualMachinePatchReceipt.guestPart,
                    patches: [String](),
                    writer: "restore",
                    bundleVersion: nil,
                )
                for (component, patches) in parts {
                    receipt.record(
                        VPhoneVirtualMachinePatchReceipt.part(for: .firmware(component)),
                        patches: patches,
                        writer: "restore",
                        // No helper reads the running VPhone.bundle's version yet.
                        bundleVersion: nil,
                    )
                }
            }
            print("[restore] recorded \(parts.values.map(\.count).reduce(0, +)) boot-chain patches"
                + " in \(VPhonePatchPresetStore.receiptFileName)")
        } catch {
            FileHandle.standardError.write(Data(
                "warning: could not write \(VPhonePatchPresetStore.receiptFileName): \(error)\n".utf8,
            ))
        }
    }
}

// MARK: - recovery-probe

/// The Python bridge's `recovery-probe`, under the same name.
///
/// A standalone DFU probe. `vm create` does the same waiting in process
/// (`VPhoneVirtualMachineCreator.waitForRecovery`).
struct VPhoneRecoveryProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recovery-probe",
        abstract: "Wait briefly for a DFU/recovery endpoint; exit 0 if one answered",
    )

    @Option(name: .shortAndLong, help: "Device ECID (hex, 0x optional; default: the only device attached)")
    var ecid: String?
    @Option(name: .shortAndLong, help: "Seconds to keep probing before giving up") var timeout: Int = 2

    func run() throws {
        let device = try VPhoneRestoreService.recoveryProbe(
            ecid: VPhoneRestoreIdentity.parseECID(ecid),
            timeout: timeout,
        )
        // The Python printed nothing at all and its one caller discarded both
        // streams. One line costs that caller nothing and is the difference
        // between "it worked" and knowing which device answered.
        print("[+] \(device.productType ?? "device") in \(device.mode), "
            + "ECID 0x\(VPhoneRestoreIdentity.formatECID(device.ecid))")
    }
}

// MARK: - cfw

struct VPhoneCustomFirmwareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cfw",
        abstract: "Custom-firmware install (host-mount; VM must be off)",
        subcommands: [
            VPhoneCustomFirmwareInstallCommand.self,
            VPhoneCustomFirmwareUpdateKernelCommand.self,
            VPhoneCustomFirmwareInstallRootCommand.self,
            VPhoneCustomFirmwareUpdateEnvironmentCommand.self,
            VPhoneCustomFirmwareFlipSnapshotCommand.self,
            // The per-step patchers the installers used to reach through
            // scripts/patchers/cfw.py for — see VPhoneCustomFirmwarePatchCommand.swift.
            VPhoneCustomFirmwareCryptexPathsCommand.self,
            VPhoneCustomFirmwareInjectDaemonsCommand.self,
            VPhoneCustomFirmwareInjectDaemonCommand.self,
            VPhoneCustomFirmwarePatchDropbearPlistCommand.self,
            VPhoneCustomFirmwareInjectDylibCommand.self,
            VPhoneCustomFirmwarePatchBuildVersionCommand.self,
            VPhoneCustomFirmwarePatchLocationdCohortingCommand.self,
            VPhoneCustomFirmwarePatchTVSetupCommand.self,
            VPhoneCustomFirmwarePatchVirtualBluetoothCommand.self,
            VPhoneCustomFirmwarePatchJetsamDisableAllowedCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioGraphConfigurationsCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioSpeakerRawCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioMicrophoneChainsCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioMicrophoneGainCommand.self,
            VPhoneCustomFirmwarePatchCampoEntitlementsCommand.self,
            VPhoneCustomFirmwarePatchPostRestoreDeviceTreeCommand.self,
            VPhoneCustomFirmwarePatchBoardAudioCommand.self,
            VPhoneCustomFirmwarePatchHomePodAudioProductCommand.self,
            VPhoneCustomFirmwarePatchHomePodCryptexClassCommand.self,
            VPhoneCustomFirmwarePatchIPhoneProductCommand.self,
            VPhoneCustomFirmwarePatchFoldableVMSubtypeCommand.self,
            VPhoneCustomFirmwarePatchFoldableProductIdCommand.self,
            VPhoneCustomFirmwarePatchFoldableDisplaysCommand.self,
            VPhoneCustomFirmwarePatchHapticsCommand.self,
            VPhoneCustomFirmwarePatchMicrophoneArrayCommand.self,
        ] + VPhoneCustomFirmwareMachOVerbs.all + VPhoneCustomFirmwareDyldSharedCacheVerbs.all,
    )
}

/// Replaces `tools/apfs_snap_rename.py`, called from `cfw_install_host.sh`
/// once the install is done.
struct VPhoneCustomFirmwareFlipSnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flip-snapshot",
        abstract: "Rename the APFS root snapshot in a Disk.img so the guest boots the live volume",
        discussion: """
        Renames the com.apple.os.update-<hash> system snapshot in place, so a
        guest kernel with seal enforcement patched out cannot find the named
        root snapshot and roots the live volume instead. Offline: no mount, no
        fs_snapshot syscall, no host security change.

        Only records inside a block whose APFS checksum verifies are touched,
        so identical strings baked into on-volume binaries are left alone.

        The VM must be powered off.
        """,
    )

    @Argument(help: "Path to the VM's Disk.img", transform: URL.init(fileURLWithPath:))
    var image: URL

    @Flag(name: .customLong("dry-run"), help: "Report what would change and exit")
    var dryRun = false

    @Option(
        name: .customLong("new-prefix"),
        help: "Replacement prefix. Must be exactly as long as 'com.apple.os.update-'.",
    )
    var newPrefix: String = VPhoneAPFSSnapshot.defaultNewPrefix

    func run() throws {
        try VPhoneAPFSSnapshot.rename(imageAt: image, newPrefix: newPrefix, dryRun: dryRun)
    }
}

struct VPhoneCustomFirmwareInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install CFW into a VM bundle via host mount",
        discussion: """
        The boot chain follows the plan `fw patch` resolved; the guest half —
        the dyld cache, the guest Mach-Os and files, the entitlements and the
        Preboot device tree — follows the VM's current patch selection, both
        ways, so a `fw set-patches` since the last `fw patch` takes effect here
        and a patch turned off is reverted from its backup. Records the guest
        half of the patch receipt (PatchReceipt.plist) on success.

        Needs a prepared restore tree and root; the VM must be powered off.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(
        name: .customLong("keep-artifacts"),
        help: "Keep the extracted firmware after install (default: removed to save space)",
    )
    var keepArtifacts = false
    @Option(name: .customLong("work-parent"), help: "Root-owned private CFW temporary directory")
    var workParent = VPhoneCustomFirmwareInstaller.defaultWorkParent

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = VPhoneResources.resolve()

        let code = try VPhoneCustomFirmwareInstaller.elevate(
            bundle: bundle.url,
            resources: resources,
            workParent: workParent,
        )
        if code == 0 {
            try recordInstall(in: bundle)
        }
        throw ExitCode(code)
    }

    /// Host bookkeeping in the caller's VM folder. Under sudo or the
    /// Launchpad helper this runs with the invoking user's credentials, so
    /// the kernel applies that user's permissions: a link planted in the
    /// folder can only lead where the user could already write.
    private func recordInstall(in bundle: VPhoneBundle) throws {
        let keepArtifacts = keepArtifacts
        let record = {
            let receipt = VPhonePatchPresetStore.receipt(forVM: bundle.url)
            let metadataData = try? Data(contentsOf: bundle.url.appendingPathComponent(VPhoneOTAArchive.userlandDirectoryName)
                .appendingPathComponent("Upgrade.plist"))
            let metadata = metadataData.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] }
            if receipt?.parts[VPhoneVirtualMachinePatchReceipt.guestPart]?.patches.contains(FirmwareGuestSystemPatchSet.otaUserland) == true,
               let target = VPhoneRestoreInfo.derive(fromBundle: bundle),
               metadata?["Build"] == target.ios.build, metadata?["Version"] == target.ios.version {
                try VPhoneRestoreInfo(ios: target.ios, cloudOS: target.cloudOS, variant: "jb", device: bundle.manifest.guestProductType)
                    .write(toBundle: bundle)
                print("[cfw] recorded full OTA userland \(target.ios.version) (\(target.ios.build))")
            } else if let info = try? VPhoneRestoreInfo.recordVariant("jb", toBundle: bundle), info.variant != nil {
                print("[cfw] recorded variant jb, device \(info.device ?? "?")")
            }
            if !keepArtifacts, let removed = try? VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: bundle) {
                print("[cfw] removed built firmware \(removed)/ to save space (--keep-artifacts to keep)")
            }
        }
        guard geteuid() == 0, let invokingUser = VPhoneInvokingUser.current else {
            try record()
            return
        }
        do {
            try invokingUser.withUserCredentials(record)
        } catch {
            // Never fall back to doing this as root.
            fputs("warning: skipped recording the install in \(bundle.url.path): \(error)\n", stderr)
        }
    }
}

/// Redeploy this bundle's guest payload into a VM that is already installed.
///
/// The gap it fills: `cfw install` needs a prepared restore tree, and the
/// restore tree is deleted once a VM has booted. So until now an existing
/// machine could not be given an updated vphoned or guest dylib at all — and
/// replacing a library in a running guest over the API cannot help either,
/// because a daemon keeps the copy it mapped at launch.
///
/// It applies the whole guest half of an install against an installed VM,
/// without the restore tree: the dyld cache verbs, every guest Mach-O and file
/// patch, the entitlement patches and the Preboot device-tree repairs, matched
/// to the VM's current selection both ways. A patch the owner has turned off is
/// reverted — a Mach-O or file from its backup, the device tree to its backup,
/// a dyld patch from the undo log the install recorded. The two steps that need
/// the restore tree, the cryptex copy and the GPU bundle, are skipped (an
/// installed guest already carries both); the recorded `jb` variant is left
/// alone. A VM that was never installed is refused rather than half-filled.
struct VPhoneCustomFirmwareUpdateKernelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-kernel",
        abstract: "Replace an installed VM's Preboot kernelcache without erasing its data (VM must be off)",
        discussion: """
        Replaces the kernel the guest boots with one re-patched from the VM's
        current selection, keeping every volume. The booting kernelcache lives
        in Preboot as an IMG4; iBoot accepts a modified IM4P under the original
        signed IM4M — the same image4 bypass that lets `cfw install` rewrite the
        Preboot device tree — so this replaces the kernelcache's payload and
        nothing else. No volume is reformatted, so the guest's data survives. It
        is the one boot-chain change that reaches an installed guest without a
        restore, which always erases (see `restore --no-erase`).

        The kernelcache is re-patched from the pristine copy kept in
        FirmwareOriginals, so no restore tree and no prior `fw patch` is needed:
        change the selection with `fw set-patches` (or the Launchpad patch
        editor), then run this. Needs root, and the VM must be powered off.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .customLong("work-parent"), help: "Root-owned private CFW temporary directory")
    var workParent = VPhoneCustomFirmwareInstaller.defaultWorkParent

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let code = try VPhoneCustomFirmwareInstaller.elevate(
            bundle: bundle.url,
            resources: VPhoneResources.resolve(),
            mode: .kernelUpdate,
            workParent: workParent,
        )
        throw ExitCode(code)
    }
}

struct VPhoneCustomFirmwareUpdateEnvironmentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-environment",
        abstract: "Match an installed VM's guest patches to its current selection (VM must be off)",
        discussion: """
        Re-applies the guest half of an install from the VM's current patch
        selection, without the restore tree. vphoned, its launch daemon, the
        guest dylibs and the libmisfix defaults are redeployed as before; on top
        of that, every guest Mach-O, file, entitlement, dyld-cache and Preboot
        device-tree patch is brought to match the selection — turned on if the
        owner has selected it since the last install, and reverted from its
        backup or the dyld undo log if the owner has turned it off. Records the
        guest half of the patch receipt (PatchReceipt.plist) on success.

        A dyld-cache patch on a VM installed before the undo log existed cannot
        be reverted and is reported and left in place. The cryptex copy and the
        GPU bundle are skipped (they need the restore tree; an installed guest
        has them already), and the VM's recorded variant does not change.

        An iPad VM's audio repair needs the iPad's own DeviceTree.<board>.im4p
        in the VM's FirmwareOriginals. When a VM patched by an older build has
        none, it is recovered from the VM's IPSW in ~/.vphone/ipsws (matched by
        its BuildManifest) and kept there; without that IPSW the repair is
        skipped with a [!] line naming the fix.

        Use it to move an existing VM onto a newer bundle, or to apply a
        `fw set-patches` change, without rebuilding it. Needs root, and the VM
        must be powered off.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .customLong("work-parent"), help: "Root-owned private CFW temporary directory")
    var workParent = VPhoneCustomFirmwareInstaller.defaultWorkParent

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let code = try VPhoneCustomFirmwareInstaller.elevate(
            bundle: bundle.url,
            resources: VPhoneResources.resolve(),
            mode: .environmentOnly,
            workParent: workParent,
        )
        throw ExitCode(code)
    }
}
