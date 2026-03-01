import AppKit
import Dynamic
import Foundation
import Virtualization

class VPhoneVMView: VZVirtualMachineView {
    var keyHelper: VPhoneKeyHelper?
    
    private var currentTouchSwipeAim: Int = 0

    // MARK: - Private API Accessors

    // https://github.com/wh1te4ever/super-tart-vphone-writeup/blob/main/contents/ScreenSharingVNC.swift
    private var multiTouchDevice: AnyObject? {
        guard let vm = self.virtualMachine else { return nil }
        guard let devices = Dynamic(vm)._multiTouchDevices.asObject as? NSArray,
            devices.count > 0
        else {
            return nil
        }
        return devices.object(at: 0) as AnyObject
    }

    // MARK: - Event Handling

    override func mouseDown(with event: NSEvent) {
        // macOS 16+: VZVirtualMachineView handles mouse-to-touch natively
        if #available(macOS 16.0, *) { super.mouseDown(with: event); return }

        let location = self.convert(event.locationInWindow, from: nil)
        
        self.currentTouchSwipeAim = hitTestEdge(at: location)
        
        sendTouchEvent(
            phase: 0, // Began
            locationInWindow: event.locationInWindow,
            timestamp: event.timestamp
        )
    }

    override func mouseDragged(with event: NSEvent) {
        if #available(macOS 16.0, *) { super.mouseDragged(with: event); return }

        sendTouchEvent(
            phase: 1, // Moved
            locationInWindow: event.locationInWindow,
            timestamp: event.timestamp
        )
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if #available(macOS 16.0, *) { super.mouseUp(with: event); return }

        sendTouchEvent(
            phase: 3, // Ended
            locationInWindow: event.locationInWindow,
            timestamp: event.timestamp
        )
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with _: NSEvent) {
        guard let keyHelper else {
            print("[keys] keyHelper was not set, no way home!")
            return
        }
        keyHelper.sendHome()
    }

    // MARK: - Legacy Touch Injection (macOS 15)

    private func sendTouchEvent(phase: Int, locationInWindow: NSPoint, timestamp: TimeInterval) {
        guard let device = multiTouchDevice,
            let vm = self.virtualMachine
        else { return }

        let normalizedPoint = normalizeCoordinate(locationInWindow)

        let touch = Dynamic._VZTouch(
            view: vm,
            index: 0,
            phase: phase,
            location: normalizedPoint,
            swipeAim: currentTouchSwipeAim,
            timestamp: timestamp
        )

        guard let touchObj = touch.asObject else {
            print("[vphone] Error: Failed to create _VZTouch")
            return
        }

        let touchEvent = Dynamic._VZMultiTouchEvent(touches: [touchObj])
        guard let eventObj = touchEvent.asObject else { return }

        Dynamic(device).sendMultiTouchEvents([eventObj] as NSArray)
    }

    // MARK: - Coordinate Helpers

    private func normalizeCoordinate(_ locationInWindow: NSPoint) -> CGPoint {
        let localPoint = self.convert(locationInWindow, from: nil)
        let w = self.bounds.width
        let h = self.bounds.height

        guard w > 0, h > 0 else { return .zero }

        var nx = Double(localPoint.x / w)
        var ny = Double(localPoint.y / h)

        // Clamp
        nx = max(0.0, min(1.0, nx))
        ny = max(0.0, min(1.0, ny))

        if !self.isFlipped {
            ny = 1.0 - ny
        }

        return CGPoint(x: nx, y: ny)
    }

    private func hitTestEdge(at point: CGPoint) -> Int {
        let w = self.bounds.width
        let h = self.bounds.height
        
        let edgeThreshold: CGFloat = 32.0
        
        let distLeft = point.x
        let distRight = w - point.x
        let distTop = self.isFlipped ? point.y : (h - point.y)
        let distBottom = self.isFlipped ? (h - point.y) : point.y

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