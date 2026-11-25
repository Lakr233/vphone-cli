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

    /// How long the wait keeps going before it gives up.
    public enum Budget: Equatable, Sendable {
        /// A wall-clock cap in seconds (`vm launch --detach --timeout`).
        case seconds(Int)
        /// A poll-iteration cap (Launchpad first boot / wait).
        case attempts(Int)
    }

    /// Per iteration, in order: the `budget` termination check, `cancelled`,
    /// `panicked`, `exited`, `progress` (elapsed whole seconds), `ping`, then
    /// `sleep(pollInterval)`. `.seconds(n)` gives up once `n` seconds have
    /// passed on `now`; `.attempts(n)` gives up after `n` completed ping
    /// attempts (each attempt sleeps `pollInterval` after its ping, including
    /// the last). Exhaustion returns `.timedOut`.
    public static func run(
        budget: Budget,
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
        var attempts = 0
        while true {
            switch budget {
            case let .seconds(seconds):
                if now().timeIntervalSince(started) >= Double(seconds) { return .timedOut }
            case let .attempts(count):
                if attempts >= count { return .timedOut }
            }
            if cancelled() { return .cancelled }
            if panicked() { return .panicked }
            if exited() { return .exited }
            let elapsed = Int(now().timeIntervalSince(started))
            progress(elapsed)
            if ping() { return .answered(elapsed) }
            sleep(pollInterval)
            attempts += 1
        }
    }
}
