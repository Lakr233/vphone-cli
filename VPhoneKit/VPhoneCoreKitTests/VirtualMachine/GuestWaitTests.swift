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
        budget: VPhoneGuestWait.Budget = .seconds(10),
        pollInterval: TimeInterval = 1,
        clock: Clock = Clock(),
        ping: () -> Bool = { false },
        exited: () -> Bool = { false },
        panicked: () -> Bool = { false },
        cancelled: () -> Bool = { false },
        progress: (Int) -> Void = { _ in },
    ) -> VPhoneGuestWait.Outcome {
        VPhoneGuestWait.run(
            budget: budget, pollInterval: pollInterval,
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
        #expect(run(budget: .seconds(7), clock: clock) == .timedOut)
        #expect(clock.time.timeIntervalSince(start) == 7)
    }

    @Test func `an attempts budget times out after exactly n ping attempts`() {
        var pings = 0
        let outcome = run(budget: .attempts(3), pollInterval: 2, ping: {
            pings += 1
            return false
        })
        #expect(outcome == .timedOut)
        #expect(pings == 3)
    }

    @Test func `an attempts budget answers on the nth attempt`() {
        var pings = 0
        let outcome = run(budget: .attempts(5), pollInterval: 2, ping: {
            pings += 1
            return pings == 3
        })
        #expect(outcome == .answered(4))
        #expect(pings == 3)
    }

    @Test func `cancellation is reported`() {
        #expect(run(cancelled: { true }) == .cancelled)
    }

    @Test func `progress gets the elapsed seconds once per iteration`() {
        var seen: [Int] = []
        _ = run(budget: .seconds(4), progress: { seen.append($0) })
        #expect(seen == [0, 1, 2, 3])
    }

    @Test func `a ping that is false keeps polling`() {
        var pings = 0
        _ = run(budget: .seconds(5), ping: {
            pings += 1
            return false
        })
        #expect(pings == 5)
    }
}
