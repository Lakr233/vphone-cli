import CoreFoundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import IcliKit
import VphonedNative

private func semanticBoolean(_ value: Any?) -> Bool? {
    guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return value.boolValue
}

private func semanticNumber(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite else { return nil }
    return value.doubleValue
}

private func semanticRect(_ value: Any?) -> CGRect? {
    guard let value = value as? [String: Any],
          let x = semanticNumber(value["x"]), let y = semanticNumber(value["y"]),
          let width = semanticNumber(value["width"]), let height = semanticNumber(value["height"]),
          width > 0, height > 0, (x + width).isFinite, (y + height).isFinite else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
}

private struct SemanticGeometry {
    let foreground: ForegroundApp
    let geometry: InterfaceGeometry
    let sceneFrame: CGRect
    let identity: NSDictionary

    static func current() throws -> Self {
        let foreground = try GuestAPI.verifiedForeground()
        let layout = vp_display_layout_for_application(foreground.bundle)
        guard try GuestAPI.verifiedForeground() == foreground,
              let monitors = layout["monitors"] as? [[String: Any]], let monitor = monitors.first,
              semanticBoolean(monitor["elements_available"]) == true,
              semanticBoolean(monitor["elements_truncated"]) == false,
              let scenes = monitor["application_scenes"] as? [[String: Any]]
        else { throw sceneError }
        // SpringBoard's own UI has no application scene: geometry comes from the monitor alone.
        if foreground.bundle == GuestAPI.springboardBundle, scenes.isEmpty {
            return try sceneless(foreground: foreground, layout: layout, monitor: monitor)
        }
        guard scenes.count == 1,
              let scene = scenes.first, scene["bundle_id"] as? String == foreground.bundle,
              let identifier = scene["identifier"] as? String, !identifier.isEmpty,
              let frame = semanticRect(scene["frame"]), let reference = semanticRect(scene["reference_frame"])
        else { throw sceneError }
        let geometry = try GuestPointGeometry.geometry(from: layout)
            ?? nativeGeometry(layout: layout, monitor: monitor, frame: frame, reference: reference)
        guard CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height).contains(frame),
              CGRect(x: 0, y: 0, width: geometry.referenceWidth, height: geometry.referenceHeight).contains(reference)
        else { throw IcliError.unavailable("Foreground scene is outside the active display") }
        let keys = ["display_id", "hardware_identifier", "bounds", "reference_bounds", "point_scale", "interface_orientation"]
        var identity = monitor.filter { keys.contains($0.key) }
        identity["scene"] = scene
        return Self(foreground: foreground, geometry: geometry, sceneFrame: frame, identity: NSDictionary(dictionary: identity))
    }

    private static let sceneError = IcliError.unavailable("Cannot bind accessibility coordinates to a unique foreground scene")

    private static func sceneless(foreground: ForegroundApp, layout: [String: Any],
                                  monitor: [String: Any]) throws -> Self {
        guard let bounds = semanticRect(monitor["bounds"]), let reference = semanticRect(monitor["reference_bounds"]),
              let scale = semanticNumber(monitor["point_scale"]), let orientation = semanticNumber(monitor["interface_orientation"])
        else { throw sceneError }
        // SpringBoard has no scene to cross-check: the monitor's own values are the geometry, 0 meaning upright.
        guard let degrees = [0.0: 0, 1.0: 0, 2.0: 180, 3.0: 270, 4.0: 90][orientation] else { throw sceneError }
        let geometry = try InterfaceGeometry(width: bounds.width, height: bounds.height, referenceWidth: reference.width,
                                             referenceHeight: reference.height, scale: scale, orientation: degrees)
        let keys = ["display_id", "hardware_identifier", "bounds", "reference_bounds", "point_scale", "interface_orientation"]
        return Self(foreground: foreground, geometry: geometry,
                    sceneFrame: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
                    identity: NSDictionary(dictionary: monitor.filter { keys.contains($0.key) }))
    }

    // FrontBoard can report orientation zero on a single-display phone. Use
    // native axes only when the full-screen scene agrees in both spaces.
    private static func nativeGeometry(layout: [String: Any], monitor: [String: Any],
                                       frame: CGRect, reference: CGRect) throws -> InterfaceGeometry {
        guard let displays = layout["cadisplays"] as? [[String: Any]], displays.count < 16 else {
            throw IcliError.unavailable("Cannot verify a complete display inventory for an unoriented scene")
        }
        // Only type 2 is a wireless output. Keep an unlit integrated panel
        // in the count even if its current bounds are zero.
        let candidates = displays.filter {
            semanticNumber($0["displayType"]) != 2 || semanticBoolean($0["empty_bounds"]) != true
        }
        guard candidates.count == 1, let display = candidates.first, semanticRect(display["bounds"]) != nil,
              let id = semanticNumber(display["displayId"]), id == semanticNumber(monitor["display_id"]),
              frame == semanticRect(monitor["bounds"]), reference == semanticRect(monitor["reference_bounds"]),
              frame == reference, let scale = semanticNumber(monitor["point_scale"]) else {
            throw IcliError.unavailable("An unoriented scene requires one display with matching native and scene bounds")
        }
        return try InterfaceGeometry(width: frame.width, height: frame.height, referenceWidth: reference.width,
                                     referenceHeight: reference.height, scale: scale, orientation: 0)
    }

    func confirm() throws {
        let after = try Self.current()
        guard foreground == after.foreground, identity.isEqual(after.identity) else {
            throw IcliError.unavailable("Foreground process, scene or display changed during the accessibility query")
        }
    }
}

