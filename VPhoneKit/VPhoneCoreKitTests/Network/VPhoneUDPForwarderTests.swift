import Foundation
import Testing
@testable import VPhoneCoreKit

/// QUIC blocking in the UDP forwarder (TASK-005).
///
/// `blockQUIC` drops guest UDP to port 443 so a QUIC app falls back to the
/// interceptable TCP path; everything else is forwarded untouched. A dropped
/// datagram opens no session; a forwarded one does, and really reaches the
/// destination. The last test drives the manifest → configuration → forwarder
/// wiring so the flag set on a tunnel manifest actually blocks QUIC.
struct VPhoneUDPForwarderTests {
    private let guest = VPhoneIPv4Address(192, 168, 127, 3)
    private let guestMAC = VPhoneMACAddress([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])

    private func flow(to port: UInt16, address: VPhoneIPv4Address = VPhoneIPv4Address(127, 0, 0, 1)) -> VPhoneUDPFlow {
        VPhoneUDPFlow(
            sourceAddress: guest,
            sourcePort: 40000,
            destinationAddress: address,
            destinationPort: port,
            guestHardware: guestMAC,
        )
    }

    /// Build a started forwarder, feed one datagram, return its session count.
    private func sessionCountAfterSend(
        to port: UInt16,
        blockQUIC: Bool,
        address: VPhoneIPv4Address = VPhoneIPv4Address(127, 0, 0, 1),
    ) -> Int {
        let queue = DispatchQueue(label: "udp.test")
        let forwarder = VPhoneUDPForwarder(
            configuration: .default,
            queue: queue,
            blockQUIC: blockQUIC,
        ) { _, _ in }
        queue.sync { forwarder.start() }
        defer { queue.sync { forwarder.stop() } }
        queue.sync { forwarder.send([0x01, 0x02, 0x03], for: flow(to: port, address: address)) }
        return forwarder.sessionCount
    }

    @Test func `UDP to port 443 is dropped when blockQUIC is set`() {
        #expect(sessionCountAfterSend(to: 443, blockQUIC: true) == 0)
    }

    @Test func `UDP to port 443 is forwarded when blockQUIC is unset`() {
        #expect(sessionCountAfterSend(to: 443, blockQUIC: false) == 1)
    }

    @Test func `UDP to port 53 is forwarded even when blockQUIC is set`() {
        #expect(sessionCountAfterSend(to: 53, blockQUIC: true) == 1)
    }

    /// A non-QUIC datagram relays to the real destination even with the flag on.
    @Test func `non-QUIC UDP relays end-to-end when blockQUIC is set`() throws {
        let receiver = try UDPReceiver()
        defer { receiver.close() }

        let queue = DispatchQueue(label: "udp.test.e2e")
        let forwarder = VPhoneUDPForwarder(
            configuration: .default,
            queue: queue,
            blockQUIC: true,
        ) { _, _ in }
        queue.sync { forwarder.start() }
        defer { queue.sync { forwarder.stop() } }

        let payload: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
        queue.sync { forwarder.send(payload, for: flow(to: receiver.port)) }

        #expect(receiver.waitForDatagram() == payload)
    }

    /// The full wiring: a tunnel manifest with `interceptBlockQUIC` yields a
    /// configuration whose forwarder drops guest QUIC.
    @Test func `a tunnel manifest with interceptBlockQUIC drops guest QUIC`() throws {
        let manifest = VPhoneVirtualMachineManifest.NetworkConfig(
            mode: .tunnel,
            macAddress: "",
            interceptBlockQUIC: true,
        )
        let plan = try VPhoneNetworking.plan(manifest)
        guard case let .tunnel(configuration) = plan.attachment else {
            Issue.record("expected a tunnel attachment")
            return
        }
        #expect(configuration.blockQUIC)

        let queue = DispatchQueue(label: "udp.test.wiring")
        let forwarder = VPhoneUDPForwarder(
            configuration: configuration,
            queue: queue,
            blockQUIC: configuration.blockQUIC,
        ) { _, _ in }
        queue.sync { forwarder.start() }
        defer { queue.sync { forwarder.stop() } }
        queue.sync { forwarder.send([0x00], for: flow(to: 443)) }
        #expect(forwarder.sessionCount == 0)
    }

    /// A loopback UDP socket that records the first datagram it receives.
    private final class UDPReceiver: @unchecked Sendable {
        enum Error: Swift.Error { case setupFailed }

        private let descriptor: Int32
        let port: UInt16

        init() throws {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw Error.setupFailed }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { Darwin.close(fd); throw Error.setupFailed }
            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            descriptor = fd
            port = UInt16(bigEndian: assigned.sin_port)
        }

        func waitForDatagram(timeout: TimeInterval = 2) -> [UInt8]? {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if poll(&poller, 1, 50) > 0 {
                    var buffer = [UInt8](repeating: 0, count: 2048)
                    let got = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
                    if got > 0 { return Array(buffer[0 ..< got]) }
                }
            }
            return nil
        }

        func close() { Darwin.close(descriptor) }
    }
}
