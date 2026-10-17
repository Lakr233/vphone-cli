import AppKit
import ObjectiveC.runtime
import Virtualization

// MARK: - Graphics Display Capture

/// The current frame of a VM display, from Virtualization's private
/// `_takeScreenshotWithCompletionHandler:`. The VM service answers it from the
/// frame it last presented, so the guest does no work for it, and it works the
/// same with and without a VM window. The buffer is in the panel's
/// orientation, whatever the guest interface shows.
enum VPhoneGraphicsDisplayCapture {
    private typealias CompletionBlock = @convention(block) (AnyObject?) -> Void
    private typealias ScreenshotIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

    @MainActor
    static func capture(_ display: VZGraphicsDisplay, completion: @escaping (CGImage?) -> Void) {
        let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
        guard display.responds(to: selector),
              let cls = object_getClass(display),
              let method = class_getInstanceMethod(cls, selector)
        else {
            completion(nil)
            return
        }
        let function = unsafeBitCast(method_getImplementation(method), to: ScreenshotIMP.self)
        let block: CompletionBlock = { object in
            completion(image(from: object))
        }
        function(display, selector, unsafeBitCast(block, to: AnyObject.self))
    }

    @MainActor
    static func capture(_ display: VZGraphicsDisplay) async -> CGImage? {
        await withCheckedContinuation { continuation in
            capture(display) { image in
                continuation.resume(returning: image)
            }
        }
    }

    private static func image(from object: AnyObject?) -> CGImage? {
        guard let object else { return nil }
        if let image = object as? NSImage {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let value = object as CFTypeRef
        guard CFGetTypeID(value) == CGImage.typeID else { return nil }
        // CGImage is a CF type, not a Swift class - unsafeDowncast cannot be used here.
        return (value as! CGImage) // swiftlint:disable:this force_cast
    }
}
