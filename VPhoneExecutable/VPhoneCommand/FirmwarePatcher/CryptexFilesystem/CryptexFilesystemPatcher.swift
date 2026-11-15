// CryptexFilesystemPatcher.swift — CryptexFilesystemPatcher.
//
// Merge the cryptex filesystems inside the main OS filesystem.
//
// A watchOS image has no cryptexes: its dyld caches are in the OS image, and
// only the guest payload is added before the seal.
//
// 1. Collect the AppOS and SystemOS Cryptex from the iPhone BuildManifest
// 2. With the OS, AppOS, and SystemOS images, attach them and copy them to a target image
// 3. Create trustcache for resulting image
// 4. Create mtree for resulting image
// 5. Generate digest.db and SystemVolume root_hash
// 6. Join mtree and digest.db to Ap,SystemVolumeCanonicalMetadata
//
// The supporting steps live beside this file: CryptexFilesystemPatcherGuestPayload.swift,
// CryptexFilesystemPatcherSealing.swift, CryptexFilesystemPatcherManifest.swift,
// CryptexFilesystemPatcherAEA.swift, CryptexFilesystemPatcherDiskImage.swift and
// CryptexFilesystemPatcherProcess.swift.

import CryptoKit
import Foundation
import Img4tool
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit

/// Patcher for the Filesystem payload.
public final class CryptexFilesystemPatcher: BufferedPatcher {
    public let component = "Filesystem"
    public let restoreDir: URL
    public let verbose: Bool
    public let noBinpack: Bool
    let resources = VPhoneResources.resolve()
    public var gate: VPhonePatchGate = .unrestricted

    var buildManiest: Data
    var rebuiltData: Data?
    /// The guest's `VPhoneGuestDevice.Family`, from the preserved iPhone manifest.
    lazy var guestFamily = VPhoneGuestDevice.Family(rawValue: FirmwarePipeline.guestFamily(restoreDir: restoreDir)) ?? .iPhone
    var tmpDirectories: [URL] = []
    var attachedDevices: Set<String> = []
    /// The CDHashes of each binary the merge signed again, mapped to the ones
    /// it had in the IPSW, so it keeps Apple's constraint category.
    var resignedCDHashes: [Data: [Data]] = [:]

    // MARK: - Init

    public init(
        buildManiest: Data,
        restoreDir: URL,
        verbose: Bool = true,
        noBinpack: Bool = false,
    ) {
        self.buildManiest = buildManiest
        self.restoreDir = restoreDir
        self.verbose = verbose
        self.noBinpack = noBinpack
    }

    deinit {
        for device in Array(attachedDevices) {
            try? detachImage(deviceNode: device)
        }
        if attachedDevices.isEmpty {
            for tmp in tmpDirectories {
                try? FileManager.default.removeItem(at: tmp)
            }
        } else {
            VPhoneConsole.shared.line("warning: filesystem patch image is still attached; left VM work files in \(restoreDir.path)", .warning, to: .error)
        }
    }

    // MARK: - Patcher

    /// Whether this step has anything to do on the system being merged. A step
    /// the gate allows but this image has no use for is left out of the records
    /// rather than reported as applied.
    func applies(_ identifier: String) -> Bool {
        switch identifier {
        case FirmwareRestoreImagePatchSet.surfaceCompression: isIOS18
        case FirmwareRestoreImagePatchSet.watchAudio: guestFamily == .watch
        case FirmwareRestoreImagePatchSet.trustedDarwinOS: guestFamily == .iPhone || guestFamily == .iPad
        // Tried on iPhone and iPad guests only; a watch keeps its customer release type.
        case FirmwareRestoreImagePatchSet.internalReleaseType: guestFamily == .iPhone || guestFamily == .iPad
        default: true
        }
    }

    /// One record per step the gate lets through. The merge itself is the
    /// patcher: the pipeline builds it only when the merge is on.
    public func findAll() throws -> [PatchRecord] {
        Self.steps.filter { gate.isEnabled($0.identifier) && applies($0.identifier) }.map { step in
            PatchRecord(
                patchID: step.identifier,
                component: "",
                fileOffset: 0,
                originalBytes: Data(),
                patchedBytes: Data(),
                description: step.description,
            )
        }
    }

    static let steps: [(identifier: String, description: String)] = [
        (FirmwareRestoreImagePatchSet.cryptexMerge, "Merge the cryptex filesystems inside the OS filesystem"),
        (FirmwareRestoreImagePatchSet.gpuDriver, "Install the paravirtual GPU driver"),
        (FirmwareRestoreImagePatchSet.surfaceCompression, "Turn off CoreAnimation's surface compression (iOS 18)"),
        (FirmwareRestoreImagePatchSet.mobileActivation, "Patch mobileactivationd"),
        (FirmwareRestoreImagePatchSet.vphoned, "Install vphoned and its launch daemon"),
        (FirmwareRestoreImagePatchSet.launchdCacheLoader, "Patch launchd_cache_loader"),
        (FirmwareRestoreImagePatchSet.virtualBluetooth, "Enable LE connections over the virtual Bluetooth controller"),
        (FirmwareRestoreImagePatchSet.watchAudio, "Install the virtio sound HAL plugin for a watch"),
        (FirmwareRestoreImagePatchSet.debugserver, "Re-sign debugserver so it can attach in the guest"),
        (FirmwareRestoreImagePatchSet.launchdJetsam, "Patch launchd's jetsam panic guard"),
        (FirmwareRestoreImagePatchSet.trustedDarwinOS, "Restore as trusted darwinOS and add cryptexctl"),
        (FirmwareRestoreImagePatchSet.internalReleaseType, "Mark the release Internal for offline app authorization"),
    ]

