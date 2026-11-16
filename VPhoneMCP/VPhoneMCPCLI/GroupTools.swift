import Foundation
import ImageIO

/// What a method does to the guest, as `methods.list` reports it.
enum Access: String {
    case read, mutating, destructive
}

/// Which actions and host tools exist.
enum Profile: String {
    case full, standard, readonly

    func allows(_ access: Access) -> Bool {
        switch self {
        case .full: true
        case .standard: access != .destructive
        case .readonly: access == .read
        }
    }
}

/// The 13 areas of the guest catalog, in the order `tools/list` returns the group tools.
let areaNames = ["input", "ui", "apps", "files", "processes", "services", "device", "sensors",
                 "network", "settings", "system", "bootstrap", "script"]

/// Methods the host tools already cover, so no group tool offers them.
private let hostMethods: Set<String> = ["screen.screenshot", "methods.list"]

struct GuestParam {
    let name: String
    let type: String
    let required: Bool
    let description: String
    let enumValues: [Any]?
    let defaultValue: Any?
    let minimum: Double?
    let maximum: Double?
    /// The element kind of an array: `string`, `integer`, `number`, `object` or `point` (an [x, y] pair of numbers).
    let items: String?
    /// Every JSON type the parameter takes, when that is not just `type`.
    let accepts: [String]?

    /// The JSON Schema type names of the parameter; an `any` parameter takes every JSON type.
    var typeNames: [String] { accepts ?? (type == "any" ? jsonTypes : [type]) }

    /// The JSON Schema property for this parameter. For an array, `minimum` and `maximum` bound the item count.
    var schema: [String: Any] {
        var property: [String: Any] = ["description": description]
        property["type"] = typeNames.count == 1 ? typeNames[0] : typeNames
        if let enumValues { property["enum"] = enumValues }
        if let defaultValue { property["default"] = compact(defaultValue) }
        if type == "array" {
            if let minimum { property["minItems"] = Int(minimum) }
            if let maximum { property["maxItems"] = Int(maximum) }
            if let items { property["items"] = itemSchema(items) }
        } else {
            if let minimum { property["minimum"] = compact(minimum) }
            if let maximum { property["maximum"] = compact(maximum) }
        }
        return property
    }
}

private let jsonTypes = ["string", "number", "boolean", "array", "object", "null"]
private let itemKinds: Set<String> = ["string", "integer", "number", "object", "point"]

private func itemSchema(_ kind: String) -> [String: Any] {
    kind == "point" ? ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2] : ["type": kind]
}

/// A fractional number as its shortest decimal text (0.1, not 0.10000000000000001), so `tools/list` stays small.
private func compact(_ value: Any) -> Any {
    guard let number = value as? NSNumber, !isJSONBool(number), CFNumberIsFloatType(number) else { return value }
    return NSDecimalNumber(string: "\(number.doubleValue)")
}

struct GuestMethod {
    let name: String
    let description: String
    let area: String
    let access: Access
    let params: [GuestParam]
    let hasForce: Bool
    /// For a `when:<key>` force, the parameter that makes it needed; nil for `always`.
    let forceKey: String?
}

private let paramTypes: Set<String> = ["string", "integer", "number", "boolean", "array", "object", "any", "null"]

/// The `methods.list` result, kept entry by entry. An entry the server cannot read is dropped.
struct Catalog {
    let methods: [GuestMethod]

