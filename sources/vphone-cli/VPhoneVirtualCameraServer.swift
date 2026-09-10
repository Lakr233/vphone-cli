import AppKit
import CoreGraphics
import Darwin
import Foundation
import VPhoneCameraShared
import Virtualization

/// Captures the VM's host-side display only while a CMIO client is consuming
/// the virtual camera. The loopback endpoint is namespaced by extension ID;
/// no physical USB device or guest camera service is touched.
@MainActor
final class VPhoneVirtualCameraServer {
    private let graphicsDisplay: VZGraphicsDisplay
    private let screenRecorder: VPhoneScreenRecorder
    private let vmID: String
    private let displayName: String
    /// Present only for `--virtual-camera`. It is deliberately separate from
    /// the VZ display capture loop, so a guest display-state probe cannot
    /// affect the ordinary VPhone panel or USB device paths.
    private let displayStateProvider: (@MainActor () async -> VPhoneControl.DisplayState?)?
    private let generation = UUID()
    private let acceptQueue = DispatchQueue(label: "com.vphone.virtual-camera.accept")
    private let sendQueue = DispatchQueue(label: "com.vphone.virtual-camera.send", qos: .userInteractive)
    private var listenFD: Int32 = -1
    private var clients = Set<Int32>()
    private var timer: Timer?
    private var heartbeatTimer: Timer?
    private var displayStateTask: Task<Void, Never>?
    private var captureInFlight = false
    private var frameDeliveryPaused = false
    private var lastDisplayOn: Bool?
    private var lastLocked: Bool?
    private var registration: VPhoneVirtualCameraRegistration?
    /// The registry relay bridges the interactive user's App Group container
    /// to the CMIO extension, which runs under `_cmiodalassistants`.
    private var registryRelay: VPhoneVirtualCameraRegistryRelay?

