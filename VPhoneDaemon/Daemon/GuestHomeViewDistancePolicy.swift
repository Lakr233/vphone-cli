import Foundation

/// RPC validation is independent of the native transport so an unacknowledged
/// environment-wide reset is rejected before opening a guest service connection.
enum GuestHomeViewDistancePolicy {
    static let modes: Set<String> = ["automatic", "near", "standard", "far"]

    static func rejection(mode: String, resetEnvironment: Bool) -> String? {
        guard modes.contains(mode) else {
            return "mode must be automatic, near, standard or far"
        }
        if mode == "automatic", !resetEnvironment {
            return "automatic requires reset_environment=true; native reset clears persona, display style, detail and backlight simulation overrides"
        }
        return nil
    }
}
