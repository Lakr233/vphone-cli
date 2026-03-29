import AppKit
import Foundation
import ImageIO

// MARK: - Host Control Socket

/// Lightweight Unix domain socket server that accepts automation commands from
/// local processes (e.g. Claude Code via `nc -U`).  One JSON line in, one JSON
/// line out, then the connection closes.
///
/// Every response includes an `"image"` field with a compact base64-encoded
/// grayscale JPEG of the current screen (unless `"screen":false` is sent).
///
/// Supported commands:
///   {"t":"screenshot"}                          → full-res save to Desktop (or explicit path)
///   {"t":"screenshot","path":"/tmp/shot.png"}   → save to explicit path (PNG/JPEG by extension)
///   {"t":"tap","x":645,"y":1398}                → tap at pixel coordinates
///   {"t":"swipe","x1":645,"y1":2600,"x2":645,"y2":1400,"ms":300}  → swipe
///   {"t":"key","name":"home"}                   → hardware key (home/power/volup/voldown)
///   {"t":"type","text":"Hello"}                 → set guest clipboard
///
/// All commands except "screenshot" wait briefly then capture a compact screen
/// image returned as `"image":"<base64>"` in the response.  Pass `"screen":false`
/// to skip the capture.
@MainActor
class VPhoneHostControl {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")

    private weak var captureView: VPhoneVirtualMachineView?
    private var screenRecorder: VPhoneScreenRecorder?
    private weak var control: VPhoneControl?

    /// Thread-safe box for passing results between main actor and accept queue.
    private final class ResultBox: @unchecked Sendable {
        var path: String?
        var error: String?
        var ok = false
        var imageBase64: String?
    }

    /// Screen pixel dimensions for coordinate mapping.
    private var screenWidth: Int = 1290
    private var screenHeight: Int = 2796

