import Foundation
import os
import SystemConfiguration

// MARK: - Host resolver lookup

/// The host's own DNS servers, so the guest's lookups can be forwarded to the
/// same place the host would use.
///
/// Read through `SystemConfiguration` rather than a file because that is what
/// changes when the VPN connects: the point of `tunnel` is that the guest's
/// egress follows the host's, and the resolver follows the same switch.
enum VPhoneHostResolver {
    static func addresses() -> [VPhoneIPv4Address] {
        guard
            let store = SCDynamicStoreCreate(nil, "com.vphone.tunnel" as CFString, nil, nil),
            let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString),
            let dictionary = value as? [String: Any],
            let servers = dictionary[kSCPropNetDNSServerAddresses as String] as? [String]
        else { return [] }
        return servers.compactMap(VPhoneIPv4Address.init(dotted:))
    }

    /// The first usable resolver, or nil when the host has none configured.
    static func preferred() -> VPhoneIPv4Address? {
        addresses().first
    }

    /// Resolve a host (a dotted-IPv4 literal or a name) to its IPv4 addresses,
    /// in the order `getaddrinfo` returns them. The SOCKS upstream stack is
    /// IPv4-only, so a bracketed-IPv6 literal or an IPv6-only name resolves to an
    /// empty list and the caller fails closed. The default production proxy
    /// resolver for `VPhoneUserspaceNetwork`.
    @Sendable
    static func resolveIPv4(_ host: String) -> [VPhoneIPv4Address] {
        if let literal = VPhoneIPv4Address(dotted: host) {
            return [literal]
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [VPhoneIPv4Address] = []
        var node = result
        while let current = node {
            if current.pointee.ai_family == AF_INET, let sa = current.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    // sin_addr is network order; VPhoneIPv4Address holds host order.
                    addresses.append(VPhoneIPv4Address(UInt32(bigEndian: sin.pointee.sin_addr.s_addr)))
                }
            }
            node = current.pointee.ai_next
        }
        return addresses
    }
}

public extension VPhoneIPv4Address {
    /// Parse `a.b.c.d`, or nil for anything else (including IPv6, which this
    /// stack deliberately does not carry).
    init?(dotted: String) {
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        self.init(octets[0], octets[1], octets[2], octets[3])
    }
}

// MARK: - Forwarder

/// Carries the guest's UDP to the host and the answers back.
///
/// One connected `SOCK_DGRAM` socket per flow, so the kernel does the demultiplex
/// for us: a reply can only arrive from the address we sent to, which is the
/// whole of the security story for an unprivileged forwarder. The socket is
/// non-blocking and drained on the same serial queue as the frame loop, so
/// nothing here needs its own locking.
///
/// Threading: every field is touched only on `queue`, which the owner supplies.
/// That is the invariant behind `@unchecked Sendable`.
final class VPhoneUDPForwarder: @unchecked Sendable {
    /// Delivers one datagram back toward the guest.
    typealias Deliver = (VPhoneUDPFlow, [UInt8]) -> Void

    /// Flows are forgotten after this long without traffic. UDP has no teardown,
    /// so this is the only thing that bounds the session table.
    private static let idleTimeout: TimeInterval = 30
    /// Largest datagram read from the host in one call. Responses that exceed the
    /// guest's MTU are fragmented on the way in (see `VPhoneUserspaceNetwork`),
    /// so nothing is dropped for size here.
    private static let datagramCapacity = 65535

    private final class Session {
        let socket: Int32
        let source: DispatchSourceRead
        let flow: VPhoneUDPFlow
        /// Where this flow's datagrams actually go. Differs from the guest's
        /// destination only for DNS, which we answer ourselves.
        let destination: (address: VPhoneIPv4Address, port: UInt16)
        var lastActivity: Date

        init(socket: Int32, source: DispatchSourceRead, flow: VPhoneUDPFlow, destination: (VPhoneIPv4Address, UInt16), lastActivity: Date) {
            self.socket = socket
            self.source = source
            self.flow = flow
            self.destination = destination
            self.lastActivity = lastActivity
        }
    }

    private let queue: DispatchQueue
    private let configuration: VPhoneUserspaceNetworkConfiguration
    private let deliver: Deliver
    /// When set, guest UDP to port 443 is dropped so QUIC apps fall back to the
    /// interceptable TCP path. Only consulted on `queue`.
    private let blockQUIC: Bool
    private var sessions: [VPhoneUDPFlowKey: Session] = [:]
    private var reaper: DispatchSourceTimer?
    private var isStopped = false
    /// Reused for every read. Allocating and zeroing a maximum-sized datagram on
    /// each burst is real work at QUIC rates, where hundreds of packets a second
    /// is ordinary. Only touched on `queue`.
    private var readBuffer = [UInt8](repeating: 0, count: VPhoneUDPForwarder.datagramCapacity)

    /// Marks `queue` as ours, so `sessionCount` can tell whether it is already on
    /// it rather than deadlocking against itself.
    private static let queueKey = DispatchSpecificKey<Void>()
    private static let log = Logger(subsystem: "com.vphone.tunnel", category: "udp")

