import CoreFoundation
import Foundation
import IcliKit
import VphonedNative

extension GuestAPI {
    /// Conversion and input validation must stay on this synchronous thread.
    static func withActivePointGeometry<T>(_ operation: () throws -> T) throws -> T {
        #if os(tvOS)
        // IcliKit refuses point input on tvOS before consulting its geometry.
        return try operation()
        #else
        guard let geometry = try GuestPointGeometry.geometry(from: vp_display_layout()) else {
            return try operation()
        }
        return try withInterfaceGeometry(geometry, operation)
        #endif
    }

    static func activeScreenInfo() throws -> [String: Any] {
        try withActivePointGeometry { screenInfo() }
    }

    static func activeScreenState(lock existingLock: [String: Any]? = nil) -> [String: Any] {
        do { return try activeScreenInfo() }
        catch {
            let failure = error as? IcliError
            var state: [String: Any] = ["available": false, "error": [
                "code": failure?.code ?? "unavailable",
                "message": failure?.message ?? String(describing: error),
            ]]
            // Lock metadata is independent of capture and oriented geometry.
            let lock = existingLock ?? (try? collectDeviceSnapshot()["lock"] as? [String: Any])
            if let lock {
                for key in ["locked", "screen_off"] {
                    if let value = lock[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
                        state[key] = value.boolValue
                    }
                }
            }
            return state
        }
    }

    static func executeTouch(_ params: [String: Any]) throws -> [String: Any] {
        guard let phase = (params["phase"] as? String).flatMap(TouchPhase.init(rawValue:)) else {
            throw GuestAPIError.invalidRequest("phase must be down, move or up")
        }
        let normalized = params["normalized"] as? Bool ?? true
        if let edge = params["edge"] as? Int, edge != 0 {
            guard normalized else {
                throw GuestAPIError.invalidRequest("edge touch coordinates are normalized 0..1 only")
            }
            vp_hid_touch_edge(touchPhaseCode(phase), number(params, "x"), number(params, "y"), Int32(edge))
            return edgeTouchResult(phase, edge: edge)
        }
        let x = number(params, "x"), y = number(params, "y")
        if normalized { return try touch(phase, x: x, y: y, normalized: true) }
        return try withActivePointGeometry { try touch(phase, x: x, y: y, normalized: false) }
    }

    static func edgeTouchResult(_ phase: TouchPhase, edge: Int) -> [String: Any] {
        ["phase": phase.rawValue, "edge": edge]
    }
}
