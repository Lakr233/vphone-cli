import Foundation
import IcliKit

/// Publishes the state a UI needs without requiring it to poll over HTTP.
/// State polling runs separately so a stalled powerd read cannot block commands.
final class GuestEventPublisher: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "vphoned.api.state", qos: .utility)
    private let hub: APIEventHub
    private let timer: DispatchSourceTimer
    private var previous: Data?

    init(hub: APIEventHub) {
        self.hub = hub
        timer = DispatchSource.makeTimerSource(queue: Self.queue)
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
            "frontmost_app": GuestForeground.current(),
            "low_power_mode": (try? lowPowerMode()) ?? [:],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              data != previous
        else { return }
        previous = data
        hub.broadcast(name: "device.state", data: state)
    }
}
