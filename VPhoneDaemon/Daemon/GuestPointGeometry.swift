import CoreFoundation
import Foundation
import IcliKit

/// Oriented point coordinates for the owned default-main display. This does
/// not bind a capture source or establish an application's AX coordinate space.
enum GuestPointGeometry {
    static func geometry(from layout: [String: Any]) throws -> InterfaceGeometry {
        func unavailable(_ reason: String) -> IcliError {
            .unavailable("Active point geometry is unavailable: \(reason)")
        }
        guard isTrue(layout["available"]), isTrue(layout["geometry_available"]),
              let monitors = layout["monitors"] as? [[String: Any]], monitors.count == 1,
              let monitor = monitors.first, isTrue(monitor["available"]),
              isTrue(monitor["geometry_available"]), monitor["monitor_source"] as? String == "default_main",
              let bounds = dimensions(monitor["bounds"]),
              let reference = dimensions(monitor["reference_bounds"]),
              let displayID = number(monitor["display_id"]), displayID > 0,
              displayID <= Double(UInt32.max), displayID.rounded() == displayID,
              let scale = number(monitor["point_scale"]), scale > 0,
              let rawOrientation = number(monitor["interface_orientation"]),
              let orientation = [1.0: 0, 2.0: 180, 3.0: 270, 4.0: 90][rawOrientation]
        else { throw unavailable("a unique oriented default-main display is required") }
        do {
            return try InterfaceGeometry(width: bounds.width, height: bounds.height,
                                         referenceWidth: reference.width, referenceHeight: reference.height,
                                         scale: scale, orientation: orientation)
        } catch {
            throw unavailable("upright and reference bounds do not match the interface orientation")
        }
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func dimensions(_ value: Any?) -> (width: Double, height: Double)? {
        guard let value = value as? [String: Any],
              let x = number(value["x"]), let y = number(value["y"]), x == 0, y == 0,
              let width = number(value["width"]), let height = number(value["height"]),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
