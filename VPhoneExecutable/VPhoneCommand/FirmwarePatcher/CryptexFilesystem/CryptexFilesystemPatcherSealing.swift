// CryptexFilesystemPatcherSealing.swift — Trust cache, mtree and SystemVolume seal generation.
//
// Split out of CryptexFilesystemPatcher.swift. Everything that turns the merged image into a
// sealed system volume: the static trust cache, the mtree, the digest database and root hash
// produced by apfs_sealvolume, and the Ap,SystemVolumeCanonicalMetadata container.

import Foundation
import VPhoneCoreKit
import Img4tool

extension CryptexFilesystemPatcher {
    /// `ipsw img4 im4p create --type T --version V` three times over. Img4tool is
    /// already a dependency of this module and builds the same DER: the IM4P
    /// SEQUENCE is the string "IM4P", the four-character type, the description
    /// — which is what ipsw's `--version` set — and the payload OCTET STRING.
    /// Dropping the subprocess takes the last Homebrew program out of the
    /// firmware pipeline.
    private func wrap(_ payload: URL, fourcc: String, description: String, named: String) throws -> URL {
        let im4pPath = try createTmpDir().appending(path: named)
        // Mapped: the mtree .aar this wraps is the whole system volume's
        // metadata and runs to hundreds of megabytes.
        let im4p = try IM4P(
            fourcc: fourcc,
            description: description,
            payload: Data(contentsOf: payload, options: .mappedIfSafe),
        )
        try im4p.data.write(to: im4pPath)
        return im4pPath
    }

    func wrapRootHash(_ rootHashPath: URL) throws -> URL {
        try wrap(rootHashPath, fourcc: "isys", description: "0", named: "metadata.root_hash")
    }

    func wrapTrustcache(_ trustcache: URL) throws -> URL {
        try wrap(trustcache, fourcc: "trst", description: "1", named: "new.filesystem")
    }

    func compressCanonicalMetadata(mtree: URL, digestDb: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let targetMtree = tmpDir.appending(path: mtree.lastPathComponent)
        try FileManager.default.copyItem(at: mtree, to: targetMtree)
        let targetDigestDb = tmpDir.appending(path: digestDb.lastPathComponent)
        try FileManager.default.copyItem(at: digestDb, to: targetDigestDb)

        let archivePath = tmpDir.appending(path: "payload.aar")
        _ = try runProcess("/usr/bin/aa", [
            "archive",
            "-d", tmpDir.path,
            "-o", archivePath.path,
        ])

        return try wrap(archivePath, fourcc: "msys", description: "0", named: "metadata.mtree")
    }

