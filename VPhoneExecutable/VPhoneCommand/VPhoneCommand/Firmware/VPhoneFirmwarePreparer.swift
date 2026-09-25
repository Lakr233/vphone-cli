import Darwin
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit

/// Builds one restore tree from two IPSWs without a shell or a second full
/// copy of either source archive. All extraction and merging happens in one
/// disposable directory inside the VM; only a complete tree is moved into
/// place for the patch/restore steps to see.
enum VPhoneFirmwarePreparer {
    enum Error: Swift.Error, LocalizedError {
        case existingRestore(URL)
        case missingComponent(URL)
        case sourceNameMismatch(URL, version: String, build: String)

        var errorDescription: String? {
            switch self {
            case let .existingRestore(path):
                "A restore tree already exists at \(path.path). Remove it, then prepare the firmware again."
            case let .missingComponent(path):
                "A firmware component is missing: \(path.path). Check that the IPSW is complete, then prepare the firmware again."
            case let .sourceNameMismatch(path, version, build):
                "The IPSW file name does not match its contents (\(version)/\(build)): \(path.path). Use the original file name or download the IPSW again."
            }
        }
    }

    static func prepare(
        iPhoneSource: String,
        cloudOSSource: String,
        gpuDriverBundle: URL? = nil,
        bundle: VPhoneBundle,
        resources: VPhoneResources,
    ) throws {
        let fm = FileManager.default
        let existing = try fm.contentsOfDirectory(
            at: bundle.url,
            includingPropertiesForKeys: [.isDirectoryKey],
        )
        for candidate in existing where candidate.lastPathComponent.contains("Restore") {
            if try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                throw Error.existingRestore(candidate)
            }
        }

