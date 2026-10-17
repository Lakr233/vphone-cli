import AppKit
import AVFoundation
import CoreVideo
import ImageIO
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
                "Unable to capture the screen. Try again."
            case .clipboardWriteFailed:
                "Unable to copy the screenshot to the clipboard. Try again."
            case .encodingFailed:
                "Unable to save the screenshot. Try again."
            }
        }
    }


    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var frameCount: Int64 = 0
    private var outputURL: URL?
    private var graphicsDisplay: VZGraphicsDisplay?
    private var screenshotInFlight = false
    private var didLogCaptureFailure = false

    var isRecording: Bool {
        writer?.status == .writing
    }

    func startRecording(view: NSView) throws {
        guard !isRecording else { return }

        let display = try resolveCaptureSource(for: view)
        let captureSize = display.sizeInPixels
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
            sourcePixelBufferAttributes: bufferAttrs,
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        videoInput = input
        self.adaptor = adaptor
        graphicsDisplay = display
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
            "[record] started - \(url.lastPathComponent) (\(width)x\(height), source: private VZGraphicsDisplay screenshots)",
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

    func copyScreenshotToPasteboard(jpegData: Data) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(jpegData, forType: .init("public.jpeg")) else {
            throw CaptureError.clipboardWriteFailed
        }
        print("[record] guest screenshot copied to clipboard")
    }

    func saveScreenshot(jpegData: Data) throws -> URL {
        let url = screenshotOutputURL()
        return try saveScreenshot(jpegData: jpegData, to: url)
    }

    func saveScreenshot(jpegData: Data, to url: URL) throws -> URL {
        do {
            if url.pathExtension.lowercased() == "png" {
                guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
                else { throw CaptureError.encodingFailed }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }
            } else {
                try jpegData.write(to: url, options: .atomic)
            }
        } catch {
            throw CaptureError.encodingFailed
        }
        print("[record] guest screenshot saved - \(url.path)")
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
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
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

    func captureStillImage(from view: NSView) async throws -> CGImage {
        let display = try resolveCaptureSource(for: view)
        guard let cgImage = await takeGraphicsScreenshot(from: display) else {
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
                | CGBitmapInfo.byteOrder32Little.rawValue,
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pbWidth, height: pbHeight))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let time = CMTime(value: frameCount, timescale: 30)
        adaptor.append(pb, withPresentationTime: time)
        frameCount += 1
    }

    private func resolveCaptureSource(for view: NSView) throws -> VZGraphicsDisplay {
        guard let vmView = view as? VPhoneVirtualMachineView,
              let graphicsDisplay = vmView.recordingGraphicsDisplay
        else {
            throw CaptureError.captureFailed
        }

        return graphicsDisplay
    }

    private func takeGraphicsScreenshot(
        from graphicsDisplay: VZGraphicsDisplay,
        completion: @escaping (CGImage?) -> Void,
    ) {
        VPhoneGraphicsDisplayCapture.capture(graphicsDisplay, completion: completion)
    }

    private func takeGraphicsScreenshot(from graphicsDisplay: VZGraphicsDisplay) async -> CGImage? {
        await VPhoneGraphicsDisplayCapture.capture(graphicsDisplay)
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
