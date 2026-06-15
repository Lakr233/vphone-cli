import CoreGraphics
import Foundation
import Virtualization

/// Host-side virtual-camera server.
///
/// Opens a vsock connection to the guest on port 1338 (separate from the
/// vphoned control channel on 1337) and pushes raw BGRA frames at a fixed
/// rate. The guest counterpart (a libvcamcaptured-attached receiver inside
/// cameracaptured) ferries those frames into the AVF capture pipeline.
///
/// Wire format (one frame, length-prefixed):
///   uint32 LE  total_payload_length
///   uint32 LE  header_json_length
///   bytes      header JSON (UTF-8), keys: w, h, bpr, fmt, ts
///   bytes      raw pixel data, exactly `bpr * h` bytes
///
/// The header carries the format so the receiver doesn't have to
/// assume; for now the producer fixes width/height/bpr/fmt at
/// 1280x720 BGRA. Future producers may emit different formats.
@MainActor
final class VPhoneCameraServer {
    enum SourceKind: String {
        case off
        case testPattern
        case videoFile  // .mov / .mp4 / .m4v via AVAssetReader
    }

    nonisolated static let vsockPort: UInt32 = 1338
    nonisolated static let defaultWidth: Int = 1280
    nonisolated static let defaultHeight: Int = 720
    nonisolated static let defaultFPS: Double = 30.0
    nonisolated static let pixelFormat: UInt32 = 0x4247_5241  // 'BGRA' — kCMPixelFormat_32BGRA

    private(set) var sourceKind: SourceKind = .off
    private(set) var isConnected = false

    private var device: VZVirtioSocketDevice?
    private var connection: VZVirtioSocketConnection?
    private var connectionFD: Int32 = -1
    private var producer: VPhoneFrameProducer?
    private var timer: DispatchSourceTimer?
    private var connectionAttemptToken: UInt64 = 0

    private let sendQueue = DispatchQueue(
        label: "com.vphone.camera.send", qos: .userInteractive)
    private let producerQueue = DispatchQueue(
        label: "com.vphone.camera.producer", qos: .userInteractive)

    var onConnectionStateChange: ((Bool) -> Void)?

    // MARK: - Lifecycle

    func connect(device: VZVirtioSocketDevice) {
        self.device = device
        attemptConnect()
    }

