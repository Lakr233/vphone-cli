import AVFoundation
import CoreImage
import Foundation
import ImageIO

public enum VPhoneCameraRotation: Int, CaseIterable, Sendable {
    case upright = 0
    case clockwise = 1
    case upsideDown = 2
    case counterclockwise = 3

    public var title: String {
        switch self {
        case .upright: "0° (Upright)"
        case .clockwise: "90° Clockwise"
        case .upsideDown: "180° Upside Down"
        case .counterclockwise: "90° Counterclockwise"
        }
    }

    public var orientation: CGImagePropertyOrientation {
        switch self {
        case .upright: .up
        case .clockwise: .right
        case .upsideDown: .down
        case .counterclockwise: .left
        }
    }
}

/// The capture queue owns the session; a lock protects the latest buffer shared
/// with the existing frame sender. Keeping one buffer bounds latency and memory.
final class VPhoneSystemCameraProducer: NSObject, VPhoneFrameProducer,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let session = AVCaptureSession()
    // Shared queue orders stop of the old camera before start of its replacement.
    private static let captureQueue = DispatchQueue(label: "com.vphone.camera.capture")
    private let queue = VPhoneSystemCameraProducer.captureQueue
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var rotation: VPhoneCameraRotation = .upright
    private let context = CIContext()
    private let width: Int
    private let height: Int

    init(width: Int, height: Int, deviceID: String? = nil, rotation: VPhoneCameraRotation = .upright) throws {
        self.width = width
        self.height = height
        self.rotation = rotation
        super.init()
        // Permission is requested by the explicit menu action, before creating
        // a device input. Selecting this source alone does not start capture.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw Self.error("Camera access has not been granted.")
        }
        let selected = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
        guard let device = deviceID == nil ? AVCaptureDevice.default(for: .video) : selected else {
            throw Self.error(deviceID == nil ? "No system camera is available." :
                "The selected camera is no longer available. Choose another camera.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw Self.error("The system camera could not be opened.")
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw Self.error("The system camera cannot provide video frames.")
        }
        session.addOutput(output)
    }

    func start() {
        queue.async { [self] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            lock.lock()
            latest = nil
            lock.unlock()
        }
    }

    func setRotation(_ rotation: VPhoneCameraRotation) {
        lock.lock()
        self.rotation = rotation
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
    }

    func nextFrame() -> VPhoneCameraFrame? {
        lock.lock()
        let buffer = latest
        let currentRotation = rotation
        lock.unlock()
        guard let buffer else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, nil, &destination) == kCVReturnSuccess,
              let destination else { return nil }
        let rawSource = CIImage(cvPixelBuffer: buffer)
        let source = (currentRotation == .upright) ? rawSource : rawSource.oriented(currentRotation.orientation)
        let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (CGFloat(width) - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (CGFloat(height) - scaled.extent.height) / 2 - scaled.extent.minY))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let image = centered.composited(over: CIImage(color: .black).cropped(to: bounds))
        context.render(image, to: destination, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        guard CVPixelBufferLockBaseAddress(destination, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(destination)
        return VPhoneCameraFrame(width: width, height: height, bytesPerRow: stride,
            timestampNS: UInt64(ProcessInfo.processInfo.systemUptime * 1e9),
            pixels: Data(bytes: base, count: stride * height))
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "VPhoneSystemCameraProducer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
