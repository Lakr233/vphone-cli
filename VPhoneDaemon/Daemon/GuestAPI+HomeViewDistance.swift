import Foundation
import VphonedNative

enum GuestHomeViewDistance {
    static var capabilities: [String] {
        vp_homeview_distance_available() ? ["homeview_distance"] : []
    }

    static func call(mode: String? = nil) throws -> [String: Any] {
        let pointer = mode.map { $0.withCString { vp_homeview_distance_copy_json($0) } }
            ?? vp_homeview_distance_copy_json(nil)
        guard let pointer else {
            throw GuestAPIError.operationFailed("HomeView distance service returned no reply")
        }
        defer { free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestAPIError.operationFailed("Invalid HomeView distance service reply")
        }
        guard envelope["ok"] as? Bool == true else {
            throw GuestAPIError.operationFailed(envelope["error"] as? String ?? "HomeView distance operation failed")
        }
        return envelope["result"] as? [String: Any] ?? [:]
    }
}

enum HomeViewDistanceMethod: String, GuestMethod {
    case homeviewDistanceGet = "homeview.distance.get"
    case homeviewDistanceSet = "homeview.distance.set"

    var spec: MethodSpec {
        switch self {
        case .homeviewDistanceGet: MethodSpec(result: [.required("applied", .any),
                                                       .required("available", .boolean),
                                                       .required("backlight_state", .any),
                                                       .required("display_style", .any),
                                                       .required("level_of_detail", .integer),
                                                       .required("mode", .any),
                                                       .required("override_active", .any),
                                                       .required("reset_scope", .string)])
        case .homeviewDistanceSet: MethodSpec(.required("mode", .string), .optional("reset_environment", .boolean), result: [.required("applied", .any),
                                                       .required("available", .boolean),
                                                       .required("backlight_state", .any),
                                                       .required("display_style", .any),
                                                       .required("level_of_detail", .integer),
                                                       .required("mode", .any),
                                                       .required("override_active", .any),
                                                       .required("reset_scope", .string)])
        }
    }
}

extension GuestAPI {
    static func executeHomeViewDistance(_ m: HomeViewDistanceMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .homeviewDistanceGet:
            return try GuestHomeViewDistance.call()
        case .homeviewDistanceSet:
            let mode = try string(params, "mode")
            if let rejection = GuestHomeViewDistancePolicy.rejection(mode: mode, resetEnvironment: params["reset_environment"] as? Bool == true) {
                throw GuestAPIError.invalidRequest(rejection)
            }
            return try GuestHomeViewDistance.call(mode: mode)
        }
    }
}
