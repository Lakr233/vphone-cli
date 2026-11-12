import Foundation
import VphonedNative

/// SoundBoard's complete SBSDebugInterface, restricted to its fixed operation
/// catalog. The native bridge checks each method's ABI before invoking it.
enum GuestHomePodDebug {
    static var capabilities: [String] {
        vp_homepod_debug_available() ? ["homepod_debug"] : []
    }

    static func call(_ operation: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        guard let text = String(data: encoded, encoding: .utf8),
              let json = operation.withCString({ operation in
                  text.withCString { vp_homepod_debug_copy_json(operation, $0) }
              })
        else { throw GuestAPIError.operationFailed("Could not call SoundBoard debug interface") }
        defer { free(json) }
        let data = Data(bytes: json, count: strlen(json))
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestAPIError.operationFailed("Invalid SoundBoard debug reply")
        }
        guard envelope["ok"] as? Bool == true else {
            throw GuestAPIError.operationFailed(envelope["error"] as? String ?? "SoundBoard debug operation failed")
        }
        return envelope["result"] as? [String: Any] ?? [:]
    }
}

extension GuestAPI {
    static func executeHomePodDebug(_ m: HomePodDebugMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .homepodDebugCatalog:
            return try GuestHomePodDebug.call("catalog")
        case .homepodDebugCall:
            let operation = try string(params, "operation")
            guard let arguments = params["arguments"] as? [String: Any] else {
                throw GuestAPIError.invalidRequest("arguments must be an object")
            }
            return try GuestHomePodDebug.call(operation, arguments: arguments)
        }
    }
}
