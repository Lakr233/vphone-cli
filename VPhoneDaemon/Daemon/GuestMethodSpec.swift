import Foundation

enum GuestAPIError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case unsupportedMethod(String)
    case operationFailed(String)
    /// The request would repeat work the guest has already done. The code is
    /// sent as the error code so a client can tell it apart from a failure.
    case alreadyDone(code: String, message: String)
    /// The guest's Location Services switch is off, so locationd gives no
    /// client a location. `location.services {enabled:true}` turns it on.
    case locationServicesOff

    var description: String {
        switch self {
        case let .invalidRequest(message), let .operationFailed(message): message
        case let .unsupportedMethod(method): "Unknown method: \(method)"
        case let .alreadyDone(_, message): message
        case .locationServicesOff:
            "Location Services are turned off in the guest. Turn them on with location.services {enabled:true}."
        }
    }

    var code: String {
        if case let .alreadyDone(code, _) = self {
            return code
        }
        if case .locationServicesOff = self {
            return "location_services_off"
        }
        return "invalid_operation"
    }
}

enum ParamType: String { case string, integer, number, boolean, array, object, any, null }

struct MethodParam {
    let name: String
    let type: ParamType
    let required: Bool
    /// One line, at most 120 characters; run-methods-tests.sh check 13 enforces it.
    let description: String
    /// Allowed values, `default`, `minimum` and `maximum` are `methods.list` metadata only: the handlers do not enforce them.
    let values: [String]?
    let defaultValue: Any?
    let min: Double?
    let max: Double?
    static func required(_ name: String, _ type: ParamType, _ description: String,
                         values: [String]? = nil, min: Double? = nil, max: Double? = nil) -> MethodParam {
        .init(name: name, type: type, required: true, description: description, values: values, defaultValue: nil, min: min, max: max)
    }

    static func optional(_ name: String, _ type: ParamType, _ description: String,
                         values: [String]? = nil, default defaultValue: Any? = nil,
                         min: Double? = nil, max: Double? = nil) -> MethodParam {
        .init(name: name, type: type, required: false, description: description, values: values,
              defaultValue: defaultValue, min: min, max: max)
    }
}

/// One top-level key of a method's result. `hidden` keys are produced by the source but never
/// reach callers, so `methods.list` omits them. `open` marks content that is data: nested keys
/// are not checked.
struct ResultKey {
    enum Presence { case required, optional, hidden }
    let name: String
    let type: ParamType
    let presence: Presence
    let isOpen: Bool
    /// Emitted on every path but null on some; the type stays the base type.
    var isNullable: Bool = false
    static func required(_ name: String, _ type: ParamType) -> ResultKey { .init(name: name, type: type, presence: .required, isOpen: false) }
    static func optional(_ name: String, _ type: ParamType) -> ResultKey { .init(name: name, type: type, presence: .optional, isOpen: false) }
    static func hidden(_ name: String, _ type: ParamType) -> ResultKey { .init(name: name, type: type, presence: .hidden, isOpen: false) }
    func `open`() -> ResultKey { .init(name: name, type: type, presence: presence, isOpen: true, isNullable: isNullable) }
    func nullable() -> ResultKey { .init(name: name, type: type, presence: presence, isOpen: isOpen, isNullable: true) }
}

/// The action text completes "Pass force: true to <action>". It is computed from the admitted
/// params and may throw: it runs exactly the validation today's handler ran before
/// `requireForce`, so an invalid unforced request fails with the same error as today.
typealias ForceAction = ([String: Any]) throws -> String

/// The leading `String` is the static action phrase `methods.list` reports as `force_action`; a `<...>`
/// placeholder stands for text the closure fills in at run time.
enum MethodForce {
    case never
    case always(String, ForceAction)
    case when(String, String, ForceAction) // the named param, read with `flag`, must be true; then the phrase

    /// A force whose action phrase is the same constant text the catalog reports.
    static func always(_ text: String) -> MethodForce { .always(text) { _ in text } }

    var text: String? {
        switch self {
        case .never: nil
        case let .always(text, _), let .when(_, text, _): text
        }
    }
}

struct MethodSpec {
    let summary: String
    let params: [MethodParam]
    let force: MethodForce
    /// nil = result undeclared; [] = declared to return no keys.
    let result: [ResultKey]?
    init(_ params: MethodParam..., summary: String, force: MethodForce = .never, result: [ResultKey]? = nil) {
        self.summary = summary
        self.params = params
        self.force = force
        self.result = result
    }
}

protocol GuestMethod: RawRepresentable, CaseIterable where RawValue == String {
    var spec: MethodSpec { get }
}

struct GuestMethodArea {
    /// A closure so a dispatch never builds the specs of all 192 methods: only `catalog` calls it.
    let entries: () -> [(name: String, spec: MethodSpec)]
    let execute: (String, [String: Any]) throws -> [String: Any]?

