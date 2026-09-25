import AVFoundation
import CoreGraphics
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
    private let startedAt: TimeInterval

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        // Round bytesPerRow up to 16-byte alignment — common requirement for
        // IOSurfaces and BGRA hardware paths. For 1280 width: 1280*4 = 5120
        // (already 16-aligned).
        let stride = ((width * 4) + 15) & ~15
        bytesPerRow = stride
        startedAt = ProcessInfo.processInfo.systemUptime
    }

    func nextFrame() -> VPhoneCameraFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - startedAt
        let pixelCount = bytesPerRow * height
        var bytes = [UInt8](repeating: 0, count: pixelCount)

        // Vertical gradient. Hue rolls with time.
        let hueOffset = elapsed * 0.4 // turns per second
        for y in 0 ..< height {
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
            for _ in 0 ..< width {
                bytes[idx + 0] = bB // B
                bytes[idx + 1] = gB // G
                bytes[idx + 2] = rB // R
                bytes[idx + 3] = 255 // A
                idx += 4
            }
        }

        // Counter overlay: a moving small white square (poor man's frame
        // counter — the receiver can eyeball motion to confirm fps).
        let sqSize = 32
        let xPos = Int(elapsed * 200) % max(1, width - sqSize)
        let yPos = max(8, (height - sqSize) / 8)
        for dy in 0 ..< sqSize {
            let row = (yPos + dy) * bytesPerRow
            for dx in 0 ..< sqSize {
                let off = row + (xPos + dx) * 4
                bytes[off + 0] = 255
                bytes[off + 1] = 255
                bytes[off + 2] = 255
                bytes[off + 3] = 255
            }
        }

        let ts = UInt64(now * 1_000_000_000)
        return VPhoneCameraFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            timestampNS: ts,
            pixels: Data(bytes),
        )
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

/// Plays a video file in a loop. Decode is delegated to
/// `AVAssetReaderVideoCompositionOutput`, so anything AVFoundation can demux
/// on macOS works (`.mov`, `.mp4`, `.m4v`). For unsupported containers
/// (`.mkv`, `.webm`, `.avi`) convert externally first
/// (e.g. `ffmpeg -i in.mkv -c copy out.mov` if codecs are compatible).
///
/// A letterbox video composition renders every frame at the configured
/// camera width/height, so full-resolution BGRA frames of a large source
/// (a 2160x3840 portrait clip is about 33 MB per frame) are never
/// materialized. The aspect ratio is preserved with black bars, and the
/// track's preferred transform is applied so rotated portrait clips stay
/// upright. Output is always 8-bit BGRA, top-down, 16-byte aligned
/// bytesPerRow.
final class VPhoneVideoFileProducer: VPhoneFrameProducer, @unchecked Sendable {
    private let url: URL
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var asset: AVURLAsset
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderVideoCompositionOutput?

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width
        self.height = height
        bytesPerRow = ((width * 4) + 15) & ~15
        asset = AVURLAsset(url: url)
        try restartReader()
    }

    /// Aspect-fit letterbox composition at the camera size.
    private func letterboxComposition(for track: AVAssetTrack) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let bounds = CGRect(origin: .zero, size: track.naturalSize)
            .applying(track.preferredTransform)
        let boundsWidth = abs(bounds.width)
        let boundsHeight = abs(bounds.height)
        let scale = min(CGFloat(width) / boundsWidth, CGFloat(height) / boundsHeight)
        let tx = (CGFloat(width) - boundsWidth * scale) / 2 - bounds.minX * scale
        let ty = (CGFloat(height) - boundsHeight * scale) / 2 - bounds.minY * scale
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            track.preferredTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty)),
            at: .zero,
        )
        // The layer instruction must sit inside a composition instruction.
        // Assigning it to `instructions` directly raises an unrecognized
        // selector (`timeRange`) when the reader validates the composition.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    private func restartReader() throws {
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NSError(
                domain: "VPhoneVideoFileProducer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent): no video track"],
            )
        }
        let r = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
            ],
        )
        output.videoComposition = letterboxComposition(for: track)
        output.alwaysCopiesSampleData = false
        r.add(output)
        guard r.startReading() else {
            throw NSError(
                domain: "VPhoneVideoFileProducer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "AVAssetReader.startReading failed: \(r.error?.localizedDescription ?? "?")"],
            )
        }
        reader = r
        readerOutput = output
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

        // The composition output already has the camera size and BGRA
        // format; copy it row by row into the 16-byte aligned wire stride.
        if srcWidth == width, srcHeight == height,
           CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
        {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let srcBPR = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            var out = Data(count: bytesPerRow * height)
            out.withUnsafeMutableBytes { dst in
                let dstBase = dst.baseAddress!
                for y in 0 ..< height {
                    let dstRow = dstBase.advanced(by: y * bytesPerRow)
                    let srcRow = base.advanced(by: y * srcBPR)
                    let copyLen = min(srcBPR, bytesPerRow)
                    memcpy(dstRow, srcRow, copyLen)
                }
            }
            return VPhoneCameraFrame(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestampNS: UInt64(ProcessInfo.processInfo.systemUptime * 1e9),
                pixels: out,
            )
        }

        // The composition renders every frame at the camera size in BGRA,
        // so the copy above always applies. Any other size means the
        // composition was ignored; drop the frame instead of sending a
        // malformed payload.
        print("[camera] video frame mismatch: \(srcWidth)x\(srcHeight) "
            + "format \(CVPixelBufferGetPixelFormatType(pb))")
        return nil
    }
}
