import Foundation
import VphonedNative

// MARK: - Clock

/// The guest's wall clock, kept on the Mac's.
///
/// A guest boots with the Mac's time, from the virtual RTC. Once timed has
/// set the clock from a time source, it replaces that on every later boot
/// with the last time the guest ran, and waits for NTP. A guest whose NTP
/// does not get through is left behind by as long as it was powered off, and
/// a Mac that sleeps under a running guest leaves it behind as well.
///
/// `{time}` (seconds since 1970) is the Mac's time. A guest within
/// `clockTolerance` of it is left alone, and so is one whose automatic time
/// is off: that clock was set by hand in Settings. Otherwise the time is
/// offered to timed as an NTP result, and timed sets the clock itself and
/// tells the system. timed turns down a result its filter does not expect
/// until it has seen five, so the offer is repeated. `{automatic}` turns
/// timed's automatic time on or off, as Set Automatically does for the
/// clock; with `time` as well, it is applied first.
///
/// Each answer is `{time, automatic}`, plus `changed` after a set and
/// `offset` (the Mac's time less the guest's, before the change) after an
/// offer.
///
/// See Research/Guest/host_clock_sync.md.
extension GuestAPI {
    /// A guest this close to the Mac is left alone. timed's filter turns
    /// down anything further out than about seven times `clockUncertainty`
    /// and then starts over from it, so no offer is ever averaged in.
    private static let clockTolerance = 1.0
    /// What timed is told the offered time is good to: the request's way
    /// through the control connection, and the Mac's own clock.
    private static let clockUncertainty = 0.1
    /// One more than timed turns down before it starts over from a result.
    private static let clockOffers = 6
    private static let clockLock = NSLock()

    static func executeClock(_ m: ClockMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .timeClock:
            let received = DispatchTime.now()
            let automatic = params["automatic"] as? Bool
            guard params["time"] != nil else {
                guard let automatic else { return try clockState() }
                return try clockLock.withLock { try setAutomaticClock(automatic) }
            }
            let time = try requiredNumber(params, "time")
            // timed refuses anything before 2001; nothing sends that in earnest.
            guard time > kCFAbsoluteTimeIntervalSince1970 else {
                throw GuestAPIError.invalidRequest("time must be seconds since 1970")
            }
            return try clockLock.withLock {
                let switched = try automatic.map { try setAutomaticClock($0)["changed"] as? Bool ?? false } ?? false
                var state = try offerClock {
                    time + Double(DispatchTime.now().uptimeNanoseconds - received.uptimeNanoseconds) / 1e9
                }
                state["changed"] = switched || state["changed"] as? Bool == true
                return state
            }
        }
    }

    private static func clockState() throws -> [String: Any] {
        let automatic: Any = switch vp_clock_automatic() {
        case 1: true
        case 0: false
        case -2: throw GuestAPIError.operationFailed("timed did not answer within 3 seconds")
        default: NSNull()
        }
        return ["time": Date().timeIntervalSince1970, "automatic": automatic]
    }

    private static func setAutomaticClock(_ enabled: Bool) throws -> [String: Any] {
        var state = try clockState()
        guard let current = state["automatic"] as? Bool else {
            throw GuestAPIError.operationFailed("CoreTime's automatic time setting is unavailable on this guest")
        }
        if current != enabled {
            guard vp_clock_set_automatic(enabled) == 0 else {
                throw GuestAPIError.operationFailed("timed did not take the automatic time setting")
            }
            var applied = false
            for _ in 0 ..< 40 where !applied {
                Thread.sleep(forTimeInterval: 0.05)
                applied = vp_clock_automatic() == (enabled ? 1 : 0)
            }
            guard applied else {
                throw GuestAPIError.operationFailed("timed did not apply the automatic time setting")
            }
            NSLog("vphoned: automatic time turned %@", enabled ? "on" : "off")
            state = try clockState()
        }
        state["changed"] = current != enabled
        return state
    }

    private static func offerClock(_ hostTime: () -> Double) throws -> [String: Any] {
        var state = try clockState()
        let offset = hostTime() - Date().timeIntervalSince1970
        state["offset"] = offset
        state["changed"] = false
        guard abs(offset) >= clockTolerance, state["automatic"] as? Bool != false else { return state }

        var remaining = offset
        for _ in 0 ..< clockOffers {
            switch vp_clock_offer(hostTime(), clockUncertainty) {
            case 0: break
            case -1: throw GuestAPIError.operationFailed("CoreTime has no TMSetSourceTime on this guest")
            default: throw GuestAPIError.operationFailed("timed did not take the time within 3 seconds")
            }
            // timed sets the clock on its own queue, a few milliseconds later.
            for _ in 0 ..< 6 {
                Thread.sleep(forTimeInterval: 0.05)
                remaining = hostTime() - Date().timeIntervalSince1970
                if abs(remaining) < clockTolerance { break }
            }
            guard abs(remaining) >= clockTolerance else {
                NSLog("vphoned: clock moved %.3f s to the Mac's time", offset)
                state["time"] = Date().timeIntervalSince1970
                state["changed"] = true
                return state
            }
        }
        throw GuestAPIError.operationFailed(String(
            format: "timed kept its own time, %.3f s from the Mac's. It holds a time it trusts more, or vphoned lacks NTP in com.apple.timed.sources.",
            -remaining,
        ))
    }
}
