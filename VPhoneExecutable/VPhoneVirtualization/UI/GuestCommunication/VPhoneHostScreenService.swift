import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import Virtualization
import VPhoneCoreKit

// MARK: - Host Screen Service

/// Serves `GET /v1/host/screen` on the API proxy (`VPhoneHostScreenProtocol`):
/// frames of the VM's own display, encoded in this process. The guest takes no
/// screenshot for it; it is asked only for its interface orientation, about
/// once a second while a stream runs.
@MainActor
final class VPhoneHostScreenService {
    private let display: @MainActor () -> VZGraphicsDisplay?
    private let interfaceDegrees: @MainActor () async -> Int?
    /// Image pixels per interface point of the upright display.
    nonisolated let scale: Double

    private var degrees = 0
    /// The first answer, or failure, has come back.
    private var answered = false
    private var checking = false
    private var checkedAt: UInt64 = 0

    init(
        scale: Double,
        display: @escaping @MainActor () -> VZGraphicsDisplay?,
        interfaceDegrees: @escaping @MainActor () async -> Int?,
    ) {
        self.scale = scale
        self.display = display
        self.interfaceDegrees = interfaceDegrees
    }

    /// The current frame and how far it turns clockwise to stand upright.
    func capture() async -> (image: CGImage, turn: Int)? {
        await refreshOrientation()
        guard let display = display(), let image = await VPhoneGraphicsDisplayCapture.capture(display) else {
            return nil
        }
        return (image, VPhoneHostScreenProtocol.clockwiseTurn(forInterfaceDegrees: degrees))
    }

    /// The guest is asked at most once a second, behind the frames. Only the
    /// first frame waits for the answer, briefly, so a landscape guest does not
    /// start with a sideways session; a guest that does not answer keeps the
    /// last value (portrait at first).
    private func refreshOrientation() async {
        let now = DispatchTime.now().uptimeNanoseconds
        if !checking, !answered || now - checkedAt >= 1_000_000_000 {
            checking = true
            checkedAt = now
            Task { @MainActor in
                if let value = await self.interfaceDegrees() {
                    self.degrees = value
                }
                self.answered = true
                self.checking = false
            }
        }
        for _ in 0 ..< 50 where !answered {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Pipeline

    /// Takes over a connection the proxy admitted for the screen route: the
    /// admitted head goes through an HTTP server pipeline that upgrades it to
    /// a WebSocket. Call on the channel's event loop, before it reads again.
    nonisolated func attach(_ context: ChannelHandlerContext, admitted: Data) throws {
        let service = self
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 16,
            shouldUpgrade: { channel, request in
                // A client that gave the proxy its token as a subprotocol
                // expects the server to select that protocol, as vphoned does.
                var headers = HTTPHeaders()
                if let offered = request.headers[canonicalForm: "Sec-WebSocket-Protocol"]
                    .first(where: { $0.hasPrefix(VPhoneAPIRequestGate.webSocketProtocolPrefix) })
                {
                    headers.add(name: "Sec-WebSocket-Protocol", value: String(offered))
                }
                return channel.eventLoop.makeSucceededFuture(headers)
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1,
                            maxAccumulatedFrameCount: 8,
                            maxAccumulatedFrameSize: 1 << 16,
                        ),
                        HostScreenSocket(service: service),
                    ])
                }
            },
        )
        let refusal = HostScreenRefusal()
        let sync = context.pipeline.syncOperations
        try sync.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: [upgrader], completionHandler: { context in
                context.pipeline.syncOperations.removeHandler(refusal, promise: nil)
            }),
        )
        try sync.addHandler(refusal)
        var buffer = context.channel.allocator.buffer(capacity: admitted.count)
        buffer.writeBytes(admitted)
        context.fireChannelRead(NIOAny(buffer))
    }
}

// MARK: - Refusal

/// Answers a request on the screen route that is not a WebSocket upgrade.
private final class HostScreenRefusal: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head = unwrapInboundIn(data) else { return }
        let body = #"{"error":{"code":"upgrade_required","message":"/v1/host/screen is a WebSocket"}}"#
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: .upgradeRequired, headers: headers)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        let channel = context.channel
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

