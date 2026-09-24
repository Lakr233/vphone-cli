// CryptexFilesystemPatcher.swift — CryptexFilesystemPatcher.
//
// Merge the cryptex filesystems inside the main OS filesystem.
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

/// Patcher for the Filesystem payload.
public final class CryptexFilesystemPatcher: Patcher {
    public let component = "Filesystem"
    public let restoreDir: URL
    public let verbose: Bool
    public let noBinpack: Bool
    let resources = VPhoneResources.resolve()

    var buildManiest: Data
    var rebuiltData: Data?
    var tmpDirectories: [URL] = []
    var attachedDevices: Set<String> = []

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
            fputs("warning: filesystem patch image is still attached; left VM work files in \(restoreDir.path)\n", stderr)
        }
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        [PatchRecord(
            patchID: "filesystem.cryptex.merge",
            component: "",
            fileOffset: 0,
            originalBytes: Data(),
            patchedBytes: Data(),
            description: "Merge the cryptex filesystems inside the OS filesystem",
        )]
    }

    @discardableResult
    public func apply() throws -> Int {
        print("Merging filesystems…")
        let (unencryptedImage, aeaImage) = try mergeFilesystems()
        defer {
            if attachedDevices.isEmpty {
                try? FileManager.default.removeItem(at: unencryptedImage)
            }
        }

        print("Creating trustcache…")
        let trustcachePath = try createTrustcache(filesystem: unencryptedImage)

        print("Creating mtree…")
        let didEdit = try removeSpecificSystemFiles(filesystem: unencryptedImage)
        let mtreePath = try createMtree(filesystem: unencryptedImage)

        print("Creating digest database and root hash…")
        let (digestDbPath, rootHashPath) = try createDigestAndHash(
            filesystem: unencryptedImage,
            mtree: mtreePath,
            remap: didEdit,
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
            throw FirmwarePatcher.PatcherError.patchVerificationFailed("Filesystem image is still attached")
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

        print("- Converting OS image…")
        let tmpDir = try createTmpDir()
        let targetImagePath = tmpDir.appending(path: "disk.dmg")
        do {
            try convertToRawImage(input: osDmgPath, output: targetImagePath)
            let (targetDevice, targetMount) = try attachImage(path: targetImagePath, forceRW: true)
            defer { try? detachImage(deviceNode: targetDevice) }

            print("- Merging App OS cryptex…")
            try copyCryptex(targetMount: targetMount, appOS: true)

            print("- Merging System OS cryptex…")
            try copyCryptex(targetMount: targetMount, systemOS: true)

            print("- Fixing dyld cache…")
            try addDyldSymlinks(targetMount: targetMount)

            print("- Fixing GPU driver…")
            try addGpuDriver(targetMount: targetMount)

            print("- Patching mobile activation…")
            try patchMobileActivation(targetMount: targetMount)

            print("- Adding vphoned…")
            try addVphoned(targetMount: targetMount)
            try injectLaunchDaemons(targetMount: targetMount)
            try patchLaunchdCacheLoader(targetMount: targetMount)
        }

        guard attachedDevices.isEmpty else {
            throw FirmwarePatcher.PatcherError.patchVerificationFailed("Filesystem image is still attached")
        }

        print("- Finalizing merged image…")
        try shrinkImage(dmg: targetImagePath)
        try convertToUDRWImage(input: targetImagePath, output: newDmgPath)
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
            throw FirmwarePatcher.PatcherError.patchVerificationFailed("Can patch only one at a time")
        }

        let osPath = if appOS {
            try restoreDir.appending(path: componentPath("Cryptex1,AppOS"))
        } else {
            try decryptAeaFile(restoreDir.appending(path: componentPath("Cryptex1,SystemOS")))
        }
        let (osDevice, osMount) = try attachImage(path: osPath, readonly: true)
        defer { try? detachImage(deviceNode: osDevice) }

        let destination = URL(filePath: targetMount)
            .appending(path: appOS ? "/System/Cryptexes/App" : "/System/Cryptexes/OS")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try copyImageContents(source: URL(filePath: osMount), destination: destination)
    }

    func createTmpDir() throws -> URL {
        let tmpDir = restoreDir.appending(path: ".filesystem-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: false)
        tmpDirectories.append(tmpDir)
        return tmpDir
    }
}
