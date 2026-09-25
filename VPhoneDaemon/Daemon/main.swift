import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import VphonedNative

let mode = vp_native_process_mode()
if mode != 1 {
    guard mode == 0 else { exit(64) }
    vp_native_bootstrap_cached_binary()
    exit(vp_native_run_proxy())
}
guard vp_native_watch_proxy() == 0 else { exit(1) }
vp_vcam_start()
GuestIrisinInstaller.refreshBootstrapOnStartup()

let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
let filePool = NIOThreadPool(numberOfThreads: 2)
filePool.start()
let fileIO = NonBlockingFileIO(threadPool: filePool)
let hub = APIEventHub()
let eventPublisher = GuestEventPublisher(hub: hub)

do {
    let server = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 128)
        .childChannelInitializer { channel in
            let http = GuestHyperTextHandler(hub: hub, fileIO: fileIO)
            let upgrader = NIOWebSocketServerUpgrader(
                maxFrameSize: 1 << 20,
                shouldUpgrade: { channel, request in
                    let allowed = request.uri == "/v1/events" || GuestPortForwardHandler.port(from: request.uri) != nil
                    return channel.eventLoop.makeSucceededFuture(allowed ? HTTPHeaders() : nil)
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
    try server.closeFuture.wait()
} catch {
    NSLog("vphoned: HTTP/WebSocket API failed: %@", String(describing: error))
    exit(1)
}

try? group.syncShutdownGracefully()
try? filePool.syncShutdownGracefully()
_ = eventPublisher
