import AppKit
import Dynamic
import Foundation
import Virtualization

// MARK: - Touch-enabled VZVirtualMachineView

struct NormalizedResult {
    var point: CGPoint
    var isInvalid: Bool
}

class VPhoneVMView: VZVirtualMachineView {
    var currentTouchSwipeAim: Int64 = 0
    private var cachedTouchDevice: AnyObject?

    /// Resolve multi-touch device once, cache for subsequent events.
    private func touchDevice() -> AnyObject? {
        if let cached = cachedTouchDevice { return cached }
        guard let vm = virtualMachine,
              let devices = multiTouchDevices(vm),
              devices.count > 0 else { return nil }
        cachedTouchDevice = devices[0]
        return cachedTouchDevice
    }

    /// 1. Mouse dragged -> touch phase 1 (moving)
    override func mouseDragged(with event: NSEvent) {
        guard let device = touchDevice() else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let swipeAim = currentTouchSwipeAim

        guard let touch = makeTouch(0, 1, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch]) else { return }

        sendMultiTouchEvents(device, [touchEvent])
    }

    /// 2. Mouse down -> touch phase 0 (began)
    override func mouseDown(with event: NSEvent) {
        guard let device = touchDevice() else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let localPoint = convert(event.locationInWindow, from: nil)
        let edgeResult = hitTestEdge(at: localPoint)
        currentTouchSwipeAim = Int64(edgeResult)

        guard let touch = makeTouch(0, 0, normalized.point, edgeResult, event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch]) else { return }

        sendMultiTouchEvents(device, [touchEvent])
    }

    /// 3. Right mouse down -> two-finger touch began
    override func rightMouseDown(with event: NSEvent) {
        guard let device = touchDevice() else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        guard !normalized.isInvalid else { return }

        let localPoint = convert(event.locationInWindow, from: nil)
        let edgeResult = hitTestEdge(at: localPoint)
        currentTouchSwipeAim = Int64(edgeResult)

        guard let touch = makeTouch(0, 0, normalized.point, edgeResult, event.timestamp),
              let touch2 = makeTouch(1, 0, normalized.point, edgeResult, event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch, touch2]) else { return }

        sendMultiTouchEvents(device, [touchEvent])
    }

    /// 4. Mouse up -> touch phase 3 (ended)
    override func mouseUp(with event: NSEvent) {
        guard let device = touchDevice() else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let swipeAim = currentTouchSwipeAim

        guard let touch = makeTouch(0, 3, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch]) else { return }

        sendMultiTouchEvents(device, [touchEvent])
    }

    /// 5. Right mouse up -> two-finger touch ended
    override func rightMouseUp(with event: NSEvent) {
        guard let device = touchDevice() else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        guard !normalized.isInvalid else { return }

        let swipeAim = currentTouchSwipeAim

        guard let touch = makeTouch(0, 3, normalized.point, Int(swipeAim), event.timestamp),
              let touch2 = makeTouch(1, 3, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch, touch2]) else { return }

        sendMultiTouchEvents(device, [touchEvent])
    }
}

// MARK: - VPhoneVMView+Geometry

extension VPhoneVMView {
    func normalizeCoordinate(_ point: CGPoint) -> NormalizedResult {
        let bounds = bounds

        if bounds.size.width <= 0 || bounds.size.height <= 0 {
            return NormalizedResult(point: .zero, isInvalid: true)
        }

        let localPoint = convert(point, from: nil)

        var nx = Double(localPoint.x / bounds.size.width)
        var ny = Double(localPoint.y / bounds.size.height)

        nx = max(0.0, min(1.0, nx))
        ny = max(0.0, min(1.0, ny))

        if !isFlipped {
            ny = 1.0 - ny
        }

        return NormalizedResult(point: CGPoint(x: nx, y: ny), isInvalid: false)
    }

    /// Returns edge code for swipe aim: 1=top, 2=bottom, 4=right, 8=left, 0=none.
    func hitTestEdge(at point: CGPoint) -> Int {
        let bounds = bounds
        let width = bounds.size.width
        let height = bounds.size.height

        let distLeft = point.x
        let distRight = width - point.x

        var minDist: Double
        var edgeCode: Int

        if distRight < distLeft {
            minDist = distRight
            edgeCode = 4 // Right
        } else {
            minDist = distLeft
            edgeCode = 8 // Left
        }

        let topCode = isFlipped ? 2 : 1
        let bottomCode = isFlipped ? 1 : 2

        let distTop = point.y
        if distTop < minDist {
            minDist = distTop
            edgeCode = topCode
        }

        let distBottom = height - point.y
        if distBottom < minDist {
            minDist = distBottom
            edgeCode = bottomCode
        }

        return minDist < 32.0 ? edgeCode : 0
    }
}

// MARK: - Private multi-touch helpers via Dynamic

private func multiTouchDevices(_ vm: VZVirtualMachine) -> [AnyObject]? {
    Dynamic(vm)._multiTouchDevices.asArray as? [AnyObject]
}

/// Creates a _VZTouch via alloc+init + KVC (avoids crash in the designated initializer).
private func makeTouch(_ index: Int, _ phase: Int, _ location: CGPoint,
                       _ swipeAim: Int, _ timestamp: TimeInterval) -> AnyObject?
{
    guard let cls = NSClassFromString("_VZTouch") as? NSObject.Type else { return nil }
    let touch = cls.init()
    touch.setValue(NSNumber(value: UInt8(clamping: index)), forKey: "_index")
    touch.setValue(NSNumber(value: phase), forKey: "_phase")
    touch.setValue(NSNumber(value: swipeAim), forKey: "_swipeAim")
    touch.setValue(NSNumber(value: timestamp), forKey: "_timestamp")
    touch.setValue(NSValue(point: location), forKey: "_location")
    return touch
}

private func makeMultiTouchEvent(_ touches: [AnyObject]) -> AnyObject? {
    Dynamic._VZMultiTouchEvent(touches: touches).asObject
}

private func sendMultiTouchEvents(_ device: AnyObject, _ events: [AnyObject]) {
    Dynamic(device).sendMultiTouchEvents(events)
}
