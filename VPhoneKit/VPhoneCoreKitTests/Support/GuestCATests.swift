import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

// MARK: - Guest CA host-side core (TASK-010 / REQ-008)

/// Exercises `VPhoneGuestCA` without the non-linkable command binary: host-side
/// rejects open no socket and raise `UsageError`; a tiny in-test Unix-socket
/// stub (the one-line request / one-line JSON reply protocol
/// `VPhoneHostAutomationProbe.send` speaks) drives the install/remove/list
/// transport, reply validation, and stdout formatting. The trust domain is
/// operator-selectable (user by default, `admin: true` for admin): the install
/// reply carries a required `domain` (`user`|`admin`), remove/list carry no
/// domain, and `ca list` renders `sha256 TAB subject`.
struct GuestCATests {
    // MARK: Helpers

    private let sha256A = String(repeating: "a", count: 64)
    private let sha256B = String(repeating: "b", count: 64)

    /// A library root short enough that `<root>/<name>/vphone.sock` fits
    /// `sun_path` (the stub binds it raw).
    private func makeLibrary() throws -> (library: VPhoneLibrary, root: URL, socketPath: String) {
        let root = URL(fileURLWithPath: "/tmp/caT\(UUID().uuidString.prefix(8))", isDirectory: true)
        let vmDir = root.appendingPathComponent("vm", isDirectory: true)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 8,
            memorySize: 8 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "AVPBooter.vresearch1.bin", avpSEPBooter: "AVPSEPBooter.vresearch1.bin"),
        )
        try manifest.write(to: vmDir.appendingPathComponent("config.plist"))
        let socketPath = vmDir.appendingPathComponent("vphone.sock").path
        #expect(socketPath.utf8.count < VPhoneUnixSocket.maximumPathLength)
        return (VPhoneLibrary(root: root), root, socketPath)
    }

    private func writePEM(_ contents: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString.prefix(8)).pem").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func validPEM(certificates: Int = 1) -> String {
        let block = "-----BEGIN CERTIFICATE-----\nMIIBfakebase64==\n-----END CERTIFICATE-----\n"
        return String(repeating: block, count: certificates)
    }

    /// A faithful stand-in for `VPhoneHostAutomationProbe.rpc`: it speaks the
    /// same wire protocol to `socketPath` and maps the reply to the same
    /// `VPhoneGuestCallError` kinds. Production injects the real probe; tests
    /// inject this so the stub server is exercised end to end.
    private func controlSocketRPC(
        _ method: String, _ params: [String: Any], _ socketPath: String, _ timeout: Int,
    ) throws -> [String: Any] {
        guard case let .success(fd) = VPhoneUnixSocket.connect(to: socketPath) else {
            throw VPhoneGuestCallError(kind: .transport, message: "no answer from vphone.sock")
        }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        _ = withUnsafePointer(to: &tv) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        let request: [String: Any] = ["t": "rpc", "method": method, "params": params, "screen": false]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while reply.count < (64 << 20) {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else {
                throw VPhoneGuestCallError(kind: .transport, message: "no answer from vphone.sock")
            }
            reply.append(contentsOf: buffer.prefix(count))
            guard
                let newline = reply.firstIndex(of: 0x0A),
                let json = try? JSONSerialization.jsonObject(with: Data(reply[..<newline])) as? [String: Any]
            else { continue }
            if json["ok"] as? Bool == true {
                return json["result"] as? [String: Any] ?? [:]
            }
            let message = json["error"] as? String ?? "refused"
            if let detail = json["guest_error"] as? [String: Any] {
                throw VPhoneGuestCallError(kind: .refused, message: message, detail: detail)
            }
            throw VPhoneGuestCallError(kind: .transport, message: message)
        }
        throw VPhoneGuestCallError(kind: .transport, message: "no answer from vphone.sock")
    }

    /// An rpc that must never be called: proves a reject opened no socket.
    private func forbiddenRPC(
        _: String, _: [String: Any], _: String, _: Int,
    ) throws -> [String: Any] {
        Issue.record("the RPC transport must not be invoked for a host-side reject")
        return [:]
    }

    // MARK: Host-side rejects (exit 2, no socket)

    @Test func `unknown VM name is a usage error and opens no socket`() throws {
        let root = URL(fileURLWithPath: "/tmp/caT\(UUID().uuidString.prefix(8))", isDirectory: true)
        let library = VPhoneLibrary(root: root)
        #expect(throws: VPhoneGuestCA.UsageError.self) {
            try VPhoneGuestCA.list(vmName: "ghost", library: library, rpc: forbiddenRPC)
        }
    }

    @Test func `a missing PEM file is a usage error and opens no socket`() throws {
        let fixture = try makeLibrary()
        #expect {
            try VPhoneGuestCA.install(
                vmName: "vm", library: fixture.library, pemPath: "/nope.pem", rpc: forbiddenRPC,
            )
        } throws: { ($0 as? VPhoneGuestCA.UsageError)?.description.contains("/nope.pem") == true }
    }

    @Test func `a malformed sha256 is a usage error and opens no socket`() throws {
        let fixture = try makeLibrary()
        #expect {
            try VPhoneGuestCA.remove(vmName: "vm", library: fixture.library, sha256: "nothex", rpc: forbiddenRPC)
        } throws: { ($0 as? VPhoneGuestCA.UsageError)?.description.contains("64 hex") == true }
    }

    @Test func `a 40-char sha1 is rejected now that anchors are keyed by sha256`() throws {
        let fixture = try makeLibrary()
        #expect {
            try VPhoneGuestCA.remove(
                vmName: "vm", library: fixture.library, sha256: String(repeating: "a", count: 40), rpc: forbiddenRPC,
            )
        } throws: { ($0 as? VPhoneGuestCA.UsageError)?.description.contains("64 hex") == true }
    }

    @Test func `a PEM one byte over 64 KiB is a usage error naming the limit`() throws {
        let fixture = try makeLibrary()
        let filler = String(repeating: "A", count: VPhoneGuestCA.maximumPEMBytes + 1 - validPEM().utf8.count)
        let pem = try writePEM(validPEM() + filler)
        #expect(try Data(contentsOf: URL(fileURLWithPath: pem)).count == VPhoneGuestCA.maximumPEMBytes + 1)
        #expect {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: forbiddenRPC)
        } throws: { ($0 as? VPhoneGuestCA.UsageError)?.description.contains("64 KiB") == true }
    }

    @Test func `a zero-cert PEM is a usage error and opens no socket`() throws {
        let fixture = try makeLibrary()
        let pem = try writePEM("not a certificate at all\n")
        #expect {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: forbiddenRPC)
        } throws: { ($0 as? VPhoneGuestCA.UsageError)?.description.contains("no certificate") == true }
    }

    @Test func `a two-cert bundle is a usage error naming the single-cert limit`() throws {
        let fixture = try makeLibrary()
        let pem = try writePEM(validPEM(certificates: 2))
        #expect {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: forbiddenRPC)
        } throws: { ($0 as? VPhoneGuestCA.UsageError)?.description.contains("holds 2 certificates") == true }
    }

    @Test func `a CERTIFICATE block with no matching END is a usage error`() throws {
        let fixture = try makeLibrary()
        let pem = try writePEM("-----BEGIN CERTIFICATE-----\nMIIBfake==\n")
        #expect {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: forbiddenRPC)
        } throws: { ($0 as? VPhoneGuestCA.UsageError)?.description.contains("no matching") == true }
    }

    // MARK: VM not running (exit 1)

    @Test func `no control socket means the VM is not running`() throws {
        let fixture = try makeLibrary() // no stub bound at the socket path
        let pem = try writePEM(validPEM())
        #expect {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: forbiddenRPC)
        } throws: { ($0 as? VPhoneGuestCA.RuntimeError)?.description.contains("vm launch") == true }
    }

    // MARK: Stub-driven transport

    @Test func `install sends ca_install with the cert block and force true`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["sha256": sha256A, "subject": "x", "domain": "user"]],
        )
        defer { server.stop() }
        let pemText = validPEM()
        let pem = try writePEM(pemText)

        try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: controlSocketRPC)

        let request = try #require(server.lastRequest())
        #expect(request["method"] as? String == "security.ca_install")
        let params = try #require(request["params"] as? [String: Any])
        let sent = try #require(params["pem"] as? String)
        #expect(sent.contains("-----BEGIN CERTIFICATE-----") && sent.contains("-----END CERTIFICATE-----"))
        #expect(sent.contains("MIIBfakebase64=="))
        #expect(params["admin"] == nil, "default (user) install sends no admin key")
        #expect(params["force"] as? Bool == true)
    }

    // MUTATION: sending `admin` unconditionally (or never) breaks one of these two tests.
    @Test func `install with admin sends admin true`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["sha256": sha256A, "subject": "x", "domain": "admin"]],
        )
        defer { server.stop() }
        let pem = try writePEM(validPEM())

        try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, admin: true, rpc: controlSocketRPC)

        let params = try #require(server.lastRequest()?["params"] as? [String: Any])
        #expect(params["admin"] as? Bool == true)
        #expect(params["force"] as? Bool == true)
    }

    @Test func `install sends only the CERTIFICATE block, never a bundled PRIVATE KEY`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["sha256": sha256A, "subject": "x", "domain": "user"]],
        )
        defer { server.stop() }
        let combined = "-----BEGIN PRIVATE KEY-----\nSECRETKEYMATERIAL==\n-----END PRIVATE KEY-----\n"
            + "-----BEGIN CERTIFICATE-----\nMIIBcert==\n-----END CERTIFICATE-----\n"
        let pem = try writePEM(combined)

        try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: controlSocketRPC)

        let sent = try #require((server.lastRequest()?["params"] as? [String: Any])?["pem"] as? String)
        #expect(sent.contains("BEGIN CERTIFICATE"))
        #expect(!sent.contains("PRIVATE KEY"), "the private key must never be shipped to the guest")
        #expect(!sent.contains("SECRETKEYMATERIAL"))
    }

    @Test func `remove sends ca_remove with a lowercased sha256 and force true`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["removed": true, "sha256": sha256A]],
        )
        defer { server.stop() }
        let upper = String(repeating: "AB", count: 32) // 64 hex, uppercase

        try VPhoneGuestCA.remove(vmName: "vm", library: fixture.library, sha256: upper, rpc: controlSocketRPC)

        let request = try #require(server.lastRequest())
        #expect(request["method"] as? String == "security.ca_remove")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["sha256"] as? String == upper.lowercased())
        #expect(params["force"] as? Bool == true)
    }

    @Test func `list sends empty params`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(path: fixture.socketPath, reply: ["ok": true, "result": ["anchors": []]])
        defer { server.stop() }

        _ = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)

        let request = try #require(server.lastRequest())
        #expect(request["method"] as? String == "security.ca_list")
        #expect((request["params"] as? [String: Any])?.isEmpty == true)
    }

    @Test func `list renders sha256 TAB subject per anchor`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["anchors": [["sha256": sha256A, "subject": "Acme Root CA"]]]],
        )
        defer { server.stop() }

        let output = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        #expect(output == "\(sha256A)\tAcme Root CA\n")
    }

    @Test func `list renders an empty subject`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["anchors": [["sha256": sha256B, "subject": ""]]]],
        )
        defer { server.stop() }

        let output = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        #expect(output == "\(sha256B)\t\n")
    }

    @Test func `list sorts anchors bytewise on the lowercase hex sha256`() throws {
        let fixture = try makeLibrary()
        let high = String(repeating: "f", count: 64)
        let low = String(repeating: "0", count: 64)
        let server = try StubSocketServer(path: fixture.socketPath, reply: ["ok": true, "result": ["anchors": [
            ["sha256": high, "subject": "high"],
            ["sha256": low, "subject": "low"],
        ]]])
        defer { server.stop() }

        let output = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        #expect(output == "\(low)\tlow\n\(high)\thigh\n")
    }

    @Test func `list host-sanitizes control characters in the subject`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["anchors": [["sha256": sha256A, "subject": "a\tb\u{7f}c"]]]],
        )
        defer { server.stop() }

        let output = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        #expect(output == "\(sha256A)\ta b c\n", "TAB and DEL in the subject each become a space")
    }

    @Test func `list with empty anchors is empty stdout`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(path: fixture.socketPath, reply: ["ok": true, "result": ["anchors": []]])
        defer { server.stop() }

        let output = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        #expect(output.isEmpty)
    }

    // MARK: Malformed ca_list replies (exit 1, no stdout)

    @Test func `a reply with no anchors array is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(path: fixture.socketPath, reply: ["ok": true, "result": ["other": 1]])
        defer { server.stop() }
        #expect(throws: VPhoneGuestCA.RuntimeError.self) {
            _ = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        }
    }

    @Test func `a row missing sha256 is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["anchors": [["subject": "x"]]]],
        )
        defer { server.stop() }
        #expect(throws: VPhoneGuestCA.RuntimeError.self) {
            _ = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        }
    }

    @Test func `a row with a non-hex sha256 is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["anchors": [["sha256": String(repeating: "z", count: 64), "subject": "x"]]]],
        )
        defer { server.stop() }
        #expect(throws: VPhoneGuestCA.RuntimeError.self) {
            _ = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        }
    }

    @Test func `a row missing subject is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["anchors": [["sha256": sha256A]]]],
        )
        defer { server.stop() }
        #expect {
            _ = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        } throws: { ($0 as? VPhoneGuestCA.RuntimeError)?.description.contains("malformed security.ca_list reply") == true }
    }

    @Test func `a row with a non-string subject is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["anchors": [["sha256": sha256A, "subject": 5]]]],
        )
        defer { server.stop() }
        #expect {
            _ = try VPhoneGuestCA.list(vmName: "vm", library: fixture.library, rpc: controlSocketRPC)
        } throws: { ($0 as? VPhoneGuestCA.RuntimeError)?.description.contains("malformed security.ca_list reply") == true }
    }

    // MARK: Malformed ca_install / ca_remove replies (exit 1)

    @Test func `an install reply missing subject is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["sha256": sha256A]],
        )
        defer { server.stop() }
        let pem = try writePEM(validPEM())
        #expect(throws: VPhoneGuestCA.RuntimeError.self) {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: controlSocketRPC)
        }
    }

    @Test func `an install reply missing domain is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["sha256": sha256A, "subject": "x"]],
        )
        defer { server.stop() }
        let pem = try writePEM(validPEM())
        #expect {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, rpc: controlSocketRPC)
        } throws: { ($0 as? VPhoneGuestCA.RuntimeError)?.description.contains("malformed security.ca_install reply") == true }
    }

    @Test(arguments: ["user", "admin"])
    func `an install reply with a valid domain is accepted`(domain: String) throws {
        try VPhoneGuestCA.validateInstallReply(["sha256": sha256A, "subject": "x", "domain": domain])
    }

    @Test func `a remove reply with removed not exactly true is malformed`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(
            path: fixture.socketPath,
            reply: ["ok": true, "result": ["removed": false, "sha256": sha256A]],
        )
        defer { server.stop() }
        #expect(throws: VPhoneGuestCA.RuntimeError.self) {
            try VPhoneGuestCA.remove(vmName: "vm", library: fixture.library, sha256: sha256A, rpc: controlSocketRPC)
        }
    }

    // MARK: Success + refusal replies

    @Test(arguments: [
        #"{"sha256":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz","subject":"x","domain":"user"}"#,
        #"{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","subject":5,"domain":"user"}"#,
        #"{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","subject":"x"}"#,
        #"{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","subject":"x","domain":"system"}"#,
        #"{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","subject":"x","domain":5}"#,
    ])
    func `an install reply with a bad field is malformed`(json: String) throws {
        let reply = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect {
            try VPhoneGuestCA.validateInstallReply(reply)
        } throws: { ($0 as? VPhoneGuestCA.RuntimeError)?.description.contains("malformed security.ca_install reply") == true }
    }

    @Test(arguments: [
        #"{"removed":true,"sha256":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}"#,
        #"{"removed":false,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
        #"{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
        #"{"removed":"true","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
    ])
    func `a remove reply with a bad field is malformed`(json: String) throws {
        let reply = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect {
            try VPhoneGuestCA.validateRemoveReply(reply)
        } throws: { ($0 as? VPhoneGuestCA.RuntimeError)?.description.contains("malformed security.ca_remove reply") == true }
    }

    @Test func `a refusal surfaces the guest message as a runtime error`() throws {
        let message = "anchor not found: \(String(repeating: "a", count: 64)); check with ca list"
        let fixture = try makeLibrary()
        let server = try StubSocketServer(path: fixture.socketPath, reply: ["ok": false, "error": message, "guest_error": ["message": message, "code": "ca_error"]])
        defer { server.stop() }
        #expect {
            try VPhoneGuestCA.remove(vmName: "vm", library: fixture.library, sha256: String(repeating: "a", count: 64), rpc: controlSocketRPC)
        } throws: { ($0 as? VPhoneGuestCA.RuntimeError)?.description == message }
    }

    // MARK: Timeout (scaled, not a real 30s wait)

    @Test func `install times out when the stub never replies`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(path: fixture.socketPath, reply: nil) // accept, never reply
        defer { server.stop() }
        let pem = try writePEM(validPEM())
        #expect {
            try VPhoneGuestCA.install(vmName: "vm", library: fixture.library, pemPath: pem, timeout: 1, rpc: controlSocketRPC)
        } throws: {
            let text = ($0 as? VPhoneGuestCA.RuntimeError)?.description ?? ""
            return text.contains("timed out") && text.contains("unknown") && text.contains("ca list")
        }
    }

    @Test func `remove timeout points at ca list`() throws {
        let fixture = try makeLibrary()
        let server = try StubSocketServer(path: fixture.socketPath, reply: nil)
        defer { server.stop() }
        #expect {
            try VPhoneGuestCA.remove(vmName: "vm", library: fixture.library, sha256: String(repeating: "a", count: 64), timeout: 1, rpc: controlSocketRPC)
        } throws: {
            let text = ($0 as? VPhoneGuestCA.RuntimeError)?.description ?? ""
            return text.contains("timed out") && text.contains("unknown") && text.contains("ca list")
        }
    }
}

// MARK: - Stub control socket

/// Listens on a Unix socket, serving one canned JSON reply line per request
/// line — the protocol `VPhoneHostAutomationProbe.send` speaks. It loop-accepts
/// so it tolerates the core's reachability pre-check (a connection that is
/// opened and immediately closed with no request). `reply: nil` accepts the
/// request but never answers, to drive the client timeout.
private final class StubSocketServer {
    let path: String
    private let server: Int32
    private let lock = NSLock()
    private var requests: [[String: Any]] = []
    private let replyLine: Data?

    init(path: String, reply: [String: Any]?) throws {
        self.path = path
        unlink(path)
        if let reply {
            var line = try JSONSerialization.data(withJSONObject: reply)
            line.append(0x0A)
            replyLine = line
        } else {
            replyLine = nil
        }
        server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(server)
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }
        guard listen(server, 8) == 0 else {
            close(server)
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }
        let listener = server
        let replyLine = replyLine
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                var line: Data?
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                    if let newline = data.firstIndex(of: 0x0A) {
                        line = Data(data[..<newline])
                        break
                    }
                }
                if let line, !line.isEmpty,
                   let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                {
                    self?.record(json)
                    if let replyLine {
                        _ = replyLine.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
                    } else {
                        // Accept but never reply: hold briefly so the client's
                        // own (scaled) read timeout fires first.
                        Thread.sleep(forTimeInterval: 5)
                    }
                }
                close(client)
            }
        }
    }

    private func record(_ json: [String: Any]) {
        lock.lock()
        requests.append(json)
        lock.unlock()
    }

    func lastRequest() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    func stop() {
        close(server)
        unlink(path)
    }
}
