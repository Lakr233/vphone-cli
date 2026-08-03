import Foundation
import Virtualization

// MARK: - Errors

public enum VPhoneManifestError: Error {
    case loadFailed(path: String, underlying: Error)
    case parseFailed(path: String, underlying: Error)
    case writeFailed(path: String, underlying: Error)
}

extension VPhoneManifestError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .loadFailed(path, underlying): "Failed to load manifest from \(path): \(underlying)"
        case let .parseFailed(path, underlying): "Failed to parse manifest at \(path): \(underlying)"
        case let .writeFailed(path, underlying): "Failed to write manifest to \(path): \(underlying)"
        }
    }
    public var errorDescription: String? { description }
}

/// VPhoneVirtualMachineManifest represents the on-disk VM configuration manifest.
/// Structure is compatible with security-pcc's VMBundle.Config format.
public struct VPhoneVirtualMachineManifest: Codable, Sendable {
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
            scale: 3.0
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
        sepStorage: String = "SEPStorage"
    ) {
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

    // MARK: - Load/Save

    /// Load manifest from a plist file
    public static func load(from url: URL) throws -> VPhoneVirtualMachineManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VPhoneManifestError.loadFailed(path: url.path, underlying: error)
        }

        let decoder = PropertyListDecoder()
        do {
            return try decoder.decode(VPhoneVirtualMachineManifest.self, from: data)
        } catch {
            throw VPhoneManifestError.parseFailed(path: url.path, underlying: error)
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
            throw VPhoneManifestError.writeFailed(path: url.path, underlying: error)
        }
    }

    // MARK: - Convenience

    /// Convert to JSON string for logging/debugging
    public func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        do {
            return try String(decoding: encoder.encode(self), as: UTF8.self)
        } catch {
            return "{ }"
        }
    }

    /// Resolve relative path to absolute URL within VM directory
    public func resolve(path: String, in vmDirectory: URL) -> URL {
        vmDirectory.appendingPathComponent(path)
    }

    /// Get VZMacMachineIdentifier from manifest data
    public func vzMachineIdentifier() -> VZMacMachineIdentifier? {
        VZMacMachineIdentifier(dataRepresentation: machineIdentifier)
    }

    // MARK: - Editing

    public func updating(
        cpuCount: UInt? = nil,
        memorySize: UInt64? = nil,
        screenConfig: ScreenConfig? = nil,
        machineIdentifier: Data? = nil,
        networkConfig: NetworkConfig? = nil
    ) -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            platformType: platformType,
            platformFusing: platformFusing,
            machineIdentifier: machineIdentifier ?? self.machineIdentifier,
            cpuCount: cpuCount ?? self.cpuCount,
            memorySize: memorySize ?? self.memorySize,
            screenConfig: screenConfig ?? self.screenConfig,
            networkConfig: networkConfig ?? self.networkConfig,
            diskImage: diskImage,
            nvramStorage: nvramStorage,
            romImages: romImages,
            sepStorage: sepStorage
        )
    }
}
