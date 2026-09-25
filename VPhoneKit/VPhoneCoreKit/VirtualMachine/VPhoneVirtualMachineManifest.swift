import Foundation

// MARK: - Errors

public enum VPhoneManifestError: Error {
    case loadFailed(path: String)
    case parseFailed(path: String)
    case unsupportedSchema(path: String, found: Int?)
    case unsupportedRuntimeVersion(String)
    case writeFailed(path: String)
}

extension VPhoneManifestError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .loadFailed(path):
            "Unable to read the VM configuration at \(path). Check that the file exists and try again."
        case let .parseFailed(path):
            "The VM configuration at \(path) is not valid. Recreate the VM, or restore a backup of config.plist."
        case let .unsupportedSchema(path, found):
            "The VM configuration at \(path) has \(found.map { "schema version \($0)" } ?? "no valid schema version"). vphone 2.x requires schema version 2. Recreate this VM with `vphone-cli vm create`."
        case let .unsupportedRuntimeVersion(version):
            "This vphone build is version \(version). VMs with schema version 2 require vphone 2.x. Install vphone 2.x before launching this VM."
        case let .writeFailed(path):
            "Unable to save the VM configuration to \(path). Check that the file is writable and try again."
        }
    }

    public var errorDescription: String? {
        description
    }
}

enum VPhoneRuntimeVersion {
    /// A plain `swift build` executable has no app bundle Info.plist.
    private static let unbundledVersion = "2.0.4"

    static var current: String {
        let contents = VPhoneResources.runningExecutable().deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app"
        else { return unbundledVersion }

        let infoURL = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else { return "unknown" }
        return version
    }

    static func requireVersion2() throws {
        let parts = current.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "2", parts.dropFirst().allSatisfy({ Int($0) != nil }) else {
            throw VPhoneManifestError.unsupportedRuntimeVersion(current)
        }
    }
}

/// VPhoneVirtualMachineManifest represents the on-disk VM configuration manifest.
/// Structure extends security-pcc's VMBundle.Config format with a vphone schema marker.
public struct VPhoneVirtualMachineManifest: Codable, Sendable {
    public static let currentSchemaVersion = 2

    /// The VM layout version. Old bundles without this marker cannot be booted.
    public let schemaVersion: Int

    // MARK: - Platform

    /// Platform type (fixed to vresearch101 for vphone)
    public let platformType: PlatformType

    /// Platform fusing mode (prod/dev) - determined by host OS capabilities
    public let platformFusing: PlatformFusing?

    /// Machine identifier (opaque ECID representation)
    public let machineIdentifier: Data

    // MARK: - Hardware

    /// CPU core count
    public let cpuCount: UInt

    /// Memory size in bytes
    public let memorySize: UInt64

    // MARK: - Display

    /// Screen configuration
    public let screenConfig: ScreenConfig

    // MARK: - Network

    /// Network configuration (NAT mode for vphone)
    public let networkConfig: NetworkConfig

    // MARK: - Storage

    /// Disk image filename
    public let diskImage: String

    /// NVRAM storage filename
    public let nvramStorage: String

    // MARK: - ROMs

    /// ROM image paths
    public let romImages: ROMImages?

    // MARK: - SEP

    /// SEP storage filename
    public let sepStorage: String

    // MARK: - Nested Types

    public enum PlatformType: String, Codable, Sendable {
        case vresearch101
    }

    public enum PlatformFusing: String, Codable, Sendable {
        case prod
        case dev
    }

    public struct ScreenConfig: Codable, Sendable {
        public let width: Int
        public let height: Int
        public let pixelsPerInch: Int
        public let scale: Double

        public static let `default` = ScreenConfig(
            width: 1290,
            height: 2796,
            pixelsPerInch: 460,
            scale: 3.0,
        )

        public init(width: Int, height: Int, pixelsPerInch: Int, scale: Double) {
            self.width = width
            self.height = height
            self.pixelsPerInch = pixelsPerInch
            self.scale = scale
        }
    }

    public struct NetworkConfig: Codable, Equatable, Sendable {
        public let mode: NetworkMode
        public let macAddress: String
        /// Host interface identifier to bridge (bridged mode only); nil otherwise.
        public let bridgeInterface: String?

        public enum NetworkMode: String, Codable, Sendable {
            case nat
            case bridged
            case hostOnly
            /// No network device. Named `off` (not `none`) so a `NetworkMode?`
            /// literal `.none` can't silently bind to `Optional.none`.
            case off = "none"
        }