    static func parse(_ result: Any?) -> Catalog? {
        guard let entries = (result as? [String: Any])?["methods"] as? [Any] else { return nil }
        let methods = entries.compactMap { entry -> GuestMethod? in
            guard let object = entry as? [String: Any], let name = object["name"] as? String, !name.isEmpty,
                  !hostMethods.contains(name),
                  let area = object["area"] as? String, areaNames.contains(area),
                  let access = (object["access"] as? String).flatMap(Access.init(rawValue:)) else { return nil }
            var params: [GuestParam] = []
            for raw in (object["params"] as? [Any]) ?? [] {
                guard let item = raw as? [String: Any], let paramName = item["name"] as? String,
                      let type = item["type"] as? String, paramTypes.contains(type) else { return nil }
                let items = item["items"] as? String
                let accepts = item["accepts"] as? [Any]
                guard items == nil || itemKinds.contains(items!),
                      accepts == nil || accepts!.allSatisfy({ ($0 as? String).map(paramTypes.contains) == true }) else { return nil }
                params.append(GuestParam(
                    name: paramName, type: type, required: (item["required"] as? Bool) ?? false,
                    description: (item["description"] as? String) ?? "", enumValues: item["enum"] as? [Any],
                    defaultValue: item["default"], minimum: jsonNumber(item["minimum"]), maximum: jsonNumber(item["maximum"]),
                    items: items, accepts: accepts?.compactMap { $0 as? String }))
            }
            // A force that is missing or not never, always or when:<key> fails closed: destructive, with no force property.
            let force = object["force"] as? String
            let known = force == "never" || force == "always" || (force?.hasPrefix("when:") == true && force!.count > 5)
            let effective: Access = force == "never" ? access : .destructive
            return GuestMethod(name: name, description: (object["description"] as? String) ?? "", area: area,
                               access: effective, params: params, hasForce: known && force != "never",
                               forceKey: force?.hasPrefix("when:") == true ? String(force!.dropFirst(5)) : nil)
        }
        // Entries that share a name are all dropped.
        let counts = Dictionary(methods.map { ($0.name, 1) }, uniquingKeysWith: +)
        let unique = methods.filter { counts[$0.name] == 1 }
        return unique.isEmpty ? nil : Catalog(methods: unique.sorted { $0.name < $1.name })
    }

    func actions(area: String, profile: Profile) -> [GuestMethod] {
        methods.filter { $0.area == area && profile.allows($0.access) }
    }
}

/// The catalog in `json` (the shape `methods.list` answers), or nil when it does not parse.
func parseCatalog(_ json: String) -> Catalog? {
    guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return Catalog.parse(object)
}

/// One group tool per area that has an action under `profile`, in `areaNames` order.
func groupTools(_ catalog: Catalog, profile: Profile) -> [Tool] {
    areaNames.compactMap { area in
        let actions = catalog.actions(area: area, profile: profile)
        guard !actions.isEmpty else { return nil }
        let lines = actions.map { action in
            let needs = !action.hasForce ? "" : (action.forceKey.map { " Needs force when \($0) is true." } ?? " Needs force.")
            return "\(action.name): \(action.description)\(needs)"
        }
        let description = "Guest methods of area \(area). Pass action and that action's parameters.\n"
            + lines.joined(separator: "\n")
        let everyRead = actions.allSatisfy { $0.access == .read }
        let annotations: [String: Bool] = everyRead
            ? ["readOnlyHint": true, "openWorldHint": false]
            : ["readOnlyHint": false, "idempotentHint": false, "destructiveHint": actions.contains { $0.access == .destructive }]
        return Tool(name: area, description: description, inputSchema: groupSchema(actions), annotations: annotations,
                    access: actions.contains { $0.access == .destructive } ? .destructive
                        : (everyRead ? .read : .mutating),
                    run: { socket, arguments in
                        let action = try checkArguments(actions, arguments)
                        var params = arguments
                        params["action"] = nil
                        var deadline = socket.deadlines.rpc
                        if let ms = jsonNumber(params["timeout_ms"]) { deadline = max(deadline, ms / 1000 + 30) }
                        return try callGuest(socket, method: action.name, params: params, deadline: deadline)
                    })
    }
}

/// The `force` property: one definition for every action that takes it.
private var forceSchema: [String: Any] { ["type": "boolean", "description": "Required to confirm a destructive action"] }

