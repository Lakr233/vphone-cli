import ApplicationServices
import Carbon.HIToolbox

// MARK: - Host Hot Keys

/// Holds back the Mac's own keyboard shortcuts while a VM window is key.
///
/// macOS handles its symbolic hot keys — Spotlight, input-source switching,
/// the 🌐 shortcuts — in the window server, before the VM window's event
/// monitor sees the key, and `capturesSystemKeys` does not reach them: ⌃Space
/// in an iPad guest opened Spotlight on the Mac, and 🌐H showed its desktop.
///
/// `PushSymbolicHotKeyMode` asks the window server to ignore them while this
/// process is frontmost. The Mac's settings are never changed: the mode lapses
/// when the process is deactivated or exits, crash included. It only takes
/// effect when the responsible app (Launchpad, or the terminal running
/// `vphone-cli`) is trusted for Accessibility; otherwise the Mac keeps its
/// shortcuts. The input-source hot keys (⌃Space) are outside the mode and stay
/// with the Mac; the guest switches with 🌐 or Device › Switch Guest Input
/// Source.
@MainActor
final class VPhoneHostHotKeys {
    static let shared = VPhoneHostHotKeys()

    private var token: UnsafeMutableRawPointer?
    private var reportedUntrusted = false

    private init() {}

    // MARK: - Suspend / Resume

    func suspend() {
        guard token == nil else { return }
        if !AXIsProcessTrusted(), !reportedUntrusted {
            reportedUntrusted = true
            print("[keys] not trusted for Accessibility; the Mac keeps its shortcuts while the VM window is key")
        }
        token = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabledExceptUniversalAccess))
    }

    func resume() {
        guard let token else { return }
        PopSymbolicHotKeyMode(token)
        self.token = nil
    }
}
