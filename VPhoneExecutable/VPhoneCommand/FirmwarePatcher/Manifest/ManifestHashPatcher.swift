// ManifestHashPatcher.swift — ManifestHashPatcher.
//
// Update the hash in the firmware manifest according to the actual hash of the corresponding files.
//

import CryptoKit
import Foundation
import Img4tool
import VPhoneCoreKit
import VPhonePatchKit

/// Patcher for Manifest payloads.
public final class ManifestHashPatcher: BufferedPatcher {
    public let component = "Manifest"
    public let restoreDir: URL?
    public let verbose: Bool

    let buffer: BinaryBuffer
    var patches: [PatchRecord] = []
    var rebuiltData: Data?

    // MARK: - Init

    public init(data: Data, restoreDir: URL?, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.restoreDir = restoreDir
        self.verbose = verbose
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        rebuiltData = nil
        let root = try parsePayload(buffer.data)
        let newRoot = try applyPatches(buildManifest: root)
        rebuiltData = try serializePayload(newRoot)

        patches = [PatchRecord(
            patchID: FirmwareRestoreImagePatchSet.digestRehash,
            component: "",
            fileOffset: 0,
            originalBytes: Data(),
            patchedBytes: Data(),
            description: "Updated the file hashes according to the actual files",
        )]
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty {
            let _ = try findAll()
        }
        if let rebuiltData {
            buffer.data = rebuiltData
        } else {
            throw PatcherError.patchSiteNotFound("ManifestHash")
        }
        return patches.count
    }

    /// Get the patched data.
    public var patchedData: Data {
        buffer.data
    }

    private func parsePayload(_ blob: Data) throws -> PlistDict {
        guard let buildManifest = try PropertyListSerialization.propertyList(
            from: blob,
            options: [],
            format: nil,
        ) as? PlistDict else {
            throw FirmwareManifest.ManifestError.invalidPlist("BuildManifest.plist")
        }
        return buildManifest
    }

    func applyPatches(buildManifest: PlistDict) throws -> PlistDict {
        var buildManifest = buildManifest
        guard let restoreDir else {
            throw FirmwareManifest.ManifestError.fileNotFound("the restore directory")
        }

        // We assume that FirmwareManifest has generated the manifest containing a single build identity.
        guard let buildIdentities = buildManifest["BuildIdentities"] as? [Any],
              buildIdentities.count == 1
        else {
            throw FirmwareManifest.ManifestError.missingKey("BuildIdentities in BuildManifest")
        }
        guard var buildIdentity = buildIdentities.first! as? PlistDict else {
            throw FirmwareManifest.ManifestError.missingKey("BuildIdentity in BuildIdentities")
        }
        guard let identityManifest = buildIdentity["Manifest"] as? PlistDict else {
            throw FirmwareManifest.ManifestError.missingKey("Manifest in BuildIdentity")
        }

        var newBuildIdentityManifest = PlistDict()
        for (comp, dict) in identityManifest {
            guard var dict = dict as? PlistDict else {
                throw FirmwareManifest.ManifestError.missingKey("component in build identity")
            }
            guard let info = dict["Info"] as? PlistDict else {
                throw FirmwareManifest.ManifestError.missingKey("Info in build identity component")
            }
            guard let path = info["Path"] as? String else {
                throw FirmwareManifest.ManifestError.missingKey("Path in build identity component info")
            }

            let componentURL = restoreDir.appendingPathComponent(path)
            if try Self.isAEA(componentURL) {
                // Apple's manifests hash the decrypted image of an AEA-wrapped
                // component, and an 18.x restore verifies the image it wrote
                // against that digest ("read-back digest verification failed").
                dict["Digest"] = try decryptedDigest(of: componentURL, in: restoreDir)
                newBuildIdentityManifest[comp] = dict
                continue
            }
            // Mapped, not read. This loop hashes every component the build
            // identity names, and that list includes `OS` — the filesystem
            // DMG, which is ten gigabytes. Reading it meant holding all of it
            // while SHA384 walked it; mapping means the kernel pages it in
            // ahead of the hash and evicts behind it.
            let componentData = try Data(
                contentsOf: componentURL,
                options: .mappedIfSafe,
            )
            let finalData = try patchIm4pTypeTag(comp, info["Img4PayloadType"] as? String, componentData)
            let shaHash = SHA384.hash(data: finalData)
            dict["Digest"] = Data(shaHash)
            newBuildIdentityManifest[comp] = dict
        }

        buildIdentity["Manifest"] = newBuildIdentityManifest
        buildManifest["BuildIdentities"] = [buildIdentity]
        return buildManifest
    }

    static func isAEA(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 4) == Data("AEA1".utf8)
    }

    /// The SHA-384 of an AEA archive's decrypted payload, decrypted with
    /// `/usr/bin/aea` beside the restore tree and hashed in chunks.
    private func decryptedDigest(of url: URL, in restoreDir: URL) throws -> Data {
        let work = restoreDir.appending(path: ".manifest-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let plain = work.appending(path: "payload")
        let key = try vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: url) }
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/aea"),
            ["decrypt", "-i", url.path, "-o", plain.path, "-key-value", key],
        )
        guard result.succeeded else {
            throw PatcherError.invalidFormat("Unable to decrypt \(url.lastPathComponent): \(result.stderr)")
        }
        if verbose {
            VPhoneConsole.shared.line("  [manifest] hashed the decrypted \(url.lastPathComponent)", .note)
        }

        var hasher = SHA384()
        let handle = try FileHandle(forReadingFrom: plain)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 64 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private func serializePayload(_ buildManifest: PlistDict) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: buildManifest,
            format: .xml,
            options: 0,
        )
    }
}

func patchIm4pTypeTag(_ component: String, _ declaredType: String?, _ data: Data) throws -> Data {
    guard [
        "RestoreKernelCache",
        "RestoreDeviceTree",
        "RestoreSEP",
        "RestoreLogo",
        "RestoreTrustCache",
        "RestoreDCP",
        "Ap,RestoreDCP2",
        "Ap,RestoreTMU",
        "Ap,RestoreCIO",
        "Ap,DCP2",
        "Ap,RestoreSecureM3Firmware",
        "Ap,RestoreSecurePageTableMonitor",
        "Ap,RestoreTrustedExecutionMonitor",
        "Ap,RestorecL4",
    ].contains(component) else {
        return data
    }
    guard let declaredType else {
        throw FirmwareManifest.ManifestError.missingKey("Img4PayloadType in build identity component info")
    }
    return try IM4P(data).renamed(to: declaredType).data
}
