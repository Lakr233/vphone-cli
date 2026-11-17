import Foundation

// MARK: - VPhoneGuestWait

/// Waits for vphoned in a launched VM to answer on `vphone.sock`. `vm launch
/// --detach` and Launchpad's first boot and `vm wait` share it; each keeps its
/// own wording for the outcomes. Synchronous, with the clock and the checks
/// injected.
public enum VPhoneGuestWait {
    public enum Outcome: Equatable, Sendable {
        /// vphoned answered after this many whole seconds.
        case answered(Int)
        /// The VM process is gone.
        case exited
        case panicked
        case timedOut
        case cancelled
    }

    /// Per iteration, in order: `cancelled`, `panicked`, `exited`, `progress`
    /// (elapsed whole seconds), `ping`, then `sleep(pollInterval)`. Gives up
    /// once `timeout` seconds have passed on `now`.
    public static func run(
        timeout: Int,
        pollInterval: TimeInterval,
        ping: () -> Bool,
        exited: () -> Bool,
        panicked: () -> Bool,
        cancelled: () -> Bool,
        progress: (Int) -> Void,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    ) -> Outcome {
        let started = now()
        while now().timeIntervalSince(started) < Double(timeout) {
            if cancelled() { return .cancelled }
            if panicked() { return .panicked }
            if exited() { return .exited }
            let elapsed = Int(now().timeIntervalSince(started))
            progress(elapsed)
            if ping() { return .answered(elapsed) }
            sleep(pollInterval)
        }
        return .timedOut
    }
}
