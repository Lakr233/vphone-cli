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

extension GuestAPI {
    static func executeHomeViewDistance(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "homeview.distance.get":
            return try GuestHomeViewDistance.call()
        case "homeview.distance.set":
            let mode = try string(params, "mode")
            if let rejection = GuestHomeViewDistancePolicy.rejection(mode: mode, resetEnvironment: params["reset_environment"] as? Bool == true) {
                throw GuestAPIError.invalidRequest(rejection)
            }
            return try GuestHomeViewDistance.call(mode: mode)
        default:
            return nil
        }
    }
}
