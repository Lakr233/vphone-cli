// ManifestHashPatcher.swift — ManifestHashPatcher.
//
// Update the hash in the firmware manifest according to the actual hash of the corresponding files.
//

import Foundation
import CryptoKit
import Img4tool

/// Patcher for Manifest payloads.
public final class ManifestHashPatcher: Patcher {
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
            patchID: "manifest.hash",
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
            format: nil
        ) as? PlistDict else {
            throw FirmwareManifest.ManifestError.invalidPlist("")
        }
        return buildManifest
    }
    
    func applyPatches(buildManifest: PlistDict) throws -> PlistDict {
        var buildManifest = buildManifest
        guard let restoreDir else {
            throw FirmwareManifest.ManifestError.fileNotFound("Restore Directory")
        }

        // We assume that FirmwareManifest has generated the manifest containing a single build identity.
        guard let buildIdentities = buildManifest["BuildIdentities"] as? [Any],
              buildIdentities.count == 1 else {
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
            
            let componentData = try Data(contentsOf: restoreDir.appendingPathComponent(path))
            let finalData = try patchIm4pTypeTag(comp, info["Img4PayloadType"] as? String, componentData)
            let shaHash = SHA384.hash(data: finalData)
            dict["Digest"] = Data(shaHash)
            newBuildIdentityManifest[comp] = dict
        }
        
        buildIdentity["Manifest"] = newBuildIdentityManifest
        buildManifest["BuildIdentities"] = [buildIdentity]
        return buildManifest
    }
    
    private func serializePayload(_ buildManifest: PlistDict) throws -> Data {
        return try PropertyListSerialization.data(
            fromPropertyList: buildManifest,
            format: .xml,
            options: 0
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
        "Ap,RestorecL4"
    ].contains(component) else {
        return data
    }
    guard let declaredType else {
        throw FirmwareManifest.ManifestError.missingKey("Img4PayloadType in build identity component info")
    }
    return try IM4P(data).renamed(to: declaredType).data
}