        // Remote IPSWs belong to this VM, not a writable shared directory.
        // Local IPSWs are read in place and are never copied into the cache.
        let cacheDirectory = bundle.url.appendingPathComponent(".ipsw-cache", isDirectory: true)
        print("[*] Resolving iPhone IPSW...")
        let phone = try vphoneRunBlocking {
            try await VPhoneIPSWCache.resolve(iPhoneSource, in: cacheDirectory)
        }
        print("[*] Resolving cloudOS IPSW...")
        let cloud = try vphoneRunBlocking {
            try await VPhoneIPSWCache.resolve(cloudOSSource, in: cacheDirectory)
        }
        try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: cloud)
        try checkIPhoneName(iPhoneSource, archive: phone)
        print("[+] iPhone \(phone.version) (\(phone.build)); cloudOS \(cloud.version) (\(cloud.build))")

        let name = "iPhone17,3_\(phone.version)_\(phone.build)_Restore"
        let destination = bundle.url.appendingPathComponent(name)
        let staging = bundle.url.appendingPathComponent(".firmware-prepare-\(UUID().uuidString)")
        let phoneTree = staging.appendingPathComponent(name)
        let cloudTree = staging.appendingPathComponent("cloudOS")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            let entries = (try? fm.contentsOfDirectory(atPath: staging.path)) ?? []
            if entries.contains(where: { $0.hasPrefix(".pcc-system-") || $0.hasPrefix(".pcc-restoration-") }) {
                fputs("warning: PCC mount may still be active; left staging at \(staging.path)\n", stderr)
            } else {
                try? fm.removeItem(at: staging)
            }
        }
        try fm.createDirectory(at: phoneTree, withIntermediateDirectories: false)
        try fm.createDirectory(at: cloudTree, withIntermediateDirectories: false)

        print("[*] Extracting iPhone IPSW...")
        try VPhoneArchiveExtractor.extract(phone.file, into: phoneTree, options: .intoHostDirectory)
        print("[*] Extracting cloudOS IPSW...")
        try VPhoneArchiveExtractor.extract(cloud.file, into: cloudTree, options: .intoHostDirectory)

        try makeUserWritable(phoneTree)
        try mergeCloudOS(from: cloudTree, into: phoneTree)
        let originalManifest = phoneTree.appendingPathComponent("BuildManifest.plist")
        try clone(originalManifest, to: phoneTree.appendingPathComponent("iPhone-BuildManifest.plist"))
        try FirmwareManifest.generate(iPhoneDir: phoneTree, cloudOSDir: cloudTree, verbose: true)
        if let gpuDriverBundle {
            print("[*] Staging GPU driver from local bundle...")
            try VPhonePCCGPUDriver.stage(
                from: gpuDriverBundle,
                into: phoneTree,
                expectedPlatformVersion: cloud.version,
            )
        } else {
            print("[*] Restoring cloudOS in a temporary vphone VM to extract its GPU driver...")
            try VPhonePCCGPURecovery.stage(
                cloudOSDirectory: cloudTree,
                into: phoneTree,
                expectedPlatformVersion: cloud.version,
            )
        }

        let source = resources.gpuCompilerPlugin
        guard fm.fileExists(atPath: source.path) else { throw Error.missingComponent(source) }
        print("[*] Merging bundled GPU compiler plugin...")
        let pluginName = "libAppleParavirtCompilerPluginIOGPUFamily.dylib"
        let destinationPlugin = VPhonePCCGPUDriver.stagedBundle(in: phoneTree).appendingPathComponent(pluginName)
        if fm.fileExists(atPath: destinationPlugin.path) {
            try fm.removeItem(at: destinationPlugin)
        }
        try fm.copyItem(at: source, to: destinationPlugin)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: destinationPlugin.path)

        // The destination did not exist at entry and the staging directory is
        // on the same volume. One rename exposes the complete restore tree.
        guard !fm.fileExists(atPath: destination.path) else { throw Error.existingRestore(destination) }
        try fm.moveItem(at: phoneTree, to: destination)
        print("[+] Restore tree ready: \(destination.path)")
    }

    private static func checkIPhoneName(_ source: String, archive: VPhoneIPSWCache.Archive) throws {
        let basename = URL(string: source)?.lastPathComponent
            ?? URL(fileURLWithPath: source).lastPathComponent
        let pattern = #"^iPhone17,3_([^_]+)_([^_]+)_Restore\.ipsw$"#
        guard let range = basename.range(of: pattern, options: .regularExpression) else { return }
        let components = basename[range].split(separator: "_")
        guard components.count == 4 else { return }
        if String(components[1]) != archive.version || String(components[2]) != archive.build {
            throw Error.sourceNameMismatch(archive.file, version: archive.version, build: archive.build)
        }
    }

    private static func mergeCloudOS(from cloud: URL, into phone: URL) throws {
        let fm = FileManager.default
        try copyMatching(from: cloud, into: phone) { $0.hasPrefix("kernelcache.") }
        for subdirectory in ["agx", "all_flash", "ane", "dfu", "pmp"] {
            let source = cloud.appending(path: "Firmware/\(subdirectory)")
            let destination = phone.appending(path: "Firmware/\(subdirectory)")
            guard fm.fileExists(atPath: source.path) else { throw Error.missingComponent(source) }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try copyMatching(from: source, into: destination) { _ in true }
        }
        let cloudFirmware = cloud.appendingPathComponent("Firmware")
        let phoneFirmware = phone.appendingPathComponent("Firmware")
        try copyMatching(from: cloudFirmware, into: phoneFirmware) { $0.hasSuffix(".im4p") }
        try copyMatching(from: cloud, into: phone, overwrite: false) { $0.hasSuffix(".dmg") }
        try copyMatching(from: cloudFirmware, into: phoneFirmware, overwrite: false) {
            $0.hasSuffix(".dmg.trustcache")
        }
    }

    private static func copyMatching(
        from source: URL,
        into destination: URL,
        overwrite: Bool = true,
        where predicate: (String) -> Bool,
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw Error.missingComponent(source) }
        let names = try fm.contentsOfDirectory(atPath: source.path).filter(predicate)
        for name in names {
            let to = destination.appendingPathComponent(name)
            if !overwrite, fm.fileExists(atPath: to.path) {
                continue
            }
            try clone(source.appendingPathComponent(name), to: to)
        }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw Error.missingComponent(source) }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        if clonefile(source.path, destination.path, 0) == 0 {
            return
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private static func makeUserWritable(_ directory: URL) throws {
        let fm = FileManager.default
        guard let entries = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
        ) else { return }
        for case let file as URL in entries {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                continue
            }
            let attributes = try fm.attributesOfItem(atPath: file.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: mode | 0o200)],
                ofItemAtPath: file.path,
            )
        }
    }
}
