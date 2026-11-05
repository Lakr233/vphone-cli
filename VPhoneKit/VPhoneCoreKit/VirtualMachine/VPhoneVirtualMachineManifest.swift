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
    private static let unbundledVersion = "2.2.0"

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

    /// Missing in older manifests, which keep the original USB keyboard.
    public let hardwareKeyboardEnabled: Bool?

    public var usesHardwareKeyboard: Bool {
        hardwareKeyboardEnabled ?? true
    }

    // MARK: - Startup

    /// Whether vphone-vm wakes the guest and dismisses its Lock Screen each
    /// time it connects to a freshly started vphoned. Missing in older
    /// manifests, which leave the guest at the Lock Screen.
    public let unlocksAtStartup: Bool?

    public var unlocksScreenAtStartup: Bool {
        unlocksAtStartup ?? false
    }

    /// Whether vphone-vm forwards the Mac's location to the guest while it
    /// runs. Missing in older manifests, which keep the Mac's location to
    /// itself.
    public let syncsHostLocation: Bool?

    public var sharesHostLocation: Bool {
        syncsHostLocation ?? false
    }

    // MARK: - Developer

    /// Whether vphone-vm holds the guest's CoreDevice tunnel open while it
    /// runs, so Xcode and Instruments see the guest online. Missing in older
    /// manifests, which leave the tunnel to whoever asks for it.
    public let holdsDeveloperTunnel: Bool?

    public var keepsDeveloperTunnelOpen: Bool {
        holdsDeveloperTunnel ?? false
    }

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

    // MARK: - Guest Device

    /// Product type of the device whose IPSW supplied the guest OS, as
    /// `fw prepare` found it. Absent for an iPhone17,3 guest and for every VM
    /// made before iPad guests existed.
    public let guestProductType: String?

    /// The guest device `fw patch` presents in the device tree.
    public var guestDevice: VPhoneGuestDevice {
        VPhoneGuestDevice.named(guestProductType) ?? .default
    }

    // MARK: - Nested Types

    public enum PlatformType: String, Codable, Sendable {
        case vresearch101
    }

    public enum PlatformFusing: String, Codable, Sendable {
        case prod
        case dev
    }

    public struct ScreenConfig: Codable, Equatable, Sendable {
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
        /// The guest NIC's MAC, `aa:bb:cc:dd:ee:ff`. Empty until first boot
        /// generates one and saves it here, so the guest keeps one identity
        /// (and one DHCP lease) across launches.
        public let macAddress: String
        /// Host interface identifier to bridge (bridged mode only); nil otherwise.
        public let bridgeInterface: String?
        /// A fixed guest address; nil leaves the address to DHCP. How each mode
        /// realizes it is in `VPhoneNetworking.plan`.
        public let ipv4: IPv4Config?
        /// Host ports carried into the guest. Nil and empty both forward nothing.
        public let portForwards: [PortForward]?
        /// The name the guest answers to as `<name>.local` over mDNS. Nil, the
        /// default, leaves the guest's own name alone.
        public let localHostName: String?
        /// Whether the guest resolves this Mac's `.local` name to the address it
        /// reaches the Mac at, through a record vphoned registers with the
        /// guest's mDNSResponder. Nil means yes; see `VPhoneNetworking.plan`.
        public let resolvesMacName: Bool?
        /// Whether, in `nat`, the guest reaches the other machines on the Mac's
        /// shared network and they reach it, as a watch and the phone it pairs
        /// with must. Nil means yes, except for a fixed address on the first
        /// shared network, set before this existed; false keeps vmnet's
        /// isolation, where each guest reaches only the Mac and beyond.
        public let reachesPeers: Bool?

        public enum NetworkMode: String, Codable, Sendable {
            case nat
            case bridged
            case hostOnly
            /// The guest's NIC is carried by this process. Egress leaves through
            /// ordinary host sockets, so it follows the host's routing table —
            /// and therefore a VPN — which vmnet's `nat` cannot do because its
            /// masquerade is pinned to a physical interface.
            case tunnel
            /// No network device. Named `off` (not `none`) so a `NetworkMode?`
            /// literal `.none` can't silently bind to `Optional.none`.
            case off = "none"
        }

        public static let `default` = NetworkConfig(mode: .nat, macAddress: "")

        public init(
            mode: NetworkMode,
            macAddress: String,
            bridgeInterface: String? = nil,
            ipv4: IPv4Config? = nil,
            portForwards: [PortForward]? = nil,
            localHostName: String? = nil,
            resolvesMacName: Bool? = nil,
            reachesPeers: Bool? = nil,
        ) {
            self.mode = mode
            self.macAddress = macAddress
            self.bridgeInterface = bridgeInterface
            self.ipv4 = ipv4
            self.portForwards = portForwards
            self.localHostName = localHostName
            self.resolvesMacName = resolvesMacName
            self.reachesPeers = reachesPeers
        }

        /// The same configuration with one field replaced.
        public func with(
            mode: NetworkMode? = nil,
            macAddress: String? = nil,
            bridgeInterface: String?? = nil,
            ipv4: IPv4Config?? = nil,
            portForwards: [PortForward]?? = nil,
            localHostName: String?? = nil,
            resolvesMacName: Bool?? = nil,
            reachesPeers: Bool?? = nil,
        ) -> NetworkConfig {
            NetworkConfig(
                mode: mode ?? self.mode,
                macAddress: macAddress ?? self.macAddress,
                bridgeInterface: bridgeInterface ?? self.bridgeInterface,
                ipv4: ipv4 ?? self.ipv4,
                portForwards: portForwards ?? self.portForwards,
                localHostName: localHostName ?? self.localHostName,
                resolvesMacName: resolvesMacName ?? self.resolvesMacName,
                reachesPeers: reachesPeers ?? self.reachesPeers,
            )
        }

        /// A fixed IPv4 configuration for the guest's NIC.
        ///
        /// Addresses are kept as dotted strings so `config.plist` stays readable
        /// and editable by hand. `VPhoneNetworking.validate` is what gives them
        /// meaning, and it runs both when the config is edited and at boot.
        public struct IPv4Config: Codable, Equatable, Sendable {
            public let address: String
            public let prefixLength: Int
            /// The default route. Nil means the first host of the subnet, which
            /// is where `nat` and `tunnel` put the host.
            public let router: String?
            /// Resolvers handed to the guest. Nil or empty means the router.
            public let dns: [String]?

            public init(address: String, prefixLength: Int, router: String? = nil, dns: [String]? = nil) {
                self.address = address
                self.prefixLength = prefixLength
                self.router = router
                self.dns = dns
            }
        }

        /// One host port carried to a guest port.
        public struct PortForward: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
            public enum TransportProtocol: String, Codable, Sendable, CaseIterable {
                case tcp
                case udp
            }

            public let transport: TransportProtocol
            /// The host address to listen on. Nil is loopback only, so a guest
            /// service is not on the LAN unless someone asks for that.
            public let hostAddress: String?
            public let hostPort: Int
            public let guestPort: Int

            private enum CodingKeys: String, CodingKey {
                case transport = "protocol"
                case hostAddress, hostPort, guestPort
            }

            public init(transport: TransportProtocol = .tcp, hostAddress: String? = nil, hostPort: Int, guestPort: Int) {
                self.transport = transport
                self.hostAddress = hostAddress
                self.hostPort = hostPort
                self.guestPort = guestPort
            }

            /// The address actually listened on.
            public var listenAddress: String {
                hostAddress ?? "127.0.0.1"
            }

            /// `tcp:127.0.0.1:8022:22`, the form `--forward` accepts.
            public var description: String {
                "\(transport.rawValue):\(listenAddress):\(hostPort):\(guestPort)"
            }
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
        guestProductType: String? = nil,
        hardwareKeyboardEnabled: Bool? = nil,
        unlocksAtStartup: Bool? = nil,
        syncsHostLocation: Bool? = nil,
        holdsDeveloperTunnel: Bool? = nil,
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
        self.guestProductType = guestProductType
        self.hardwareKeyboardEnabled = hardwareKeyboardEnabled
        self.unlocksAtStartup = unlocksAtStartup
        self.syncsHostLocation = syncsHostLocation
        self.holdsDeveloperTunnel = holdsDeveloperTunnel
    }

    // MARK: - Creation

    /// The manifest a freshly created VM starts with.
    ///
    /// Replaces `scripts/vm_manifest.py`. Everything not named here is a
    /// default that the guest or the framework fills in later:
    /// `machineIdentifier` and `macAddress` are empty until first boot
    /// generates and persists them.
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
        hardwareKeyboardEnabled: Bool? = nil,
        unlocksAtStartup: Bool? = nil,
        syncsHostLocation: Bool? = nil,
        holdsDeveloperTunnel: Bool? = nil,
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
            guestProductType: guestProductType,
            hardwareKeyboardEnabled: hardwareKeyboardEnabled ?? self.hardwareKeyboardEnabled,
            unlocksAtStartup: unlocksAtStartup ?? self.unlocksAtStartup,
            syncsHostLocation: syncsHostLocation ?? self.syncsHostLocation,
            holdsDeveloperTunnel: holdsDeveloperTunnel ?? self.holdsDeveloperTunnel,
        )
    }

    /// This manifest with other ROM file names.
    public func updating(romImages: ROMImages) -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            platformType: platformType,
            platformFusing: platformFusing,
            machineIdentifier: machineIdentifier,
            cpuCount: cpuCount,
            memorySize: memorySize,
            screenConfig: screenConfig,
            networkConfig: networkConfig,
            diskImage: diskImage,
            nvramStorage: nvramStorage,
            romImages: romImages,
            sepStorage: sepStorage,
            guestProductType: guestProductType,
            hardwareKeyboardEnabled: hardwareKeyboardEnabled,
            unlocksAtStartup: unlocksAtStartup,
            syncsHostLocation: syncsHostLocation,
            holdsDeveloperTunnel: holdsDeveloperTunnel,
        )
    }

    /// This manifest for a guest running `device`'s OS: its product type and
    /// its display. An iPhone17,3 guest records no product type, so its
    /// configuration stays readable by bundles that predate iPad guests.
    public func updating(guestDevice device: VPhoneGuestDevice) -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            platformType: platformType,
            platformFusing: platformFusing,
            machineIdentifier: machineIdentifier,
            cpuCount: cpuCount,
            memorySize: memorySize,
            screenConfig: device.screen,
            networkConfig: networkConfig,
            diskImage: diskImage,
            nvramStorage: nvramStorage,
            romImages: romImages,
            sepStorage: sepStorage,
            guestProductType: device == .default ? nil : device.productType,
            hardwareKeyboardEnabled: hardwareKeyboardEnabled,
            unlocksAtStartup: unlocksAtStartup,
            syncsHostLocation: syncsHostLocation,
            holdsDeveloperTunnel: holdsDeveloperTunnel,
        )
    }
}
