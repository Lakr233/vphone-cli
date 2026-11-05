import CoreFoundation
import Foundation
import IcliKit

enum InputMethod: String, GuestMethod {
    case inputButton = "input.button"
    case inputKey = "input.key"
    case inputType = "input.type"
    case inputPaste = "input.paste"
    case inputTap = "input.tap"
    case inputDoubleTap = "input.double_tap"
    case inputLongPress = "input.long_press"
    case inputSwipe = "input.swipe"
    case inputDrag = "input.drag"
    case inputTouchSequence = "input.touch_sequence"

    var spec: MethodSpec {
        switch self {
        case .inputButton: MethodSpec(.required("name", .string))
        case .inputKey: MethodSpec(.required("name", .string))
        case .inputType: MethodSpec(.required("text", .string), .optional("delay_ms", .number))
        case .inputPaste: MethodSpec(.required("text", .string))
        case .inputTap: MethodSpec(.required("x", .number), .required("y", .number))
        case .inputDoubleTap:
            MethodSpec(.required("x", .number),
                       .required("y", .number),
                       .optional("interval", .number))
        case .inputLongPress:
            MethodSpec(.required("x", .number),
                       .required("y", .number),
                       .optional("seconds", .number))
        case .inputSwipe:
            MethodSpec(.required("x1", .number),
                       .required("y1", .number),
                       .required("x2", .number),
                       .required("y2", .number),
                       .optional("seconds", .number),
                       .optional("steps", .integer))
        case .inputDrag:
            MethodSpec(.required("points", .array),
                       .optional("seconds", .number),
                       .optional("hold", .number),
                       .optional("steps", .integer))
        case .inputTouchSequence: MethodSpec(.required("events", .array), .optional("normalized", .boolean))
        }
    }
}

enum InterfaceMethod: String, GuestMethod {
    case uiTree = "ui.tree"
    case accessibilityTree = "accessibility.tree"
    case uiElementAt = "ui.element_at"
    case uiTapElement = "ui.tap_element"
    case uiWait = "ui.wait"
    case uiWaitGone = "ui.wait_gone"
    case uiOcr = "ui.ocr"
    case uiDescribe = "ui.describe"

    var spec: MethodSpec {
        switch self {
        case .uiTree, .accessibilityTree:
            MethodSpec(.optional("nested", .boolean),
                       .optional("max_elements", .integer),
                       .optional("visible_only", .boolean),
                       .optional("clickable_only", .boolean),
                       .optional("limit", .integer),
                       .optional("max_depth", .integer),
                       .optional("timeout_ms", .integer))
        case .uiElementAt: MethodSpec(.required("x", .number), .required("y", .number))
        case .uiTapElement:
            MethodSpec(.optional("text", .string),
                       .optional("identifier", .string),
                       .optional("role", .string),
                       .optional("match", .string),
                       .optional("index", .integer))
        case .uiWait, .uiWaitGone:
            MethodSpec(.optional("text", .string),
                       .optional("identifier", .string),
                       .optional("role", .string),
                       .optional("match", .string),
                       .optional("index", .integer),
                       .optional("timeout", .number))
        case .uiOcr: MethodSpec(.optional("languages", .array), .optional("min_confidence", .number))
        case .uiDescribe: MethodSpec()
        }
    }
}

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
            return try tap(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case .inputDoubleTap:
            return try doubleTap(
                x: requiredNumber(params, "x"),
                y: requiredNumber(params, "y"),
                interval: number(params, "interval", default: 0.1),
            )
        case .inputLongPress:
            return try longPress(
                x: requiredNumber(params, "x"),
                y: requiredNumber(params, "y"),
                seconds: number(params, "seconds", default: 1),
            )
        case .inputSwipe:
            return try swipe(
                x1: requiredNumber(params, "x1"),
                y1: requiredNumber(params, "y1"),
                x2: requiredNumber(params, "x2"),
                y2: requiredNumber(params, "y2"),
                seconds: number(params, "seconds", default: 0.3),
                steps: (params["steps"] as? NSNumber)?.intValue ?? 20,
            )
        case .inputDrag:
            guard let rows = params["points"] as? [[NSNumber]], rows.count >= 2,
                  rows.allSatisfy({ $0.count == 2 })
            else {
                throw GuestAPIError.invalidRequest("points must be at least two [x, y] pairs")
            }
            return try drag(
                points: rows.map { ($0[0].doubleValue, $0[1].doubleValue) },
                seconds: number(params, "seconds", default: 0.5),
                hold: number(params, "hold", default: 0.5),
                steps: (params["steps"] as? NSNumber)?.intValue ?? 20,
            )
        case .inputTouchSequence:
            guard let events = params["events"] as? [[String: Any]] else {
                throw GuestAPIError.invalidRequest("events must be an array of {phase, x, y, delay_ms}")
            }
            let json = try String(decoding: JSONSerialization.data(withJSONObject: events), as: UTF8.self)
            return try touchSequence(
                TouchEvent.list(fromJSON: json),
                normalized: bool(params, "normalized", default: true),
            )
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
