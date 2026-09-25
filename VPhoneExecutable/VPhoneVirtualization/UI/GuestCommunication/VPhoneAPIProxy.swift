import Darwin
import Foundation
import NIOCore
import NIOPosix
import Security
import Virtualization
import VPhoneCoreKit

/// Transparent TCP-to-VSOCK forwarding for the guest's HTTP/WebSocket API.
/// Each host connection gets its own guest connection, so HTTP upgrades,
/// streaming bodies, and future protocol changes pass through unchanged.
///
/// vphoned runs as root and cannot tell a proxied connection from the VM's
/// own client, so the proxy admits a connection only after its first request
/// head carries the per-launch token (see `VPhoneAPIRequestGate`).
@MainActor
public final class VPhoneAPIProxy {
    public enum ProxyError: Error, CustomStringConvertible {
        case invalidListenAddress(String)
        case invalidToken
        case randomUnavailable(OSStatus)

        public var description: String {
            switch self {
            case let .invalidListenAddress(value):
                "Invalid API listen address '\(value)'; use host:port, for example 127.0.0.1:8765"
            case .invalidToken:
                "\(VPhoneAPIRequestGate.environmentKey) must be 16 to 256 characters of A-Z, a-z, 0-9, '-', '.', '_' or '~'"
            case let .randomUnavailable(status):
                "Could not generate an API token (SecRandomCopyBytes status \(status))"
            }
        }
    }

    private let host: String
    private let port: Int
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let provider: GuestSocketProvider
    private var server: Channel?

    public init(device: VZVirtioSocketDevice, listen: String) throws {
        guard let components = URLComponents(string: "tcp://\(listen)"),
              let host = components.host, !host.isEmpty,
              let port = components.port, (0 ... 65535).contains(port),
              components.path.isEmpty, components.query == nil, components.fragment == nil
        else { throw ProxyError.invalidListenAddress(listen) }
        self.host = host
        self.port = port
        provider = GuestSocketProvider(device: device, group: group)
        if !Self.isLoopback(host) {
            print("[api] warning: \(host) is not a loopback address; other machines can reach the guest API with the token")
        }
    }

    /// Starts only when the boot command explicitly supplied `--api-listen`.
    /// The returned URL contains the actual port when the caller requested 0.
    /// The token is `VPHONE_API_TOKEN` from this process's environment when
    /// set, otherwise 32 random bytes in hex, new for each launch.
    @discardableResult
    public func start() async throws -> (url: URL, token: String) {
        let token = try Self.makeToken()
        // vphoned accepts only a few loopback Host names, and a client names
        // whatever address the proxy listens on (127.0.0.2, a LAN address).
        // The token already admitted the request, so it is always forwarded
        // with `Host: localhost`.
        let forwardedHost = "localhost"
        let provider = provider
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(APIAdmission(token: token, host: forwardedHost, provider: provider))
            }
            .bind(host: host, port: port)
            .get()
        server = channel
        let actualPort = channel.localAddress?.port ?? port
        var url = URLComponents()
        url.scheme = "http"
        url.host = host
        url.port = actualPort
        return (url.url!, token)
    }

    public func stop() {
        server?.close(promise: nil)
        server = nil
        group.shutdownGracefully { error in
            if let error {
                print("[api] proxy shutdown: \(error)")
            }
        }
    }

    // MARK: - Token and Address

    private static func makeToken() throws -> String {
        if let configured = ProcessInfo.processInfo.environment[VPhoneAPIRequestGate.environmentKey],
           !configured.isEmpty
        {
            guard VPhoneAPIRequestGate.isValidToken(configured) else { throw ProxyError.invalidToken }
            return configured
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ProxyError.randomUnavailable(status) }
        return VPhoneAPIRequestGate.hexToken(bytes)
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host.caseInsensitiveCompare("localhost") == .orderedSame {
            return true
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { $0.elementsEqual([UInt8](repeating: 0, count: 15) + [1]) }
        }
        return false
    }
}

// MARK: - Admission

