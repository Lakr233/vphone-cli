import Dispatch
import Foundation

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [GuestHealthCheck.Outcome] = []
    private var producers = 0

    func produced() { lock.withLock { producers += 1 } }
    func append(_ outcome: GuestHealthCheck.Outcome) { lock.withLock { outcomes.append(outcome) } }
    var producerCount: Int { lock.withLock { producers } }
    var values: [GuestHealthCheck.Outcome] { lock.withLock { outcomes } }
}

private func wait(_ semaphore: DispatchSemaphore, _ message: String) {
    precondition(semaphore.wait(timeout: .now() + 5) == .success, message)
}

private func healthyReport() -> [String: Any] {
    ["status": "ok", "setup_pending": true, "binary_hash": "fixture",
     "capabilities": ["touch", "display"], "mobilegestalt_restart_pending": false]
}

@main
private enum HealthCheckTests {
    static func main() {
        coalescesWithoutBlockingCaller()
        timeoutKeepsProducerAdmission()
        expiredAdmissionDoesNotStartProducer()
        print("health checks: asynchronous delivery, bounded coalescing, timeout and late completion passed")
    }

    private static func coalescesWithoutBlockingCaller() {
        let health = GuestHealthCheck(timeout: .seconds(5), maximumWaiters: 2)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let replies = DispatchSemaphore(value: 0)
        let results = Results()
        let expected = healthyReport()
        DispatchQueue(label: "fixture.http.event-loop").async {
            health.request(produce: {
                results.produced()
                started.signal()
                wait(release, "producer was not released")
                return healthyReport()
            }) { outcome in results.append(outcome); replies.signal() }
            returned.signal()
        }
        wait(started, "health producer did not start")
        wait(returned, "health blocked its HTTP caller")
        health.request(produce: {
            preconditionFailure("coalesced request started another producer")
        }) { outcome in results.append(outcome); replies.signal() }
        health.request(produce: {
            preconditionFailure("over-limit request started another producer")
        }) { outcome in results.append(outcome); replies.signal() }
        wait(replies, "over-limit request did not fail promptly")
        precondition(results.values.count == 1)
        guard case .busy = results.values[0] else { preconditionFailure("waiter limit was not enforced") }
        release.signal()
        wait(replies, "first coalesced reply was lost")
        wait(replies, "second coalesced reply was lost")
        precondition(results.producerCount == 1)
        for outcome in results.values.dropFirst() {
            guard case let .success(report) = outcome else { preconditionFailure("healthy producer failed") }
            precondition(NSDictionary(dictionary: report).isEqual(to: expected), "health DTO was changed")
        }
    }

    private static func timeoutKeepsProducerAdmission() {
        let health = GuestHealthCheck(timeout: .milliseconds(80))
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let replies = DispatchSemaphore(value: 0)
        let results = Results()
        health.request(produce: {
            results.produced()
            started.signal()
            wait(release, "timed-out producer was not released")
            return ["status": "late"]
        }) { outcome in results.append(outcome); replies.signal() }
        wait(started, "timeout producer did not start")
        health.request(produce: {
            preconditionFailure("coalesced timeout started another producer")
        }) { outcome in results.append(outcome); replies.signal() }
        wait(replies, "first timeout was not delivered")
        wait(replies, "coalesced timeout was not delivered")
        for outcome in results.values {
            guard case .timedOut = outcome else { preconditionFailure("stalled producer did not time out") }
        }
        let refused = DispatchSemaphore(value: 0)
        health.request(produce: {
            preconditionFailure("timeout released a still-running producer's slot")
        }) { outcome in
            guard case .busy = outcome else { preconditionFailure("stalled producer did not retain admission") }
            refused.signal()
        }
        wait(refused, "probe after timeout did not fail promptly")
        precondition(results.producerCount == 1)
        release.signal()

        // A late result must not reply twice, and admission must recover after
        // the actual producer returns. Busy retries do not launch more work.
        let deadline = DispatchTime.now() + .seconds(5)
        while true {
            precondition(DispatchTime.now() < deadline, "producer admission did not recover")
            let answered = DispatchSemaphore(value: 0)
            let attempt = Results()
            health.request(produce: { results.produced(); return ["status": "ok"] }) { outcome in
                attempt.append(outcome)
                answered.signal()
            }
            wait(answered, "recovery probe did not complete")
            if case .success = attempt.values[0] { break }
            guard case .busy = attempt.values[0] else { preconditionFailure("recovery probe timed out") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(results.producerCount == 2)
        precondition(results.values.count == 2, "late completion replied twice")
    }

    private static func expiredAdmissionDoesNotStartProducer() {
        let health = GuestHealthCheck(timeout: .nanoseconds(0))
        let replied = DispatchSemaphore(value: 0)
        health.request(produce: {
            preconditionFailure("expired queued check still started health dependencies")
        }) { outcome in
            guard case .timedOut = outcome else { preconditionFailure("expired admission did not time out") }
            replied.signal()
        }
        wait(replied, "expired admission did not reply")
    }
}
