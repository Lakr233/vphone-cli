import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import VPhoneCoreKit

// MARK: - Host Screen Encoder

/// Turns display frames into one video stream: upright, fitted into the
/// requested box and encoded by the hardware encoder. It serves one client and
/// is called from one queue at a time; `encode` returns that frame's result.
///
/// Colour follows the screen helper's own encoder (Display P3 primaries, sRGB
/// transfer, BT.709 matrix, video range), so a consumer configured for the
/// helper's stream decodes this one unchanged.
///
/// Unchecked: all of its state is used from the one queue its client owns.
final class VPhoneHostScreenEncoder: @unchecked Sendable {
    typealias Codec = VPhoneHostScreenProtocol.Codec

    enum Status: String {
        case frame
        case unchanged
        case dropped
    }

    struct Result {
        var status: Status
        var session: Int
        var key = false
        var width: Int
        var height: Int
        var sourceWidth: Int
        var sourceHeight: Int
        var payload = Data()
        /// The decoder configuration record, on a session's first frame.
        var record: Data?
        var encodeMicroseconds = 0
    }

    struct Failure: Error, CustomStringConvertible {
        let code: String
        let description: String
    }

    private struct Layout: Equatable {
        var codec: Codec
        var imageWidth: Int
        var imageHeight: Int
        var turn: Int
        var boxWidth: Int
        var boxHeight: Int
    }

    private var layout: Layout?
    private var sessions = 0
    private var encoder: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var rotator: VTPixelRotationSession?
    private var sourcePool: CVPixelBufferPool?
    private var scaledPool: CVPixelBufferPool?
    private var output = (width: 0, height: 0, sourceWidth: 0, sourceHeight: 0)
    private var bitrate = 0
    private var fps = 0
    /// The pixels of the last frame encoded, to tell a still screen apart.
    private var lastPixels: CFData?
    private var sentRecord = false
    private var frameIndex: Int64 = 0

    deinit {
        close()
    }

    func close() {
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        transfer.map { VTPixelTransferSessionInvalidate($0) }
        transfer = nil
        rotator.map { VTPixelRotationSessionInvalidate($0) }
        rotator = nil
        layout = nil
    }

