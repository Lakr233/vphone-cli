import Foundation
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
        if let id, !(id is String) && !(id is NSNumber) {
            throw GuestAPIError.invalidRequest("id must be a string or number")
        }
        return APIRequest(method: method, params: object["params"] as? [String: Any] ?? [:], id: id)
    }

    static func execute(_ request: APIRequest) -> APIReply {
        do {
            let result = try GuestAPI.execute(method: request.method, params: request.params)
            return .json(["type": "response", "id": request.id ?? NSNull(), "result": result])
        } catch {
            let code = error is GuestAPIError ? "invalid_operation" : "operation_failed"
            return .json(status: 400, [
                "type": "response", "id": request.id ?? NSNull(),
                "error": ["code": code, "message": String(describing: error)],
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

    func add(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
    }

    func remove(_ channel: Channel) {
        lock.lock()
        channels.removeValue(forKey: ObjectIdentifier(channel))
        lock.unlock()
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