    var onClientCountChange: ((Int) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var isRunning: Bool { listenFD >= 0 }
    var clientCount: Int { clients.count }

    init(graphicsDisplay: VZGraphicsDisplay, screenRecorder: VPhoneScreenRecorder,
         vmID: String, displayName: String,
         displayStateProvider: (@MainActor () async -> VPhoneControl.DisplayState?)? = nil) {
        self.graphicsDisplay = graphicsDisplay
        self.screenRecorder = screenRecorder
        self.vmID = vmID
        self.displayName = displayName
        self.displayStateProvider = displayStateProvider
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            let message = "VPhone Display: socket creation failed"
            print("[virtual-camera] \(message): \(String(cString: strerror(errno)))")
            onStatusChange?(message)
            return false
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let message = "VPhone Display: endpoint unavailable"
            print("[virtual-camera] listen failed: \(String(cString: strerror(errno)))")
            onStatusChange?(message)
            close(fd); return false
        }
        var actualAddress = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actualAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &actualLength)
            }
        }
        let port = UInt16(bigEndian: actualAddress.sin_port)
        guard port != 0 else { close(fd); return false }
        let endpoint = "tcp://127.0.0.1:\(port)"
        let registration = VPhoneVirtualCameraRegistration(
            vmID: vmID, displayName: displayName, endpoint: endpoint,
            pid: Int32(getpid()), generation: generation)
        do {
            try VPhoneVirtualCameraRegistry.write(registration)
        } catch {
            print("[virtual-camera] registry write failed: \(error)")
            close(fd); return false
        }
        self.registration = registration
        registryRelay = VPhoneVirtualCameraRegistryRelay()
        listenFD = fd
        // The CMIO extension treats registrations older than five seconds as
        // stale. Keep the same identity/endpoint/generation while refreshing
        // only updatedAt so a running VM remains published indefinitely.
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRegistration() }
        }
        heartbeatTimer?.tolerance = 0.2
        print("[virtual-camera] \(displayName): listening on \(endpoint)")
        onStatusChange?("VPhone Display: waiting for camera client")
        acceptQueue.async { [weak self] in Self.acceptLoop(fd: fd, server: self) }
        return true
    }

    func stop() {
        timer?.invalidate(); timer = nil; captureInFlight = false
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        stopDisplayStateMonitor()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        for fd in clients { shutdown(fd, SHUT_RDWR); close(fd) }
        clients.removeAll(); onClientCountChange?(0)
        if registration?.generation == generation {
            VPhoneVirtualCameraRegistry.remove(vmID: vmID)
        }
        registration = nil
    }

    private func refreshRegistration() {
        guard isRunning, let current = registration else { return }
        // If the VM that originally owned the relay exited, a remaining VM
        // promotes itself on its next heartbeat.
        if registryRelay == nil { registryRelay = VPhoneVirtualCameraRegistryRelay() }
        let refreshed = VPhoneVirtualCameraRegistration(
            vmID: current.vmID,
            displayName: current.displayName,
            endpoint: current.endpoint,
            pid: current.pid,
            generation: current.generation
        )
        do {
            try VPhoneVirtualCameraRegistry.write(refreshed)
            registration = refreshed
        } catch {
            // A transient App Group/filesystem failure must not mutate the
            // endpoint or identity. The extension will fail closed if the
            // heartbeat cannot be restored.
            print("[virtual-camera] \(displayName): heartbeat failed: \(error)")
        }
    }

    private func addClient(_ fd: Int32) {
        guard isRunning else { close(fd); return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let hello = Data("VPHONE-CMIO/1 \(vmID) \(generation.uuidString)\n".utf8)
        guard Self.writeAll(hello, to: fd) else { close(fd); return }
        clients.insert(fd); onClientCountChange?(clients.count)
        startDisplayStateMonitorIfNeeded()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(VPhoneVirtualCamera.frameRate), repeats: true) {
                [weak self] _ in Task { @MainActor in self?.captureFrame() }
            }
            timer?.tolerance = 0.002
        }
        print("[virtual-camera] \(displayName): client connected (\(clients.count) active)")
    }

    private func removeClients(_ failed: [Int32]) {
        for fd in failed where clients.remove(fd) != nil { shutdown(fd, SHUT_RDWR); close(fd) }
        guard !failed.isEmpty else { return }
        onClientCountChange?(clients.count)
        if clients.isEmpty {
            timer?.invalidate(); timer = nil
            stopDisplayStateMonitor()
        }
    }

    private func captureFrame() {
        guard !frameDeliveryPaused, !captureInFlight, !clients.isEmpty else { return }
        captureInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let image = try? await screenRecorder.captureStillImage(from: graphicsDisplay),
                  let packet = Self.makePacket(image) else { captureInFlight = false; return }
            let recipients = Array(clients)
            sendQueue.async {
                let failed = Self.send(packet, to: recipients)
                Task { @MainActor [weak self] in self?.removeClients(failed); self?.captureInFlight = false }
            }
        }
    }

    /// Poll only while a CMIO consumer is attached.  This runs far below the
    /// frame cadence (4 Hz, not once per frame), and a missing/unknown answer
    /// leaves delivery active.  The guest control request is never used by
    /// normal VPhone launches because this server only exists with
    /// `--virtual-camera`.
    private func startDisplayStateMonitorIfNeeded() {
        guard displayStateTask == nil, displayStateProvider != nil else { return }
        displayStateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning, !self.clients.isEmpty else { break }
                if let state = await self.displayStateProvider?() {
                    self.applyDisplayState(state)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopDisplayStateMonitor() {
        displayStateTask?.cancel()
        displayStateTask = nil
        frameDeliveryPaused = false
        lastDisplayOn = nil
        lastLocked = nil
    }

    private func applyDisplayState(_ state: VPhoneControl.DisplayState) {
        if let locked = state.locked, locked != lastLocked {
            lastLocked = locked
            if locked, state.displayOn != false {
                // Preserve a fresh lock-screen sample before a later display
                // off transition pauses delivery. This is extra capture only
                // at the transition; normal 30 FPS delivery is unchanged.
                captureFrame()
            }
        }

        guard let displayOn = state.displayOn else { return }
        guard displayOn != lastDisplayOn else { return }
        lastDisplayOn = displayOn

        if displayOn {
            let wasPaused = frameDeliveryPaused
            frameDeliveryPaused = false
            if wasPaused {
                print("[virtual-camera] \(displayName): guest display on; resuming CMIO frames")
                onStatusChange?("VPhone Display: guest display on; resuming CMIO frames")
                captureFrame()
            }
        } else {
            frameDeliveryPaused = true
            let source = state.source.map { " (\($0))" } ?? ""
            print("[virtual-camera] \(displayName): guest display off; pausing CMIO frames\(source)")
            onStatusChange?("VPhone Display: guest display off; pausing CMIO frames")
        }
    }

    private static func makePacket(_ image: CGImage) -> Data? {
        let width = VPhoneVirtualCamera.frameWidth, height = VPhoneVirtualCamera.frameHeight
        let bytesPerRow = ((width * 4) + 63) & ~63
        var pixels = Data(count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return VPhoneVirtualCameraFrameProtocol.packet(
            width: width, height: height, bytesPerRow: bytesPerRow,
            hostTimeNS: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000), pixels: pixels)
    }

    private nonisolated static func acceptLoop(fd: Int32, server: VPhoneVirtualCameraServer?) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            Task { @MainActor [weak server] in server?.addClient(client) }
        }
    }

    private nonisolated static func send(_ packet: Data, to fds: [Int32]) -> [Int32] {
        fds.filter { !writeAll(packet, to: $0) }
    }

    private nonisolated static func writeAll(_ data: Data, to fd: Int32) -> Bool {
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