    /// `turn` is how far the panel buffer turns clockwise to stand upright.
    func encode(_ image: CGImage, request: VPhoneHostScreenProtocol.Request, turn: Int) throws(Failure) -> Result {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else {
            throw Failure(code: "display_unavailable", description: "the display frame has no pixels")
        }
        let wanted = Layout(
            codec: request.codec, imageWidth: image.width, imageHeight: image.height,
            turn: turn, boxWidth: request.boxWidth, boxHeight: request.boxHeight,
        )
        if wanted != layout || encoder == nil {
            try open(wanted, request: request)
        } else if request.bitrate != bitrate {
            bitrate = request.bitrate
            VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        }

        var result = Result(
            status: .unchanged, session: sessions, width: output.width, height: output.height,
            sourceWidth: output.sourceWidth, sourceHeight: output.sourceHeight,
        )
        let key = request.key || !sentRecord
        // Every byte is compared: a sampled hash misses a text cursor.
        guard key || !Self.same(data, lastPixels) else { return result }

        let source = try sourceBuffer(image, base: base)
        let picture = try convert(source)
        let started = DispatchTime.now().uptimeNanoseconds
        let encoded = try compress(picture, key: key)
        result.encodeMicroseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1000)
        guard let encoded else {
            result.status = .dropped
            return result
        }
        lastPixels = data
        result.status = .frame
        result.key = encoded.key
        result.payload = encoded.payload
        if encoded.key {
            result.record = encoded.record
            sentRecord = sentRecord || encoded.record != nil
        }
        return result
    }

    // MARK: Sessions

    private func check(_ status: OSStatus, _ what: String, code: String = "encoder_failed") throws(Failure) {
        guard status == noErr else { throw Failure(code: code, description: "\(what) failed (\(status))") }
    }

    private func open(_ wanted: Layout, request: VPhoneHostScreenProtocol.Request) throws(Failure) {
        close()
        let sideways = wanted.turn == 90 || wanted.turn == 270
        let sourceWidth = sideways ? wanted.imageHeight : wanted.imageWidth
        let sourceHeight = sideways ? wanted.imageWidth : wanted.imageHeight
        let size = VPhoneHostScreenProtocol.outputSize(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            boxWidth: wanted.boxWidth, boxHeight: wanted.boxHeight,
        )
        output = (size.width, size.height, sourceWidth, sourceHeight)

        var transfer: VTPixelTransferSession?
        try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer), "pixel transfer session")
        guard let transfer else { throw Failure(code: "encoder_failed", description: "no pixel transfer session") }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_P3_D65)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        self.transfer = transfer

        sourcePool = try Self.pool(kCVPixelFormatType_32BGRA, wanted.imageWidth, wanted.imageHeight)
        if wanted.turn != 0 {
            var rotator: VTPixelRotationSession?
            try check(VTPixelRotationSessionCreate(nil, &rotator), "pixel rotation session")
            guard let rotator else { throw Failure(code: "encoder_failed", description: "no pixel rotation session") }
            let angle: CFString = switch wanted.turn {
            case 90: kVTRotation_CW90
            case 180: kVTRotation_180
            default: kVTRotation_CCW90
            }
            VTSessionSetProperty(rotator, key: kVTPixelRotationPropertyKey_Rotation, value: angle)
            self.rotator = rotator
            let scaledWidth = sideways ? size.height : size.width
            let scaledHeight = sideways ? size.width : size.height
            scaledPool = try Self.pool(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, scaledWidth, scaledHeight)
        } else {
            scaledPool = nil
        }

        try openEncoder(wanted.codec, width: size.width, height: size.height, request: request)
        layout = wanted
        sessions += 1
        sentRecord = false
        lastPixels = nil
        frameIndex = 0
    }

    private func openEncoder(_ codec: Codec, width: Int, height: Int, request: VPhoneHostScreenProtocol.Request) throws(Failure) {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session,
        )
        guard created == noErr, let session else {
            throw Failure(code: "codec_unavailable", description: "no hardware \(codec.rawValue) encoder for \(width)x\(height) (\(created))")
        }
        // Required: with reordering a frame would not come out of the call
        // that put it in, and encode() answers each request with its own frame.
        guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw Failure(code: "codec_unavailable", description: "the \(codec.rawValue) encoder cannot disable frame reordering")
        }
        bitrate = request.bitrate
        fps = request.fps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_P3_D65)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        // Key frames come when the client asks for one.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 36000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw Failure(code: "codec_unavailable", description: "the \(codec.rawValue) encoder did not start")
        }
        encoder = session
    }

    private static func pool(_ format: OSType, _ width: Int, _ height: Int) throws(Failure) -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw Failure(code: "encoder_failed", description: "no \(width)x\(height) buffer pool (\(status))")
        }
        return pool
    }

    private static func buffer(_ pool: CVPixelBufferPool?) throws(Failure) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw Failure(code: "encoder_failed", description: "no pixel buffer")
        }
        return buffer
    }

    // MARK: Pixels

    /// The frame as a BGRA IOSurface. Pixel transfer refuses the display's
    /// RGBA bytes as they are, so one pass swaps the channels while copying.
    private func sourceBuffer(_ image: CGImage, base: UnsafePointer<UInt8>) throws(Failure) -> CVPixelBuffer {
        let buffer = try Self.buffer(sourcePool)
        CVPixelBufferLockBaseAddress(buffer, [])
        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: base),
            height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
            rowBytes: image.bytesPerRow,
        )
        var destination = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(buffer),
            height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer),
        )
        let order: [UInt8] = switch image.bitmapInfo.intersection(.byteOrderMask) {
        case .byteOrder32Little: [0, 1, 2, 3]
        default: [2, 1, 0, 3]
        }
        let error = vImagePermuteChannels_ARGB8888(&source, &destination, order, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard error == kvImageNoError else {
            throw Failure(code: "encoder_failed", description: "the frame could not be copied (\(error))")
        }
        if let space = image.colorSpace {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        }
        return buffer
    }

    private func convert(_ source: CVPixelBuffer) throws(Failure) -> CVPixelBuffer {
        guard let transfer, let encoder else { throw Failure(code: "encoder_failed", description: "no session") }
        let picture = try Self.buffer(VTCompressionSessionGetPixelBufferPool(encoder))
        if let rotator {
            let scaled = try Self.buffer(scaledPool)
            try check(VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled), "pixel transfer")
            try check(VTPixelRotationSessionRotateImage(rotator, scaled, picture), "pixel rotation")
        } else {
            try check(VTPixelTransferSessionTransferImage(transfer, from: source, to: picture), "pixel transfer")
        }
        return picture
    }

    // MARK: Encoding

    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var status: OSStatus = noErr
        var sample: CMSampleBuffer?
        var done = false
    }

    private func compress(_ picture: CVPixelBuffer, key: Bool) throws(Failure) -> (payload: Data, key: Bool, record: Data?)? {
        guard let encoder else { throw Failure(code: "encoder_failed", description: "no session") }
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(max(fps, 1)))
        frameIndex += 1
        let properties: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let output = Output()
        let submitted = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: picture, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil,
        ) { status, _, sample in
            output.lock.withLock {
                output.status = status
                output.sample = sample
                output.done = true
            }
        }
        try check(submitted, "encode")
        try check(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: pts), "complete frame")
        let (status, sample, done) = output.lock.withLock { (output.status, output.sample, output.done) }
        try check(status, "encode")
        guard done, let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
            return nil
        }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        try check(copied, "read the encoded frame")
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true
        {
            isKey = false
        }
        var record: Data?
        if isKey, let description = CMSampleBufferGetFormatDescription(sample),
           let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        {
            record = (atoms["hvcC"] ?? atoms["avcC"]) as? Data
        }
        return (payload, isKey, record)
    }

    private static func same(_ data: CFData, _ other: CFData?) -> Bool {
        guard let other, CFDataGetLength(data) == CFDataGetLength(other),
              let a = CFDataGetBytePtr(data), let b = CFDataGetBytePtr(other)
        else { return false }
        return memcmp(a, b, CFDataGetLength(data)) == 0
    }
}
