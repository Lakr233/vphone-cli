import Darwin
import Foundation

enum AppleMobileDeviceLibrary {
    static let frameworkPath = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"

    typealias USBMuxCopyDeviceArrayFn = @convention(c) () -> Unmanaged<CFArray>?
    typealias USBMuxConnectByPortFn = @convention(c) (UInt32, UInt16, UnsafeMutablePointer<Int32>?) -> Int32

    static func copyDeviceArray() -> USBMuxCopyDeviceArrayFn? {
        symbol("_USBMuxCopyDeviceArray")
    }

    static func connectByPort() -> USBMuxConnectByPortFn? {
        symbol("_USBMuxConnectByPort")
    }

    static func symbol<T>(_ name: String) -> T? {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return nil }
        guard let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}

struct USBMuxDevice: Sendable {
    let deviceID: Int
    let serialNumber: String
    let connectionType: String?
    let productID: Int?
    let locationID: Int?
}

enum USBMuxError: Error, CustomStringConvertible {
    case connectFailed(String)
    case invalidReply(String)
    case deviceNotFound(String)
    case socketError(String)

    var description: String {
        switch self {
        case let .connectFailed(message),
             let .invalidReply(message),
             let .deviceNotFound(message),
             let .socketError(message):
            return message
        }
    }
}

enum USBMuxClient {
    static let socketPath = "/var/run/usbmuxd"
    static let plistMessageType: UInt32 = 8
    static let protocolVersion: UInt32 = 1

    struct Header {
        let length: UInt32
        let version: UInt32
        let message: UInt32
        let tag: UInt32
    }

    static func listDevices() throws -> [USBMuxDevice] {
        if let copyDeviceArray = AppleMobileDeviceLibrary.copyDeviceArray(),
           let array = copyDeviceArray()?.takeRetainedValue() as? [[String: Any]]
        {
            let parsed = array.compactMap(parseDevice)
            if !parsed.isEmpty {
                return parsed
            }
        }

        let socket = try connectSocket()
        defer { close(socket) }

        try sendPlist([
            "MessageType": "ListDevices",
            "ClientVersionString": "vphone-cli",
            "ProgName": "vphone-cli",
            "kLibUSBMuxVersion": 3,
        ], to: socket, tag: 1)

        let (_, plist) = try receivePlist(from: socket)
        guard let dictionary = plist as? [String: Any],
              let devices = dictionary["DeviceList"] as? [[String: Any]]
        else {
            throw USBMuxError.invalidReply("usbmuxd ListDevices reply missing DeviceList")
        }

        return devices.compactMap(parseDevice)
    }

    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        if let connectByPort = AppleMobileDeviceLibrary.connectByPort() {
            var socket: Int32 = -1
            let result = connectByPort(UInt32(deviceID), port.bigEndian, &socket)
            if result == 0, socket >= 0 {
                return socket
            }
        }

