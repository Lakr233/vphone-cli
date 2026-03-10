import Foundation
import Virtualization

/// VPhoneVirtualMachineManifest represents the on-disk VM configuration manifest.
/// Structure is compatible with security-pcc's VMBundle.Config format.
struct VPhoneVirtualMachineManifest: Codable {
    // MARK: - Platform

    /// Platform type (fixed to vresearch101 for vphone)
    let platformType: PlatformType

    /// Platform fusing mode (prod/dev) - determined by host OS capabilities
    let platformFusing: PlatformFusing?

    /// Machine identifier (opaque ECID representation)
    let machineIdentifier: Data

    // MARK: - Hardware

    /// CPU core count
    let cpuCount: UInt

    /// Memory size in bytes
    let memorySize: UInt64

    // MARK: - Display

    /// Screen configuration
    let screenConfig: ScreenConfig

    // MARK: - Network

    /// Network configuration (NAT mode for vphone)
    let networkConfig: NetworkConfig

    // MARK: - Storage

    /// Disk image filename
    let diskImage: String

    /// NVRAM storage filename
    let nvramStorage: String

    // MARK: - ROMs

    /// ROM image paths
    let romImages: ROMImages

    // MARK: - SEP

    /// SEP storage filename
    let sepStorage: String

    // MARK: - Nested Types

    enum PlatformType: String, Codable {
        case vresearch101
    }

    enum PlatformFusing: String, Codable {
        case prod
        case dev
    }

    struct ScreenConfig: Codable {
        let width: Int
        let height: Int
        let pixelsPerInch: Int
        let scale: Double

        static let `default` = ScreenConfig(
            width: 1290,
            height: 2796,
            pixelsPerInch: 460,
            scale: 3.0
        )
    }

    struct NetworkConfig: Codable {
        let mode: NetworkMode
        let macAddress: String

        enum NetworkMode: String, Codable {
            case nat
            case bridged
            case hostOnly
            case none
        }

        static let `default` = NetworkConfig(mode: .nat, macAddress: "")
    }

    struct ROMImages: Codable {
        let avpBooter: String
        let avpSEPBooter: String
    }

    // MARK: - Init from VM creation parameters

    init(
        platformType: PlatformType = .vresearch101,
        platformFusing: PlatformFusing? = nil,
        machineIdentifier: Data = Data(),
        cpuCount: UInt,
        memorySize: UInt64,
        screenConfig: ScreenConfig = .default,
        networkConfig: NetworkConfig = .default,
        diskImage: String = "Disk.img",
        nvramStorage: String = "nvram.bin",
        romImages: ROMImages,
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
    static func load(from url: URL) throws -> VPhoneVirtualMachineManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VPhoneError.manifestLoadFailed(path: url.path, underlying: error)
        }

        let decoder = PropertyListDecoder()
        do {
            return try decoder.decode(VPhoneVirtualMachineManifest.self, from: data)
        } catch {
            throw VPhoneError.manifestParseFailed(path: url.path, underlying: error)
        }
    }

    /// Save manifest to a plist file
    func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(self)
            try data.write(to: url)
        } catch {
            throw VPhoneError.manifestWriteFailed(path: url.path, underlying: error)
        }
    }

    // MARK: - Convenience

    /// Convert to JSON string for logging/debugging
    func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        do {
            return try String(decoding: encoder.encode(self), as: UTF8.self)
        } catch {
            return "{ }"
        }
    }

    /// Resolve relative path to absolute URL within VM directory
    func resolve(path: String, in vmDirectory: URL) -> URL {
        vmDirectory.appendingPathComponent(path)
    }

    /// Get VZMacMachineIdentifier from manifest data
    func vzMachineIdentifier() -> VZMacMachineIdentifier? {
        VZMacMachineIdentifier(dataRepresentation: machineIdentifier)
    }
}
