import CoreFoundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import IcliKit
import VphonedNative

private struct SemanticForeground: Equatable {
    let bundle: String
    let pid: Int

    static func current() throws -> Self {
        let front = frontmostApp()
        guard semanticBoolean(front["verified"]) == true,
              let bundle = front["bundle_id"] as? String, !bundle.isEmpty,
              let apps = try runningApps()["apps"] as? [[String: Any]]
        else { throw IcliError.unavailable("Cannot verify the foreground application for accessibility input") }
        let matches = apps.filter { $0["bundle_id"] as? String == bundle }
        guard matches.count == 1, let number = semanticNumber(matches[0]["pid"]),
              let pid = Int(exactly: number), pid > 1, pid <= Int(Int32.max)
        else { throw IcliError.unavailable("Cannot verify a unique foreground process for accessibility input") }
        return Self(bundle: bundle, pid: pid)
    }
}

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
    let foreground: SemanticForeground
    let geometry: InterfaceGeometry
    let sceneFrame: CGRect
    let identity: NSDictionary

    static func current() throws -> Self {
        let foreground = try SemanticForeground.current()
        let layout = vp_display_layout_for_application(foreground.bundle)
        guard try SemanticForeground.current() == foreground,
              let geometry = try GuestPointGeometry.geometry(from: layout),
              let monitors = layout["monitors"] as? [[String: Any]], let monitor = monitors.first,
              semanticBoolean(monitor["elements_available"]) == true,
              semanticBoolean(monitor["elements_truncated"]) == false,
              let scenes = monitor["application_scenes"] as? [[String: Any]], scenes.count == 1,
              let scene = scenes.first, scene["bundle_id"] as? String == foreground.bundle,
              let identifier = scene["identifier"] as? String, !identifier.isEmpty,
              let frame = semanticRect(scene["frame"]), let reference = semanticRect(scene["reference_frame"]),
              CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height).contains(frame),
              CGRect(x: 0, y: 0, width: geometry.referenceWidth, height: geometry.referenceHeight).contains(reference)
        else { throw IcliError.unavailable("Cannot bind accessibility coordinates to a unique foreground scene and oriented display") }
        let keys = ["display_id", "hardware_identifier", "bounds", "reference_bounds", "point_scale", "interface_orientation"]
        var identity = monitor.filter { keys.contains($0.key) }
        identity["scene"] = scene
        return Self(foreground: foreground, geometry: geometry, sceneFrame: frame, identity: NSDictionary(dictionary: identity))
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
            try uiElements(maxElements: maxElements, visibleOnly: visibleOnly, clickableOnly: clickableOnly, limit: limit)
        }
        guard result["source"] as? String == "ax", semanticNumber(result["pid"]) == Double(snapshot.foreground.pid) else {
            throw IcliError.unavailable("Accessibility query did not belong to the verified foreground process")
        }
        try snapshot.confirm()
        return (result, snapshot)
    }

    // Icli exposes selector fields but keeps its matcher private. Preserve its
    // label/identifier, role and indexed-match contract while rechecking the
    // geometry after the AX query and before dispatch.
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
