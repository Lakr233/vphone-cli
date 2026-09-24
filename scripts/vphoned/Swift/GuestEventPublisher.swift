import Foundation
import IcliKit

/// Publishes the state a UI needs without requiring it to poll over HTTP.
/// The synchronous IcliKit calls share the same serial queue as commands.
final class GuestEventPublisher: @unchecked Sendable {
    private let hub: APIEventHub
    private let timer: DispatchSourceTimer
    private var previous: Data?

    init(hub: APIEventHub) {
        self.hub = hub
        timer = DispatchSource.makeTimerSource(queue: GuestAPI.queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3))
        timer.setEventHandler { [weak self] in self?.publishIfChanged() }
        timer.resume()
    }

    private func publishIfChanged() {
        guard hub.hasSubscribers else {
            previous = nil
            return
        }
        let state: [String: Any] = [
            "screen": screenInfo(),
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
