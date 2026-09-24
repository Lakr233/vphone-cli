import Darwin
import Foundation
import NIOCore
import NIOPosix
import Virtualization

/// Transparent TCP-to-VSOCK forwarding for the guest's HTTP/WebSocket API.
/// Each host connection gets its own guest connection, so HTTP upgrades,
/// streaming bodies, and future protocol changes pass through unchanged.
@MainActor
public final class VPhoneAPIProxy {
    public enum ProxyError: Error, CustomStringConvertible {
        case invalidListenAddress(String)

        public var description: String {
            switch self {
            case .invalidListenAddress(let value):
                "Invalid API listen address '\(value)'; use host:port, for example 127.0.0.1:8765"
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
              let port = components.port, (0...65535).contains(port),
              components.path.isEmpty, components.query == nil, components.fragment == nil
        else { throw ProxyError.invalidListenAddress(listen) }
        self.host = host
        self.port = port
        self.provider = GuestSocketProvider(device: device, group: group)
    }

    /// Starts only when the boot command explicitly supplied `--api-listen`.
    /// The returned URL contains the actual port when the caller requested 0.
    @discardableResult
    public func start() async throws -> URL {
        let provider = self.provider
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in provider.attach(channel) }
            .bind(host: host, port: port)
            .get()
        server = channel
        let actualPort = channel.localAddress?.port ?? port
        var url = URLComponents()
        url.scheme = "http"
        url.host = host
        url.port = actualPort
        return url.url!
    }

    public func stop() {
        server?.close(promise: nil)
        server = nil
        group.shutdownGracefully { error in
            if let error { print("[api] proxy shutdown: \(error)") }
        }
    }
}

private final class GuestSocketProvider: @unchecked Sendable {
    private let device: VZVirtioSocketDevice
    private let group: EventLoopGroup
    private let guestPort: UInt32 = 1339

    init(device: VZVirtioSocketDevice, group: EventLoopGroup) {
        self.device = device
        self.group = group
    }

    func attach(_ host: Channel) -> EventLoopFuture<Void> {
        let promise = host.eventLoop.makePromise(of: Void.self)
        Task { @MainActor in
            device.connect(toPort: guestPort) { result in
                Task { @MainActor in
                    switch result {
                    case .failure(let error):
                        print("[api] guest connection failed: \(error)")
                        promise.fail(error)
                    case .success(let connection):
                        let fd = dup(connection.fileDescriptor)
                        guard fd >= 0 else {
                            promise.fail(POSIXError(.EBADF))
                            return
                        }
                        let guestRelay = ByteRelay(connection: connection)
                        let hostRelay = ByteRelay(connection: connection)
                        ClientBootstrap(group: self.group)
                            .channelInitializer { guest in guest.pipeline.addHandler(guestRelay) }
                            .withConnectedSocket(fd)
                            .flatMap { guest in
                                guestRelay.peer = host
                                hostRelay.peer = guest
                                return host.pipeline.addHandler(hostRelay)
                            }
                            .whenComplete { result in
                                switch result {
                                case .success:
                                    host.setOption(ChannelOptions.autoRead, value: true).cascade(to: promise)
                                case .failure(let error):
                                    print("[api] guest relay failed: \(error)")
                                    promise.fail(error)
                                }
                            }
                    }
                }
            }
        }
        return promise.futureResult
    }
}

private final class ByteRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    // Keeping this object alive also keeps Virtualization.framework's original
    // socket descriptor alive while NIO owns its duplicated descriptor.
    private let connection: VZVirtioSocketConnection
    private let lock = NSLock()
    private var _peer: Channel?

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

    init(connection: VZVirtioSocketConnection) { self.connection = connection }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let peer else { return }
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
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
        other?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
