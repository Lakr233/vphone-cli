import CoreGraphics
import Foundation
import ImageIO

let toolNames = hostTools.map(\.name) + areaNames

/// What a tool returns. `.failure` is a result with `isError:true`.
enum ToolResult {
    case text(String)
    /// Images as MCP image content, then `caption` as text.
    case images([(base64: String, mimeType: String)], caption: String)
    case failure(String)
}

/// A tool: its `tools/list` entry, and what it does through the socket.
struct Tool: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let annotations: [String: Bool]
    let access: Access
    let run: (MachineSocket, [String: Any]) throws -> ToolResult
}

/// The host tools, in the order `tools/list` returns them, before the generated group tools.
let hostTools: [Tool] = [screenshotTool, pushTool, pullTool, shellTool, methodsTool, rpcTool]

/// The annotation hints. They inform the client; nothing enforces them.
private let readOnly = ["readOnlyHint": true, "openWorldHint": false]
private let hostFiles = ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]
private let guestAnything = ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]

private let screenshotTool = Tool(
    name: "screenshot",
    description: "Capture the guest screen as a PNG at point size: the image is as many pixels wide as the screen has points. Call it to see the screen before acting. The caption gives the size in points.",
    inputSchema: schema([:], required: []),
    annotations: readOnly, access: .read,
    run: { socket, _ in
        let scale = try pointScale(socket)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try socket.send(["t": "screenshot", "path": path], deadline: socket.deadlines.base)
        guard let file = FileManager.default.contents(atPath: path), let image = decodeImage(file) else {
            return .failure(unreadableMessage(path))
        }
        let width = (Double(image.width) / scale).rounded()
        let height = (Double(image.height) / scale).rounded()
        guard width >= 1, height >= 1, width <= Double(Int32.max), height <= Double(Int32.max),
              let png = scaledPNG(image, width: Int(width), height: Int(height)) else {
            return .failure(unreadableMessage(path))
        }
        return .images([(png.base64EncodedString(), "image/png")], caption: "\(Int(width))x\(Int(height)) points")
    })

private let pushTool = Tool(
    name: "push",
    description: "Copy a file from this Mac into the guest. local and path are absolute. mode is 3 or 4 octal digits, such as 755. Returns the guest's result.",
    inputSchema: schema(["local": pathSchema, "path": pathSchema, "mode": modeSchema], required: ["local", "path"]),
    annotations: hostFiles, access: .destructive,
    run: { socket, arguments in
        let local = try absolutePath(arguments, "local")
        let path = try absolutePath(arguments, "path")
        var request: [String: Any] = ["t": "push", "local": local, "path": path]
        if let mode = try octalMode(arguments) { request["mode"] = mode }
        return resultText(try socket.send(request, deadline: socket.deadlines.long))
    })

private let pullTool = Tool(
    name: "pull",
    description: "Copy a file from the guest to this Mac. path and local are absolute. Returns the guest's result.",
    inputSchema: schema(["path": pathSchema, "local": pathSchema], required: ["path", "local"]),
    annotations: hostFiles, access: .destructive,
    run: { socket, arguments in
        let path = try absolutePath(arguments, "path")
        let local = try absolutePath(arguments, "local")
        return resultText(try socket.send(["t": "pull", "path": path, "local": local], deadline: socket.deadlines.long))
    })

private let methodsTool = Tool(
    name: "methods",
    description: "List the guest's rpc methods with their parameters. Call it before rpc to find a method name. prefix keeps only the names that start with it, such as ui.; method keeps only that one name.",
    inputSchema: schema(["prefix": textSchema, "method": textSchema], required: []),
    annotations: readOnly, access: .read,
    run: { socket, arguments in
        let prefix = try arguments["prefix"].map { _ in try nonEmptyString(arguments, "prefix") }
        let method = try arguments["method"].map { _ in try nonEmptyString(arguments, "method") }
        let reply = try socket.send(["t": "rpc", "method": "methods.list"], deadline: socket.deadlines.base)
        guard prefix != nil || method != nil,
              let entries = (reply["result"] as? [String: Any])?["methods"] as? [Any] else { return resultText(reply) }
        let kept = entries.filter { entry in
            guard let name = (entry as? [String: Any])?["name"] as? String else { return false }
            return (prefix.map { name.hasPrefix($0) } ?? true) && (method.map { name == $0 } ?? true)
        }
        return .text(sortedJSON(["methods": kept]))
    })

private let rpcTool = Tool(
    name: "rpc",
    description: "Call a guest rpc method by name, with optional params as an object. Call methods first to see the names and their params. timeout_ms is the wait for the reply in milliseconds, an integer from 1000 to 180000, default 180000. Returns the guest's result; an image result (data and an image/* mime_type) comes back as an image.",
    inputSchema: schema(["method": textSchema, "params": ["type": "object"] as [String: Any],
                         "timeout_ms": ["type": "integer", "minimum": 1000, "maximum": 180000] as [String: Any]],
                        required: ["method"]),
    annotations: guestAnything, access: .destructive,
    run: { socket, arguments in
        let method = try nonEmptyString(arguments, "method")
        var params: [String: Any]?
        if let raw = arguments["params"] {
            guard let object = raw as? [String: Any] else {
                throw ArgumentError(message: "invalid argument params: must be an object")
            }
            params = object
        }
        let deadline = try integerArgument(arguments, "timeout_ms", 1000...180000).map { Double($0) / 1000 }
            ?? socket.deadlines.rpc
        return try callGuest(socket, method: method, params: params, deadline: deadline)
    })

