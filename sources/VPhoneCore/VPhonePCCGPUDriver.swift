import Foundation

/// Stages Apple's paravirtual GPU bundle from a restored PCC System volume or
/// a user-supplied bundle. The bundle is never shipped in the app.
public enum VPhonePCCGPUDriver {
    public static let name = "AppleParavirtGPUMetalIOGPUFamily.bundle"

    public enum Error: Swift.Error, LocalizedError {
        case invalidBundle(URL)
        case wrongPlatformVersion(URL, expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case let .invalidBundle(path):
                "GPU driver bundle is incomplete or has the wrong identifier: \(path.path)"
            case let .wrongPlatformVersion(path, expected, actual):
                "GPU driver at \(path.path) is for iPhoneOS \(actual), expected cloudOS \(expected)"
            }
        }
    }

    public static func stagedBundle(in restoreDirectory: URL) -> URL {
        restoreDirectory.appending(path: ".pcc-gpu/\(name)")
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
        guard actual == expectedPlatformVersion else {
            throw Error.wrongPlatformVersion(
                source,
                expected: expectedPlatformVersion,
                actual: actual,
            )
        }
    }
}
