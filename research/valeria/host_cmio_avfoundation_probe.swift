#!/usr/bin/env swift
// Validate that a published VPhone CMIO device delivers an AVFoundation frame.
// Usage: swiftc host_cmio_avfoundation_probe.swift -o /tmp/probe && /tmp/probe [device-name]

import AVFoundation
import CoreVideo
import Foundation

private final class FrameProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var value: (width: Int, height: Int, format: OSType)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = (
            width: CVPixelBufferGetWidth(image),
            height: CVPixelBufferGetHeight(image),
            format: CVPixelBufferGetPixelFormatType(image)
        )
        lock.unlock()
        signal.signal()
    }

    func wait(timeout: TimeInterval) -> (width: Int, height: Int, format: OSType)? {
        _ = signal.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

let requestedName = CommandLine.arguments.dropFirst().first
let devices = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external],
    mediaType: .video,
    position: .unspecified
).devices
let device = devices.first { candidate in
    if let requestedName { return candidate.localizedName == requestedName }
    return candidate.localizedName.hasPrefix("VPhone — ")
}

guard let device else {
    let names = devices.map(\.localizedName).joined(separator: ", ")
    fputs("[host-cmio-avfoundation-probe] VPhone device not found; available: \(names)\n", stderr)
    exit(2)
}

let session = AVCaptureSession()
guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
    fputs("[host-cmio-avfoundation-probe] cannot create input for \(device.localizedName)\n", stderr)
    exit(3)
}
session.addInput(input)

let output = AVCaptureVideoDataOutput()
output.alwaysDiscardsLateVideoFrames = true
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
guard session.canAddOutput(output) else {
    fputs("[host-cmio-avfoundation-probe] cannot add video output\n", stderr)
    exit(4)
}
private let probe = FrameProbe()
output.setSampleBufferDelegate(probe, queue: DispatchQueue(label: "com.vphone.cmio.avfoundation-probe"))
session.addOutput(output)
session.startRunning()
defer { session.stopRunning() }

guard let frame = probe.wait(timeout: 10) else {
    fputs("[host-cmio-avfoundation-probe] timed out waiting for \(device.localizedName) frame\n", stderr)
    exit(5)
}
print("[host-cmio-avfoundation-probe] device=\(device.localizedName) width=\(frame.width) height=\(frame.height) pixelFormat=0x\(String(frame.format, radix: 16))")
