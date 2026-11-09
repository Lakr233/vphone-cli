import Foundation
import IcliKit

/// Publishes the state a UI needs without requiring it to poll over HTTP.
/// State polling runs separately so a stalled powerd read cannot block commands.
/// It runs only while a client is subscribed: with nobody listening the timer
/// used to wake vphoned every three seconds for nothing.
final class GuestEventPublisher: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "vphoned.api.state", qos: .utility)
    private static let interval: DispatchTimeInterval = .seconds(3)
    private let hub: APIEventHub
    private let timer: DispatchSourceTimer
    /// Owned by `queue`.
    private var previous: Data?
    private var polling = false

    init(hub: APIEventHub) {
        self.hub = hub
        timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.publishIfChanged() }
        timer.resume()
        hub.onSubscribedChange = { [weak self] _ in
            guard let self else { return }
            Self.queue.async { self.updatePolling() }
        }
    }

    /// Follows the hub's current state rather than the change that was
    /// reported, so two changes delivered out of order still end right.
    private func updatePolling() {
        let subscribed = hub.hasSubscribers
        guard subscribed != polling else { return }
        polling = subscribed
        if subscribed {
            timer.schedule(deadline: .now(), repeating: Self.interval)
        } else {
            previous = nil
            timer.schedule(deadline: .distantFuture)
        }
    }

    private func publishIfChanged() {
        guard !GuestRuntimePlatform.isVisionOS else { return }
        guard hub.hasSubscribers else {
            previous = nil
            return
        }
        let state: [String: Any] = [
            "screen": GuestAPI.activeScreenState(),
            "frontmost_app": frontmostApp(),
            "low_power_mode": (try? lowPowerMode()) ?? [:],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              data != previous
        else { return }
        previous = data
        hub.broadcast(name: "device.state", data: state)
    }
}
