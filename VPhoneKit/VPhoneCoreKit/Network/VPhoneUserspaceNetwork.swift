import Foundation
import os
import Virtualization

// MARK: - Errors

public enum VPhoneUserspaceNetworkError: Error, Equatable {
    /// `socketpair(2)` failed.
    case socketPairFailed(errno: Int32)
    /// The attachment was asked for before `start()`, or after `stop()`.
    case notRunning
}

extension VPhoneUserspaceNetworkError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .socketPairFailed(errno):
            "Could not create the network device socket pair (errno \(errno))."
        case .notRunning:
            "The userspace network is not running."
        }
    }

    public var errorDescription: String? {
        description
    }
}

// MARK: - The device

/// A guest NIC backed entirely by this process.
///
/// `VZFileHandleNetworkDeviceAttachment` hands frames to us untouched — it
/// performs no DHCP, no ARP, no translation — so everything the guest expects a
/// network to do is implemented on this side, in `VPhoneUserspaceNetworkResponder`.
///
/// The point of the mode is egress: replies leave through ordinary host sockets,
/// so they follow the host's routing table and therefore a VPN, with no root, no
/// interface, and no change to the host's configuration. `nat` cannot do that
/// because vmnet's masquerade is pinned to a physical interface.
///
/// Threading: every field is touched only on `queue`, a serial queue. Frame reads
/// arrive as `DispatchSource` events on that queue, and `stop()` hops onto it
/// before tearing down. That is the whole of the invariant behind
/// `@unchecked Sendable`.
public final class VPhoneUserspaceNetwork: @unchecked Sendable {
    public let configuration: VPhoneUserspaceNetworkConfiguration

    /// Our end of the socket pair. The other end belongs to the attachment.
    private let socket: Int32
    /// Held so the attachment (and therefore the VZ device tree) outlives us.
    private let attachment: VZFileHandleNetworkDeviceAttachment
    private let queue: DispatchQueue
    private static let log = Logger(subsystem: "com.vphone.tunnel", category: "frames")
    /// Reused across frames; see the note on the UDP forwarder's buffer.
    private var frameBuffer = [UInt8](repeating: 0, count: VPhoneUserspaceNetwork.frameCapacity)
    private var source: DispatchSourceRead?
    /// Set by `stop()`. Cancelling the read source closes our descriptor once no
    /// handler is running, so the pair cannot be reopened after that.
    private var isStopped = false
    private var responder: VPhoneUserspaceNetworkResponder
    /// Carries the guest's UDP out to the host and the answers back. Owns one
    /// socket per flow, so it is the thing `stop()` has to tear down.
    ///
    /// `lazy` because building it needs a closure over `self`, and a stored
    /// property cannot be captured until every property is initialised. First
    /// touch is always on `queue`.
    private lazy var forwarder = VPhoneUDPForwarder(
        configuration: configuration,
        queue: queue,
        blockQUIC: configuration.blockQUIC,
    ) { [weak self] flow, payload in
        self?.sendUDPReply(flow: flow, payload: payload)
    }

    /// Host clients of forwarded UDP ports, by the gateway port the guest
    /// sees them on.
    private var inboundUDP: [UInt16: InboundUDPSession] = [:]
    private var inboundUDPCursor: UInt16 = 40000

    /// Terminates the guest's TCP against host sockets. Owns one connection per
    /// flow, and emits segments of its own rather than echoing ours.
    ///
    /// `start()` resolves the proxy host and substitutes the `${…}` tokens
    /// synchronously, stores the final `.resolved`/`.failed` in `resolvedUpstream`
    /// before this lazy forwarder is first touched, and the forwarder adopts it
    /// at init. It is never handed a nil upstream while `intercept` is set, so a
    /// configured proxy is never silently bypassed, and there is no pending state
    /// or later replacement.
    private lazy var tcpForwarder = VPhoneTCPForwarder(
        queue: queue,
        gatewayAddress: configuration.hostAddress,
        upstream: resolvedUpstream,
    ) { [weak self] flow, segment in
        self?.sendTCPReply(flow: flow, segment: segment)
    }

    /// The upstream handed to the forwarder, computed in `start()` before the
    /// lazy forwarder is first touched. Nil while `intercept` is absent.
    private var resolvedUpstream: VPhoneSOCKSUpstream?

