import Foundation

enum AccessibilityMethod: String, GuestMethod {
    case accessibilityGet = "accessibility.get"
    case accessibilitySet = "accessibility.set"

    var spec: MethodSpec {
        switch self {
        case .accessibilityGet:
            MethodSpec(.optional("feature", .string, "One feature to read; every feature when omitted",
                                 values: ["voiceover", "assistive_touch", "switch_control", "reduce_motion", "full_keyboard_access", "text_size"]),
                       summary: "Read the accessibility features: VoiceOver, AssistiveTouch, Switch Control, Reduce Motion, keyboard access, text size.",
                       result: [.required("features", .object), .required("unavailable", .array)])
        case .accessibilitySet:
            MethodSpec(.required("feature", .string, "Feature to change",
                                 values: ["voiceover", "assistive_touch", "switch_control", "reduce_motion", "full_keyboard_access", "text_size"]),
                       .required("value", .any, "true or false; for text_size one of xs, s, m, l, xl, xxl, xxxl, ax1 to ax5"),
                       summary: "Change one accessibility feature persistently and return the value read back.",
                       result: [.required("feature", .string), .required("value", .any)])
        }
    }
}
