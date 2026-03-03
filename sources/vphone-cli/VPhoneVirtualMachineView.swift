import AppKit
import Dynamic
import Foundation
import Virtualization

class VPhoneVirtualMachineView: VZVirtualMachineView {
    var keyHelper: VPhoneKeyHelper?

    private var currentTouchSwipeAim: Int = 0

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

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure keyboard events route to VM view right after window attach.
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the VM display should always restore keyboard focus.
        window?.makeFirstResponder(self)
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

    // MARK: - Legacy Touch Injection (macOS 15)

    @discardableResult
    private func sendTouchEvent(phase: Int, localPoint: NSPoint, timestamp: TimeInterval) -> Bool {
        guard let device = multiTouchDevice,
              virtualMachine != nil
        else { return false }

        let normalizedPoint = normalizeCoordinate(localPoint)

        let touch = Dynamic._VZTouch(
            view: self,
            index: 0,
            phase: phase,
            location: normalizedPoint,
            swipeAim: currentTouchSwipeAim,
            timestamp: timestamp
        )

        guard let touchObj = touch.asObject else {
            print("[vphone] Error: Failed to create _VZTouch")
            return false
        }

        let touchEvent = Dynamic._VZMultiTouchEvent(touches: [touchObj])
        guard let eventObj = touchEvent.asObject else { return false }

        Dynamic(device).sendMultiTouchEvents([eventObj] as NSArray)
        return true
    }

    // MARK: - Coordinate Helpers

    private func normalizeCoordinate(_ localPoint: NSPoint) -> CGPoint {
        let w = bounds.width
        let h = bounds.height

        guard w > 0, h > 0 else { return .zero }

        var nx = Double(localPoint.x / w)
        var ny = Double(localPoint.y / h)

        // Clamp
        nx = max(0.0, min(1.0, nx))
        ny = max(0.0, min(1.0, ny))

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
