@testable import VPhoneCore
import Darwin
import Foundation
import Testing
import Virtualization

/// Covers the tunnel (`--network tunnel`) backend: mode plumbing, helper discovery,
/// socket-path limits, and the datagram socket the guest NIC hangs off.
///
/// The helper-dependent tests skip when `gvproxy` cannot be found, so they stay
/// meaningful on a developer machine (run `make net_helper`) without failing elsewhere.
///
/// Serialized on purpose: these tests spawn real helper processes and assert on the
/// contents of a shared socket directory, so running them concurrently would race
/// (the tests themselves stay milliseconds long).
@Suite(.serialized)
struct TunnelNetworkingTests {
    typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig

    // MARK: - Mode plumbing

    @Test func mergeAcceptsTunnelMode() throws {
        let out = try VPhoneNetworking.merge(into: .default, mode: .tunnel, bridgeInterface: nil)
        #expect(out.mode == .tunnel)
        #expect(out.bridgeInterface == nil)
    }

    @Test func mergeRejectsBridgeInterfaceOutsideBridgedMode() {
        #expect(throws: VPhoneNetworkingError.bridgeInterfaceWithoutBridgedMode) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .tunnel, bridgeInterface: "en0")
        }
    }

    @Test func tunnelModeCannotBeRealizedAsABareDevice() {
        #expect(throws: VPhoneNetworkingError.tunnelModeNeedsSession) {
            _ = try VPhoneNetworking.makeNetworkDevice(NetworkConfig(mode: .tunnel, macAddress: ""))
        }
    }

    @Test func sessionForModeWithoutHelperIsDeviceOnly() throws {
        let session = try VPhoneNetworking.makeNetworkSession(NetworkConfig(mode: .nat, macAddress: ""))
        #expect(session.mode == .nat)
        #expect(session.device?.attachment is VZNATNetworkDeviceAttachment)
        session.stop()
    }

    @Test func sessionForOffHasNoDevice() throws {
        let session = try VPhoneNetworking.makeNetworkSession(NetworkConfig(mode: .off, macAddress: ""))
        #expect(session.device == nil)
        session.stop()
    }

    @Test func networkConfigRoundTripsThroughPlist() throws {
        let config = NetworkConfig(mode: .tunnel, macAddress: "aa:bb:cc:dd:ee:ff")
        let data = try PropertyListEncoder().encode(config)
        let decoded = try PropertyListDecoder().decode(NetworkConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.mode.rawValue == "tunnel")
    }

    // MARK: - Helper resolution

    @Test func explicitHelperWins() {
        let echo = URL(fileURLWithPath: "/bin/echo")
        let found = VPhoneTunnelNetwork.resolveHelper(
            explicit: echo, environment: [:], executableDirectory: nil,
            resourceDirectory: nil, pathDirectories: [])
        #expect(found == echo)
    }

    @Test func helperIsLookedUpOnPATH() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = try makeExecutable(named: VPhoneTunnelNetwork.helperName, in: dir)

        let found = VPhoneTunnelNetwork.resolveHelper(
            explicit: nil, environment: [:], executableDirectory: nil,
            resourceDirectory: nil, pathDirectories: [dir.path])
        #expect(found?.path == helper.path)
    }

    @Test func environmentOverrideIsHonoured() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = try makeExecutable(named: VPhoneTunnelNetwork.helperName, in: dir)

        let found = VPhoneTunnelNetwork.resolveHelper(
            explicit: nil, environment: ["VPHONE_GVPROXY": helper.path],
            executableDirectory: nil, resourceDirectory: nil, pathDirectories: [])
        #expect(found?.path == helper.path)
    }

    @Test func missingHelperResolvesToNil() {
        let found = VPhoneTunnelNetwork.resolveHelper(
            explicit: nil, environment: ["PATH": "/nonexistent"], executableDirectory: nil,
            resourceDirectory: nil, pathDirectories: [])
        #expect(found == nil)
    }

    @Test func nonExecutableHelperIsRejected() {
        #expect(throws: VPhoneTunnelNetworkError.helperNotExecutable(path: "/etc/hosts")) {
            _ = try VPhoneTunnelNetwork.resolveHelperOrThrow(explicit: URL(fileURLWithPath: "/etc/hosts"))
        }
    }

    // MARK: - Arguments / paths

    @Test func helperArgumentsSelectTheVfkitTransport() {
        #expect(VPhoneTunnelNetwork.helperArguments(vfkitSocketPath: "/tmp/vp-gv-1.sock")
            == ["-listen-vfkit", "unixgram:///tmp/vp-gv-1.sock"])
        // gvproxy's default 2222 ssh forward makes concurrent helpers collide.
        #expect(VPhoneTunnelNetwork.helperArguments(vfkitSocketPath: "/tmp/vp-gv-1.sock", sshPort: 21122)
            == ["-listen-vfkit", "unixgram:///tmp/vp-gv-1.sock", "-ssh-port", "21122"])
    }

    @Test func helperArgumentsCarryDiagnostics() {
        #expect(VPhoneTunnelNetwork.helperArguments(
            vfkitSocketPath: "/tmp/vp-gv-1.sock", debug: true, pcapPath: "/tmp/vp-net.pcap")
            == ["-listen-vfkit", "unixgram:///tmp/vp-gv-1.sock", "-debug", "-pcap", "/tmp/vp-net.pcap"])
        // An empty capture path is "not asked for", not `-pcap ""`.
        #expect(VPhoneTunnelNetwork.helperArguments(vfkitSocketPath: "/tmp/vp-gv-1.sock", pcapPath: "")
            == ["-listen-vfkit", "unixgram:///tmp/vp-gv-1.sock"])
    }

    /// Diagnostics have to be opt-in: `-debug` logs every frame and a capture grows with
    /// traffic, so neither may switch itself on.
    @Test func diagnosticsAreOffUnlessTheEnvironmentAsks() {
        let plain = VPhoneTunnelNetwork.Options.fromEnvironment(environment: [:])
        #expect(!plain.debug)
        #expect(plain.pcapURL == nil)

        let asked = VPhoneTunnelNetwork.Options.fromEnvironment(environment: [
            "VPHONE_NET_DEBUG": "1",
            "VPHONE_NET_PCAP": "/tmp/vp-net.pcap",
        ])
        #expect(asked.debug)
        #expect(asked.pcapURL?.path == "/tmp/vp-net.pcap")

        #expect(!VPhoneTunnelNetwork.Options.fromEnvironment(environment: ["VPHONE_NET_DEBUG": "yes"]).debug)
        #expect(VPhoneTunnelNetwork.Options.fromEnvironment(environment: ["VPHONE_NET_PCAP": ""]).pcapURL == nil)
    }

    @Test func freePortFallsInTheRangeTheHelperAccepts() throws {
        let port = try #require(VPhoneTunnelNetwork.pickFreePort())
        #expect((1024 ... 65535).contains(port))
    }

    /// Regression: the helper's default `-ssh-port 2222` made a second instance exit
    /// immediately ("bind: address already in use"), which also broke two VMs at once.
    @Test func twoNetworksCanRunAtTheSameTime() throws {
        guard let helper = VPhoneTunnelNetwork.resolveHelper() else { return }
        guard let dir = socketDirectory() else { return }

        let first = VPhoneTunnelNetwork(options: .init(
            helperURL: helper, logFileURL: helperLogURL(),
            socketDirectory: URL(fileURLWithPath: dir), readinessTimeout: 5))
        let second = VPhoneTunnelNetwork(options: .init(
            helperURL: helper, logFileURL: helperLogURL(),
            socketDirectory: URL(fileURLWithPath: dir), readinessTimeout: 5))
        defer { first.stop(); second.stop() }

        _ = try first.start()
        _ = try second.start()
    }

    @Test func socketPathLimitMatchesSunPath() {
        #expect(VPhoneTunnelNetwork.isSocketPathUsable(String(repeating: "a", count: 103)))
        #expect(!VPhoneTunnelNetwork.isSocketPathUsable(String(repeating: "a", count: 104)))
    }

    @Test func socketDirectoryDefaultsToTmp() {
        #expect(VPhoneTunnelNetwork.defaultSocketDirectory(environment: [:]).path == "/tmp")
        let override = VPhoneTunnelNetwork.defaultSocketDirectory(
            environment: ["VPHONE_NET_SOCKET_DIR": "/short"])
        #expect(override.path == "/short")
    }

    // MARK: - Datagram socket

    @Test func datagramSocketRoundTripsAFrame() throws {
        guard let dir = socketDirectory() else { return }

        let remotePath = dir + "/vp-test-remote-\(getpid()).sock"
        let localPath = dir + "/vp-test-local-\(getpid()).sock"
        unlink(remotePath)
        unlink(localPath)

        let listener = socket(AF_UNIX, SOCK_DGRAM, 0)
        try #require(listener >= 0)
        defer { close(listener); unlink(remotePath); unlink(localPath) }
        try #require(bindUnix(listener, remotePath) == 0)

        let fd = try VPhoneTunnelNetwork.connectDatagramSocket(localPath: localPath, remotePath: remotePath)
        defer { close(fd) }
        // bind() is what lets gvproxy address replies back to us.
        #expect(FileManager.default.fileExists(atPath: localPath))

        var payload = [UInt8]("frame".utf8)
        #expect(write(fd, &payload, payload.count) == payload.count)

        var buffer = [UInt8](repeating: 0, count: 64)
        let received = recv(listener, &buffer, buffer.count, 0)
        #expect(received == payload.count)
        #expect(String(decoding: buffer[0 ..< max(received, 0)], as: UTF8.self) == "frame")
    }

    @Test func secondStartOnTheSameInstanceIsRejected() throws {
        guard let helper = VPhoneTunnelNetwork.resolveHelper() else { return }
        guard let dir = socketDirectory() else { return }

        let network = VPhoneTunnelNetwork(options: .init(
            helperURL: helper, logFileURL: helperLogURL(),
            socketDirectory: URL(fileURLWithPath: dir), readinessTimeout: 5))
        _ = try network.start()
        defer { network.stop() }

        #expect(throws: VPhoneTunnelNetworkError.alreadyStarted) { _ = try network.start() }
    }

    @Test func helperIsStartedAndTornDown() throws {
        guard let helper = VPhoneTunnelNetwork.resolveHelper() else { return }
        guard let dir = socketDirectory() else { return }

        let network = VPhoneTunnelNetwork(options: .init(
            helperURL: helper, logFileURL: helperLogURL(),
            socketDirectory: URL(fileURLWithPath: dir), readinessTimeout: 5))
        let attachment = try network.start()
        #expect(attachment is VZFileHandleNetworkDeviceAttachment)

        network.stop()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasPrefix("vp-gv-") || $0.hasPrefix("vp-cl-") } ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: - Test helpers

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-net-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// `/tmp` keeps the path inside `sun_path`; overridable for sandboxed runs.
    /// Returns nil when the host refuses to bind a unix socket there.
    private func socketDirectory() -> String? {
        let candidate = ProcessInfo.processInfo.environment["VPHONE_NET_SOCKET_DIR"] ?? "/tmp"
        try? FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true)
        return canBindUnixSocket(in: candidate) ? candidate : nil
    }

    /// Distinct log per test, so a failed start reports the helper's own output.
    private func helperLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-net-helper-\(UUID().uuidString).log")
    }

    private func canBindUnixSocket(in directory: String) -> Bool {
        let probe = directory + "/vp-probe-\(getpid())-\(UInt32.random(in: 0 ..< .max)).sock"
        guard VPhoneTunnelNetwork.isSocketPathUsable(probe) else { return false }
        unlink(probe)
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd); unlink(probe) }
        return bindUnix(fd, probe) == 0
    }

    private func bindUnix(_ fd: Int32, _ path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        return withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
