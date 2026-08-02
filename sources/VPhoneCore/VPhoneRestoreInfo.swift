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

    public static let baseDevice = "iPhone99,11"
    public static let experimentalDevice = "iPhone17,3"

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
    public static func load(fromBundle bundle: VPhoneBundle) -> VPhoneRestoreInfo? {
        if let data = try? Data(contentsOf: url(forBundle: bundle)),
           let info = try? JSONDecoder().decode(VPhoneRestoreInfo.self, from: data) {
            return info
        }
        return derive(fromBundle: bundle)
    }

    /// Read both versions from the bundle's `iPhone*_Restore` plists:
    /// `iPhone-BuildManifest.plist` (iOS userland) and the hybrid
    /// `BuildManifest.plist` (cloudOS kernel). `nil` if the restore directory or
    /// either version is missing.
    public static func derive(fromBundle bundle: VPhoneBundle) -> VPhoneRestoreInfo? {
        guard let restoreDir = findRestoreDirectory(inBundle: bundle),
              let ios = readVersion(restoreDir.appendingPathComponent("iPhone-BuildManifest.plist")),
              let cloudOS = readVersion(restoreDir.appendingPathComponent("BuildManifest.plist"))
        else { return nil }
        return VPhoneRestoreInfo(ios: ios, cloudOS: cloudOS)
    }

    public func write(toBundle bundle: VPhoneBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(forBundle: bundle))
    }

    /// Set `variant` (and its device) on the bundle's restore-info.json, keeping
    /// the recorded versions. nil if no versions exist yet to preserve.
    @discardableResult
    public static func recordVariant(_ variant: String, toBundle bundle: VPhoneBundle) throws
        -> VPhoneRestoreInfo?
    {
        guard let base = load(fromBundle: bundle) else { return nil }
        let merged = VPhoneRestoreInfo(
            ios: base.ios, cloudOS: base.cloudOS,
            variant: variant, device: device(forVariant: variant))
        try merged.write(toBundle: bundle)
        return merged
    }

    /// Remove the `iPhone*_Restore/` tree from the bundle; returns its name, or
    /// nil if absent. Record versions (`derive`) first — it reads this directory.
    @discardableResult
    public static func removeBuiltFirmware(fromBundle bundle: VPhoneBundle) throws -> String? {
        guard let dir = findRestoreDirectory(inBundle: bundle) else { return nil }
        try FileManager.default.removeItem(at: dir)
        return dir.lastPathComponent
    }

    // MARK: - Restore-directory reads

    static func findRestoreDirectory(inBundle bundle: VPhoneBundle) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: bundle.url, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("iPhone") && $0.lastPathComponent.hasSuffix("_Restore") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readVersion(_ plist: URL) -> OSVersion? {
        guard let data = try? Data(contentsOf: plist),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = root["ProductVersion"] as? String,
              let build = root["ProductBuildVersion"] as? String
        else { return nil }
        return OSVersion(version: version, build: build)
    }
}
