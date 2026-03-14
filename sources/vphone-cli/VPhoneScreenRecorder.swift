import AppKit
import ImageIO
import AVFoundation
import CoreVideo
import ObjectiveC.runtime
import Virtualization

// MARK: - Screen Recorder

@MainActor
class VPhoneScreenRecorder {
    private enum CaptureError: LocalizedError {
        case captureFailed
        case clipboardWriteFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .captureFailed:
                "Failed to capture a frame from the virtual machine."
            case .clipboardWriteFailed:
                "Failed to copy the screenshot to the pasteboard."
            case .encodingFailed:
                "Failed to encode the screenshot as PNG."
            }
        }
    }

    private struct CaptureSource {
        let graphicsDisplay: VZGraphicsDisplay
        let description: String
    }

    private typealias ScreenshotCompletionBlock = @convention(block) (AnyObject?) -> Void
    private typealias ScreenshotIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var frameCount: Int64 = 0
    private var outputURL: URL?
    private var graphicsDisplay: VZGraphicsDisplay?
    private var captureModeDescription = "private VZGraphicsDisplay screenshots"
    private var screenshotInFlight = false
    private var didLogCaptureFailure = false

    var isRecording: Bool {
        writer?.status == .writing
    }

    func startRecording(view: NSView) throws {
        guard !isRecording else { return }

        let source = try resolveCaptureSource(for: view)
        let captureSize = source.graphicsDisplay.sizeInPixels
        let width = max(Int(captureSize.width), 1)
        let height = max(Int(captureSize.height), 1)

        let url = recordingOutputURL()
        outputURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttrs
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        videoInput = input
        self.adaptor = adaptor
        graphicsDisplay = source.graphicsDisplay
        captureModeDescription = source.description
        frameCount = 0
        screenshotInFlight = false
        didLogCaptureFailure = false

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }

        print(
            "[record] started - \(url.lastPathComponent) (\(width)x\(height), source: \(captureModeDescription))"
        )
    }

    func stopRecording() async -> URL? {
        guard let writer, writer.status == .writing else { return nil }

        timer?.invalidate()
        timer = nil

        videoInput?.markAsFinished()
        await writer.finishWriting()

        let url = outputURL
        self.writer = nil
        videoInput = nil
        adaptor = nil
        outputURL = nil
        graphicsDisplay = nil
        screenshotInFlight = false
        didLogCaptureFailure = false

        if let url {
            print("[record] saved - \(url.path)")
        }
        return url
    }

    func copyScreenshotToPasteboard(view: NSView) async throws {
        let cgImage = try await captureStillImage(from: view)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CaptureError.clipboardWriteFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.clipboardWriteFailed
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data as Data, forType: .init("public.jpeg"))

        print("[record] screenshot copied to clipboard")
    }

    func saveScreenshot(view: NSView) async throws -> URL {
        let cgImage = try await captureStillImage(from: view)
        let url = screenshotOutputURL()

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.encodingFailed
        }

        print("[record] screenshot saved - \(url.path)")
        return url
    }

    // MARK: - Frame Capture

    private func captureFrame() {
        guard let adaptor, let input = videoInput,
              input.isReadyForMoreMediaData,
              let graphicsDisplay
        else { return }

        captureGraphicsDisplayFrame(graphicsDisplay, adaptor: adaptor)
    }

    private func captureGraphicsDisplayFrame(
        _ graphicsDisplay: VZGraphicsDisplay,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) {
        guard !screenshotInFlight else { return }

        screenshotInFlight = true
        takeGraphicsScreenshot(from: graphicsDisplay) { [weak self] cgImage in
            Task { @MainActor in
                guard let self else { return }

                self.screenshotInFlight = false

                guard let input = self.videoInput, input.isReadyForMoreMediaData else { return }

                guard let cgImage else {
                    if !self.didLogCaptureFailure {
                        print("[record] graphics screenshot returned no image")
                        self.didLogCaptureFailure = true
                    }
                    return
                }

                self.didLogCaptureFailure = false
                self.appendFrame(from: adaptor, cgImage: cgImage)
            }
        }
    }

    private func captureStillImage(from view: NSView) async throws -> CGImage {
        let source = try resolveCaptureSource(for: view)
        guard let cgImage = await takeGraphicsScreenshot(from: source.graphicsDisplay) else {
            throw CaptureError.captureFailed
        }
        return cgImage
    }

    private func appendFrame(from adaptor: AVAssetWriterInputPixelBufferAdaptor, cgImage: CGImage) {
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }
        guard let pool = adaptor.pixelBufferPool else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        let pbWidth = CVPixelBufferGetWidth(pb)
        let pbHeight = CVPixelBufferGetHeight(pb)
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: pbWidth,
            height: pbHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pbWidth, height: pbHeight))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let time = CMTime(value: frameCount, timescale: 30)
        adaptor.append(pb, withPresentationTime: time)
        frameCount += 1
    }

    private func resolveCaptureSource(for view: NSView) throws -> CaptureSource {
        guard let vmView = view as? VPhoneVirtualMachineView,
              let graphicsDisplay = vmView.recordingGraphicsDisplay
        else {
            throw CaptureError.captureFailed
        }

        return CaptureSource(
            graphicsDisplay: graphicsDisplay,
            description: "private VZGraphicsDisplay screenshots"
        )
    }

    private func takeGraphicsScreenshot(
        from graphicsDisplay: VZGraphicsDisplay,
        completion: @escaping (CGImage?) -> Void
    ) {
        let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
        guard graphicsDisplay.responds(to: selector),
              let cls = object_getClass(graphicsDisplay),
              let method = class_getInstanceMethod(cls, selector)
        else {
            completion(nil)
            return
        }

        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: ScreenshotIMP.self)

        let block: ScreenshotCompletionBlock = { [weak self] imageObject in
            completion(self?.convertScreenshotObject(imageObject))
        }
        let blockObject = unsafeBitCast(block, to: AnyObject.self)
        function(graphicsDisplay, selector, blockObject)
    }

    private func takeGraphicsScreenshot(from graphicsDisplay: VZGraphicsDisplay) async -> CGImage? {
        await withCheckedContinuation { continuation in
            takeGraphicsScreenshot(from: graphicsDisplay) { cgImage in
                continuation.resume(returning: cgImage)
            }
        }
    }

    private func convertScreenshotObject(_ imageObject: AnyObject?) -> CGImage? {
        guard let imageObject else { return nil }

        if let nsImage = imageObject as? NSImage {
            return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        let cfObject = imageObject as CFTypeRef
        if CFGetTypeID(cfObject) == CGImage.typeID {
            // CGImage is a CF type, not a Swift class - unsafeDowncast cannot be used here.
            return (cfObject as! CGImage) // swiftlint:disable:this force_cast
        }

        return nil
    }

    private func recordingOutputURL() -> URL {
        desktopDirectory().appendingPathComponent("vphone-recording-\(timestampString()).mov")
    }

    private func screenshotOutputURL() -> URL {
        desktopDirectory().appendingPathComponent("vphone-screenshot-\(timestampString()).jpg")
    }

    private func timestampString() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    private func desktopDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
}