    /// Resolves the proxy host to IPv4 addresses, once, when the network starts.
    /// Injected so tests can supply a never-returning, delayed, or multi-address
    /// stub without a real DNS lookup. Default is the production resolver.
    private let resolveProxy: @Sendable (String) -> [VPhoneIPv4Address]
    /// Deadline for that resolution. Production is 5 s (REQ-004); tests scale it
    /// so a never-returning resolver does not cost a real 5 s wait.
    private let resolveDeadline: TimeInterval
    /// Sink for the single resolution-failure log line. Default writes through
    /// the frames logger; tests inject a collector to assert exactly one line.
    private let resolutionLog: @Sendable (String) -> Void

    /// Largest frame we will accept from the guest. Ethernet header plus a
    /// jumbo-sized IP packet; the guest is expected to stay within `mtu`.
    private static let frameCapacity = 9216

    public convenience init(configuration: VPhoneUserspaceNetworkConfiguration = .default) throws {
        try self.init(configuration: configuration, resolveProxy: VPhoneHostResolver.resolveIPv4, resolveDeadline: 5)
    }

    /// Test seam: the public initialiser plus an injectable proxy resolver, its
    /// deadline, and a log sink, so resolution can be driven without a DNS lookup
    /// or a real 5 s wait and its single failure line can be asserted.
    convenience init(
        configuration: VPhoneUserspaceNetworkConfiguration = .default,
        resolveProxy: @escaping @Sendable (String) -> [VPhoneIPv4Address],
        resolveDeadline: TimeInterval = 5,
        resolutionLog: (@Sendable (String) -> Void)? = nil,
    ) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw VPhoneUserspaceNetworkError.socketPairFailed(errno: errno)
        }
        try self.init(
            configuration: configuration,
            guestDescriptor: descriptors[0],
            hostDescriptor: descriptors[1],
            resolveProxy: resolveProxy,
            resolveDeadline: resolveDeadline,
            resolutionLog: resolutionLog,
        )
    }

    /// Adopt a socket pair that already exists rather than making one.
    ///
    /// The frame loop only fails in ways a direct call cannot reproduce: a
    /// blocking read that parks the shared queue, a `start()` that deadlocks
    /// against the forwarders it owns. Catching those needs a real event loop,
    /// and a test driving one needs the guest's end of the pair. That is what
    /// this seam is for; production always goes through the initialiser above.
    init(
        configuration: VPhoneUserspaceNetworkConfiguration,
        guestDescriptor: Int32,
        hostDescriptor: Int32,
        resolveProxy: @escaping @Sendable (String) -> [VPhoneIPv4Address] = VPhoneHostResolver.resolveIPv4,
        resolveDeadline: TimeInterval = 5,
        resolutionLog: (@Sendable (String) -> Void)? = nil,
    ) throws {
        for descriptor in [guestDescriptor, hostDescriptor] {
            // A SOCK_DGRAM pair has a small default buffer, and the guest can
            // burst (a DHCP retry plus an ARP plus a DNS query) faster than we
            // drain it. Dropping frames here would look like packet loss.
            var size: Int32 = 4 << 20
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            // Non-blocking is load-bearing. `drain` loops until recv reports
            // EAGAIN, and everything -- the UDP and TCP forwarders included --
            // shares this one serial queue. On a blocking socket the loop parks
            // in recv the moment the guest goes quiet, which is exactly when it
            // is waiting for a reply, so the reply is never read. The symptom is
            // a guest whose DNS queries leave but whose answers never arrive.
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
            // VZ closes its end when the device goes away; a frame sent after that
            // must fail with EPIPE, not kill the VM process with SIGPIPE.
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        }

        socket = hostDescriptor
        attachment = VZFileHandleNetworkDeviceAttachment(
            fileHandle: FileHandle(fileDescriptor: guestDescriptor, closeOnDealloc: true),
        )
        queue = DispatchQueue(label: "com.vphone.userspace-network")
        responder = VPhoneUserspaceNetworkResponder(configuration: configuration)
        self.configuration = configuration
        self.resolveProxy = resolveProxy
        self.resolveDeadline = resolveDeadline
        self.resolutionLog = resolutionLog ?? { line in Self.log.error("\(line, privacy: .public)") }
    }

    /// The object to hand to `VZVirtioNetworkDeviceConfiguration.attachment`.
    public var networkAttachment: VZNetworkDeviceAttachment {
        attachment
    }

    /// Begin draining the guest's frames. Idempotent, and a no-op after `stop()`.
    public func start() {
        queue.sync {
            guard !isStopped, source == nil else { return }
            let descriptor = socket
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            // Closing the source closes the descriptor, but only once no handler
            // is running; VZ holds its own end of the pair until the device goes.
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
            // Resolve and substitute synchronously, before the lazy forwarder is
            // first touched below, so it adopts the final upstream at init.
            if let endpoint = configuration.intercept {
                resolvedUpstream = resolveUpstream(endpoint)
            }
            forwarder.start()
            tcpForwarder.start()
            Self.log.info(
                "tunnel up: gateway \(String(describing: self.configuration.hostAddress), privacy: .public) guest \(String(describing: self.configuration.guestAddress), privacy: .public) mtu \(self.configuration.mtu, privacy: .public) resolver \(VPhoneHostResolver.preferred()?.description ?? "NONE", privacy: .public)",
            )
        }
    }

    /// Stop draining and close our end. Idempotent. There is no way back: the
    /// descriptors are gone, so a later `start()` does nothing.
    public func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            source?.cancel()
            source = nil
            forwarder.stop()
            tcpForwarder.stop()
        }
    }

    deinit {
        // Nothing may hop onto `queue` from deinit, so only cancel if we are
        // already on it — which is why `stop()` exists and should be preferred.
        source?.cancel()
    }

    // MARK: - Proxy resolution

    /// Lock-guarded box so the off-thread resolver can publish its result to the
    /// semaphore waiter without a data race.
    private final class ResolveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var addresses: [VPhoneIPv4Address] = []
        func set(_ value: [VPhoneIPv4Address]) { lock.lock(); addresses = value; lock.unlock() }
        func get() -> [VPhoneIPv4Address] { lock.lock(); defer { lock.unlock() }; return addresses }
    }

    /// Substitute and validate the credentials, then resolve the proxy host, all
    /// synchronously so the forwarder receives its final upstream at init. On any
    /// failure the single resolution-failure line is logged here (`.failed` is
    /// payload-free). Called on `queue` from `start()`.
    func resolveUpstream(_ endpoint: VPhoneInterceptEndpoint) -> VPhoneSOCKSUpstream {
        // Credentials first: token substitution and the RFC 1929 length limits
        // need no DNS, and resolving them before the host wait gives the right
        // cause category without paying for a lookup that cannot be used.
        var credentials: VPhoneSOCKSCredentials?
        if let rawUser = endpoint.user {
            guard let username = substitute(rawUser) else {
                return fail(endpoint, cause: "token", reason: "undefined ${…} token in username")
            }
            guard let password = substitute(endpoint.password ?? "") else {
                return fail(endpoint, cause: "token", reason: "undefined ${…} token in password")
            }
            // RFC 1929 ULEN/PLEN are one octet each; ULEN must be 1-255.
            if username.isEmpty {
                return fail(endpoint, cause: "credentials", reason: "username is empty after substitution")
            }
            if username.utf8.count > 255 {
                return fail(endpoint, cause: "credentials", reason: "username exceeds 255 bytes after substitution")
            }
            if password.utf8.count > 255 {
                return fail(endpoint, cause: "credentials", reason: "password exceeds 255 bytes after substitution")
            }
            credentials = VPhoneSOCKSCredentials(username: username, password: password)
        }

        // The resolver may block (a real DNS lookup, or a test stub that delays
        // or never returns); keep it off the serial queue so it cannot stall the
        // frame loop, and bound the wait with the deadline. The pick is
        // deterministic: the first IPv4 address returned.
        let box = ResolveBox()
        let semaphore = DispatchSemaphore(value: 0)
        let resolve = resolveProxy
        let host = endpoint.host
        DispatchQueue.global().async {
            box.set(resolve(host))
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + resolveDeadline) == .timedOut {
            return fail(endpoint, cause: "deadline", reason: "resolution deadline expired")
        }
        guard let first = box.get().first else {
            return fail(endpoint, cause: "host", reason: "no IPv4 address")
        }
        return .resolved(first, endpoint.port, credentials)
    }

    /// Log the single resolution-failure line and return `.failed`. Format names
    /// the proxy endpoint, the cause category, a short reason, and the remedy.
    private func fail(_ endpoint: VPhoneInterceptEndpoint, cause: String, reason: String) -> VPhoneSOCKSUpstream {
        resolutionLog(
            "socks \(endpoint.host):\(endpoint.port) \(cause): \(reason); fix it and restart the VM; guest TCP is reset until then")
        return .failed
    }

    /// Resolve the three REQ-001 tokens (`${env:NAME}`, `${vm.name}`, `${vm.id}`)
    /// in a userinfo field. Returns nil when a token is undefined — an unset
    /// environment variable, or `${vm.id}` on a VM with no predicted UDID — which
    /// fails the upstream closed. The grammar was already validated at parse
    /// time, so any `${…}` here is one of the three.
    private func substitute(_ field: String) -> String? {
        VPhoneVirtualMachineManifest.NetworkConfig.expandInterceptTokens(field) { name in
            switch name {
            case "vm.name": configuration.vmName
            case "vm.id": configuration.vmID
            case _ where name.hasPrefix("env:"): ProcessInfo.processInfo.environment[String(name.dropFirst(4))]
            default: nil
            }
        }
    }

    // MARK: - Frame loop

    private func drain() {
        while true {
            let received = frameBuffer.withUnsafeMutableBytes { raw in
                recv(socket, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 {
                return
            } // EAGAIN once the queue is empty
            let frame = Array(frameBuffer[0 ..< received])
            switch responder.handle(frame) {
            case .drop:
                continue
            case let .reply(reply):
                write(reply)
            case let .forward(flow, payload):
                if flow.destinationAddress == configuration.hostAddress,
                   let session = inboundUDP[flow.destinationPort], session.guestPort == flow.sourcePort
                {
                    replyInbound(payload, session: session, gatewayPort: flow.destinationPort)
                    continue
                }
                // The answer arrives later, on this same queue.
                forwarder.send(payload, for: flow)
            case let .forwardTCP(flow, segment):
                tcpForwarder.receive(segment, for: flow)
            }
        }
    }

    /// Hand a finished frame to the guest's side of the pair.
    ///
    /// The result matters. This is a datagram socket, so a frame the kernel
    /// refuses is gone -- and since TCP is an ordered stream, one lost frame
    /// leaves the guest waiting forever for a segment we never resend. Reporting
    /// a failure here is the difference between "slow" and "silently stalled".
    private func write(_ frame: [UInt8]) {
        let sent = frame.withUnsafeBytes { raw in
            send(socket, raw.baseAddress, raw.count, 0)
        }
        if sent != frame.count {
            Self.log.error("frame send failed: \(sent, privacy: .public)/\(frame.count, privacy: .public) errno \(errno, privacy: .public)")
        }
    }

    /// Wrap one forwarded datagram as if it came from where the guest sent it.
    ///
    /// The source address is the guest's *destination*, not our gateway address:
    /// a DNS lookup was addressed to `192.168.127.1`, so the answer has to
    /// appear to come from there or the guest's stack will discard it.
    /// Wrap one TCP segment the forwarder produced.
    ///
    /// Same addressing rule as UDP: the source is what the guest believes it is
    /// talking to, not our gateway address, or the guest's stack drops the
    /// segment before its TCP ever sees it.
    private func sendTCPReply(flow: VPhoneTCPFlow, segment: VPhoneTCPSegment) {
        let packet = VPhoneIPv4Packet(
            source: flow.destinationAddress,
            destination: flow.sourceAddress,
            proto: .tcp,
            payload: segment.bytes(source: flow.destinationAddress, destination: flow.sourceAddress),
        )
        // Segments are already cut to the guest's MSS, so these normally fit in
        // one. The call stays because a guest is free to advertise an MSS larger
        // than the MTU we sent it, and silently emitting an oversized datagram
        // would be the same bug as above.
        for fragment in packet.fragmented(toFit: configuration.mtu) {
            let frame = VPhoneEthernetFrame(
                destination: flow.guestHardware,
                source: .gateway,
                etherType: .ipv4,
                payload: fragment,
            ).bytes
            write(frame)
        }
    }

    private func sendUDPReply(flow: VPhoneUDPFlow, payload: [UInt8]) {
        let datagram = VPhoneUDPDatagram(
            sourcePort: flow.destinationPort,
            destinationPort: flow.sourcePort,
            payload: payload,
        )
        let packet = VPhoneIPv4Packet(
            source: flow.destinationAddress,
            destination: flow.sourceAddress,
            proto: .udp,
            payload: datagram.bytes(source: flow.destinationAddress, destination: flow.sourceAddress),
        )
        // UDP has no layer above it to chop anything up, and QUIC rides right at
        // the MTU boundary, so a reply that does not fit has to be fragmented
        // here or it goes out as a datagram the guest cannot take.
        for fragment in packet.fragmented(toFit: configuration.mtu) {
            let frame = VPhoneEthernetFrame(
                destination: flow.guestHardware,
                source: .gateway,
                etherType: .ipv4,
                payload: fragment,
            ).bytes
            write(frame)
        }
    }
}

// MARK: - Inbound

/// Port forwarding into the guest. The host side (`VPhonePortForwarder`) owns
/// the listening sockets; this side makes each client look, to the guest, like
/// a peer at the gateway address, which is the only address it can reach.
extension VPhoneUserspaceNetwork {
    /// One host client of a forwarded UDP port.
    struct InboundUDPSession {
        let listener: Int32
        let client: sockaddr_in
        let guestPort: UInt16
        var lastActivity: Date
    }

    /// UDP has no teardown, so a client that goes quiet is forgotten after this.
    private static let inboundUDPIdleTimeout: TimeInterval = 60
    private static let inboundUDPPorts: ClosedRange<UInt16> = 40000 ... 59999

    /// Connect an accepted host TCP client to `guestPort`. Takes ownership of
    /// the descriptor, and closes it when the guest cannot be reached: before
    /// the guest has sent its first frame there is no MAC to address it by.
    public func acceptInbound(tcp descriptor: Int32, guestPort: UInt16) {
        queue.async { [self] in
            guard !isStopped, let mac = responder.guestMAC else {
                close(descriptor)
                return
            }
            tcpForwarder.openInbound(
                socket: descriptor,
                guestAddress: configuration.guestAddress,
                guestPort: guestPort,
                gatewayAddress: configuration.hostAddress,
                guestHardware: mac,
            )
        }
    }

    /// One datagram a host client sent to a forwarded UDP port. Answers go
    /// back through `listener`, which the caller keeps open.
    public func receiveInbound(udp payload: [UInt8], from client: sockaddr_in, listener: Int32, guestPort: UInt16) {
        queue.async { [self] in
            guard !isStopped, let mac = responder.guestMAC else { return }
            let now = Date()
            inboundUDP = inboundUDP.filter { now.timeIntervalSince($0.value.lastActivity) < Self.inboundUDPIdleTimeout }

            let gatewayPort: UInt16
            if let existing = inboundUDP.first(where: { _, session in
                session.listener == listener && session.guestPort == guestPort
                    && session.client.sin_addr.s_addr == client.sin_addr.s_addr
                    && session.client.sin_port == client.sin_port
            }) {
                gatewayPort = existing.key
            } else {
                guard let port = nextInboundUDPPort() else { return }
                gatewayPort = port
            }
            inboundUDP[gatewayPort] = InboundUDPSession(listener: listener, client: client, guestPort: guestPort, lastActivity: now)

            let flow = VPhoneUDPFlow(
                sourceAddress: configuration.guestAddress,
                sourcePort: guestPort,
                destinationAddress: configuration.hostAddress,
                destinationPort: gatewayPort,
                guestHardware: mac,
            )
            sendUDPReply(flow: flow, payload: payload)
        }
    }

    private func nextInboundUDPPort() -> UInt16? {
        for _ in Self.inboundUDPPorts {
            inboundUDPCursor = inboundUDPCursor >= Self.inboundUDPPorts.upperBound
                ? Self.inboundUDPPorts.lowerBound
                : inboundUDPCursor + 1
            if inboundUDP[inboundUDPCursor] == nil {
                return inboundUDPCursor
            }
        }
        return nil
    }

    /// The guest answered a forwarded UDP client.
    private func replyInbound(_ payload: [UInt8], session: InboundUDPSession, gatewayPort: UInt16) {
        inboundUDP[gatewayPort]?.lastActivity = Date()
        var client = session.client
        _ = payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &client) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(session.listener, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
