import AppKit
import Dynamic
import Foundation
import Virtualization

class VPhoneVirtualMachineView: VZVirtualMachineView {
    var keyHelper: VPhoneKeyHelper?
    weak var control: VPhoneControl?

    /// Whether trackpad scroll/pinch gestures are replayed as guest touches.
    var trackpadGesturesEnabled = VPhoneTrackpadGestures.isEnabled {
        didSet {
            guard !trackpadGesturesEnabled else { return }
            finishScrollTouch()
            endPinch()
        }
    }

    private var currentTouchSwipeAim: Int = 0
    private var isDragHighlightVisible = false

    /// Synthetic guest finger driven by an in-flight trackpad scroll gesture.
    private var scrollTouchPoint: NSPoint?
    /// Travel accumulated before the finger is pressed down, so the large delta
    /// that trips the start threshold is not thrown away.
    private var scrollPending = CGPoint.zero
    /// Travel wasted while the guest was clamping the finger to a screen edge.
    private var scrollOverflow = CGPoint.zero
    /// Landing spot waiting for the re-anchor gap to elapse.
    private var scrollRebasePoint: NSPoint?
    /// Uptime at which the finger was lifted to start a re-anchor.
    private var scrollRebaseTime: TimeInterval = 0
    /// Uptime of the last touch update forwarded to the guest.
    private var scrollLastSend: TimeInterval = 0

    /// Center and half-gap of the two synthetic fingers used for pinch gestures.
    private var pinchTouchCenter: NSPoint?
    private var pinchTouchRadius: CGFloat = 0

    /// Guest points travelled per point of trackpad delta. Above 1 because a
    /// single trackpad swipe produces far less travel than a finger covers on a
    /// phone screen: at 1:1 an ordinary swipe could not carry a gesture that has
    /// to travel a third of the screen (unlock, back) to completion.
    private static let scrollToTouchScale: CGFloat = 1.5
    /// Bottom fraction of the window treated as the Home indicator strip. See
    /// `scrollStartPoint(for:travel:)`.
    private static let homeEdgeSnapFraction: CGFloat = 0.10
    /// Travel required before a scroll gesture presses a finger down. Keeps
    /// taps and zero-travel scrolls from reaching the guest as a click.
    private static let scrollStartThreshold: CGFloat = 2
    /// Minimum interval between forwarded touch updates, ~70Hz: every frame of
    /// a 60Hz trackpad gets through and a 120Hz stream is halved. Forwarding
    /// every frame outruns the guest's HID queue, which shows up as stutter and
    /// as the finger still drifting after the gesture ended. The finger's
    /// position still advances on every frame; only the events in between are
    /// dropped, and the release carries the final position.
    private static let scrollMinSendInterval: TimeInterval = 1.0 / 70.0
    /// Travel the guest is known to have thrown away that triggers a re-anchor.
    private static let scrollRebaseThreshold: CGFloat = 12
    /// Gap between lifting and re-pressing the finger during a re-anchor.
    /// Back-to-back events sharing a timestamp get folded into one move by the
    /// guest, which drags the swipe backwards across the whole window instead of
    /// starting a fresh touch.
    private static let scrollRebaseGap: TimeInterval = 0.02
    /// Where a re-anchored finger lands, as a fraction of the window measured
    /// from the edge it ran into towards the opposite side. Fixed rather than
    /// derived from the pointer, so the travel a swipe gets is never a function
    /// of where the pointer happens to sit.
    private static let scrollRebaseLandingInset: CGFloat = 0.12
    private static let minPinchRadius: CGFloat = 8

    // MARK: - Private API Accessors

    /// https://github.com/wh1te4ever/super-tart-vphone-writeup/blob/main/contents/ScreenSharingVNC.swift
    private var multiTouchDevice: AnyObject? {
        guard let vm = virtualMachine else { return nil }
        guard let devices = Dynamic(vm)._multiTouchDevices.asObject as? NSArray,
              devices.count > 0
        else {
            return nil
        }
        return devices.object(at: 0) as AnyObject
    }