// MARK: - Socket

/// One client. Requests are answered one at a time, in order: each takes a
/// frame on the main actor and encodes it on this client's queue.
private final class HostScreenSocket: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    /// A client keeps one or two requests outstanding; more than this is one
    /// that does not wait for answers.
    private static let maximumQueued = 16

    private let service: VPhoneHostScreenService
    private let work = DispatchQueue(label: "vphone.hostscreen.encode")
    private let encoder = VPhoneHostScreenEncoder()
    private let lock = NSLock()
    private var queued: [VPhoneHostScreenProtocol.Request] = []
    private var busy = false
    private var closed = false
    private var channel: Channel?

    init(service: VPhoneHostScreenService) {
        self.service = service
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var buffer = frame.unmaskedData
            let bytes = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
            do {
                enqueue(try VPhoneHostScreenProtocol.parse(bytes))
            } catch {
                send(VPhoneHostScreenProtocol.errorMessage(id: nil, code: error.code, message: error.description))
            }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            let channel = context.channel
            let echo = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(echo)).whenComplete { _ in
                channel.close(promise: nil)
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.withLock {
            closed = true
            queued.removeAll()
        }
        work.async { [encoder] in
            encoder.close()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    private func enqueue(_ request: VPhoneHostScreenProtocol.Request) {
        let start = lock.withLock { () -> Bool? in
            guard !closed else { return nil }
            guard queued.count < Self.maximumQueued else { return nil }
            queued.append(request)
            guard !busy else { return false }
            busy = true
            return true
        }
        switch start {
        case nil:
            send(VPhoneHostScreenProtocol.errorMessage(id: request.id, code: "too_many_requests",
                                                       message: "at most \(Self.maximumQueued) requests may wait"))
        case true?:
            next()
        case false?:
            break
        }
    }

    private func next() {
        let request = lock.withLock { () -> VPhoneHostScreenProtocol.Request? in
            guard !closed, !queued.isEmpty else {
                busy = false
                return nil
            }
            return queued.removeFirst()
        }
        guard let request else { return }
        let service = service
        Task { @MainActor in
            let started = DispatchTime.now().uptimeNanoseconds
            let captured = await service.capture()
            let captureMicroseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1000)
            nonisolated(unsafe) let image = captured?.image
            let turn = captured?.turn ?? 0
            self.work.async {
                self.answer(request, image: image, turn: turn, captureMicroseconds: captureMicroseconds)
                self.next()
            }
        }
    }

    private func answer(_ request: VPhoneHostScreenProtocol.Request, image: CGImage?, turn: Int, captureMicroseconds: Int) {
        guard let image else {
            send(VPhoneHostScreenProtocol.errorMessage(id: request.id, code: "display_unavailable",
                                                       message: "the VM display returned no frame"))
            return
        }
        do {
            let result = try encoder.encode(image, request: request, turn: turn)
            var header: [String: Any] = [
                "id": request.id,
                "status": result.status.rawValue,
                "session": result.session,
                "key": result.key,
                "width": result.width,
                "height": result.height,
                "sourceWidth": result.sourceWidth,
                "sourceHeight": result.sourceHeight,
                "scale": service.scale,
                "captureUs": captureMicroseconds,
                "encodeUs": result.encodeMicroseconds,
            ]
            if let record = result.record {
                header["record"] = record.base64EncodedString()
            }
            send(VPhoneHostScreenProtocol.message(header: header, payload: result.payload))
        } catch {
            // The next request starts a fresh session.
            encoder.close()
            send(VPhoneHostScreenProtocol.errorMessage(id: request.id, code: error.code, message: error.description))
        }
    }

    private func send(_ message: Data) {
        guard let channel = lock.withLock({ closed ? nil : channel }) else { return }
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: message.count)
            buffer.writeBytes(message)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer), promise: nil)
        }
    }
}