    init(
        configuration: VPhoneUserspaceNetworkConfiguration,
        queue: DispatchQueue,
        blockQUIC: Bool = false,
        deliver: @escaping Deliver,
    ) {
        self.configuration = configuration
        self.queue = queue
        self.blockQUIC = blockQUIC
        self.deliver = deliver
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    /// Number of live flows. Exposed for tests and diagnostics.
    ///
    /// The only member callable from any thread: off the queue it hops on, on the
    /// queue it reads directly. Hopping unconditionally would deadlock, which is
    /// exactly the bug `start()` had.
    var sessionCount: Int {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return sessions.count
        }
        return queue.sync { sessions.count }
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopped, reaper == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleTimeout, repeating: Self.idleTimeout)
        timer.setEventHandler { [weak self] in self?.reapIdleSessions() }
        timer.resume()
        reaper = timer
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopped else { return }
        isStopped = true
        reaper?.cancel()
        reaper = nil
        for session in sessions.values {
            closeSession(session)
        }
        sessions.removeAll()
    }

    /// Send one guest datagram onward. `flow` names both ends. On `queue`.
    func send(_ payload: [UInt8], for flow: VPhoneUDPFlow) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopped else { return }
        guard let session = session(for: flow) else { return }
        session.lastActivity = Date()
        let sent = payload.withUnsafeBytes { raw in
            // Qualified: the type has its own `send` for guest payloads.
            Darwin.send(session.socket, raw.baseAddress, raw.count, 0)
        }
        if sent != payload.count {
            // EAGAIN (the host's buffer is full) or EMSGSIZE (the datagram is
            // larger than this socket will carry). Either way the datagram is
            // gone, and a silent drop here looks like the network misbehaving.
            Self.log.error("udp to host failed: \(sent, privacy: .public)/\(payload.count, privacy: .public)B errno \(errno, privacy: .public)")
        }
    }

    // MARK: - Sessions

    private func session(for flow: VPhoneUDPFlow) -> Session? {
        let key = flow.key
        if let existing = sessions[key] {
            // A new request on the same flow is what keeps it alive.
            if existing.flow.guestHardware.bytes != flow.guestHardware.bytes {
                // The guest came back with a different MAC (a re-created NIC).
                // Rebuild rather than answer to the wrong address.
                closeSession(existing)
                sessions[key] = nil
            } else {
                return existing
            }
        }
        return createSession(for: flow, key: key)
    }

    private func createSession(for flow: VPhoneUDPFlow, key: VPhoneUDPFlowKey) -> Session? {
        guard let destination = resolveDestination(for: flow) else { return nil }
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = destination.port.bigEndian
        let octets = destination.address.bytes
        // Both fields are network order: leaving sin_addr in host order asks for
        // a different address entirely (EADDRNOTAVAIL on 127.0.0.1).
        let hostOrder = UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16 | UInt32(octets[2]) << 8 | UInt32(octets[3])
        address.sin_addr = in_addr(s_addr: hostOrder.bigEndian)

        // A connected UDP socket: the kernel drops datagrams from anyone else, so
        // the guest cannot be reached by an unrelated sender.
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }

        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var bufferSize: Int32 = 256 << 10
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let session = Session(
            socket: descriptor,
            source: source,
            flow: flow,
            destination: (destination.address, destination.port),
            lastActivity: Date(),
        )
        source.setEventHandler { [weak self] in self?.drain(session) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sessions[key] = session
        return session
    }

    /// Where a flow's datagrams actually go.
    ///
    /// The guest is told its resolver is the gateway (`192.168.127.1`), so a
    /// lookup arrives addressed to us. Send it to the host's resolver instead —
    /// the same one the host itself would use, VPN or not.
    ///
    /// Anything else sent to the gateway goes to the Mac's loopback, as TCP
    /// does (see `VPhoneTCPForwarder.gatewayAddress`).
    private func resolveDestination(for flow: VPhoneUDPFlow) -> (address: VPhoneIPv4Address, port: UInt16)? {
        // QUIC rides UDP/443. Dropping it forces the app onto TCP, which the
        // SOCKS path can intercept; nil means "no session, drop the datagram".
        if blockQUIC, flow.destinationPort == 443 {
            return nil
        }
        guard flow.destinationAddress == configuration.hostAddress else {
            return (flow.destinationAddress, flow.destinationPort)
        }
        guard flow.destinationPort == 53 else {
            return (VPhoneIPv4Address(127, 0, 0, 1), flow.destinationPort)
        }
        guard let resolver = VPhoneHostResolver.preferred() else {
            return (flow.destinationAddress, flow.destinationPort)
        }
        return (resolver, 53)
    }

    private func drain(_ session: Session) {
        while true {
            let received = readBuffer.withUnsafeMutableBytes { raw in
                recv(session.socket, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 {
                return
            } // EAGAIN, or an ICMP error on the flow
            session.lastActivity = Date()
            deliver(session.flow, Array(readBuffer[0 ..< received]))
        }
    }

    private func reapIdleSessions() {
        let now = Date()
        for (key, session) in sessions where now.timeIntervalSince(session.lastActivity) >= Self.idleTimeout {
            closeSession(session)
            sessions[key] = nil
        }
    }

    private func closeSession(_ session: Session) {
        session.source.cancel()
    }
}
