import Darwin
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

    /// `data` cut to at most `cap` raw bytes; `truncated` is true when `data` was longer than `cap`.
    /// When the byte at index `cap` is a continuation byte, the cut drops back to the last lead byte
    /// at or below `cap` within 3 bytes, excluding that character; with no lead byte there, or any
    /// other byte at `cap`, the cut is at `cap`.
    static func cutOutput(_ data: Data, cap: Int) -> (data: Data, truncated: Bool) {
        guard data.count > cap else { return (data, false) }
        let bytes = Array(data)
        var cut = cap
        if bytes[cap] & 0xC0 == 0x80 {
            for index in stride(from: cap, through: max(0, cap - 3), by: -1) where bytes[index] & 0xC0 == 0xC0 {
                cut = index
                break
            }
        }
        return (Data(bytes[..<cut]), true)
    }
}
