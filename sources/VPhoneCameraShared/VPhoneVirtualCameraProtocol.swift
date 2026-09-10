import CryptoKit
import Darwin
import Foundation

/// Identifiers and wire-format constants shared by the host app and the
/// CoreMediaIO system extension.
public enum VPhoneVirtualCamera {
    private static let defaultHostBundleIdentifier = "com.vphone.cli"

    public static var hostBundleIdentifier: String {
        if let configured = ProcessInfo.processInfo.environment["APP_BUNDLE_ID"],
           Self.isBundleIdentifier(configured) {
            return configured
        }
        if let bundleID = Self.runtimeBundleIdentifier {
            if bundleID.hasSuffix(".camera-installer") {
                return String(bundleID.dropLast(".camera-installer".count))
            }
            if bundleID.hasSuffix(".camera") {
                return String(bundleID.dropLast(".camera".count))
            }
            return bundleID
        }
        return defaultHostBundleIdentifier
    }

    public static var extensionIdentifier: String {
        if let configured = ProcessInfo.processInfo.environment["CAMERA_BUNDLE_ID"],
           Self.isBundleIdentifier(configured) {
            return configured
        }
        if let configuredBase = ProcessInfo.processInfo.environment["APP_BUNDLE_ID"],
           Self.isBundleIdentifier(configuredBase) {
            return "\(configuredBase).camera"
        }
        if let bundleID = Self.runtimeBundleIdentifier {
            if bundleID.hasSuffix(".camera") {
                return bundleID
            }
            if bundleID.hasSuffix(".camera-installer") {
                return String(bundleID.dropLast(".camera-installer".count)) + ".camera"
            }
            return "\(bundleID).camera"
        }
        return "\(defaultHostBundleIdentifier).camera"
    }

    private static func isBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static var runtimeBundleIdentifier: String? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app"
                || bundle.bundleURL.pathExtension == "systemextension",
              let bundleID = bundle.bundleIdentifier,
              Self.isBundleIdentifier(bundleID) else {
            return nil
        }
        return bundleID
    }

    public static let deviceName = "VPhone Display"
    public static var deviceIdentifier: String { "\(hostBundleIdentifier).display" }
    public static var streamIdentifier: String { "\(deviceIdentifier).video" }
    public static let frameWidth = 720
    public static let frameHeight = 1560
    public static let frameRate: Int32 = 30
    @available(*, deprecated, message: "CMIO endpoints are dynamically allocated per VM")
    public static var loopbackPort: UInt16 { loopbackPort(for: extensionIdentifier) }
    @available(*, deprecated, message: "CMIO endpoints are dynamically allocated per VM")
    public static func loopbackPort(for identifier: String) -> UInt16 {
        var hash: UInt32 = 2_166_136_261
        for byte in identifier.utf8 { hash ^= UInt32(byte); hash &*= 16_777_619 }
        return UInt16(49_152 + hash % 16_384)
    }

    /// The group is injected at build time and can be overridden for local
    /// diagnostics. Both the Host and the CMIO extension must use the same
    /// provisioned group to see the registration directory.
    public static var appGroupIdentifier: String {
        if let value = ProcessInfo.processInfo.environment["CAMERA_APP_GROUP"],
           isBundleIdentifier(value) { return value }
        return "group.com.vp.vphone.shared"
    }

    public static var registryDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["VPHONE_CAMERA_REGISTRY_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return container.appendingPathComponent("registrations", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/CMIO/registrations", isDirectory: true)
    }

    public static func stableUUID(namespace: String, value: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace)\0\(value)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}

public struct VPhoneVirtualCameraRegistration: Codable, Sendable, Equatable {
    public let vmID: String
    public let displayName: String
    public let deviceID: UUID
    public let streamID: UUID
    public let endpoint: String
    public let pid: Int32
    public let generation: UUID
    public let updatedAt: Date

