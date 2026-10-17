import Foundation
import Testing
@testable import VPhoneCoreKit

struct HostScreenProtocolTests {
    typealias HostScreen = VPhoneHostScreenProtocol

    private func parse(_ json: String) throws(HostScreen.RequestError) -> HostScreen.Request {
        try HostScreen.parse(Data(json.utf8))
    }

    private func code(_ json: String) -> String? {
        do {
            _ = try parse(json)
            return nil
        } catch {
            return error.code
        }
    }

    // MARK: - Requests

    @Test func `a full request is read`() throws {
        let request = try parse(#"{"id":7,"codec":"hevc","box":[1280,800],"fps":60,"bitrate":4000000,"key":true}"#)
        #expect(request == HostScreen.Request(id: 7, codec: .hevc, boxWidth: 1280, boxHeight: 800, fps: 60, bitrate: 4_000_000, key: true))
    }

    @Test func `key is optional`() throws {
        let request = try parse(#"{"id":0,"codec":"h264","box":[2,2],"fps":1,"bitrate":1}"#)
        #expect(request.codec == .h264)
        #expect(!request.key)
    }

    @Test func `an unknown codec is its own error`() {
        #expect(code(#"{"id":1,"codec":"jpeg","box":[1,1],"fps":1,"bitrate":1}"#) == "codec_unavailable")
        #expect(code(#"{"id":1,"box":[1,1],"fps":1,"bitrate":1}"#) == "codec_unavailable")
    }

    @Test func `malformed requests are refused`() {
        for json in [
            "",
            "[]",
            #"{"codec":"hevc","box":[1,1],"fps":1,"bitrate":1}"#,
            #"{"id":-1,"codec":"hevc","box":[1,1],"fps":1,"bitrate":1}"#,
            #"{"id":1.5,"codec":"hevc","box":[1,1],"fps":1,"bitrate":1}"#,
            #"{"id":true,"codec":"hevc","box":[1,1],"fps":1,"bitrate":1}"#,
            #"{"id":1,"codec":"hevc","box":[1],"fps":1,"bitrate":1}"#,
            #"{"id":1,"codec":"hevc","box":[0,10],"fps":1,"bitrate":1}"#,
            #"{"id":1,"codec":"hevc","box":[10,8193],"fps":1,"bitrate":1}"#,
            #"{"id":1,"codec":"hevc","box":[10,10],"fps":0,"bitrate":1}"#,
            #"{"id":1,"codec":"hevc","box":[10,10],"fps":241,"bitrate":1}"#,
            #"{"id":1,"codec":"hevc","box":[10,10],"fps":60}"#,
            #"{"id":1,"codec":"hevc","box":[10,10],"fps":60,"bitrate":100000001}"#,
        ] {
            #expect(code(json) == "bad_request", "\(json)")
        }
    }

    // MARK: - Geometry

    @Test func `output size matches the screen helper`() {
        // Each expected size is what the helper's media.OutputSize returns.
        let size = HostScreen.outputSize
        #expect(size(1488, 2266, 8192, 8192) == (1488, 2266))
        #expect(size(1488, 2266, 1280, 1280) == (840, 1280))
        #expect(size(2266, 1488, 1280, 1280) == (1280, 840))
        #expect(size(2266, 1488, 1280, 400) == (608, 400))
        #expect(size(1179, 2556, 50, 50) == (240, 520))
        #expect(size(100, 200, 50, 50) == (100, 200))
        #expect(size(1001, 1001, 8192, 8192) == (1000, 1000))
    }

    @Test func `the buffer turns with the interface`() {
        #expect(HostScreen.clockwiseTurn(forInterfaceDegrees: 0) == 0)
        #expect(HostScreen.clockwiseTurn(forInterfaceDegrees: 90) == 90)
        #expect(HostScreen.clockwiseTurn(forInterfaceDegrees: 180) == 180)
        #expect(HostScreen.clockwiseTurn(forInterfaceDegrees: 270) == 270)
        #expect(HostScreen.clockwiseTurn(forInterfaceDegrees: 45) == 0)
    }

    // MARK: - Messages

    @Test func `a message is length, header and payload`() throws {
        let data = HostScreen.message(header: ["id": 3, "status": "frame"], payload: Data([0xAA, 0xBB]))
        let length = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        let header = try #require(try JSONSerialization.jsonObject(with: data.dropFirst(4).prefix(length)) as? [String: Any])
        #expect(header["id"] as? Int == 3)
        #expect(header["status"] as? String == "frame")
        #expect(Array(data.suffix(from: 4 + length)) == [0xAA, 0xBB])
    }

    @Test func `an error carries no payload`() throws {
        let data = HostScreen.errorMessage(id: 9, code: "display_unavailable", message: "no display")
        let length = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        #expect(data.count == 4 + length)
        let header = try #require(try JSONSerialization.jsonObject(with: data.dropFirst(4)) as? [String: Any])
        let error = try #require(header["error"] as? [String: Any])
        #expect(header["id"] as? Int == 9)
        #expect(error["code"] as? String == "display_unavailable")
    }
}
