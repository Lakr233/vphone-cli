import Foundation

/// Stages Apple's paravirtual GPU bundle from a restored PCC System volume or
/// a user-supplied bundle. The bundle is never shipped in the app.
public enum VPhonePCCGPUDriver {
    public static let name = "AppleParavirtGPUMetalIOGPUFamily.bundle"

    public enum Error: Swift.Error, LocalizedError {
        case invalidBundle(URL)
        case wrongPlatformVersion(URL, expected: String, actual: String)
        case imageToolFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case let .invalidBundle(path):
                "The GPU driver at \(path.path) is incomplete or invalid. Download the firmware again and retry."
            case let .wrongPlatformVersion(path, expected, actual):
                "The GPU driver at \(path.path) is for iPhoneOS \(actual), but cloudOS \(expected) is required. Choose a matching driver and try again."
            case let .imageToolFailed(tool, detail):
                "\(tool) failed while extracting the PCC GPU driver: \(detail)"
            }
        }
    }

    public static func stagedBundle(in restoreDirectory: URL) -> URL {
        restoreDirectory.appending(path: ".pcc-gpu/\(name)")
    }

    /// Extract a driver without booting an older PCC kernel. AEA images that
    /// do not carry a key return false so the caller can use its restore path.
    /// An invalid key, archive, image or bundle is an error, not a cache hit.
    @discardableResult
    public static func stage(
        fromSystemImage image: URL,
        into restoreDirectory: URL,
        expectedPlatformVersion: String,
    ) throws -> Bool {
        let key: String?
        if image.pathExtension == "aea" {
            guard let embedded = try VPhoneAEA.embeddedSymmetricKey(of: image) else { return false }
            key = embedded
        } else {
            key = nil
        }
        let fm = FileManager.default
        // The preparer's outer cleanup retains .pcc-system-* directories
        // when an image might still be attached.
        let work = restoreDirectory.deletingLastPathComponent().appending(path: ".pcc-system-gpu-\(UUID().uuidString)")
        let mount = work.appending(path: "mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        var mountAttempted = false
        var device: String?
        defer {
            let detached: Bool
            if let device {
                detached = (try? runImageTool("/usr/bin/hdiutil", ["detach", device])) != nil
                    || (try? runImageTool("/usr/bin/hdiutil", ["detach", "-force", device])) != nil
            } else {
                detached = !mountAttempted
            }
            // An attach can fail after creating a device. Never traverse or
            // remove a possibly mounted image when its device is unknown.
            if detached {
                try? fm.removeItem(at: work)
            } else {
                fputs("warning: PCC GPU image may still be attached; left \(work.path)\n", stderr)
            }
        }
        let disk: URL
        if let key {
            disk = work.appending(path: "System.dmg")
            try runImageTool("/usr/bin/aea", ["decrypt", "-i", image.path, "-o", disk.path, "-key-value", key])
        } else {
            disk = image
        }
        mountAttempted = true
        let output = try runImageTool("/usr/bin/hdiutil", [
            "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, disk.path,
        ])
        let attachment = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any]
        device = (attachment?["system-entities"] as? [[String: Any]])?
            .compactMap { $0["dev-entry"] as? String }
            .first { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
        guard device != nil else { throw Error.imageToolFailed("hdiutil", "the attached image reported no disk device") }
        try stage(from: mount.appending(path: "System/Library/Extensions/\(name)"),
                  into: restoreDirectory, expectedPlatformVersion: expectedPlatformVersion)
        return true
    }

    @discardableResult
    private static func runImageTool(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: executable), arguments)
        guard result.succeeded else {
            throw Error.imageToolFailed(URL(fileURLWithPath: executable).lastPathComponent,
                                        result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout
    }

    /// Keep only the validated bundle in the VM's restore tree.
    public static func stage(
        from bundle: URL,
        into restoreDirectory: URL,
        expectedPlatformVersion: String,
    ) throws {
        let fm = FileManager.default
        let destination = stagedBundle(in: restoreDirectory)
        let source = bundle.standardizedFileURL.resolvingSymlinksInPath()
        try validateBundle(at: source, expectedPlatformVersion: expectedPlatformVersion)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        print("[+] GPU driver staged: \(destination.path)")
    }

    /// A point release's driver names the SDK it was built with: cloudOS
    /// 18.7.2 ships one that says 18.7. Compare major and minor only.
    public static func release(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func validateBundle(at source: URL, expectedPlatformVersion: String) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Error.invalidBundle(source)
        }
        for file in ["AppleParavirtGPUMetalIOGPUFamily",
                     "Info.plist",
                     "_CodeSignature/CodeResources"]
        {
            guard fm.fileExists(atPath: source.appendingPathComponent(file).path) else {
                throw Error.invalidBundle(source)
            }
        }
        let infoURL = source.appendingPathComponent("Info.plist")
        let info = try Data(contentsOf: infoURL, options: .mappedIfSafe)
        let plist = try PropertyListSerialization.propertyList(from: info, format: nil)
        guard let properties = plist as? [String: Any],
              properties["CFBundleIdentifier"] as? String ==
              "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily"
        else { throw Error.invalidBundle(source) }
        let actual = properties["DTPlatformVersion"] as? String ?? "unknown"
        guard release(actual) == release(expectedPlatformVersion) else {
            throw Error.wrongPlatformVersion(
                source,
                expected: expectedPlatformVersion,
                actual: actual,
            )
        }
    }
}