    public init(vmID: String, displayName: String, endpoint: String, pid: Int32,
                generation: UUID = UUID(), updatedAt: Date = Date()) {
        self.vmID = vmID
        self.displayName = displayName
        self.deviceID = VPhoneVirtualCamera.stableUUID(namespace: "device", value: vmID)
        self.streamID = VPhoneVirtualCamera.stableUUID(namespace: "stream", value: vmID)
        self.endpoint = endpoint
        self.pid = pid
        self.generation = generation
        self.updatedAt = updatedAt
    }
}

public enum VPhoneVirtualCameraRegistry {
    private static let queue = DispatchQueue(label: "com.vphone.camera.registry")

    public static func write(_ registration: VPhoneVirtualCameraRegistration) throws {
        try queue.sync {
            let fm = FileManager.default
            try fm.createDirectory(at: VPhoneVirtualCamera.registryDirectory,
                                   withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(registration)
            let target = fileURL(for: registration.vmID)
            let temporary = target.appendingPathExtension("tmp-\(UUID().uuidString)")
            try data.write(to: temporary, options: .atomic)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: temporary, to: target)
        }
    }

    public static func remove(vmID: String) {
        queue.sync { try? FileManager.default.removeItem(at: fileURL(for: vmID)) }
    }

    public static func readAll(now: Date = Date()) -> [VPhoneVirtualCameraRegistration] {
        queue.sync {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: VPhoneVirtualCamera.registryDirectory, includingPropertiesForKeys: nil) else { return [] }
            return urls.compactMap { url -> VPhoneVirtualCameraRegistration? in
                guard url.pathExtension == "json",
                      let data = try? Data(contentsOf: url),
                      let registration = try? JSONDecoder().decode(
                        VPhoneVirtualCameraRegistration.self, from: data) else { return nil }
                return now.timeIntervalSince(registration.updatedAt) <= 5.0 ? registration : nil
            }.sorted { $0.vmID < $1.vmID }
        }
    }

    /// Read registrations from the user-side relay when this code runs inside
    /// the CMIO system extension. System extensions run as
    /// `_cmiodalassistants`, whose App Group container is intentionally
    /// different from the interactive user's App Group container. Reading the
    /// filesystem directly would therefore make a healthy Host endpoint
    /// invisible to AVFoundation.
    ///
    /// A failed relay request deliberately falls back to the local registry:
    /// that keeps host-side diagnostics and unit tests useful while making the
    /// extension fail closed (no synthetic device) when no user-side Host is
    /// available.
    public static func readPublished(now: Date = Date()) -> [VPhoneVirtualCameraRegistration] {
        VPhoneVirtualCameraRegistryRelay.fetchRegistrations(now: now) ?? readAll(now: now)
    }

    private static func fileURL(for vmID: String) -> URL {
        let safe = vmID.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return VPhoneVirtualCamera.registryDirectory.appendingPathComponent("\(safe).json")
    }
}