    /// Whether this guest is restored as trusted darwinOS.
    var trustedDarwinOS: Bool {
        gate.isEnabled(FirmwareRestoreImagePatchSet.trustedDarwinOS)
            && applies(FirmwareRestoreImagePatchSet.trustedDarwinOS)
    }

    @discardableResult
    public func apply() throws -> Int {
        VPhoneConsole.shared.line("Merging filesystems…", .step)
        let (unencryptedImage, aeaImage) = try mergeFilesystems()
        defer {
            if attachedDevices.isEmpty {
                try? FileManager.default.removeItem(at: unencryptedImage)
            }
        }

        VPhoneConsole.shared.line("Creating trustcache…", .step)
        let trustcachePath = try createTrustcache(filesystem: unencryptedImage)

        VPhoneConsole.shared.line("Creating mtree…", .step)
        // The restore gets the image as encrypted above, so whatever changes
        // from here on is what its mtree finds different (see parseEditTime).
        let editStart = Date()
        let didEdit = try removeSpecificSystemFiles(filesystem: unencryptedImage)
        let mtreePath = try createMtree(filesystem: unencryptedImage)

        VPhoneConsole.shared.line("Creating digest database and root hash…", .step)
        // The merged image was shrunk to its minimum size. With a remap,
        // apfs_sealvolume copies the whole fsroot tree first and fails with
        // ENOSPC (exit 65) in the space that is left.
        try growImage(dmg: unencryptedImage, by: Self.sealHeadroom)
        let (digestDbPath, rootHashPath) = try createDigestAndHash(
            filesystem: unencryptedImage,
            mtree: mtreePath,
            remap: didEdit,
            editedSince: editStart,
        )
        let metadataPath = try compressCanonicalMetadata(mtree: mtreePath, digestDb: digestDbPath)
        let rootHashContainer = try wrapRootHash(rootHashPath)

        // update trustcache, metadata, root_hash path
        let updatedManifest = try setUpdatedComponentsInManifest(
            filesystem: aeaImage,
            trustcache: trustcachePath,
            metadata: metadataPath,
            rootHash: rootHashContainer,
        )
        rebuiltData = try serializePayload(updatedManifest)

        guard attachedDevices.isEmpty else {
            throw VPhonePatchKit.PatcherError.patchVerificationFailed("The filesystem image is still attached. Detach it, then try again.")
        }

        return 1
    }

    /// Get the patched data.
    public var patchedData: Data {
        rebuiltData!
    }