        let socket = try connectSocket()
        do {
            try sendPlist([
                "MessageType": "Connect",
                "ClientVersionString": "vphone-cli",
                "ProgName": "vphone-cli",
                "kLibUSBMuxVersion": 3,
                "DeviceID": deviceID,
                "PortNumber": Int(port.bigEndian),
            ], to: socket, tag: 1)

            let (_, plist) = try receivePlist(from: socket)
            guard let dictionary = plist as? [String: Any],
                  let number = dictionary["Number"] as? Int
            else {
                throw USBMuxError.invalidReply("usbmuxd Connect reply missing Number")
            }
            guard number == 0 else {
                throw USBMuxError.connectFailed("usbmuxd Connect failed with code \(number)")
            }
            return socket
        } catch {
            close(socket)
            throw error
        }
    }

    static func device(matching serial: String) throws -> USBMuxDevice {
        let devices = try listDevices()
        if let exact = devices.first(where: { $0.serialNumber.caseInsensitiveCompare(serial) == .orderedSame }) {
            return exact
        }
        if let partial = devices.first(where: { $0.serialNumber.localizedCaseInsensitiveContains(serial) }) {
            return partial
        }
        throw USBMuxError.deviceNotFound("No usbmux device matched '\(serial)'")
    }

    static func connectSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw USBMuxError.socketError("Failed to create unix socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                _ = strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }

        let addressLength = socklen_t(MemoryLayout.size(ofValue: address))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw USBMuxError.socketError("Failed to connect to usbmuxd: \(message)")
        }
        return fd
    }

    static func sendPlist(_ plist: [String: Any], to socket: Int32, tag: UInt32) throws {
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let totalLength = UInt32(MemoryLayout<UInt32>.size * 4 + payload.count)
        let headerWords = [
            totalLength.littleEndian,
            protocolVersion.littleEndian,
            plistMessageType.littleEndian,
            tag.littleEndian,
        ]
        try headerWords.withUnsafeBytes { bytes in
            try writeAll(socket: socket, data: Data(bytes))
        }
        try writeAll(socket: socket, data: payload)
    }

    static func receivePlist(from socket: Int32) throws -> (Header, Any) {
        let headerData = try readExactly(socket: socket, count: MemoryLayout<UInt32>.size * 4)
        let words = stride(from: 0, to: headerData.count, by: 4).map { offset in
            headerData.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
        }
        guard words.count == 4 else {
            throw USBMuxError.invalidReply("Invalid usbmux header length")
        }
        let header = Header(length: words[0], version: words[1], message: words[2], tag: words[3])
        guard header.length >= 16 else {
            throw USBMuxError.invalidReply("Invalid usbmux packet length \(header.length)")
        }
        let payload = try readExactly(socket: socket, count: Int(header.length) - 16)
        let plist = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
        return (header, plist)
    }

    static func parseDevice(_ dictionary: [String: Any]) -> USBMuxDevice? {
        guard let deviceID = dictionary["DeviceID"] as? Int else { return nil }
        let properties = dictionary["Properties"] as? [String: Any] ?? dictionary
        guard let serialNumber = properties["SerialNumber"] as? String else { return nil }
        return USBMuxDevice(
            deviceID: deviceID,
            serialNumber: serialNumber,
            connectionType: properties["ConnectionType"] as? String,
            productID: properties["ProductID"] as? Int,
            locationID: properties["LocationID"] as? Int
        )
    }

    static func readExactly(socket: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        let result = data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return -1 }
            while offset < count {
                let bytesRead = Darwin.read(socket, base.advanced(by: offset), count - offset)
                if bytesRead <= 0 {
                    return Int(bytesRead)
                }
                offset += bytesRead
            }
            return offset
        }
        guard result == count else {
            throw USBMuxError.socketError("Failed to read \(count) bytes from usbmuxd")
        }
        return data
    }

    static func writeAll(socket: Int32, data: Data) throws {
        var offset = 0
        let result = data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return -1 }
            while offset < data.count {
                let written = Darwin.write(socket, base.advanced(by: offset), data.count - offset)
                if written <= 0 {
                    return Int(written)
                }
                offset += written
            }
            return offset
        }
        guard result == data.count else {
            throw USBMuxError.socketError("Failed to write \(data.count) bytes to usbmuxd")
        }
    }
}

enum USBMuxForwarder {
    static func start(localPort: UInt16, serial: String, remotePort: UInt16) throws -> USBMuxForwardingService {
        let device = try USBMuxClient.device(matching: serial)
        let listener = try makeListener(port: localPort)
        let service = USBMuxForwardingService(listener: listener, device: device, remotePort: remotePort)
        service.start()
        return service
    }

    static func run(localPort: UInt16, serial: String, remotePort: UInt16) throws {
        _ = try start(localPort: localPort, serial: serial, remotePort: remotePort)
        dispatchMain()
    }

    static func makeListener(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw USBMuxError.socketError("socket() failed")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw USBMuxError.socketError("bind() failed on port \(port): \(message)")
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw USBMuxError.socketError("listen() failed: \(message)")
        }
        return fd
    }

    static func relay(client: Int32, remote: Int32) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            copyLoop(from: client, to: remote)
            shutdown(remote, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            copyLoop(from: remote, to: client)
            shutdown(client, SHUT_WR)
            group.leave()
        }
        group.wait()
        close(client)
        close(remote)
    }

    static func copyLoop(from source: Int32, to destination: Int32) {
        let bufferSize = 32 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = Darwin.read(source, buffer, bufferSize)
            if bytesRead <= 0 { break }
            var written = 0
            while written < bytesRead {
                let count = Darwin.write(destination, buffer.advanced(by: written), bytesRead - written)
                if count <= 0 { return }
                written += count
            }
        }
    }
}

final class USBMuxForwardingService: @unchecked Sendable {
    private let listener: Int32
    private let device: USBMuxDevice
    private let remotePort: UInt16
    private let queue = DispatchQueue(label: "com.vphone.usbmux-forward", qos: .userInitiated)
    private let lock = NSLock()
    private var stopped = false

    init(listener: Int32, device: USBMuxDevice, remotePort: UInt16) {
        self.listener = listener
        self.device = device
        self.remotePort = remotePort
    }

    func start() {
        queue.async { [self] in
            acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()

        if shouldStop {
            close(listener)
        }
    }

    private func acceptLoop() {
        while !isStopped {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listener, $0, &length)
                }
            }
            if client < 0 {
                if isStopped || errno == EBADF || errno == EINVAL {
                    break
                }
                if errno == EINTR {
                    continue
                }
                break
            }

            DispatchQueue.global(qos: .userInitiated).async { [device, remotePort] in
                do {
                    let remote = try USBMuxClient.connect(deviceID: device.deviceID, port: remotePort)
                    USBMuxForwarder.relay(client: client, remote: remote)
                } catch {
                    close(client)
                }
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