    static func make<M: GuestMethod>(
        _: M.Type, _ handle: @escaping (M, [String: Any]) throws -> [String: Any],
    ) -> GuestMethodArea {
        GuestMethodArea(entries: { M.allCases.map { ($0.rawValue, $0.spec) } }) { method, params in
            guard let m = M(rawValue: method) else { return nil }
            return try handle(m, admit(m.spec, GuestLegacyNames.params(of: method, params)))
        }
    }

    /// The first area that answers `method` runs it; no area answering is an unknown method.
    static func dispatch(_ areas: [GuestMethodArea], method: String, params: [String: Any]) throws -> [String: Any] {
        let method = GuestLegacyNames.methods[method] ?? method
        for area in areas {
            if let result = try area.execute(method, params) { return result }
        }
        throw GuestAPIError.unsupportedMethod(method)
    }

    static func flag(_ params: [String: Any], _ key: String, default fallback: Bool = false) -> Bool {
        (params[key] as? NSNumber)?.boolValue ?? fallback
    }

    static func admit(_ spec: MethodSpec, _ params: [String: Any]) throws -> [String: Any] {
        let declared = Set(spec.params.map(\.name))
        let admitted = params.filter { declared.contains($0.key) }
        let action: ForceAction? = switch spec.force {
        case .never: nil
        case let .always(_, action): action
        case let .when(key, _, action): flag(admitted, key) ? action : nil
        }
        if let action, !flag(params, "force") {
            throw GuestAPIError.invalidRequest("Pass force: true to \(try action(admitted))")
        }
        return admitted
    }

    static func catalog(_ areas: [GuestMethodArea]) -> [String: Any] {
        let methods: [[String: Any]] = areas.flatMap { $0.entries() }.map { name, spec in
            let force = switch spec.force {
            case .never: "never"
            case .always: "always"
            case let .when(key, _, _): "when:" + key
            }
            let params = spec.params.map { param -> [String: Any] in
                var entry: [String: Any] = [
                    "name": param.name, "type": param.type.rawValue, "required": param.required, "description": param.description,
                ]
                if let values = param.values { entry["enum"] = values }
                if let value = param.defaultValue { entry["default"] = value }
                if let min = param.min { entry["minimum"] = min }
                if let max = param.max { entry["maximum"] = max }
                return entry
            }
            var entry: [String: Any] = ["name": name, "description": spec.summary, "params": params, "force": force]
            if let text = spec.force.text { entry["force_action"] = text }
            if let result = spec.result {
                entry["result"] = result.filter { $0.presence != .hidden }.sorted { $0.name < $1.name }.map {
                    ["name": $0.name, "type": $0.type.rawValue, "required": $0.presence == .required, "open": $0.isOpen, "nullable": $0.isNullable] as [String: Any]
                }
            }
            return entry
        }
        return ["methods": methods]
    }
}

// MARK: - Names Before the Renames

/// The names guest methods and their params had before they followed one set
/// of rules (`processes.spawn`, `timeout_ms`, `input.swipe` `from`/`to`).
/// Older clients still send them, so they are translated to today's before a
/// request is admitted; `methods.list` and the docs name only today's.
enum GuestLegacyNames {
    static let methods = ["process.spawn": "processes.spawn"]

    /// Per method, a param in seconds and the millisecond param it became.
    static let seconds: [String: [(old: String, new: String)]] = [
        "location.current": [("timeout", "timeout_ms")],
        "processes.spawn": [("timeout_seconds", "timeout_ms")],
        "screen.unlock": [("timeout", "timeout_ms")],
        "script.eval": [("timeout", "timeout_ms")],
        "setup.settle": [("timeout_s", "timeout_ms"), ("poll_s", "poll_ms")],
        "ui.wait": [("timeout", "timeout_ms")],
        "ui.wait_gone": [("timeout", "timeout_ms")],
    ]

    /// `params` with the old names of `method` turned into today's. A new
    /// name the request also carries wins; a value that is not a number is
    /// passed on as it is, so it fails the way the new param would.
    static func params(of method: String, _ params: [String: Any]) -> [String: Any] {
        var params = params
        for (old, new) in seconds[method] ?? [] where params[new] == nil {
            guard let value = params.removeValue(forKey: old) else { continue }
            params[new] = (value as? NSNumber).map { NSNumber(value: $0.doubleValue * 1000) } ?? value
        }
        if method == "input.swipe", params["from"] == nil, params["to"] == nil,
           let x1 = params["x1"], let y1 = params["y1"], let x2 = params["x2"], let y2 = params["y2"]
        {
            params["from"] = [x1, y1]
            params["to"] = [x2, y2]
        }
        return params
    }
}
