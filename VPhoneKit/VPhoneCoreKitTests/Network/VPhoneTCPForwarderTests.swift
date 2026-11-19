import Foundation
import Testing
@testable import VPhoneCoreKit

/// Behaviour tests for the TCP forwarder.
///
/// These drive the forwarder the way the frame loop does and play the guest's
/// part, so what is under test is the forwarder's own decisions -- how much it
/// sends, when it sends it again, what it advertises -- against a real host
/// socket on the loopback interface.
///
/// Every bug found against a real guest lived here: a window it did not honour,
/// a retransmission that did not exist, a scale it never negotiated, an upload
/// path that spun instead of waiting. They all passed the frame-level tests in
/// `VPhoneUserspaceNetworkTests`, which is the point of having both.
struct VPhoneTCPForwarderTests {
    // MARK: - Shared plumbing

    /// A mutex box, because the forwarder's callback fires on its own queue and
    /// Swift 6 will not let that touch a captured `var`.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// Plays the guest: hands segments to the forwarder and records what comes
    /// back, exactly as the frame loop's `deliver` would.
    private final class Harness: @unchecked Sendable {
        let forwarder: VPhoneTCPForwarder
        let flow: VPhoneTCPFlow
        let guestPort: UInt16

        private let queue: DispatchQueue
        private let recorded = Box<[VPhoneTCPSegment]>([])
        /// When set, the harness answers every segment the way a guest stack
        /// would: acknowledge at once, window wide open. Used by the tests that
        /// are about the send path rather than about windowing.
        private let acknowledgesImmediately = Box(false)

        init(
            guestPort: UInt16,
            destinationPort: UInt16,
            mss: Int = 1460,
            upstream: VPhoneSOCKSUpstream? = nil,
            handshakeTimeout: TimeInterval = 10,
            socksLog: (@Sendable (String) -> Void)? = nil,
        ) {
            self.guestPort = guestPort
            let queue = DispatchQueue(label: "forwarder-tests.\(guestPort)")
            let recorded = recorded
            let acknowledgesImmediately = acknowledgesImmediately
            let flow = VPhoneTCPFlow(
                sourceAddress: VPhoneUserspaceNetworkConfiguration.default.guestAddress,
                sourcePort: guestPort,
                destinationAddress: VPhoneIPv4Address(127, 0, 0, 1),
                destinationPort: destinationPort,
                guestHardware: VPhoneMACAddress([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]),
            )
            self.queue = queue
            self.flow = flow

            // The callback needs the forwarder, and the forwarder needs the
            // callback, so the reference goes through a box filled in below.
            let box = Box<VPhoneTCPForwarder?>(nil)
            forwarder = VPhoneTCPForwarder(
                queue: queue,
                upstream: upstream,
                handshakeTimeout: handshakeTimeout,
                socksLog: socksLog,
            ) { _, segment in
                recorded.withLock { $0.append(segment) }
                guard !segment.payload.isEmpty, acknowledgesImmediately.withLock({ $0 }) else { return }
                let acknowledgment = VPhoneTCPSegment(
                    sourcePort: guestPort,
                    destinationPort: 0,
                    sequenceNumber: segment.sequenceNumber,
                    acknowledgmentNumber: segment.sequenceNumber &+ UInt32(segment.payload.count),
                    flags: VPhoneTCPFlags.ack,
                    windowSize: 65535,
                )
                // Async rather than direct: `receive` re-enters the same object,
                // and this way the recursion depth stays bounded.
                queue.async { box.withLock { $0 }?.receive(acknowledgment, for: flow) }
            }
            box.withLock { $0 = forwarder }
            _ = mss
        }

        func acknowledgeImmediately() {
            acknowledgesImmediately.withLock { $0 = true }
        }

        /// What the forwarder has put on the wire, oldest first.
        var sent: [VPhoneTCPSegment] {
            recorded.withLock { $0 }
        }

        /// Our ISN, read off the SYN-ACK the only way any peer could.
        var ourISN: UInt32? {
            sent.first { $0.hasSYN && $0.hasACK }?.sequenceNumber
        }

        /// Bytes of *distinct* sequence numbers. A retransmission repeats a range
        /// rather than extending it, so counting transmissions would overcount.
        var sentDataBytes: Int {
            var unique: [UInt32: Int] = [:]
            for segment in sent where !segment.payload.isEmpty {
                unique[segment.sequenceNumber] = segment.payload.count
            }
            return unique.values.reduce(0, +)
        }

        /// Payload bytes delivered to the guest, distinct by sequence and in
        /// ascending sequence order. Any proxy bind-address bytes that leaked
        /// would show up here as extra bytes.
        var deliveredPayload: [UInt8] {
            var unique: [UInt32: [UInt8]] = [:]
            for segment in sent where !segment.payload.isEmpty {
                unique[segment.sequenceNumber] = segment.payload
            }
            return unique.sorted { $0.key < $1.key }.flatMap { $0.value }
        }

        /// Distinct sequence numbers and their sizes, ascending.
        var dataBySequence: [(sequence: UInt32, count: Int)] {
            var unique: [UInt32: Int] = [:]
            for segment in sent where !segment.payload.isEmpty {
                unique[segment.sequenceNumber] = segment.payload.count
            }
            return unique.sorted { $0.key < $1.key }.map { (sequence: $0.key, count: $0.value) }
        }

        func feed(_ segment: VPhoneTCPSegment) {
            queue.sync { forwarder.receive(segment, for: flow) }
        }

        func start() {
            queue.sync { forwarder.start() }
        }

        func stop() {
            queue.sync { forwarder.stop() }
        }

        /// Run the idle reaper as if `seconds` had passed with nothing sent.
        func reap(after seconds: TimeInterval) {
            queue.sync { forwarder.reapIdle(now: Date().addingTimeInterval(seconds)) }
        }

        var connectionCount: Int {
            forwarder.connectionCount
        }

