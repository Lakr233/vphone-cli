import CoreFoundation
import Foundation
import IcliKit
import VphonedNative

extension GuestAPI {
    /// AX enable/restore is process-wide. Interface operations share this lock,
    /// so a flat query cannot race this opt-in native snapshot's restoration.
    static let interfaceLock = NSRecursiveLock()

    private static func hierarchyInteger(
        _ params: [String: Any], _ key: String, default fallback: Int, range: ClosedRange<Int>,
    ) throws -> Int {
        guard let value = params[key] else { return fallback }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              range.contains(number.intValue)
        else { throw GuestAPIError.invalidRequest("\(key) must be an integer in \(range)") }
        return number.intValue
    }

    private static func hierarchyForeground() throws -> [String: Any] {
        let front = frontmostApp()
        guard front["verified"] as? Bool == true,
              let bundle = front["bundle_id"] as? String, !bundle.isEmpty,
              let running = try runningApps()["apps"] as? [[String: Any]],
              let pid = running.first(where: { $0["bundle_id"] as? String == bundle })?["pid"] as? Int,
              pid > 1, pid <= Int(Int32.max)
        else { throw GuestAPIError.operationFailed("Cannot verify foreground application and PID") }
        return ["bundle_id": bundle, "pid": pid, "verified": true, "source": front["source"] ?? ""]
    }

    static func nestedHierarchy(_ params: [String: Any]) throws -> [String: Any] {
        guard params["limit"] == nil,
              !bool(params, "clickable_only"), params["visible_only"] == nil
        else {
            throw GuestAPIError.invalidRequest("Nested snapshots preserve all structural nodes; filtering and limit are unsupported", hint: "Omit limit, clickable_only and visible_only, or set nested to false")
        }
        let count = try hierarchyInteger(params, "max_elements", default: 500, range: 1 ... 2000)
        let depth = try hierarchyInteger(params, "max_depth", default: 32, range: 1 ... 32)
        let duration = try hierarchyInteger(params, "timeout_ms", default: 5000, range: 100 ... 10000)
        let before = try hierarchyForeground()
        let pid = before["pid"] as! Int
        let native = vp_ax_hierarchy(Int32(pid), Int32(count), Int32(depth), Int32(duration))
        guard let report = native as? [String: Any] else {
            throw GuestAPIError.operationFailed("Native hierarchy returned no diagnostic snapshot")
        }
        let after = try hierarchyForeground()
        guard NSDictionary(dictionary: before).isEqual(to: after) else {
            throw GuestAPIError.operationFailed("Foreground application changed during hierarchy snapshot")
        }
        return report.merging([
            "foreground_before": before, "foreground_after": after,
            "action_eligible": false, "filtering_applied": false,
            "runtime": ["daemon_binary_hash": binaryHash, "pid": ProcessInfo.processInfo.processIdentifier],
        ], uniquingKeysWith: { _, value in value })
    }
}
