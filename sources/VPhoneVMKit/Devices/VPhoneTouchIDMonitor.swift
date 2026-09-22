import AppKit
import Darwin
import Dynamic
import Foundation

// MARK: - BiometricKit Delegate Sink

/// Standalone NSObject that receives BKOperationDelegate callbacks from biometrickitd.
/// No actor isolation — callbacks can arrive on any queue biometrickitd dispatches on.
/// Closures hop back to MainActor via Task so the state machine always runs there.
@MainActor
private final class VPhoneBiometricDelegate: NSObject {
    var onFingerDown: (() -> Void)?
    var onFingerUp: (() -> Void)?
    var onInterrupted: (() -> Void)?

    // MARK: BiometricKit delegate callbacks

    /// Primary dispatch path for Touch ID sensor contact on macOS.
    /// Called by BiometricKit after the XPC layer delivers the touch event.
    /// First param: non-zero = finger pressed, 0 = finger released (or context ID on some versions).
    @objc func touchIDButtonPressed(_ pressed: Int, client: AnyObject?) {
        print("[touchid-bk] touchIDButtonPressed: %ld (client: %@)", pressed, client.debugDescription)
        if pressed != 0 { onFingerDown?() } else { onFingerUp?() }
    }

    /// Fired by BKPresenceDetectOperation when finger presence changes.
    /// Second param is BOOL-encoded: non-zero = finger on sensor, 0 = finger off.
    @objc func operation(_ operation: AnyObject, presenceStateChanged state: Int) {
        print("[touchid-bk] presenceStateChanged: %ld", state)
        if state != 0 { onFingerDown?() } else { onFingerUp?() }
    }

    /// Called by BiometricKit singleton on finger presence change.
    /// On macOS Sequoia: 63 = kBiometricKitStatusFinger (down), 64 = kBiometricKitStatusNoFinger (up).
    @objc func statusMessage(_ status: UInt) {
        switch status {
        case 64: onFingerUp?()
        case 63: onFingerDown?()
        default:
            print("[touchid-bk] unknown status %lu — treating as finger down", status)
            onFingerDown?()
        }
    }

    /// 2-arg variant (some OS versions pass a client context).
    @objc func statusMessage(_ status: UInt, client: AnyObject?) {
        print("[touchid-bk] statusMessage: %lu (client: %@)", status, client.debugDescription)
        switch status {
        case 1:  onFingerDown?()
        case 0:  onFingerUp?()
        default: break
        }
    }

    /// 3-arg variant of statusMessage seen on BKDevice (some OS versions).
    @objc func statusMessage(_ status: UInt, details: AnyObject?, client: AnyObject?) {
        print("[touchid-bk] statusMessage:details: %lu", status)
        switch status {
        case 1:  onFingerDown?()
        case 0:  onFingerUp?()
        default: break
        }
    }

    // MARK: XPC interruption

    /// Sent by BKOperation when the XPC link to biometrickitd is torn down.
    @objc func operationInterrupted(_ operation: AnyObject) {
        print("[touchid-bk] operationInterrupted: %@", "\(operation)")
        onInterrupted?()
    }

    /// Also delivered on some OS versions as a bare connectionInterrupted message.
    @objc func connectionInterrupted() {
        print("[touchid-bk] connectionInterrupted")
        onInterrupted?()
    }

    // MARK: - Debug: catch unexpected messages in dev builds

    #if DEBUG
    override func responds(to aSelector: Selector!) -> Bool {
        let result = super.responds(to: aSelector)
        if !result {
            print("[touchid-bk] delegate asked about unknown selector: %@", NSStringFromSelector(aSelector))
        }
        return result
    }
    #endif
}

// MARK: - Touch ID Monitor

/// Monitors the physical Touch ID sensor for finger contact using the BiometricKit
/// singleton (`[BiometricKit manager]`) and its `detectPresenceWithOptions:` API,
/// which manages the XPC connection to biometrickitd internally.
/// Requires the com.apple.private.bmk.allow entitlement.
@MainActor
final class VPhoneTouchIDMonitor {
    private weak var control: VPhoneControl?
    private weak var window: NSWindow?

