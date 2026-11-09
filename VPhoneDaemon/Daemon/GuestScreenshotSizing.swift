import CoreGraphics
import Foundation
import ImageIO

// MARK: - Screenshot Sizing

/// The `max_dimension`, `quality` and `region` parameters of
/// `screen.screenshot`: crop to a region, scale down, re-encode.
///
/// A region is in points, the space `input.*` takes. The crop rounds its edges
/// to whole pixels, so an image pixel `(px, py)` is the point
/// `(region.x + px / scale, region.y + py / scale)` within one pixel, where
/// `scale` is the returned pixels per point (`width / region.width`).
///
/// Nothing here touches the guest, so `VPhoneDaemon/Tests/run-logic-tests.sh`
/// builds this file on the Mac.
enum GuestScreenshotSizing {
    struct Region: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Options: Equatable {
        var maxDimension: Int?
        var quality: Double?
        var region: Region?

        /// No option asked for: the capture goes back as it is, undecoded.
        var isEmpty: Bool { maxDimension == nil && quality == nil && region == nil }
    }

    /// JPEG quality of a re-encoded image without `quality`, IcliKit's default.
    static let defaultQuality = 0.8

    static func parse(_ params: [String: Any]) throws -> Options {
        var options = Options()
        if let value = params["max_dimension"] {
            guard let number = number(value), number.rounded() == number, number >= 1, number <= Double(Int32.max) else {
                throw GuestAPIError.invalidRequest("max_dimension \(describe(value)) is out of range; use a whole number of 1 or more")
            }
            options.maxDimension = Int(number)
        }
        if let value = params["quality"] {
            guard let number = number(value), (0.1 ... 1.0).contains(number) else {
                throw GuestAPIError.invalidRequest("quality \(describe(value)) is out of range; use 0.1 to 1.0")
            }
            options.quality = number
        }
        if let value = params["region"] {
            guard let fields = value as? [String: Any] else {
                throw GuestAPIError.invalidRequest("region \(describe(value)) is not an object; use {x, y, width, height} in points")
            }
            func field(_ name: String) throws -> Double {
                guard let value = fields[name], let number = number(value) else {
                    let received = fields[name].map(describe) ?? "missing"
                    throw GuestAPIError.invalidRequest("region.\(name) \(received) is not a number; use a number of points")
                }
                return number
            }
            let region = try Region(x: field("x"), y: field("y"), width: field("width"), height: field("height"))
            for (name, value) in [("width", region.width), ("height", region.height)] where value <= 0 {
                throw GuestAPIError.invalidRequest("region.\(name) \(describe(value)) is out of range; use a value above 0")
            }
            for (name, value) in [("x", region.x), ("y", region.y)] where value < 0 {
                throw GuestAPIError.invalidRequest("region.\(name) \(describe(value)) is out of range; use 0 or more")
            }
            options.region = region
        }
        return options
    }

