import AppKit
import Dynamic
import Foundation
import Virtualization
import VPhoneCoreKit

class VPhoneVirtualMachineView: VZVirtualMachineView {
    var keySender: VPhoneVirtualMachineKeySender?
    weak var control: VPhoneGuestControl?
    /// Whether Esc replays the back gesture (an iPhone, which has no Esc key)
    /// or reaches the guest as Esc (an iPad). See `VPhoneApplication`.
    var escapeIsBackGesture = true
    var isTVGuest = false
    var hardwareKeyboardEnabled = true
    /// Guest pixels per interface point, to turn trackpad travel into the
    /// guest's points for a native scroll.
    var screenScale: CGFloat = 3

    private(set) var isMouseCaptured = false
    var onMouseCaptureChange: ((Bool) -> Void)?
    private var capturedMousePoint = NSPoint.zero
    private var mouseReleaseMonitor: Any?

    /// Explicit per-window capture, never persisted or activated by a click.
    func setMouseCaptured(_ captured: Bool) {
        guard captured != isMouseCaptured else { return }
        if captured {
            guard window?.isKeyWindow == true, control?.supportsPointerScroll == true else { return }
            finishScrollTouch()
            releaseSecondaryPress()
            endNativeScroll()
            endPinch()
            guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { return }
            capturedMousePoint = NSPoint(x: bounds.midX, y: bounds.midY)
            if let screenPoint = window?.convertPoint(toScreen: convert(capturedMousePoint, to: nil)),
               let top = NSScreen.screens.first?.frame.maxY {
                CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: top - screenPoint.y))
            }
            isMouseCaptured = true
            Self.hiddenCursor.set()
            control?.movePointer(to: interfacePoint(capturedMousePoint))
            mouseReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 46,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option],
                   self?.isMouseCaptured == true {
                    self?.setMouseCaptured(false)
                    return nil
                }
                return event
            }
        } else {
            if pointerButtons != 0 {
                pointerButtons = 0
                control?.setPointer(interfacePoint(capturedMousePoint), buttons: 0)
            }
            endNativeScroll()
            isMouseCaptured = false
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.arrow.set()
            if let monitor = mouseReleaseMonitor { NSEvent.removeMonitor(monitor) }
            mouseReleaseMonitor = nil
        }
        onMouseCaptureChange?(isMouseCaptured)
    }

    private func advanceCapturedMouse(_ event: NSEvent) {
        capturedMousePoint.x = min(bounds.maxX, max(bounds.minX, capturedMousePoint.x + event.deltaX))
        capturedMousePoint.y = min(bounds.maxY, max(bounds.minY,
            capturedMousePoint.y + (isFlipped ? event.deltaY : -event.deltaY)))
    }

    private func pointerPoint(_ localPoint: NSPoint) -> CGPoint {
        interfacePoint(isMouseCaptured ? capturedMousePoint : localPoint)
    }

    /// Whether trackpad scroll/pinch gestures are replayed as guest touches.
    var trackpadGesturesEnabled = VPhoneTrackpadGestures.isEnabled {
        didSet {
            guard !trackpadGesturesEnabled else { return }
            finishScrollTouch()
            endNativeScroll()
            endPinch()
        }
    }

    private var currentTouchSwipeAim: Int = 0
    /// The touch in flight started at a screen edge and goes through vphoned,
    /// which can mark it as an edge touch. Decided when the finger goes down and
    /// kept until it lifts, so one touch never switches injection path.
    private var edgeTouchViaGuest = false
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

    /// A native scroll (`input.scroll`) is under way: `began` has gone out and
    /// `ended` not yet.
    private var nativeScrollActive = false
    /// `ended` waiting to see whether AppKit's momentum follows the lift.
    private var nativeScrollEndWork: DispatchWorkItem?
    /// A click ended the scroll; the rest of its momentum is dropped until the
    /// fingers start a new one.
    private var nativeScrollMomentumDropped = false
    /// The timestamp of the scroll's first momentum event, which the fade
    /// counts from.
    private var nativeScrollMomentumStart: TimeInterval?
    private var pointerTrackingArea: NSTrackingArea?

    /// How long after the fingers lift a scroll waits for AppKit's momentum
    /// before it ends. Momentum starts on the next frame when it starts at all.
    private static let nativeScrollMomentumWait: TimeInterval = 0.05
    /// Half-life of the fade laid over AppKit's own deceleration. The guest
    /// takes momentum as more travel of a scroll that is still open, so at
    /// the content's edge the rubber band went on stretching for the second
    /// or more AppKit's momentum lasts, and sprang back only after it.
    private static let nativeScrollMomentumHalfLife: TimeInterval = 0.03
    /// Faded momentum travel, in guest points per event, below which the
    /// scroll ends and the rest of the momentum is dropped.
    private static let nativeScrollMomentumStop: CGFloat = 3
    /// How long a scroll from a wheel without gesture phases stays open after
    /// its last event, as the web console does.
    private static let nativeScrollIdleEnd: TimeInterval = 0.12
    /// Points per line of a wheel that scrolls in lines (no precise deltas).
    private static let nativeScrollLine: CGFloat = 16

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

    /// Where the finger a right click put down is, while it is down.
    private var secondaryPressPoint: NSPoint?
    /// Uptime at which that finger was pressed.
    private var secondaryPressStart: TimeInterval = 0
    /// Release waiting for the hold to register after the button came up.
    private var secondaryReleaseWork: DispatchWorkItem?
    /// How long a right click holds the finger down. Long enough for the
    /// guest's touch-and-hold (about half a second) to fire, short of the
    /// longer hold that starts Home Screen editing.
    private static let secondaryClickHoldDuration: TimeInterval = 0.6

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = pointerTrackingArea {
            removeTrackingArea(area)
        }
        // Always, not only in the key window: a VM window opened behind
        // another app, or not yet clicked, should still show hover.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self,
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    /// On a guest that scrolls natively the guest has a pointer of its own;
    /// it follows the mouse, so the guest sees hover as an iPad with a
    /// trackpad does.
    override func mouseMoved(with event: NSEvent) {
        guard guestPointerFollowsMouse, let control else {
            super.mouseMoved(with: event)
            return
        }
        advanceCapturedMouse(event)
        if hidesHostCursor {
            Self.hiddenCursor.set()
        }
        control.movePointer(to: interfacePoint(capturedMousePoint))
    }

    /// The guest's pointer stands in for the Mac's over the display, so the
    /// Mac's is hidden there, as Universal Control hides it on the iPad.
    override func cursorUpdate(with event: NSEvent) {
        if hidesHostCursor {
            Self.hiddenCursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private var guestPointerFollowsMouse: Bool {
        isMouseCaptured && control?.supportsPointerScroll == true
    }

    /// Only in the key window: over a window in the background the Mac's
    /// cursor is the one the user is steering with.
    private var hidesHostCursor: Bool {
        guestPointerFollowsMouse && window?.isKeyWindow == true
    }

    /// A cursor with nothing to draw. `NSCursor.hide()` is counted and
    /// app-wide, so it would have to be balanced on every way out of the view.
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func mouseDown(with event: NSEvent) {
        // Clicking the VM display should always restore keyboard focus.
        window?.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        if pressPointer(Self.primaryPointerButton, at: localPoint) {
            return
        }
        // A click is a touch, and iPadOS hides its pointer under a finger: the
        // Mac's shows where the drag is until the mouse moves freely again.
        if guestPointerFollowsMouse {
            NSCursor.arrow.set()
        }
        if beginTouch(at: localPoint, timestamp: event.timestamp) {
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isMouseCaptured { advanceCapturedMouse(event) }
        let localPoint = convert(event.locationInWindow, from: nil)
        if dragPointer(to: localPoint) || sendTouchEvent(phase: 1, localPoint: localPoint, timestamp: event.timestamp) {
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if releasePointer(Self.primaryPointerButton, at: localPoint) {
            if hidesHostCursor {
                Self.hiddenCursor.set()
            }
            return
        }
        if !endTouch(at: localPoint, timestamp: event.timestamp) {
            super.mouseUp(with: event)
        }
        // Bring the guest's pointer back where the finger lifted.
        if guestPointerFollowsMouse, let control {
            if hidesHostCursor {
                Self.hiddenCursor.set()
            }
            control.movePointer(to: pointerPoint(localPoint))
        }
    }

    // MARK: - Secondary Click

    /// A right click is iPadOS's secondary click: the context menu under the
    /// pointer. Where the guest's pointer follows the mouse it is that
    /// pointer's secondary button. Elsewhere the guest has a touchscreen and
    /// no pointer, so it is replayed as a touch-and-hold, which is what opens
    /// the same menu by finger. A click released before the hold registers is
    /// kept down until it has. Holding and dragging carries on as a drag, as a
    /// finger would.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        if pressPointer(Self.secondaryPointerButton, at: localPoint) {
            return
        }
        finishScrollTouch()
        releaseSecondaryPress()
        // A hold is never an edge swipe, wherever it lands.
        currentTouchSwipeAim = 0
        guard sendTouchEvent(phase: 0, localPoint: localPoint, timestamp: event.timestamp) else {
            super.rightMouseDown(with: event)
            return
        }
        secondaryPressPoint = localPoint
        secondaryPressStart = ProcessInfo.processInfo.systemUptime
    }

    override func rightMouseDragged(with event: NSEvent) {
        if isMouseCaptured { advanceCapturedMouse(event) }
        if dragPointer(to: convert(event.locationInWindow, from: nil)) {
            return
        }
        guard secondaryPressPoint != nil, secondaryReleaseWork == nil else {
            super.rightMouseDragged(with: event)
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        secondaryPressPoint = localPoint
        sendTouchEvent(phase: 1, localPoint: localPoint, timestamp: event.timestamp)
    }

    override func rightMouseUp(with event: NSEvent) {
        if releasePointer(Self.secondaryPointerButton, at: convert(event.locationInWindow, from: nil)) {
            return
        }
        guard secondaryPressPoint != nil, secondaryReleaseWork == nil else {
            super.rightMouseUp(with: event)
            return
        }
        secondaryPressPoint = convert(event.locationInWindow, from: nil)
        let held = ProcessInfo.processInfo.systemUptime - secondaryPressStart
        let remaining = Self.secondaryClickHoldDuration - held
        guard remaining > 0 else {
            releaseSecondaryPress()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.releaseSecondaryPress()
        }
        secondaryReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    /// Lift the finger a right click put down. A new touch calls this first,
    /// so it never shares the slot with a hold still waiting to finish.
    private func releaseSecondaryPress() {
        secondaryReleaseWork?.cancel()
        secondaryReleaseWork = nil
        guard let point = secondaryPressPoint else { return }
        secondaryPressPoint = nil
        sendTouchEvent(phase: 3, localPoint: point, timestamp: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Pointer Clicks

    private static let primaryPointerButton = 1
    private static let secondaryPointerButton = 2

    /// The buttons Mac clicks hold down on the guest's pointer.
    private var pointerButtons = 0

    /// On a guest whose pointer follows the mouse a click is that pointer's,
    /// as on an iPad with a trackpad. A touch is the wrong input there: iPadOS
    /// ignores a touch on an alert's button while the pointer hovers it, until
    /// the pointer hides itself a few seconds after it last moved.
    private var clicksWithGuestPointer: Bool {
        guestPointerFollowsMouse && control?.supportsPointerButtons == true
    }

    /// Presses `button` on the guest's pointer at `localPoint`, ending any
    /// scroll or touch first. False when a click is a touch on this guest.
    private func pressPointer(_ button: Int, at localPoint: NSPoint) -> Bool {
        guard clicksWithGuestPointer, let control else { return false }
        finishScrollTouch()
        if nativeScrollActive {
            endNativeScroll()
            nativeScrollMomentumDropped = true
        }
        releaseSecondaryPress()
        pointerButtons |= button
        control.setPointer(pointerPoint(localPoint), buttons: pointerButtons)
        return true
    }

    /// Moves the guest's pointer with its buttons held. False when none is.
    private func dragPointer(to localPoint: NSPoint) -> Bool {
        guard pointerButtons != 0, let control else { return false }
        control.setPointer(pointerPoint(localPoint), buttons: pointerButtons)
        return true
    }

    /// Releases `button`. False when the guest's pointer is not holding it, so
    /// a release whose press was a touch lifts the finger instead.
    private func releasePointer(_ button: Int, at localPoint: NSPoint) -> Bool {
        guard pointerButtons & button != 0, let control else { return false }
        pointerButtons &= ~button
        control.setPointer(pointerPoint(localPoint), buttons: pointerButtons)
        return true
    }

    // MARK: - Touches

    /// Puts a finger down at `localPoint`, after ending every other input that
    /// would fight it for the same slot. False when there is no touch path.
    @discardableResult
    private func beginTouch(at localPoint: NSPoint, timestamp: TimeInterval) -> Bool {
        finishScrollTouch()
        if nativeScrollActive {
            endNativeScroll()
            nativeScrollMomentumDropped = true
        }
        releaseSecondaryPress()
        currentTouchSwipeAim = hitTestEdge(at: localPoint)
        return sendTouchEvent(phase: 0, localPoint: localPoint, timestamp: timestamp)
    }

    @discardableResult
    private func endTouch(at localPoint: NSPoint, timestamp: TimeInterval) -> Bool {
        defer { currentTouchSwipeAim = 0 }
        return sendTouchEvent(phase: 3, localPoint: localPoint, timestamp: timestamp)
    }

    // MARK: - Trackpad Gestures

    /// Replay a trackpad scroll as a guest finger that presses under the pointer
    /// and follows the physical direction of the gesture.
    override func scrollWheel(with event: NSEvent) {
        if guestPointerFollowsMouse, let control {
            scrollNatively(event, control: control)
            return
        }
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

    /// Scroll the guest the way an iPad with a trackpad scrolls: the view under
    /// its pointer moves by the gesture's travel, and AppKit's momentum is sent
    /// as more travel, since the guest does not decelerate after `ended`. The
    /// momentum is faded, so a swipe runs on for a shorter way than in a Mac
    /// app and the scroll ends soon after the fingers lift.
    private func scrollNatively(_ event: NSEvent, control: VPhoneGuestControl) {
        nativeScrollEndWork?.cancel()
        nativeScrollEndWork = nil
        let momentum = !event.momentumPhase.isEmpty
        if momentum, nativeScrollMomentumDropped {
            return
        }
        if event.phase == .began {
            // A new gesture: whatever was still running on is over.
            nativeScrollMomentumDropped = false
            endNativeScroll()
        }
        var delta = nativeScrollDelta(of: event)
        if momentum {
            let start = nativeScrollMomentumStart ?? event.timestamp
            nativeScrollMomentumStart = start
            let fade = pow(0.5, (event.timestamp - start) / Self.nativeScrollMomentumHalfLife)
            delta = CGVector(dx: delta.dx * fade, dy: delta.dy * fade)
            if delta != .zero, hypot(delta.dx, delta.dy) < Self.nativeScrollMomentumStop {
                endNativeScroll()
                nativeScrollMomentumDropped = true
                return
            }
        }
        if !nativeScrollActive, delta != .zero {
            nativeScrollActive = true
            control.sendScroll(phase: "began", pointer: pointerPoint(convert(event.locationInWindow, from: nil)))
        }
        if nativeScrollActive, delta != .zero {
            control.sendScroll(phase: "changed", delta: delta)
        }
        if momentum {
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                endNativeScroll()
            }
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scheduleNativeScrollEnd(after: Self.nativeScrollMomentumWait)
        } else if event.phase.isEmpty {
            // A wheel without gesture phases never says when it stops.
            scheduleNativeScrollEnd(after: Self.nativeScrollIdleEnd)
        }
    }

    private func scheduleNativeScrollEnd(after delay: TimeInterval) {
        guard nativeScrollActive else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.endNativeScroll()
        }
        nativeScrollEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func endNativeScroll() {
        nativeScrollEndWork?.cancel()
        nativeScrollEndWork = nil
        nativeScrollMomentumStart = nil
        guard nativeScrollActive else { return }
        nativeScrollActive = false
        control?.sendScroll(phase: "ended")
    }

    /// The event's travel in guest interface points, with a browser wheel
    /// event's signs (positive y toward the end of the content), which is the
    /// opposite of AppKit's. Natural scrolling is already in both. The travel
    /// is the window's, and the window shows the interface upright, so it
    /// needs no turning; one window point is as many guest points as the drawn
    /// display is smaller than the guest's.
    private func nativeScrollDelta(of event: NSEvent) -> CGVector {
        let unit = event.hasPreciseScrollingDeltas ? 1 : Self.nativeScrollLine
        let geometry = displayGeometry
        let pixels = recordingGraphicsDisplay?.sizeInPixels ?? .zero
        var scale: CGFloat = 1
        if pixels.width > 0, geometry.displayRect.width > 0, screenScale > 0 {
            scale = pixels.width / screenScale / geometry.displayRect.width
        }
        return CGVector(dx: -event.scrollingDeltaX * unit * scale, dy: -event.scrollingDeltaY * unit * scale)
    }

    /// A view point as `input.pointer` takes it: 0...1 of the interface as the
    /// window shows it, from the top-left corner.
    private func interfacePoint(_ localPoint: NSPoint) -> CGPoint {
var panel = normalizeCoordinate(localPoint)
        if let active = activePanelPixels, let backing = recordingGraphicsDisplay?.sizeInPixels,
           active.width > 0, active.height > 0 {
            panel.x *= backing.width / active.width
            panel.y *= backing.height / active.height
        }
        let unit = CGSize(width: 1, height: 1)
        let screen = screenOrientation.screenPoint(fromPanel: CGPoint(x: panel.x, y: 1 - panel.y), panel: unit)
        return CGPoint(x: min(max(screen.x, 0), 1), y: min(max(1 - screen.y, 0), 1))
    }

    /// Replay a trackpad pinch as two guest fingers spreading or closing around
    /// the pointer position.
    override func magnify(with event: NSEvent) {
        guard trackpadGesturesEnabled else {
            super.magnify(with: event)
            return
        }
        // A native scroll and a pinch never overlap, like a synthetic drag and one.
        endNativeScroll()
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
            let start = scrollStartPoint(for: pointer, travel: carry)
            beginScrollTouch(at: start.point, swipeAim: start.swipeAim)
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
    ///
    /// The deltas are the window's; the finger moves on the panel, which the
    /// window shows turned when the guest is sideways. Unturned, a vertical
    /// swipe on a landscape guest dragged the finger across it, into the
    /// panel's edge, where the re-anchor pressed it down again as a tap.
    private func scrollDelta(of event: NSEvent) -> CGPoint {
        var dx = -event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice {
            dx = -dx
            dy = -dy
        }
        return screenOrientation.panelVector(
            fromScreen: CGPoint(x: dx * Self.scrollToTouchScale, y: dy * Self.scrollToTouchScale),
        )
    }

    /// How the window shows the panel: this view is turned with the guest's
    /// interface, and keeps its portrait bounds.
    private var screenOrientation: VPhoneDisplayOrientation {
        VPhoneDisplayOrientation(viewRotation: enclosingDisplayRotation ?? frameCenterRotation)
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
    ///
    /// Up and the bottom strip are the window's, which is the interface's: on
    /// a sideways guest the Home indicator runs along a long side of the panel.
    ///
    /// The snapped touch is also marked as starting at the bottom edge
    /// (`swipeAim`): the guest's edge-pan recognizers ignore a touch that
    /// begins at the edge but does not carry the edge flags.
    private func scrollStartPoint(for pointer: NSPoint, travel: CGPoint) -> (point: NSPoint, swipeAim: Int) {
        let orientation = screenOrientation
        let screenTravel = orientation.screenVector(fromPanel: travel)
        let screenPointer = orientation.screenPoint(fromPanel: pointer, panel: bounds.size)
        let screenHeight = orientation.displayedSize(panel: bounds.size).height
        guard screenTravel.y > abs(screenTravel.x),
              screenPointer.y <= screenHeight * Self.homeEdgeSnapFraction
        else { return (pointer, 0) }
        let point = orientation.panelPoint(fromScreen: CGPoint(x: screenPointer.x, y: 0), panel: bounds.size)
        // The interface's bottom is a panel edge; on a sideways guest it is a
        // long side of the panel, which is what the digitizer reports.
        return (point, hitTestEdge(at: clampedTouchPoint(point)))
    }

    /// Press the synthetic finger down at `point`, so the drag starts where the
    /// user is pointing.
    private func beginScrollTouch(at point: NSPoint, swipeAim: Int = 0) {
        releaseSecondaryPress()
        currentTouchSwipeAim = swipeAim
        let start = clampedTouchPoint(point)
        scrollTouchPoint = start
        scrollLastSend = 0
        if !sendTouchEvent(
            phase: 0, localPoint: start, timestamp: ProcessInfo.processInfo.systemUptime,
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
            NSPoint(x: current.x + delta.x, y: current.y + delta.y),
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
                    : overflow.y < 0 ? bounds.height * (1 - inset) : current.y,
            ),
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
            timestamp: ProcessInfo.processInfo.systemUptime,
        )
        // The re-press lands inside the window: an ordinary touch.
        currentTouchSwipeAim = 0
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
            timestamp: ProcessInfo.processInfo.systemUptime,
        )
        currentTouchSwipeAim = 0
    }

    private func beginPinch(at center: NSPoint) {
        endPinch()
        releaseSecondaryPress()
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

    /// The two fingers sit side by side as the window shows the panel.
    private func sendPinchTouch(phase: Int) {
        guard let center = pinchTouchCenter else { return }
        let offset = screenOrientation.panelVector(fromScreen: CGPoint(x: pinchTouchRadius, y: 0))
        let points = [
            clampedTouchPoint(NSPoint(x: center.x - offset.x, y: center.y - offset.y)),
            clampedTouchPoint(NSPoint(x: center.x + offset.x, y: center.y + offset.y)),
        ]
        sendTouchEvent(
            phase: phase, localPoints: points, swipeAim: 0,
            timestamp: ProcessInfo.processInfo.systemUptime,
        )
    }

    private static func initialPinchRadius(in bounds: CGRect) -> CGFloat {
        max(minPinchRadius, min(bounds.width, bounds.height) * 0.15)
    }

    private static func maxPinchRadius(in bounds: CGRect) -> CGFloat {
        max(initialPinchRadius(in: bounds), min(bounds.width, bounds.height) * 0.45)
    }

    // MARK: - Clipboard

    /// The Edit menu's Copy, Cut and Paste reach the guest through here, so
    /// ⌘C, ⌘X and ⌘V sync the clipboard. Without a connected agent the items
    /// are disabled and the keys go to the guest unchanged.
    var clipboardSync: VPhoneClipboardSync?

    @objc func copy(_: Any?) {
        clipboardSync?.copy(cut: false)
    }

    @objc func cut(_: Any?) {
        clipboardSync?.copy(cut: true)
    }

    @objc func paste(_: Any?) {
        clipboardSync?.paste()
    }

    // MARK: - Drag and Drop

    /// Every dropped file goes through vphoned: an .ipa or .tipa is installed,
    /// anything else is saved to the Files app's On My iPhone › vphone-drop.
    /// Folders are not taken.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !droppedFileURLs(from: sender).isEmpty else { return [] }
        updateDragHighlight(true)
        return .copy
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        updateDragHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !droppedFileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        updateDragHighlight(false)
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let packagesOnly = urls.allSatisfy(VPhoneInstallPackage.isSupportedFile)
        let title = packagesOnly ? "Install App Package" : "Dropped Files"

        Task { @MainActor in
            guard let control, control.isConnected else {
                VPhoneAlert.present(
                    title: title,
                    message: "The guest agent is not connected. Wait for it to connect, then try again.",
                    style: .warning,
                )
                return
            }

            var lines: [String] = []
            var failed = false
            for url in urls {
                let name = url.lastPathComponent
                if VPhoneInstallPackage.isSupportedFile(url) {
                    do {
                        let result = try await control.installIPA(localURL: url)
                        print("[install] \(result)")
                        lines.append(VPhoneLocalization.installedMessage(for: name, detail: result))
                    } catch {
                        failed = true
                        lines.append(VPhoneLocalization.format("Unable to install %@.", name))
                    }
                } else {
                    do {
                        let saved = try await control.saveDroppedFile(localURL: url)
                        print("[drop] saved \(name) as \(saved)")
                        lines.append(VPhoneLocalization.format(
                            "Saved “%@” to On My iPhone › %@ in Files.", saved, VPhoneGuestControl.dropFolder,
                        ))
                    } catch {
                        failed = true
                        lines.append(VPhoneLocalization.format(
                            "Unable to upload “%@”. Check the connection, then try again.", name,
                        ))
                    }
                }
            }
            VPhoneAlert.present(
                title: title,
                message: lines.joined(separator: "\n"),
                style: failed ? .warning : .informational,
            )
        }
        return true
    }

    private func droppedFileURLs(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    private func updateDragHighlight(_ visible: Bool) {
        guard isDragHighlightVisible != visible else { return }
        isDragHighlightVisible = visible
        wantsLayer = true
        layer?.borderWidth = visible ? 4 : 0
        layer?.borderColor = visible ? NSColor.systemGreen.cgColor : NSColor.clear.cgColor
    }

    // MARK: - Programmatic Touch (for automation)

    var enclosingDisplayRotation: CGFloat?
    var activePanelPixels: CGSize?
    var displayedOrientation: VPhoneDisplayOrientation { screenOrientation }

    /// Read-only diagnostic: use the same geometry as real mouse/touch input.
    func inputGeometryReport() -> [String: Any] {
        let pixels = recordingGraphicsDisplay?.sizeInPixels ?? .zero
        func rect(_ value: CGRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        return [
            "graphics_pixels": [Double(pixels.width), Double(pixels.height)],
            "view_bounds": rect(bounds), "display_rect": rect(displayGeometry.displayRect),
            "view_rotation": Double(enclosingDisplayRotation ?? frameCenterRotation), "screen_orientation": screenOrientation.rawValue,
            "is_flipped": isFlipped, "mouse_uses_pointer": clicksWithGuestPointer,
        ]
    }

    /// Convert screenshot pixel coordinates to NSView local coordinates.
    private func pixelToLocal(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) -> NSPoint {
        displayGeometry.viewPoint(normalized: CGPoint(
            x: pixelX / Double(screenWidth),
            y: pixelY / Double(screenHeight),
        ))
    }

    /// Inject a tap at pixel coordinates (matching screenshot image dimensions).
    /// Always a touch, even where a Mac click is the guest pointer's: a tap
    /// stands for a finger, and the pointer shows only once the mouse moves.
    func injectTap(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) {
        let localPoint = pixelToLocal(
            pixelX: pixelX,
            pixelY: pixelY,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
        )
        beginTouch(at: localPoint, timestamp: ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.endTouch(at: localPoint, timestamp: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Inject a swipe from one pixel coordinate to another, as a finger.
    func injectSwipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        screenWidth: Int,
        screenHeight: Int,
        durationMs: Int = 300,
    ) {
        let startLocal = pixelToLocal(
            pixelX: fromX,
            pixelY: fromY,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
        )
        let endLocal = pixelToLocal(pixelX: toX, pixelY: toY, screenWidth: screenWidth, screenHeight: screenHeight)

        let steps = max(10, durationMs / 16)
        let stepInterval = Double(durationMs) / Double(steps) / 1000.0

        beginTouch(at: startLocal, timestamp: ProcessInfo.processInfo.systemUptime)

        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            let pt = NSPoint(
                x: startLocal.x + (endLocal.x - startLocal.x) * t,
                y: startLocal.y + (endLocal.y - startLocal.y) * t,
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval * Double(i)) { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if i < steps {
                    sendTouchEvent(phase: 1, localPoint: pt, timestamp: now)
                } else {
                    endTouch(at: pt, timestamp: now)
                }
            }
        }
    }

    // MARK: - Back Gesture

    /// Replay the system back gesture: a drag from the interface's left edge
    /// toward the centre, which on a sideways guest is a long side of the
    /// panel.
    ///
    /// iOS has no back key. This is the gesture every app honours, so both the
    /// Esc key and the Device menu's Back item come through here.
    ///
    /// The touch starts a hair inside the left edge on purpose: the system only
    /// reads a drag as the back gesture when the touch *begins* in the
    /// screen-edge zone. It goes through `injectSwipe`, which is always a
    /// touch, even where a Mac click is the guest pointer's, and follows
    /// whichever injection path the running base uses (vphoned on iOS 18, the
    /// native VZ multitouch path on 26 and later).
    /// True while a back swipe is in flight. A second press during one cannot
    /// stack another gesture on top of it, which is what made a double press
    /// look like nothing happened.
    private var backGestureInFlight = false

    func performBackGesture() {
        if isTVGuest {
            keySender?.sendTVBack()
            return
        }
        guard !backGestureInFlight, let display = recordingGraphicsDisplay else { return }
        let size = display.sizeInPixels
        guard size.width > 0, size.height > 0 else { return }

        backGestureInFlight = true
        let durationMS = 250
        // The swipe queues its steps on the main queue too, so clearing the flag
        // from there after the last step keeps the two in order.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(durationMS) / 1000 + 0.05) {
            [weak self] in
            self?.backGestureInFlight = false
        }

        // Laid out on the interface, y up, then carried onto the panel's
        // pixels, y down.
        let orientation = screenOrientation
        let screen = orientation.displayedSize(panel: size)
        let from = orientation.panelPoint(fromScreen: CGPoint(x: screen.width * 0.004, y: screen.height * 0.5), panel: size)
        let to = orientation.panelPoint(fromScreen: CGPoint(x: screen.width * 0.85, y: screen.height * 0.5), panel: size)
        injectSwipe(
            fromX: from.x,
            fromY: size.height - from.y,
            toX: to.x,
            toY: size.height - to.y,
            screenWidth: Int(size.width),
            screenHeight: Int(size.height),
            durationMs: durationMS,
        )
    }

    // MARK: - Legacy Touch Injection (macOS 15)

    @discardableResult
    private func sendTouchEvent(
        phase: Int, localPoint: NSPoint, allowOutside: Bool = false, timestamp: TimeInterval,
    ) -> Bool {
        sendTouchEvent(
            phase: phase, localPoints: [localPoint], swipeAim: currentTouchSwipeAim,
            allowOutside: allowOutside, timestamp: timestamp,
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
        timestamp: TimeInterval,
    ) -> Bool {
        guard !localPoints.isEmpty else { return false }
        let normalized = localPoints.map { normalizeCoordinate($0, allowOutside: allowOutside) }

        // A single finger that starts at a screen edge goes through vphoned
        // when the guest can flag it as an edge touch. The native path cannot:
        // VZ forwards `swipeAim` to its USB touchscreen, whose HID report has
        // no field for it, so UIKit's edge-pan recognizers (SpringBoard's home
        // gesture) never begin. The choice is made on the down and kept until
        // the lift.
        if phase == 0 {
            edgeTouchViaGuest = localPoints.count == 1 && swipeAim != 0
                && control?.supportsEdgeTouch == true
        }
        defer {
            if phase == 3 { edgeTouchViaGuest = false }
        }

        // iOS 18 bases: the VZ USB touchscreen dext emits no digitizer events on
        // the 26.x kernel, so route touches through vphoned's guest-side HID
        // injection. 26.x bases fall through to the native VZ multitouch path.
        if let control, control.useGuestTouchInjection || edgeTouchViaGuest {
            if normalized.count >= 2, control.supportsMultiTouch {
                control.sendTouch2(
                    phase: phase,
                    x1: Double(normalized[0].x), y1: Double(normalized[0].y),
                    x2: Double(normalized[1].x), y2: Double(normalized[1].y),
                )
            } else {
                // Edge flags must not move an ordinary tap onto the edge.
                // Deliberate trackpad home gestures select their edge start
                // in snappedScrollStart; pointer/tap coordinates stay exact.
                let point = normalized[0]
                control.sendTouch(
                    phase: phase, x: Double(point.x), y: Double(point.y), edge: swipeAim,
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
                timestamp: timestamp,
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
            y: min(max(point.y, inset), maxY),
        )
    }

    /// Soft bound for a finger that is allowed past the window edge: wide enough
    /// that no single swipe reaches it, tight enough that a wedged gesture can
    /// not drift to absurd coordinates.
    private func boundedScrollTouch(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, -bounds.width), bounds.width * 2),
            y: min(max(point.y, -bounds.height), bounds.height * 2),
        )
    }

    /// The guest display as drawn in this view. Full screen letterboxes it,
    /// so touches are measured against it rather than `bounds`.
    private var displayGeometry: VPhoneDisplayGeometry {
        VPhoneDisplayGeometry(
            viewBounds: touchViewportBounds,
            displaySize: touchViewportSize,
            isFlipped: isFlipped,
        )
    }

    /// The visible activity surface inside the fixed backing framebuffer.
    /// Duo keeps one physical Main/backing surface and clips it to the current
    /// outer or inner viewport. Input must be measured against that clipped
    /// rectangle; using the full backing bounds makes outer-screen touches
    /// land in the hidden part of the framebuffer.
    private var touchViewportSize: CGSize { touchViewportBounds.size }

    private var touchViewportBounds: CGRect {
        guard let active = activePanelPixels,
              let backing = recordingGraphicsDisplay?.sizeInPixels else { return bounds }
        return VPhoneDisplayGeometry.activeViewportBounds(
            viewBounds: bounds, activePixels: active, backingPixels: backing
        )
    }

    /// Map a view-local point into the guest's normalized touch space,
    /// measured against the drawn display rather than the view (a full-screen
    /// VM letterboxes it).
    ///
    /// `allowOutside` keeps coordinates that fall beyond the display instead of
    /// clamping them to its edge. The scroll gesture needs it: once the finger
    /// reaches the edge the guest stops receiving new positions, so a long
    /// swipe could not keep scrolling.
    private func normalizeCoordinate(_ localPoint: NSPoint, allowOutside: Bool = false) -> CGPoint {
        displayGeometry.normalizedPoint(localPoint, clamped: !allowOutside)
    }

    private func hitTestEdge(at point: CGPoint) -> Int {
        displayGeometry.edge(at: point).rawValue
    }
}

// MARK: - Menu Validation

extension VPhoneVirtualMachineView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)):
            clipboardSync?.isAvailable == true
        default:
            true
        }
    }
}

// MARK: - Trackpad Gesture Preference

/// User preference for replaying trackpad scroll/pinch gestures as guest
/// touches. Enabled by default; the Device menu exposes the toggle.
enum VPhoneTrackpadGestures {
    private static let disabledKey = "trackpadGesturesDisabled"

    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: disabledKey) }
        set { UserDefaults.standard.set(!newValue, forKey: disabledKey) }
    }
}
