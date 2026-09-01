import XCTest
@testable import VPhoneCameraShared

final class VPhoneVirtualCameraProtocolTests: XCTestCase {
    func testIdentifiersAndPortAreStable() {
        XCTAssertEqual(VPhoneVirtualCamera.extensionIdentifier, "com.vphone.cli.camera")
        XCTAssertEqual(VPhoneVirtualCamera.deviceIdentifier, "com.vphone.cli.display")
        XCTAssertEqual(VPhoneVirtualCamera.streamIdentifier, "com.vphone.cli.display.video")
        XCTAssertEqual(VPhoneVirtualCamera.loopbackPort,
                       VPhoneVirtualCamera.loopbackPort(for: VPhoneVirtualCamera.extensionIdentifier))
        XCTAssertTrue((49_152...65_535).contains(VPhoneVirtualCamera.loopbackPort))
    }

    func testPacketRoundTripsHeader() throws {
        let pixels = Data(repeating: 0xA5, count: 64 * 3)
        let packet = VPhoneVirtualCameraFrameProtocol.packet(
            width: 12, height: 3, bytesPerRow: 64, hostTimeNS: 123_456_789, pixels: pixels)
        let header = try XCTUnwrap(VPhoneVirtualCameraFrameProtocol.decodeHeader(
            Data(packet.prefix(VPhoneVirtualCameraFrameProtocol.headerLength))))
        XCTAssertEqual(header.width, 12)
        XCTAssertEqual(header.height, 3)
        XCTAssertEqual(header.bytesPerRow, 64)
        XCTAssertEqual(header.hostTimeNS, 123_456_789)
        XCTAssertEqual(header.payloadLength, pixels.count)
        XCTAssertEqual(packet.dropFirst(VPhoneVirtualCameraFrameProtocol.headerLength), pixels)
    }

    func testInvalidHeaderIsRejected() {
        var packet = VPhoneVirtualCameraFrameProtocol.packet(
            width: 16, height: 1, bytesPerRow: 64, hostTimeNS: 1, pixels: Data(repeating: 0, count: 64))
        packet[0] = 0
        XCTAssertNil(VPhoneVirtualCameraFrameProtocol.decodeHeader(
            Data(packet.prefix(VPhoneVirtualCameraFrameProtocol.headerLength))))
    }
}