        public static let `default` = NetworkConfig(mode: .nat, macAddress: "")

        public init(mode: NetworkMode, macAddress: String, bridgeInterface: String? = nil) {
            self.mode = mode
            self.macAddress = macAddress
            self.bridgeInterface = bridgeInterface
        }
    }

    public struct ROMImages: Codable, Sendable {
        public let avpBooter: String
        public let avpSEPBooter: String

        /// The names `vm create` copies the ROMs in as.
        public static let `default` = ROMImages(
            avpBooter: "AVPBooter.vresearch1.bin",
            avpSEPBooter: "AVPSEPBooter.vresearch1.bin",
        )

        public init(avpBooter: String, avpSEPBooter: String) {
            self.avpBooter = avpBooter
            self.avpSEPBooter = avpSEPBooter
        }
    }

    // MARK: - Init from VM creation parameters

    public init(
        platformType: PlatformType = .vresearch101,
        platformFusing: PlatformFusing? = nil,
        machineIdentifier: Data = Data(),
        cpuCount: UInt,
        memorySize: UInt64,
        screenConfig: ScreenConfig = .default,
        networkConfig: NetworkConfig = .default,
        diskImage: String = "Disk.img",
        nvramStorage: String = "nvram.bin",
        romImages: ROMImages?,
        sepStorage: String = "SEPStorage",
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.platformType = platformType
        self.platformFusing = platformFusing
        self.machineIdentifier = machineIdentifier
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.screenConfig = screenConfig
        self.networkConfig = networkConfig
        self.diskImage = diskImage
        self.nvramStorage = nvramStorage
        self.romImages = romImages
        self.sepStorage = sepStorage
    }

    // MARK: - Creation

    /// The manifest a freshly created VM starts with.
    ///
    /// Replaces `scripts/vm_manifest.py`. Everything not named here is a
    /// default that the guest or the framework fills in later:
    /// `machineIdentifier` is empty until first boot persists one, and
    /// `macAddress` is empty so Virtualization assigns it — forcing a MAC
    /// breaks guest networking.
    ///
    /// `platformFusing` stays nil unless asked for, which leaves the key out
    /// of the plist entirely and lets the host OS decide.
    public static func newVM(
        cpuCount: UInt = 8,
        memoryMB: UInt64 = 8192,
        platformFusing: PlatformFusing? = nil,
    ) -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            platformFusing: platformFusing,
            cpuCount: cpuCount,
            memorySize: memoryMB * 1024 * 1024,
            romImages: .default,
        )
    }

    // MARK: - Load/Save

    /// Load manifest from a plist file
    public static func load(from url: URL) throws -> VPhoneVirtualMachineManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw VPhoneManifestError.loadFailed(path: url.path)
        }

        let decoder = PropertyListDecoder()
        struct SchemaMarker: Decodable { let schemaVersion: Int? }
        let marker = try? decoder.decode(SchemaMarker.self, from: data)
        guard marker?.schemaVersion == Self.currentSchemaVersion else {
            throw VPhoneManifestError.unsupportedSchema(path: url.path, found: marker?.schemaVersion)
        }
        try VPhoneRuntimeVersion.requireVersion2()
        do {
            return try decoder.decode(VPhoneVirtualMachineManifest.self, from: data)
        } catch {
            throw VPhoneManifestError.parseFailed(path: url.path)
        }
    }

    /// Save manifest to a plist file
    public func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(self)
            try data.write(to: url)
        } catch {
            throw VPhoneManifestError.writeFailed(path: url.path)
        }
    }

    // MARK: - Convenience

    /// Resolve relative path to absolute URL within VM directory
    public func resolve(path: String, in vmDirectory: URL) -> URL {
        vmDirectory.appendingPathComponent(path)
    }

    // MARK: - Editing

    public func updating(
        cpuCount: UInt? = nil,
        memorySize: UInt64? = nil,
        machineIdentifier: Data? = nil,
        networkConfig: NetworkConfig? = nil,
    ) -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            platformType: platformType,
            platformFusing: platformFusing,
            machineIdentifier: machineIdentifier ?? self.machineIdentifier,
            cpuCount: cpuCount ?? self.cpuCount,
            memorySize: memorySize ?? self.memorySize,
            screenConfig: screenConfig,
            networkConfig: networkConfig ?? self.networkConfig,
            diskImage: diskImage,
            nvramStorage: nvramStorage,
            romImages: romImages,
            sepStorage: sepStorage,
        )
    }
}
