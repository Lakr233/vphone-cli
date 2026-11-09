import Foundation
import IcliPrivate

// UIKit/HID boundaries only. The scope and conversion core are compiled from
// the pinned Icli checkout, and the daemon's real handlers call this witness.
public enum IcliError: Error {
    case failed(String), unavailable(String)
    public var code: String { "unavailable" }
    public var message: String { switch self { case let .failed(s), let .unavailable(s): s } }
}

public enum PointInputWitness {
    nonisolated(unsafe) public static var locked = true
    nonisolated(unsafe) public static var snapshotReads = 0
    nonisolated(unsafe) public static var points: [[Double]] = []
    public static func metrics() -> IcliInterfaceGeometry {
        var geometry = IcliInterfaceGeometry()
        if !icli_interface_geometry_current(&geometry) {
            geometry = IcliInterfaceGeometry(width: 678, height: 466, reference_width: 466,
                                            reference_height: 678, scale: 3, orientation: 90)
        }
        return geometry
    }
    static func point(_ x: Double, _ y: Double, normalized: Bool = false) throws {
        if normalized {
            precondition(!icli_interface_geometry_current(nil))
            points.append([x, y])
        } else {
            let geometry = metrics()
            guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < geometry.width, y < geometry.height else {
                throw IcliError.failed("point outside reported screen")
            }
            var nx = 0.0, ny = 0.0
            icli_interface_geometry_point_to_digitizer(geometry, x, y, &nx, &ny)
            points.append([nx, ny])
        }
    }
}

public func screenInfo() -> [String: Any] {
    let m = PointInputWitness.metrics()
    return ["width": m.width, "height": m.height, "scale": m.scale,
            "orientation": m.orientation, "locked": PointInputWitness.locked, "screen_off": false]
}
public func collectDeviceSnapshot() throws -> [String: Any] {
    PointInputWitness.snapshotReads += 1
    return ["lock": ["locked": PointInputWitness.locked, "screen_off": false]]
}
public func tap(x: Double, y: Double) throws -> [String: Any] { try PointInputWitness.point(x, y); return [:] }
public func doubleTap(x: Double, y: Double, interval: Double) throws -> [String: Any] { try tap(x: x, y: y) }
public func longPress(x: Double, y: Double, seconds: Double) throws -> [String: Any] { try tap(x: x, y: y) }
public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double, steps: Int) throws -> [String: Any] {
    try PointInputWitness.point(x1, y1); try PointInputWitness.point(x2, y2); return [:]
}
public func drag(points: [(Double, Double)], seconds: Double, hold: Double, steps: Int) throws -> [String: Any] {
    for (x, y) in points { try PointInputWitness.point(x, y) }; return [:]
}
public enum TouchPhase: String { case down, move, up }
public struct TouchEvent {
    let x: Double, y: Double
    public static func list(fromJSON json: String) throws -> [TouchEvent] {
        let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        return try rows.map { row in
            guard let phase = row["phase"] as? String, TouchPhase(rawValue: phase) != nil,
                  let x = row["x"] as? NSNumber, let y = row["y"] as? NSNumber else { throw IcliError.failed("invalid event") }
            return TouchEvent(x: x.doubleValue, y: y.doubleValue)
        }
    }
}
public func touch(_ phase: TouchPhase, x: Double, y: Double, normalized: Bool) throws -> [String: Any] {
    try PointInputWitness.point(x, y, normalized: normalized); return [:]
}
public func touchSequence(_ events: [TouchEvent], normalized: Bool) throws -> [String: Any] {
    for event in events { try PointInputWitness.point(event.x, event.y, normalized: normalized) }; return [:]
}
private func unscoped() -> [String: Any] { precondition(!icli_interface_geometry_current(nil)); return [:] }
public func pressButton(_ name: String) throws -> [String: Any] { unscoped() }
public func pressKey(_ name: String) throws -> [String: Any] { unscoped() }
public func typeText(_ text: String, delayMS: Double) throws -> [String: Any] { unscoped() }
public func pasteText(_ text: String) throws -> [String: Any] { unscoped() }
public struct ElementSelector { public init(text: String?, identifier: String?, role: String?, match: String, index: Int) throws {} }
public func uiElements(maxElements: Int, visibleOnly: Bool, clickableOnly: Bool, limit: Int?) throws -> [String: Any] { unscoped() }
public func elementAt(x: Double, y: Double) throws -> [String: Any] { unscoped() }
public func tapElement(_ selector: ElementSelector) throws -> [String: Any] { unscoped() }
public func waitForElement(_ selector: ElementSelector, appear: Bool, timeout: Double) throws -> [String: Any] { unscoped() }
public func recognizeScreen(languages: [String], minConfidence: Float) throws -> [String: Any] { unscoped() }
public func describeScreen() throws -> [String: Any] { unscoped() }
