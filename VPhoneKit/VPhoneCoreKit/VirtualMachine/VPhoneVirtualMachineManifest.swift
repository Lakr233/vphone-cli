import Foundation

// MARK: - Errors

public enum VPhoneManifestError: Error {
    case loadFailed(path: String)
    case parseFailed(path: String)
    case unsupportedSchema(path: String, found: Int?)
    case unsupportedRuntimeVersion(String)
    case writeFailed(path: String)
    /// A file name in the manifest is not one plain name inside the VM folder.
    case invalidPath(path: String, field: String)
    /// A VM file exists but is a symbolic link or not a regular file.
    case notRegularFile(path: String)
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
        case let .invalidPath(path, field):
            "The VM configuration at \(path) has an invalid \(field). It must be a single file name inside the VM folder. Recreate the VM, or restore a backup of config.plist."
        case let .notRegularFile(path):
            "\(path) is a symbolic link or not a regular file. VM files must be regular files inside the VM folder. Recreate the VM, or restore the file from a backup."
        }
    }

    public var errorDescription: String? {
        description
    }
}

enum VPhoneRuntimeVersion {
    /// A plain `swift build` executable has no app bundle Info.plist.
    private static let unbundledVersion = "2.0.5"

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
        let manifest: VPhoneVirtualMachineManifest
        do {
            manifest = try decoder.decode(VPhoneVirtualMachineManifest.self, from: data)
        } catch {
            throw VPhoneManifestError.parseFailed(path: url.path)
        }
        try manifest.validateFileNames(configPath: url.path)
        return manifest
    }

    /// Save manifest to a plist file.
    ///
    /// Atomic, so a config.plist that is a symbolic link is replaced by a new
    /// file rather than written through to wherever it points.
    public func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            throw VPhoneManifestError.writeFailed(path: url.path)
        }
    }

    // MARK: - File Names

    /// Whether `name` is one plain entry in a directory: not empty, not `.` or
    /// `..`, no `/`, no NUL, and within NAME_MAX bytes.
    public static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
            && name.utf8.count <= 255
    }

    /// The bundle files this manifest names, keyed by their plist field.
    public var bundleFileNames: [(field: String, name: String)] {
        var names = [
            (field: "diskImage", name: diskImage),
            (field: "nvramStorage", name: nvramStorage),
            (field: "sepStorage", name: sepStorage),
        ]
        if let romImages {
            names.append((field: "romImages.avpBooter", name: romImages.avpBooter))
            names.append((field: "romImages.avpSEPBooter", name: romImages.avpSEPBooter))
        }
        return names
    }

    /// Every file the manifest names must sit directly in the VM folder. An
    /// imported config.plist is untrusted, and vphone-vm overwrites the NVRAM
    /// file and attaches the disk read-write, so a `../` name would reach any
    /// file the user can write.
    func validateFileNames(configPath: String) throws {
        for (field, name) in bundleFileNames where !Self.isPlainFileName(name) {
            throw VPhoneManifestError.invalidPath(path: configPath, field: field)
        }
    }

    // MARK: - Convenience

    /// Resolve a manifest file name to its URL directly inside the VM directory.
    ///
    /// `load(from:)` already rejects names that are not plain; this refuses
    /// them again so no caller can reach outside the bundle with a manifest
    /// built some other way.
    public func resolve(path: String, in vmDirectory: URL) throws -> URL {
        let configPath = vmDirectory.appendingPathComponent("config.plist").path
        guard Self.isPlainFileName(path) else {
            throw VPhoneManifestError.invalidPath(path: configPath, field: "file name \"\(path)\"")
        }
        let url = vmDirectory.appendingPathComponent(path, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL.path
            == vmDirectory.standardizedFileURL.path
        else {
            throw VPhoneManifestError.invalidPath(path: configPath, field: "file name \"\(path)\"")
        }
        return url
    }

    // MARK: - Bundle Files

    /// What `lstat` finds at a VM file's path. A symbolic link is never
    /// followed, so it counts as `.other`.
    public enum FileKind: Sendable {
        case missing
        case regularFile
        case other
    }

    public static func fileKind(at url: URL) -> FileKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .other
        }
        return info.st_mode & S_IFMT == S_IFREG ? .regularFile : .other
    }

    /// Throws unless the entry at `url` is missing or a regular file, and
    /// returns whether it exists. Checked before a VM file is handed to
    /// Virtualization, which opens, creates and overwrites through symbolic
    /// links.
    @discardableResult
    public static func requireRegularFileIfPresent(at url: URL) throws -> Bool {
        switch fileKind(at: url) {
        case .missing: false
        case .regularFile: true
        case .other: throw VPhoneManifestError.notRegularFile(path: url.path)
        }
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
