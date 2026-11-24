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
/// wakes, when the Mac's own clock is set and when the guest runs again after
/// a pause or a memory dump. vphoned leaves a clock within a second of the
/// Mac's alone, and one set by hand in the guest's Settings.
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
    /// The guest ran again while `sending` was out, so that send carries a
    /// time from before the pause; a new one follows once it is answered.
    private var resendsAfterSending = false
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
                let resumed = name == VPhoneMemoryDump.guestResumedNotification
                let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.send(afterPause: resumed) }
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
        resendsAfterSending = false
    }

    /// `afterPause`: the guest has just run again after a pause or a memory
    /// dump. A send out since before then is answered after the resume with
    /// the Mac's time from before the pause, which the guest's clock, stopped
    /// as long, matches; so another follows it. It follows rather than runs
    /// beside it, so the old time can never be the last one the guest takes.
    private func send(afterPause: Bool = false) {
        // A paused guest is set when it resumes (`guestResumedNotification`).
        guard !control.isGuestPaused else { return }
        // Otherwise a send still out carries a time as good as a new one would.
        guard sending == nil else {
            if afterPause { resendsAfterSending = true }
            return
        }
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
            if resendsAfterSending {
                resendsAfterSending = false
                send()
            }
        }
    }
}
