import Foundation
import IcliKit
import IcliPrivate
import VphonedNative

enum GuestAPI {
    static let interfaceLock = NSRecursiveLock()
    static func nestedHierarchy(_ params: [String: Any]) throws -> [String: Any] { [:] }
    static func number(_ p: [String: Any], _ k: String, default d: Double = .nan) -> Double {
        if let n = p[k] as? NSNumber { return n.doubleValue }; return (p[k] as? String).flatMap(Double.init) ?? d
    }
    static func requiredNumber(_ p: [String: Any], _ k: String) throws -> Double {
        let n = number(p, k); guard n.isFinite else { throw GuestAPIError.invalidRequest(k) }; return n
    }
    static func string(_ p: [String: Any], _ k: String) throws -> String { p[k] as? String ?? "" }
    static func optionalString(_ p: [String: Any], _ k: String) -> String? { p[k] as? String }
    static func bool(_ p: [String: Any], _ k: String, default d: Bool = false) -> Bool { GuestMethodArea.flag(p, k, default: d) }
    static func touchPhaseCode(_ phase: TouchPhase) -> Int32 { switch phase { case .down: 0; case .move: 1; case .up: 3 } }
}

func layout(orientation: Int = 4) -> [String: Any] {
    let sideways = orientation == 3 || orientation == 4
    func rect(_ width: Double, _ height: Double) -> [String: Any] { ["x": 0, "y": 0, "width": width, "height": height] }
    return ["available": true, "geometry_available": true, "monitors": [[
        "available": true, "geometry_available": true, "monitor_source": "default_main", "display_id": 1,
        "bounds": rect(sideways ? 951 : 669, sideways ? 669 : 951),
        "reference_bounds": rect(669, 951), "point_scale": 3, "interface_orientation": orientation,
    ]]]
}

func unorientedLayout(rootGeometry: Any = false, monitorGeometry: Any = false) -> [String: Any] {
    let bounds: [String: Any] = ["x": 0, "y": 0, "width": 744, "height": 1133]
    return ["available": true, "geometry_available": rootGeometry, "monitors": [[
        "available": true, "geometry_available": monitorGeometry, "monitor_source": "default_main", "display_id": 1,
        "bounds": bounds, "reference_bounds": bounds, "point_scale": 2, "interface_orientation": 0,
    ]]]
}

func rejects(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("invalid geometry or input was accepted") } catch {}
}

