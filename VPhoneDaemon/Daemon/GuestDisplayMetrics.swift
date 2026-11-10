import CoreFoundation
import Foundation

/// Display configuration metrics do not require an interface orientation.
/// They describe the owned default-main FrontBoard monitor, not a capture or
/// an input transform. CADisplay inventory is not used to choose a panel.
enum GuestDisplayMetrics {
    static func report(from layout: [String: Any]) -> [String: Any] {
        guard isTrue(layout["available"]) else {
            return unavailable(layout["reason"] as? String ?? "No current FrontBoard layout was available")
        }
        guard let monitors = layout["monitors"] as? [[String: Any]], monitors.count == 1,
              let monitor = monitors.first, isTrue(monitor["available"]),
              monitor["monitor_source"] as? String == "default_main" else {
            return unavailable("A unique available default-main FrontBoard monitor is required")
        }
        guard let bounds = rect(monitor["bounds"]), let reference = rect(monitor["reference_bounds"]) else {
            return unavailable("FrontBoard bounds or reference bounds are invalid")
        }
        guard let displayID = number(monitor["display_id"]), displayID > 0,
              displayID <= Double(UInt32.max), displayID.rounded() == displayID else {
            return unavailable("FrontBoard display identity is invalid")
        }
        guard let scale = number(monitor["point_scale"]), scale > 0 else {
            return unavailable("FrontBoard point scale is invalid")
        }
        return [
            "available": true, "source": "frontboard_default_main", "reason": "",
            "display_id": Int(displayID), "bounds": bounds,
            "reference_bounds": reference, "point_scale": scale,
        ]
    }

    private static func unavailable(_ reason: String) -> [String: Any] {
        ["available": false, "source": "frontboard_default_main",
         "reason": reason.isEmpty ? "No current FrontBoard layout was available" : reason]
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func rect(_ value: Any?) -> [String: Double]? {
        guard let value = value as? [String: Any],
              let x = number(value["x"]), let y = number(value["y"]), x == 0, y == 0,
              let width = number(value["width"]), let height = number(value["height"]),
              width > 0, height > 0 else { return nil }
        return ["x": x, "y": y, "width": width, "height": height]
    }
}