    var recordingGraphicsDisplay: VZGraphicsDisplay? {
        if let display = Dynamic(self)._graphicsDisplay.asObject as? VZGraphicsDisplay {
            return display
        }
        return virtualMachine?.graphicsDevices.first?.displays.first
    }

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure keyboard events route to VM view right after window attach.
        window?.makeFirstResponder(self)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the VM display should always restore keyboard focus.
        window?.makeFirstResponder(self)
        // A synthetic trackpad finger would fight this touch for the same slot.
        finishScrollTouch()
        let localPoint = convert(event.locationInWindow, from: nil)
        currentTouchSwipeAim = hitTestEdge(at: localPoint)
        if sendTouchEvent(phase: 0, localPoint: localPoint, timestamp: event.timestamp) { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if sendTouchEvent(phase: 1, localPoint: localPoint, timestamp: event.timestamp) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if !sendTouchEvent(phase: 3, localPoint: localPoint, timestamp: event.timestamp) {
            super.mouseUp(with: event)
        }
        currentTouchSwipeAim = 0
    }

    override func rightMouseDown(with _: NSEvent) {
        guard let keyHelper else { return }
        keyHelper.sendHome()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "h"
        {
            keyHelper?.sendHome()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Trackpad Gestures

    /// Replay a trackpad scroll as a guest finger that presses under the pointer
    /// and follows the physical direction of the gesture.
    override func scrollWheel(with event: NSEvent) {
        guard trackpadGesturesEnabled, event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        // A pinch in flight owns both fingers; interleaving it with a synthetic
        // drag leaves the guest with conflicting touches and no gesture at all.
        guard pinchTouchCenter == nil else { return }

        // Inertia is synthesised by AppKit once the fingers have left the
        // trackpad. The guest decelerates on its own when the finger lifts, so
        // replaying the momentum stream just drags on after the user stopped.
        guard event.momentumPhase.isEmpty else {
            finishScrollTouch()
            return
        }

        // Complete a re-anchor whose gap has elapsed before this event is
        // applied, so the finger is down again when its travel lands. Travel
        // banked during the gap is replayed against the fresh touch.
        if let point = scrollRebasePoint, hasScrollRebaseGapElapsed() {
            scrollRebasePoint = nil
            beginScrollTouch(at: point)
            flushScrollPending()
        }

        let delta = scrollDelta(of: event)
        let pointer = convert(event.locationInWindow, from: nil)

        switch event.phase {
        case .began, .mayBegin:
            // A new gesture supersedes whatever was still in flight.
            finishScrollTouch()
            followScrollDelta(delta, pointer: pointer)
        case .ended, .cancelled:
            followScrollDelta(delta, pointer: pointer)
            finishScrollTouch()
        default:
            // Devices without gesture phases (e.g. Magic Mouse) report plain
            // deltas and never end the gesture, so press, drag and release each
            // event instead of leaving a finger down between them.
            followScrollDelta(delta, pointer: pointer)
            if event.phase.isEmpty {
                finishScrollTouch()
            }
        }
    }

    /// Replay a trackpad pinch as two guest fingers spreading or closing around
    /// the pointer position.
    override func magnify(with event: NSEvent) {
        guard trackpadGesturesEnabled else {
            super.magnify(with: event)
            return
        }
        // A synthetic drag owns the touch surface; ignoring the pinch keeps the
        // guest from seeing one- and two-finger touches interleaved.
        guard scrollTouchPoint == nil else { return }

        if event.phase == .began || pinchTouchCenter == nil {
            beginPinch(at: convert(event.locationInWindow, from: nil))
        }
        if pinchTouchCenter != nil {
            applyPinch(magnification: event.magnification)
        }
        if event.phase == .ended || event.phase == .cancelled {
            endPinch()
        }
    }

    /// Apply one trackpad delta to the synthetic finger, pressing it down first
    /// once the gesture has clearly become a drag.
    private func followScrollDelta(_ delta: CGPoint, pointer: NSPoint) {
        guard delta != .zero else { return }
        // A re-anchor is mid-flight: the finger is deliberately up for the gap.
        // Bank the travel instead of dropping it, otherwise a fast swipe would
        // silently lose distance to every re-press.
        guard scrollRebasePoint == nil else {
            scrollPending.x += delta.x
            scrollPending.y += delta.y
            return
        }

        guard scrollTouchPoint != nil else {
            scrollPending.x += delta.x
            scrollPending.y += delta.y
            guard hypot(scrollPending.x, scrollPending.y) >= Self.scrollStartThreshold else {
                return
            }
            let carry = scrollPending
            scrollPending = .zero
            beginScrollTouch(at: scrollStartPoint(for: pointer, travel: carry))
            if scrollTouchPoint != nil {
                moveScrollTouch(by: carry)
            }
            return
        }

        moveScrollTouch(by: delta)
    }

    /// Trackpad deltas expressed in the physical direction of the gesture so the
    /// synthetic finger follows the user's fingers.
    ///
    /// AppKit flips the deltas when natural scrolling is on. The two axes do not
    /// share a baseline: on hardware the vertical axis came out matching the
    /// fingers while the horizontal axis was mirrored, hence the extra sign on
    /// x. This is the one place the convention lives.
    private func scrollDelta(of event: NSEvent) -> CGPoint {
        var dx = -event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice {
            dx = -dx
            dy = -dy
        }
        return CGPoint(x: dx * Self.scrollToTouchScale, y: dy * Self.scrollToTouchScale)
    }

    /// Where to press the synthetic finger: the pointer, except for an upward
    /// swipe that starts inside the Home indicator strip, which is pressed at
    /// the very bottom edge instead.
    ///
    /// The guest only treats an upward gesture as unlock / home when the touch
    /// *begins* inside that strip; the same swipe starting a few points higher
    /// is an ordinary drag, which is why unlocking worked with the pointer
    /// parked on the bar and stopped as soon as it moved up a little. Snapping
    /// only in that strip keeps the rest of the window usable for scrolling.
    private func scrollStartPoint(for pointer: NSPoint, travel: CGPoint) -> NSPoint {
        guard travel.y > abs(travel.x),
              pointer.y <= bounds.height * Self.homeEdgeSnapFraction
        else { return pointer }
        return NSPoint(x: pointer.x, y: 0)
    }

    /// Press the synthetic finger down at `point`, so the drag starts where the
    /// user is pointing.
    private func beginScrollTouch(at point: NSPoint) {
        let start = clampedTouchPoint(point)
        scrollTouchPoint = start
        scrollLastSend = 0
        if !sendTouchEvent(
            phase: 0, localPoint: start, timestamp: ProcessInfo.processInfo.systemUptime
        ) {
            scrollTouchPoint = nil
        }
    }

    private func moveScrollTouch(by delta: CGPoint) {
        guard let current = scrollTouchPoint else { return }
        // The finger is allowed to leave the window rather than being pinned to
        // the edge. `boundedScrollTouch` is only a guard against a stuck gesture
        // running away.
        let target = boundedScrollTouch(
            NSPoint(x: current.x + delta.x, y: current.y + delta.y)
        )
        guard target != current else { return }

        scrollTouchPoint = target

        // Past the edge the guest clamps the touch to the screen and stops
        // following it, so this travel no longer scrolls anything no matter how
        // much of it accumulates here. Bank it and re-anchor: otherwise a swipe
        // dies part-way through — how far it gets decided by where the pointer
        // happened to be — and the pinned finger is read as a long press.
        if isPastScrollEdge(target) {
            scrollOverflow.x += delta.x
            scrollOverflow.y += delta.y
            if hypot(scrollOverflow.x, scrollOverflow.y) >= Self.scrollRebaseThreshold {
                rebaseScrollTouch()
            }
            return
        }

        scrollOverflow = .zero
        // Advance the finger on every frame but forward events at most at
        // `scrollMinSendInterval`; the release below carries the final position.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - scrollLastSend >= Self.scrollMinSendInterval else { return }
        scrollLastSend = now
        sendTouchEvent(phase: 1, localPoint: target, allowOutside: true, timestamp: now)
    }

    /// Lift the finger where it ran out of window and press it back down near
    /// the opposite side, so the rest of the same swipe keeps scrolling. The
    /// landing spot is a fraction of the window rather than anything derived
    /// from the pointer, which is what stops a swipe from being limited by where
    /// the pointer sits: every re-anchor hands back nearly a full window of
    /// travel in the direction of the swipe.
    private func rebaseScrollTouch() {
        guard let current = scrollTouchPoint else { return }
        let overflow = scrollOverflow
        scrollOverflow = .zero
        guard overflow != .zero else { return }

        let inset = Self.scrollRebaseLandingInset
        let landing = clampedTouchPoint(
            NSPoint(
                x: overflow.x > 0
                    ? bounds.width * inset
                    : overflow.x < 0 ? bounds.width * (1 - inset) : current.x,
                y: overflow.y > 0
                    ? bounds.height * inset
                    : overflow.y < 0 ? bounds.height * (1 - inset) : current.y
            )
        )
        guard landing != clampedTouchPoint(current) else { return }

        // The gap matters: back-to-back events sharing a timestamp are folded
        // into a single move by the guest, which drags the swipe backwards
        // across the window instead of starting a fresh touch. The re-press is
        // completed on the next scroll event once the gap has elapsed.
        scrollTouchPoint = nil
        scrollRebasePoint = landing
        scrollRebaseTime = ProcessInfo.processInfo.systemUptime
        sendTouchEvent(
            phase: 3, localPoint: clampedTouchPoint(current),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    private func hasScrollRebaseGapElapsed() -> Bool {
        ProcessInfo.processInfo.systemUptime - scrollRebaseTime >= Self.scrollRebaseGap
    }

    /// Replay travel that arrived while the finger was up for a re-anchor.
    private func flushScrollPending() {
        guard scrollTouchPoint != nil, scrollPending != .zero else { return }
        let carry = scrollPending
        scrollPending = .zero
        moveScrollTouch(by: carry)
    }

    /// Whether the finger has left the window, where the guest stops following
    /// its position.
    private func isPastScrollEdge(_ point: NSPoint) -> Bool {
        point.x <= 0 || point.y <= 0 || point.x >= bounds.width || point.y >= bounds.height
    }

    private func finishScrollTouch() {
        scrollPending = .zero
        scrollOverflow = .zero
        scrollRebasePoint = nil
        guard let point = scrollTouchPoint else { return }
        scrollTouchPoint = nil
        // Release where the finger actually is, even if that is off-screen, so
        // the guest does not see it snap back to the edge on the way up.
        sendTouchEvent(
            phase: 3, localPoint: point, allowOutside: true,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    private func beginPinch(at center: NSPoint) {
        endPinch()
        pinchTouchCenter = clampedTouchPoint(center)
        pinchTouchRadius = Self.initialPinchRadius(in: bounds)
        sendPinchTouch(phase: 0)
    }

    private func applyPinch(magnification: CGFloat) {
        let radius = pinchTouchRadius * (1 + magnification)
        pinchTouchRadius = min(max(radius, Self.minPinchRadius), Self.maxPinchRadius(in: bounds))
        sendPinchTouch(phase: 1)
    }

    private func endPinch() {
        guard pinchTouchCenter != nil else { return }
        sendPinchTouch(phase: 3)
        pinchTouchCenter = nil
        pinchTouchRadius = 0
    }

    private func sendPinchTouch(phase: Int) {
        guard let center = pinchTouchCenter else { return }
        let points = [
            clampedTouchPoint(NSPoint(x: center.x - pinchTouchRadius, y: center.y)),
            clampedTouchPoint(NSPoint(x: center.x + pinchTouchRadius, y: center.y)),
        ]
        sendTouchEvent(
            phase: phase, localPoints: points, swipeAim: 0,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func initialPinchRadius(in bounds: CGRect) -> CGFloat {
        max(minPinchRadius, min(bounds.width, bounds.height) * 0.15)
    }

    private static func maxPinchRadius(in bounds: CGRect) -> CGFloat {
        max(initialPinchRadius(in: bounds), min(bounds.width, bounds.height) * 0.45)
    }

    // MARK: - Drag and Drop Install

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard droppedInstallPackageURL(from: sender) != nil else { return [] }
        updateDragHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        _ = sender
        updateDragHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        droppedInstallPackageURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        updateDragHighlight(false)
        guard let url = droppedInstallPackageURL(from: sender) else { return false }

        Task { @MainActor in
            guard let control else {
                showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
                return
            }
            guard control.isConnected else {
                showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
                return
            }

            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                showAlert(
                    title: "Install App Package",
                    message: VPhoneInstallPackage.successMessage(
                        for: url.lastPathComponent,
                        detail: result
                    ),
                    style: .informational
                )
            } catch {
                showAlert(title: "Install App Package", message: "\(error)", style: .warning)
            }
        }
        return true
    }

    private func droppedInstallPackageURL(from sender: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first(where: VPhoneInstallPackage.isSupportedFile)
    }

    private func updateDragHighlight(_ visible: Bool) {
        guard isDragHighlightVisible != visible else { return }
        isDragHighlightVisible = visible
        wantsLayer = true
        layer?.borderWidth = visible ? 4 : 0
        layer?.borderColor = visible ? NSColor.systemGreen.cgColor : NSColor.clear.cgColor
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Programmatic Touch (for automation)

    /// Convert screenshot pixel coordinates to NSView local coordinates.
    private func pixelToLocal(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) -> NSPoint {
        let w = bounds.width
        let h = bounds.height
        let localX = pixelX / Double(screenWidth) * w
        // Screenshot y=0 is top, NSView y=0 is bottom (non-flipped)
        let localY = (1.0 - pixelY / Double(screenHeight)) * h
        return NSPoint(x: localX, y: localY)
    }

    /// Synthesize an NSEvent at a given window point.
    private func synthesizeMouseEvent(type: NSEvent.EventType, at windowPoint: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseUp ? 0 : 1,
            pressure: type == .leftMouseUp ? 0.0 : 1.0
        )
    }

    /// Inject a tap at pixel coordinates (matching screenshot image dimensions).
    func injectTap(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) {
        let localPoint = pixelToLocal(pixelX: pixelX, pixelY: pixelY, screenWidth: screenWidth, screenHeight: screenHeight)
        let windowPoint = convert(localPoint, to: nil)

        if let downEvent = synthesizeMouseEvent(type: .leftMouseDown, at: windowPoint) {
            mouseDown(with: downEvent)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            if let upEvent = self.synthesizeMouseEvent(type: .leftMouseUp, at: windowPoint) {
                self.mouseUp(with: upEvent)
            }
        }
    }

    /// Inject a swipe from one pixel coordinate to another.
    func injectSwipe(
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        screenWidth: Int, screenHeight: Int, durationMs: Int = 300
    ) {
        let startLocal = pixelToLocal(pixelX: fromX, pixelY: fromY, screenWidth: screenWidth, screenHeight: screenHeight)
        let endLocal = pixelToLocal(pixelX: toX, pixelY: toY, screenWidth: screenWidth, screenHeight: screenHeight)
        let startWindow = convert(startLocal, to: nil)
        let endWindow = convert(endLocal, to: nil)

        let steps = max(10, durationMs / 16)
        let stepInterval = Double(durationMs) / Double(steps) / 1000.0

        if let downEvent = synthesizeMouseEvent(type: .leftMouseDown, at: startWindow) {
            mouseDown(with: downEvent)
        }

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = startWindow.x + (endWindow.x - startWindow.x) * t
            let y = startWindow.y + (endWindow.y - startWindow.y) * t
            let pt = NSPoint(x: x, y: y)
            let delay = stepInterval * Double(i)

            if i < steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if let dragEvent = self.synthesizeMouseEvent(type: .leftMouseDragged, at: pt) {
                        self.mouseDragged(with: dragEvent)
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if let upEvent = self.synthesizeMouseEvent(type: .leftMouseUp, at: pt) {
                        self.mouseUp(with: upEvent)
                    }
                }
            }
        }
    }

    // MARK: - Legacy Touch Injection (macOS 15)

    @discardableResult
    private func sendTouchEvent(
        phase: Int, localPoint: NSPoint, allowOutside: Bool = false, timestamp: TimeInterval
    ) -> Bool {
        sendTouchEvent(
            phase: phase, localPoints: [localPoint], swipeAim: currentTouchSwipeAim,
            allowOutside: allowOutside, timestamp: timestamp
        )
    }

    /// Inject one or more fingers at `localPoints` (view coordinates) in a single
    /// touch event. Guest-side injection carries at most two fingers; the native
    /// VZ multitouch path numbers them by array index.
    ///
    /// `allowOutside` forwards coordinates that fall beyond the view instead of
    /// clamping them, which the scroll gesture uses to keep a swipe alive after
    /// it has passed the window edge.
    @discardableResult
    private func sendTouchEvent(
        phase: Int, localPoints: [NSPoint], swipeAim: Int, allowOutside: Bool = false,
        timestamp: TimeInterval
    ) -> Bool {
        guard !localPoints.isEmpty else { return false }
        let normalized = localPoints.map { normalizeCoordinate($0, allowOutside: allowOutside) }

        // iOS 18 bases: the VZ USB touchscreen dext emits no digitizer events on
        // the 26.x kernel, so route touches through vphoned's guest-side HID
        // injection. 26.x bases fall through to the native VZ multitouch path.
        if let control, control.useGuestTouchInjection {
            if normalized.count >= 2, control.supportsMultiTouch {
                control.sendTouch2(
                    phase: phase,
                    x1: Double(normalized[0].x), y1: Double(normalized[0].y),
                    x2: Double(normalized[1].x), y2: Double(normalized[1].y)
                )
            } else {
                control.sendTouch(
                    phase: phase, x: Double(normalized[0].x), y: Double(normalized[0].y)
                )
            }
            return true
        }

        guard let device = multiTouchDevice,
              virtualMachine != nil
        else { return false }

        let touches = normalized.enumerated().compactMap { index, point in
            Dynamic._VZTouch(
                view: self,
                index: index,
                phase: phase,
                location: point,
                swipeAim: swipeAim,
                timestamp: timestamp
            ).asObject
        }

        guard touches.count == normalized.count else {
            print("[vphone] Error: Failed to create _VZTouch")
            return false
        }

        let touchEvent = Dynamic._VZMultiTouchEvent(touches: touches)
        guard let eventObj = touchEvent.asObject else { return false }

        Dynamic(device).sendMultiTouchEvents([eventObj] as NSArray)
        return true
    }

    // MARK: - Coordinate Helpers

    private func clampedTouchPoint(_ point: NSPoint) -> NSPoint {
        let inset: CGFloat = 1
        let maxX = max(inset, bounds.width - inset)
        let maxY = max(inset, bounds.height - inset)
        return NSPoint(
            x: min(max(point.x, inset), maxX),
            y: min(max(point.y, inset), maxY)
        )
    }

    /// Soft bound for a finger that is allowed past the window edge: wide enough
    /// that no single swipe reaches it, tight enough that a wedged gesture can
    /// not drift to absurd coordinates.
    private func boundedScrollTouch(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, -bounds.width), bounds.width * 2),
            y: min(max(point.y, -bounds.height), bounds.height * 2)
        )
    }

    /// Map a view-local point into the guest's normalized touch space.
    ///
    /// `allowOutside` keeps coordinates that fall beyond the view instead of
    /// clamping them to the edge. The scroll gesture needs it: once the finger
    /// has reached the edge the guest would stop receiving new positions, so a
    /// long swipe could not keep scrolling.
    private func normalizeCoordinate(_ localPoint: NSPoint, allowOutside: Bool = false) -> CGPoint {
        let w = bounds.width
        let h = bounds.height

        guard w > 0, h > 0 else { return .zero }

        var nx = Double(localPoint.x / w)
        var ny = Double(localPoint.y / h)

        if !allowOutside {
            nx = max(0.0, min(1.0, nx))
            ny = max(0.0, min(1.0, ny))
        }

        if !isFlipped {
            ny = 1.0 - ny
        }

        return CGPoint(x: nx, y: ny)
    }

    private func hitTestEdge(at point: CGPoint) -> Int {
        let w = bounds.width
        let h = bounds.height

        let edgeThreshold: CGFloat = 32.0

        let distLeft = point.x
        let distRight = w - point.x
        let distTop = isFlipped ? point.y : (h - point.y)
        let distBottom = isFlipped ? (h - point.y) : point.y

        var minDist = distLeft
        var edgeCode = 8 // Left

        if distRight < minDist {
            minDist = distRight
            edgeCode = 4 // Right
        }

        if distBottom < minDist {
            minDist = distBottom
            edgeCode = 2 // Bottom (Home bar swipe up)
        }

        if distTop < minDist {
            minDist = distTop
            edgeCode = 1 // Top (Notification Center)
        }

        return minDist < edgeThreshold ? edgeCode : 0
    }
}

// MARK: - Trackpad Gesture Preference

/// User preference for replaying trackpad scroll/pinch gestures as guest
/// touches. Enabled by default; the Keys menu exposes the toggle.
enum VPhoneTrackpadGestures {
    private static let disabledKey = "trackpadGesturesDisabled"

    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: disabledKey) }
        set { UserDefaults.standard.set(!newValue, forKey: disabledKey) }
    }
}
