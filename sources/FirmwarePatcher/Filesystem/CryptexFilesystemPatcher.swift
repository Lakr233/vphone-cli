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

import Foundation
import CryptoKit
import Img4tool

enum ProcessError: Error {
    case failed(Int32, String)
}

extension Data {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

/// Patcher for the Filesystem payload.
public final class CryptexFilesystemPatcher: Patcher {
    public let component = "Filesystem"
    public let restoreDir: URL
    public let verbose: Bool
    let vphoneCliDirectory = URL(filePath: "./")
    
    var buildManiest: Data
    var rebuiltData: Data?
    var tmpDirectories: [URL] = []
    
    // MARK: - Init
    
    public init(buildManiest: Data, restoreDir: URL, verbose: Bool = true) {
        self.buildManiest = buildManiest
        self.restoreDir = restoreDir
        self.verbose = verbose
    }
    
    deinit {
        for tmp in tmpDirectories {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
    
    // MARK: - Patcher
    
    public func findAll() throws -> [PatchRecord] {
        return [PatchRecord(
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
        print("Merging Filesystems")
        let (unencryptedImage, aeaImage) = try mergeFilesystems()
        
        print("Creating Trustcache")
        let trustcachePath = try createTrustcache(filesystem: unencryptedImage)
        
        print("Creating mtree")
        let didEdit = try removeSpecificSystemFiles(filesystem: unencryptedImage)
        let mtreePath = try createMtree(filesystem: unencryptedImage)
        
        print("Creating DigestDB and Root Hash")
        let (digestDbPath, rootHashPath) = try createDigestAndHash(filesystem: unencryptedImage, mtree: mtreePath, remap: didEdit)
        let metadataPath = try compressCanonicalMetadata(mtree: mtreePath, digestDb: digestDbPath)
        let rootHashContainer = try wrapRootHash(rootHashPath)
        
        // update trustcache, metadata, root_hash path
        let updatedManifest = try setUpdatedComponentsInManifest(filesystem: aeaImage, trustcache: trustcachePath, metadata: metadataPath, rootHash: rootHashContainer)
        rebuiltData = try serializePayload(updatedManifest)
        
        return 1
    }
    
    /// Get the patched data.
    public var patchedData: Data {
        rebuiltData!
    }
    
    // mergeFilesystems merges the main OS filesystem with the Cryptexes filesystems.
    // It returns the path of the merged image (plain and encrypted)
    func mergeFilesystems() throws -> (URL, URL) {
        let osPath = try getOSFilesystemPath()
        let osDmgPath = try decryptAeaFile(self.restoreDir.appending(path: osPath))
        let tmpDir = try createTmpDir()
        let newDmgPath = tmpDir.appending(path: "new-filesystem.dmg")
        
        print("- Converting OS image")
        let targetImagePath = tmpDir.appending(path: "disk.dmg")
        do {
            try convertToRawImage(input: osDmgPath, output: targetImagePath)
            let (targetDevice, targetMount) = try attachImage(path: targetImagePath, forceRW: true)
            defer { try? detachImage(deviceNode: targetDevice) }
            
            print("- Merging App OS Cryptex")
            try copyCryptex(targetMount: targetMount, appOS: true)

            print("- Merging System OS Cryptex")
            try copyCryptex(targetMount: targetMount, systemOS: true)
            
            print("- Fix Dyld Cache")
            try addDyldSymlinks(targetMount: targetMount)
            
            let cfwInputOgPath = vphoneCliDirectory.appending(path: "scripts/resources/cfw_input.tar.zst")
            let cfwInputPath = try createTmpDir()
            _ = try runProcess("/usr/bin/tar", [
                "--zstd", "-xf", cfwInputOgPath.path, "-C", cfwInputPath.path
            ])
            
            print("- Fix GPU Driver")
            try addGpuDriver(targetMount: targetMount, cfwInput: cfwInputPath)
            
            print("- Patch Mobile Activation")
            try patchMobileActivation(targetMount: targetMount, cfwInput: cfwInputPath)
            
            print("- Add vphoned")
            try addVphoned(targetMount: targetMount, cfwInput: cfwInputPath)
            try patchLaunchdCacheLoader(targetMount: targetMount, cfwInput: cfwInputPath)
        }
        
        print("- Finalizing merged image")
        try shrinkImage(dmg: targetImagePath)
        try convertToUDRWImage(input: targetImagePath, output: newDmgPath)
        let key = try getAeaKey(self.restoreDir.appending(path: osPath))
        let metadata = try getAeaMetadata(self.restoreDir.appending(path: osPath))
        let finalFile = try encryptAeaFile(newDmgPath, key: key, metadata: metadata)
        let finalDestination = self.restoreDir.appending(path: finalFile.lastPathComponent)
        if FileManager.default.fileExists(atPath: finalDestination.path) {
            try FileManager.default.removeItem(at: finalDestination)
        }
        try FileManager.default.moveItem(at: finalFile, to: finalDestination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: finalDestination.path)
        return (newDmgPath, finalDestination)
    }
    
    func patchLaunchdCacheLoader(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let launchdCacheLoaderPath = target.appending(path: "/usr/libexec/launchd_cache_loader")
        let pythonPath = vphoneCliDirectory.appending(path: ".venv/bin/python3")
        let patcherPath = vphoneCliDirectory.appending(path: "scripts/patchers/cfw.py")
        _ = try runProcess(pythonPath.path, [
            patcherPath.path, "patch-launchd-cache-loader",
            launchdCacheLoaderPath.path
        ])
        _ = try runProcess("/bin/chmod", ["0755", launchdCacheLoaderPath.path])
        
        let signingCertificatePath = cfwInput.appending(path: "cfw_input/signcert.p12")
        _ = try runProcess("/opt/homebrew/bin/ldid", [
            "-S", "-M", "-K\(signingCertificatePath.path)",
            "-Icom.apple.launchd_cache_loader",
            launchdCacheLoaderPath.path
        ])
    }
    
    func addVphoned(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let scriptDir = vphoneCliDirectory.appending(path: "scripts")
        let vphonedSrc = scriptDir.appendingPathComponent("vphoned")
        let vphonedBin = vphonedSrc.appendingPathComponent("vphoned")

        try buildVphoned(vphonedSrc: vphonedSrc, vphonedBin: vphonedBin)
        defer { try? FileManager.default.removeItem(at: vphonedBin) }
        
        // Sign
        let targetBin = target.appending(path: "/usr/bin/vphoned")
        try FileManager.default.copyItem(at: vphonedBin, to: targetBin)
        let signingCertificatePath = cfwInput.appending(path: "cfw_input/signcert.p12")
        _ = try runProcess("/opt/homebrew/bin/ldid", [
            "-S\(vphonedSrc.appendingPathComponent("entitlements.plist").path)",
            "-M", "-K\(signingCertificatePath.path)",
            targetBin.path
        ])
        _ = try runProcess("/bin/chmod", ["0755", targetBin.path])
        
        // Register Launch Daemon
        let vphonedLaunchdPlist = vphonedSrc.appending(path: "vphoned.plist")
        try FileManager.default.copyItem(at: vphonedLaunchdPlist,
                                         to: target.appending(path: "System/Library/LaunchDaemons/vphoned.plist"))
        let tmpDir = try createTmpDir()
        let launchdPath = tmpDir.appending(path: "launchd.plist")
        let launchDaemonsPath = tmpDir.appending(path: "launchDaemons")
        let launchdOgPath = target.appending(path: "/System/Library/xpc/launchd.plist")
        try FileManager.default.createDirectory(at: launchDaemonsPath, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: launchdOgPath, to: launchdPath)
        try FileManager.default.copyItem(at: vphonedLaunchdPlist, to: launchDaemonsPath.appending(path: vphonedLaunchdPlist.lastPathComponent))
        _ = try runProcess(vphoneCliDirectory.appending(path: ".venv/bin/python3").path, [
            vphoneCliDirectory.appending(path: "scripts/patchers/cfw.py").path, "inject-daemons",
            launchdPath.path, launchDaemonsPath.path
        ])
        try FileManager.default.moveItem(at: launchdPath, to: launchdOgPath)
        _ = try runProcess("/bin/chmod", ["0644", launchdOgPath.path])
    }
    
    func buildVphoned(vphonedSrc: URL, vphonedBin: URL) throws {
        let srcURLs = try FileManager.default.contentsOfDirectory(
            at: vphonedSrc,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "m" }

        var args = [
            "-sdk", "iphoneos", "clang",
            "-arch", "arm64",
            "-Os",
            "-fobjc-arc",
            "-I\(vphonedSrc.path)",
            "-I\(vphonedSrc.appendingPathComponent("vendor/libarchive").path)",
            "-DLESS=1",
            "-o", vphonedBin.path
        ]
        args.append(contentsOf: srcURLs.map { $0.path })
        args.append(contentsOf: [
            "-larchive",
            "-lsqlite3",
            "-framework", "Foundation",
            "-framework", "Security",
            "-framework", "CoreServices"
        ])
        
        _ = try runProcess("/usr/bin/xcrun", args)
    }
    
    func addGpuDriver(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)

        let gpuTarPath = cfwInput.appending(path: "cfw_input/custom/AppleParavirtGPUMetalIOGPUFamily.tar")
        _ = try runProcess("/usr/bin/tar", [
            "--preserve-permissions",
            "-xf", gpuTarPath.path,
            "-C", target.path
        ])
        
        let bundle = target.appending(path: "/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle")
        // Clean macOS resource fork files (._* files from tar xattrs)
        _ = try? runProcess("/usr/bin/find", [bundle.path, "-name", "._*", "-delete"])
        _ = try runProcess("/usr/sbin/chown", ["-R", "0:0", bundle.path])
        for path in [
            bundle.path,
            bundle.appending(path: "/libAppleParavirtCompilerPluginIOGPUFamily.dylib").path,
            bundle.appending(path: "/AppleParavirtGPUMetalIOGPUFamily").path,
            bundle.appending(path: "/_CodeSignature").path,
        ] {
            _ = try runProcess("/bin/chmod", ["0755", path])
        }
        for path in [
            bundle.appending(path: "/_CodeSignature/CodeResources").path,
            bundle.appending(path: "/Info.plist").path
        ] {
            _ = try runProcess("/bin/chmod", ["0644", path])
        }
    }

    func patchMobileActivation(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let mobileActivationdPath = target.appending(path: "/usr/libexec/mobileactivationd")
        _ = try runProcess("./.venv/bin/python3", [
            "./scripts/patchers/cfw.py", "patch-mobileactivationd",
            mobileActivationdPath.path
        ])
        _ = try runProcess("/bin/chmod", ["0755", mobileActivationdPath.path])
        
        let signingCertificatePath = cfwInput.appending(path: "cfw_input/signcert.p12")
        _ = try runProcess("/opt/homebrew/bin/ldid", [
            "-S", "-M", "-K\(signingCertificatePath.path)",
            mobileActivationdPath.path
        ])
    }
    
    func addDyldSymlinks(targetMount: String) throws {
        let target = URL.init(filePath: targetMount)
        _ = try runProcess("/bin/ln", [
            "-sf", "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
            target.appending(path: "/System/Library/Caches/com.apple.dyld").path
        ])
        _ = try runProcess("/bin/ln", [
            "-sf", "../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld",
            target.appending(path: "/System/DriverKit/System/Library/dyld").path
        ])
    }
    
    func wrapRootHash(_ rootHashPath: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let im4pPath = tmpDir.appending(path: "metadata.root_hash")
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "img4", "im4p", "create",
            "--type", "isys", "--version", "0",
            "-o", im4pPath.path,
            rootHashPath.path
        ])
        return im4pPath
    }

    func wrapTrustcache(_ trustcache: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let im4pPath = tmpDir.appending(path: "new.filesystem")
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "img4", "im4p", "create",
            "--type", "trst", "--version", "1",
            "-o", im4pPath.path,
            trustcache.path
        ])
        return im4pPath
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
            "-o", archivePath.path
        ])
        
        let im4pPath = tmpDir.appending(path: "metadata.mtree")
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "img4", "im4p", "create",
            "--type", "msys", "--version", "0",
            "-o", im4pPath.path,
            archivePath.path
        ])
        return im4pPath
    }
    
    func createDigestAndHash(filesystem: URL, mtree: URL, remap: Bool) throws -> (URL, URL) {
        let (device, mount) = try attachImage(path: filesystem)
        defer { try? detachImage(deviceNode: device) }

        let tmpDir = try createTmpDir()
        let digestDbPath = tmpDir.appending(path: "digest.db")
        let rootHashPath = tmpDir.appending(path: "root_hash")
        let mtreeRemapPath = tmpDir.appending(path: "mtree_remap.xml")
        
        // We want to get the nanosecond timestamp of the last modification before the mtree collection.
        // We know that we remove directories in /private/var in removeSpecificSystemFiles last.
        // Therefore, we parse the modification time of /private/var.
        let modificationTime = try parsePrivateVarTime(mtree: mtree)
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
        print("Used time: \(remap ? modificationTime : "none")")
        FileManager.default.createFile(atPath: mtreeRemapPath.path, contents: remapContent.data(using: .utf8))

        try unmount(mount: mount)
        let sealvolume = self.vphoneCliDirectory.appending(path: ".tools/apfs_sealvolume")
        _ = try runProcess(sealvolume.path, [
            "-R", mtreeRemapPath.path,
            "-U", digestDbPath.path, // Save digest records
            "-M", rootHashPath.path, // Save root hash
            device
        ])
        return (digestDbPath, rootHashPath)
    }
    
    func parsePrivateVarTime(mtree: URL) throws -> String {
        guard let mtreeData = FileManager.default.contents(atPath: mtree.path),
              let text = String(data: mtreeData, encoding: .utf8) else {
            throw FirmwareManifest.ManifestError.fileNotFound(mtree.path)
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        // Find the section header for /private/var
        guard let sectionIndex = lines.firstIndex(of: "# ./private/var") else {
            throw FirmwareManifest.ManifestError.fileNotFound("/private/var")
        }

        // Look at the lines after that header until the next section header
        for line in lines[(sectionIndex + 1)...] {
            // Stop if we hit the next section
            if line.hasPrefix("# ./") {
                break
            }

            // The metadata line for /private/var starts with "var "
            guard line.hasPrefix("var ") else { continue }

            // Extract time=...
            guard let match = line.range(of: #"time=([0-9]+(?:\.[0-9]+)?)"#,
                                         options: .regularExpression) else {
                throw FirmwareManifest.ManifestError.fileNotFound("time")
            }

            let matchedText = String(line[match])
            return matchedText
                .replacingOccurrences(of: "time=", with: "")
                .replacingOccurrences(of: ".", with: "")
        }

        throw FirmwareManifest.ManifestError.fileNotFound("metadata")
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
            "/private/var/MobileAsset/PreinstalledAssets",
            "/private/var/MobileAsset/PreinstalledAssetsV2",
            "/private/var/staged_system_apps",
        ]
        var didEdit = false
        for path in removedPaths {
            if FileManager.default.fileExists(atPath: mount.appending(path)) {
                try FileManager.default.removeItem(atPath: mount.appending(path))
                didEdit = true
            }
        }
        return didEdit
    }
    
    func createTrustcache(filesystem: URL) throws -> URL {
        let (device, mount) = try attachImage(path: filesystem, readonly: true)
        defer { try? detachImage(deviceNode: device) }
        
        let oldTrustcache = try getTrustcachePath()
        let oldTrustcachePath = self.restoreDir.appending(path: oldTrustcache)
        let newTrustcachePath = self.restoreDir.appending(path: "Firmware/new.trustcache")
        let tmpDir = try createTmpDir()
        
        let tcContainer = tmpDir.appending(path: "new.trustcache")
        _ = try runProcess("/System/Library/SecurityResearch/usr/bin/cryptexctl", [
            "generate-trust-cache", "--type", "static",
            "--base-trust-cache", oldTrustcachePath.path,
            "--output-file", tcContainer.path,
            mount
        ])
        
        if FileManager.default.fileExists(atPath: newTrustcachePath.path) {
            try FileManager.default.removeItem(at: newTrustcachePath)
        }
        try FileManager.default.moveItem(at: tcContainer, to: newTrustcachePath)

        return newTrustcachePath
    }
    
    func copyCryptex(targetMount: String, appOS: Bool = false, systemOS: Bool = false) throws {
        guard (appOS || systemOS) && !(appOS && systemOS) else {
            throw FirmwarePatcher.PatcherError.patchVerificationFailed("Can patch only one at a time")
        }
        
        let osPath = if appOS {
            self.restoreDir.appending(path: try getAppOsFilesystemPath())
        } else {
            try decryptAeaFile(self.restoreDir.appending(path: try getSystemOsFilesystemPath()))
        }
        let (osDevice, osMount) = try attachImage(path: osPath, readonly: true)
        defer { try? detachImage(deviceNode: osDevice) }
        
        let destination = URL.init(filePath: targetMount).appending(path: appOS ? "/System/Cryptexes/App" : "/System/Cryptexes/OS")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try copyImageContents(source: URL.init(filePath: osMount), destination: destination)
    }
    
    func serializePayload(_ buildManifest: PlistDict) throws -> Data {
        return try PropertyListSerialization.data(
            fromPropertyList: buildManifest,
            format: .xml,
            options: 0
        )
    }
    
    func setUpdatedComponentsInManifest(filesystem: URL, trustcache: URL, metadata: URL, rootHash: URL) throws -> PlistDict {
        var root = try parsePlist(data: buildManiest)
        guard var buildIdentities = root["BuildIdentities"] as? [Any],
              buildIdentities.count > 0,
              var buildIdentity = buildIdentities.first! as? PlistDict else {
            throw FirmwareManifest.ManifestError.missingKey("Component in BuildManifest")
        }
        var identityManifest = try getChildPlistDict(parent: buildIdentity, key: "Manifest")
        
        // We assume that the filesystem is already placed in the restore directory.
        identityManifest = try updateManifestComponentPath(identityManifest: identityManifest, component: "OS", at: filesystem)
        
        let newTrustcachePath = self.restoreDir.appending(path: "Firmware").appending(path: trustcache.lastPathComponent)
        if trustcache != newTrustcachePath && FileManager.default.fileExists(atPath: newTrustcachePath.path) {
            try FileManager.default.removeItem(at: newTrustcachePath)
        }
        try FileManager.default.moveItem(at: trustcache, to: newTrustcachePath)
        identityManifest = try updateManifestComponentPath(identityManifest: identityManifest, component: "StaticTrustCache", at: newTrustcachePath)
        
        let newMetadataPath = self.restoreDir.appending(path: "Firmware").appending(path: metadata.lastPathComponent)
        if metadata != newMetadataPath && FileManager.default.fileExists(atPath: newMetadataPath.path) {
            try FileManager.default.removeItem(at: newMetadataPath)
        }
        try FileManager.default.moveItem(at: metadata, to: newMetadataPath)
        identityManifest = try updateManifestComponentPath(identityManifest: identityManifest, component: "Ap,SystemVolumeCanonicalMetadata", at: newMetadataPath)
        
        let newRootHashPath = self.restoreDir.appending(path: "Firmware").appending(path: rootHash.lastPathComponent)
        if rootHash != newRootHashPath && FileManager.default.fileExists(atPath: newRootHashPath.path) {
            try FileManager.default.removeItem(at: newRootHashPath)
        }
        try FileManager.default.moveItem(at: rootHash, to: newRootHashPath)
        identityManifest = try updateManifestComponentPath(identityManifest: identityManifest, component: "SystemVolume", at: newRootHashPath)
        
        buildIdentity["Manifest"] = identityManifest
        buildIdentities[0] = buildIdentity
        root["BuildIdentities"] = buildIdentities
        return root
    }
    
    func updateManifestComponentPath(identityManifest: PlistDict, component: String, at: URL) throws -> PlistDict {
        var identityManifest = identityManifest
        let pathSuffix = relativePath(from: at, base: self.restoreDir.appendingPathComponent("", isDirectory: true))
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
    
    func getTrustcachePath() throws -> String {
        let path = self.restoreDir.appending(path: "iPhone-BuildManifest.plist")
        let manifest = try getBuildIdentityManifest(path: path)
        return try getComponentPath(component: "StaticTrustCache", buildManifest: manifest)
    }
    
    func getOSFilesystemPath() throws -> String {
        let path = self.restoreDir.appending(path: "iPhone-BuildManifest.plist")
        let manifest = try getBuildIdentityManifest(path: path)
        return try getComponentPath(component: "OS", buildManifest: manifest)
    }
    
    func getAppOsFilesystemPath() throws -> String {
        let path = self.restoreDir.appending(path: "iPhone-BuildManifest.plist")
        let manifest = try getBuildIdentityManifest(path: path)
        return try getComponentPath(component: "Cryptex1,AppOS", buildManifest: manifest)
    }
    
    func getSystemOsFilesystemPath() throws -> String {
        let path = self.restoreDir.appending(path: "iPhone-BuildManifest.plist")
        let manifest = try getBuildIdentityManifest(path: path)
        return try getComponentPath(component: "Cryptex1,SystemOS", buildManifest: manifest)
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
        let data = try Data.init(contentsOf: path)
        return try getBuildIdentityManifest(data: data)
    }
    
    func getBuildIdentityManifest(data: Data) throws -> PlistDict {
        let buildManifest = try parsePlist(data: data)
        guard let buildIdentities = buildManifest["BuildIdentities"] as? [Any],
              buildIdentities.count > 0,
              let buildIdentity = buildIdentities.first! as? PlistDict else {
            throw FirmwareManifest.ManifestError.missingKey("Component in BuildManifest")
        }
        return try getChildPlistDict(parent: buildIdentity, key: "Manifest")
    }
    
    func parsePlist(data: Data) throws -> PlistDict {
        guard let buildManifest = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
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
    
    func createTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "vphone-\(UUID.init().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        self.tmpDirectories.append(tmpDir)
        return tmpDir
    }
    
    func copyImageContents(source: URL, destination: URL) throws {
        // Copy everything from source volume root into destination volume root.
        let sourceRoot = source.appendingPathComponent("", isDirectory: true)
        let sourcePath = sourceRoot.path
        let destinationRoot = destination.appendingPathComponent("", isDirectory: true)
        
        // We delete the files first as we want to replace symlinks with actual files.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: keys) else {
            throw FirmwareManifest.ManifestError.fileNotFound("enumerator")
        }
        for case let fileURL as URL in enumerator {
            guard fileURL.path.hasPrefix(sourcePath) else { continue }

            let values = try fileURL.resourceValues(forKeys: Set(keys))
            var suffix = String(fileURL.path.dropFirst(sourcePath.count))
            if suffix.hasPrefix("/") {
                suffix.removeFirst()
            }

            let destinationPath = destinationRoot.appendingPathComponent(suffix)
            guard let ok = try? destinationPath.checkResourceIsReachable(), ok else {
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                let result = copyfile(fileURL.path, destinationPath.path, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_DATA))
                if result < 0 {
                    print("Failed to copy: \(destinationPath)")
                }
                continue
            }
            
            let vals = try destinationPath.resourceValues(forKeys: Set(keys))
            if values.isDirectory != vals.isDirectory ||
                values.isRegularFile != vals.isRegularFile ||
                values.isSymbolicLink != vals.isSymbolicLink {
                try FileManager.default.removeItem(at: destinationPath)
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                let result = copyfile(fileURL.path, destinationPath.path, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_DATA))
                if result < 0 {
                    print("Failed to copy: \(destinationPath)")
                }
            }
        }
    }
    
    func getAeaKey(_ path: URL) throws -> String {
        return try runProcess("/opt/homebrew/bin/ipsw", [
            "fw", "aea",
            "--no-color",
            "--key",
            path.path,
        ]).trimmingCharacters(in: ["\n"])
    }
    
    func encryptAeaFile(_ path: URL, key: String, metadata: [String: String]) throws -> URL {
        let outputPath = path.appendingPathExtension("aea")
        var arguments = [
            "encrypt", "-i", path.path, "-o", outputPath.path,
            "-profile", "1", "-key-value", key,
        ]
        for (metaKey, metaValue) in metadata {
            arguments.append("-auth-data-key")
            arguments.append(metaKey)
            arguments.append("-auth-data-value")
            arguments.append(metaValue)
        }
        _ = try runProcess("/usr/bin/aea", arguments)
        return outputPath
    }
    
    func decryptAeaFile(_ path: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let outputPath = tmpDir.appending(path: path.appendingPathExtension("dmg").lastPathComponent)
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "fw", "aea",
            "-o", outputPath.path,
            path.path,
        ])
        return outputPath.appending(path: path.lastPathComponent.dropLast(4))
    }
    
    func getAeaMetadata(_ path: URL) throws -> [String: String] {
        let output = try runProcess("/opt/homebrew/bin/ipsw", [
            "fw", "aea",
            "--no-color",
            "--info",
            path.path,
        ])
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

        var result: [String: String] = [:]
        var currentKey: String?
        var bodyLines: [String] = []

        func flushCurrentSection() {
            guard let key = currentKey else { return }
            result[key] = parseSectionBody(bodyLines)
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if let key = parseSectionHeader(trimmed) {
                flushCurrentSection()
                currentKey = key
                bodyLines = []
            } else {
                // Ignore banner lines before the first section
                if currentKey != nil {
                    bodyLines.append(rawLine)
                }
            }
        }

        flushCurrentSection()
        return result
    }
    
    private func parseSectionHeader(_ line: String) -> String? {
        // Matches both:
        // [com.apple.wkms.url]:
        // [saksKey]:
        guard line.hasPrefix("[") else { return nil }
        guard let end = line.firstIndex(of: "]") else { return nil }

        let key = String(line[line.index(after: line.startIndex)..<end])
        return key.isEmpty ? nil : key
    }
    
    private func parseSectionBody(_ bodyLines: [String]) -> String {
        let nonEmpty = bodyLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // If the section contains hex dump lines, parse and concatenate them.
        let hexBytes = nonEmpty.flatMap { parseHexDumpLine($0) }
        if !hexBytes.isEmpty {
            let b64Encoded = Data(hexBytes).base64EncodedString()
            return "hex:\(Data(b64Encoded.utf8).hexString)"
        }

        // Otherwise treat it as plain text / JSON / whatever the section contains.
        let text = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return "hex:\(Data(text.utf8).hexString)"
    }

    private func parseHexDumpLine(_ line: String) -> [UInt8] {
        // Example:
        // 0000000000000000:  0a 8d 03 0a 2f c7 ... |....|
        guard let colonIndex = line.firstIndex(of: ":") else { return [] }

        let afterColon = line[line.index(after: colonIndex)...]
        let beforeAscii = afterColon.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? afterColon

        let tokens = beforeAscii.split(whereSeparator: \.isWhitespace)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count)

        for token in tokens {
            guard token.count == 2, let b = UInt8(token, radix: 16) else {
                return []   // not a hexdump line
            }
            bytes.append(b)
        }

        return bytes
    }
    
    func convertToRawImage(input: URL, output: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "create", "from",
            "--format", "RAW", input.path,
            output.path
        ])
        
        // Resize to max
        let maxsize = try runProcess("/bin/sh", [
            "-c", "diskutil image resize --plist \"\(output.path)\" | plutil -extract max raw -o - -"
        ]).trimmingCharacters(in: ["\n"])
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "--size", maxsize, output.path
        ])
    }
    
    func convertToUDRWImage(input: URL, output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        _ = try runProcess("/usr/bin/hdiutil", [
            "convert",
            input.path,
            "-format", "UDRW",
            "-o", output.path
        ])
    }
    
    func shrinkImage(dmg: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image",
            "resize",
            "--size", "min",
            dmg.path
        ])
    }
    
    func unmount(mount: String) throws {
        _ = try runProcess("/usr/sbin/diskutil", ["unmount", mount])
    }
    
    // attachImage returns the device and mount point
    func attachImage(path: URL, readonly: Bool = false, forceRW: Bool = false) throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = if readonly {[
            "attach",
            "-readonly",
            "-plist",
            path.path,
        ]} else {[
            "attach",
            "-plist",
            path.path,
        ]}
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            throw ProcessError.failed(process.terminationStatus, output)
        }
        
        let root = try parsePlist(data: data)
        guard let entries = root["system-entities"] as? [Any] else {
            throw FirmwareManifest.ManifestError.missingKey("system-entities")
        }
        for entry in entries {
            guard let entry = entry as? PlistDict,
                  let volumeKind = entry["volume-kind"] as? String,
                  volumeKind == "apfs" || volumeKind == "hfs" else {
                continue
            }
            let device = entry["dev-entry"] as? String ?? ""
            let mountPoint = entry["mount-point"] as? String ?? ""
            
            if forceRW {
                _ = try runProcess("/sbin/mount", ["-u", "-w", device, mountPoint])
            }
            return (device, mountPoint)
        }
        throw FirmwareManifest.ManifestError.missingKey("dev-entry or mount-point")
    }
    
    func detachImage(deviceNode: String) throws {
        _ = try runProcess("/usr/bin/hdiutil", ["detach", deviceNode])
    }
    
    func runProcess(_ launchPath: String, _ arguments: [String], sudo: Bool = false, output: URL? = nil) throws -> String {
        let process = Process()
        if sudo {
            let whoami = try runProcess("/usr/bin/whoami", [])
            if !whoami.contains("root") {
                print("Please rerun as root or fix this program")
                exit(42)
            }
        }
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        if let output {
            let outFile = try FileHandle.init(forWritingTo: output)
            process.standardOutput = outFile
            process.standardError = outFile
        } else {
            process.standardOutput = outPipe
            process.standardError = outPipe
        }

        try process.run()
        process.waitUntilExit()

        let output = output == nil ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) : nil
        guard process.terminationStatus == 0 else {
            throw ProcessError.failed(process.terminationStatus, output ?? "")
        }
        return output ?? ""
    }
}
