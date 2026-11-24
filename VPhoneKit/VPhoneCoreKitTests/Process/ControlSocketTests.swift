import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

/// `ping` against a temp-path Unix server that answers, refuses, or stays silent.
struct ControlSocketTests {
    /// Binds a listener at a short temp path. `reply` is written to each
    /// connection after its request line is read; nil leaves the client
    /// waiting.
    private final class Server {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(8)).sock").path
        private let fd: Int32
        private let held = DispatchQueue(label: "ControlSocketTests.server")

        init(reply: String?) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(fd >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() {
                    buffer[index] = byte
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0)
            try #require(listen(fd, 4) == 0)
            let listener = fd
            held.async {
                while true {
                    let client = accept(listener, nil, nil)
                    if client < 0 { return }
                    var byte: UInt8 = 0
                    while Darwin.read(client, &byte, 1) == 1, byte != 0x0A {}
                    if let reply {
                        let line = Array((reply + "\n").utf8)
                        _ = Darwin.write(client, line, line.count)
                        close(client)
                    } else {
                        // Silent: keep the connection open until the test ends.
                        Thread.sleep(forTimeInterval: 5)
                        close(client)
                    }
                }
            }
        }

        deinit {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    @Test func `an ok true reply is a ping`() throws {
        let server = try Server(reply: #"{"ok":true}"#)
        #expect(VPhoneControlSocket.ping(socketPath: server.path))
    }

    @Test func `an ok false reply is not a ping`() throws {
        let server = try Server(reply: #"{"ok":false}"#)
        #expect(!VPhoneControlSocket.ping(socketPath: server.path))
    }

    @Test func `no listener is not a ping`() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(8)).sock").path
        #expect(!VPhoneControlSocket.ping(socketPath: path))
    }

    @Test func `a silent server is not a ping and returns in under 3 seconds`() throws {
        let server = try Server(reply: nil)
        let start = Date()
        #expect(!VPhoneControlSocket.ping(socketPath: server.path))
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
