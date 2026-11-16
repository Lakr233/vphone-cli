import Foundation
import Testing
@testable import VPhoneCoreKit

struct HostAutomationProbeTests {
    private func socketPath(_ guest: FakeGuestVM) -> String {
        guest.bundle.url.appendingPathComponent("vphone.sock").path
    }

    /// Waits for the listener thread to bind.
    private func waitForSocket(_ guest: FakeGuestVM) {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath(guest)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    @Test("ping is true when the listener answers ok:true")
    func pingTrue() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle)
        defer { socket.stop(); guest.cleanUp() }
        waitForSocket(guest)
        #expect(VPhoneHostAutomationProbe.ping(socketPath: socketPath(guest)))
    }

    @Test("ping is false when there is no socket file")
    func pingNoSocket() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        #expect(!VPhoneHostAutomationProbe.ping(socketPath: socketPath(guest)))
    }

    @Test("ping is false when the listener answers ok:false")
    func pingRefused() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, reply: "{\"ok\":false}")
        defer { socket.stop(); guest.cleanUp() }
        waitForSocket(guest)
        #expect(!VPhoneHostAutomationProbe.ping(socketPath: socketPath(guest)))
    }

    @Test("ping is false, bounded by its timeout, when the listener never answers")
    func pingSilent() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, mode: .silent)
        defer { socket.stop(); guest.cleanUp() }
        waitForSocket(guest)
        let started = Date()
        #expect(!VPhoneHostAutomationProbe.ping(socketPath: socketPath(guest), timeout: 1))
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.9)
        #expect(elapsed < 5)
    }

    @Test("rpc returns the decoded result")
    func rpcResult() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle, reply: "{\"ok\":true,\"result\":{\"count\":3,\"name\":\"x\"}}")
        defer { socket.stop(); guest.cleanUp() }
        waitForSocket(guest)
        let result = try VPhoneHostAutomationProbe.rpc("apps.list", params: ["a": 1], socketPath: socketPath(guest), timeout: 2)
        #expect(result["count"] as? Int == 3)
        #expect(result["name"] as? String == "x")
    }

    @Test("rpc turns a guest_error reply into a refused error with its detail")
    func rpcRefused() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(
            bundle: guest.bundle,
            reply: "{\"ok\":false,\"error\":\"nope\",\"guest_error\":{\"code\":\"E1\"}}",
        )
        defer { socket.stop(); guest.cleanUp() }
        waitForSocket(guest)
        let error = #expect(throws: VPhoneGuestCallError.self) {
            try VPhoneHostAutomationProbe.rpc("m", params: [:], socketPath: socketPath(guest), timeout: 2)
        }
        #expect(error?.kind == .refused)
        #expect(error?.message == "nope")
        #expect(error?.detail?["code"] as? String == "E1")
    }

    @Test("rpc without guest_error, or without a socket, is a transport error")
    func rpcTransport() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        let none = #expect(throws: VPhoneGuestCallError.self) {
            try VPhoneHostAutomationProbe.rpc("m", params: [:], socketPath: socketPath(guest), timeout: 1)
        }
        #expect(none?.kind == .transport)
        #expect(none?.message == "no answer from vphone.sock")

        let socket = FakeControlSocket(bundle: guest.bundle, reply: "{\"ok\":false,\"error\":\"guest not connected\"}")
        defer { socket.stop() }
        waitForSocket(guest)
        let refused = #expect(throws: VPhoneGuestCallError.self) {
            try VPhoneHostAutomationProbe.rpc("m", params: [:], socketPath: socketPath(guest), timeout: 2)
        }
        #expect(refused?.kind == .transport)
        #expect(refused?.message == "guest not connected")
    }

    @Test("send delivers the request as one JSON line")
    func sendDeliversRequest() throws {
        let guest = try FakeGuestVM()
        let socket = FakeControlSocket(bundle: guest.bundle)
        defer { socket.stop(); guest.cleanUp() }
        waitForSocket(guest)
        let reply = VPhoneHostAutomationProbe.send(["t": "ping", "n": 7], socketPath: socketPath(guest))
        #expect(reply?["ok"] as? Bool == true)
        let request = try #require(socket.requests.first)
        #expect(request.last == 0x0A)
        let json = try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any]
        #expect(json?["t"] as? String == "ping")
        #expect(json?["n"] as? Int == 7)
    }
}
