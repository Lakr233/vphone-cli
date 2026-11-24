import AppKit
import VPhoneCoreKit

// MARK: - Application

/// Offers each key press in the VM window to the main menu before the VM view
/// can take it, takes Esc for the guest's back gesture, and carries the keys the
/// virtual keyboard cannot.
///
/// `capturesSystemKeys` makes `VZVirtualMachineView` install a local event
/// monitor that sends every key to the guest and swallows it. AppKit runs
/// local monitors in the order they were added, and the view adds its own
/// again each time it becomes first responder or its window becomes key, so
/// a monitor of ours always runs after it. `sendEvent(_:)` runs before any
/// local monitor, so the menu lookup, the Esc handling and the dropped keys
/// all live here.
final class VPhoneApplication: NSApplication {
    /// Keys whose key-down a menu item took. Their key-up is dropped too, so
    /// the guest never sees a release without a press.
    private var menuKeyCodes = Set<UInt16>()

    /// Keys whose key-down went to the guest through vphoned, with the usage
    /// sent, so their key-up goes the same way even after 🌐 is let go.
    private var forwardedKeys: [UInt16: (control: VPhoneGuestControl, usage: VPhoneGuestKeyMap.Usage)] = [:]

    /// The guest 🌐 is held through, while it is held. fn's release only arrives
    /// while the window is key, so leaving the window lets go of it here.
    private weak var globeHolder: VPhoneGuestControl?
    private var resignObserver: NSObjectProtocol?

    /// `kVK_Escape`. Intercepted here instead of as a menu key equivalent:
    /// AppKit's matching for a modifier-less Esc is not dependable, and a missed
    /// match forwards the key to the guest as a plain Escape — which is what
    /// made the back gesture take a second press.
    private static let escapeKeyCode: UInt16 = 53
    /// `kVK_Home`: fn-← on a Mac laptop keyboard.
    private static let homeKeyCode: UInt16 = 0x73

    override func sendEvent(_ event: NSEvent) {
        // The remote's Return/Esc are consumer Select/Menu, including while
        // AppKit would otherwise match the Device menu's bare Escape item.
        if (event.type == .keyDown || event.type == .keyUp),
           event.keyCode != 49, // Space activates the focused native button.
           event.window?.attachedSheet == nil,
           let remote = event.window?.contentView as? VPhoneTVRemoteView,
           remote.handleKey(event, down: event.type == .keyDown) {
            return
        }
        // While a sheet is up, its keys are its own: Esc must reach its
        // Cancel button, not the guest's back gesture.
        guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged,
              event.window?.attachedSheet == nil,
              let view = event.window?.firstResponder as? VPhoneVirtualMachineView
        else {
            super.sendEvent(event)
            return
        }
        if !takeKeyEvent(event, view: view) {
            super.sendEvent(event)
        }
    }

    /// Whatever this class does with a key event for the VM view before the
    /// view's own handling. Returns true when the event stops here; false when
    /// it goes on to the virtual keyboard, which `VPhoneHostKeyEvents` then
    /// delivers to the view itself.
    func takeKeyEvent(_ event: NSEvent, view: VPhoneVirtualMachineView) -> Bool {
        if view.isGuestPaused, view.hardwareKeyboardEnabled, event.type == .flagsChanged
            || (event.type == .keyUp && !menuKeyCodes.contains(event.keyCode)) {
            // A key or modifier pressed before the pause is let go in the
            // virtual keyboard, which hands the release over at the resume;
            // dropped, it would stay held. Keys held through vphoned were let
            // go before the pause (`releaseHeldGuestKeys()`).
            return false
        }
        if !view.hardwareKeyboardEnabled || view.isGuestPaused {
            // Keep host menu shortcuts available, including the keyboard toggle.
            // Do not synthesize dropped keys through vphoned while disconnected.
            // A paused guest takes no new key: Virtualization would hold them
            // and hand them over together at the resume.
            if event.type == .keyDown, mainMenu?.performKeyEquivalent(with: event) == true {
                menuKeyCodes.insert(event.keyCode)
            } else if event.type == .keyUp {
                menuKeyCodes.remove(event.keyCode)
            }
            return true
        }
        if event.type == .flagsChanged {
            forwardGlobe(event, view: view)
            return false
        }
        // No keyboard key reaches tvOS as the TV button, which goes Home on a
        // press and opens Control Center when held. The Mac's Home key stands
        // in for it through vphoned, held for as long as the key is.
        if event.keyCode == Self.homeKeyCode, view.isTVGuest {
            if event.type == .keyDown, !event.isARepeat {
                view.control?.sendHIDDown(page: 0x0C, usage: 0x40)
            } else if event.type == .keyUp {
                view.control?.sendHIDUp(page: 0x0C, usage: 0x40)
            }
            return true
        }
        // tvOS consumes Escape as Back/Menu through its native keyboard.
        // Bypass both the phone swipe and the menu equivalent, forwarding the
        // matching press/release. Backspace remains available for text editing.
        if event.keyCode == Self.escapeKeyCode, view.isTVGuest {
            return false
        }
        // Esc replays the guest's back gesture: iOS has no back key, and a
        // forwarded Escape only reads as cancel. The press and its release both
        // stop here, so the guest sees neither. An iPad has a real Esc key —
        // it cancels a composition, a sheet or a menu — so there it goes
        // through like any other key.
        if event.keyCode == Self.escapeKeyCode, view.escapeIsBackGesture {
            if event.type == .keyDown {
                view.performBackGesture()
            }
            return true
        }
        if forwardThroughGuest(event, view: view) {
            return true
        }
        if event.type == .keyUp {
            return menuKeyCodes.remove(event.keyCode) != nil
        }
        if mainMenu?.performKeyEquivalent(with: event) == true {
            menuKeyCodes.insert(event.keyCode)
            return true
        }
        return false
    }

