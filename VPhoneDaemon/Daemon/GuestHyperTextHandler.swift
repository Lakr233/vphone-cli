import Foundation
import IcliKit
import NIOCore
import NIOHTTP1
import NIOPosix

final class GuestHyperTextHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let hub: APIEventHub
    private let fileIO: NonBlockingFileIO
    private var head: HTTPRequestHead?
    private var body = Data()
    private var exceededLimit = false
    private var upload: GuestFileUpload?
    private var uploadError: (any Error)?
    private let maximumJSONBody = 1 << 20

    init(hub: APIEventHub, fileIO: NonBlockingFileIO) {
        self.hub = hub
        self.fileIO = fileIO
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(request):
            head = request
            body.removeAll(keepingCapacity: true)
            exceededLimit = false
            upload = nil
            uploadError = nil
            let requestPath = request.uri.split(separator: "?", maxSplits: 1).first
            if request.method == .PUT, requestPath == "/v1/files/content" || requestPath == "/v1/clipboard/image" {
                do {
                    upload = try GuestFileUpload(
                        destination: requestPath == "/v1/clipboard/image"
                            ? "/var/root/Library/Caches/vphoned-clipboard-image"
                            : GuestFileTransfer.path(from: request.uri),
                        fileIO: fileIO,
                        channel: context.channel,
                        mode: Self.uploadMode(from: request.uri),
                        onCommit: requestPath == "/v1/clipboard/image"
                            ? { path in
                                _ = try setClipboardImage(Data(contentsOf: URL(fileURLWithPath: path)))
                                unlink(path)
                            } : nil,
                    )
                } catch { uploadError = error }
            }
        case var .body(buffer):
            let requestPath = head?.uri.split(separator: "?", maxSplits: 1).first
            if head?.method == .PUT, requestPath == "/v1/files/content" || requestPath == "/v1/clipboard/image" {
                upload?.append(buffer, channel: context.channel)
                return
            }
            if body.count + buffer.readableBytes > maximumJSONBody {
                exceededLimit = true
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
            if path == "/v1/files/content" || path == "/v1/clipboard/image" {
                if head.method == .PUT {
                    if let uploadError {
                        Self.send(APIWire.error(String(describing: uploadError)), on: context.channel)
                    } else {
                        upload?.finish(channel: context.channel)
                    }
                    upload = nil
                } else if head.method == .GET, path == "/v1/clipboard/image" {
                    do {
                        guard let image = try clipboardImagePNG() else {
                            Self.send(APIWire.error("Clipboard has no image", status: 404), on: context.channel)
                            return
                        }
                        Self.send(APIReply(status: 200, data: image), on: context.channel, contentType: "image/png")
                    } catch { Self.send(APIWire.error(String(describing: error)), on: context.channel) }
                } else if head.method == .GET {
                    do {
                        try GuestFileTransfer.download(
                            path: GuestFileTransfer.path(from: head.uri),
                            fileIO: fileIO,
                            channel: context.channel,
                        )
                    } catch {
                        Self.send(APIWire.error(String(describing: error)), on: context.channel)
                    }
                } else {
                    Self.send(APIWire.error("Method not allowed", status: 405), on: context.channel)
                }
                return
            }
            if exceededLimit {
                Self.send(APIWire.error("JSON body exceeds 1 MiB", status: 413), on: context.channel)
                return
            }
            handle(head, body: body, channel: context.channel)
        }
    }

    private func handle(_ head: HTTPRequestHead, body: Data, channel: Channel) {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        if head.method == .GET, path == "/v1/health" {
            Self.send(.json(GuestAPI.health()), on: channel)
            return
        }
        if path.hasPrefix("/v1/ports/"), GuestPortForwardHandler.port(from: head.uri) == nil {
            Self.send(APIWire.error("Port must be a decimal number from 1 to 65535"), on: channel)
            return
        }
        if path == "/v1/events" || path.hasPrefix("/v1/ports/") {
            Self.send(APIWire.error("WebSocket upgrade required", status: 426), on: channel)
            return
        }

        do {
            let request: APIRequest
            if head.method == .POST, path == "/v1/rpc" {
                request = try APIWire.decode(body)
            } else {
                let method = try Self.route(head.method, path: path)
                var params = try Self.parameters(body)
                let components = URLComponents(string: "http://vphoned\(head.uri)")
                for item in components?.queryItems ?? [] {
                    if let value = item.value {
                        params[item.name] = value
                    }
                }
                request = APIRequest(method: method, params: params, id: nil)
            }
            let job = HTTPJob(channel: channel, request: request, hub: hub)
            GuestAPI.queue.async { job.run() }
        } catch {
            Self.send(APIWire.error(String(describing: error)), on: channel)
        }
    }

    private static func parameters(_ body: Data) throws -> [String: Any] {
        if body.isEmpty {
            return [:]
        }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw GuestAPIError.invalidRequest("Request body must be a JSON object")
        }
        return object
    }

    private static func uploadMode(from uri: String) throws -> mode_t {
        let components = URLComponents(string: "http://vphoned\(uri)")
        guard let value = components?.queryItems?.first(where: { $0.name == "mode" })?.value else {
            return 0o644
        }
        guard !value.isEmpty, value.count <= 4,
              value.utf8.allSatisfy({ (48 ... 55).contains($0) }),
              let mode = UInt16(value, radix: 8), mode <= 0o777
        else { throw GuestAPIError.invalidRequest("mode must be an octal permission, up to 0777") }
        return mode_t(mode)
    }

    private static func route(_ verb: HTTPMethod, path: String) throws -> String {
        switch (verb, path) {
        case (.GET, "/v1/device"): "device.snapshot"
        case (.GET, "/v1/device/screen"): "device.screen"
        case (.GET, "/v1/apps"): "apps.list"
        case (.POST, "/v1/apps/refresh"): "apps.refresh"
        case (.POST, "/v1/apps/launch"): "apps.launch"
        case (.POST, "/v1/apps/terminate"): "apps.terminate"
        case (.GET, "/v1/apps/foreground"): "apps.foreground"
        case (.POST, "/v1/apps/open-url"): "apps.open_url"
        case (.POST, "/v1/apps/install"): "apps.install"
        case (.POST, "/v1/bootstrap/install"): "bootstrap.install"
        case (.GET, "/v1/bootstrap/status"): "bootstrap.status"
        case (.POST, "/v1/input/touch"): "input.touch"
        case (.POST, "/v1/input/hid"): "input.hid"
        case (.GET, "/v1/location"): "location.current"
        case (.PUT, "/v1/location"): "location.set"
        case (.DELETE, "/v1/location"): "location.clear"
        case (.GET, "/v1/developer-mode"): "developer_mode.status"
        case (.POST, "/v1/developer-mode/enable"): "developer_mode.enable"
        case (.GET, "/v1/low-power-mode"), (.PUT, "/v1/low-power-mode"): "power.low_power_mode"
        case (.GET, "/v1/clipboard"), (.PUT, "/v1/clipboard"): verb == .GET ? "clipboard.get" : "clipboard.set"
        case (.DELETE, "/v1/clipboard"): "clipboard.clear"
        case (.GET, "/v1/files"): "files.list"
        case (.POST, "/v1/files/mkdir"): "files.mkdir"
        case (.POST, "/v1/files/remove"): "files.remove"
        case (.POST, "/v1/files/rename"): "files.rename"
        case (.POST, "/v1/settings/get"): "settings.get"
        case (.POST, "/v1/settings/set"): "settings.set"
        case (.POST, "/v1/settings/delete"): "settings.delete"
        case (.GET, "/v1/keychain"): "keychain.list"
        case (.POST, "/v1/keychain"): "keychain.add"
        case (.DELETE, "/v1/keychain"): "keychain.delete"
        default: throw GuestAPIError.invalidRequest("No route for \(verb) \(path)")
        }
    }

    static func send(_ reply: APIReply, on channel: Channel, contentType: String = "application/json; charset=utf-8") {
        let write: @Sendable () -> Void = {
            guard channel.isActive else { return }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: String(reply.data.count))
            headers.add(name: "Connection", value: "close")
            let status = HTTPResponseStatus(statusCode: reply.status)
            channel.write(
                HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: headers)),
                promise: nil,
            )
            var buffer = channel.allocator.buffer(capacity: reply.data.count)
            buffer.writeBytes(reply.data)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        if channel.eventLoop.inEventLoop {
            write()
        } else {
            channel.eventLoop.execute(write)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upload = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }
}

private final class HTTPJob: @unchecked Sendable {
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
        if reply.status == 200 {
            hub.broadcast(name: "operation.completed", data: ["method": request.method])
        }
        GuestHyperTextHandler.send(reply, on: channel)
    }
}