    /// Compact screenshot scale factor (1/3 = 430x932).
    private static let compactScale = 3

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(
        captureView: VPhoneVirtualMachineView,
        screenRecorder: VPhoneScreenRecorder,
        control: VPhoneControl,
        screenWidth: Int,
        screenHeight: Int
    ) {
        self.captureView = captureView
        self.screenRecorder = screenRecorder
        self.control = control
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[hostctl] failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            print("[hostctl] socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            print("[hostctl] bind failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard listen(fd, 4) == 0 else {
            print("[hostctl] listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        print("[hostctl] listening on \(socketPath)")

        let capturedFD = fd
        acceptQueue.async { [weak self] in
            Self.acceptLoop(listenFD: capturedFD, controller: self)
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Compact Screenshot

    /// Capture current screen as a small grayscale JPEG, returned as base64.
    private func captureCompactScreenshot() async -> String? {
        guard let recorder = screenRecorder, let view = captureView, view.window != nil else {
            return nil
        }

        // Reuse the existing private-API capture
        guard let cgImage = await captureStillImage(recorder: recorder, view: view) else {
            return nil
        }

        let dstW = cgImage.width / Self.compactScale
        let dstH = cgImage.height / Self.compactScale

        // Draw into grayscale context
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: dstW, height: dstH,
            bitsPerComponent: 8, bytesPerRow: dstW,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // High contrast: bump brightness
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

        guard let grayImage = ctx.makeImage() else { return nil }

        // Encode as low-quality JPEG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.35]
        CGImageDestinationAddImage(dest, grayImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (data as Data).base64EncodedString()
    }

    /// Access the recorder's private capture method via the existing async wrapper.
    private func captureStillImage(recorder: VPhoneScreenRecorder, view: NSView) async -> CGImage? {
        // Use the public saveScreenshot path but intercept before encoding.
        // We call the recorder's internal captureStillImage indirectly by
        // going through saveScreenshot to a temp file, then reading back.
        // This is suboptimal but avoids exposing internal API.
        //
        // Better: use the same private API directly.
        guard let vmView = view as? VPhoneVirtualMachineView,
              let display = vmView.recordingGraphicsDisplay
        else { return nil }

        return await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
            guard display.responds(to: selector),
                  let cls = object_getClass(display),
                  let method = class_getInstanceMethod(cls, selector)
            else {
                continuation.resume(returning: nil)
                return
            }

            typealias CompletionBlock = @convention(block) (AnyObject?) -> Void
            typealias IMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

            let impl = method_getImplementation(method)
            let fn = unsafeBitCast(impl, to: IMP.self)

            let block: CompletionBlock = { imageObject in
                guard let imageObject else {
                    continuation.resume(returning: nil)
                    return
                }
                if let nsImage = imageObject as? NSImage {
                    continuation.resume(returning: nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    return
                }
                let cf = imageObject as CFTypeRef
                if CFGetTypeID(cf) == CGImage.typeID {
                    continuation.resume(returning: (cf as! CGImage))
                    return
                }
                continuation.resume(returning: nil)
            }
            let blockObj = unsafeBitCast(block, to: AnyObject.self)
            fn(display, selector, blockObj)
        }
    }

    // MARK: - Accept Loop

    private nonisolated static func acceptLoop(listenFD: Int32, controller: VPhoneHostControl?) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }
            handleClient(clientFD, controller: controller)
        }
    }

    private nonisolated static func handleClient(_ fd: Int32, controller: VPhoneHostControl?) {
        defer { close(fd) }

        guard let line = readLine(from: fd) else { return }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String
        else {
            writeResponse(fd, ok: false, error: "invalid JSON")
            return
        }

        // Whether to include a compact screenshot in the response (default: true)
        let wantScreen = json["screen"] as? Bool ?? true
        // Delay before screenshot (ms) — lets animations settle
        let screenDelay = json["delay"] as? Int ?? 500

        switch type {
        case "screenshot":
            let outputPath = json["path"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller,
                      let recorder = controller.screenRecorder,
                      let view = controller.captureView,
                      view.window != nil
                else {
                    result.error = "no active VM view"
                    return
                }
                do {
                    if let outputPath {
                        let url = try await recorder.saveScreenshot(view: view, to: URL(fileURLWithPath: outputPath))
                        result.path = url.path
                    }
                    // Always include compact image for screenshot command
                    result.imageBase64 = await controller.captureCompactScreenshot()
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, path: result.path, image: result.imageBase64)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "tap":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                writeResponse(fd, ok: false, error: "tap requires x and y (pixel coordinates)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectTap(
                    pixelX: x, pixelY: y,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight
                )
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "swipe":
            guard let x1 = json["x1"] as? Double, let y1 = json["y1"] as? Double,
                  let x2 = json["x2"] as? Double, let y2 = json["y2"] as? Double
            else {
                writeResponse(fd, ok: false, error: "swipe requires x1, y1, x2, y2")
                return
            }
            let durationMs = json["ms"] as? Int ?? 300
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectSwipe(
                    fromX: x1, fromY: y1, toX: x2, toY: y2,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight,
                    durationMs: durationMs
                )
                result.ok = true
                if wantScreen {
                    // Wait for swipe to finish + settle
                    let totalDelay = durationMs + screenDelay
                    try? await Task.sleep(nanoseconds: UInt64(totalDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "key":
            guard let name = json["name"] as? String else {
                writeResponse(fd, ok: false, error: "key requires name (home/power/volup/voldown)")
                return
            }
            let hidKey: (page: UInt32, usage: UInt32)? = switch name {
            case "home": (0x0C, 0x40)
            case "power": (0x0C, 0x30)
            case "volup": (0x0C, 0xE9)
            case "voldown": (0x0C, 0xEA)
            default: nil
            }
            guard let key = hidKey else {
                writeResponse(fd, ok: false, error: "unknown key: \(name)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                ctl.sendHIDPress(page: key.page, usage: key.usage)
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "type":
            guard let text = json["text"] as? String else {
                writeResponse(fd, ok: false, error: "type requires text")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.clipboardSet(text: text)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        default:
            writeResponse(fd, ok: false, error: "unknown command: \(type)")
        }
    }

    // MARK: - Socket I/O

    private nonisolated static func readLine(from fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()

        while accumulated.count < 4096 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            accumulated.append(contentsOf: buffer[..<n])
            if accumulated.contains(0x0A) { break }
        }

        if let nlRange = accumulated.firstIndex(of: 0x0A) {
            return String(data: accumulated[..<nlRange], encoding: .utf8)
        }
        return accumulated.isEmpty ? nil : String(data: accumulated, encoding: .utf8)
    }

    private nonisolated static func writeResponse(
        _ fd: Int32, ok: Bool, path: String? = nil, error: String? = nil, image: String? = nil
    ) {
        var dict: [String: Any] = ["ok": ok]
        if let path { dict["path"] = path }
        if let error { dict["error"] = error }
        if let image { dict["image"] = image }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var json = String(data: data, encoding: .utf8)
        else { return }

        json += "\n"
        json.withCString { ptr in
            var remaining = strlen(ptr)
            var offset = 0
            while remaining > 0 {
                let written = write(fd, ptr.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }
}