private let shellTool = Tool(
    name: "shell",
    description: "Run input in a shell session in the guest and return its terminal output, with the echo of input and the final status line. Pass program: \"bash\" to run shell commands; without program the guest runs a JavaScript session. timeout_seconds is 1 to 600, default 30.",
    inputSchema: schema(["input": textSchema, "program": textSchema,
                         "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 600] as [String: Any]],
                        required: ["input"]),
    annotations: guestAnything, access: .destructive,
    run: { socket, arguments in
        let input = try nonEmptyString(arguments, "input")
        var program: String?
        if arguments["program"] != nil { program = try nonEmptyString(arguments, "program") }
        let timeout = try integerArgument(arguments, "timeout_seconds", 1...600) ?? Int(socket.deadlines.base)
        let result = try socket.shell(program: program, input: input, timeout: timeout)
        return result.isError ? .failure(result.text) : .text(result.text)
    })

/// An optional integer argument: nil when absent, otherwise an integer in `range`.
func integerArgument(_ arguments: [String: Any], _ name: String, _ range: ClosedRange<Int>) throws -> Int? {
    guard let value = arguments[name] else { return nil }
    guard let number = jsonNumber(value), number == number.rounded(),
          (Double(range.lowerBound)...Double(range.upperBound)).contains(number) else {
        throw ArgumentError(message: "invalid argument \(name): must be an integer from \(range.lowerBound) to \(range.upperBound)")
    }
    return Int(number)
}

private var textSchema: [String: Any] { ["type": "string", "minLength": 1] }

private var pathSchema: [String: Any] { ["type": "string", "minLength": 1, "pattern": "^/"] }

private var modeSchema: [String: Any] { ["type": "string", "pattern": "^[0-7]{3,4}$"] }

/// A required string argument: non-empty.
func nonEmptyString(_ arguments: [String: Any], _ name: String) throws -> String {
    guard let value = arguments[name] else {
        throw ArgumentError(message: "invalid argument \(name): missing")
    }
    guard let string = value as? String, !string.isEmpty else {
        throw ArgumentError(message: "invalid argument \(name): must be a non-empty string")
    }
    return string
}

/// A required string argument that is an absolute path.
func absolutePath(_ arguments: [String: Any], _ name: String) throws -> String {
    let path = try nonEmptyString(arguments, name)
    guard path.hasPrefix("/") else {
        throw ArgumentError(message: "invalid argument \(name): must be an absolute path")
    }
    return path
}

/// The optional `mode` argument of push: 3 or 4 octal digits.
func octalMode(_ arguments: [String: Any]) throws -> String? {
    guard let value = arguments["mode"] else { return nil }
    guard let mode = value as? String, (3...4).contains(mode.count),
          mode.allSatisfy({ $0 >= "0" && $0 <= "7" }) else {
        throw ArgumentError(message: "invalid argument mode: must be an octal mode of 3 or 4 digits")
    }
    return mode
}

/// The reply's `result` as text, with sorted keys so equal results give equal text.
/// `{}` when the reply has no result.
func resultText(_ reply: [String: Any]) -> ToolResult {
    .text(sortedJSON(reply["result"] ?? [String: Any]()))
}

/// The JSON text of any JSON value, with sorted keys and unescaped slashes.
func sortedJSON(_ value: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value,
                                            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

/// The `vm` property of every tool.
var vmSchema: [String: Any] { ["type": "string", "minLength": 1, "description": "Name of a VM in the library (a directory under $VPHONE_LIBRARY_ROOT or ~/.vphone/machines)"] }

private func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    var all = properties
    all["vm"] = vmSchema
    return ["type": "object", "properties": all, "required": ["vm"] + required]
}

/// A JSON number that is not a boolean.
func jsonNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, !isJSONBool(number) else { return nil }
    return number.doubleValue
}

/// The guest's pixels per point, read on every call: the screenshot's pixel
/// width over the guest's point width. Both come from the guest, which changes
/// orientation.
func pointScale(_ socket: MachineSocket) throws -> Double {
    let geometry = try socket.send(["t": "display.geometry"], deadline: socket.deadlines.base)
    let screen = try socket.send(["t": "rpc", "method": "device.screen"], deadline: socket.deadlines.base)
    let pixelsValue = (geometry["result"] as? [String: Any])?["screenshot_pixels"]
    if pixelsValue != nil && !(pixelsValue is [Any]) {
        throw invalidScreen(socket, "screenshot_pixels", pixelsValue)
    }
    let pixelValue = (pixelsValue as? [Any])?.first
    let widthValue = (screen["result"] as? [String: Any])?["width"]
    guard let pixelCount = jsonNumber(pixelValue), pixelCount > 0 else {
        throw invalidScreen(socket, "screenshot_pixels[0]", pixelValue)
    }
    guard let widthPoints = jsonNumber(widthValue), widthPoints > 0 else {
        throw invalidScreen(socket, "width", widthValue)
    }
    let scale = pixelCount / widthPoints
    guard scale.isFinite, scale > 0 else { throw invalidScreen(socket, "width", widthValue) }
    return scale
}

private func invalidScreen(_ socket: MachineSocket, _ field: String, _ value: Any?) -> SocketError {
    SocketError(message: screenMessage(socket.path, field, value.map(sortedJSON) ?? "missing"))
}

/// The first image in `png`, decoded, or nil when it is not a decodable image.
func decodeImage(_ png: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// A PNG of `width` by `height` pixels, drawn from `image`, or nil when the
/// output cannot be created or encoded.
func scaledPNG(_ image: CGImage, width: Int, height: Int) -> Data? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
