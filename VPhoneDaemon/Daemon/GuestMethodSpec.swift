import Foundation

enum GuestAPIError: Error, CustomStringConvertible {
    case invalidRequest(String, hint: String? = nil)
    case unsupportedMethod(String, hint: String? = nil)
    case operationFailed(String, hint: String? = nil)
    /// The named target (file, app, process, service) does not exist.
    case notFound(String, hint: String? = nil)
    /// The platform, OS or a component cannot do this.
    case unavailable(String, hint: String? = nil)
    /// The OS refused for lack of entitlement or access.
    case permission(String, hint: String? = nil)
    /// A destructive call came without `force: true`.
    case forceRequired(String, hint: String? = nil)
    /// The request would repeat work the guest has already done. The code is
    /// sent as the error code so a client can tell it apart from a failure.
    case alreadyDone(code: String, message: String)
    /// The guest's Location Services switch is off, so locationd gives no
    /// client a location. `location.services {enabled:true}` turns it on.
    case locationServicesOff

    var description: String {
        switch self {
        case let .invalidRequest(message, _), let .operationFailed(message, _), let .notFound(message, _),
             let .unavailable(message, _), let .permission(message, _), let .forceRequired(message, _): message
        case let .unsupportedMethod(method, _):
            "Unknown method: \(method.count > 64 ? String(method.prefix(64)) + "…" : method)"
        case let .alreadyDone(_, message): message
        case .locationServicesOff:
            "Location Services are turned off in the guest. Turn them on with location.services {enabled:true}."
        }
    }

    var code: String {
        switch self {
        case .invalidRequest: "invalid_param"
        case .notFound, .unsupportedMethod: "not_found"
        case .unavailable: "unavailable"
        case .permission: "permission"
        case .forceRequired: "force_required"
        case .operationFailed: "invalid_operation"
        case let .alreadyDone(code, _): code
        case .locationServicesOff: "location_services_off"
        }
    }

    /// One line naming the fix; nil for errors that carry none.
    var hint: String? {
        switch self {
        case let .invalidRequest(_, hint), let .unsupportedMethod(_, hint), let .operationFailed(_, hint),
             let .notFound(_, hint), let .unavailable(_, hint), let .permission(_, hint), let .forceRequired(_, hint): hint
        case .alreadyDone, .locationServicesOff: nil
        }
    }

    /// The wire `error` object. `hint` is present only when the error has one.
    var wireBody: [String: Any] {
        var body: [String: Any] = ["code": code, "message": description]
        if let hint { body["hint"] = hint }
        return body
    }

    /// A producer's result whose `error` key reports a whole-call failure: the failure, thrown as
    /// `make(message)`; a result without an `error` string is returned as it is.
    static func inBandFailure(_ result: [String: Any], as make: (String) -> GuestAPIError) throws -> [String: Any] {
        if let message = result["error"] as? String { throw make(message) }
        return result
    }

    /// The candidate nearest `name` by Levenshtein distance, if within max(2, name.count / 3).
    /// Ties go to the first candidate. A name over 64 characters has no match.
    static func closest(_ name: String, _ candidates: [String]) -> String? {
        let a = Array(name)
        guard a.count <= 64 else { return nil }
        let limit = max(2, a.count / 3)
        var best: (name: String, distance: Int)?
        for candidate in candidates {
            let b = Array(candidate)
            guard abs(a.count - b.count) <= limit else { continue }
            var row = Array(0 ... b.count)
            for i in 0 ..< a.count {
                var previous = row[0]
                row[0] = i + 1
                for j in 0 ..< b.count {
                    let saved = row[j + 1]
                    row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (a[i] == b[j] ? 0 : 1))
                    previous = saved
                }
            }
            let distance = row[b.count]
            if distance <= limit, distance < (best?.distance ?? Int.max) { best = (candidate, distance) }
        }
        return best?.name
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
            return try handle(m, admit(m.spec, params))
        }
    }

    /// The first area that answers `method` runs it; no area answering is an unknown method.
    static func dispatch(_ areas: [GuestMethodArea], method: String, params: [String: Any]) throws -> [String: Any] {
        for area in areas {
            if let result = try area.execute(method, params) { return result }
        }
        let names = areas.flatMap { $0.entries().map(\.name) }.sorted()
        throw GuestAPIError.unsupportedMethod(
            method, hint: GuestAPIError.closest(method, names).map { "Did you mean `\($0)`?" },
        )
    }

    static func flag(_ params: [String: Any], _ key: String, default fallback: Bool = false) -> Bool {
        (params[key] as? NSNumber)?.boolValue ?? fallback
    }

    static func admit(_ spec: MethodSpec, _ params: [String: Any]) throws -> [String: Any] {
        let names = spec.params.map(\.name)
        let declared = Set(names)
        let unknown = params.keys.filter { !declared.contains($0) && $0 != "force" }.sorted()
        if !unknown.isEmpty {
            let shown = unknown.prefix(5).joined(separator: ", ")
            let more = unknown.count > 5 ? " and \(unknown.count - 5) more" : ""
            let hint = if names.isEmpty {
                "This method takes no params"
            } else {
                (GuestAPIError.closest(unknown[0], names).map { "Did you mean `\($0)`? " } ?? "")
                    + "Valid params: \(names.joined(separator: ", "))"
            }
            throw GuestAPIError.invalidRequest("Unknown param: \(shown)\(more)", hint: hint)
        }
        let admitted = params.filter { declared.contains($0.key) }
        let action: ForceAction? = switch spec.force {
        case .never: nil
        case let .always(_, action): action
        case let .when(key, _, action): flag(admitted, key) ? action : nil
        }
        if let action, !flag(params, "force") {
            throw GuestAPIError.forceRequired(
                "Pass force: true to \(try action(admitted))",
                hint: "Confirm with the user, then repeat the call with force: true",
            )
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

extension GuestAPIError {
    /// An OS failure as a coded error: a missing target (ENOENT, ESRCH) is `notFound`, a refusal for
    /// lack of access (EACCES, EPERM) is `permission`, anything else stays `operationFailed`.
    static func fromErrno(_ code: Int32, _ message: String) -> GuestAPIError {
        switch code {
        case ENOENT, ESRCH: .notFound(message)
        case EACCES, EPERM: .permission(message)
        default: .operationFailed(message)
        }
    }
}