extension GuestAPI {
    /// Keep the query's clipping and its eventual HID conversion on one
    /// immutable geometry. Recheck ownership after AX, before any input.
    /// These observations cannot lock the OS scene against a later transition.
    static func semanticElements(maxElements: Int = 2000, visibleOnly: Bool = true,
                                 clickableOnly: Bool = false, limit: Int? = nil) throws -> [String: Any] {
        try readSemanticElements(maxElements: maxElements, visibleOnly: visibleOnly,
                                 clickableOnly: clickableOnly, limit: limit).0
    }

    private static func readSemanticElements(maxElements: Int = 2000, visibleOnly: Bool = true,
                                            clickableOnly: Bool = false, limit: Int? = nil) throws -> ([String: Any], SemanticGeometry) {
        let snapshot = try SemanticGeometry.current()
        let result = try withInterfaceGeometry(snapshot.geometry) {
            snapshot.foreground.bundle == springboardBundle
                ? try springboardElements(pid: snapshot.foreground.pid, maxElements: maxElements,
                                          visibleOnly: visibleOnly, clickableOnly: clickableOnly, limit: limit)
                : try uiElements(maxElements: maxElements, visibleOnly: visibleOnly, clickableOnly: clickableOnly, limit: limit)
        }
        guard result["source"] as? String == "ax", semanticNumber(result["pid"]) == Double(snapshot.foreground.pid) else {
            throw IcliError.unavailable("Accessibility query did not belong to the verified foreground process")
        }
        try snapshot.confirm()
        return (result, snapshot)
    }

    /// IcliKit's `uiElements` against SpringBoard's pid: its own helper needs a verified frontmost app.
    private static func springboardElements(pid: Int, maxElements: Int, visibleOnly: Bool,
                                            clickableOnly: Bool, limit: Int?) throws -> [String: Any] {
        guard (1 ... 2000).contains(maxElements), limit == nil || (limit! > 0 && limit! <= 2000) else {
            throw IcliError.failed("element limits must be between 1 and 2000")
        }
        var result = try decodeIcliAX(vp_icli_ax_elements(Int32(pid), Int32(maxElements)))
        var elements = result["elements"] as? [[String: Any]] ?? []
        if visibleOnly { elements = elements.filter { $0["visible"] as? Bool == true } }
        if clickableOnly { elements = elements.filter { $0["clickable"] as? Bool == true } }
        if let limit { elements = Array(elements.prefix(limit)) }
        result["elements"] = elements
        result["count"] = elements.count
        return result
    }