/// A parameter name is defined once, at the top level, when every action that takes it defines it the same way; each
/// branch then lists it as `{}`. A name the actions define differently has a top level of its description and the union
/// of its types, and each branch carries that action's own definition.
private func groupSchema(_ actions: [GuestMethod]) -> [String: Any] {
    var variants: [String: [[String: Any]]] = [:]
    for action in actions {
        for param in action.params { variants[param.name, default: []].append(param.schema) }
        if action.hasForce { variants["force", default: []].append(forceSchema) }
    }
    var top: [String: Any] = ["action": ["type": "string", "enum": actions.map(\.name)] as [String: Any], "vm": vmSchema]
    var shared: Set<String> = []
    for (name, definitions) in variants {
        let first = definitions[0]
        if definitions.allSatisfy({ sortedJSON($0) == sortedJSON(first) }) {
            top[name] = first
            shared.insert(name)
        } else {
            var types: [String] = []
            for definition in definitions {
                for type in (definition["type"] as? [String]) ?? [definition["type"] as? String ?? ""] where !types.contains(type) {
                    types.append(type)
                }
            }
            var merged: [String: Any] = ["description": first["description"] ?? "", "type": types.count == 1 ? types[0] : types]
            if let items = definitions.compactMap({ $0["items"] }).first { merged["items"] = items }
            top[name] = merged
        }
    }
    let branches: [[String: Any]] = actions.map { action in
        var properties: [String: Any] = ["action": ["const": action.name], "vm": [String: Any]()]
        for param in action.params { properties[param.name] = shared.contains(param.name) ? [String: Any]() : param.schema }
        if action.hasForce { properties["force"] = [String: Any]() }
        return ["properties": properties, "required": ["action"] + action.params.filter(\.required).map(\.name),
                "additionalProperties": false]
    }
    return ["type": "object", "properties": top, "required": ["vm", "action"], "oneOf": branches, "additionalProperties": false]
}

private func fault(_ name: String, _ problem: String) -> ArgumentError {
    ArgumentError(message: "invalid argument \(name): \(problem)")
}

/// The action `arguments` names, after the checks of REQ-MCP-015. `vm` is not in `arguments`.
func checkArguments(_ actions: [GuestMethod], _ arguments: [String: Any]) throws -> GuestMethod {
    let names = actions.map(\.name)
    guard let raw = arguments["action"] else { throw fault("action", "missing") }
    guard let name = raw as? String, let action = actions.first(where: { $0.name == name }) else {
        throw fault("action", "must be one of \(names.joined(separator: ", "))")
    }
    let takes = (action.params.map(\.name) + (action.hasForce ? ["force"] : []) + ["action", "vm"]).sorted()
    if let unknown = arguments.keys.sorted().first(where: { !takes.contains($0) }) {
        throw fault(unknown, "unknown argument for \(action.name); \(action.name) takes \(takes.joined(separator: ", "))")
    }
    for param in action.params where param.required && arguments[param.name] == nil {
        throw fault(param.name, "missing for \(action.name)")
    }
    for param in action.params {
        guard let value = arguments[param.name] else { continue }
        try check(value, against: param)
    }
    if let force = arguments["force"], !(isJSONBool(force)) { throw fault("force", "must be a boolean") }
    return action
}

/// Whether `value` is of the JSON Schema type `type`; an integer is a whole number and a boolean is never a number.
private func isType(_ value: Any, _ type: String) -> Bool {
    switch type {
    case "string": value is String && !isJSONBool(value)
    case "integer": jsonNumber(value).map { $0 == $0.rounded() } ?? false
    case "number": jsonNumber(value) != nil
    case "boolean": isJSONBool(value)
    case "array": value is [Any]
    case "object": value is [String: Any]
    case "null": value is NSNull
    default: true
    }
}

private let typeWords = ["string": "a string", "integer": "an integer", "number": "a number", "boolean": "a boolean",
                         "array": "an array", "object": "an object", "null": "null"]

private let itemWords = ["string": "strings", "integer": "integers", "number": "numbers", "object": "objects",
                         "point": "[x, y] pairs of numbers"]

private func isPoint(_ value: Any) -> Bool {
    guard let pair = value as? [Any], pair.count == 2 else { return false }
    return pair.allSatisfy { isType($0, "number") }
}

