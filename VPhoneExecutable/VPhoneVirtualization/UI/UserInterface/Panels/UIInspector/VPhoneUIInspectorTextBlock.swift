import Foundation

// MARK: - OCR Text Block

/// One block of `ui.ocr`. icli reports `text`, `confidence` (0…1) and the
/// block's center `x`, `y` plus `width`, `height`, all in screen points.
struct VPhoneUIInspectorTextBlock: Identifiable {
    let id: Int
    let text: String
    let confidence: Double
    let frame: CGRect
    let details: [VPhoneUIInspectorDetail]
    let json: String

    init?(index: Int, object: [String: Any]) {
        guard let x = object.double("x"), let y = object.double("y"),
              let width = object.double("width"), let height = object.double("height")
        else { return nil }
        id = index
        text = object.string("text") ?? ""
        confidence = object.double("confidence") ?? 0
        frame = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
        details = VPhoneUIInspectorRecord.details(object)
        json = VPhoneUIInspectorRecord.json(object)
    }

    var frameText: String {
        VPhoneUIInspectorRecord.frame(frame)
    }

    var frameOrder: Double {
        frame.minY * 100_000 + frame.minX
    }

    var tapPoint: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}
