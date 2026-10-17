import Foundation

/// The host screen API, `GET /v1/host/screen` on the `--api-listen` proxy.
///
/// The VM's own display is captured and encoded by `vphone-vm` itself, so the
/// guest does no work for it: no screenshot, no JPEG, no base64. The client
/// pulls one frame per request, which keeps its own pacing and flow control.
///
/// Each request is a WebSocket text message:
///
///     {"id":7,"codec":"hevc","box":[1280,1280],"fps":60,"bitrate":4000000,"key":false}
///
/// and its answer one binary message: a 4-byte little-endian header length,
/// that many bytes of JSON header, then the payload. Requests are answered in
/// the order they arrive. The header always carries `id`, and then either
/// `error` (`{"code","message"}`) with no payload, or `status`:
///
/// - `frame`: the payload is one access unit as VideoToolbox writes it
///   (length-prefixed NAL units). `session` counts encoder sessions and
///   changes when the size, codec or orientation does; the first frame of a
///   session is a key frame. Every key frame carries the decoder configuration
///   record (`avcC` / `hvcC`) as base64 in `record`.
/// - `unchanged`: the display shows what the last frame showed and no key
///   frame was asked for; nothing was encoded.
/// - `dropped`: the encoder's rate control skipped the frame.
///
/// `width` and `height` are the encoded size, `sourceWidth`, `sourceHeight`
/// and `scale` the upright display in pixels and pixels per interface point.
public enum VPhoneHostScreenProtocol {
    public static let path = "/v1/host/screen"

    public enum Codec: String, Sendable {
        case hevc
        case h264
    }

    public struct Request: Equatable, Sendable {
        public var id: UInt64
        public var codec: Codec
        public var boxWidth: Int
        public var boxHeight: Int
        public var fps: Int
        public var bitrate: Int
        public var key: Bool

        public init(id: UInt64, codec: Codec, boxWidth: Int, boxHeight: Int, fps: Int, bitrate: Int, key: Bool) {
            self.id = id
            self.codec = codec
            self.boxWidth = boxWidth
            self.boxHeight = boxHeight
            self.fps = fps
            self.bitrate = bitrate
            self.key = key
        }
    }

    public struct RequestError: Error, Equatable, CustomStringConvertible {
        public let code: String
        public let description: String
    }

    static let maximumBox = 8192
    static let maximumFps = 240
    static let maximumBitrate = 100_000_000

    public static func parse(_ data: Data) throws(RequestError) -> Request {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RequestError(code: "bad_request", description: "a request is one JSON object")
        }
        guard let id = (object["id"] as? NSNumber).flatMap(integer), id >= 0 else {
            throw RequestError(code: "bad_request", description: "id must be a non-negative integer")
        }
        guard let name = object["codec"] as? String, let codec = Codec(rawValue: name) else {
            throw RequestError(code: "codec_unavailable", description: "codec must be hevc or h264")
        }
        guard let box = object["box"] as? [NSNumber], box.count == 2,
              let width = integer(box[0]), let height = integer(box[1]),
              (1 ... maximumBox).contains(width), (1 ... maximumBox).contains(height)
        else {
            throw RequestError(code: "bad_request", description: "box must be [width, height] within 1...\(maximumBox)")
        }
        guard let fps = (object["fps"] as? NSNumber).flatMap(integer), (1 ... maximumFps).contains(fps) else {
            throw RequestError(code: "bad_request", description: "fps must be within 1...\(maximumFps)")
        }
        guard let bitrate = (object["bitrate"] as? NSNumber).flatMap(integer),
              (1 ... maximumBitrate).contains(bitrate)
        else {
            throw RequestError(code: "bad_request", description: "bitrate must be within 1...\(maximumBitrate)")
        }
        let key = object["key"] as? Bool ?? false
        return Request(id: UInt64(id), codec: codec, boxWidth: width, boxHeight: height, fps: fps, bitrate: bitrate, key: key)
    }

    /// A JSON number that is a whole number; a boolean is not one.
    private static func integer(_ number: NSNumber) -> Int? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    // MARK: - Geometry

    /// The output size for a source in a box: the screen helper's own rule
    /// (`media.OutputSize`), so a stream keeps the size it had when the helper
    /// scaled the guest's screenshots itself. The source is fitted without
    /// enlarging it, the short side is kept at 240 when the source allows, and
    /// both sides are rounded down to even numbers.
    public static func outputSize(sourceWidth: Int, sourceHeight: Int, boxWidth: Int, boxHeight: Int) -> (width: Int, height: Int) {
        let minimumShortSide = 240
        var width = sourceWidth
        var height = sourceHeight
        if width > boxWidth || height > boxHeight {
            width = boxWidth
            height = (sourceHeight * boxWidth + sourceWidth / 2) / sourceWidth
            if height > boxHeight {
                height = boxHeight
                width = (sourceWidth * boxHeight + sourceHeight / 2) / sourceHeight
            }
        }
        let short = min(width, height)
        if short < minimumShortSide, min(sourceWidth, sourceHeight) > short {
            let target = min(minimumShortSide, min(sourceWidth, sourceHeight))
            if sourceWidth <= sourceHeight {
                width = target
                height = (sourceHeight * target + sourceWidth / 2) / sourceWidth
            } else {
                width = (sourceWidth * target + sourceHeight / 2) / sourceHeight
                height = target
            }
        }
        return (max(width & ~1, 2), max(height & ~1, 2))
    }

    /// How far the panel-oriented display buffer turns clockwise to stand
    /// upright under an interface orientation in `display.orientation`'s
    /// degrees: under landscape-left (90) the top of the interface lies along
    /// the buffer's left edge. Unknown values leave the buffer as it is.
    public static func clockwiseTurn(forInterfaceDegrees degrees: Int) -> Int {
        switch degrees {
        case 90: 90
        case 180: 180
        case 270: 270
        default: 0
        }
    }

    // MARK: - Messages

    /// One answer: header length, JSON header, payload.
    public static func message(header: [String: Any], payload: Data = Data()) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
            ?? Data(#"{"error":{"code":"internal","message":"header is not JSON"}}"#.utf8)
        var length = UInt32(json.count).littleEndian
        var message = Data(bytes: &length, count: 4)
        message.append(json)
        message.append(payload)
        return message
    }

    public static func errorMessage(id: UInt64?, code: String, message text: String) -> Data {
        var header: [String: Any] = ["error": ["code": code, "message": text]]
        if let id {
            header["id"] = id
        }
        return message(header: header)
    }
}