    func disconnect() {
        stopStreaming()
        if connectionFD >= 0 {
            close(connectionFD)
            connectionFD = -1
        }
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionStateChange?(false)
        }
    }

    // MARK: - Source selection

    func setSource(_ kind: SourceKind, videoURL: URL? = nil) {
        if sourceKind == kind, kind != .videoFile { return }
        let wasStreaming = (timer != nil)
        if wasStreaming { stopStreaming() }
        sourceKind = kind
        switch kind {
        case .off:
            producer = nil
        case .testPattern:
            producer = VPhoneTestPatternProducer(
                width: Self.defaultWidth,
                height: Self.defaultHeight)
        case .videoFile:
            guard let url = videoURL else {
                print("[camera] videoFile source requires a URL")
                producer = nil
                sourceKind = .off
                return
            }
            do {
                producer = try VPhoneVideoFileProducer(
                    url: url,
                    width: Self.defaultWidth,
                    height: Self.defaultHeight)
                print("[camera] video file source = \(url.lastPathComponent)")
            } catch {
                print("[camera] failed to open \(url.lastPathComponent): \(error)")
                producer = nil
                sourceKind = .off
            }
        }
        if wasStreaming, producer != nil {
            startStreaming()
        }
    }

    // MARK: - Streaming

    func startStreaming() {
        guard producer != nil, isConnected else { return }
        if timer != nil { return }
        let interval = 1.0 / Self.defaultFPS
        // Timer fires on the main queue so MainActor-isolated state
        // (producer, connectionFD) can be read directly without tripping
        // Swift 6's strict-concurrency isolation check. The frame
        // production + send is then hopped onto producerQueue so
        // BGRA generation doesn't run on the UI thread.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard let producer = self.producer else { return }
            let fd = self.connectionFD
            guard fd >= 0 else { return }
            let q = self.producerQueue
            q.async {
                guard let frame = producer.nextFrame() else { return }
                let ok = Self.send(fd: fd, frame: frame)
                if !ok {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Avoid double-handling if a parallel write already
                        // dropped the connection.
                        if self.connectionFD == fd {
                            self.handleDisconnect()
                        }
                    }
                }
            }
        }
        timer = t
        t.resume()
        print("[camera] streaming started — source=\(sourceKind.rawValue)")
    }

    func stopStreaming() {
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        print("[camera] streaming stopped")
    }

    /// Mark the current connection dead and start reconnecting. Called when
    /// a write fails with EPIPE — the most common case is vphoned auto-update
    /// killing its server-side socket while the host is streaming.
    private func handleDisconnect() {
        print("[camera] disconnect detected, will reconnect")
        let oldFD = connectionFD
        connectionFD = -1
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionStateChange?(false)
        }
        if oldFD >= 0 { close(oldFD) }
        // Note: streaming timer continues running but ticks no-op until
        // connectionFD becomes valid again.
        attemptConnect()
    }

    // MARK: - Connect

    private func attemptConnect() {
        guard let device else { return }
        connectionAttemptToken &+= 1
        let attemptToken = connectionAttemptToken
        device.connect(toPort: Self.vsockPort) {
            [weak self] (result: Result<VZVirtioSocketConnection, any Error>) in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionAttemptToken == attemptToken else { return }
                switch result {
                case let .success(conn):
                    self.connection = conn
                    self.connectionFD = conn.fileDescriptor
                    self.isConnected = true
                    print("[camera] connected on vsock port \(Self.vsockPort)")
                    self.onConnectionStateChange?(true)
                    if self.sourceKind != .off { self.startStreaming() }
                case let .failure(error):
                    print("[camera] connect failed: \(error). Retrying in 3s.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            guard self.connectionAttemptToken == attemptToken else { return }
                            self.attemptConnect()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Wire

    @discardableResult
    nonisolated private static func send(fd: Int32, frame: VPhoneCameraFrame) -> Bool {
        // header
        let headerDict: [String: Any] = [
            "w": frame.width,
            "h": frame.height,
            "bpr": frame.bytesPerRow,
            "fmt": Self.pixelFormat,
            "ts": frame.timestampNS,
        ]
        guard
            let headerData = try? JSONSerialization.data(withJSONObject: headerDict, options: [])
        else { return false }
        let totalLen = UInt32(4 + headerData.count + frame.pixels.count)
        let headerLen = UInt32(headerData.count)
        var prefix = Data()
        prefix.append(contentsOf: withUnsafeBytes(of: totalLen.littleEndian) { Array($0) })
        prefix.append(contentsOf: withUnsafeBytes(of: headerLen.littleEndian) { Array($0) })
        // Concat all into one buffer to make a single write — short frames
        // are cheap; large ones (1280*720*4 ≈ 3.5 MB) still fit comfortably
        // in a vsock send buffer and a single write keeps frame integrity
        // even if a future reader uses non-buffered I/O.
        var out = Data(capacity: Int(totalLen) + 4)
        out.append(prefix)
        out.append(headerData)
        out.append(frame.pixels)
        var ok = true
        out.withUnsafeBytes { bytes -> Void in
            guard let base = bytes.baseAddress else { ok = false; return }
            var remaining = bytes.count
            var cursor = base
            while remaining > 0 {
                let n = write(fd, cursor, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    print("[camera] write errno=\(errno)")
                    ok = false
                    return
                }
                if n == 0 { ok = false; return }
                remaining -= n
                cursor = cursor.advanced(by: n)
            }
        }
        return ok
    }
}