    /// Enables or disables Touch ID forwarding. Setting to false cancels the active
    /// BiometricKit session and unloads the framework; setting to true reconnects.
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                connectBiometricKit()
            } else {
                tearDown()
            }
        }
    }

    // BiometricKit objects, retained as AnyObject via Dynamic
    private var bkManager: AnyObject?                  // BiometricKit singleton
    private var bkDelegate: VPhoneBiometricDelegate?   // strong ref so it lives as long as the session
    private var reconnectTimer: DispatchWorkItem?

    // Tap detection state — all MainActor-isolated
    private var fingerIsDown = false
    private var tapCount = 0
    private var fingerLiftedTimer: DispatchWorkItem?
    private var doubleTapTimer: DispatchWorkItem?

    /// If no finger-down event arrives within this interval after the last one,
    /// treat the finger as lifted (fallback when finger-up events are missing).
    private let fingerLiftDebounce: TimeInterval = 0.20

    /// How long to wait after the first tap for a possible second tap.
    private let doubleTapWindow: TimeInterval = 0.30

    // MARK: - Lifecycle

    func start(control: VPhoneControl, window: NSWindow) {
        self.control = control
        self.window = window
        if isEnabled { connectBiometricKit() }
    }

    func stop() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        tearDown()
    }

    // MARK: - BiometricKit Connection

    private func connectBiometricKit() {
        // BiometricKit lives in the dyld shared cache but is not linked by the binary,
        // so we must explicitly load it before NSClassFromString can find its classes.
        let bkPath = "/System/Library/PrivateFrameworks/BiometricKit.framework/BiometricKit"
        if dlopen(bkPath, RTLD_NOW | RTLD_NOLOAD) != nil {
            print("[touchid-bk] BiometricKit already loaded")
        } else if dlopen(bkPath, RTLD_NOW) != nil {
            print("[touchid-bk] BiometricKit loaded via dlopen")
        } else {
            let why = String(cString: dlerror())
            print("[touchid-bk] dlopen failed: %@ — will try anyway", why)
        }

        // `BiometricKit` (no BK prefix) is the high-level singleton class that owns the
        // XPC connection to biometrickitd. +manager returns the shared instance.
        guard NSClassFromString("BiometricKit") != nil else {
            print("[touchid-bk] BiometricKit class not found — framework not loaded")
            return
        }

        guard let mgr = Dynamic.BiometricKit.manager().asObject else {
            print("[touchid-bk] BiometricKit.manager() returned nil")
            scheduleReconnect()
            return
        }
        bkManager = mgr

        // Wire delegate before starting detection so no events are missed.
        let delegate = VPhoneBiometricDelegate()
        delegate.onFingerDown = { [weak self] in
            self?.handleFingerDown()
        }
        delegate.onFingerUp = { [weak self] in
            self?.handleFingerUp()
        }
        delegate.onInterrupted = { [weak self] in
            self?.scheduleReconnect()
        }
        bkDelegate = delegate
        Dynamic(mgr).setDelegate(delegate)

        // Enable background finger detection so events fire when our process is not
        // the frontmost app (biometrickitd internal: enableBackgroundFdet:).
        Dynamic(mgr).enableBackgroundFdet(true)

        // Start continuous presence detection. nil options = default policy.
        Dynamic(mgr).detectPresenceWithOptions(nil)
    }

    private func tearDown() {
        if let mgr = bkManager {
            // Clear BK's delegate reference BEFORE releasing our delegate object.
            // BiometricKit holds an unsafe-unretained pointer; if we free the delegate
            // first, any in-flight BK callback will message a dangling pointer and
            // trigger a PAC ISA authentication trap in objc_opt_respondsToSelector.
            Dynamic(mgr).setDelegate(nil)
            Dynamic(mgr).cancel()
        }
        bkManager = nil
        bkDelegate = nil
    }

    private func scheduleReconnect() {
        tearDown()
        reconnectTimer?.cancel()
        print("[touchid-bk] scheduling reconnect in 2s")
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconnectTimer = nil
                self?.connectBiometricKit()
            }
        }
        reconnectTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Finger State Machine

    private func handleFingerUp() {
        guard fingerIsDown else { return }
        fingerIsDown = false
        fingerLiftedTimer?.cancel()
        fingerLiftedTimer = nil
    }

    private func handleFingerDown() {
        // Debounce: reschedule the "finger lifted" timer on every event.
        // If BK stops sending finger-down events (finger removed), the timer fires
        // and transitions us back to the finger-up state.
        fingerLiftedTimer?.cancel()
        let liftTimer = DispatchWorkItem { [weak self] in
            guard let self, self.fingerIsDown else { return }
            self.fingerIsDown = false
            self.fingerLiftedTimer = nil
        }
        fingerLiftedTimer = liftTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + fingerLiftDebounce, execute: liftTimer)

        // Ignore burst/continuation events while the finger is still down
        guard !fingerIsDown else { return }
        fingerIsDown = true

        tapCount += 1
        let count = tapCount

        guard let control, window?.isKeyWindow == true, control.isConnected else {
            print("[touchid] tap ignored (window not key or disconnected)")
            tapCount = 0
            return
        }

        if count >= 2 {
            // Double tap — cancel pending single-tap and send two Home presses
            doubleTapTimer?.cancel()
            doubleTapTimer = nil
            tapCount = 0
            control.sendHIDPress(page: 0x0C, usage: 0x40)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                control.sendHIDPress(page: 0x0C, usage: 0x40)
                print("[touchid] Double-tap detected, triggering app switcher")
            }
        } else {
            // First tap — arm a timer; fire Home if no second tap arrives in time
            doubleTapTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tapCount = 0
                self.doubleTapTimer = nil
                guard let control = self.control,
                      self.window?.isKeyWindow == true,
                      control.isConnected else { return }
                control.sendHIDPress(page: 0x0C, usage: 0x40)
                print("[touchid] Home sent")
            }
            doubleTapTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: timer)
        }
    }
}
