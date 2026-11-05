import Foundation

enum GuestAPIError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case unsupportedMethod(String)
    case operationFailed(String)
    /// The request would repeat work the guest has already done. The code is
    /// sent as the error code so a client can tell it apart from a failure.
    case alreadyDone(code: String, message: String)
    /// The guest's Location Services switch is off, so locationd gives no
    /// client a location. vphoned leaves the switch to the guest's Settings.
    case locationServicesOff

    var description: String {
        switch self {
        case let .invalidRequest(message), let .operationFailed(message): message
        case let .unsupportedMethod(method): "Unknown method: \(method)"
        case let .alreadyDone(_, message): message
        case .locationServicesOff:
            "Location Services are turned off in the guest. Turn them on in Settings > Privacy & Security > Location Services."
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

enum ParamType: String { case string, integer, number, boolean, array, object, any }

struct MethodParam {
    let name: String
    let type: ParamType
    let required: Bool
    static func required(_ name: String, _ type: ParamType) -> MethodParam { .init(name: name, type: type, required: true) }
    static func optional(_ name: String, _ type: ParamType) -> MethodParam { .init(name: name, type: type, required: false) }
}

/// The action text completes "Pass force: true to <action>". It is computed from the admitted
/// params and may throw: it runs exactly the validation today's handler ran before
/// `requireForce`, so an invalid unforced request fails with the same error as today.
typealias ForceAction = ([String: Any]) throws -> String

enum MethodForce {
    case never
    case always(ForceAction)
    case when(String, ForceAction) // the named param, read with `flag`, must be true
}

struct MethodSpec {
    let params: [MethodParam]
    let force: MethodForce
    init(_ params: MethodParam..., force: MethodForce = .never) {
        self.params = params
        self.force = force
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
        case let .always(action): action
        case let .when(key, action): flag(admitted, key) ? action : nil
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
            case let .when(key, _): "when:" + key
            }
            let params = spec.params.map { ["name": $0.name, "type": $0.type.rawValue, "required": $0.required] as [String: Any] }
            return ["name": name, "params": params, "force": force]
        }
        return ["methods": methods]
    }
}