    /// mergeFilesystems merges the main OS filesystem with the Cryptexes filesystems.
    /// It returns the path of the merged image (plain and encrypted)
    func mergeFilesystems() throws -> (URL, URL) {
        let osPath = try componentPath("OS")
        let osDmgPath = try decryptAeaFile(restoreDir.appending(path: osPath))
        let newDmgPath = restoreDir.appending(path: "new-filesystem.dmg")

        VPhoneConsole.shared.line("- Converting OS image…", .step)
        let tmpDir = try createTmpDir()
        let targetImagePath = tmpDir.appending(path: "disk.dmg")
        do {
            try convertToRawImage(input: osDmgPath, output: targetImagePath)
            // The decrypted OS image is only the conversion's input. Gone now,
            // its ~7 GB are free for the merge, which on a nearly full disk
            // otherwise runs out of room (iOS 18.6 22G86 with 24 GB free).
            try? FileManager.default.removeItem(at: osDmgPath)
            let (targetDevice, targetMount) = try attachImage(path: targetImagePath, forceRW: true)
            defer { try? detachImage(deviceNode: targetDevice) }

            if guestFamily != .watch {
                VPhoneConsole.shared.line("- Merging App OS cryptex…", .step)
                try copyCryptex(targetMount: targetMount, appOS: true)

                VPhoneConsole.shared.line("- Merging System OS cryptex…", .step)
                try copyCryptex(targetMount: targetMount, systemOS: true)

                VPhoneConsole.shared.line("- Fixing dyld cache…", .step)
                try addDyldSymlinks(targetMount: targetMount)
            }

            if gate.isEnabled(FirmwareRestoreImagePatchSet.gpuDriver) {
                VPhoneConsole.shared.line("- Fixing GPU driver…", .step)
                try addGpuDriver(targetMount: targetMount)
            }
            if gate.isEnabled(FirmwareRestoreImagePatchSet.surfaceCompression), isIOS18 {
                VPhoneConsole.shared.line("- Turning off CoreAnimation's surface compression (iOS 18)…", .step)
                try addCoreAnimationDefaults(targetMount: targetMount)
            }

            if gate.isEnabled(FirmwareRestoreImagePatchSet.mobileActivation) {
                VPhoneConsole.shared.line("- Patching mobile activation…", .step)
                try patchMobileActivation(targetMount: targetMount)
            }

            if gate.isEnabled(FirmwareRestoreImagePatchSet.vphoned) {
                VPhoneConsole.shared.line("- Adding vphoned…", .step)
                try addVphoned(targetMount: targetMount)
                try injectLaunchDaemons(targetMount: targetMount)
            }
            if gate.isEnabled(FirmwareRestoreImagePatchSet.launchdCacheLoader) {
                try patchLaunchdCacheLoader(targetMount: targetMount)
            }
            if gate.isEnabled(FirmwareRestoreImagePatchSet.virtualBluetooth) {
                try editGuestFile(CustomFirmwareBluetoothVirtualController.relativePath, targetMount: targetMount, mode: 0o644) { file in
                    try CustomFirmwareBluetoothVirtualController.patch(at: file)
                }
                VPhoneConsole.shared.line("  [+] \(CustomFirmwareBluetoothVirtualController.feature) on", .note)
            }
            if gate.isEnabled(FirmwareRestoreImagePatchSet.watchAudio), applies(FirmwareRestoreImagePatchSet.watchAudio) {
                VPhoneConsole.shared.line("- Adding the watch speaker…", .step)
                try addWatchAudio(targetMount: targetMount)
                try patchWatchAudioBudget(targetMount: targetMount)
            }
            if gate.isEnabled(FirmwareRestoreImagePatchSet.debugserver) {
                VPhoneConsole.shared.line("- Re-signing debugserver for in-guest attach…", .step)
                try patchDebugserver(targetMount: targetMount)
            }
            if gate.isEnabled(FirmwareRestoreImagePatchSet.launchdJetsam) {
                VPhoneConsole.shared.line("- Patching launchd's jetsam panic guard…", .step)
                try patchLaunchdJetsam(targetMount: targetMount)
            }
            if trustedDarwinOS {
                VPhoneConsole.shared.line("- Adding cryptexctl for trusted darwinOS…", .step)
                try addCryptexctl(targetMount: targetMount)
            }
            if gate.isEnabled(FirmwareRestoreImagePatchSet.internalReleaseType), applies(FirmwareRestoreImagePatchSet.internalReleaseType) {
                print("- Marking the release Internal for offline app authorization…")
                try markInternalReleaseType(targetMount: targetMount)
            }
            try removeHostEventLog(mount: targetMount)
        }

        guard attachedDevices.isEmpty else {
            throw VPhonePatchKit.PatcherError.patchVerificationFailed("The filesystem image is still attached. Detach it, then try again.")
        }

        VPhoneConsole.shared.line("- Finalizing merged image…", .step)
        try shrinkImage(dmg: targetImagePath)
        try convertToUDRWImage(input: targetImagePath, output: newDmgPath)
        try? FileManager.default.removeItem(at: targetImagePath)
        let metadata = try getAeaMetadata(restoreDir.appending(path: osPath))
        let key = try getAeaKey(restoreDir.appending(path: osPath), metadata: metadata)
        let finalFile = newDmgPath.appendingPathExtension("aea")
        let finalDestination = restoreDir.appending(path: finalFile.lastPathComponent)
        if FileManager.default.fileExists(atPath: finalDestination.path) {
            try FileManager.default.removeItem(at: finalDestination)
        }
        try encryptAeaFile(newDmgPath, output: finalFile, key: key, metadata: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: finalDestination.path)
        return (newDmgPath, finalDestination)
    }

    func copyCryptex(targetMount: String, appOS: Bool = false, systemOS: Bool = false) throws {
        guard appOS || systemOS, !(appOS && systemOS) else {
            throw VPhonePatchKit.PatcherError.patchVerificationFailed("Specify exactly one cryptex to copy: AppOS or SystemOS.")
        }

        let osPath = if appOS {
            try restoreDir.appending(path: componentPath("Cryptex1,AppOS"))
        } else {
            try decryptAeaFile(restoreDir.appending(path: componentPath("Cryptex1,SystemOS")))
        }
        // The System OS image is a decrypted copy; drop it once detached.
        defer { if systemOS { try? FileManager.default.removeItem(at: osPath) } }
        let (osDevice, osMount) = try attachImage(path: osPath, readonly: true)
        defer { try? detachImage(deviceNode: osDevice) }

        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let relative = appOS ? "System/Cryptexes/App" : "System/Cryptexes/OS"
        try target.removeItem(relative)
        try target.directory(relative, create: true)
        try copyImageContents(source: URL(filePath: osMount), destination: URL(filePath: targetMount).appending(path: relative))
    }

    func createTmpDir() throws -> URL {
        let tmpDir = restoreDir.appending(path: ".filesystem-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: false)
        tmpDirectories.append(tmpDir)
        return tmpDir
    }
}
