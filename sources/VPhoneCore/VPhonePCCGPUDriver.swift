import Foundation

/// Stages Apple's paravirtual GPU bundle from the selected PCC OS image.
/// The bundle belongs to that firmware build; it is never shipped in the app.
public enum VPhonePCCGPUDriver {
    public static let name = "AppleParavirtGPUMetalIOGPUFamily.bundle"

    public enum Error: Swift.Error, LocalizedError {
        case missingOSPath(URL)
        case unsafeOSPath(String)
        case missingBundle(URL)
        case invalidCachedBundle(URL)
        case wrongPlatformVersion(URL, expected: String, actual: String)
        case toolFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case let .missingOSPath(manifest):
                "No vphone600 OS image in PCC manifest: \(manifest.path)"
            case let .unsafeOSPath(path):
                "PCC manifest has an unsafe OS image path: \(path)"
            case let .missingBundle(path):
                "PCC OS image has no GPU driver bundle at \(path.path)"
            case let .invalidCachedBundle(path):
                "GPU driver bundle is incomplete or has the wrong identifier: \(path.path)"
            case let .wrongPlatformVersion(path, expected, actual):
                "GPU driver at \(path.path) is for iPhoneOS \(actual), expected cloudOS \(expected)"
            case let .toolFailed(tool, detail):
                "\(tool) failed while extracting the PCC GPU driver: \(detail)"
            }
        }
    }

    public static func stagedBundle(in restoreDirectory: URL) -> URL {
        restoreDirectory.appending(path: ".pcc-gpu/\(name)")
    }

    public static func osImage(in cloudOSDirectory: URL) throws -> URL {
        let manifest = cloudOSDirectory.appendingPathComponent("BuildManifest.plist")
        let data = try Data(contentsOf: manifest, options: .mappedIfSafe)
        let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let identities = root?["BuildIdentities"] as? [[String: Any]] ?? []
        guard let path = identities.compactMap({ identity -> String? in
            let info = identity["Info"] as? [String: Any]
            guard info?["DeviceClass"] as? String == "vphone600ap" else { return nil }
            let components = identity["Manifest"] as? [String: Any]
            let os = components?["OS"] as? [String: Any]
            let osInfo = os?["Info"] as? [String: Any]
            return osInfo?["Path"] as? String
        }).first else {
            throw Error.missingOSPath(manifest)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
              !parts.contains("") else { throw Error.unsafeOSPath(path) }
        return cloudOSDirectory.appendingPathComponent(path)
    }

    /// Called during `fw prepare`, while the extracted PCC tree still exists.
    /// Only the small bundle survives in the VM's restore tree; the decrypted
    /// system image and mount are discarded before firmware preparation ends.
    public static func stage(
        from cloudOSDirectory: URL,
        into restoreDirectory: URL,
        cachedBundle: URL? = nil,
        expectedPlatformVersion: String? = nil,
    ) throws {
        let fm = FileManager.default
        let destination = stagedBundle(in: restoreDirectory)
        if let cachedBundle {
            let source = cachedBundle.standardizedFileURL.resolvingSymlinksInPath()
            try validateBundle(at: source, expectedPlatformVersion: expectedPlatformVersion)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            print("[+] GPU driver staged from local bundle: \(destination.path)")
            return
        }

        let encrypted = try osImage(in: cloudOSDirectory)
        let scratch = restoreDirectory.appendingPathComponent(".pcc-gpu-extract-\(UUID().uuidString)")
        let plain = scratch.appendingPathComponent("OS.dmg")
        let mount = scratch.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let key = try vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: encrypted) }
        try run("/usr/bin/aea", [
            "decrypt", "-t", "4", "-i", encrypted.path, "-o", plain.path, "-key-value", key,
        ])
        defer {
            _ = try? VPhoneProcessRunner.runCapturing(
                URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path],
            )
        }
        try run("/usr/bin/hdiutil", [
            "attach", "-readonly", "-nobrowse", "-owners", "off",
            "-mountpoint", mount.path, plain.path,
        ])

        let source = mount.appending(path: "System/Library/Extensions/\(name)")
        guard fm.fileExists(atPath: source.path) else { throw Error.missingBundle(source) }
        try validateBundle(at: source, expectedPlatformVersion: expectedPlatformVersion)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        print("[+] GPU driver staged from PCC OS: \(destination.path)")
    }

    static func validateBundle(at source: URL, expectedPlatformVersion: String?) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Error.invalidCachedBundle(source)
        }
        for file in ["AppleParavirtGPUMetalIOGPUFamily",
                     "Info.plist",
                     "_CodeSignature/CodeResources"]
        {
            guard fm.fileExists(atPath: source.appendingPathComponent(file).path) else {
                throw Error.invalidCachedBundle(source)
            }
        }
        let infoURL = source.appendingPathComponent("Info.plist")
        let info = try Data(contentsOf: infoURL, options: .mappedIfSafe)
        let plist = try PropertyListSerialization.propertyList(from: info, format: nil)
        guard let properties = plist as? [String: Any],
              properties["CFBundleIdentifier"] as? String ==
              "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily"
        else { throw Error.invalidCachedBundle(source) }
        if let expectedPlatformVersion {
            let actual = properties["DTPlatformVersion"] as? String ?? "unknown"
            guard actual == expectedPlatformVersion else {
                throw Error.wrongPlatformVersion(
                    source, expected: expectedPlatformVersion, actual: actual,
                )
            }
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: tool), args)
        guard result.succeeded else {
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            throw Error.toolFailed(URL(fileURLWithPath: tool).lastPathComponent,
                                   output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
