import Foundation

/// iOS-userland and cloudOS-kernel versions a bundle was restored with, recorded
/// host-side so they're readable without booting the VM. Persisted as
/// `restore-info.json` at the bundle root and rewritten on every restore.
public struct VPhoneRestoreInfo: Codable, Equatable, Sendable {
    public struct OSVersion: Codable, Equatable, Sendable {
        public let version: String
        public let build: String

        public init(version: String, build: String) {
            self.version = version
            self.build = build
        }
    }

    public let ios: OSVersion
    public let cloudOS: OSVersion
    public let variant: String?
    public let device: String?

    public init(ios: OSVersion, cloudOS: OSVersion, variant: String? = nil, device: String? = nil) {
        self.ios = ios
        self.cloudOS = cloudOS
        self.variant = variant
        self.device = device
    }

    static let fileName = "restore-info.json"

    private static let baseDevice = "iPhone99,11"
    private static let experimentalDevice = "iPhone17,3"

    /// Only `exp` rewrites the DeviceTree identity; others keep the base type.
    public static func device(forVariant variant: String) -> String {
        variant == "exp" ? experimentalDevice : baseDevice
    }

    public static func url(forBundle bundle: VPhoneBundle) -> URL {
        bundle.url.appendingPathComponent(fileName)
    }

    /// The `restore-info.json` snapshot if present, else derived live from the
    /// bundle's restore-directory plists — so bundles restored before this file
    /// existed still report their versions. `nil` when neither is available.
    /// A snapshot that is a symbolic link or not a regular file is ignored.
    public static func load(fromBundle bundle: VPhoneBundle) -> VPhoneRestoreInfo? {
        if let directory = readableDirectory(of: bundle),
           let data = try? directory.readData(fileName),
           let info = try? JSONDecoder().decode(VPhoneRestoreInfo.self, from: data)
        {
            return info
        }
        return derive(fromBundle: bundle)
    }

    /// Read both versions from the bundle's `iPhone*_Restore` plists:
    /// `iPhone-BuildManifest.plist` (iOS userland) and the hybrid
    /// `BuildManifest.plist` (cloudOS kernel). `nil` if the restore directory or
    /// either version is missing.
    public static func derive(fromBundle bundle: VPhoneBundle) -> VPhoneRestoreInfo? {
        guard let directory = readableDirectory(of: bundle),
              let name = findRestoreDirectory(in: directory),
              let restore = try? directory.directory(name),
              let ios = readVersion("iPhone-BuildManifest.plist", in: restore),
              let cloudOS = readVersion("BuildManifest.plist", in: restore)
        else { return nil }
        return VPhoneRestoreInfo(ios: ios, cloudOS: cloudOS)
    }

    /// Root runs this in a folder the caller controls (`vm new` under sudo),
    /// so the write is descriptor relative: a new file created exclusively
    /// beside the old one, then renamed over it. A symbolic link planted at
    /// `restore-info.json` is replaced, never written through, and the bundle
    /// folder itself must not be a link.
    public func write(toBundle bundle: VPhoneBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let directory = try VPhoneConfinedDirectory(root: bundle.url.path)
        try directory.writeFile(Self.fileName, contents: data, mode: 0o644)
    }

    /// Set `variant` (and its device) on the bundle's restore-info.json, keeping
    /// the recorded versions. nil if no versions exist yet to preserve.
    @discardableResult
    public static func recordVariant(_ variant: String, toBundle bundle: VPhoneBundle) throws
        -> VPhoneRestoreInfo?
    {
        guard let base = load(fromBundle: bundle) else { return nil }
        let merged = VPhoneRestoreInfo(
            ios: base.ios,
            cloudOS: base.cloudOS,
            variant: variant,
            device: device(forVariant: variant),
        )
        try merged.write(toBundle: bundle)
        return merged
    }

    /// Remove the `iPhone*_Restore/` tree from the bundle; returns its name, or
    /// nil if absent. Record versions (`derive`) first — it reads this directory.
    /// Only a real folder is removed, without following any link inside it:
    /// an `iPhone*_Restore` symbolic link is not a restore tree.
    @discardableResult
    public static func removeBuiltFirmware(fromBundle bundle: VPhoneBundle) throws -> String? {
        let directory = try VPhoneConfinedDirectory(root: bundle.url.path)
        guard let name = findRestoreDirectory(in: directory) else { return nil }
        try directory.removeItem(name)
        return name
    }

    // MARK: - Restore-directory reads

    /// Reads may follow a bundle folder that is itself a link (a VM moved to
    /// another disk); everything below it is still opened without following.
    private static func readableDirectory(of bundle: VPhoneBundle) -> VPhoneConfinedDirectory? {
        try? VPhoneConfinedDirectory(root: bundle.url.resolvingSymlinksInPath().path)
    }

    /// The newest `iPhone*_Restore` entry that `lstat` reports as a folder.
    static func findRestoreDirectory(in directory: VPhoneConfinedDirectory) -> String? {
        let entries = (try? directory.entries()) ?? []
        return entries
            .filter { $0.hasPrefix("iPhone") && $0.hasSuffix("_Restore") }
            .filter { (try? directory.isDirectory($0)) == true }
            .max()
    }

    private static func readVersion(_ name: String, in directory: VPhoneConfinedDirectory) -> OSVersion? {
        guard let data = try? directory.readData(name),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = root["ProductVersion"] as? String, isVersionToken(version),
              let build = root["ProductBuildVersion"] as? String, isVersionToken(build)
        else { return nil }
        return OSVersion(version: version, build: build)
    }

    /// Versions and builds come from plists in a caller-controlled folder and
    /// end up in JSON, logs and UI: accept only `[0-9A-Za-z.]{1,32}`.
    static func isVersionToken(_ text: String) -> Bool {
        (1 ... 32).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E
        }
    }
}
