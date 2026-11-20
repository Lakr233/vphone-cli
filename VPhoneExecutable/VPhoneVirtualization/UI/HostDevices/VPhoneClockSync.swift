import AppKit
import Foundation

/// Keeps the guest's clock on the Mac's. A guest boots with the Mac's time
/// and timed then replaces it with the last time the guest ran; only NTP
/// corrects that, and where the guest's NTP does not get through the guest
/// stays behind by as long as it was powered off. A Mac that sleeps leaves a
/// running guest behind as well. vphoned offers timed the time the host
/// sends instead.
///
/// Call `start()` when the guest reports the "clock" capability, on every
/// connect: it sends the Mac's time, then again every minute, when the Mac
/// wakes, when the Mac's own clock is set and when a memory dump has paused
/// the guest. vphoned leaves a clock within a second of the Mac's alone, and
/// one set by hand in the guest's Settings.
///
/// See Research/Guest/host_clock_sync.md.
@MainActor
class VPhoneClockSync {
    /// Nothing tells the host that a guest's clock moved, so it asks. An
    /// answer of "close enough" costs the guest one read of its clock.
    private static let interval: Duration = .seconds(60)

    private let control: VPhoneGuestControl
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var ticking: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    /// What the last send came to, so a minute's repeat of it is not logged.
    private var lastOutcome: String?

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    func start() {
        if observers.isEmpty {
            let sources: [(NotificationCenter, Notification.Name)] = [
                (.default, .NSSystemClockDidChange),
                (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
                (.default, VPhoneMemoryDump.guestResumedNotification),
            ]
            observers = sources.map { center, name in
                let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.send() }
                }
                return (center, observer)
            }
        }
        lastOutcome = nil
        ticking?.cancel()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                self?.send()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
        ticking?.cancel()
        ticking = nil
        sending?.cancel()
        sending = nil
    }

    private func send() {
        // A send still out carries a time as good as a new one would.
        guard sending == nil else { return }
        sending = Task { [weak self, control] in
            let outcome: String
            var moved = false
            do {
                let answer = try await control.setClock()
                moved = answer.changed
                outcome = if answer.changed {
                    String(format: "guest was %.1f s %@, set to the Mac's time", abs(answer.offset), answer.offset > 0 ? "behind" : "ahead")
                } else if answer.automatic {
                    "guest is on the Mac's time"
                } else {
                    "guest keeps the time set in its Settings (automatic time is off)"
                }
            } catch {
                outcome = "could not set the guest's clock: \(error)"
            }
            guard !Task.isCancelled, let self else { return }
            sending = nil
            // A clock moved twice says so twice; anything else once.
            if moved || outcome != lastOutcome {
                print("[clock] \(outcome)")
            }
            lastOutcome = outcome
        }
    }
}
