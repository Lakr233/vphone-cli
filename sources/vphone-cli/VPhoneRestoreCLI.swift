import ArgumentParser
import Foundation
import VPhoneCore
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
    /// The Python exposed this as `--erase/--no-erase`, defaulting to erase, and
    /// `VPhoneRestoreOptions.erase` has carried it since the port. Only the flag
    /// was missing, which left `Behavior.Update` reachable from the library and
    /// its unit test but not from the command line.
    @Flag(name: .customLong("no-erase"), help: "Update in place instead of erasing (upstream's Behavior.Update)")
    var noErase = false
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    /// The restore runs here now, in this process: `VPhoneRestore` over
    /// libirecovery and idevicerestore, where a python spawned with an argv
    /// used to be. A failure therefore throws instead of returning an exit
    /// code — which keeps the two halves that mattered, the non-zero exit and
    /// `restore-info.json` staying unwritten.
    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        guard let ecidText = VPhoneRestoreOps.resolveECID(explicit: ecid, bundle: bundle) else {
            throw VPhoneRestoreError.ecidUnresolved
        }
        let ecidValue = try VPhoneRestoreIdentity.parseECID(ecidText)
        let onEvent = VPhoneRestoreConsole.handler(level: v.restoreLogLevel)
        if v.tracesInternals {
            let ecidLabel = ecidValue.map { "0x" + VPhoneRestoreIdentity.formatECID($0) } ?? "(any attached device)"
            print("[trace] restore backend: in-process, ECID \(ecidLabel), debug level \(v.restoreDebugLevel)")
        }

        if getShsh {
            try VPhoneRestoreBridge.fetchSHSH(
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
            try VPhoneRestoreOps.decryptAEAImages(inRestoreDir: restoreDir)
            ticket = shsh
        }

        try VPhoneRestoreBridge.restore(
            vmDir: bundle.url,
            ecid: ecidValue,
            udid: udid,
            erase: !noErase,
            ticketPath: ticket,
            debugLevel: v.restoreDebugLevel,
            onEvent: onEvent,
        )
        recordRestoreVersions(bundle: bundle)
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
}

// MARK: - recovery-probe

/// The Python bridge's `recovery-probe`, under the same name.
///
/// A standalone DFU probe. `vm create` does the same waiting in process
/// (`VPhoneCreateOrchestrator.waitForRecovery`).
struct VPhoneRecoveryProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recovery-probe",
        abstract: "Wait briefly for a DFU/recovery endpoint; exit 0 if one answered",
    )

    @Option(name: .shortAndLong, help: "Device ECID (hex, 0x optional; default: the only device attached)")
    var ecid: String?
    @Option(name: .shortAndLong, help: "Seconds to keep probing before giving up") var timeout: Int = 2

    func run() throws {
        let device = try VPhoneRestoreBridge.recoveryProbe(
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

struct VPhoneCFWCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cfw",
        abstract: "Custom-firmware install (host-mount; VM must be off; re-execs sudo)",
        subcommands: [
            VPhoneCFWInstallCommand.self,
            VPhoneCFWInstallRootCommand.self,
            VPhoneCFWFlipSnapshotCommand.self,
            // The per-step patchers the installers used to reach through
            // scripts/patchers/cfw.py for — see VPhoneCFWPatchCLI.swift.
            VPhoneCFWCryptexPathsCommand.self,
            VPhoneCFWInjectDaemonsCommand.self,
            VPhoneCFWInjectDaemonCommand.self,
            VPhoneCFWPatchDropbearPlistCommand.self,
            VPhoneCFWInjectDylibCommand.self,
            VPhoneCFWPatchBuildVersionCommand.self,
            VPhoneCFWPatchCampoEntitlementsCommand.self,
            VPhoneCFWPatchPostRestoreDTCommand.self,
        ] + VPhoneCFWMachOVerbs.all + VPhoneCFWDSCVerbs.all,
    )
}

/// Replaces `tools/apfs_snap_rename.py`, called from `cfw_install_host.sh`
/// once the install is done.
struct VPhoneCFWFlipSnapshotCommand: ParsableCommand {
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

struct VPhoneCFWInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install CFW into a VM bundle via host mount",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(
        name: .customLong("force-dsc-maxslide"),
        help: "Zero the dyld cache maxSlide on non-27 bases (opt-in DSC-map fit)",
    )
    var forceDSCMaxSlide = false
    @Flag(
        name: .customLong("root-popup"),
        help: "Elevate via macOS's native authentication dialog (osascript) instead of the sudo re-exec",
    )
    var rootPopup = false
    @Flag(
        name: .customLong("keep-artifacts"),
        help: "Keep the extracted firmware after install (default: removed to save space)",
    )
    var keepArtifacts = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()

        let code = try VPhoneCFWInstaller.elevate(
            bundle: bundle.url, resources: resources,
            forceDSCMaxSlide: forceDSCMaxSlide, rootPopup: rootPopup,
            verbose: v.showsToolDetail,
        )
        if code == 0 {
            if let info = try? VPhoneRestoreInfo.recordVariant("jb", toBundle: bundle), info.variant != nil {
                print("[cfw] recorded variant jb, device \(info.device ?? "?")")
            }
            if !keepArtifacts, let removed = try? VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: bundle) {
                print("[cfw] removed built firmware \(removed)/ to save space (--keep-artifacts to keep)")
            }
        }
        throw ExitCode(code)
    }
}
