import AppKit
import AVFoundation
import CoreVideo

// MARK: - Screen Recorder

@MainActor
class VPhoneScreenRecorder {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var frameCount: Int64 = 0
    private var outputURL: URL?
    private weak var view: NSView?

    var isRecording: Bool {
        writer?.status == .writing
    }

    func startRecording(view: NSView) throws {
        guard !isRecording else { return }

        let backingSize = view.convertToBacking(view.bounds.size)
        let width = Int(backingSize.width)
        let height = Int(backingSize.height)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        let url = desktop.appendingPathComponent("vphone-recording-\(timestamp).mov")
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
        self.view = view
        frameCount = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }

        print("[record] started — \(url.lastPathComponent) (\(width)x\(height))")
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
        view = nil

        if let url {
            print("[record] saved — \(url.path)")
        }
        return url
    }

    // MARK: - Frame Capture

    private func captureFrame() {
        guard let view, let adaptor, let input = videoInput,
              input.isReadyForMoreMediaData
        else { return }

        // Render view into bitmap at backing (retina) resolution
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let cgImage = rep.cgImage else { return }

        // Get pixel buffer from pool
        guard let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        // Draw CGImage into pixel buffer
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
}
