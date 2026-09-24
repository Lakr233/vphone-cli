import Foundation

/// JSON values used by the public API, so callers do not need `[String: Any]`.
public indirect enum VPhoneJSONValue: Codable, Sendable, Equatable {
    case object([String: VPhoneJSONValue])
    case array([VPhoneJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let object = try? value.decode([String: VPhoneJSONValue].self) { self = .object(object) }
        else { self = .array(try value.decode([VPhoneJSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

public struct VPhoneAPIError: Error, Codable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
}

public struct VPhoneAPIResponse: Codable, Sendable {
    public let type: String
    public let id: VPhoneJSONValue?
    public let result: VPhoneJSONValue?
    public let error: VPhoneAPIError?
}

public struct VPhoneAPIEvent: Codable, Sendable {
    public let type: String
    public let event: String
    public let data: VPhoneJSONValue
}

public enum VPhoneAPIMessage: Sendable {
    case response(VPhoneAPIResponse)
    case event(VPhoneAPIEvent)
}

/// An unentitled client for the optional host proxy. vphone-ui can import this
/// product without linking Virtualization.framework or running the CLI.
public struct VPhoneAPIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func call(
        _ method: String,
        params: [String: VPhoneJSONValue] = [:],
        id: VPhoneJSONValue = .string(UUID().uuidString)
    ) async throws -> VPhoneJSONValue {
        let request = Request(id: id, method: method, params: params)
        var http = URLRequest(url: baseURL.appending(path: "v1/rpc"))
        http.httpMethod = "POST"
        http.timeoutInterval = 130
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await session.data(for: http)
        guard let response = response as? HTTPURLResponse else {
            throw VPhoneAPIError(code: "transport", message: "No HTTP response")
        }
        let value = try JSONDecoder().decode(VPhoneAPIResponse.self, from: data)
        if let error = value.error { throw error }
        guard (200..<300).contains(response.statusCode), let result = value.result else {
            throw VPhoneAPIError(code: "protocol", message: "Missing result (HTTP \(response.statusCode))")
        }
        return result
    }

    public func openWebSocket() throws -> VPhoneAPIWebSocket {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw VPhoneAPIError(code: "url", message: "Invalid API URL")
        }
        switch components.scheme {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: throw VPhoneAPIError(code: "url", message: "API URL must use HTTP or HTTPS")
        }
        components.path = (components.path as NSString).appendingPathComponent("v1/events")
        guard let url = components.url else {
            throw VPhoneAPIError(code: "url", message: "Invalid WebSocket URL")
        }
        let task = session.webSocketTask(with: url)
        task.resume()
        return VPhoneAPIWebSocket(task: task)
    }

    /// Runs any icli subcommand inside the guest. Arguments are passed as an
    /// array to the pinned icli executable, without a shell. The result holds
    /// its exit code, decoded JSON output (or text), and stderr.
    public func runIcli(
        _ arguments: [String],
        stdin: String? = nil,
        stdinData: Data? = nil
    ) async throws -> VPhoneJSONValue {
        guard stdin == nil || stdinData == nil else {
            throw VPhoneAPIError(code: "input", message: "Pass either stdin or stdinData")
        }
        var params: [String: VPhoneJSONValue] = ["argv": .array(arguments.map(VPhoneJSONValue.string))]
        if let stdin { params["stdin"] = .string(stdin) }
        if let stdinData { params["stdin_base64"] = .string(stdinData.base64EncodedString()) }
        return try await call("icli.execute", params: params)
    }

    /// Streams a guest file to a new temporary host file. The caller owns the
    /// returned file and should move or delete it when finished.
    public func downloadFile(at guestPath: String) async throws -> URL {
        let url = try fileURL(guestPath)
        let (temporary, response) = try await session.download(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw VPhoneAPIError(code: "download", message: "Guest file download failed")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-" + UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Sends a host file to an absolute guest path without loading it into
    /// memory. The guest stages it beside the destination and renames it.
    public func uploadFile(
        from localURL: URL,
        toGuestPath guestPath: String,
        permissions: String = "644"
    ) async throws -> VPhoneJSONValue {
        var request = URLRequest(url: try fileURL(guestPath, mode: permissions))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: localURL)
        let object = try JSONDecoder().decode([String: VPhoneJSONValue].self, from: data)
        if let error = object["error"] {
            let encoded = try JSONEncoder().encode(error)
            throw try JSONDecoder().decode(VPhoneAPIError.self, from: encoded)
        }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, let result = object["result"]
        else { throw VPhoneAPIError(code: "upload", message: "Guest file upload failed") }
        return result
    }

    private func fileURL(_ guestPath: String, mode: String? = nil) throws -> URL {
        guard guestPath.hasPrefix("/"), !guestPath.contains("\0"),
              var components = URLComponents(url: baseURL.appending(path: "v1/files/content"),
                                             resolvingAgainstBaseURL: false)
        else { throw VPhoneAPIError(code: "path", message: "Guest path must be absolute") }
        components.queryItems = [URLQueryItem(name: "path", value: guestPath)]
        if let mode { components.queryItems?.append(URLQueryItem(name: "mode", value: mode)) }
        guard let url = components.url else { throw VPhoneAPIError(code: "url", message: "Invalid file URL") }
        return url
    }

    private struct Request: Encodable {
        let id: VPhoneJSONValue
        let method: String
        let params: [String: VPhoneJSONValue]
    }
}

public actor VPhoneAPIWebSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    public func send(
        _ method: String,
        params: [String: VPhoneJSONValue] = [:],
        id: VPhoneJSONValue = .string(UUID().uuidString)
    ) async throws {
        let object: [String: VPhoneJSONValue] = [
            "id": id, "method": .string(method), "params": .object(params),
        ]
        let data = try JSONEncoder().encode(object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func next() async throws -> VPhoneAPIMessage {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: throw VPhoneAPIError(code: "protocol", message: "Unknown WebSocket message")
        }
        let object = try JSONDecoder().decode([String: VPhoneJSONValue].self, from: data)
        switch object["type"] {
        case .string("response"):
            return .response(try JSONDecoder().decode(VPhoneAPIResponse.self, from: data))
        case .string("event"):
            return .event(try JSONDecoder().decode(VPhoneAPIEvent.self, from: data))
        default:
            throw VPhoneAPIError(code: "protocol", message: "Unknown WebSocket envelope")
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
