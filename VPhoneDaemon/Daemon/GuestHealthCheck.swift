import Dispatch
import Foundation

/// Health may load private frameworks or wait for preferences. Keep that work
/// off NIO, with one producer even after its clients' response deadline expires.
final class GuestHealthCheck: @unchecked Sendable {
    enum Outcome: @unchecked Sendable {
        case success([String: Any])
        case timedOut
        case busy
    }

    typealias Completion = @Sendable (Outcome) -> Void
    static let shared = GuestHealthCheck()

    private final class Attempt: @unchecked Sendable {
        let deadline: DispatchTime
        var completions: [Completion]
        var expired = false
        var timer: DispatchSourceTimer?

        init(deadline: DispatchTime, completion: @escaping Completion) {
            self.deadline = deadline
            completions = [completion]
        }
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "vphoned.health.producer", qos: .utility)
    private let deadlines = DispatchQueue(label: "vphoned.health.deadlines", qos: .utility)
    private let timeout: DispatchTimeInterval
    private let maximumWaiters: Int
    private var current: Attempt?

    init(timeout: DispatchTimeInterval = .seconds(3), maximumWaiters: Int = 32) {
        precondition(maximumWaiters > 0)
        self.timeout = timeout
        self.maximumWaiters = maximumWaiters
    }

    func request(produce: @escaping @Sendable () -> [String: Any], completion: @escaping Completion) {
        lock.lock()
        if let current {
            guard !current.expired, current.completions.count < maximumWaiters else {
                lock.unlock()
                completion(.busy)
                return
            }
            current.completions.append(completion)
            lock.unlock()
            return
        }
        let attempt = Attempt(deadline: .now() + timeout, completion: completion)
        current = attempt
        let timer = DispatchSource.makeTimerSource(queue: deadlines)
        timer.setEventHandler { self.expire(attempt) }
        timer.schedule(deadline: attempt.deadline)
        attempt.timer = timer
        timer.activate()
        lock.unlock()

        worker.async {
            self.lock.lock()
            let admitted = self.current === attempt && !attempt.expired && DispatchTime.now() < attempt.deadline
            self.lock.unlock()
            let report = admitted ? produce() : nil
            self.complete(attempt, report: report)
        }
    }

    private func expire(_ attempt: Attempt) {
        lock.lock()
        guard current === attempt, !attempt.expired else {
            lock.unlock()
            return
        }
        attempt.expired = true
        let completions = attempt.completions
        attempt.completions.removeAll()
        attempt.timer?.cancel()
        attempt.timer = nil
        lock.unlock()
        for completion in completions { completion(.timedOut) }
    }

    private func complete(_ attempt: Attempt, report: [String: Any]?) {
        lock.lock()
        guard current === attempt else {
            lock.unlock()
            return
        }
        current = nil
        attempt.timer?.cancel()
        attempt.timer = nil
        let completions = attempt.completions
        attempt.completions.removeAll()
        let expired = attempt.expired || DispatchTime.now() >= attempt.deadline
        lock.unlock()
        for completion in completions {
            if let report, !expired { completion(.success(report)) }
            else { completion(.timedOut) }
        }
    }
}
