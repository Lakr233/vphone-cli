import Foundation
import Testing
@testable import VPhoneCoreKit

/// The wait loop's order of checks and its outcomes, on a fake clock.
struct GuestWaitTests {
    private final class Clock {
        var time = Date(timeIntervalSince1970: 1000)
        func now() -> Date { time }
        func sleep(_ seconds: TimeInterval) { time += seconds }
    }

    private func run(
        timeout: Int = 10,
        clock: Clock = Clock(),
        ping: () -> Bool = { false },
        exited: () -> Bool = { false },
        panicked: () -> Bool = { false },
        cancelled: () -> Bool = { false },
        progress: (Int) -> Void = { _ in },
    ) -> VPhoneGuestWait.Outcome {
        VPhoneGuestWait.run(
            timeout: timeout, pollInterval: 1,
            ping: ping, exited: exited, panicked: panicked, cancelled: cancelled,
            progress: progress, now: clock.now, sleep: clock.sleep,
        )
    }

    @Test func `an answer on the third poll is answered after two seconds`() {
        var polls = 0
        let outcome = run(ping: {
            polls += 1
            return polls == 3
        })
        #expect(outcome == .answered(2))
        #expect(polls == 3)
    }

    @Test func `an exited VM is reported without pinging that round`() {
        var pings = 0
        let outcome = run(ping: {
            pings += 1
            return false
        }, exited: { true })
        #expect(outcome == .exited)
        #expect(pings == 0)
    }

    @Test func `a panic is reported`() {
        #expect(run(panicked: { true }) == .panicked)
    }

    @Test func `a panic wins over an exit`() {
        #expect(run(exited: { true }, panicked: { true }) == .panicked)
    }

    @Test func `a guest that never answers times out after exactly the timeout`() {
        let clock = Clock()
        let start = clock.time
        #expect(run(timeout: 7, clock: clock) == .timedOut)
        #expect(clock.time.timeIntervalSince(start) == 7)
    }

    @Test func `cancellation is reported`() {
        #expect(run(cancelled: { true }) == .cancelled)
    }

    @Test func `progress gets the elapsed seconds once per iteration`() {
        var seen: [Int] = []
        _ = run(timeout: 4, progress: { seen.append($0) })
        #expect(seen == [0, 1, 2, 3])
    }

    @Test func `a ping that is false keeps polling`() {
        var pings = 0
        _ = run(timeout: 5, ping: {
            pings += 1
            return false
        })
        #expect(pings == 5)
    }
}
