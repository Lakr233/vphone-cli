import Foundation

// MARK: - Accessibility Element

/// One row of `ui.tree`. icli serializes each AX element with `label`,
/// `identifier`, `value` (string or number), `role` (`button`, `text`,
/// `element`), `traits`, `enabled`, `clickable`, `visible`, `frame`
/// {x, y, width, height} and the activation point `x`, `y`. Frames and the
/// activation point are in upright interface points, the space `input.tap`
/// takes; SpringBoard's fixed-space frames are converted guest side.
struct VPhoneUIInspectorElement: Identifiable {
    /// Position in the guest's AX order.
    let id: Int
    let role: String
    let label: String
    let identifier: String
    let value: String
    let traits: Int
    let isEnabled: Bool
    let isClickable: Bool
    let isVisible: Bool
    let frame: CGRect
    let tapPoint: CGPoint
    let details: [VPhoneUIInspectorDetail]
    let json: String

    init?(index: Int, object: [String: Any]) {
        guard let rect = object.object("frame"),
              let x = rect.double("x"), let y = rect.double("y"),
              let width = rect.double("width"), let height = rect.double("height")
        else { return nil }
        id = index
        role = object.string("role") ?? ""
        label = object.string("label") ?? ""
        identifier = object.string("identifier") ?? ""
        value = object["value"].map { value in
            (value as? String) ?? VPhoneUIInspectorRecord.display(value)
        } ?? ""
        traits = object.int("traits") ?? 0
        isEnabled = object.bool("enabled") ?? true
        isClickable = object.bool("clickable") ?? false
        isVisible = object.bool("visible") ?? true
        frame = CGRect(x: x, y: y, width: width, height: height)
        tapPoint = CGPoint(x: object.double("x") ?? frame.midX, y: object.double("y") ?? frame.midY)
        details = VPhoneUIInspectorRecord.details(object)
        json = VPhoneUIInspectorRecord.json(object)
    }

    // MARK: - Display

    var frameText: String {
        VPhoneUIInspectorRecord.frame(frame)
    }

    /// Reading order: top to bottom, then left to right.
    var frameOrder: Double {
        frame.minY * 100_000 + frame.minX
    }

    var clickableOrder: Int {
        isClickable ? 1 : 0
    }

    var enabledOrder: Int {
        isEnabled ? 1 : 0
    }

    /// The text a person would use to name this element.
    var summary: String {
        [label, identifier, value, role].first { !$0.isEmpty } ?? ""
    }
}