    // MARK: - Keys the Virtual Keyboard Drops

    /// Before a pause: lets go of 🌐 and every key held through vphoned, as
    /// leaving the window does, so their releases are not refused while paused.
    func releaseHeldGuestKeys() {
        releaseGlobe(leavingWindow: true)
        for (keyCode, key) in forwardedKeys {
            key.control.sendHIDUp(page: key.usage.page, usage: key.usage.usage)
            forwardedKeys[keyCode] = nil
        }
    }

    /// A rebuilt VM must not inherit keys or a guest connection from the old one.
    func resetGuestKeyState() {
        releaseGlobe(leavingWindow: true)
        forwardedKeys.removeAll()
        menuKeyCodes.removeAll()
    }

    /// fn / 🌐 reaches AppKit only as a flags change, and the virtual USB
    /// keyboard has no field for it. vphoned presses the guest's 🌐 for it, held
    /// for as long as fn is, so 🌐 alone switches the input source and 🌐
    /// shortcuts work. The event still goes on to the view, which keeps the
    /// virtual keyboard's own modifier state in step.
    private func forwardGlobe(_ event: NSEvent, view: VPhoneVirtualMachineView) {
        guard event.keyCode == VPhoneGuestKeyMap.functionKeyCode, let control = view.control else { return }
        let globe = VPhoneGuestKeyMap.globe
        if event.modifierFlags.contains(.function) {
            guard globeHolder == nil else { return }
            globeHolder = control
            control.sendHIDDown(page: globe.page, usage: globe.usage)
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: event.window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseGlobe(leavingWindow: true) }
            }
        } else {
            releaseGlobe(leavingWindow: false)
        }
    }

    /// Lets go of 🌐 in the guest. Leaving the window also lets go of every key
    /// still held through vphoned, whose release would never arrive.
    private func releaseGlobe(leavingWindow: Bool) {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        guard let holder = globeHolder else { return }
        globeHolder = nil
        if leavingWindow {
            for (keyCode, key) in forwardedKeys {
                key.control.sendHIDUp(page: key.usage.page, usage: key.usage.usage)
                forwardedKeys[keyCode] = nil
            }
        }
        let globe = VPhoneGuestKeyMap.globe
        holder.sendHIDUp(page: globe.page, usage: globe.usage)
    }

    /// Sends a key through vphoned instead of the virtual keyboard: a key
    /// `_VZKeyboard` would drop — the JIS input-mode and character keys,
    /// Context Menu, Insert, volume — and, while 🌐 is held, every key, so the
    /// guest sees 🌐 and the key from one keyboard and combines them (🌐H, 🌐A,
    /// 🌐←). Returns whether the event went this way; it then goes no further.
    private func forwardThroughGuest(_ event: NSEvent, view: VPhoneVirtualMachineView) -> Bool {
        if event.type == .keyUp {
            guard let key = forwardedKeys.removeValue(forKey: event.keyCode) else { return false }
            key.control.sendHIDUp(page: key.usage.page, usage: key.usage.usage)
            return true
        }
        let usage = globeHolder != nil
            ? VPhoneGuestKeyMap.usage(whileGlobeHeld: event.keyCode)
            : VPhoneGuestKeyMap.usage(forDroppedKeyCode: event.keyCode)
        guard let usage, let control = view.control else { return false }
        // The guest repeats a held key itself.
        guard !event.isARepeat, forwardedKeys[event.keyCode] == nil else { return true }
        forwardedKeys[event.keyCode] = (control, usage)
        control.sendHIDDown(page: usage.page, usage: usage.usage)
        return true
    }
}
