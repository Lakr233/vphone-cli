import NIOCore
import NIOPosix
import NIOWebSocket

/// A WebSocket binary frame is one chunk of the guest TCP byte stream.
/// Connections are limited to loopback; callers cannot select another host.
final class GuestPortForwardHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let port: Int
    private var backend: Channel?
    private var pending: [ByteBuffer] = []
    private var pendingBytes = 0
    private let maximumPendingBytes = 1 << 20
    private var lastBackendWrite: EventLoopFuture<Void>?
    private var closing = false

    init(port: Int) {
        self.port = port
    }

    static func port(from uri: String) -> Int? {
        let prefix = "/v1/ports/"
        guard uri.hasPrefix(prefix) else { return nil }
        let digits = uri.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let port = Int(digits), (1 ... 65535).contains(port)
        else { return nil }
        return port
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let webSocket = context.channel
        _ = webSocket.setOption(ChannelOptions.autoRead, value: false)
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(5))
            .channelInitializer { [weak self] backend in
                backend.pipeline.addHandler(GuestPortBackendHandler(webSocket: webSocket) { [weak self] in
                    self?.closing == false
                })
            }
            .connect(host: "127.0.0.1", port: port)
            .whenComplete { result in
                guard webSocket.isActive, !self.closing else {
                    if case let .success(backend) = result { backend.close(promise: nil) }
                    return
                }
                switch result {
                case let .success(backend):
                    self.backend = backend
                    for chunk in self.pending.dropLast() { backend.write(chunk, promise: nil) }
                    if let chunk = self.pending.last {
                        self.lastBackendWrite = backend.writeAndFlush(chunk)
                        self.lastBackendWrite?.whenFailure { _ in self.closeWithError(on: webSocket) }
                    }
                    self.pending.removeAll()
                    self.pendingBytes = 0
                    _ = webSocket.setOption(ChannelOptions.autoRead, value: backend.isWritable)
                case .failure:
                    self.closeWithError(on: webSocket)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard !closing else { return }
        switch frame.opcode {
        case .binary:
            let chunk = frame.unmaskedData
            if let backend {
                lastBackendWrite = backend.writeAndFlush(chunk)
                let webSocket = context.channel
                lastBackendWrite?.whenFailure { _ in self.closeWithError(on: webSocket) }
            } else {
                pendingBytes += chunk.readableBytes
                guard pendingBytes <= maximumPendingBytes else {
                    closeWithError(on: context.channel)
                    return
                }
                pending.append(chunk)
            }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong,
                                                                  data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            closing = true
            let webSocket = context.channel
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose,
                                                                  data: frame.unmaskedData))).whenComplete { _ in
                webSocket.close(promise: nil)
            }
        default:
            closeWithError(on: context.channel)
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        _ = backend?.setOption(ChannelOptions.autoRead, value: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        closing = true
        if let backend {
            if let lastBackendWrite {
                // A WebSocket close can arrive in the same read as the final data
                // frame. Let NIO flush those bytes before closing the TCP socket.
                let timeout = context.eventLoop.scheduleTask(in: .seconds(5)) {
                    backend.close(promise: nil)
                }
                lastBackendWrite.whenComplete { _ in
                    timeout.cancel()
                    backend.close(promise: nil)
                }
            } else {
                backend.close(promise: nil)
            }
        }
        backend = nil
        lastBackendWrite = nil
        pending.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    private func closeWithError(on channel: Channel) {
        guard !closing, channel.isActive else { return }
        closing = true
        var data = channel.allocator.buffer(capacity: 2)
        data.writeInteger(UInt16(1011), endianness: .big)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose,
                                             data: data)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

private final class GuestPortBackendHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let webSocket: Channel
    let shouldForward: @Sendable () -> Bool
    private var lastWrite: EventLoopFuture<Void>?

    init(webSocket: Channel, shouldForward: @escaping @Sendable () -> Bool) {
        self.webSocket = webSocket
        self.shouldForward = shouldForward
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        guard webSocket.isActive, shouldForward() else { return }
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: unwrapInboundIn(data))
        lastWrite = webSocket.writeAndFlush(frame)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        _ = webSocket.setOption(ChannelOptions.autoRead, value: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let lastWrite {
            lastWrite.whenComplete { _ in self.closeWebSocket() }
        } else {
            closeWebSocket()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    private func closeWebSocket() {
        guard webSocket.isActive, shouldForward() else { return }
        var data = webSocket.allocator.buffer(capacity: 2)
        data.writeInteger(UInt16(1000), endianness: .big)
        webSocket.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose,
                                               data: data)).whenComplete { _ in
            self.webSocket.close(promise: nil)
        }
    }
}
