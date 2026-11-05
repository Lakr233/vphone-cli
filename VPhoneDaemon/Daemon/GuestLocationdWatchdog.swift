import CoreLocation
import Darwin
import Foundation
import IcliKit
import VphonedNative

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
///
/// On an iPhone Duo with CoreMotion's hinge, iOS 27.2's locationd that starts
/// with the guest answers but never hands a new CMAngleManager the hinge
/// angle (WebDriverAgent's hinge GET times out) until the hinge moves; it did
/// so on every cold boot measured. Its device-state relay now skips a resend
/// of the angle it holds, so the virtual hinge's periodic resend no longer
/// repairs it. A locationd started later serves the angle, so vphoned
/// restarts that first one once, after it has settled. See
/// Research/Guest/iphone_duo_bringup.md, "iOS 27.2, and WebDriverAgent's hinge
/// GET after boot".
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
    /// A locationd that started this soon after boot, on the uptime clock,
    /// started with the guest (it starts within a second).
    private static let bootStart: TimeInterval = 30
    /// How long the first locationd runs before it is replaced. One restarted
    /// 30 s after boot served the hinge angle 2 s later.
    private static let bootSettle: TimeInterval = 20

    /// Runs the checks; owns `restarts` and `bootLocationdHandled`.
    private let queue = DispatchQueue(label: "vphoned.locationd-watchdog", qos: .utility)
    /// Runs the request, which blocks for as long as locationd does not answer.
    private let probeQueue = DispatchQueue(label: "vphoned.locationd-probe", qos: .utility)
    private let started = Date()
    private var restarts = 0
    /// Whether the locationd that started with the guest was replaced, is
    /// gone, or needs nothing, so a later one is never taken for it.
    private var bootLocationdHandled = false

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
            restarted = restartLocationd(because: "did not answer")
            // The request returns once its locationd is gone. Waiting for it
            // keeps a second request from queueing behind a stuck first one.
            _ = answered.wait(timeout: .now() + Self.timeout)
        } else if bootLocationdWithoutHingeAngle() {
            restarted = restartLocationd(because: "started with the guest and gives no hinge angle")
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

    /// Whether the running locationd is the one that started with an iOS 27.2
    /// iPhone Duo and has settled, and so is due its one restart.
    private func bootLocationdWithoutHingeAngle() -> Bool {
        guard !bootLocationdHandled else { return false }
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
        guard vp_core_motion_hinge(), ProcessInfo.processInfo.isOperatingSystemAtLeast(version) else {
            bootLocationdHandled = true
            return false
        }
        var usage = VPProcessUsage()
        guard let pid = locationd(), vp_process_usage(Int32(pid), &usage), usage.has_task_info else { return false }
        // The uptime clock, because vphoned moves the wall clock to the Mac's
        // after boot, which moves no process's start.
        guard usage.start_uptime < Self.bootStart else {
            bootLocationdHandled = true
            return false
        }
        guard ProcessInfo.processInfo.systemUptime - usage.start_uptime >= Self.bootSettle else { return false }
        bootLocationdHandled = true
        return true
    }

    private func locationd() -> Int? {
        let rows = (try? listProcesses(filter: "locationd"))?["processes"] as? [[String: Any]] ?? []
        return rows.first(where: { $0["executable"] as? String == Self.executable })?["pid"] as? Int
    }

    /// Whether a locationd was killed.
    private func restartLocationd(because reason: String) -> Bool {
        guard let pid = locationd() else {
            NSLog("vphoned: locationd watchdog: no answer, and no locationd is running")
            return false
        }
        guard restarts < Self.maxRestarts else {
            NSLog("vphoned: locationd watchdog: locationd %d %@; restarted %d times already, leaving it", pid, reason, restarts)
            return false
        }
        restarts += 1
        // A deadlocked locationd does not finish its SIGTERM handler.
        guard kill(pid_t(pid), SIGKILL) == 0 else {
            NSLog("vphoned: locationd watchdog: kill(%d): %@", pid, String(cString: strerror(errno)))
            return false
        }
        NSLog("vphoned: locationd watchdog: locationd %d %@, killed it (restart %d)", pid, reason, restarts)
        return true
    }
}
