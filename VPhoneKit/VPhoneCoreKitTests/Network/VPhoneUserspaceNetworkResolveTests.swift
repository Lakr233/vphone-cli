import Foundation
import Testing
@testable import VPhoneCoreKit

/// Resolve-at-start wiring for the SOCKS upstream (TASK-003).
///
/// These build a real `VPhoneUserspaceNetwork` over a socket pair — no VM — and
/// inject a stub resolver so the no-IPv4, multi-address, and blocking cases run
/// without a real DNS lookup or a real 5 s deadline. Resolution and `${…}` token
/// substitution are synchronous: `start()` resolves the forwarder's
/// upstream, which is its final `.resolved`/`.failed` (never nil while `intercept` is
/// set, never a pending state). The fail-closed and proxy-routing decisions that
/// upstream then drives are covered at the socket level in
/// `VPhoneTCPForwarderTests`.
struct VPhoneUserspaceNetworkResolveTests {
    /// A lock-guarded invocation counter, since the resolver runs off-queue.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A lock-guarded line collector for the single resolution-failure log line.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private func configuration(
        intercept: VPhoneInterceptEndpoint?,
        vmName: String = "lab",
        vmID: String? = nil,
    ) -> VPhoneUserspaceNetworkConfiguration {
        var configuration = VPhoneUserspaceNetworkConfiguration.default
        configuration.intercept = intercept
        configuration.vmName = vmName
        configuration.vmID = vmID
        return configuration
    }

    private func network(
        intercept: VPhoneInterceptEndpoint?,
        vmName: String = "lab",
        vmID: String? = nil,
        resolveDeadline: TimeInterval = 2,
        resolutionLog: (@Sendable (String) -> Void)? = nil,
        resolveProxy: @escaping @Sendable (String) -> [VPhoneIPv4Address] = { _ in [] },
    ) throws -> VPhoneUserspaceNetwork {
        try VPhoneUserspaceNetwork(
            configuration: configuration(intercept: intercept, vmName: vmName, vmID: vmID),
            resolveProxy: resolveProxy,
            resolveDeadline: resolveDeadline,
            resolutionLog: resolutionLog,
        )
    }

    @Test func `a resolved endpoint is handed to the forwarder exactly once`() throws {
        let calls = Counter()
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080)
        let network = try network(intercept: endpoint, resolveProxy: { host in
            calls.increment()
            #expect(host == "proxy.test")
            return [VPhoneIPv4Address(10, 0, 0, 9)]
        })
        defer { network.stop() }

        #expect(network.resolveUpstream(endpoint) == .resolved(VPhoneIPv4Address(10, 0, 0, 9), 1080, nil))
        // Synchronous resolve-at-start: one pick, no re-resolution.
        #expect(calls.value == 1)
    }

    @Test func `a username spec resolves credentials alongside the address`() throws {
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080, user: "alice", password: "s3cret")
        let network = try network(intercept: endpoint, resolveProxy: { _ in [VPhoneIPv4Address(10, 0, 0, 9)] })
        defer { network.stop() }

        #expect(network.resolveUpstream(endpoint) == .resolved(
            VPhoneIPv4Address(10, 0, 0, 9), 1080,
            VPhoneSOCKSCredentials(username: "alice", password: "s3cret")))
    }

    @Test func `no intercept leaves the upstream nil`() throws {
        let calls = Counter()
        let network = try network(intercept: nil, resolveProxy: { _ in calls.increment(); return [] })
        network.start()
        defer { network.stop() }
        // No resolution is kicked off, so the forwarder stays on direct-connect.
        #expect(calls.value == 0)
    }

    @Test func `an unresolvable host fails closed, not nil`() throws {
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080)
        let network = try network(intercept: endpoint, resolveProxy: { _ in [] })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .failed)
    }

    @Test func `an IPv6-only result fails closed`() throws {
        // The resolver is IPv4-only; an IPv6-only host surfaces as no IPv4.
        let endpoint = VPhoneInterceptEndpoint(host: "v6only.test", port: 1080)
        let network = try network(intercept: endpoint, resolveProxy: { _ in [] })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .failed)
    }

    @Test func `a bracketed IPv6 literal fails closed`() throws {
        // `[::1]` parses but the production resolver yields no IPv4 for it.
        let endpoint = VPhoneInterceptEndpoint(host: "::1", port: 1080)
        let network = try network(intercept: endpoint, resolveProxy: { VPhoneHostResolver.resolveIPv4($0) })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .failed)
    }

    @Test func `a missing env token fails closed, not nil`() throws {
        let name = "VPHONE_TEST_MISSING_\(UUID().uuidString.prefix(8))"
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080, user: "${env:\(name)}")
        let network = try network(intercept: endpoint, resolveProxy: { _ in [VPhoneIPv4Address(10, 0, 0, 9)] })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .failed)
    }

    @Test func `a never-returning resolver fails closed at the deadline`() throws {
        let gate = DispatchSemaphore(value: 0)
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080)
        let network = try network(intercept: endpoint, resolveDeadline: 0.3, resolveProxy: { _ in
            gate.wait() // never returns until the test releases it
            return []
        })
        let began = Date()
        let upstream = network.resolveUpstream(endpoint)
        let elapsed = Date().timeIntervalSince(began)
        defer { network.stop(); gate.signal() }

        // Start returns within the deadline plus tolerance, failing closed.
        #expect(elapsed < 1.5)
        #expect(upstream == .failed)
    }

    @Test func `a resolver returning just inside the deadline resolves`() throws {
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080)
        let network = try network(intercept: endpoint, resolveDeadline: 5.0, resolveProxy: { _ in
            usleep(80000) // well inside the 5 s deadline
            return [VPhoneIPv4Address(10, 0, 0, 5)]
        })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .resolved(VPhoneIPv4Address(10, 0, 0, 5), 1080, nil))
    }

    @Test func `a multi-address host uses the first address`() throws {
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080)
        let network = try network(intercept: endpoint, resolveProxy: { _ in
            [VPhoneIPv4Address(10, 0, 0, 1), VPhoneIPv4Address(10, 0, 0, 2), VPhoneIPv4Address(10, 0, 0, 3)]
        })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .resolved(VPhoneIPv4Address(10, 0, 0, 1), 1080, nil))
    }

    @Test func `vm name, vm id, and env tokens substitute into credentials`() throws {
        let name = "VPHONE_TEST_PW_\(UUID().uuidString.prefix(8))"
        setenv(name, "envpass", 1)
        defer { unsetenv(name) }
        let endpoint = VPhoneInterceptEndpoint(
            host: "proxy.test", port: 1080, user: "${vm.name}-${vm.id}", password: "${env:\(name)}")
        let network = try network(intercept: endpoint, vmName: "lab7", vmID: "UDID123", resolveProxy: { _ in
            [VPhoneIPv4Address(10, 0, 0, 9)]
        })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .resolved(
            VPhoneIPv4Address(10, 0, 0, 9), 1080,
            VPhoneSOCKSCredentials(username: "lab7-UDID123", password: "envpass")))
    }

    @Test func `a vm id token with no predicted UDID fails closed`() throws {
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080, user: "${vm.id}")
        let network = try network(intercept: endpoint, vmID: nil, resolveProxy: { _ in [VPhoneIPv4Address(10, 0, 0, 9)] })
        defer { network.stop() }
        #expect(network.resolveUpstream(endpoint) == .failed)
    }

    @Test func `a failure logs exactly one line with endpoint, cause, and remedy`() throws {
        let lines = Lines()
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080)
        let network = try network(intercept: endpoint, resolutionLog: { lines.append($0) }, resolveProxy: { _ in [] })
        defer { network.stop() }

        #expect(network.resolveUpstream(endpoint) == .failed)
        let all = lines.all
        #expect(all.count == 1)
        let line = all.first ?? ""
        #expect(line.contains("proxy.test:1080"))
        #expect(line.contains("host"))
        #expect(line.contains("fix it and restart the VM; guest TCP is reset until then"))
    }

    @Test func `an empty substituted username fails closed with the credentials cause`() throws {
        let name = "VPHONE_TEST_EMPTY_\(UUID().uuidString.prefix(8))"
        setenv(name, "", 1)
        defer { unsetenv(name) }
        let lines = Lines()
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080, user: "${env:\(name)}")
        let network = try network(intercept: endpoint, resolutionLog: { lines.append($0) }, resolveProxy: { _ in
            [VPhoneIPv4Address(10, 0, 0, 9)]
        })
        defer { network.stop() }

        #expect(network.resolveUpstream(endpoint) == .failed)
        #expect(lines.all.count == 1)
        #expect((lines.all.first ?? "").contains("credentials"))
    }

    @Test func `an over-255-byte credential fails closed with the credentials cause`() throws {
        let name = "VPHONE_TEST_BIG_\(UUID().uuidString.prefix(8))"
        setenv(name, String(repeating: "a", count: 256), 1)
        defer { unsetenv(name) }
        let lines = Lines()
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080, user: "${env:\(name)}")
        let network = try network(intercept: endpoint, resolutionLog: { lines.append($0) }, resolveProxy: { _ in
            [VPhoneIPv4Address(10, 0, 0, 9)]
        })
        defer { network.stop() }

        #expect(network.resolveUpstream(endpoint) == .failed)
        #expect(lines.all.count == 1)
        #expect((lines.all.first ?? "").contains("credentials"))
    }

    @Test func `a 255-byte credential resolves`() throws {
        let name = "VPHONE_TEST_255_\(UUID().uuidString.prefix(8))"
        let value = String(repeating: "a", count: 255)
        setenv(name, value, 1)
        defer { unsetenv(name) }
        let endpoint = VPhoneInterceptEndpoint(host: "proxy.test", port: 1080, user: "${env:\(name)}")
        let network = try network(intercept: endpoint, resolveProxy: { _ in [VPhoneIPv4Address(10, 0, 0, 9)] })
        defer { network.stop() }

        #expect(network.resolveUpstream(endpoint) == .resolved(
            VPhoneIPv4Address(10, 0, 0, 9), 1080,
            VPhoneSOCKSCredentials(username: value, password: "")))
    }

    /// The production resolver is IPv4-only, so an IPv6 literal resolves to an
    /// empty list — which the network turns into `.failed`, never a direct
    /// connect — while an IPv4 literal resolves to itself.
    @Test func `the production resolver yields only IPv4 addresses`() throws {
        #expect(VPhoneHostResolver.resolveIPv4("127.0.0.1") == [VPhoneIPv4Address(127, 0, 0, 1)])
        #expect(VPhoneHostResolver.resolveIPv4("::1").isEmpty)
        #expect(VPhoneHostResolver.resolveIPv4("[::1]").isEmpty)
    }
}
