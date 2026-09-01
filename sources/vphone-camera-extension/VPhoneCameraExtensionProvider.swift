import CoreMedia
import CoreMediaIO
import CoreVideo
import Darwin
import Foundation
import IOKit.audio
import os.log
import VPhoneCameraShared

private final class VPhoneCameraSocketClient: @unchecked Sendable {
    typealias FrameHandler = (VPhoneVirtualCameraFrameHeader, Data) -> Void
    private let registration: VPhoneVirtualCameraRegistration
    private let handler: FrameHandler
    private let queue = DispatchQueue(label: "com.vphone.camera-extension.socket", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private var activeFD: Int32 = -1

    init(registration: VPhoneVirtualCameraRegistration, handler: @escaping FrameHandler) {
        self.registration = registration; self.handler = handler
    }
    func start() {
        lock.lock(); stopped = false; lock.unlock()
        queue.async { [weak self] in self?.run() }
    }
    func stop() {
        lock.lock(); stopped = true; let fd = activeFD; activeFD = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func run() {
        while !isStopped {
            guard let fd = Self.connect(registration.endpoint),
                  Self.readHandshake(fd, registration: registration) else {
                Thread.sleep(forTimeInterval: 0.5); continue
            }
            lock.lock(); let canUse = !stopped; if canUse { activeFD = fd }; lock.unlock()
            guard canUse else { close(fd); break }
            while !isStopped,
                  let headerData = Self.readExactly(VPhoneVirtualCameraFrameProtocol.headerLength, from: fd),
                  let header = VPhoneVirtualCameraFrameProtocol.decodeHeader(headerData),
                  header.width == VPhoneVirtualCamera.frameWidth,
                  header.height == VPhoneVirtualCamera.frameHeight,
                  let pixels = Self.readExactly(header.payloadLength, from: fd) {
                handler(header, pixels)
            }
            lock.lock(); if activeFD == fd { activeFD = -1 }; lock.unlock(); close(fd)
        }
    }
    private static func connect(_ endpoint: String) -> Int32? {
        guard let url = URL(string: endpoint), url.scheme == "tcp",
              url.host == "127.0.0.1", let port = url.port else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }; return fd
    }
    private static func readHandshake(_ fd: Int32, registration: VPhoneVirtualCameraRegistration) -> Bool {
        guard let data = readUntilNewline(from: fd), let line = String(data: data, encoding: .utf8) else {
            return false
        }
        // The Host wire format deliberately ends each greeting with `\n`.
        // Splitting only on a literal space leaves that newline attached to
        // the generation UUID and causes every otherwise-valid connection to
        // be rejected and retried. Treat all whitespace as separators.
        let parts = line.split(whereSeparator: \.isWhitespace)
        return parts.count == 3 && parts[0] == "VPHONE-CMIO/1"
            && parts[1] == Substring(registration.vmID)
            && parts[2] == Substring(registration.generation.uuidString)
    }
    private static func readUntilNewline(from fd: Int32) -> Data? {
        var data = Data()
        while data.count < 512 {
            var byte: UInt8 = 0; let result = read(fd, &byte, 1)
            if result == 1 { data.append(byte); if byte == 10 { return data } }
            else if result < 0 && errno == EINTR { continue } else { return nil }
        }
        return nil
    }
    private static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard var pointer = bytes.baseAddress else { return false }; var remaining = count
            while remaining > 0 {
                let result = read(fd, pointer, remaining)
                if result < 0 { if errno == EINTR { continue }; return false }
                if result == 0 { return false }; remaining -= result; pointer = pointer.advanced(by: result)
            }; return true
        }; return success ? data : nil
    }
}

private final class VPhoneCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private weak var device: CMIOExtensionDevice?
    private let format: CMIOExtensionStreamFormat
    init(device: CMIOExtensionDevice, streamID: UUID, format: CMIOExtensionStreamFormat) {
        self.device = device; self.format = format; super.init()
        stream = CMIOExtensionStream(localizedName: "VPhone Display Video", streamID: streamID,
            direction: .source, clockType: .hostTime, source: self)
    }
    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: VPhoneVirtualCamera.frameRate)
        }; return result
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws {
        guard let source = device?.source as? VPhoneCameraDeviceSource else {
            throw NSError(domain: "VPhoneVirtualCamera", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "VPhone Display source unavailable"])
        }; source.startStreaming()
    }
    func stopStream() throws { (device?.source as? VPhoneCameraDeviceSource)?.stopStreaming() }
}

