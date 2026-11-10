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
        case .inputButton: MethodSpec(.required("name", .string, "Hardware button name", values: ["home", "power", "volume-up", "volume-down", "mute", "wake"]),
                                           summary: "Press a hardware button on the guest: home, power, volume up or down, mute, or wake the screen.", result: [.optional("active_category", .string),
                                               .optional("active_muted", .boolean),
                                               .optional("active_volume", .number),
                                               .optional("before", .object),
                                               .optional("button", .string),
                                               .optional("error", .string),
                                               .optional("locked", .boolean),
                                               .optional("method", .string),
                                               .optional("screen_off", .boolean)])
        case .inputKey: MethodSpec(.required("name", .string, "Key name such as return, tab, escape, space, up, home, or a letter a-z; modifiers combine as cmd+a"),
                                        summary: "Press and release one named keyboard key.", result: [.required("dispatched", .boolean), .required("key", .string)])
        case .inputType: MethodSpec(.required("text", .string, "Text to type, 1 to 65536 bytes"),
                                         .optional("delay_ms", .number, "Pause after each character in milliseconds", default: 30, min: 0, max: 1000),
                                         summary: "Type text into the focused field one keystroke at a time.", result: [.required("method", .string), .required("sent", .integer)])
        case .inputPaste: MethodSpec(.required("text", .string, "Text to paste, 1 to 65536 bytes"),
                                          summary: "Send text to the focused field in one Unicode input event, without typing it key by key.", result: [.required("method", .string), .required("sent", .integer)])
        case .inputTap: MethodSpec(.required("x", .number, "Screen x in points", min: 0), .required("y", .number, "Screen y in points", min: 0),
                                       summary: "Tap the screen once at a point.", result: [.required("x", .number), .required("y", .number)])
        case .inputDoubleTap:
            MethodSpec(.required("x", .number, "Screen x in points", min: 0),
                       .required("y", .number, "Screen y in points", min: 0),
                       .optional("interval", .number, "Seconds between the two taps; above 0, at most 1", default: 0.1, max: 1),
                       summary: "Tap the screen twice quickly at a point.", result: [.required("x", .number), .required("y", .number)])
        case .inputLongPress:
            MethodSpec(.required("x", .number, "Screen x in points", min: 0),
                       .required("y", .number, "Screen y in points", min: 0),
                       .optional("seconds", .number, "How long to hold the touch in seconds; above 0, at most 60", default: 1, max: 60),
                       summary: "Press and hold the screen at a point.", result: [.required("seconds", .number), .required("x", .number), .required("y", .number)])
        case .inputSwipe:
            MethodSpec(.required("x1", .number, "Start x in screen points", min: 0),
                       .required("y1", .number, "Start y in screen points", min: 0),
                       .required("x2", .number, "End x in screen points", min: 0),
                       .required("y2", .number, "End y in screen points", min: 0),
                       .optional("seconds", .number, "Swipe duration in seconds; above 0, at most 60", default: 0.3, max: 60),
                       .optional("steps", .integer, "Number of intermediate touch moves", default: 20, min: 1, max: 2000),
                       summary: "Swipe from one screen point to another.", result: [.required("from", .array), .required("to", .array)])
        case .inputDrag:
            MethodSpec(.required("points", .array, "Path of 2 to 1000 [x, y] pairs in screen points"),
                       .optional("seconds", .number, "Duration of the drag in seconds; above 0, at most 60", default: 0.5, max: 60),
                       .optional("hold", .number, "Seconds to hold at the first point before moving, 0 to 60", default: 0.5, min: 0, max: 60),
                       .optional("steps", .integer, "Touch moves in total; at least one per segment, at most 2000", default: 20, min: 1, max: 2000),
                       summary: "Press at the first point and drag through the given points, as when moving an icon.", result: [.required("points", .integer)])
        case .inputTouchSequence: MethodSpec(.required("events", .array, "1 to 10000 objects with phase (down, move or up), x, y and optional delay_ms (0 to 60000)"),
                                                  .optional("normalized", .boolean, "True reads x and y as 0 to 1 fractions of the screen; false reads screen points", default: true),
                                                  summary: "Play a scripted multi-event touch sequence for custom gestures.", result: [.required("duration_ms", .integer),
                                                      .required("events", .integer),
                                                      .required("finger_down", .boolean),
                                                      .required("normalized", .boolean)])
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
            MethodSpec(.optional("nested", .boolean, "Return the nested hierarchy; cannot combine with visible_only, clickable_only true or limit", default: false),
                       .optional("max_elements", .integer, "Maximum elements to read, 1 to 2000", default: 500, min: 1, max: 2000),
                       .optional("visible_only", .boolean, "Flat mode only: return only visible elements", default: true),
                       .optional("clickable_only", .boolean, "Flat mode only: return only clickable elements", default: false),
                       .optional("limit", .integer, "Flat mode only: cap on the number of elements returned, 1 to 2000", min: 1, max: 2000),
                       .optional("max_depth", .integer, "Nested mode only: maximum tree depth", default: 32, min: 1, max: 32),
                       .optional("timeout_ms", .integer, "Nested mode only: time budget in milliseconds", default: 5000, min: 100, max: 10000),
                       summary: "Return the on-screen accessibility elements of the frontmost app, flat or nested.", result: [.optional("action_eligible", .boolean),
                                .required("count", .any),
                                .optional("elapsed_ms", .any),
                                .optional("elements", .array),
                                .optional("error", .string),
                                .optional("filtering_applied", .boolean),
                                .optional("foreground_after", .object),
                                .optional("foreground_before", .object),
                                .optional("format", .string),
                                .optional("limits", .object),
                                .optional("native_exception", .any),
                                .optional("parent_checks", .object),
                                .optional("pid", .integer),
                                .optional("queries", .any),
                                .optional("readiness", .object),
                                .optional("relationship_source", .string),
                                .optional("roots", .array),
                                .optional("runtime", .object),
                                .optional("source", .string),
                                .optional("status", .string),
                                .optional("switches_after_restore", .object),
                                .optional("switches_before", .object),
                                .optional("symbols", .object),
                                .optional("truncated", .boolean),
                                .optional("truncation_reasons", .any)])
        case .uiElementAt: MethodSpec(.required("x", .number, "Screen x in points, inside the screen", min: 0), .required("y", .number, "Screen y in points, inside the screen", min: 0),
                                           summary: "Return the accessibility element at a screen point.", result: [.optional("element", .object),
                                               .optional("error", .string),
                                               .optional("source", .string),
                                               .optional("x", .number),
                                               .optional("y", .number)])
        case .uiTapElement:
            MethodSpec(.optional("text", .string, "Text in the element label, identifier or value; ignored if identifier is set; one of the two is required"),
                       .optional("identifier", .string, "Identifier to match against the element identifier or label; text or identifier is required"),
                       .optional("role", .string, "Role filter: control for clickable, element for any, or an exact role such as button"),
                       .optional("match", .string, "How text is compared, ignoring case", values: ["contains", "exact"], default: "contains"),
                       .optional("index", .integer, "Which match to use when several elements match, from 0", default: 0, min: 0),
                       summary: "Find an on-screen element by text or identifier, optionally narrowed by role, and tap it.", result: [.required("element", .object), .required("tapped", .boolean)])
        case .uiWait, .uiWaitGone:
            MethodSpec(.optional("text", .string, "Text in the element label, identifier or value; ignored if identifier is set; one of the two is required"),
                       .optional("identifier", .string, "Identifier to match against the element identifier or label; text or identifier is required"),
                       .optional("role", .string, "Role filter: control for clickable, element for any, or an exact role such as button"),
                       .optional("match", .string, "How text is compared, ignoring case", values: ["contains", "exact"], default: "contains"),
                       .optional("index", .integer, "Which match to use when several elements match, from 0", default: 0, min: 0),
                       .optional("timeout", .number, "Seconds to wait before failing, 0 to 60", default: 10, min: 0, max: 60),
                       summary: "Wait until an element matching text or identifier appears (ui.wait) or disappears (ui.wait_gone).", result: [.required("disappeared", .boolean),
                                .required("element", .object),
                                .required("found", .boolean),
                                .required("waited_ms", .integer)])
        case .uiOcr: MethodSpec(.optional("languages", .array, "Recognition language codes, at least one", default: ["en-US"]),
                                      .optional("min_confidence", .number, "Minimum confidence of a text block to include", default: 0.3, min: 0, max: 1),
                                      summary: "Read the text on screen with OCR and return text blocks with positions.", result: [.required("blocks", .array), .required("count", .integer), .required("engine", .string)])
        case .uiDescribe: MethodSpec(summary: "Capture a screenshot with the on-screen elements and OCR text to describe the current screen.", result: [.required("context_changed", .boolean),
                                              .optional("elements", .any),
                                              .required("frontmost", .object),
                                              .optional("ocr", .any),
                                              .required("screen", .object),
                                              .required("screenshot", .object)])
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