    /// The JSON dictionary an icli accessibility call returned, or its `error` as a failure.
    static func decodeIcliAX(_ json: String?) throws -> [String: Any] {
        guard let json, let result = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw IcliError.failed("invalid AX response")
        }
        if let message = result["error"] as? String { throw IcliError.failed(message) }
        return result
    }

    /// `ui.element_at`: IcliKit's query, except at SpringBoard, which it cannot address.
    static func elementAtForeground(x: Double, y: Double) throws -> [String: Any] {
        let foreground = try verifiedForeground()
        guard foreground.bundle == springboardBundle else { return try elementAt(x: x, y: y) }
        let screen = screenInfo()
        guard x.isFinite, y.isFinite, x >= 0, y >= 0,
              let width = (screen["width"] as? NSNumber)?.doubleValue, x < width,
              let height = (screen["height"] as? NSNumber)?.doubleValue, y < height
        else { throw IcliError.failed("coordinates must be finite points inside the screen") }
        return try decodeIcliAX(vp_icli_ax_element_at(Int32(foreground.pid), x, y))
    }

    // Mirrors ElementSelector.matches in Icli 1.0.0 (bd25a1d0),
    // Sources/IcliKit/Input/Screen.swift. Check it when updating the Icli pin.
    private static func semanticMatch(_ element: [String: Any], selector: ElementSelector) -> Bool {
        if let role = selector.role {
            if role == "control" {
                if element["clickable"] as? Bool != true { return false }
            } else if role != "element", element["role"] as? String != role { return false }
        }
        if let identifier = selector.identifier {
            return element["identifier"] as? String == identifier || element["label"] as? String == identifier
        }
        guard let text = selector.text else { return false }
        return ["label", "identifier", "value"].contains { key in
            let value = element[key] as? String ?? ""
            return selector.match == "exact"
                ? value.compare(text, options: .caseInsensitive) == .orderedSame
                : value.localizedCaseInsensitiveContains(text)
        }
    }

    private static func semanticSelection(_ result: [String: Any], selector: ElementSelector) throws -> [String: Any]? {
        guard result["truncated"] as? Bool != true else {
            throw IcliError.failed("AX query was truncated; narrow the screen before selecting an element")
        }
        let hits = (result["elements"] as? [[String: Any]] ?? []).filter { semanticMatch($0, selector: selector) }
        return hits.indices.contains(selector.index) ? hits[selector.index] : nil
    }

    static func tapSemanticElement(_ selector: ElementSelector) throws -> [String: Any] {
        let (result, snapshot) = try readSemanticElements()
        guard let hit = try semanticSelection(result, selector: selector) else { throw IcliError.failed("element not found") }
        guard let x = semanticNumber(hit["x"]), let y = semanticNumber(hit["y"]) else { throw IcliError.failed("element has no tap point") }
        guard snapshot.sceneFrame.contains(CGPoint(x: x, y: y)) else {
            throw IcliError.unavailable("Accessibility activation point is outside the verified foreground scene")
        }
        _ = try withInterfaceGeometry(snapshot.geometry) { try tap(x: x, y: y) }
        return ["tapped": true, "element": hit]
    }

    static func waitForSemanticElement(_ selector: ElementSelector, appear: Bool, timeout: TimeInterval) throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        repeat {
            let result = try semanticElements()
            let hit = try semanticSelection(result, selector: selector)
            if (hit != nil) == appear {
                return ["found": hit != nil, "disappeared": hit == nil,
                        "waited_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000), "element": hit ?? [:]]
            }
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(0.3, remaining))
        } while ProcessInfo.processInfo.systemUptime - started <= timeout
        throw IcliError.failed("element wait timed out")
    }
}