/// The first handler on each accepted host connection. It reads until the
/// request head is complete, then either replies 401 and closes, or asks the
/// provider for a guest connection and hands it the admitted bytes. After
/// that it passes every read straight to the relay behind it.
private final class APIAdmission: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case reading
        case connecting
        case relaying
        case closed
    }

    private let token: String
    private let host: String?
    private let provider: GuestSocketProvider
    private var state = State.reading
    private var received = Data()
    private var pending = Data()
    private var timeout: Scheduled<Void>?

    init(token: String, host: String?, provider: GuestSocketProvider) {
        self.token = token
        self.host = host
        self.provider = provider
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(10)) {
            channel.close(promise: nil)
        }
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        switch state {
        case .relaying:
            context.fireChannelRead(data)
        case .connecting:
            pending.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .closed:
            break
        case .reading:
            received.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            switch VPhoneAPIRequestGate.evaluate(received, token: token, host: host) {
            case .needMore:
                break
            case .reject:
                finish()
                state = .closed
                let channel = context.channel
                var reply = channel.allocator.buffer(capacity: VPhoneAPIRequestGate.unauthorizedResponse.count)
                reply.writeBytes(VPhoneAPIRequestGate.unauthorizedResponse)
                channel.writeAndFlush(reply).whenComplete { _ in
                    channel.close(promise: nil)
                }
            case let .accept(bytes):
                finish()
                state = .connecting
                pending = bytes
                provider.attach(context.channel, admission: self)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if state == .reading {
            context.read()
        }
        context.fireChannelReadComplete()
    }

    /// Called on the host event loop once the relay is in the pipeline:
    /// returns the admitted bytes, and later reads pass through.
    func beginRelay() -> Data {
        state = .relaying
        defer { pending = Data() }
        return pending
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        state = .closed
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    private func finish() {
        timeout?.cancel()
        timeout = nil
        received = Data()
    }
}

// MARK: - Guest Connection

private final class GuestSocketProvider: @unchecked Sendable {
    private let device: VZVirtioSocketDevice
    private let group: EventLoopGroup
    private let guestPort: UInt32 = 1339

    init(device: VZVirtioSocketDevice, group: EventLoopGroup) {
        self.device = device
        self.group = group
    }

    /// Connects an admitted host channel to a new guest connection. The
    /// admitted request head is written first, then both sides relay.
    func attach(_ host: Channel, admission: APIAdmission) {
        Task { @MainActor in
            device.connect(toPort: guestPort) { result in
                Task { @MainActor in
                    switch result {
                    case let .failure(error):
                        print("[api] guest connection failed: \(error)")
                        host.close(promise: nil)
                    case let .success(connection):
                        let fd = dup(connection.fileDescriptor)
                        guard fd >= 0 else {
                            host.close(promise: nil)
                            return
                        }
                        let guestRelay = ByteRelay(connection: connection)
                        let hostRelay = ByteRelay(connection: connection)
                        ClientBootstrap(group: self.group)
                            .channelOption(ChannelOptions.autoRead, value: false)
                            .channelInitializer { guest in guest.pipeline.addHandler(guestRelay) }
                            .withConnectedSocket(fd)
                            .flatMap { guest -> EventLoopFuture<Void> in
                                guestRelay.peer = host
                                hostRelay.peer = guest
                                return host.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
                                    guard host.isActive else {
                                        return host.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                                    }
                                    do {
                                        try host.pipeline.syncOperations.addHandler(hostRelay)
                                    } catch {
                                        return host.eventLoop.makeFailedFuture(error)
                                    }
                                    hostRelay.forward(admission.beginRelay())
                                    return host.setOption(ChannelOptions.autoRead, value: guest.isWritable)
                                        .flatMap {
                                            guest.setOption(ChannelOptions.autoRead, value: host.isWritable)
                                        }
                                }
                                .flatMapError { error in
                                    guest.close(promise: nil)
                                    return host.eventLoop.makeFailedFuture(error)
                                }
                            }
                            .whenFailure { error in
                                print("[api] guest relay failed: \(error)")
                                host.close(promise: nil)
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Relay

private final class ByteRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    // Keeping this object alive also keeps Virtualization.framework's original
    // socket descriptor alive while NIO owns its duplicated descriptor.
    private let connection: VZVirtioSocketConnection
    private let lock = NSLock()
    private var _peer: Channel?
    private var lastWrite: EventLoopFuture<Void>?

    var peer: Channel? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _peer
        }
        set {
            lock.lock()
            _peer = newValue
            lock.unlock()
        }
    }

    init(connection: VZVirtioSocketConnection) {
        self.connection = connection
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        guard let peer else { return }
        lastWrite = peer.writeAndFlush(unwrapInboundIn(data))
    }

    /// Sends bytes read before this relay joined the pipeline. Call it on
    /// this relay's event loop, before its channel reads again.
    func forward(_ bytes: Data) {
        guard !bytes.isEmpty, let peer else { return }
        var buffer = peer.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        lastWrite = peer.writeAndFlush(buffer)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        _ = peer?.setOption(ChannelOptions.autoRead, value: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        let other = _peer
        _peer = nil
        lock.unlock()
        if let other {
            if let lastWrite {
                // A close can follow the last TCP chunk before the other event
                // loop has written it. Drain that write before closing its socket.
                let timeout = context.eventLoop.scheduleTask(in: .seconds(5)) {
                    other.close(promise: nil)
                }
                lastWrite.whenComplete { _ in
                    timeout.cancel()
                    other.close(promise: nil)
                }
            } else {
                other.close(promise: nil)
            }
        }
        lastWrite = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }
}