/// User-session relay for the CMIO extension's discovery data.
///
/// The payload is metadata only. Frame bytes remain on each VM's separately
/// allocated loopback endpoint and each consumer must still pass the
/// vmID+generation handshake before it receives a frame. Every VM Host tries
/// to own the same loopback relay; `SO_REUSEPORT` permits coexistence and a
/// surviving VM can take over after the original owner exits.
public final class VPhoneVirtualCameraRegistryRelay: @unchecked Sendable {
    public static let port: UInt16 = 57_300
    private static let request = Data("VPHONE-CMIO-REGISTRY/1\n".utf8)
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "com.vphone.camera.registry-relay")

    public init?() {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return nil }
        listenFD = fd
        queue.async { [weak self] in self?.acceptLoop() }
    }

    deinit { close(listenFD) }

    public static func fetchRegistrations(now: Date = Date()) -> [VPhoneVirtualCameraRegistration]? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0, writeAll(Self.request, to: fd) else { return nil }
        shutdown(fd, SHUT_WR)
        guard let data = readToEOF(from: fd, maxBytes: 128 * 1024),
              let values = try? JSONDecoder().decode([VPhoneVirtualCameraRegistration].self, from: data) else {
            return nil
        }
        return values.filter { now.timeIntervalSince($0.updatedAt) <= 5.0 }
            .sorted { $0.vmID < $1.vmID }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // `acceptLoop` itself permanently occupies `queue`; dispatching
            // back onto that same serial queue would accept the connection but
            // starve its request handler forever.
            DispatchQueue.global(qos: .userInitiated).async { Self.handle(client) }
        }
    }

    private static func handle(_ fd: Int32) {
        defer { shutdown(fd, SHUT_RDWR); close(fd) }
        guard readLine(from: fd) == String(decoding: request, as: UTF8.self),
              let data = try? JSONEncoder().encode(VPhoneVirtualCameraRegistry.readAll()) else { return }
        _ = writeAll(data, to: fd)
    }

    private static func readLine(from fd: Int32) -> String? {
        var data = Data()
        while data.count < 256 {
            var byte: UInt8 = 0
            let count = read(fd, &byte, 1)
            if count == 1 {
                data.append(byte)
                if byte == 10 { return String(data: data, encoding: .utf8) }
            } else if count < 0 && errno == EINTR { continue }
            else { return nil }
        }
        return nil
    }

    private static func readToEOF(from fd: Int32, maxBytes: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count) }
            else if count == 0 { return data }
            else if errno == EINTR { continue }
            else { return nil }
        }
        return nil
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes -> Bool in
            guard var pointer = bytes.baseAddress else { return false }
            var remaining = bytes.count
            while remaining > 0 {
                let count = write(fd, pointer, remaining)
                if count < 0 { if errno == EINTR { continue }; return false }
                if count == 0 { return false }
                remaining -= count; pointer = pointer.advanced(by: count)
            }
            return true
        }
    }
}

public struct VPhoneVirtualCameraFrameHeader: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let hostTimeNS: UInt64
    public let payloadLength: Int
}

/// Every frame is a fixed 32-byte little-endian header followed by raw BGRA.
public enum VPhoneVirtualCameraFrameProtocol {
    public static let magic: UInt32 = 0x3146_5056 // VPF1
    public static let version: UInt32 = 1
    public static let headerLength = 32

    public static func packet(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        hostTimeNS: UInt64,
        pixels: Data
    ) -> Data {
        var data = Data(capacity: headerLength + pixels.count)
        append(UInt32(magic), to: &data)
        append(UInt32(version), to: &data)
        append(UInt32(width), to: &data)
        append(UInt32(height), to: &data)
        append(UInt32(bytesPerRow), to: &data)
        append(hostTimeNS, to: &data)
        append(UInt32(pixels.count), to: &data)
        data.append(pixels)
        return data
    }

    public static func decodeHeader(_ data: Data) -> VPhoneVirtualCameraFrameHeader? {
        guard data.count == headerLength,
              readUInt32(data, at: 0) == magic,
              readUInt32(data, at: 4) == version else { return nil }
        let width = Int(readUInt32(data, at: 8))
        let height = Int(readUInt32(data, at: 12))
        let bytesPerRow = Int(readUInt32(data, at: 16))
        let hostTimeNS = readUInt64(data, at: 20)
        let payloadLength = Int(readUInt32(data, at: 28))
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              bytesPerRow <= Int.max / height else { return nil }
        let expectedPayloadLength = bytesPerRow * height
        guard payloadLength == expectedPayloadLength else { return nil }
        return VPhoneVirtualCameraFrameHeader(
            width: width, height: height, bytesPerRow: bytesPerRow,
            hostTimeNS: hostTimeNS, payloadLength: payloadLength
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(data[offset]) | UInt64(data[offset + 1]) << 8 |
            UInt64(data[offset + 2]) << 16 | UInt64(data[offset + 3]) << 24 |
            UInt64(data[offset + 4]) << 32 | UInt64(data[offset + 5]) << 40 |
            UInt64(data[offset + 6]) << 48 | UInt64(data[offset + 7]) << 56
    }
}
