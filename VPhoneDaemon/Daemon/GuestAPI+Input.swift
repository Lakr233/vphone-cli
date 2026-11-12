import CoreFoundation
import Foundation
import IcliKit

// MARK: - Buttons, Text, Gestures

extension GuestAPI {
    /// Gesture coordinates are screen points, as `device.screen` reports them.
    static func executeInput(_ m: InputMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .inputButton:
            return try pressButton(string(params, "name"))
        case .inputKey:
            return try pressKey(string(params, "name"))
        case .inputType:
            return try typeText(string(params, "text"), delayMS: number(params, "delay_ms", default: 30))
        case .inputPaste:
            return try pasteText(string(params, "text"))
        case .inputTap:
            let x = try requiredNumber(params, "x"), y = try requiredNumber(params, "y")
            return try withActivePointGeometry { try tap(x: x, y: y) }
        case .inputDoubleTap:
            let x = try requiredNumber(params, "x"), y = try requiredNumber(params, "y")
            let interval = number(params, "interval", default: 0.1)
            return try withActivePointGeometry { try doubleTap(x: x, y: y, interval: interval) }
        case .inputLongPress:
            let x = try requiredNumber(params, "x"), y = try requiredNumber(params, "y")
            let seconds = number(params, "seconds", default: 1)
            return try withActivePointGeometry { try longPress(x: x, y: y, seconds: seconds) }
        case .inputSwipe:
            let x1 = try requiredNumber(params, "x1"), y1 = try requiredNumber(params, "y1")
            let x2 = try requiredNumber(params, "x2"), y2 = try requiredNumber(params, "y2")
            let seconds = number(params, "seconds", default: 0.3)
            let steps = (params["steps"] as? NSNumber)?.intValue ?? 20
            return try withActivePointGeometry { try swipe(x1: x1, y1: y1, x2: x2, y2: y2, seconds: seconds, steps: steps) }
        case .inputDrag:
            guard let rows = params["points"] as? [[NSNumber]], rows.count >= 2,
                  rows.allSatisfy({ $0.count == 2 })
            else {
                throw GuestAPIError.invalidRequest("points must be at least two [x, y] pairs")
            }
            let points = rows.map { ($0[0].doubleValue, $0[1].doubleValue) }
            let seconds = number(params, "seconds", default: 0.5), hold = number(params, "hold", default: 0.5)
            let steps = (params["steps"] as? NSNumber)?.intValue ?? 20
            return try withActivePointGeometry { try drag(points: points, seconds: seconds, hold: hold, steps: steps) }
        case .inputTouchSequence:
            guard let events = params["events"] as? [[String: Any]] else {
                throw GuestAPIError.invalidRequest("events must be an array of {phase, x, y, delay_ms}")
            }
            let json = try String(decoding: JSONSerialization.data(withJSONObject: events), as: UTF8.self)
            let parsed = try TouchEvent.list(fromJSON: json)
            let normalized = bool(params, "normalized", default: true)
            if normalized { return try touchSequence(parsed, normalized: true) }
            return try withActivePointGeometry { try touchSequence(parsed, normalized: false) }
        }
    }

    // MARK: - Accessibility and OCR

    static func executeInterface(_ m: InterfaceMethod, _ params: [String: Any]) throws -> [String: Any] {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        switch m {
        case .uiTree, .accessibilityTree:
            if let value = params["nested"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw GuestAPIError.invalidRequest("nested must be a boolean")
                }
            }
            if bool(params, "nested") {
                return try nestedHierarchy(params)
            }
            return try uiElements(
                maxElements: (params["max_elements"] as? NSNumber)?.intValue ?? 500,
                visibleOnly: bool(params, "visible_only", default: true),
                clickableOnly: bool(params, "clickable_only"),
                limit: (params["limit"] as? NSNumber)?.intValue,
            )
        case .uiElementAt:
            return try elementAt(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case .uiTapElement:
            return try tapElement(selector(params))
        case .uiWait, .uiWaitGone:
            return try waitForElement(
                selector(params),
                appear: m == .uiWait,
                timeout: number(params, "timeout", default: 10),
            )
        case .uiOcr:
            try requireTextRecognition()
            return try recognizeScreen(
                languages: params["languages"] as? [String] ?? ["en-US"],
                minConfidence: Float(number(params, "min_confidence", default: 0.3)),
            )
        case .uiDescribe:
            try requireTextRecognition()
            return try describeScreen()
        }
    }

    /// IcliKit's OCR is Vision's, which watchOS does not ship: vphoned links
    /// it weakly, so its classes are nil on a watch.
    private static func requireTextRecognition() throws {
        guard NSClassFromString("VNRecognizeTextRequest") != nil else {
            throw GuestAPIError.operationFailed("Text recognition needs Vision, which this guest does not have")
        }
    }

    private static func selector(_ params: [String: Any]) throws -> ElementSelector {
        try ElementSelector(
            text: optionalString(params, "text"),
            identifier: optionalString(params, "identifier"),
            role: optionalString(params, "role"),
            match: optionalString(params, "match") ?? "contains",
            index: (params["index"] as? NSNumber)?.intValue ?? 0,
        )
    }
}