    /// Crops, scales and encodes `jpeg`, a capture of a screen `pointSize`
    /// points large. Returns the new image, its size in pixels and the region
    /// of the screen it shows.
    static func apply(
        _ options: Options,
        jpeg: Data,
        pointSize: (width: Double, height: Double),
    ) throws -> (jpeg: Data, width: Int, height: Int, region: Region) {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
            throw GuestAPIError.operationFailed("screenshot decode failed: not an image")
        }
        guard var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GuestAPIError.operationFailed("screenshot decode failed: no image in the data")
        }
        let scale = Double(image.width) / pointSize.width
        let region = options.region ?? Region(x: 0, y: 0, width: pointSize.width, height: pointSize.height)
        if options.region != nil {
            // Tolerance for a sum like 0.1 + 0.2 landing a hair past the edge.
            for (name, edge, size) in [("width", region.x + region.width, pointSize.width),
                                       ("height", region.y + region.height, pointSize.height)] where edge > size + 1e-9 {
                throw GuestAPIError.invalidRequest(
                    "region \(name == "width" ? "x + width" : "y + height") \(describe(edge)) is outside the screen; use at most \(describe(size))",
                )
            }
            let x0 = min(Int((region.x * scale).rounded()), image.width)
            let y0 = min(Int((region.y * scale).rounded()), image.height)
            let x1 = min(Int(((region.x + region.width) * scale).rounded()), image.width)
            let y1 = min(Int(((region.y + region.height) * scale).rounded()), image.height)
            for (name, pixels, points) in [("width", x1 - x0, region.width), ("height", y1 - y0, region.height)] where pixels < 1 {
                throw GuestAPIError.invalidRequest(
                    "region.\(name) \(describe(points)) is under one pixel; use at least \(describe(1 / scale)) points",
                )
            }
            guard let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else {
                throw GuestAPIError.operationFailed("screenshot crop failed")
            }
            image = cropped
        }
        if let maxDimension = options.maxDimension, maxDimension < max(image.width, image.height) {
            image = try scaled(image, longerSide: maxDimension)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw GuestAPIError.operationFailed("screenshot encode failed: no JPEG destination")
        }
        let encoding: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.quality ?? defaultQuality]
        CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw GuestAPIError.operationFailed("screenshot encode failed: JPEG finalize")
        }
        return (output as Data, image.width, image.height, region)
    }

    /// The `screen.screenshot` reply for `capture`, the reply of a native
    /// resolution capture. Without options the capture's image goes back as it
    /// is, undecoded. Otherwise `capture["jpeg"]` (`Data`) is cropped, scaled and encoded. Every reply
    /// carries `point_width`, `point_height` and `region`.
    static func reply(
        capture: [String: Any],
        options: Options,
        pointSize: (width: Double, height: Double),
    ) throws -> [String: Any] {
        var reply: [String: Any]
        var region = Region(x: 0, y: 0, width: pointSize.width, height: pointSize.height)
        if options.isEmpty {
            guard let bytes = capture["bytes"] as? Int, let mimeType = capture["mime_type"] as? String,
                  let width = capture["width"] as? Int, let height = capture["height"] as? Int,
                  let coordinateScale = capture["coordinate_scale"] as? Double, let data = capture["data"] as? String
            else {
                throw GuestAPIError.operationFailed("screenshot capture failed: the capture reply is incomplete")
            }
            reply = ["bytes": bytes, "mime_type": mimeType, "width": width, "height": height,
                     "coordinate_scale": coordinateScale, "data": data]
        } else {
            guard let jpeg = capture["jpeg"] as? Data else {
                throw GuestAPIError.operationFailed("screenshot capture failed: no image in the capture")
            }
            let sized = try apply(options, jpeg: jpeg, pointSize: pointSize)
            region = sized.region
            reply = ["bytes": sized.jpeg.count, "mime_type": "image/jpeg", "width": sized.width, "height": sized.height,
                     "coordinate_scale": Double(sized.width) / region.width, "data": sized.jpeg.base64EncodedString()]
        }
        reply["point_width"] = pointSize.width
        reply["point_height"] = pointSize.height
        reply["region"] = ["x": region.x, "y": region.y, "width": region.width, "height": region.height]
        return reply
    }

    /// Redraws `image` so its longer side is `longerSide` pixels, as
    /// `compactJPEG` in VPhoneHostAutomationServer does (the daemon cannot
    /// import the executable target, so the drawing is repeated here).
    private static func scaled(_ image: CGImage, longerSide: Int) throws -> CGImage {
        let longest = Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * Double(longerSide) / longest).rounded()))
        let height = max(1, Int((Double(image.height) * Double(longerSide) / longest).rounded()))
        // JPEG has no alpha, so none is kept.
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
              )
        else {
            throw GuestAPIError.operationFailed("screenshot scale failed: no drawing context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw GuestAPIError.operationFailed("screenshot scale failed: no scaled image")
        }
        return result
    }

    /// A JSON number, never a boolean, and finite.
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// A value as the caller sent it: whole numbers without a fraction.
    private static func describe(_ value: Any) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return describe(number.doubleValue)
        }
        return "\(value)"
    }

    private static func describe(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
