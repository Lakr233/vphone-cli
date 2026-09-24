import Foundation
import NIOCore
import NIOWebSocket

final class GuestWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let hub: APIEventHub
    init(hub: APIEventHub) {
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        hub.add(context.channel)
        let hello = APIReply.json(["type": "event", "event": "connected", "data": ["api_version": 1]])
        Self.send(hello.data, on: context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var buffer = frame.unmaskedData
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            do {
                let request = try APIWire.decode(Data(bytes))
                let job = WebSocketJob(channel: context.channel, request: request, hub: hub)
                GuestAPI.queue.async { job.run() }
            } catch {
                let reply = APIReply.json(["type": "response", "id": NSNull(),
                                           "error": ["code": "bad_request", "message": String(describing: error)]])
                Self.send(reply.data, on: context.channel)
            }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        hub.remove(context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    fileprivate static func send(_ data: Data, on channel: Channel) {
        let write: @Sendable () -> Void = {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
        }
        if channel.eventLoop.inEventLoop {
            write()
        } else {
            channel.eventLoop.execute(write)
        }
    }
}

private final class WebSocketJob: @unchecked Sendable {
    let channel: Channel
    let request: APIRequest
    let hub: APIEventHub

    init(channel: Channel, request: APIRequest, hub: APIEventHub) {
        self.channel = channel
        self.request = request
        self.hub = hub
    }

    func run() {
        let reply = APIWire.execute(request)
        GuestWebSocketHandler.send(reply.data, on: channel)
        if reply.status == 200 {
            hub.broadcast(name: "operation.completed", data: ["method": request.method])
        }
    }
}
