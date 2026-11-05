import CoreLocation
import Darwin
import Foundation
import IcliKit

/// Restarts a locationd that deadlocked while it was starting.
///
/// iOS 27.0's locationd can deadlock about a second after launch. Its main
/// thread runs a run-loop callback (`CLLocationController::sendTechStatusNotification`,
/// `checkActiveProviders`, or a silo timer) that waits synchronously on a silo
/// still being constructed, and that construction waits for a silo served by
/// the main queue. Nothing in locationd runs again, and every CoreLocation
/// client blocks on `com.apple.locationd.synchronous` for good: `location.*`
/// here, Maps, navd, nearbyd and the rest. It happened on about four boots in
/// ten, headless or windowed alike, and on about half of the restarts after
/// one. See Research/Guest/locationd_startup_deadlock.md.
///
/// vphoned asks locationd whether Location Services are on, the cheapest
/// synchronous request it serves. When no answer comes within `timeout`,
/// vphoned kills the running locationd and asks again at once, which has
/// launchd start a new one; the requests that were waiting fail instead of
/// blocking. A restart that deadlocks too is caught the same way.
final class GuestLocationdWatchdog: @unchecked Sendable {
    static let shared = GuestLocationdWatchdog()

    private static let executable = "/usr/libexec/locationd"
    /// A healthy locationd answers in milliseconds, also while it starts.
    private static let timeout: DispatchTimeInterval = .seconds(10)
    /// Often while locationd is most likely to be starting, then rarely.
    private static let startupInterval: DispatchTimeInterval = .seconds(15)
    private static let startupPeriod: TimeInterval = 300
    private static let interval: DispatchTimeInterval = .seconds(60)
    /// A locationd that deadlocks on every start is not helped by more restarts.
    private static let maxRestarts = 20

    /// Runs the checks; owns `restarts`.
    private let queue = DispatchQueue(label: "vphoned.locationd-watchdog", qos: .utility)
    /// Runs the request, which blocks for as long as locationd does not answer.
    private let probeQueue = DispatchQueue(label: "vphoned.locationd-probe", qos: .utility)
    private let started = Date()
    private var restarts = 0

    func startOnStartup() {
        queue.asyncAfter(deadline: .now() + Self.startupInterval) { self.check() }
    }

    private func check() {
        let answered = DispatchSemaphore(value: 0)
        probeQueue.async {
            _ = CLLocationManager.locationServicesEnabled()
            answered.signal()
        }
        var restarted = false
        if answered.wait(timeout: .now() + Self.timeout) == .timedOut {
            restarted = restartLocationd()
            // The request returns once its locationd is gone. Waiting for it
            // keeps a second request from queueing behind a stuck first one.
            _ = answered.wait(timeout: .now() + Self.timeout)
        }
        let next: DispatchTimeInterval = if restarted {
            .seconds(1)
        } else if Date().timeIntervalSince(started) < Self.startupPeriod {
            Self.startupInterval
        } else {
            Self.interval
        }
        queue.asyncAfter(deadline: .now() + next) { self.check() }
    }

    /// Whether a locationd was killed.
    private func restartLocationd() -> Bool {
        let rows = (try? listProcesses(filter: "locationd"))?["processes"] as? [[String: Any]] ?? []
        guard let pid = rows.first(where: { $0["executable"] as? String == Self.executable })?["pid"] as? Int else {
            NSLog("vphoned: locationd watchdog: no answer, and no locationd is running")
            return false
        }
        guard restarts < Self.maxRestarts else {
            NSLog("vphoned: locationd watchdog: locationd %d does not answer; restarted %d times already, leaving it", pid, restarts)
            return false
        }
        restarts += 1
        // A deadlocked locationd does not finish its SIGTERM handler.
        guard kill(pid_t(pid), SIGKILL) == 0 else {
            NSLog("vphoned: locationd watchdog: kill(%d): %@", pid, String(cString: strerror(errno)))
            return false
        }
        NSLog("vphoned: locationd watchdog: locationd %d did not answer, killed it (restart %d)", pid, restarts)
        return true
    }
}