@main enum PointGeometryTests {
    static func main() throws {
        LayoutWitness.layout = layout()
        // The real handler must validate and normalize beyond the legacy
        // 678-point capture width, using the actual Icli C conversion core.
        _ = try GuestMethodArea.dispatch([.make(InputMethod.self, GuestAPI.executeInput)], method: "input.tap", params: ["x": 900, "y": 300])
        let point = PointInputWitness.points.last!
        precondition(abs(point[0] - 300 / 669.0) < 1e-9 && abs(point[1] - 51 / 951.0) < 1e-9)
        precondition(!icli_interface_geometry_current(nil))
        for orientation in 1 ... 4 {
            LayoutWitness.layout = layout(orientation: orientation)
            let screen = try GuestAPI.activeScreenInfo()
            precondition((screen["orientation"] as? NSNumber)?.intValue == [1: 0, 2: 180, 3: 270, 4: 90][orientation])
            precondition(screen["locked"] as? Bool == true && screen["screen_off"] as? Bool == false)
        }
        LayoutWitness.layout = unorientedLayout()
        do {
            // FrontBoard's 744x1133-point report cannot replace Icli's independent
            // 678x466-point contract without a known orientation.
            let legacy = screenInfo()
            let reported = try GuestAPI.activeScreenInfo()
            precondition(NSDictionary(dictionary: reported).isEqual(NSDictionary(dictionary: legacy)))
            let snapshots = PointInputWitness.snapshotReads
            precondition(NSDictionary(dictionary: GuestAPI.activeScreenState()).isEqual(NSDictionary(dictionary: legacy)))
            precondition(PointInputWitness.snapshotReads == snapshots)
            _ = try GuestMethodArea.dispatch([.make(InputMethod.self, GuestAPI.executeInput)],
                                            method: "input.tap", params: ["x": 600, "y": 300])
            let fallbackPoint = PointInputWitness.points.last!
            precondition(abs(fallbackPoint[0] - 300 / 466.0) < 1e-9)
            precondition(abs(fallbackPoint[1] - 78 / 678.0) < 1e-9)
            for method in [InputMethod.inputDoubleTap, .inputLongPress, .inputSwipe, .inputDrag] {
                _ = try GuestAPI.executeInput(method, ["x": 600, "y": 300, "from": [600, 300], "to": [500, 200],
                                                      "points": [[600, 300], [500, 200]]])
            }
            _ = try GuestAPI.executeTouch(["phase": "down", "x": 600, "y": 300, "normalized": false])
            _ = try GuestAPI.executeInput(.inputTouchSequence,
                                         ["normalized": false, "events": [["phase": "down", "x": 600, "y": 300]]])
            let inputs = PointInputWitness.points.count
            rejects { _ = try GuestAPI.executeInput(.inputTap, ["x": 900, "y": 300]) }
            precondition(PointInputWitness.points.count == inputs, "fallback bypassed Icli point bounds")
            precondition(!icli_interface_geometry_current(nil), "fallback installed an active override")
        } catch {
            print("Orientation-zero legacy input regression: \(error)")
            exit(1)
        }
        for report in [unorientedLayout(rootGeometry: 0), unorientedLayout(monitorGeometry: 0),
                       unorientedLayout(rootGeometry: true), unorientedLayout(monitorGeometry: true)] {
            rejects { _ = try GuestPointGeometry.geometry(from: report) }
        }
        for changes: [String: Any] in [["available": 1], ["monitor_source": "other"], ["display_id": true],
                                       ["point_scale": 0], ["interface_orientation": true],
                                       ["bounds": ["x": 1, "y": 0, "width": 744, "height": 1133]],
                                       ["reference_bounds": ["x": 0, "y": 0, "width": -1, "height": 1133]]] {
            var report = unorientedLayout()
            var rows = report["monitors"] as! [[String: Any]]
            rows[0].merge(changes, uniquingKeysWith: { _, new in new })
            report["monitors"] = rows
            rejects { _ = try GuestPointGeometry.geometry(from: report) }
        }
        var ambiguous = unorientedLayout()
        ambiguous["monitors"] = (ambiguous["monitors"] as! [[String: Any]]) + (ambiguous["monitors"] as! [[String: Any]])
        rejects { _ = try GuestPointGeometry.geometry(from: ambiguous) }
        var invalid = layout()
        func monitor(_ changes: [String: Any]) -> [String: Any] {
            var report = layout(); var rows = report["monitors"] as! [[String: Any]]
            rows[0].merge(changes, uniquingKeysWith: { _, new in new }); report["monitors"] = rows; return report
        }
        let bad = [layout(orientation: 0), monitor(["point_scale": true]), monitor(["display_id": true]),
                   monitor(["display_id": 1.5]), monitor(["display_id": Double(UInt32.max) + 1]),
                   monitor(["point_scale": Double.infinity]), monitor(["interface_orientation": true]),
                   monitor(["reference_bounds": ["x": 0, "y": 0, "width": 10, "height": 10]]),
                   monitor(["bounds": ["x": 1, "y": 0, "width": 951, "height": 669]]),
                   monitor(["available": 1]), monitor(["monitor_source": "other"])]
        for report in bad { rejects { _ = try GuestPointGeometry.geometry(from: report) } }
        invalid["monitors"] = (layout()["monitors"] as! [[String: Any]]) + (layout()["monitors"] as! [[String: Any]])
        rejects { _ = try GuestPointGeometry.geometry(from: invalid) }
        rejects { _ = try GuestPointGeometry.geometry(from: [:]) }
        LayoutWitness.layout = layout(orientation: 0)
        let before = LayoutWitness.reads
        rejects { _ = try GuestAPI.executeInput(.inputTap, ["x": "invalid", "y": 1]) }
        rejects { _ = try GuestAPI.executeInput(.inputDrag, ["points": [[1]]]) }
        rejects { _ = try GuestAPI.executeInput(.inputTouchSequence, ["events": [["phase": "bad", "x": 0, "y": 0]]]) }
        precondition(LayoutWitness.reads == before, "invalid parameters reached layout observation")
        _ = try GuestAPI.executeInput(.inputTouchSequence, ["events": [["phase": "down", "x": 0.5, "y": 0.5]]])
        _ = try GuestAPI.executeTouch(["phase": "down", "x": 0.5, "y": 0.5])
        let edge = try GuestAPI.executeTouch(["phase": "down", "edge": 1, "normalized": true, "x": 0.5, "y": 0.5])
        precondition(edge["phase"] as? String == "down" && edge["edge"] as? Int == 1)
        rejects { _ = try GuestAPI.executeTouch(["phase": "down", "edge": 1, "normalized": false]) }
        _ = try GuestAPI.executeInput(.inputButton, ["name": "home"])
        _ = try GuestAPI.executeInterface(.uiTree, [:])
        precondition(LayoutWitness.reads == before, "normalized, native or AX operations acquired point geometry")
        let state = GuestAPI.activeScreenState()
        precondition(state["available"] as? Bool == false && state["width"] == nil && state["orientation"] == nil)
        precondition(state["locked"] as? Bool == true && state["screen_off"] as? Bool == false)
        let snapshots = PointInputWitness.snapshotReads
        let reused = GuestAPI.activeScreenState(lock: ["locked": false, "screen_off": true])
        precondition(reused["locked"] as? Bool == false && reused["screen_off"] as? Bool == true)
        precondition(PointInputWitness.snapshotReads == snapshots, "device.info repeated its existing snapshot")
        LayoutWitness.layout = layout()
        for flag: Any in [false, NSNumber(value: 0)] {
            _ = try GuestAPI.executeInput(.inputTouchSequence, ["normalized": flag, "events": [["phase": "down", "x": 900, "y": 300]]])
            _ = try GuestAPI.executeTouch(["phase": "down", "normalized": flag, "x": 900, "y": 300])
        }
        for method in [InputMethod.inputDoubleTap, .inputLongPress, .inputSwipe, .inputDrag] {
            _ = try GuestAPI.executeInput(method, ["x": 900, "y": 300, "from": [900, 300], "to": [800, 400],
                                                  "points": [[900, 300], [800, 400]]])
        }
        rejects { _ = try GuestAPI.withActivePointGeometry { throw IcliError.failed("input failed") } }
        precondition(!icli_interface_geometry_current(nil), "input error leaked geometry")
        print("Active point handlers, screen state and geometry refusal checks passed")
    }
}
