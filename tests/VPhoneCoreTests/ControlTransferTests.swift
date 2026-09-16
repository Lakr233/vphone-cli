import Darwin
import Foundation
import XCTest
@testable import VPhoneCore

final class ControlTransferTests: XCTestCase {
    func testStrictLengths() throws {
        for json in ["true", "-1", "1.5", "\"3\"", "9223372036854775808", "null"] {
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            XCTAssertThrowsError(try VPhoneControlTransfer.length(value))
        }
        XCTAssertEqual(try VPhoneControlTransfer.length(NSNumber(value: 0)), 0)
        XCTAssertEqual(try VPhoneControlTransfer.length(NSNumber(value: 123)), 123)
        XCTAssertThrowsError(try VPhoneControlTransfer.length(nil))
    }

    func testPayloadPolicy() throws {
        XCTAssertThrowsError(try VPhoneControlTransfer.payloadLength(
            message: ["t": "file_data", "size": 8], requestType: "ping", streaming: false))
        XCTAssertThrowsError(try VPhoneControlTransfer.payloadLength(
            message: ["t": "file_data", "size": Int.max], requestType: "file_get", streaming: false))
        XCTAssertEqual(try VPhoneControlTransfer.payloadLength(
            message: ["t": "file_data", "size": Int.max], requestType: "file_get", streaming: true), Int.max)
        XCTAssertThrowsError(try VPhoneControlTransfer.payloadLength(
            message: ["t": "clipboard_get", "has_image": true], requestType: "clipboard_get", streaming: false))
    }

    func testReadDeadlineAndTruncation() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        XCTAssertThrowsError(try VPhoneControlTransfer.receive(fd: sockets[0], count: 1,
            deadline: ProcessInfo.processInfo.systemUptime + 0.02))
        shutdown(sockets[1], SHUT_WR)
        XCTAssertThrowsError(try VPhoneControlTransfer.receive(fd: sockets[0], count: 1,
            deadline: ProcessInfo.processInfo.systemUptime + 1))
    }

    func testEmptyAndValidPayload() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        XCTAssertEqual(try VPhoneControlTransfer.receive(fd: sockets[0], count: 0, deadline: deadline), Data())
        let bytes = Data("payload".utf8)
        _ = bytes.withUnsafeBytes { write(sockets[1], $0.baseAddress!, $0.count) }
        XCTAssertEqual(try VPhoneControlTransfer.receive(fd: sockets[0], count: bytes.count, deadline: deadline), bytes)
    }
}