        /// Wait for something a background socket is responsible for.
        ///
        /// Polls rather than sleeping a fixed time: the far end of these tests is
        /// a real socket, so there is no moment at which it is known to be done.
        @discardableResult
        func waitUntil(_ what: String, timeout: TimeInterval = 8, _ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate() {
                    return true
                }
                usleep(10000)
            }
            Issue.record("timed out waiting for \(what)")
            return false
        }
    }

    /// A one-connection TCP server on the loopback interface, so the forwarder
    /// has something real to terminate against.
    private final class LoopbackServer: @unchecked Sendable {
        let port: UInt16
        private let received = Box(0)
        private let finished = Box(false)
        private let stopped = Box(false)

        /// - Parameter session: runs with the accepted socket on the server's
        ///   own thread and owns closing it.
        init(session: @escaping @Sendable (Int32, LoopbackServer) -> Void) throws {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Error.socketFailed }

            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0 // let the kernel choose
            address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw Error.bindFailed }
            guard listen(descriptor, 4) == 0 else { throw Error.listenFailed }

            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            port = UInt16(bigEndian: assigned.sin_port)

            let server = self
            // A thread of its own, not a global queue: in a full CoreKit run a
            // block queued there started 2 to 3.5 s late, all of it counted
            // against the throughput test.
            Thread {
                // Only this thread closes the listener. Closed by stop() while
                // the accept had yet to run, its number went to the next test's
                // listener, and the late accept below took that test's
                // connection: a forwarder handshake does not wait for accept.
                defer { close(descriptor) }
                var listening = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                while poll(&listening, 1, 50) <= 0 {
                    if server.stopped.withLock({ $0 }) {
                        return
                    }
                }
                let client = accept(descriptor, nil, nil)
                defer { server.finished.withLock { $0 = true } }
                guard client >= 0 else { return }
                defer { close(client) }
                session(client, server)
            }.start()
        }

        /// Bytes pulled out of the socket by the session.
        var bytesReceived: Int {
            received.withLock { $0 }
        }

        /// Whether the session has returned.
        var isFinished: Bool {
            finished.withLock { $0 }
        }

        /// Read and count everything the guest sends.
        func drain(_ client: Int32) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let read = recv(client, &buffer, buffer.count, 0)
                if read <= 0 {
                    return
                }
                received.withLock { $0 += read }
            }
        }

        /// Read and count, stopping early once `target` bytes have arrived.
        func drain(_ client: Int32, until target: Int) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while bytesReceived < target {
                let read = recv(client, &buffer, buffer.count, 0)
                if read <= 0 {
                    return
                }
                received.withLock { $0 += read }
            }
        }

        /// Stop waiting for a connection; the server's thread closes the listener.
        func stop() {
            stopped.withLock { $0 = true }
        }

        enum Error: Swift.Error {
            case socketFailed
            case bindFailed
            case listenFailed
        }
    }

    /// Complete the three-way handshake, returning our ISN.
    @discardableResult
    private func handshake(
        _ harness: Harness,
        guestSequence: UInt32 = 1000,
        window: UInt16 = 65535,
        mss: Int = 1460,
        windowScale: Int? = nil,
    ) throws -> UInt32 {
        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: harness.flow.destinationPort,
            sequenceNumber: guestSequence,
            acknowledgmentNumber: 0,
            flags: VPhoneTCPFlags.syn,
            windowSize: window,
            maximumSegmentSize: mss,
            windowScale: windowScale,
        ))
        try #require(harness.waitUntil("the SYN-ACK") { harness.ourISN != nil })
        let isn = try #require(harness.ourISN)
        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: harness.flow.destinationPort,
            sequenceNumber: guestSequence &+ 1,
            acknowledgmentNumber: isn &+ 1,
            flags: VPhoneTCPFlags.ack,
            windowSize: window,
        ))
        return isn
    }

    /// Ask the host for data: a push with the peek byte.
    private func request(_ harness: Harness, acknowledged: UInt32, window: UInt16 = 65535) {
        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: harness.flow.destinationPort,
            sequenceNumber: 1001,
            acknowledgmentNumber: acknowledged,
            flags: VPhoneTCPFlags.ack | VPhoneTCPFlags.psh,
            windowSize: window,
            payload: [0x41],
        ))
    }

    // MARK: - The guest's window

    /// The window is a promise about how much the guest can take. Sending past
    /// it is how a download stalls halfway: the extra segments are discarded,
    /// nothing is sent again, and both ends sit waiting.
    @Test func `a transfer does not outrun the window the guest advertises`() async throws {
        let total = 5000
        let payload = [UInt8](repeating: 0x5A, count: total)
        let server = try LoopbackServer { client, server in
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &buffer, buffer.count, 0)
            var sent = 0
            while sent < payload.count {
                let written = payload.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                if written <= 0 {
                    break
                }
                sent += written
            }
            server.drain(client)
        }
        defer { server.stop() }

        let harness = Harness(guestPort: 51001, destinationPort: server.port)
        harness.start()
        defer { harness.stop() }

        let window: UInt16 = 2048
        let isn = try handshake(harness, window: window, mss: 1024)
        request(harness, acknowledged: isn &+ 1, window: window)

        try #require(harness.waitUntil("the first burst") { harness.sentDataBytes > 0 })
        try await Task.sleep(for: .seconds(1)) // let it overshoot if it is going to
        let afterFirstWindow = harness.sentDataBytes
        #expect(
            afterFirstWindow <= Int(window),
            "sent \(afterFirstWindow)B into a \(window)B window",
        )
        #expect(afterFirstWindow > 0, "nothing was sent even with the window open")

        // Advance the window; the transfer must resume.
        var acknowledged = isn &+ 1 &+ UInt32(afterFirstWindow)
        for _ in 2 ... 8 {
            // `feed` runs synchronously, so whatever the ACK releases is already
            // sent when it returns. Read the count before it, not after.
            let before = harness.sentDataBytes
            harness.feed(VPhoneTCPSegment(
                sourcePort: harness.guestPort,
                destinationPort: server.port,
                sequenceNumber: 1001 &+ UInt32(afterFirstWindow),
                acknowledgmentNumber: acknowledged,
                flags: VPhoneTCPFlags.ack,
                windowSize: window,
            ))
            harness.waitUntil("more data", timeout: 3) { harness.sentDataBytes > before }
            acknowledged = isn &+ 1 &+ UInt32(harness.sentDataBytes)
            if harness.sentDataBytes >= total {
                break
            }
        }

        #expect(harness.sentDataBytes >= total, "stalled at \(harness.sentDataBytes)B of \(total)B")

        let ordered = harness.dataBySequence
        let contiguous = zip(ordered, ordered.dropFirst()).allSatisfy { previous, next in
            next.sequence == previous.sequence &+ UInt32(previous.count)
        }
        #expect(contiguous, "sequence numbers are not contiguous: \(ordered.map(\.sequence))")
        #expect(ordered.allSatisfy { $0.count <= 1024 }, "a segment exceeded the guest's MSS")
    }

    // MARK: - The upload direction

    /// When the host stops reading, the bytes pile up on this side. The guest has
    /// to be told to stop -- a zero window -- and answering that by spinning
    /// would starve every other flow sharing the queue.
    @Test func `the upload direction applies back pressure instead of spinning`() throws {
        // More than the kernel can buffer. A megabyte was not: the server's
        // receive buffer grew to 1.1 MiB unread in one run and took it all, so
        // the window never had to shut. Each side grows to 4 MiB at most
        // (net.inet.tcp.autorcvbufmax, autosndbufmax).
        let total = 16 << 20
        let server = try LoopbackServer { client, server in
            sleep(1) // refuse to read, so the socket buffers fill
            server.drain(client, until: total)
        }
        defer { server.stop() }

        let harness = Harness(guestPort: 51002, destinationPort: server.port)
        harness.start()
        defer { harness.stop() }

        let isn = try handshake(harness, mss: 1024)

        let chunk = [UInt8](repeating: 0x42, count: 1240)
        var sequence = UInt32(1001)
        var remaining = total
        let started = Date()
        while remaining > 0 {
            let take = min(chunk.count, remaining)
            harness.feed(VPhoneTCPSegment(
                sourcePort: harness.guestPort,
                destinationPort: server.port,
                sequenceNumber: sequence,
                acknowledgmentNumber: isn &+ 1,
                flags: VPhoneTCPFlags.ack | VPhoneTCPFlags.psh,
                windowSize: 65535,
                payload: Array(chunk.prefix(take)),
            ))
            sequence &+= UInt32(take)
            remaining -= take
        }
        let pushTime = Date().timeIntervalSince(started)

        #expect(
            harness.sent.contains { $0.windowSize == 0 && $0.hasACK },
            "the guest was never told the window shut",
        )
        #expect(
            harness.sent.filter { $0.windowSize > 0 && $0.payload.isEmpty }.count > 1,
            "no window update when the backlog cleared",
        )
        #expect(pushTime < 10, "handing the bytes over blocked for \(String(format: "%.1f", pushTime))s")

        harness.waitUntil("the host to drain", timeout: 20) { server.bytesReceived >= total }
        #expect(server.bytesReceived >= total, "the host only saw \(server.bytesReceived)B")
    }

    // MARK: - Window scaling

    /// Scaling only applies when both ends offer it, so a guest finding no
    /// option 3 in our SYN-ACK must keep its window under 64 KiB however much
    /// buffer it has. That ceiling, divided by the round-trip time, is the most
    /// the connection can ever carry.
    @Test func `window scaling is negotiated and the guest's field read at its true size`() throws {
        // The option survives a round trip before anything else is meaningful.
        let offered = VPhoneTCPSegment(
            sourcePort: 1, destinationPort: 2,
            sequenceNumber: 0, acknowledgmentNumber: 0,
            flags: VPhoneTCPFlags.syn,
            windowSize: 65535,
            advertisedMSS: 1460,
            advertisedWindowScale: 7,
        )
        let encoded = offered.bytes(
            source: VPhoneIPv4Address.any,
            destination: VPhoneIPv4Address.any,
        )
        let decoded = try #require(VPhoneTCPSegment(bytes: encoded))
        #expect(decoded.maximumSegmentSize == 1460, "MSS did not survive the round trip")
        #expect(decoded.windowScale == 7, "window scale did not survive the round trip")
        #expect(encoded[12] >> 4 == 7, "the option list must pad to a 32-bit boundary")

        let total = 400_000
        let blob = [UInt8](repeating: 0x21, count: 65536)
        let server = try LoopbackServer { client, server in
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &buffer, buffer.count, 0)
            var sent = 0
            while sent < total {
                let written = blob.withUnsafeBytes { raw in
                    send(client, raw.baseAddress, min(raw.count, total - sent), 0)
                }
                if written <= 0 {
                    break
                }
                sent += written
            }
            server.drain(client)
        }
        defer { server.stop() }

        let harness = Harness(guestPort: 51003, destinationPort: server.port)
        harness.start()
        defer { harness.stop() }

        // A guest that offers scaling, then advertises a window field of 512 --
        // which at scale 7 means 64 KiB, not 512 bytes.
        let isn = try handshake(harness, windowScale: 7)
        let synAck = try #require(harness.sent.first { $0.hasSYN && $0.hasACK })
        #expect(synAck.advertisedWindowScale == 7, "we did not offer scaling back")

        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: server.port,
            sequenceNumber: 1001,
            acknowledgmentNumber: isn &+ 1,
            flags: VPhoneTCPFlags.ack | VPhoneTCPFlags.psh,
            windowSize: 512,
            payload: [0x41],
            windowScale: 7,
        ))

        try #require(harness.waitUntil("a scaled window's worth") { harness.sentDataBytes > 512 * 8 })
        #expect(
            harness.sentDataBytes > 512,
            "a scaled window was read as \(harness.sentDataBytes)B, i.e. unscaled",
        )
    }

    // MARK: - Retransmission

    /// A segment the guest never acknowledges stops the connection where it
    /// stands. The link to the guest drops nothing by itself, but that is not the
    /// only way a segment goes unacknowledged, and with no copy kept there is
    /// nothing to send again -- the peer just waits for a timeout.
    @Test func `data the guest does not acknowledge is sent again`() throws {
        let payload = [UInt8](repeating: 0x77, count: 4000)
        let server = try LoopbackServer { client, server in
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &buffer, buffer.count, 0)
            _ = payload.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            server.drain(client)
        }
        defer { server.stop() }

        let harness = Harness(guestPort: 51004, destinationPort: server.port)
        harness.start()
        defer { harness.stop() }

        let isn = try handshake(harness)
        request(harness, acknowledged: isn &+ 1) // and never acknowledge the reply

        try #require(harness.waitUntil("the first data") { harness.sentDataBytes > 0 })
        let nudged = harness.waitUntil("the data to be sent again", timeout: 6) {
            var counts: [UInt32: Int] = [:]
            for segment in harness.sent where !segment.payload.isEmpty {
                counts[segment.sequenceNumber, default: 0] += 1
            }
            return counts.values.contains { $0 > 1 }
        }
        #expect(nudged, "nothing was ever sent twice, so a lost segment would stall forever")
    }

    // MARK: - Idle connections

    /// An ssh session nobody types into sends nothing. Reaped after 120 s of
    /// silence, it dropped two to four minutes after its user stopped typing.
    @Test func `an established connection survives minutes of silence`() throws {
        let server = try LoopbackServer { client, server in server.drain(client) }
        defer { server.stop() }

        let harness = Harness(guestPort: 51006, destinationPort: server.port)
        harness.start()
        defer { harness.stop() }

        try handshake(harness)
        #expect(harness.connectionCount == 1)

        harness.reap(after: 30 * 60)
        #expect(harness.connectionCount == 1, "an idle established connection was reaped after 30 minutes")

        harness.reap(after: 3 * 3600)
        #expect(harness.connectionCount == 0, "a connection silent for three hours was kept")
    }

    /// A handshake the guest never finished still goes after the short bound.
    @Test func `a half-open connection is still reaped quickly`() throws {
        let server = try LoopbackServer { client, server in server.drain(client) }
        defer { server.stop() }

        let harness = Harness(guestPort: 51007, destinationPort: server.port)
        harness.start()
        defer { harness.stop() }

        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: server.port,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            flags: VPhoneTCPFlags.syn,
            windowSize: 65535,
            maximumSegmentSize: 1460,
        ))
        try #require(harness.waitUntil("the SYN-ACK") { harness.ourISN != nil })
        #expect(harness.connectionCount == 1)

        harness.reap(after: 180)
        #expect(harness.connectionCount == 0, "a handshake left unanswered for three minutes was kept")
    }

    // MARK: - Throughput

    /// The send path should not be the limit. Not a benchmark -- a guard that a
    /// change to windowing or retransmission has not made it one.
    @Test func `a promptly acknowledging guest gets the payload fast`() throws {
        let total = 4 << 20
        let blob = [UInt8](repeating: 0x33, count: 65536)
        let server = try LoopbackServer { client, server in
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &buffer, buffer.count, 0)
            var sent = 0
            while sent < total {
                let written = blob.withUnsafeBytes { raw in
                    send(client, raw.baseAddress, min(raw.count, total - sent), 0)
                }
                if written <= 0 {
                    break
                }
                sent += written
            }
            server.drain(client, until: total)
        }
        defer { server.stop() }

        let harness = Harness(guestPort: 51005, destinationPort: server.port)
        harness.acknowledgeImmediately()
        harness.start()
        defer { harness.stop() }

        let isn = try handshake(harness)
        request(harness, acknowledged: isn &+ 1)

        let started = Date()
        harness.waitUntil("the payload", timeout: 25) { harness.sentDataBytes >= total }
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        let kibibytesPerSecond = Double(harness.sentDataBytes) / 1024 / elapsed
        #expect(
            harness.sentDataBytes >= total,
            "stalled at \(harness.sentDataBytes / 1024) KiB of \(total / 1024) KiB",
        )
        #expect(
            kibibytesPerSecond > 2048,
            "the send path only managed \(Int(kibibytesPerSecond)) KiB/s",
        )
    }

    // MARK: - SOCKS upstream routing (TASK-003)

    /// A failed resolution fails closed, and stays that way until a later
    /// VM start re-resolves. Distinct from nil (disabled), which connects direct.
    @Test func `a failed upstream fails closed`() async throws {
        let destinationConnected = Box(false)
        let destination = try LoopbackServer { _, _ in destinationConnected.withLock { $0 = true } }
        defer { destination.stop() }

        let harness = Harness(guestPort: 51102, destinationPort: destination.port, upstream: .failed)
        harness.start()
        defer { harness.stop() }

        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: harness.flow.destinationPort,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            flags: VPhoneTCPFlags.syn,
            windowSize: 65535,
        ))

        #expect(harness.waitUntil("a reset") { harness.sent.contains { $0.hasRST } })
        #expect(harness.connectionCount == 0)
        usleep(100000)
        #expect(!destinationConnected.withLock { $0 })
    }

    /// A resolved upstream routes every flow through the proxy, never to the
    /// original destination: the proxy socket is connected and the destination
    /// is left untouched.
    @Test func `a resolved upstream connects the proxy, not the destination`() async throws {
        let proxyConnected = Box(false)
        let proxy = try LoopbackServer { _, _ in proxyConnected.withLock { $0 = true } }
        defer { proxy.stop() }
        let destinationConnected = Box(false)
        let destination = try LoopbackServer { _, _ in destinationConnected.withLock { $0 = true } }
        defer { destination.stop() }

        let harness = Harness(
            guestPort: 51103,
            destinationPort: destination.port,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil),
        )
        harness.start()
        defer { harness.stop() }

        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: harness.flow.destinationPort,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            flags: VPhoneTCPFlags.syn,
            windowSize: 65535,
        ))

        #expect(harness.waitUntil("the proxy connection") { proxyConnected.withLock { $0 } })
        #expect(!destinationConnected.withLock { $0 })
    }

    // MARK: - SOCKS5 handshake (TASK-004)

    /// A scriptable multi-connection SOCKS5 proxy for the handshake tests.
    ///
    /// Its `Behavior` covers the method it selects in the greeting, whether it
    /// reads and answers an RFC 1929 auth frame (and with what status), where (if
    /// anywhere) it falls silent for a deadline test, and how it frames the
    /// CONNECT reply.
    final class SOCKSStub: @unchecked Sendable {
        /// How far the proxy gets before going silent, for the deadline tests.
        enum Stall: Sendable {
            case none
            /// Accept the TCP connection, then read and answer nothing.
            case afterAccept
            /// Answer the greeting (no-auth), then stay silent (no CONNECT reply).
            case afterGreeting
            /// Select `02`, read the auth frame, then stay silent (no status).
            case afterAuth
            /// Complete greeting (and auth), read the CONNECT, then stay silent.
            case afterConnectRequest
        }

        /// How the proxy frames — or mis-frames — the CONNECT reply.
        enum ConnectReply: Sendable {
            /// A 10-byte IPv4 bind reply, then this trailing payload.
            case ipv4(trailing: [UInt8])
            /// A 22-byte IPv6 (ATYP 04) bind reply.
            case ipv6
            /// Only 6 of the 10 IPv4 reply bytes, then close.
            case truncated
            /// VER != 05.
            case badVersion
            /// REP != 00.
            case badRep
            /// An ATYP the forwarder does not recognise.
            case unknownAtyp
        }

        /// The full script for one stub. Defaults to a no-auth proxy that
        /// succeeds with an empty payload.
        struct Behavior: Sendable {
            /// The method byte returned in the greeting reply (`00`, `02`, `FF`).
            var greetingMethod: UInt8 = 0x00
            /// When the selected method is `02`, read the RFC 1929 frame and
            /// answer `01 <authStatus>`.
            var expectAuth = false
            var authStatus: UInt8 = 0x00
            var connect: ConnectReply = .ipv4(trailing: [])
            var stall: Stall = .none
        }

        enum Error: Swift.Error { case setupFailed }

        let port: UInt16
        private let recordedConnect = Box<[UInt8]?>(nil)
        private let recordedAuth = Box<[UInt8]?>(nil)
        private let stopped = Box(false)

        /// The first CONNECT request the proxy received, VER…PORT.
        var connectRequest: [UInt8]? { recordedConnect.withLock { $0 } }
        /// The first RFC 1929 auth frame the proxy received, VER…PASS, or nil if
        /// none was sent.
        var authFrame: [UInt8]? { recordedAuth.withLock { $0 } }

        /// Convenience for the common "just frame the CONNECT reply this way" case.
        convenience init(_ connect: ConnectReply, maxConnections: Int = 1) throws {
            try self.init(Behavior(connect: connect), maxConnections: maxConnections)
        }

        init(_ behavior: Behavior, maxConnections: Int = 1) throws {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Error.setupFailed }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(descriptor, 512) == 0 else { throw Error.setupFailed }
            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            port = UInt16(bigEndian: assigned.sin_port)

            let connect = recordedConnect
            let auth = recordedAuth
            let stopped = stopped
            Thread {
                defer { close(descriptor) }
                var accepted = 0
                while accepted < maxConnections {
                    var listening = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    while poll(&listening, 1, 50) <= 0 {
                        if stopped.withLock({ $0 }) { return }
                    }
                    let client = accept(descriptor, nil, nil)
                    guard client >= 0 else { continue }
                    accepted += 1
                    Thread {
                        defer { close(client) }
                        Self.serve(client, behavior: behavior, connect: connect, auth: auth)
                    }.start()
                }
                // Keep the listener open so pending connects stay admitted.
                while !stopped.withLock({ $0 }) { usleep(20000) }
            }.start()
        }

        func stop() { stopped.withLock { $0 = true } }

        private static func readExactly(_ client: Int32, _ count: Int) -> [UInt8]? {
            var out: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: count)
            while out.count < count {
                let got = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, count - out.count, 0) }
                if got <= 0 { return nil }
                out += buffer[0 ..< got]
            }
            return out
        }

        private static func writeAll(_ client: Int32, _ bytes: [UInt8]) {
            var offset = 0
            while offset < bytes.count {
                let wrote = bytes[offset...].withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                if wrote <= 0 { return }
                offset += wrote
            }
        }

        /// Block, discarding anything the peer sends, until it closes.
        private static func holdOpen(_ client: Int32) {
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let got = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
                if got <= 0 { return }
            }
        }

        private static func serve(_ client: Int32, behavior: Behavior, connect: Box<[UInt8]?>, auth: Box<[UInt8]?>) {
            if case .afterAccept = behavior.stall { holdOpen(client); return }

            // Greeting: VER NMETHODS METHODS…
            guard let head = readExactly(client, 2), head[0] == 0x05 else { return }
            guard readExactly(client, Int(head[1])) != nil else { return }
            writeAll(client, [0x05, behavior.greetingMethod])
            if behavior.greetingMethod == 0xFF { return }
            if case .afterGreeting = behavior.stall { holdOpen(client); return }

            if behavior.greetingMethod == 0x02, behavior.expectAuth {
                // RFC 1929: VER ULEN user PLEN pass.
                guard let authHead = readExactly(client, 2), authHead[0] == 0x01 else { return }
                guard let user = readExactly(client, Int(authHead[1])),
                      let plenByte = readExactly(client, 1),
                      let password = readExactly(client, Int(plenByte[0]))
                else { return }
                auth.withLock { if $0 == nil { $0 = authHead + user + plenByte + password } }
                if case .afterAuth = behavior.stall { holdOpen(client); return }
                writeAll(client, [0x01, behavior.authStatus])
                if behavior.authStatus != 0x00 { holdOpen(client); return }
            }

            guard let request = readExactly(client, 10) else { return }
            connect.withLock { if $0 == nil { $0 = request } }
            if case .afterConnectRequest = behavior.stall { holdOpen(client); return }

            switch behavior.connect {
            case let .ipv4(trailing):
                writeAll(client, [0x05, 0x00, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x00] + trailing)
                holdOpen(client)
            case .ipv6:
                writeAll(client, [0x05, 0x00, 0x00, 0x04] + [UInt8](repeating: 0, count: 16) + [0x00, 0x00])
                holdOpen(client)
            case .truncated:
                writeAll(client, [0x05, 0x00, 0x00, 0x01, 0x7F, 0x00]) // 6 of 10, then close
            case .badVersion:
                writeAll(client, [0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            case .badRep:
                writeAll(client, [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            case .unknownAtyp:
                writeAll(client, [0x05, 0x00, 0x00, 0x09, 0, 0, 0, 0, 0, 0])
            }
        }
    }

    /// Drives many flows through one forwarder, recording which guest ports got
    /// a reset, for the connection-ceiling and fail-closed tests.
    private final class MultiFlowDriver: @unchecked Sendable {
        let forwarder: VPhoneTCPForwarder
        private let queue: DispatchQueue
        private let resets = Box<Set<UInt16>>([])

        init(
            upstream: VPhoneSOCKSUpstream,
            handshakeTimeout: TimeInterval = 10,
            socksLog: (@Sendable (String) -> Void)? = nil,
        ) {
            let queue = DispatchQueue(label: "multiflow")
            self.queue = queue
            let resets = resets
            forwarder = VPhoneTCPForwarder(
                queue: queue,
                upstream: upstream,
                handshakeTimeout: handshakeTimeout,
                socksLog: socksLog,
            ) { flow, segment in
                if segment.hasRST { resets.withLock { _ = $0.insert(flow.sourcePort) } }
            }
        }

        func start() { queue.sync { forwarder.start() } }
        func stop() { queue.sync { forwarder.stop() } }

        func openFlow(guestPort: UInt16, destinationPort: UInt16 = 443) {
            let flow = VPhoneTCPFlow(
                sourceAddress: VPhoneUserspaceNetworkConfiguration.default.guestAddress,
                sourcePort: guestPort,
                destinationAddress: VPhoneIPv4Address(127, 0, 0, 1),
                destinationPort: destinationPort,
                guestHardware: VPhoneMACAddress([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]),
            )
            queue.sync {
                forwarder.receive(VPhoneTCPSegment(
                    sourcePort: guestPort,
                    destinationPort: destinationPort,
                    sequenceNumber: 1000,
                    acknowledgmentNumber: 0,
                    flags: VPhoneTCPFlags.syn,
                    windowSize: 65535,
                ), for: flow)
            }
        }

        var connectionCount: Int { forwarder.connectionCount }
        func wasReset(_ guestPort: UInt16) -> Bool { resets.withLock { $0.contains(guestPort) } }

        @discardableResult
        func waitUntil(_ what: String, timeout: TimeInterval = 8, _ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate() { return true }
                usleep(10000)
            }
            Issue.record("timed out waiting for \(what)")
            return false
        }
    }

    /// Feed a bare SYN; used by tests that expect a reset rather than a completed
    /// handshake.
    private func openGuestFlow(_ harness: Harness) {
        harness.feed(VPhoneTCPSegment(
            sourcePort: harness.guestPort,
            destinationPort: harness.flow.destinationPort,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            flags: VPhoneTCPFlags.syn,
            windowSize: 65535,
        ))
    }

    /// A proxied flow reaches the original destination through the proxy: the
    /// CONNECT names it, server bytes relay through to the guest, and with no
    /// credentials no RFC 1929 frame is sent.
    @Test func `a proxied flow performs CONNECT for the original destination`() async throws {
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let proxy = try SOCKSStub(.ipv4(trailing: payload))
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52001,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil),
        )
        harness.start()
        defer { harness.stop() }

        try handshake(harness)
        #expect(harness.waitUntil("the relayed payload") { harness.deliveredPayload == payload })

        // CONNECT: VER CMD RSV ATYP + 127.0.0.1 + port 443.
        let expected: [UInt8] = [0x05, 0x01, 0x00, 0x01, 0x7F, 0x00, 0x00, 0x01, 0x01, 0xBB]
        #expect(proxy.connectRequest == expected)
        #expect(proxy.authFrame == nil)
    }

    /// A credentialed upstream whose proxy selects username/password sends the
    /// RFC 1929 frame with the resolved username and password, then proceeds.
    @Test func `a credentialed upstream sends the RFC 1929 frame the proxy reads`() async throws {
        let payload: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        let proxy = try SOCKSStub(SOCKSStub.Behavior(
            greetingMethod: 0x02,
            expectAuth: true,
            connect: .ipv4(trailing: payload),
        ))
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52050,
            destinationPort: 443,
            upstream: .resolved(
                VPhoneIPv4Address(127, 0, 0, 1), proxy.port,
                VPhoneSOCKSCredentials(username: "vm-alpha", password: "s3cret"),
            ),
        )
        harness.start()
        defer { harness.stop() }

        try handshake(harness)
        #expect(harness.waitUntil("the relayed payload") { harness.deliveredPayload == payload })

        let expectedFrame: [UInt8] = [0x01, 0x08] + Array("vm-alpha".utf8) + [0x06] + Array("s3cret".utf8)
        #expect(proxy.authFrame == expectedFrame)
    }

    /// An empty password is a legal RFC 1929 frame (`PLEN = 0`).
    @Test func `an empty password sends a zero-length PLEN frame`() async throws {
        let proxy = try SOCKSStub(SOCKSStub.Behavior(greetingMethod: 0x02, expectAuth: true))
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52053,
            destinationPort: 443,
            upstream: .resolved(
                VPhoneIPv4Address(127, 0, 0, 1), proxy.port,
                VPhoneSOCKSCredentials(username: "u", password: ""),
            ),
        )
        harness.start()
        defer { harness.stop() }

        try handshake(harness)
        #expect(harness.connectionCount == 1)
        #expect(proxy.authFrame == [0x01, 0x01, 0x75, 0x00])
    }

    /// A proxy that fails RFC 1929 auth (`01 01`) resets the guest.
    @Test func `an auth-failure status resets the guest`() async throws {
        let proxy = try SOCKSStub(SOCKSStub.Behavior(greetingMethod: 0x02, expectAuth: true, authStatus: 0x01))
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52051,
            destinationPort: 443,
            upstream: .resolved(
                VPhoneIPv4Address(127, 0, 0, 1), proxy.port,
                VPhoneSOCKSCredentials(username: "u", password: "p"),
            ),
        )
        harness.start()
        defer { harness.stop() }

        openGuestFlow(harness)
        #expect(harness.waitUntil("a reset") { harness.sent.contains { $0.hasRST } })
        #expect(harness.ourISN == nil)
        #expect(harness.waitUntil("teardown") { harness.connectionCount == 0 })
    }

    /// A no-credential upstream whose proxy illegally selects `02` is reset, and
    /// no RFC 1929 frame is ever sent (the greeting only offered no-auth).
    @Test func `a no-credential upstream rejects a username-password selection`() async throws {
        let proxy = try SOCKSStub(SOCKSStub.Behavior(greetingMethod: 0x02))
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52052,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil),
        )
        harness.start()
        defer { harness.stop() }

        openGuestFlow(harness)
        #expect(harness.waitUntil("a reset") { harness.sent.contains { $0.hasRST } })
        #expect(harness.ourISN == nil)
        #expect(harness.waitUntil("teardown") { harness.connectionCount == 0 })
        usleep(100000)
        #expect(proxy.authFrame == nil)
    }

    /// A credentialed upstream whose proxy selects no-auth (`05 00`) proceeds
    /// without sending a frame — attribution is simply unavailable this flow.
    @Test func `a credentialed upstream against a no-auth proxy proceeds without a frame`() async throws {
        let payload: [UInt8] = [0xAB, 0xCD, 0xEF]
        let proxy = try SOCKSStub(SOCKSStub.Behavior(greetingMethod: 0x00, connect: .ipv4(trailing: payload)))
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52054,
            destinationPort: 443,
            upstream: .resolved(
                VPhoneIPv4Address(127, 0, 0, 1), proxy.port,
                VPhoneSOCKSCredentials(username: "vm-alpha", password: "p"),
            ),
        )
        harness.start()
        defer { harness.stop() }

        try handshake(harness)
        #expect(harness.waitUntil("the relayed payload") { harness.deliveredPayload == payload })
        #expect(proxy.authFrame == nil)
    }

    /// A reply with payload in the same burst: the guest gets only the payload,
    /// never the bind-address bytes of the reply.
    @Test func `the bind-address reply never leaks into the guest stream`() async throws {
        let payload = [UInt8](repeating: 0x5A, count: 32)
        let proxy = try SOCKSStub(.ipv4(trailing: payload))
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52002,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil),
        )
        harness.start()
        defer { harness.stop() }

        try handshake(harness)
        #expect(harness.waitUntil("the payload") { harness.deliveredPayload.count >= payload.count })
        #expect(harness.deliveredPayload == payload)
    }

    /// An ATYP-04 (IPv6, 22-byte) bind reply is framed correctly and succeeds.
    @Test func `an IPv6 bind reply is consumed and the handshake succeeds`() async throws {
        let proxy = try SOCKSStub(.ipv6)
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52003,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil),
        )
        harness.start()
        defer { harness.stop() }

        try handshake(harness)
        #expect(harness.connectionCount == 1)
        #expect(harness.deliveredPayload.isEmpty)
    }

    /// A bad greeting method, a bad CONNECT version/reply, an unknown ATYP, or a
    /// truncated reply each reset the guest and relay nothing, and the slot is
    /// released.
    @Test(arguments: [
        SOCKSStub.Behavior(greetingMethod: 0xFF),
        SOCKSStub.Behavior(connect: .badVersion),
        SOCKSStub.Behavior(connect: .badRep),
        SOCKSStub.Behavior(connect: .unknownAtyp),
        SOCKSStub.Behavior(connect: .truncated),
    ]) func `a malformed SOCKS reply resets the guest`(behavior: SOCKSStub.Behavior) async throws {
        let proxy = try SOCKSStub(behavior)
        defer { proxy.stop() }

        let harness = Harness(
            guestPort: 52010,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil),
        )
        harness.start()
        defer { harness.stop() }

        openGuestFlow(harness)
        #expect(harness.waitUntil("a reset") { harness.sent.contains { $0.hasRST } })
        #expect(harness.ourISN == nil)
        #expect(harness.deliveredPayload.isEmpty)
        #expect(harness.waitUntil("teardown") { harness.connectionCount == 0 })
    }

    /// A proxy that refuses the TCP connect resets the guest and releases the
    /// slot, relaying nothing.
    @Test func `a refused proxy connect resets the guest`() async throws {
        // A socket bound but never listening refuses every connect with a RST.
        let refuser = socket(AF_INET, SOCK_STREAM, 0)
        try #require(refuser >= 0)
        defer { close(refuser) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(refuser, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(refuser, $0, &length)
            }
        }
        let refusedPort = UInt16(bigEndian: assigned.sin_port)

        let harness = Harness(
            guestPort: 52060,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), refusedPort, nil),
        )
        harness.start()
        defer { harness.stop() }

        openGuestFlow(harness)
        #expect(harness.waitUntil("a reset") { harness.sent.contains { $0.hasRST } })
        #expect(harness.ourISN == nil)
        #expect(harness.deliveredPayload.isEmpty)
        #expect(harness.waitUntil("teardown") { harness.connectionCount == 0 })
    }

    /// A proxy that accepts then stalls — at the greeting, after auth, or after
    /// reading the CONNECT — is torn down at the single handshake deadline, not
    /// before it, and the slot is released.
    @Test(arguments: [
        SOCKSStub.Behavior(stall: .afterAccept),
        SOCKSStub.Behavior(stall: .afterGreeting),
        SOCKSStub.Behavior(greetingMethod: 0x02, expectAuth: true, stall: .afterAuth),
        SOCKSStub.Behavior(stall: .afterConnectRequest),
    ]) func `a silent proxy is reset at the handshake deadline`(behavior: SOCKSStub.Behavior) async throws {
        let proxy = try SOCKSStub(behavior)
        defer { proxy.stop() }

        let credentials = behavior.greetingMethod == 0x02
            ? VPhoneSOCKSCredentials(username: "u", password: "p")
            : nil
        let harness = Harness(
            guestPort: 52020,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, credentials),
            handshakeTimeout: 0.6,
        )
        harness.start()
        defer { harness.stop() }

        let started = Date()
        openGuestFlow(harness)

        // No reset well before the deadline (scaled stand-in for "not at 9.9s").
        usleep(350000)
        #expect(!harness.sent.contains { $0.hasRST })

        #expect(harness.waitUntil("the deadline reset", timeout: 2) { harness.sent.contains { $0.hasRST } })
        #expect(Date().timeIntervalSince(started) >= 0.5)
        #expect(harness.ourISN == nil)
        #expect(harness.waitUntil("teardown") { harness.connectionCount == 0 })
    }

    /// A connect that never completes (an unroutable proxy address) is torn down
    /// at the same single deadline.
    @Test func `a stalled connect is reset at the handshake deadline`() async throws {
        // TEST-NET-1 (RFC 5737): syntactically routable, never answers, so the
        // non-blocking connect stays in progress until the deadline fires.
        let harness = Harness(
            guestPort: 52070,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(192, 0, 2, 1), 1080, nil),
            handshakeTimeout: 0.6,
        )
        harness.start()
        defer { harness.stop() }

        let started = Date()
        openGuestFlow(harness)

        usleep(350000)
        #expect(!harness.sent.contains { $0.hasRST })

        #expect(harness.waitUntil("the deadline reset", timeout: 2) { harness.sent.contains { $0.hasRST } })
        #expect(Date().timeIntervalSince(started) >= 0.5)
        #expect(harness.waitUntil("teardown") { harness.connectionCount == 0 })
    }

    /// The connection ceiling is unchanged by interception: 256 proxied flows
    /// are admitted, the 257th refused.
    @Test func `the 257th proxied flow is refused`() async throws {
        let proxy = try SOCKSStub(.ipv4(trailing: []), maxConnections: 300)
        defer { proxy.stop() }

        let driver = MultiFlowDriver(upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil))
        driver.start()
        defer { driver.stop() }

        for index in 0 ..< 257 {
            driver.openFlow(guestPort: UInt16(20000 + index))
        }

        #expect(driver.connectionCount == 256)
        #expect(driver.wasReset(UInt16(20000 + 256)))
    }

    /// A `.failed` upstream fails every flow closed and the forwarder logs
    /// nothing (the single resolution-failure line is logged elsewhere, at start).
    @Test func `a failed upstream resets every flow and logs nothing`() async throws {
        let lines = Box<[String]>([])
        let driver = MultiFlowDriver(
            upstream: .failed,
            socksLog: { line in lines.withLock { $0.append(line) } },
        )
        driver.start()
        defer { driver.stop() }

        for index in 0 ..< 5 { driver.openFlow(guestPort: UInt16(33000 + index)) }
        driver.waitUntil("every flow reset") { (0 ..< 5).allSatisfy { driver.wasReset(UInt16(33000 + $0)) } }
        #expect(driver.connectionCount == 0)
        #expect(lines.withLock { $0 }.isEmpty)
    }

    /// A per-flow handshake failure against a `.resolved` upstream logs exactly
    /// one line naming that endpoint, with the SOCKS reply code.
    @Test func `a handshake failure logs one line naming the endpoint`() async throws {
        let proxy = try SOCKSStub(.badRep)
        defer { proxy.stop() }

        let lines = Box<[String]>([])
        let harness = Harness(
            guestPort: 52030,
            destinationPort: 443,
            upstream: .resolved(VPhoneIPv4Address(127, 0, 0, 1), proxy.port, nil),
            socksLog: { line in lines.withLock { $0.append(line) } },
        )
        harness.start()
        defer { harness.stop() }

        openGuestFlow(harness)
        #expect(harness.waitUntil("a reset") { harness.sent.contains { $0.hasRST } })
        #expect(harness.waitUntil("a log line") { !lines.withLock { $0 }.isEmpty })
        usleep(100000)
        let captured = lines.withLock { $0 }
        #expect(captured.count == 1)
        let line = captured.first ?? ""
        #expect(line.contains("127.0.0.1:\(proxy.port)"))
        #expect(line.contains("0x01"))
    }
}
