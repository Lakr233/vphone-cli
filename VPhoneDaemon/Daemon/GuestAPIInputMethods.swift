import Foundation

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
                                               .hidden("error", .string),
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
            MethodSpec(.required("from", .array, "Start point as [x, y] in screen points"),
                       .required("to", .array, "End point as [x, y] in screen points"),
                       .optional("seconds", .number, "Swipe duration in seconds; above 0, at most 60", default: 0.3, max: 60),
                       .optional("steps", .integer, "Number of intermediate touch moves", default: 20, min: 1, max: 2000),
                       summary: "Swipe from one screen point to another.", result: [.required("from", .array), .required("to", .array)])
        case .inputDrag:
            MethodSpec(.required("points", .array, "Path of 2 to 1000 [x, y] pairs in screen points"),
                       .optional("seconds", .number, "Duration of the drag in seconds; above 0, at most 60", default: 0.5, max: 60),
                       .optional("hold", .number, "Seconds to hold at the first point before moving, 0 to 60", default: 0.5, min: 0, max: 60),
                       .optional("steps", .integer, "Touch moves in total; at least one per segment, at most 2000", default: 20, min: 1, max: 2000),
                       summary: "Press at the first point and drag through the given points, as when moving an icon.", result: [.required("count", .integer), .required("points", .integer)])
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
                                .required("count", .integer),
                                .optional("elapsed_ms", .number),
                                .optional("elements", .array),
                                .hidden("error", .string),
                                .optional("filtering_applied", .boolean),
                                .optional("foreground_after", .object),
                                .optional("foreground_before", .object),
                                .optional("format", .string),
                                .optional("limits", .object),
                                .optional("native_exception", .string),
                                .optional("parent_checks", .object),
                                .optional("pid", .integer),
                                .optional("queries", .integer),
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
                                .optional("truncation_reasons", .array)])
        case .uiElementAt: MethodSpec(.required("x", .number, "Screen x in points, inside the screen", min: 0), .required("y", .number, "Screen y in points, inside the screen", min: 0),
                                           summary: "Return the accessibility element at a screen point.", result: [.optional("element", .object),
                                               .hidden("error", .string),
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
                       .optional("timeout_ms", .number, "Milliseconds to wait before failing, 0 to 60000", default: 10000, min: 0, max: 60000),
                       summary: "Wait until an element matching text or identifier appears (ui.wait) or disappears (ui.wait_gone).", result: [.required("disappeared", .boolean),
                                .required("element", .object),
                                .required("found", .boolean),
                                .required("waited_ms", .integer)])
        case .uiOcr: MethodSpec(.optional("languages", .array, "Recognition language codes, at least one", default: ["en-US"]),
                                      .optional("min_confidence", .number, "Minimum confidence of a text block to include", default: 0.3, min: 0, max: 1),
                                      summary: "Read the text on screen with OCR and return text blocks with positions.", result: [.required("blocks", .array), .required("count", .integer), .required("engine", .string)])
        case .uiDescribe: MethodSpec(summary: "Capture a screenshot with the on-screen elements and OCR text to describe the current screen.", result: [.required("context_changed", .boolean),
                                              .optional("elements", .object),
                                              .required("frontmost", .object),
                                              .optional("ocr", .object),
                                              .required("screen", .object),
                                              .required("screenshot", .object)])
        }
    }
}