    private func identifyApfsSealvolume() throws -> URL {
        let iosVersion = try getProductVersion()
        // The optional filesystem merge reads a seal tool staged inside the VM.
        let sealDir = geteuid() == 0 ? restoreDir.appendingPathComponent(".tools")
            : ProcessInfo.processInfo.environment["VPHONE_SEAL_DIR"].map { URL(fileURLWithPath: $0) }
                ?? restoreDir.appendingPathComponent(".tools")
        let path = sealDir.appendingPathComponent("apfs_sealvolume_\(iosVersion)")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw FirmwareManifest.ManifestError.fileNotFound(path.path)
        }
        guard FileManager.default.isExecutableFile(atPath: path.path) else {
            throw ProcessError.notExecutable(path.path)
        }
        return path
    }

    func createDigestAndHash(filesystem: URL, mtree: URL, remap: Bool, editedSince: Date) throws -> (URL, URL) {
        // Not mounted: apfs_sealvolume needs only the device, and a mount would
        // change the volume after the mtree described it, so the root hash here
        // would differ from the one the restore computes from that mtree.
        let device = try attachImageWithoutMounting(path: filesystem)
        defer { try? detachImage(deviceNode: device) }

        let tmpDir = try createTmpDir()
        let digestDbPath = tmpDir.appending(path: "digest.db")
        let rootHashPath = tmpDir.appending(path: "root_hash")
        let mtreeRemapPath = tmpDir.appending(path: "mtree_remap.xml")
        let sealLogPath = tmpDir.appending(path: "seal.log")

        // The modification time the restore will derive from the mtree. From
        // iOS 27 on, restored takes the "fast mtree path" and always remaps,
        // with the root's time.
        let fastMtree = try Self.usesFastMtree(productVersion: getProductVersion())
        let remap = remap || fastMtree
        let modificationTime = try !remap ? "" : fastMtree ? parseRootTime(mtree: mtree) : parseEditTime(mtree: mtree, since: editedSince)
        let remapContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(remap ? """
            <key>MODIFICATION</key>
            <integer>\(modificationTime)</integer>
        """ : "")
        </dict>
        </plist>
        """
        print("Modification time: \(remap ? modificationTime : "none")")
        FileManager.default.createFile(atPath: mtreeRemapPath.path, contents: remapContent.data(using: .utf8))

        let sealvolume = try identifyApfsSealvolume()
        FileManager.default.createFile(atPath: sealLogPath.path, contents: nil)
        do {
            _ = try runProcess(sealvolume.path, [
                "-R", mtreeRemapPath.path,
                "-U", digestDbPath.path, // Save digest records
                "-M", rootHashPath.path, // Save root hash
                device,
            ], output: sealLogPath)
        } catch {
            // apfs_sealvolume says why it rejects a volume only in its log
            // (exit 65 = EX_DATAERR), which goes with the temporary directory.
            let log = (try? String(contentsOf: sealLogPath, encoding: .utf8)) ?? ""
            print("apfs_sealvolume log (last 60 lines):")
            print(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n"))
            throw error
        }
        return (digestDbPath, rootHashPath)
    }

    /// Whether the restore of `productVersion` seals with restored's "fast
    /// mtree path": it skips `mtree -m` and writes MODIFICATION from the
    /// time of the first entry of the mtree it was given (the root's), cut to
    /// whole seconds ("Found remapper time of: 1792721395", then
    /// apfs_sealvolume's "Timestamp set by B+I is 1792721395000000000",
    /// which on 26.x equals the MODIFICATION sent). Every 26.x restore
    /// logged "Fast mtree path not enabled", 27.2's "enabled"; restored
    /// decides on its own, as the host sends no option for it.
    static func usesFastMtree(productVersion: String) -> Bool {
        (Int(productVersion.split(separator: ".").first ?? "") ?? 0) >= 27
    }

    /// The time of the mtree's first entry (the root), cut to whole seconds and
    /// given in nanoseconds, as the fast mtree path writes it.
    func parseRootTime(mtree: URL) throws -> String {
        guard let mtreeData = FileManager.default.contents(atPath: mtree.path),
              let text = String(data: mtreeData, encoding: .utf8)
        else {
            throw FirmwareManifest.ManifestError.fileNotFound(mtree.path)
        }
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("/set") && !line.hasPrefix("#") {
            guard let match = line.range(of: #"time=[0-9]+"#, options: .regularExpression) else {
                continue
            }
            return String(line[match].dropFirst("time=".count)) + "000000000"
        }
        throw FirmwareManifest.ManifestError.fileNotFound("an entry with a time in \(mtree.path)")
    }

    /// The modification time of the first mtree entry edited since `since`, in
    /// nanoseconds.
    ///
    /// The restore seals the volume with the time its own `mtree -m` derives,
    /// and `mtree -m` takes it from the first entry, in walk order, whose time
    /// differs from the mtree. The restore gets the image as it was encrypted,
    /// before `removeSpecificSystemFiles`, so that is the first entry this run
    /// edited afterwards: the root when removing a host `.fseventsd` edited
    /// it, otherwise `/private/var` (`-nobrowse` mounts get no `.fseventsd`,
    /// so the root keeps the IPSW's time). The mtree lists entries in
    /// walk order. Any other value gives this side a root hash the restore
    /// rejects ("Invalid root hash").
    func parseEditTime(mtree: URL, since: Date) throws -> String {
        guard let mtreeData = FileManager.default.contents(atPath: mtree.path),
              let text = String(data: mtreeData, encoding: .utf8)
        else {
            throw FirmwareManifest.ManifestError.fileNotFound(mtree.path)
        }
        // File times have nanoseconds, so the edits are in the second `since`
        // falls in or later; everything before the edits is older.
        let threshold = Int(since.timeIntervalSince1970.rounded(.down))
        // An entry continues on the next line after a trailing backslash, so
        // each line is searched on its own and entries need not be joined.
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("/set") {
            guard let match = line.range(of: #"time=[0-9]+\.[0-9]+"#, options: .regularExpression) else {
                continue
            }
            let value = line[match].dropFirst("time=".count)
            let parts = value.split(separator: ".")
            guard let seconds = Int(parts[0]), seconds >= threshold else { continue }
            return parts.joined()
        }
        throw FirmwareManifest.ManifestError.fileNotFound("an entry edited since \(since) in \(mtree.path)")
    }

    func createMtree(filesystem: URL) throws -> URL {
        let (device, mount) = try attachImage(path: filesystem, readonly: true)
        defer { try? detachImage(deviceNode: device) }

        let tmpDir = try createTmpDir()
        let mtreeFile = tmpDir.appending(path: "mtree.txt")
        FileManager.default.createFile(atPath: mtreeFile.path, contents: nil)
        _ = try runProcess("/usr/sbin/mtree", [
            "-c",
            "-p", mount,
        ], output: mtreeFile)
        return mtreeFile
    }

    func removeSpecificSystemFiles(filesystem: URL) throws -> Bool {
        let (device, mount) = try attachImage(path: filesystem, forceRW: true)
        defer { try? detachImage(deviceNode: device) }

        let removedPaths = [
            "private/var/MobileAsset/PreinstalledAssets",
            "private/var/MobileAsset/PreinstalledAssetsV2",
            "private/var/staged_system_apps",
        ]
        try removeHostEventLog(mount: mount)
        let directory = try VPhoneConfinedDirectory.pin(absolutePath: mount)
        var didEdit = false
        for path in removedPaths {
            do {
                if try directory.exists(path) {
                    try directory.removeItem(path)
                    didEdit = true
                }
            } catch VPhoneConfinedDirectoryError.missing {
                // Some guest families have no MobileAsset directory at all.
                continue
            }
        }
        return didEdit
    }

    func createTrustcache(filesystem: URL) throws -> URL {
        let (device, mount) = try attachImage(path: filesystem, readonly: true)
        defer { try? detachImage(deviceNode: device) }

        let oldTrustcache = try componentPath("StaticTrustCache")
        let oldTrustcachePath = restoreDir.appending(path: oldTrustcache)
        let newTrustcachePath = restoreDir.appending(path: "Firmware/new.trustcache")
        let tmpDir = try createTmpDir()

        // cryptexctl hashes Mach-O code directories only. launchd.plist's
        // detached signature is not one, so its cdhashes go in through a second
        // base trust cache. Unedited, they are Apple's and already in the first.
        var baseTrustcaches = [oldTrustcachePath]
        let volume = try VPhoneConfinedDirectory.pin(absolutePath: mount)
        if try volume.exists(CustomFirmwareDetachedSignature.launchdCacheSignaturePath) {
            let signature = try volume.readData(CustomFirmwareDetachedSignature.launchdCacheSignaturePath)
            let hashes = try CustomFirmwareDetachedSignature.codeDirectoryHashes(in: signature)
            let detached = tmpDir.appending(path: "detached.trustcache")
            try CustomFirmwareDetachedSignature.trustCache(hashes).write(to: detached)
            baseTrustcaches.append(detached)
        }

        let tcContainer = tmpDir.appending(path: "new.trustcache")
        _ = try runProcess("/System/Library/SecurityResearch/usr/bin/cryptexctl", [
            "generate-trust-cache", "--type", "static",
        ] + baseTrustcaches.flatMap { ["--base-trust-cache", $0.path] } + [
            "--output-file", tcContainer.path,
            mount,
        ])
        try addConstraintCategories(to: tcContainer)

        if FileManager.default.fileExists(atPath: newTrustcachePath.path) {
            try FileManager.default.removeItem(at: newTrustcachePath)
        }
        try FileManager.default.moveItem(at: tcContainer, to: newTrustcachePath)

        return newTrustcachePath
    }

    /// Apple's trust caches for what the merged volume holds: the OS's, and
    /// each cryptex's merged into it. A watch has no cryptexes.
    static let originalTrustCacheComponents = ["StaticTrustCache", "Cryptex1,SystemTrustCache", "Cryptex1,AppTrustCache"]

    /// Give cryptexctl's cache the launch-constraint categories of Apple's.
    ///
    /// cryptexctl writes a version 1 cache, which has no category, so every
    /// system service launched with category 0 and the kernel logged
    /// "launched as a system service unexpectedly but met System Service
    /// constraints" for each. Apple's caches are version 2 and carry a
    /// category for each CDHash. See `TrustCache.withConstraintCategories`
    /// for which entries get one.
    func addConstraintCategories(to trustCache: URL) throws {
        let manifest = try getBuildIdentityManifest(path: restoreDir.appending(path: "iPhone-BuildManifest.plist"))
        let originals = try Self.originalTrustCacheComponents.filter { manifest[$0] != nil }.map { component in
            let path = try getComponentPath(component: component, buildManifest: manifest)
            return try TrustCache(payload: IM4P(contentsOf: restoreDir.appending(path: path)).payload())
        }
        let container = try IM4P(contentsOf: trustCache)
        let generated = try TrustCache(payload: container.payload())
        var cache = generated.withConstraintCategories(from: originals, inherited: resignedCDHashes)
        if trustedDarwinOS {
            let before = cache.entries.count
            cache = cache.allowingBothRestrictedExecutionPhases()
            print("  [+] Restricted Execution Mode: all \(cache.entries.count) entries allowed in both phases (\(before - cache.entries.count) duplicates dropped)")
        }
        try IM4P(fourcc: container.fourcc, description: container.description, payload: cache.payload)
            .data.write(to: trustCache)
        let categorized = cache.entries.filter { $0.constraintCategory != 0 }.count
        print("  [+] Constraint categories for \(categorized) of \(cache.entries.count) trust cache entries")
        for entry in cache.entries where resignedCDHashes[entry.cdHash] != nil {
            let hex = entry.cdHash.map { String(format: "%02x", $0) }.joined()
            print("  [+] Re-signed cdhash \(hex) (hash type \(entry.hashType)): category \(entry.constraintCategory)")
        }
    }
}
