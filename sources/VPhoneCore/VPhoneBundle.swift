import Foundation

// MARK: - Bundle

public struct VPhoneBundle: Sendable {
    public let url: URL
    public let manifest: VPhoneVirtualMachineManifest

    public init(url: URL, manifest: VPhoneVirtualMachineManifest) {
        self.url = url
        self.manifest = manifest
    }

    public var name: String { url.lastPathComponent }
    public var configURL: URL { url.appendingPathComponent("config.plist") }

    public var diskSizeBytes: Int64 {
        let disk = url.appendingPathComponent(manifest.diskImage)
        let attrs = try? FileManager.default.attributesOfItem(atPath: disk.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func load(at url: URL) throws -> VPhoneBundle {
        let manifest = try VPhoneVirtualMachineManifest.load(
            from: url.appendingPathComponent("config.plist"))
        return VPhoneBundle(url: url, manifest: manifest)
    }
}
