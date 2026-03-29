
// 1. Collect the AppOS and SystemOS Cryptex from the iPhone BuildManifest
// 2. With the OS, AppOS, and SystemOS images, attach them and copy them to a target image
// 3. Create mtree for resulting image
// 4. Download apfs_sealvolume
// 5. Generate digest.db
// 6. Join mtree and digest.db to Ap,SystemVolumeCanonicalMetadata
// 7. Create SystemVolume root_hash

import Foundation
import CryptoKit
import Img4tool

/// Patcher for DeviceTree payloads.
public final class CryptexFilesystemPatcher: Patcher {
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
}