private final class VPhoneCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: VPhoneCameraStreamSource!
    private let registration: VPhoneVirtualCameraRegistration
    private let formatDescription: CMVideoFormatDescription
    private let pool: CVPixelBufferPool
    private let lock = NSLock()
    private var socket: VPhoneCameraSocketClient?
    private var streamingCount = 0
    private var discontinuity = true
    private var lastHostTime: UInt64 = 0

    init(registration: VPhoneVirtualCameraRegistration, localizedName: String) {
        self.registration = registration
        let width = Int32(VPhoneVirtualCamera.frameWidth), height = Int32(VPhoneVirtualCamera.frameHeight)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA, width: width, height: height,
            extensions: nil, formatDescriptionOut: &description) == noErr,
            let description else { fatalError("[virtual-camera] format creation failed") }
        formatDescription = description
        let attrs: NSDictionary = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
        var pixelPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pixelPool) == kCVReturnSuccess,
              let pixelPool else { fatalError("[virtual-camera] pool creation failed") }
        pool = pixelPool; super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: registration.deviceID,
            legacyDeviceID: registration.vmID, source: self)
        let duration = CMTime(value: 1, timescale: VPhoneVirtualCamera.frameRate)
        streamSource = VPhoneCameraStreamSource(device: device, streamID: registration.streamID,
            format: CMIOExtensionStreamFormat(formatDescription: description,
                maxFrameDuration: duration, minFrameDuration: duration, validFrameDurations: [duration]))
        do { try device.addStream(streamSource.stream) }
        catch { fatalError("[virtual-camera] stream registration failed: \(error)") }
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "vphone-cli virtual display (\(registration.vmID))" }
        return result
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
    func startStreaming() {
        lock.lock(); streamingCount += 1; let shouldStart = streamingCount == 1
        if shouldStart { discontinuity = true; lastHostTime = 0 }; lock.unlock()
        guard shouldStart else { return }
        let client = VPhoneCameraSocketClient(registration: registration) { [weak self] h, p in
            self?.consume(header: h, pixels: p)
        }
        lock.lock(); socket = client; lock.unlock(); client.start()
        os_log(.info, "VPhone Display camera stream started for %{public}@", registration.vmID)
    }
    func stopStreaming() {
        lock.lock(); streamingCount = max(0, streamingCount - 1)
        let client = streamingCount == 0 ? socket : nil
        if streamingCount == 0 { socket = nil }; lock.unlock(); client?.stop()
    }
    private func consume(header: VPhoneVirtualCameraFrameHeader, pixels: Data) {
        lock.lock(); let active = streamingCount > 0
        let flags: CMIOExtensionStream.DiscontinuityFlags
        if discontinuity { discontinuity = false; flags = .time }
        else if header.hostTimeNS > lastHostTime && header.hostTimeNS - lastHostTime > 100_000_000 {
            flags = .sampleDropped
        } else { flags = [] }
        lastHostTime = header.hostTimeNS; lock.unlock(); guard active else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let destination = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let destinationBPR = CVPixelBufferGetBytesPerRow(pixelBuffer)
            pixels.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                for row in 0..<VPhoneVirtualCamera.frameHeight {
                    memcpy(destination.advanced(by: row * destinationBPR),
                           base.advanced(by: row * header.bytesPerRow),
                           min(destinationBPR, header.bytesPerRow))
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: VPhoneVirtualCamera.frameRate),
            presentationTimeStamp: CMTime(value: CMTimeValue(header.hostTimeNS), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        streamSource.stream.send(sample, discontinuity: flags, hostTimeInNanoseconds: header.hostTimeNS)
    }
}

final class VPhoneCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var devices: [String: VPhoneCameraDeviceSource] = [:]
    private let queue = DispatchQueue(label: "com.vphone.camera-extension.registry")
    private var timer: DispatchSourceTimer?

    init(clientQueue: DispatchQueue?) {
        super.init(); provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.refresh() }; timer.resume(); self.timer = timer
    }
    private func refresh() {
        let registrations = VPhoneVirtualCameraRegistry.readPublished()
        os_log(.info, "VPhone CMIO registry refresh: count=%{public}d path=%{public}@",
               registrations.count, VPhoneVirtualCamera.registryDirectory.path)
        let groups = Dictionary(grouping: registrations, by: \.displayName)
        let active = Set(registrations.map(\.vmID))
        for registration in registrations {
            let suffix = groups[registration.displayName]!.count > 1
                ? " [\(String(registration.vmID.suffix(6)))]" : ""
            let name = "VPhone — \(registration.displayName)\(suffix)"
            if let old = devices[registration.vmID] {
                if old.device.deviceID == registration.deviceID { continue }
                try? provider.removeDevice(old.device); devices.removeValue(forKey: registration.vmID)
            }
            guard devices[registration.vmID] == nil else { continue }
            let source = VPhoneCameraDeviceSource(registration: registration, localizedName: name)
            do { try provider.addDevice(source.device); devices[registration.vmID] = source }
            catch {
                os_log(.error, "VPhone CMIO device add failed vm=%{public}@ name=%{public}@ error=%{public}@",
                       registration.vmID, name, "\(error)")
            }
        }
        let stale = devices.filter { !active.contains($0.key) }
        for (vmID, source) in stale {
            try? provider.removeDevice(source.device)
            devices.removeValue(forKey: vmID)
        }
    }
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer, .providerName] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "vphone-cli" }
        if properties.contains(.providerName) { result.name = "VPhone Display" }
        return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
