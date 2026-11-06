import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

let mode = vp_native_process_mode()
if mode == 2 {
    // A scripting session, spawned by the worker for one script or one
    // interactive session. None of the startup below belongs here; see
    // GuestScriptSession.
    exit(VPhoneDarwinSession.run())
}
if mode != 1 {
    guard mode == 0 else { exit(64) }
    vp_native_bootstrap_cached_binary()
    exit(vp_native_run_proxy())
}

guard vp_native_watch_proxy() == 0 else { exit(1) }
let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
let filePool = NIOThreadPool(numberOfThreads: 2)
filePool.start()
let fileIO = NonBlockingFileIO(threadPool: filePool)
let hub = APIEventHub()

do {
    let server = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 128)
        .childChannelInitializer { channel in
            let http = GuestHyperTextHandler(hub: hub, fileIO: fileIO)
            let upgrader = NIOWebSocketServerUpgrader(
                maxFrameSize: 1 << 20,
                shouldUpgrade: { channel, request in
                    // Browsers apply no CORS to WebSockets; refuse any handshake
                    // that carries Origin or a non-loopback Host. The refused
                    // request then reaches GuestHyperTextHandler, which replies 403.
                    let allowed = GuestHyperTextHandler.isLocalClient(request.headers) &&
                        (request.uri == "/v1/events" || GuestPortForwardHandler.port(from: request.uri) != nil ||
                            GuestShellSessionHandler.request(from: request.uri) != nil)
                    guard allowed else { return channel.eventLoop.makeSucceededFuture(nil) }
                    // A client that gave the host proxy its token as a WebSocket
                    // subprotocol expects the server to select that protocol.
                    var headers = HTTPHeaders()
                    if let offered = request.headers[canonicalForm: "Sec-WebSocket-Protocol"]
                        .first(where: { $0.hasPrefix("vphone-token.") })
                    {
                        headers.add(name: "Sec-WebSocket-Protocol", value: String(offered))
                    }
                    return channel.eventLoop.makeSucceededFuture(headers)
                },
                upgradePipelineHandler: { channel, request in
                    // Add the post-upgrade handlers synchronously on the channel's
                    // event loop (removeHandler's future completes there). Building
                    // them through syncOperations keeps them off any concurrency
                    // boundary, so NIOWebSocketFrameAggregator's unavailable Sendable
                    // conformance is never required. The pipeline is unchanged.
                    channel.pipeline.removeHandler(http).flatMapThrowing {
                        let sync = channel.pipeline.syncOperations
                        if let port = GuestPortForwardHandler.port(from: request.uri) {
                            try sync.addHandlers([
                                NIOWebSocketFrameAggregator(
                                    minNonFinalFragmentSize: 1,
                                    maxAccumulatedFrameCount: 32,
                                    maxAccumulatedFrameSize: 1 << 20,
                                ),
                                GuestPortForwardHandler(port: port),
                            ])
                        } else if let session = GuestShellSessionHandler.request(from: request.uri) {
                            try sync.addHandlers([
                                NIOWebSocketFrameAggregator(
                                    minNonFinalFragmentSize: 1,
                                    maxAccumulatedFrameCount: 32,
                                    maxAccumulatedFrameSize: 1 << 20,
                                ),
                                GuestShellSessionHandler(request: session),
                            ])
                        } else {
                            try sync.addHandlers([
                                NIOWebSocketFrameAggregator(
                                    minNonFinalFragmentSize: 1,
                                    maxAccumulatedFrameCount: 32,
                                    maxAccumulatedFrameSize: 1 << 20,
                                ),
                                GuestWebSocketHandler(hub: hub),
                            ])
                        }
                    }
                },
            )
            return channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
            ).flatMap { channel.pipeline.addHandler(http) }
        }
        .bind(to: VsockAddress(cid: .any, port: 1339))
        .wait()
    vp_native_confirm_cached_binary()
    NSLog("vphoned: HTTP/WebSocket API listening on vsock 1339")
    server.closeFuture.whenComplete { _ in
        DispatchQueue.main.async {
            try? group.syncShutdownGracefully()
            try? filePool.syncShutdownGracefully()
            exit(0)
        }
    }
} catch {
    NSLog("vphoned: HTTP/WebSocket API failed: %@", String(describing: error))
    exit(1)
}

// Keep the main thread available to Foundation callbacks while NIO owns its
// event loops. The timer keeps the run loop alive between callbacks.
RunLoop.main.add(Timer(fire: .distantFuture, interval: 0, repeats: false) { _ in }, forMode: .default)
RunLoop.main.run()
