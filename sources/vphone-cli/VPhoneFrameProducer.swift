import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// A single BGRA frame produced by a frame source.
struct VPhoneCameraFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let timestampNS: UInt64
    let pixels: Data
}

/// Frame source for the host-side virtual camera server.
///
/// `@unchecked Sendable` because each conforming producer is mutated only
/// from the camera server's producer queue (single writer); Swift can't
/// see the queue isolation, so we opt out of the strict-concurrency
/// check.
protocol VPhoneFrameProducer: AnyObject, Sendable {
    func nextFrame() -> VPhoneCameraFrame?
}

// MARK: - Test pattern

/// Generates a smoothly-animating BGRA pattern: a moving vertical gradient
/// modulated by a sin wave, plus a frame counter overlay in the corner so
/// the receiver can verify that frames are advancing. No external assets
/// required.
final class VPhoneTestPatternProducer: VPhoneFrameProducer, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var frameIndex: UInt64 = 0
    private let startedAt: TimeInterval

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        // Round bytesPerRow up to 16-byte alignment — common requirement for
        // IOSurfaces and BGRA hardware paths. For 1280 width: 1280*4 = 5120
        // (already 16-aligned).
        let stride = ((width * 4) + 15) & ~15
        self.bytesPerRow = stride
        self.startedAt = ProcessInfo.processInfo.systemUptime
    }

    func nextFrame() -> VPhoneCameraFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - startedAt
        let pixelCount = bytesPerRow * height
        var bytes = [UInt8](repeating: 0, count: pixelCount)

        // Vertical gradient. Hue rolls with time.
        let hueOffset = elapsed * 0.4  // turns per second
        for y in 0..<height {
            let v = Double(y) / Double(height)
            // Simple HSV → RGB on hue, full sat/val.
            let h = (v + hueOffset).truncatingRemainder(dividingBy: 1.0)
            let (r, g, b) = Self.hsvToRGB(h: h, s: 0.85, v: 0.85)
            let rB = UInt8(min(255, max(0, Int(r * 255))))
            let gB = UInt8(min(255, max(0, Int(g * 255))))
            let bB = UInt8(min(255, max(0, Int(b * 255))))

            let rowStart = y * bytesPerRow
            var idx = rowStart
            // BGRA order on little-endian Apple platforms.
            for _ in 0..<width {
                bytes[idx + 0] = bB  // B
                bytes[idx + 1] = gB  // G
                bytes[idx + 2] = rB  // R
                bytes[idx + 3] = 255  // A
                idx += 4
            }
        }

        // Counter overlay: a moving small white square (poor man's frame
        // counter — the receiver can eyeball motion to confirm fps).
        let sqSize = 32
        let xPos = Int(elapsed * 200) % max(1, width - sqSize)
        let yPos = max(8, (height - sqSize) / 8)
        for dy in 0..<sqSize {
            let row = (yPos + dy) * bytesPerRow
            for dx in 0..<sqSize {
                let off = row + (xPos + dx) * 4
                bytes[off + 0] = 255
                bytes[off + 1] = 255
                bytes[off + 2] = 255
                bytes[off + 3] = 255
            }
        }

        frameIndex &+= 1
        let ts = UInt64(now * 1_000_000_000)
        return VPhoneCameraFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            timestampNS: ts,
            pixels: Data(bytes))
    }

    // MARK: - HSV helpers

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let i = floor(h * 6.0)
        let f = h * 6.0 - i
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)
        switch Int(i) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

// MARK: - Video file (.mov / .mp4 / .m4v via AVAssetReader)

/// Plays a video file in a loop. Decode is delegated to `AVAssetReader`
/// with a BGRA output spec, so anything AVFoundation can demux on macOS
/// works (`.mov`, `.mp4`, `.m4v`). For unsupported containers
/// (`.mkv`, `.webm`, `.avi`) convert externally first
/// (e.g. `ffmpeg -i in.mkv -c copy out.mov` if codecs are compatible).
///
/// The producer rescales the input video to the configured camera
/// width/height using a Core Image render so the wire-format payload
/// length stays constant regardless of the source resolution. Output is
/// always 8-bit BGRA, top-down, 16-byte aligned bytesPerRow.
final class VPhoneVideoFileProducer: VPhoneFrameProducer, @unchecked Sendable {
    private let url: URL
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var asset: AVURLAsset
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private let ciContext: CIContext

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width
        self.height = height
        self.bytesPerRow = ((width * 4) + 15) & ~15
        self.asset = AVURLAsset(url: url)
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        try restartReader()
    }

    private func restartReader() throws {
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NSError(
                domain: "VPhoneVideoFileProducer", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent): no video track"])
        }
        let r = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
            ])
        output.alwaysCopiesSampleData = false
        r.add(output)
        guard r.startReading() else {
            throw NSError(
                domain: "VPhoneVideoFileProducer", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "AVAssetReader.startReading failed: \(r.error?.localizedDescription ?? "?")"])
        }
        self.reader = r
        self.readerOutput = output
    }

    func nextFrame() -> VPhoneCameraFrame? {
        if reader?.status != .reading {
            // Loop on EOF (or after an error)
            do { try restartReader() } catch { print("[camera] mov restart failed: \(error)"); return nil }
        }
        guard let sb = readerOutput?.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb)
        else {
            // EOF — restart on next call.
            do { try restartReader() } catch {}
            return nil
        }

        let srcWidth = CVPixelBufferGetWidth(pb)
        let srcHeight = CVPixelBufferGetHeight(pb)

        // Fast path: source already matches our requested dimensions and is
        // BGRA — copy the planar bytes directly without going through Core
        // Image. Saves the GPU render.
        if srcWidth == width, srcHeight == height,
            CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let srcBPR = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            var out = Data(count: bytesPerRow * height)
            out.withUnsafeMutableBytes { dst in
                let dstBase = dst.baseAddress!
                for y in 0..<height {
                    let dstRow = dstBase.advanced(by: y * bytesPerRow)
                    let srcRow = base.advanced(by: y * srcBPR)
                    let copyLen = min(srcBPR, bytesPerRow)
                    memcpy(dstRow, srcRow, copyLen)
                }
            }
            return VPhoneCameraFrame(
                width: width, height: height,
                bytesPerRow: bytesPerRow,
                timestampNS: UInt64(ProcessInfo.processInfo.systemUptime * 1e9),
                pixels: out)
        }

        // Slow path: resize via Core Image. Stretches to fit; pick aspect
        // strategy here if you want letterboxing instead.
        let srcImage = CIImage(cvPixelBuffer: pb)
        let scaleX = CGFloat(width) / CGFloat(srcWidth)
        let scaleY = CGFloat(height) / CGFloat(srcHeight)
        let scaled = srcImage.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var out = Data(count: bytesPerRow * height)
        out.withUnsafeMutableBytes { dst in
            let dstBase = dst.baseAddress!
            ciContext.render(
                scaled,
                toBitmap: dstBase,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .BGRA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return VPhoneCameraFrame(
            width: width, height: height,
            bytesPerRow: bytesPerRow,
            timestampNS: UInt64(ProcessInfo.processInfo.systemUptime * 1e9),
            pixels: out)
    }
}