private func check(_ value: Any, against param: GuestParam) throws {
    let name = param.name
    guard param.typeNames.contains(where: { isType(value, $0) }) else {
        throw fault(name, "must be \(param.typeNames.map { typeWords[$0] ?? $0 }.joined(separator: " or "))")
    }
    if let allowed = param.enumValues, !allowed.contains(where: { sortedJSON($0) == sortedJSON(value) }) {
        throw fault(name, "must be one of \(allowed.map { ($0 as? String) ?? sortedJSON($0) }.joined(separator: ", "))")
    }
    if let list = value as? [Any] {
        if let low = param.minimum, let high = param.maximum, Double(list.count) < low || Double(list.count) > high {
            throw fault(name, low == high ? "must have \(sortedJSON(low)) items" : "must have from \(sortedJSON(low)) to \(sortedJSON(high)) items")
        }
        if let low = param.minimum, Double(list.count) < low { throw fault(name, "must have at least \(sortedJSON(low)) \(low == 1 ? "item" : "items")") }
        if let high = param.maximum, Double(list.count) > high { throw fault(name, "must have at most \(sortedJSON(high)) \(high == 1 ? "item" : "items")") }
        if let kind = param.items, !list.allSatisfy({ kind == "point" ? isPoint($0) : isType($0, kind) }) {
            throw fault(name, "must be an array of \(itemWords[kind] ?? kind)")
        }
        return
    }
    guard let number = jsonNumber(value) else { return }
    if let low = param.minimum, let high = param.maximum, number < low || number > high {
        throw fault(name, "must be from \(sortedJSON(low)) to \(sortedJSON(high))")
    }
    if let low = param.minimum, number < low { throw fault(name, "must be at least \(sortedJSON(low))") }
    if let high = param.maximum, number > high { throw fault(name, "must be at most \(sortedJSON(high))") }
}

/// Sends one guest method as an rpc request. Every image in the result (an object with a non-empty base64 `data` and an
/// `image/*` `mime_type`, at any depth) comes back as image content, and the text is the result without those `data`
/// values. An image whose object has a `coordinate_scale` above 1 is scaled to point size, as `screenshot` does.
func callGuest(_ socket: MachineSocket, method: String, params: [String: Any]?, deadline: Double) throws -> ToolResult {
    var request: [String: Any] = ["t": "rpc", "method": method]
    if let params { request["params"] = params }
    let reply = try socket.send(request, deadline: deadline, noReply: rpcNoReplyMessage)
    guard let result = reply["result"] else { return resultText(reply) }
    var images: [(base64: String, mimeType: String)] = []
    let text = takingImages(result, &images)
    return images.isEmpty ? resultText(reply) : .images(images, caption: sortedJSON(text))
}

/// `value` without the `data` of every embedded image, which is appended to `images`.
private func takingImages(_ value: Any, _ images: inout [(base64: String, mimeType: String)]) -> Any {
    if let list = value as? [Any] { return list.map { takingImages($0, &images) } }
    guard var object = value as? [String: Any] else { return value }
    if let data = object["data"] as? String, !data.isEmpty, Data(base64Encoded: data) != nil,
       let mimeType = object["mime_type"] as? String, mimeType.hasPrefix("image/") {
        images.append(pointSized(data, mimeType, scale: jsonNumber(object["coordinate_scale"])))
        object["data"] = nil
    }
    for key in object.keys.sorted() { object[key] = takingImages(object[key]!, &images) }
    return object
}

/// Whether the image header declares at most 64 million pixels, read before any decoding.
private func withinPixelLimit(_ bytes: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double else { return false }
    return width * height <= 64_000_000
}

/// The image at point size: its pixel sides divided by `scale`, as PNG; unchanged when `scale` is not above 1 or the
/// image cannot be redrawn.
private func pointSized(_ base64: String, _ mimeType: String, scale: Double?) -> (base64: String, mimeType: String) {
    guard let scale, scale > 1, scale.isFinite, let bytes = Data(base64Encoded: base64), withinPixelLimit(bytes),
          let image = decodeImage(bytes) else {
        return (base64, mimeType)
    }
    let width = (Double(image.width) / scale).rounded(), height = (Double(image.height) / scale).rounded()
    guard width >= 1, height >= 1, let png = scaledPNG(image, width: Int(width), height: Int(height)) else { return (base64, mimeType) }
    return (png.base64EncodedString(), "image/png")
}
