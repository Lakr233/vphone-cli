import AppKit

// MARK: - Application

/// Offers each key press in the VM window to the main menu before the VM view
/// can take it, and takes Esc for the guest's back gesture.
///
/// `capturesSystemKeys` makes `VZVirtualMachineView` install a local event
/// monitor that sends every key to the guest and swallows it. AppKit runs
/// local monitors in the order they were added, and the view adds its own
/// again each time it becomes first responder or its window becomes key, so
/// a monitor of ours always runs after it. `sendEvent(_:)` runs before any
/// local monitor, so both the menu lookup and the Esc handling live here.
final class VPhoneApplication: NSApplication {
    /// Keys whose key-down a menu item took. Their key-up is dropped too, so
    /// the guest never sees a release without a press.
    private var menuKeyCodes = Set<UInt16>()

    /// `kVK_Escape`. Intercepted here instead of as a menu key equivalent:
    /// AppKit's matching for a modifier-less Esc is not dependable, and a missed
    /// match forwards the key to the guest as a plain Escape — which is what
    /// made the back gesture take a second press.
    private static let escapeKeyCode: UInt16 = 53

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp,
              event.window?.firstResponder is VPhoneVirtualMachineView
        else {
            super.sendEvent(event)
            return
        }
        // Esc replays the guest's back gesture: iOS has no back key, and a
        // forwarded Escape only reads as cancel. The press and its release both
        // stop here, so the guest sees neither.
        if event.keyCode == Self.escapeKeyCode {
            if event.type == .keyDown,
               let view = event.window?.firstResponder as? VPhoneVirtualMachineView
            {
                view.performBackGesture()
            }
            return
        }
        if event.type == .keyUp {
            if menuKeyCodes.remove(event.keyCode) == nil {
                super.sendEvent(event)
            }
            return
        }
        if mainMenu?.performKeyEquivalent(with: event) == true {
            menuKeyCodes.insert(event.keyCode)
            return
        }
        super.sendEvent(event)
    }
}
