import Foundation

/// Guest-free validation shared by vphoned and its regression harness.
enum GuestProcessSpawnPolicy {
    static let executables: [String: String] = [
        "ps": "/bin/ps", "launchctl": "/bin/launchctl", "log": "/usr/bin/log",
    ]
    static let outputLimit = 64 * 1024

    static func validate(executable name: String?, arguments: [String], timeout: Double) -> String? {
        guard let name, executables[name] != nil else { return "unknown executable" }
        guard arguments.count <= 16 else { return "too many arguments" }
        guard arguments.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) }) else { return "invalid argument" }
        guard arguments.joined().utf8.count <= 2048 else { return "arguments too long" }
        guard timeout.isFinite, timeout >= 0.1, timeout <= 10 else { return "timeout_ms must be 100–10000" }
        return nil
    }
}
