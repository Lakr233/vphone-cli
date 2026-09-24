import AppKit
import Foundation

@MainActor
@Observable
final class VPhoneUIInspectorModel {
    // MARK: - Types

    enum Source: String, CaseIterable, Identifiable {
        case accessibility
        case text

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .accessibility: String(localized: "Accessibility", bundle: VPhoneLocalization.bundle)
            case .text: String(localized: "Text (OCR)", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    enum Activity {
        case capturing
        case inspecting
        case recognizing
        case tapping

        var title: String {
            switch self {
            case .capturing: String(localized: "Capturing the guest screen…", bundle: VPhoneLocalization.bundle)
            case .inspecting: String(localized: "Reading accessibility elements…", bundle: VPhoneLocalization.bundle)
            case .recognizing: String(localized: "Recognizing text on the guest screen…", bundle: VPhoneLocalization.bundle)
            case .tapping: String(localized: "Tapping the guest…", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    /// One outline drawn over the screenshot, in guest points.
    struct Overlay: Identifiable {
        let id: Int
        let frame: CGRect
    }

    /// The upper bound sent as `max_elements`; icli accepts 1…2000.
    static let maxElements = 1000
    /// Vision languages sent to `ui.ocr`.
    static let ocrLanguages = ["en-US", "zh-Hans"]
    static let ocrMinimumConfidence = 0.3

    // MARK: - State

    let control: VPhoneGuestControl
    var source: Source = .accessibility
    var visibleOnly = true
    var clickableOnly = false

    private(set) var activity: Activity?
    private(set) var status: VPhoneGuestToolStatus?

    private(set) var screenshot: NSImage?
    /// The screenshot's size in pixels.
    private(set) var screenshotPixels: CGSize?
    /// `device.screen` width and height, in points.
    private(set) var screenPoints: CGSize?
    private(set) var screenScale: Double?

    private(set) var appName = ""
    private(set) var appBundleID = ""
    private(set) var appPID: Int?

    private(set) var elements: [VPhoneUIInspectorElement] = []
    private(set) var elementsTruncated = false
    private(set) var hasLoadedElements = false
    var selectedElementID: VPhoneUIInspectorElement.ID?
    /// Guest AX order until a column header is clicked.
    var elementSortOrder = [KeyPathComparator(\VPhoneUIInspectorElement.id)]

    private(set) var textBlocks: [VPhoneUIInspectorTextBlock] = []
    private(set) var hasLoadedText = false
    var selectedTextID: VPhoneUIInspectorTextBlock.ID?
    var textSortOrder = [KeyPathComparator(\VPhoneUIInspectorTextBlock.frameOrder)]

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Derived

    var isBusy: Bool {
        activity != nil
    }

    var sortedElements: [VPhoneUIInspectorElement] {
        elements.sorted(using: elementSortOrder)
    }

    var sortedTextBlocks: [VPhoneUIInspectorTextBlock] {
        textBlocks.sorted(using: textSortOrder)
    }

    /// The coordinate space of frames and taps: guest points in the
    /// orientation of the screenshot. icli matches its OCR point space to the
    /// image the same way (`pointSizeMatching`).
    var pointSize: CGSize? {
        switch (screenPoints, screenshotPixels) {
        case let (points?, pixels?):
            let imageIsLandscape = pixels.width > pixels.height
            let screenIsLandscape = points.width > points.height
            return imageIsLandscape == screenIsLandscape
                ? points
                : CGSize(width: points.height, height: points.width)
        case let (points?, nil):
            return points
        case let (nil, pixels?):
            let scale = max(screenScale ?? 1, 1)
            return CGSize(width: pixels.width / scale, height: pixels.height / scale)
        case (nil, nil):
            return nil
        }
    }

    var overlays: [Overlay] {
        switch source {
        case .accessibility: elements.map { Overlay(id: $0.id, frame: $0.frame) }
        case .text: textBlocks.map { Overlay(id: $0.id, frame: $0.frame) }
        }
    }

    var selectedID: Int? {
        get {
            switch source {
            case .accessibility: selectedElementID
            case .text: selectedTextID
            }
        }
        set {
            switch source {
            case .accessibility: selectedElementID = newValue
            case .text: selectedTextID = newValue
            }
        }
    }

    var selectedElement: VPhoneUIInspectorElement? {
        selectedElementID.flatMap { id in elements.first { $0.id == id } }
    }

    var selectedTextBlock: VPhoneUIInspectorTextBlock? {
        selectedTextID.flatMap { id in textBlocks.first { $0.id == id } }
    }

    var selectedFrame: CGRect? {
        switch source {
        case .accessibility: selectedElement?.frame
        case .text: selectedTextBlock?.frame
        }
    }

    var selectedDetails: [VPhoneUIInspectorDetail] {
        switch source {
        case .accessibility: selectedElement?.details ?? []
        case .text: selectedTextBlock?.details ?? []
        }
    }

    var selectedJSON: String? {
        switch source {
        case .accessibility: selectedElement?.json
        case .text: selectedTextBlock?.json
        }
    }

    var selectedTapPoint: CGPoint? {
        switch source {
        case .accessibility: selectedElement?.tapPoint
        case .text: selectedTextBlock?.tapPoint
        }
    }

    var hasLoadedSource: Bool {
        switch source {
        case .accessibility: hasLoadedElements
        case .text: hasLoadedText
        }
    }

    var canTapSelected: Bool {
        selectedTapPoint != nil && control.isConnected && !isBusy
    }

    // MARK: - Hit Testing

    /// The smallest loaded frame of the current source containing `point`
    /// (guest points). Equal areas prefer the later element, which AX lists
    /// after its container.
    func hitTest(_ point: CGPoint) -> Int? {
        overlays
            .filter { $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.contains(point) }
            .min { lhs, rhs in
                let lhsArea = lhs.frame.width * lhs.frame.height
                let rhsArea = rhs.frame.width * rhs.frame.height
                return lhsArea == rhsArea ? lhs.id > rhs.id : lhsArea < rhsArea
            }?
            .id
    }

    func select(at point: CGPoint) {
        selectedID = hitTest(point)
    }

    // MARK: - Loading

    /// Captures the screen, then reloads the current source.
    func refresh() async {
        guard activity == nil else { return }
        guard control.isConnected else {
            status = nil
            return
        }
        activity = .capturing
        defer { activity = nil }
        var failure: String?

        do {
            try await apply(screenshotJPEG: control.screenshotJPEG())
        } catch {
            failure = message(String(localized: "Unable to capture the guest screen. Check the connection, then try again.", bundle: VPhoneLocalization.bundle), error)
        }
        if let screen = try? await control.call("device.screen") {
            apply(screenResult: screen)
        }
        if let foreground = try? await control.call("apps.foreground") {
            apply(foregroundResult: foreground)
        }

        if let sourceFailure = await loadSource() {
            failure = failure ?? sourceFailure
        }
        if let failure {
            fail(failure)
        }
    }

    /// Reloads the current source without a new screenshot.
    func reloadSource() async {
        guard activity == nil, control.isConnected else { return }
        if let failure = await loadSource() {
            fail(failure)
        }
        activity = nil
    }

    /// Loads the current source; returns an error message on failure.
    private func loadSource() async -> String? {
        switch source {
        case .accessibility:
            activity = .inspecting
            do {
                try await apply(treeResult: control.call("ui.tree", params: [
                    "max_elements": Self.maxElements,
                    "visible_only": visibleOnly,
                    "clickable_only": clickableOnly,
                ]))
                succeed(elementSummary)
            } catch {
                return message(String(localized: "Unable to read the accessibility elements. Bring an app to the front in the guest, then try again.", bundle: VPhoneLocalization.bundle), error)
            }
        case .text:
            activity = .recognizing
            do {
                try await apply(ocrResult: control.call("ui.ocr", params: [
                    "languages": Self.ocrLanguages,
                    "min_confidence": Self.ocrMinimumConfidence,
                ]))
                succeed(textSummary)
            } catch {
                return message(String(localized: "Unable to recognize text on the guest screen. Check the connection, then try again.", bundle: VPhoneLocalization.bundle), error)
            }
        }
        return nil
    }

    private var elementSummary: String {
        if elementsTruncated {
            return String(localized: "Showing the first \(elements.count) accessibility elements. The guest stopped reading at its limit.", bundle: VPhoneLocalization.bundle)
        }
        return elements.count == 1
            ? String(localized: "Found 1 accessibility element.", bundle: VPhoneLocalization.bundle)
            : String(localized: "Found \(elements.count) accessibility elements.", bundle: VPhoneLocalization.bundle)
    }

    private var textSummary: String {
        textBlocks.count == 1
            ? String(localized: "Recognized 1 text block.", bundle: VPhoneLocalization.bundle)
            : String(localized: "Recognized \(textBlocks.count) text blocks.", bundle: VPhoneLocalization.bundle)
    }

    // MARK: - Parsing

    func apply(screenshotJPEG data: Data) throws {
        guard let image = NSImage(data: data),
              let rep = image.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0
        else {
            throw VPhoneGuestControl.ControlError.protocolError("invalid guest screenshot")
        }
        screenshot = image
        screenshotPixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// `device.screen`: {width, height, scale, orientation, locked, screen_off}.
    func apply(screenResult result: [String: Any]) {
        if let width = result.double("width"), let height = result.double("height"), width > 0, height > 0 {
            screenPoints = CGSize(width: width, height: height)
        }
        screenScale = result.double("scale")
    }

    /// `apps.foreground`: {bundle_id, name, pid, verified, source}.
    func apply(foregroundResult result: [String: Any]) {
        appBundleID = result.string("bundle_id") ?? ""
        appName = result.string("name") ?? ""
        appPID = result.int("pid").flatMap { $0 > 0 ? $0 : nil }
    }

    /// `ui.tree`: {source, pid, elements, count, truncated}.
    func apply(treeResult result: [String: Any]) {
        let previous = selectedElement
        elements = result.objects("elements").enumerated().compactMap { index, object in
            VPhoneUIInspectorElement(index: index, object: object)
        }
        elementsTruncated = result.bool("truncated") ?? false
        hasLoadedElements = true
        selectedElementID = previous.flatMap { old in
            elements.first { $0.frame == old.frame && $0.summary == old.summary }?.id
        }
    }

    /// `ui.ocr`: {blocks, count, engine}.
    func apply(ocrResult result: [String: Any]) {
        let previous = selectedTextBlock
        textBlocks = result.objects("blocks").enumerated().compactMap { index, object in
            VPhoneUIInspectorTextBlock(index: index, object: object)
        }
        hasLoadedText = true
        selectedTextID = previous.flatMap { old in
            textBlocks.first { $0.text == old.text && $0.frame.intersects(old.frame) }?.id
        }
    }

    // MARK: - Actions

    func tapSelected() async {
        guard let point = selectedTapPoint else { return }
        await tap(at: point)
    }

    /// Taps `point` (guest points) on the guest, then refreshes once the
    /// guest has had a moment to react.
    func tap(at point: CGPoint) async {
        guard activity == nil, control.isConnected else { return }
        let bounds = pointSize ?? CGSize(width: point.x + 1, height: point.y + 1)
        let x = min(max(point.x, 0), max(bounds.width - 0.5, 0))
        let y = min(max(point.y, 0), max(bounds.height - 0.5, 0))
        activity = .tapping
        do {
            _ = try await control.call("input.tap", params: ["x": x, "y": y])
        } catch {
            activity = nil
            fail(message(String(localized: "Unable to tap the guest. Check the connection, then try again.", bundle: VPhoneLocalization.bundle), error))
            return
        }
        activity = nil
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
    }

    func copySelected() {
        guard let json = selectedJSON else { return }
        copy(json)
        succeed(String(localized: "Copied the selected element as JSON.", bundle: VPhoneLocalization.bundle))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Status

    private func message(_ base: String, _ error: any Error) -> String {
        guard case let VPhoneGuestControl.ControlError.guestError(detail) = error, !detail.isEmpty else {
            return base
        }
        return String(localized: "\(base) Guest error: \(detail)", bundle: VPhoneLocalization.bundle)
    }

    private func succeed(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: false)
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
    }
}
