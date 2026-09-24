// CryptexFilesystemPatcherManifest.swift — BuildManifest reading and rewriting.
//
// Split out of CryptexFilesystemPatcher.swift. Plist parsing helpers, component path lookup,
// and the rewrite that points OS, StaticTrustCache, Ap,SystemVolumeCanonicalMetadata and
// SystemVolume at the freshly built payloads.

import Foundation

extension CryptexFilesystemPatcher {
    func serializePayload(_ buildManifest: PlistDict) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: buildManifest,
            format: .xml,
            options: 0,
        )
    }

    func setUpdatedComponentsInManifest(
        filesystem: URL,
        trustcache: URL,
        metadata: URL,
        rootHash: URL,
    ) throws -> PlistDict {
        var root = try parsePlist(data: buildManiest)
        guard var buildIdentities = root["BuildIdentities"] as? [Any],
              buildIdentities.count > 0,
              var buildIdentity = buildIdentities.first! as? PlistDict
        else {
            throw FirmwareManifest.ManifestError.missingKey("Component in BuildManifest")
        }
        var identityManifest = try getChildPlistDict(parent: buildIdentity, key: "Manifest")

        // We assume that the filesystem is already placed in the restore directory.
        identityManifest = try updateManifestComponentPath(
            identityManifest: identityManifest,
            component: "OS",
            at: filesystem,
        )

        let newTrustcachePath = restoreDir.appending(path: "Firmware").appending(path: trustcache.lastPathComponent)
        if trustcache != newTrustcachePath, FileManager.default.fileExists(atPath: newTrustcachePath.path) {
            try FileManager.default.removeItem(at: newTrustcachePath)
        }
        try FileManager.default.moveItem(at: trustcache, to: newTrustcachePath)
        identityManifest = try updateManifestComponentPath(
            identityManifest: identityManifest,
            component: "StaticTrustCache",
            at: newTrustcachePath,
        )

        let newMetadataPath = restoreDir.appending(path: "Firmware").appending(path: metadata.lastPathComponent)
        if metadata != newMetadataPath, FileManager.default.fileExists(atPath: newMetadataPath.path) {
            try FileManager.default.removeItem(at: newMetadataPath)
        }
        try FileManager.default.moveItem(at: metadata, to: newMetadataPath)
        identityManifest = try updateManifestComponentPath(
            identityManifest: identityManifest,
            component: "Ap,SystemVolumeCanonicalMetadata",
            at: newMetadataPath,
        )

        let newRootHashPath = restoreDir.appending(path: "Firmware").appending(path: rootHash.lastPathComponent)
        if rootHash != newRootHashPath, FileManager.default.fileExists(atPath: newRootHashPath.path) {
            try FileManager.default.removeItem(at: newRootHashPath)
        }
        try FileManager.default.moveItem(at: rootHash, to: newRootHashPath)
        identityManifest = try updateManifestComponentPath(
            identityManifest: identityManifest,
            component: "SystemVolume",
            at: newRootHashPath,
        )

        buildIdentity["Manifest"] = identityManifest
        buildIdentities[0] = buildIdentity
        root["BuildIdentities"] = buildIdentities
        return root
    }

    func updateManifestComponentPath(identityManifest: PlistDict, component: String, at: URL) throws -> PlistDict {
        var identityManifest = identityManifest
        let pathSuffix = relativePath(from: at, base: restoreDir.appendingPathComponent("", isDirectory: true))
        var comp = try getChildPlistDict(parent: identityManifest, key: component)
        var info = try getChildPlistDict(parent: comp, key: "Info")
        info["Path"] = pathSuffix
        comp["Info"] = info
        identityManifest[component] = comp
        return identityManifest
    }

    func relativePath(from child: URL, base: URL) -> String? {
        let basePath = base.standardizedFileURL.pathComponents
        let childPath = child.standardizedFileURL.pathComponents

        guard childPath.starts(with: basePath) else { return nil }

        let remaining = childPath.dropFirst(basePath.count)
        return remaining.joined(separator: "/")
    }

    func getProductVersion() throws -> String {
        let root = try parsePlist(data: buildManiest)
        guard let productVersion = root["ProductVersion"] as? String else {
            throw FirmwareManifest.ManifestError.missingKey("ProductVersion in BuildManifest")
        }
        return productVersion
    }

    func componentPath(_ component: String) throws -> String {
        let path = restoreDir.appending(path: "iPhone-BuildManifest.plist")
        let manifest = try getBuildIdentityManifest(path: path)
        return try getComponentPath(component: component, buildManifest: manifest)
    }

    func getComponentPath(component: String, buildManifest: PlistDict) throws -> String {
        let comp = try getChildPlistDict(parent: buildManifest, key: component)
        let info = try getChildPlistDict(parent: comp, key: "Info")
        guard let path = info["Path"] as? String else {
            throw FirmwareManifest.ManifestError.missingKey("component path")
        }
        return path
    }

    func getBuildIdentityManifest(path: URL) throws -> PlistDict {
        let data = try Data(contentsOf: path, options: .mappedIfSafe)
        return try getBuildIdentityManifest(data: data)
    }

    func getBuildIdentityManifest(data: Data) throws -> PlistDict {
        let buildManifest = try parsePlist(data: data)
        guard let buildIdentities = buildManifest["BuildIdentities"] as? [Any],
              buildIdentities.count > 0,
              let buildIdentity = buildIdentities.first! as? PlistDict
        else {
            throw FirmwareManifest.ManifestError.missingKey("Component in BuildManifest")
        }
        return try getChildPlistDict(parent: buildIdentity, key: "Manifest")
    }

    func parsePlist(data: Data) throws -> PlistDict {
        guard let buildManifest = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil,
        ) as? PlistDict else {
            throw FirmwareManifest.ManifestError.invalidPlist("")
        }
        return buildManifest
    }

    func getChildPlistDict(parent: PlistDict, key: String) throws -> PlistDict {
        guard let value = parent[key] as? PlistDict else {
            throw FirmwareManifest.ManifestError.missingKey(key)
        }
        return value
    }
}
