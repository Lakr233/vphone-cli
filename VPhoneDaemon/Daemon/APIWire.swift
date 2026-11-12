import Foundation
import IcliSystem
import NIOCore
import NIOWebSocket

struct APIReply: Sendable {
    let status: Int
    let data: Data

    static func json(status: Int = 200, _ value: [String: Any]) -> APIReply {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            ?? Data(#"{"error":{"code":"serialization_failed","message":"Could not encode response"}}"#.utf8)
        return APIReply(status: status, data: data)
    }
}

struct APIRequest: @unchecked Sendable {
    let method: String
    let params: [String: Any]
    let id: Any?
}

enum APIWire {
    static func decode(_ data: Data) throws -> APIRequest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String, !method.isEmpty,
              method.count <= 128,
              object["params"] == nil || object["params"] is [String: Any]
        else {
            throw GuestAPIError.invalidRequest("Expected {method, params?, id?}")
        }
        let id = object["id"]
        if let id, !(id is String), !(id is NSNumber) {
            throw GuestAPIError.invalidRequest("id must be a string or number")
        }
        return APIRequest(method: method, params: object["params"] as? [String: Any] ?? [:], id: id)
    }

    static func execute(_ request: APIRequest) -> APIReply {
        do {
            let result = try GuestAPI.execute(method: request.method, params: request.params)
            return .json(["type": "response", "id": request.id ?? NSNull(), "result": result])
        } catch {
            var body: [String: Any]
            if let error = error as? IcliError {
                body = ["code": error.code, "message": error.message]
                // A failed command's output says what failed, which the
                // generic "command exited with status 1" does not.
                if case let .commandFailed(output) = error {
                    body.merge(output.filter { $0.key != "error" }) { $1 }
                    if output["message"] as? String == nil {
                        body["message"] = error.message
                    }
                }
            } else if let error = error as? GuestAPIError {
                body = error.wireBody
            } else {
                body = ["code": "operation_failed", "message": String(describing: error)]
            }
            return .json(status: 400, [
                "type": "response", "id": request.id ?? NSNull(),
                "error": body,
            ])
        }
    }

    static func error(_ message: String, status: Int = 400) -> APIReply {
        .json(status: status, ["error": ["code": "bad_request", "message": message]])
    }
}

/// A client receives guest events on the same WebSocket it uses for commands.
/// Writes are always scheduled on each channel's event loop.
final class APIEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    /// Called with true when the first subscriber arrives and false when the
    /// last one leaves, outside the lock. Set once, before any client connects.
    var onSubscribedChange: (@Sendable (Bool) -> Void)?

    func add(_ channel: Channel) {
        lock.lock()
        let first = channels.isEmpty
        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
        if first { onSubscribedChange?(true) }
    }

    func remove(_ channel: Channel) {
        lock.lock()
        let removed = channels.removeValue(forKey: ObjectIdentifier(channel)) != nil
        let last = removed && channels.isEmpty
        lock.unlock()
        if last { onSubscribedChange?(false) }
    }

    func broadcast(name: String, data: [String: Any]) {
        let reply = APIReply.json(["type": "event", "event": name, "data": data])
        lock.lock()
        let recipients = Array(channels.values)
        lock.unlock()
        for channel in recipients {
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                var buffer = channel.allocator.buffer(capacity: reply.data.count)
                buffer.writeBytes(reply.data)
                channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
            }
        }
    }

    var hasSubscribers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !channels.isEmpty
    }
}

// MARK: - Closing

extension Channel {
    /// Ends a VSOCK connection whose last write has been flushed. Closing it
    /// here would lose data: XNU's vsock answers close() and shutdown() with an
    /// immediate RESET or SHUTDOWN, and drops bytes still queued in the send
    /// buffer for host credit. A reply of about 8 to 16 KiB is truncated that
    /// way. The host closes once it has read everything, and NIO then closes
    /// this channel on EOF. The timer only covers a host that never closes.
    func closeAfterPeer() {
        let channel = self
        let fallback = eventLoop.scheduleTask(in: .seconds(30)) {
            channel.close(promise: nil)
        }
        closeFuture.whenComplete { _ in fallback.cancel() }
        // EOF is only seen while reading, and a relay may have paused reads.
        _ = setOption(ChannelOptions.autoRead, value: true)
    }
}
