import Foundation

// MARK: - Machine

/// A refused or undelivered vphoned call, as the setup boot sees it.
public struct VPhoneGuestCallError: Error, CustomStringConvertible, Sendable {
    public enum Kind: Sendable {
        /// The request did not reach vphoned or its answer did not come back:
        /// no control socket, the guest not connected, a timeout.
        case transport
        /// vphoned answered with an error object.
        case refused
    }

    public var kind: Kind
    public var message: String
    /// vphoned's error object (`guest_error` on `vphone.sock`), as JSON.
    public var detailJSON: String?

    public init(kind: Kind, message: String, detail: [String: Any]? = nil) {
        self.kind = kind
        self.message = message
        detailJSON = detail.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    public var detail: [String: Any]? {
        detailJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    public var code: String? {
        detail?["code"] as? String
    }

    /// Worth asking again: the guest was not reachable, or vphoned said the
    /// operation may succeed later (`retryable`, `reason: busy`).
    public var isRetryable: Bool {
        switch kind {
        case .transport:
            return true
        case .refused:
            let detail = detail
            return detail?["retryable"] as? Bool == true || detail?["reason"] as? String == "busy"
        }
    }

    public var description: String {
        message
    }
}

/// The VM a setup boot drives. `VPhoneCommand` implements it over
/// `vphone-vm` and its `vphone.sock`; tests implement it with a scripted
/// guest.
public protocol VPhoneTemplateSetupMachine: AnyObject {
    /// Starts the VM process. Refuses a frozen template.
    func start() throws
    /// Why the VM can no longer serve the setup boot (its process exited, the
    /// guest panicked), or nil while it runs.
    func failure() -> String?
    /// Whether the VM process has exited with status 0 and no guest panic,
    /// as vphone-vm does when the guest powers the virtual machine off.
    func exitedCleanly() -> Bool
    /// Whether vphoned answers through the VM's control socket.
    func ping() -> Bool
    /// One vphoned method. Throws ``VPhoneGuestCallError``.
    func call(_ method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any]
    /// Asks the guest to shut down and waits for the VM process to exit.
    /// True when it shut down cleanly within `timeout`; false when it had to
    /// be turned off or is still running (it is then killed).
    func stop(timeout: TimeInterval) -> Bool
    /// Ends the VM process at once, after a failure.
    func kill()
}

public protocol VPhoneTemplateSetupClock {
    func now() -> Date
    func sleep(_ seconds: TimeInterval)
}

public struct VPhoneSystemClock: VPhoneTemplateSetupClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

// MARK: - Plan

/// How long each step of a setup boot may take. Every step has a deadline;
/// a step that misses it fails the setup boot.
public struct VPhoneTemplateSetupTimeouts: Equatable, Sendable {
    /// From the VM start until vphoned answers. A first boot reaches it in a
    /// few seconds; the first-boot check of `vm create` allows 300.
    public var connect: TimeInterval = 300
    public var snapshot: TimeInterval = 120
    /// vphoned writes the keys at once. A vphoned that also has to restart
    /// SpringBoard is refused until the first boot's data migration ends,
    /// which took up to 98 s on a fast Mac and more than 120 s on a MacBook
    /// Air, so the deadline is sized like the settle step's.
    public var skipSetup: TimeInterval = 600
    /// Overall, across `setup.settle` calls of at most `settleCallLimit`
    /// seconds each. The first boot's data migration ended 60–180 s after
    /// the VM started on a fast Mac (2026-10-09); a slow host takes longer.
    public var settle: TimeInterval = 600
    /// No progress for this long while data migration has not finished is a
    /// stall: the settle step captures what installd and DataMigrator are
    /// doing, reboots the guest once and waits `settle` again. On a 27.0.1
    /// setup boot (2026-10-15) the app expansion stopped with 46 apps staged
    /// and installd idle for all 600 s; the next boot finished it in 45 s.
    /// A healthy boot's longest quiet stretch, `SpringBoard.migrator` after
    /// the expansion, took 26–67 s.
    public var settleStall: TimeInterval = 180
    /// For capturing a stall before the reboot, spindump included.
    public var stallCapture: TimeInterval = 120
    /// How often a waiting step prints its progress.
    public var progressInterval: TimeInterval = 30
    public var removeApps: TimeInterval = 300
    public var serviceProfile: TimeInterval = 180
    /// From `system.reboot` until vphoned of the new boot answers (P1: 20 s).
    public var reboot: TimeInterval = 300
    /// One `processes.list` while waiting for the new boot. It answers within
    /// a few seconds even right after a boot; one that reaches vphoned just
    /// before the reboot stops it is never answered and holds the step for
    /// this whole timeout (30 s made the step take 33 s instead of 10 s in
    /// about a third of the setup boots).
    public var rebootPoll: TimeInterval = 10
    public var verify: TimeInterval = 120
    public var crashReports: TimeInterval = 60
    public var deviceName: TimeInterval = 30
    /// The VM gives the guest 15 s to shut down before turning it off.
    public var stop: TimeInterval = 60
    /// Between attempts of a retryable call.
    public var retryInterval: TimeInterval = 3
    /// Between polls of the control socket.
    public var pollInterval: TimeInterval = 1

    public init() {}

    public static let standard = VPhoneTemplateSetupTimeouts()
}

/// What a setup boot does to the guest, from the slimming a template's key
/// promises (or the switches of `vm template setup`).
public struct VPhoneTemplateSetupPlan: Equatable, Sendable {
    public var serviceProfile: String
    public var serviceGroups: [String]
    public var removedApps: [String]
    /// Strict: whether falling short of this plan fails the setup boot, an
    /// app vphoned does not remove above all, instead of being reported and
    /// left out of the recorded steps. A template being built has its key,
    /// and with it the apps it promises, fixed; so does a machine Launchpad
    /// (`vm template setup --strict`) adopts under the key `vm template find`
    /// gave. Otherwise a machine to be adopted gets a key from what was done.
    public var requiresEveryApp: Bool
    /// Clear the device name `vphone-vm` pinned during this boot, so a clone
    /// does not show the template's name before its own VM pins its name.
    public var clearsDeviceName: Bool
    /// Delete the crash reports the template's own boots left (above all the
    /// restore's pre-CFW `initproc failed` panic, written at the first boot
    /// after CFW), so a clone does not start with reports of boots it never had.
    public var clearsCrashReports: Bool
    public var timeouts: VPhoneTemplateSetupTimeouts

    public init(
        slimming: VPhoneMachineTemplateSlimming,
        requiresEveryApp: Bool,
        clearsDeviceName: Bool = true,
        clearsCrashReports: Bool = true,
        timeouts: VPhoneTemplateSetupTimeouts = .standard,
    ) {
        serviceProfile = slimming.serviceProfile
        serviceGroups = slimming.serviceGroups
        removedApps = slimming.removedApps
        self.requiresEveryApp = requiresEveryApp
        self.clearsDeviceName = clearsDeviceName
        self.clearsCrashReports = clearsCrashReports
        self.timeouts = timeouts
    }
}

// MARK: - Steps and outcome

/// The steps of a setup boot, in the order they run. The order is fixed:
/// the snapshot goes before anything writes to the System volume's blocks
/// again; Setup is skipped before first-boot work is waited for; apps are
/// removed only after installd expanded them; the profile (with the sign-in
/// follow-up group) comes after first-boot work, and a reboot makes launchd
/// honor it before the result is checked.
public enum VPhoneTemplateSetupStep: String, CaseIterable, Sendable, CustomStringConvertible {
    case boot
    case connect
    case snapshot
    case skipSetup = "setup-skip"
    case settle
    case removeApps = "remove-apps"
    case serviceProfile = "service-profile"
    case reboot
    case verify
    case crashReports = "crash-reports"
    case deviceName = "device-name"
    case stop

    public var description: String {
        switch self {
        case .boot: "start the VM"
        case .connect: "wait for vphoned"
        case .snapshot: "0. delete the orig-fs snapshot"
        case .skipSetup: "a. skip Setup Assistant"
        case .settle: "b. wait for first-boot work"
        case .removeApps: "c. remove system apps"
        case .serviceProfile: "d/e. apply the service profile"
        case .reboot: "f. reboot"
        case .verify: "f. verify after the reboot"
        case .crashReports: "clear the crash reports"
        case .deviceName: "clear the pinned device name"
        case .stop: "g. shut down"
        }
    }
}

public struct VPhoneTemplateSetupAppResult: Equatable, Sendable {
    public var bundleID: String
    /// vphoned's status: `removed`, `absent`, `unregistered_stale` or `failed`.
    public var status: String
    public var error: String?
    /// How many times vphoned called LaunchServices to unregister the app:
    /// more than one when the app was still listed after the first call (the
    /// race with Find My's first-boot registration). vphoned reports it only
    /// above one; 1 otherwise.
    public var unregisterAttempts: Int

    public init(bundleID: String, status: String, error: String? = nil, unregisterAttempts: Int = 1) {
        self.bundleID = bundleID
        self.status = status
        self.error = error
        self.unregisterAttempts = unregisterAttempts
    }

    /// The app is not installed afterwards, whichever way.
    public var isGone: Bool {
        ["removed", "absent", "unregistered_stale"].contains(status)
    }
}

public struct VPhoneTemplateSetupOutcome: Equatable, Sendable {
    public var deletedSnapshots: [String] = []
    /// No `orig-fs.disabled.rn-*` snapshot is left (deleted now or before).
    public var snapshotsGone = false
    public var setupSkipped = false
    public var settled = false
    /// Reboots the settle step made to resume a stalled first boot (0 or 1).
    public var settleReboots = 0
    public var apps: [VPhoneTemplateSetupAppResult] = []
    public var serviceProfile = "none"
    public var serviceGroups: [String] = []
    /// Labels the profile owns after it was applied.
    public var servicesOwned = 0
    public var verified = false
    /// Names of the crash reports deleted before the shutdown.
    public var clearedCrashReports: [String] = []
    public var deviceNameCleared = false
    public var stoppedCleanly = false
    public var durations: [VPhoneTemplateSetupStep: TimeInterval] = [:]
    public var warnings: [String] = []

    public init() {}

    public var removedApps: [String] {
        apps.filter(\.isGone).map(\.bundleID).sorted()
    }

    /// The apps vphoned had to unregister more than once, with the number of
    /// attempts.
    public var retriedUnregistrations: [String: Int] {
        var retried: [String: Int] = [:]
        for app in apps where app.unregisterAttempts > 1 {
            retried[app.bundleID] = app.unregisterAttempts
        }
        return retried
    }

    /// Where the slimming done so far falls short of `plan`: an app not
    /// removed, another service profile or groups. What a strict setup boot
    /// refuses once the profile is applied.
    public func deviations(from plan: VPhoneTemplateSetupPlan) -> [String] {
        var lines: [String] = []
        let kept = Set(plan.removedApps).subtracting(removedApps).sorted()
        if !kept.isEmpty {
            let reasons = kept.map { id in
                apps.first { $0.bundleID == id }.map { "\(id) (\($0.error ?? $0.status))" } ?? id
            }
            lines.append("not removed: \(reasons.joined(separator: ", "))")
        }
        if serviceProfile != plan.serviceProfile {
            lines.append("service profile \(serviceProfile), not \(plan.serviceProfile)")
        }
        if serviceGroups.sorted() != plan.serviceGroups.sorted() {
            lines.append("service groups \(serviceGroups.sorted().joined(separator: ",")), not \(plan.serviceGroups.sorted().joined(separator: ","))")
        }
        return lines
    }

    /// Every step ran and the VM shut down cleanly.
    public var isComplete: Bool {
        snapshotsGone && setupSkipped && settled && verified && stoppedCleanly
    }

    /// The steps a template records.
    public func applying(to steps: VPhoneMachineTemplateSteps) -> VPhoneMachineTemplateSteps {
        var steps = steps
        steps.snapshotDeleted = snapshotsGone
        steps.setupDone = isComplete
        steps.serviceProfile = serviceProfile
        steps.serviceGroups = serviceGroups.sorted()
        steps.removedApps = removedApps
        steps.unregisterAttempts = retriedUnregistrations
        return steps
    }
}

public struct VPhoneTemplateSetupFailure: Error, CustomStringConvertible, LocalizedError {
    public var step: VPhoneTemplateSetupStep
    public var reason: String
    public var outcome: VPhoneTemplateSetupOutcome

    public var description: String {
        "Setup boot failed at step \(step.rawValue) (\(step)): \(reason)"
    }

    public var errorDescription: String? {
        description
    }
}

// MARK: - Setup boot

/// Boots a template (or a machine about to be adopted as one) once and
/// finishes it the way every clone should start: Setup skipped, first-boot
/// work done, the system apps and services the key promises removed and
/// turned off, the `orig-fs` snapshot deleted. Then it reboots, checks the
/// result and shuts down.
///
/// A step that fails stops the run: the VM is killed, the failure names the
/// step, and the caller records nothing, so a template build is never frozen
/// from a failed setup boot. Calls vphoned marks retryable (or that did not
/// reach it) are repeated until the step's deadline.
public final class VPhoneTemplateSetupBoot {
    public static let snapshotPrefix = "orig-fs.disabled.rn-"
    /// The sign-in follow-up group the trimmed profile includes by default
    /// (step e), and the labels it must have turned off.
    public static let signInFollowUpGroup = "signin_followup"
    public static let signInFollowUpLabels = ["com.apple.appleidsetupd", "com.apple.followupd"]
    /// One `setup.settle` call waits at most this long (vphoned's cap is
    /// 110 s, the host's read timeout 120 s), so the step prints progress
    /// between calls.
    static let settleCallLimit = 30

    private let machine: VPhoneTemplateSetupMachine
    private let plan: VPhoneTemplateSetupPlan
    private let clock: VPhoneTemplateSetupClock
    private let log: (String) -> Void
    private var outcome = VPhoneTemplateSetupOutcome()
    private var timeouts: VPhoneTemplateSetupTimeouts {
        plan.timeouts
    }

    public init(
        machine: VPhoneTemplateSetupMachine,
        plan: VPhoneTemplateSetupPlan,
        clock: VPhoneTemplateSetupClock = VPhoneSystemClock(),
        log: @escaping (String) -> Void = { print($0) },
    ) {
        self.machine = machine
        self.plan = plan
        self.clock = clock
        self.log = log
    }

    /// Runs every step. Throws ``VPhoneTemplateSetupFailure``.
    public func run() throws -> VPhoneTemplateSetupOutcome {
        outcome = VPhoneTemplateSetupOutcome()
        var current = VPhoneTemplateSetupStep.boot
        var running = false
        func step(_ which: VPhoneTemplateSetupStep, _ body: () throws -> Void) throws {
            current = which
            log("[setup] \(which)")
            let start = clock.now()
            try body()
            outcome.durations[which] = clock.now().timeIntervalSince(start)
        }
        do {
            try step(.boot) {
                try machine.start()
                running = true
            }
            try step(.connect) { try waitForGuest(deadline: deadline(timeouts.connect)) }
            try step(.snapshot) { try deleteSnapshot() }
            try step(.skipSetup) { try skipSetup() }
            try step(.settle) { try settle() }
            try step(.removeApps) { try removeApps() }
            try step(.serviceProfile) {
                try applyServiceProfile()
                try requirePlan()
            }
            try step(.reboot) { try reboot() }
            try step(.verify) { try verify() }
            try step(.crashReports) { clearCrashReports() }
            try step(.deviceName) { clearDeviceName() }
            try step(.stop) {
                running = false
                guard machine.stop(timeout: timeouts.stop) else {
                    throw StepError("the guest did not shut down cleanly within \(Int(timeouts.stop)) s; the VM was turned off")
                }
                outcome.stoppedCleanly = true
            }
            log("[setup] done")
            return outcome
        } catch {
            if running {
                machine.kill()
            }
            let reason = (error as? StepError)?.message ?? "\(error)"
            log("[setup] failed at \(current.rawValue): \(reason)")
            throw VPhoneTemplateSetupFailure(step: current, reason: reason, outcome: outcome)
        }
    }

    // MARK: Steps

    private func waitForGuest(deadline: Date) throws {
        while true {
            try checkMachine()
            if machine.ping() {
                return
            }
            guard clock.now() < deadline else {
                throw StepError("vphoned did not answer within \(Int(timeouts.connect)) s")
            }
            clock.sleep(timeouts.pollInterval)
        }
    }

    /// 0. `apfs.snapshot.delete` selects every `orig-fs.disabled.rn-*`
    /// snapshot; none there is fine (deleted before, or never made).
    private func deleteSnapshot() throws {
        let result = try call("apfs.snapshot.delete", ["force": true], deadline: deadline(timeouts.snapshot))
        outcome.deletedSnapshots = strings(result["deleted"])
        let left = (strings(result["remaining"]) + strings(result["after"])).filter { $0.hasPrefix(Self.snapshotPrefix) }
        guard left.isEmpty else {
            throw StepError("snapshots still present after deletion: \(Set(left).sorted().joined(separator: ", "))")
        }
        outcome.snapshotsGone = true
        log(outcome.deletedSnapshots.isEmpty
            ? "  no orig-fs snapshot left to delete"
            : "  deleted \(outcome.deletedSnapshots.joined(separator: ", "))")
    }

    /// a. `setup.skip` writes purplebuddy's keys. On the setup boot (the
    /// guest's first) data migration is still running: SpringBoard decides
    /// whether to run Setup only when it ends, so vphoned leaves SpringBoard
    /// alone and the step takes a moment. Before vphoned did that, it asked
    /// FrontBoard to restart SpringBoard, which FrontBoard ignores until
    /// migration ends, and the fallback `launchctl stop` failed with launchd
    /// status 144 ("Requestor lacks required entitlement"); the step was
    /// retried for 45–98 s, as long as migration had left. Waiting for
    /// migration is now part of the settle step. Right after vphoned first
    /// answers, cfprefsd may not be up yet ("Cannot allocate memory" seconds
    /// into a fresh 27.0 boot). The skip is idempotent, so any refusal is
    /// retried until the deadline.
    private func skipSetup() throws {
        let start = clock.now()
        var lastProgress = start
        let result = try call(
            "setup.skip", ["force": true], deadline: deadline(timeouts.skipSetup), retryingRefusals: true,
        ) { [self] error in
            // A vphoned that restarts SpringBoard is refused until data
            // migration ends: report the wait, not every refusal.
            guard Self.isSpringBoardRestartRefusal(error.message) else { return "  setup.skip: \(error.message); retrying" }
            let now = clock.now()
            guard now.timeIntervalSince(lastProgress) >= timeouts.progressInterval || lastProgress == start else { return nil }
            lastProgress = now
            return "  waiting for the guest's first-boot data migration before SpringBoard can restart (\(Int(now.timeIntervalSince(start))) s)"
        }
        guard result["setup_done"] as? Bool == true else {
            throw StepError("setup.skip did not report setup_done")
        }
        outcome.setupSkipped = true
        let respring = result["respring"] as? [String: Any]
        if respring?["restarted"] as? Bool == false {
            log("  SpringBoard left alone: \(respring?["reason"] as? String ?? "not restarted"); it reads the keys when data migration ends")
        }
    }

    /// The refusal of a SpringBoard restart FrontBoard ignored: 2.9.0's
    /// "relaunch action ignored and launchd stop failed: 144 …", or the
    /// later "… SpringBoard did not restart: …".
    static func isSpringBoardRestartRefusal(_ message: String) -> Bool {
        message.contains("relaunch action ignored") || message.contains("SpringBoard did not restart")
    }

    /// b. `setup.settle` waits at most `settleCallLimit` seconds per call;
    /// it is called again until the overall deadline, printing what it waits
    /// for in between. It settles once the system apps are expanded and data
    /// migration has ended, which is also when SpringBoard reads the keys
    /// `setup.skip` wrote. A first boot that stops making progress
    /// (`SettleStallWatch`) is captured and rebooted once; data migration
    /// carries on in the next boot, and the deadline starts again.
    private func settle() throws {
        let start = clock.now()
        var end = deadline(timeouts.settle)
        var watch = SettleStallWatch(window: timeouts.settleStall)
        var reasons: [String] = []
        while true {
            let remaining = end.timeIntervalSince(clock.now())
            guard remaining > 0 else {
                throw StepError("first-boot work did not settle within \(Int(timeouts.settle)) s"
                    + (outcome.settleReboots > 0 ? " of the reboot that was to resume it" : "")
                    + (reasons.isEmpty ? "" : ": \(reasons.joined(separator: "; "))"))
            }
            let wait = Int(min(Double(Self.settleCallLimit), max(10, remaining.rounded(.up))))
            let result = try call("setup.settle", ["timeout_s": wait], deadline: end, timeout: Double(wait) + 20)
            let elapsed = Int(clock.now().timeIntervalSince(start))
            if result["settled"] as? Bool == true {
                outcome.settled = true
                log("  settled after \(elapsed) s")
                return
            }
            reasons = strings(result["reasons"])
            log(Self.settleProgress(reasons, elapsed: elapsed))

            let signals = SettleSignals(result["signals"] as? [String: Any])
            guard let quiet = watch.observe(signals, at: clock.now()), outcome.settleReboots == 0 else { continue }
            let summary = signals?.summary ?? "no signals"
            log("  first-boot work made no progress for \(Int(quiet)) s (\(summary)); data migration has not finished")
            captureStall()
            log("  rebooting the guest once to resume first-boot work")
            try restartGuest(deadline: deadline(timeouts.reboot))
            outcome.settleReboots += 1
            outcome.warnings.append("first-boot work stalled at \(elapsed) s (\(summary)); the guest was rebooted once to resume it")
            end = deadline(timeouts.settle)
            watch = SettleStallWatch(window: timeouts.settleStall)
        }
    }

    /// What one `setup.settle` answer's `signals` say about progress.
    struct SettleSignals: Equatable {
        var stagedSystemApps: Int?
        /// The app counts of the answer's last polls, oldest first.
        var appCounts: [Int?]
        var installdPID: Int?
        var installdCPUSeconds: Double?
        /// installd's CPU between the answer's last two polls.
        var installdCPUDelta: Double?
        var dataMigrationDone: Bool?

        init(
            stagedSystemApps: Int? = nil, appCounts: [Int?] = [], installdPID: Int? = nil,
            installdCPUSeconds: Double? = nil, installdCPUDelta: Double? = nil, dataMigrationDone: Bool? = nil,
        ) {
            self.stagedSystemApps = stagedSystemApps
            self.appCounts = appCounts
            self.installdPID = installdPID
            self.installdCPUSeconds = installdCPUSeconds
            self.installdCPUDelta = installdCPUDelta
            self.dataMigrationDone = dataMigrationDone
        }

        /// Nil without `signals` (a vphoned that does not send them).
        init?(_ signals: [String: Any]?) {
            guard let signals else { return nil }
            func int(_ key: String) -> Int? {
                VPhoneTemplateSetupBoot.number(signals[key]).flatMap { Int(exactly: $0.rounded()) }
            }
            self.init(
                stagedSystemApps: int("staged_system_apps"),
                appCounts: (signals["app_counts"] as? [Any] ?? []).map { VPhoneTemplateSetupBoot.number($0).map { Int($0) } },
                installdPID: int("installd_pid"),
                installdCPUSeconds: VPhoneTemplateSetupBoot.number(signals["installd_cpu_seconds"]),
                installdCPUDelta: VPhoneTemplateSetupBoot.number(signals["installd_cpu_delta"]),
                dataMigrationDone: signals["data_migration_done"] as? Bool,
            )
        }

        var appCount: Int? {
            appCounts.last ?? nil
        }

        /// `46 apps staged, 220 apps, installd 312 idle`.
        var summary: String {
            var parts = ["\(stagedSystemApps.map(String.init) ?? "?") apps staged"]
            if let appCount {
                parts.append("\(appCount) apps")
            }
            parts.append(installdPID.map { "installd \($0)" } ?? "installd not running")
            return parts.joined(separator: ", ")
        }
    }

    /// Tells a slow first boot from a stalled one across `setup.settle`
    /// answers. Progress is any change in the staged apps, the app count,
    /// installd's pid or the migration's state, or installd using CPU
    /// (vphoned's idle threshold, 0.2 s between polls). Stalled: no progress
    /// for `window` while data migration has not finished; an unknown
    /// migration state never stalls.
    struct SettleStallWatch {
        static let installdBusyCPUSeconds = 0.2

        let window: TimeInterval
        private var last: SettleSignals?
        private var lastProgress: Date?

        init(window: TimeInterval) {
            self.window = window
        }

        /// The seconds without progress once that reaches `window`, else nil.
        mutating func observe(_ signals: SettleSignals?, at now: Date) -> TimeInterval? {
            guard let signals else { return nil }
            if let last, lastProgress != nil, !Self.progressed(from: last, to: signals) {
                // No progress: keep the time it was last made.
            } else {
                lastProgress = now
            }
            last = signals
            guard signals.dataMigrationDone == false, let lastProgress else { return nil }
            let quiet = now.timeIntervalSince(lastProgress)
            return quiet >= window ? quiet : nil
        }

        static func progressed(from earlier: SettleSignals, to later: SettleSignals) -> Bool {
            if earlier.stagedSystemApps != later.stagedSystemApps || earlier.installdPID != later.installdPID
                || earlier.dataMigrationDone != later.dataMigrationDone || earlier.appCount != later.appCount
            {
                return true
            }
            if Set(later.appCounts.compactMap(\.self)).count > 1 {
                return true
            }
            if (later.installdCPUDelta ?? 0) >= installdBusyCPUSeconds {
                return true
            }
            if let before = earlier.installdCPUSeconds, let after = later.installdCPUSeconds,
               after - before >= installdBusyCPUSeconds
            {
                return true
            }
            return false
        }
    }

    // MARK: Stall capture

    /// A launchd job that spindumps every process for `stallSpindumpSeconds`.
    static let stallSpindumpLabel = "com.vphone.settle-stall.spindump"
    static let stallSpindumpJobPath = "/private/var/tmp/com.vphone.settle-stall.spindump.plist"
    static let stallSpindumpReportPath = "/private/var/tmp/com.vphone.settle-stall.spindump.txt"
    static let stallSpindumpSeconds = 5
    /// At most this many lines of each process from the report.
    static let stallSpindumpLinesPerProcess = 250

    /// The first-boot processes a stall capture reports: installd, which
    /// expands the staged system apps, and DataMigrator's XPC service
    /// (`com.apple.datamigrator`; the kernel cuts its name to `com.apple.datami`).
    static func isStallProcess(name: String, executable: String) -> Bool {
        executable.hasSuffix("/installd") || name == "installd"
            || executable.hasSuffix("/com.apple.datamigrator") || name.hasPrefix("com.apple.datami")
    }

    /// Best effort, within `timeouts.stallCapture`: what installd and
    /// DataMigrator are doing, into the log, before the reboot ends them.
    /// Each part that fails says so and the capture goes on.
    private func captureStall() {
        let end = deadline(timeouts.stallCapture)
        log("  capturing the stall:")
        do {
            let rows = try call("processes.list", [:], deadline: end)["processes"] as? [[String: Any]] ?? []
            let picked = rows.filter {
                Self.isStallProcess(name: $0["name"] as? String ?? "", executable: $0["executable"] as? String ?? "")
            }
            if picked.isEmpty {
                log("    neither installd nor DataMigrator is running")
            }
            for row in picked {
                let cpu = Self.number(row["cpu_seconds"]).map { String(format: "%.2f s CPU", $0) } ?? "CPU ?"
                let started = Self.number(row["start_time"])
                    .map { "started \(Int(clock.now().timeIntervalSince1970 - $0)) s ago" } ?? "start ?"
                log("    \(row["executable"] as? String ?? row["name"] as? String ?? "?") pid \(row["pid"] ?? "?"): \(cpu), \(started)")
            }
        } catch {
            log("    processes.list: \(error)")
        }
        do {
            let text = try call("services.print", ["label": "com.apple.mobile.installd"], deadline: end)["description"] as? String ?? ""
            log("    installd in launchd: \(Self.launchdSummary(text))")
        } catch {
            log("    services.print com.apple.mobile.installd: \(error)")
        }
        do {
            let report = try stallSpindump(deadline: end)
            let excerpt = Self.spindumpExcerpt(report, maximumLines: Self.stallSpindumpLinesPerProcess) {
                Self.isStallProcess(name: $0, executable: "")
            }
            log(excerpt.isEmpty
                ? "    spindump (\(report.utf8.count) bytes) has neither installd nor DataMigrator"
                : "    spindump, \(Self.stallSpindumpSeconds) s:")
            for line in excerpt {
                log("    | \(line)")
            }
        } catch {
            log("    spindump: \(error)")
        }
    }

    /// The few lines of a `launchctl print` that say whether a job is stuck:
    /// `state = running; active count = 2; runs = 1; …`.
    static func launchdSummary(_ description: String) -> String {
        let keys = ["state", "active count", "runs", "pid", "immediate reason", "last exit code"]
        var found: [String: String] = [:]
        for line in description.split(separator: "\n") {
            // The job's own keys are one tab deep; nested blocks are deeper.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, keys.contains(parts[0]), found[parts[0]] == nil else { continue }
            found[parts[0]] = parts[1]
        }
        let summary = keys.compactMap { key in found[key].map { "\(key) = \($0)" } }
        return summary.isEmpty ? "no record" : summary.joined(separator: "; ")
    }

    /// The sections of a spindump report whose `Process:` line names a
    /// process `matches` accepts, each without its `Binary Images` list and
    /// cut to `maximumLines`.
    static func spindumpExcerpt(_ report: String, maximumLines: Int, matches: (String) -> Bool) -> [String] {
        var lines: [String] = []
        var taken = 0
        var inSection = false
        var inImages = false
        for raw in report.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Process:") {
                // `Process:          installd [312]`
                let name = line.dropFirst("Process:".count).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " [").first ?? ""
                inSection = matches(name)
                inImages = false
                taken = 0
            } else if line.hasPrefix("Binary Images:") {
                inImages = true
            }
            guard inSection, !inImages else { continue }
            if taken == maximumLines {
                lines.append("… (cut at \(maximumLines) lines)")
            }
            if taken < maximumLines {
                lines.append(line)
            }
            taken += 1
        }
        return lines
    }

    /// The guest spindumps itself: vphoned cannot run a program, so a launchd
    /// job does, and the report is read back. The job and the report are
    /// removed afterwards, whatever happened.
    private func stallSpindump(deadline end: Date) throws -> String {
        let job: [String: Any] = [
            "Label": Self.stallSpindumpLabel,
            "ProgramArguments": [
                "/usr/sbin/spindump", "-notarget", "\(Self.stallSpindumpSeconds)", "10",
                "-file", Self.stallSpindumpReportPath,
            ],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        defer {
            _ = try? machine.call("services.unload", params: ["paths": [Self.stallSpindumpJobPath], "force": true], timeout: 10)
            _ = try? machine.call("files.remove", params: ["path": Self.stallSpindumpJobPath], timeout: 10)
            _ = try? machine.call("files.remove", params: ["path": Self.stallSpindumpReportPath], timeout: 10)
        }
        _ = try? machine.call("files.remove", params: ["path": Self.stallSpindumpReportPath], timeout: 10)
        _ = try call("files.write", ["path": Self.stallSpindumpJobPath, "content": String(decoding: data, as: UTF8.self)], deadline: end)
        _ = try call("services.load", ["paths": [Self.stallSpindumpJobPath]], deadline: end)
        clock.sleep(TimeInterval(Self.stallSpindumpSeconds))
        while true {
            let status = try call("services.status", ["label": Self.stallSpindumpLabel], deadline: end)
            if status["running"] as? Bool != true {
                break
            }
            guard clock.now().addingTimeInterval(timeouts.retryInterval) < end else {
                throw StepError("did not finish within \(Int(timeouts.stallCapture)) s")
            }
            clock.sleep(timeouts.retryInterval)
        }
        let read = try call("files.read", ["path": Self.stallSpindumpReportPath, "limit": 24 << 20], deadline: end, timeout: 60)
        guard let content = read["content"] as? String else {
            throw StepError("no report at \(Self.stallSpindumpReportPath)")
        }
        return content
    }

    static let migrationReason = "data migration has not finished"

    /// One progress line of the settle step.
    static func settleProgress(_ reasons: [String], elapsed: Int) -> String {
        let others = reasons.filter { $0 != migrationReason }
        guard others.count < reasons.count else {
            return "  waiting for first-boot work (\(elapsed) s): \(reasons.joined(separator: "; "))"
        }
        return "  waiting for the guest's first-boot data migration (\(elapsed) s)"
            + (others.isEmpty ? "" : "; also \(others.joined(separator: "; "))")
    }

    /// c. `apps.remove_system` backs each container up, unregisters it and
    /// removes it, then resprings once.
    private func removeApps() throws {
        guard !plan.removedApps.isEmpty else {
            log("  nothing to remove")
            return
        }
        let params: [String: Any] = ["bundle_ids": plan.removedApps, "force": true]
        var rows: [[String: Any]]
        do {
            let result = try call("apps.remove_system", params, deadline: deadline(timeouts.removeApps), timeout: 240)
            rows = result["results"] as? [[String: Any]] ?? []
        } catch let error as VPhoneGuestCallError where error.detail?["results"] != nil {
            // `remove_incomplete`: the same results, with at least one failed.
            rows = error.detail?["results"] as? [[String: Any]] ?? []
        }
        var results = rows.compactMap { row -> VPhoneTemplateSetupAppResult? in
            guard let id = row["bundle_id"] as? String else { return nil }
            return VPhoneTemplateSetupAppResult(
                bundleID: id,
                status: row["status"] as? String ?? "failed",
                error: row["error"] as? String,
                unregisterAttempts: max(1, Self.number(row["unregister_attempts"]).flatMap { Int(exactly: $0.rounded()) } ?? 1),
            )
        }
        for id in plan.removedApps where !results.contains(where: { $0.bundleID == id }) {
            results.append(VPhoneTemplateSetupAppResult(bundleID: id, status: "failed", error: "vphoned returned no result for it"))
        }
        outcome.apps = results
        let refused = results.filter { !$0.isGone }
        log("  \(results.count - refused.count) of \(results.count) apps removed or absent")
        // Each app LaunchServices still listed after the first unregister
        // call: the build log is where the race with first-boot
        // registration can be counted.
        for app in results.sorted(by: { $0.bundleID < $1.bundleID }) where app.unregisterAttempts > 1 {
            log("  \(app.bundleID): unregistered after \(app.unregisterAttempts) attempts")
        }
        guard !refused.isEmpty else { return }
        let lines = refused.map { "\($0.bundleID): \($0.error ?? $0.status)" }
        if plan.requiresEveryApp {
            throw StepError("vphoned did not remove \(lines.joined(separator: "; "))")
        }
        for line in lines {
            outcome.warnings.append("not removed: \(line)")
            log("  warning: not removed: \(line)")
        }
    }

    /// d. `services.profile.apply`; e. the trimmed profile includes the
    /// sign-in follow-up group, which turns off followupd and appleidsetupd.
    private func applyServiceProfile() throws {
        let end = deadline(timeouts.serviceProfile)
        if plan.serviceProfile == "none" {
            // Undo a profile only when one is recorded; a fresh guest has none.
            let state = try call("services.profile", [:], deadline: end)
            if state["profile"] as? String ?? "none" != "none" {
                try requireApplied(applyProfile(["profile": "none", "force": true], deadline: end))
            }
            outcome.serviceProfile = "none"
            outcome.serviceGroups = []
            log("  service profile none")
            return
        }
        let applied = try applyProfile(
            ["profile": plan.serviceProfile, "groups": plan.serviceGroups, "force": true],
            deadline: end,
        )
        try requireApplied(applied)
        guard applied["profile"] as? String == plan.serviceProfile else {
            throw StepError("services.profile.apply answered profile \(applied["profile"] ?? "nil"), not \(plan.serviceProfile)")
        }

        let state = try call("services.profile", [:], deadline: end)
        let record = state["record"] as? [String: Any]
        let groups = Set(strings(record?["groups"]))
        let missing = ([Self.signInFollowUpGroup] + plan.serviceGroups).filter { !groups.contains($0) }
        guard missing.isEmpty else {
            throw StepError("the applied profile lacks the group(s) \(missing.joined(separator: ", "))")
        }
        let disabled = Set(strings(state["disabled"]))
        let notOff = Self.signInFollowUpLabels.filter { !disabled.contains($0) }
        guard notOff.isEmpty else {
            throw StepError("the sign-in follow-up services are not disabled: \(notOff.joined(separator: ", "))")
        }
        outcome.serviceProfile = plan.serviceProfile
        outcome.serviceGroups = plan.serviceGroups
        outcome.servicesOwned = applied["owned"] as? Int ?? disabled.count
        log("  profile \(plan.serviceProfile)\(plan.serviceGroups.isEmpty ? "" : " +\(plan.serviceGroups.joined(separator: ","))"): "
            + "\(outcome.servicesOwned) services owned, \(strings(applied["disabled"]).count) disabled now")
    }

    /// A strict setup boot stops here, before the reboot, when what was done
    /// falls short of the plan.
    private func requirePlan() throws {
        guard plan.requiresEveryApp else { return }
        let deviations = outcome.deviations(from: plan)
        guard deviations.isEmpty else {
            throw StepError("strict: the setup boot fell short of the requested slimming: \(deviations.joined(separator: "; "))")
        }
    }

    /// `services.profile.apply`, applied again 5 and 15 s later while launchd
    /// refuses some of its changes this early in the boot and takes them a
    /// moment later: "disable requires root (launchd status 1)" for
    /// com.apple.seserviced on iOS 26.5 and com.apple.fitnesscoachingd on
    /// iPadOS 27.0.1 (2026-10-23). vphoned records only what an apply changed,
    /// so another apply redoes just the rest; what each one disabled is added up.
    private func applyProfile(_ params: [String: Any], deadline end: Date) throws -> [String: Any] {
        var applied = try call("services.profile.apply", params, deadline: end)
        var disabled = strings(applied["disabled"])
        for wait in [5.0, 15.0] where Self.isEarlyBootRefusal(applied) && clock.now().addingTimeInterval(wait) < end {
            log("  retrying the service profile in \(Int(wait)) s: \(Self.failures(applied).joined(separator: "; "))")
            clock.sleep(wait)
            applied = try call("services.profile.apply", params, deadline: end)
            disabled += strings(applied["disabled"])
        }
        applied["disabled"] = disabled
        return applied
    }

    /// Whether every change an apply could not make was launchd refusing it,
    /// as icli reports its EPERM and EACCES. Anything else fails at once.
    static func isEarlyBootRefusal(_ result: [String: Any]) -> Bool {
        let failed = result["failed"] as? [[String: Any]] ?? []
        return !failed.isEmpty && failed.allSatisfy { ($0["error"] as? String ?? "").contains("requires root (launchd status") }
    }

    private func requireApplied(_ result: [String: Any]) throws {
        let failed = Self.failures(result)
        guard failed.isEmpty else {
            throw StepError("services.profile.apply could not change \(failed.joined(separator: "; "))")
        }
    }

    /// The services an apply could not change, as `label (action: error)`.
    static func failures(_ result: [String: Any]) -> [String] {
        (result["failed"] as? [[String: Any]] ?? []).map { row in
            "\(row["label"] as? String ?? "?") (\(row["action"] as? String ?? "?"): \(row["error"] as? String ?? "?"))"
        }
    }

    /// f. Reboots the guest and waits for vphoned of the next boot: launchd's
    /// start time (pid 1) tells the boots apart.
    private func reboot() throws {
        try restartGuest(deadline: deadline(timeouts.reboot))
    }

    private func restartGuest(deadline end: Date) throws {
        let before = try bootMarker(deadline: end)
        do {
            _ = try machine.call("system.reboot", params: ["force": true], timeout: 30)
        } catch let error as VPhoneGuestCallError where error.kind == .transport {
            // The guest can go down before it answers.
        }

        // A guest that powers off instead of restarting stops the virtual
        // machine, and vphone-vm exits with status 0 (guestDidStop). Start it
        // again once for the second boot; any other exit still fails the step.
        var relaunched = false
        while true {
            if !relaunched, machine.exitedCleanly() {
                relaunched = true
                try machine.start()
            }
            try checkMachine()
            if machine.ping(), let after = try? machine.call("processes.list", params: [:], timeout: timeouts.rebootPoll),
               let marker = Self.bootMarker(after), marker != before
            {
                return
            }
            guard clock.now() < end else {
                throw StepError("the guest did not come back from the reboot within \(Int(timeouts.reboot)) s")
            }
            clock.sleep(timeouts.retryInterval)
        }
    }

    private func bootMarker(deadline: Date) throws -> Double {
        let list = try call("processes.list", [:], deadline: deadline)
        guard let marker = Self.bootMarker(list) else {
            throw StepError("processes.list does not list launchd (pid 1) with a start time")
        }
        return marker
    }

    static func bootMarker(_ list: [String: Any]) -> Double? {
        let rows = list["processes"] as? [[String: Any]] ?? []
        let launchd = rows.first { number($0["pid"]) == 1 }
        return number(launchd?["start_time"])
    }

    /// A number from JSON (NSNumber) or from a dictionary built in Swift.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Int: Double(value)
        case let value as Double: value
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    /// f. After the reboot: no orig-fs snapshot, Setup done, the profile
    /// recorded and none of its services running, the removed apps absent,
    /// vphoned answering. Checked again until the deadline, since services
    /// started by the boot can still be winding down.
    private func verify() throws {
        let end = deadline(timeouts.verify)
        while true {
            let problems = try verificationProblems(deadline: end)
            if problems.isEmpty {
                outcome.verified = true
                log("  verified")
                return
            }
            guard clock.now().addingTimeInterval(timeouts.retryInterval) < end else {
                throw StepError(problems.joined(separator: "; "))
            }
            log("  not yet: \(problems.joined(separator: "; "))")
            clock.sleep(timeouts.retryInterval)
        }
    }

    private func verificationProblems(deadline end: Date) throws -> [String] {
        var problems: [String] = []
        let snapshots = try strings(call("apfs.snapshots", [:], deadline: end)["snapshots"])
            .filter { $0.hasPrefix(Self.snapshotPrefix) }
        if !snapshots.isEmpty {
            problems.append("snapshots left: \(snapshots.joined(separator: ", "))")
        }
        let status = try call("setup.status", [:], deadline: end)
        if status["setup_done"] as? Bool != true {
            problems.append("Setup Assistant is not done")
        }
        let profile = try call("services.profile", [:], deadline: end)
        let recorded = profile["profile"] as? String ?? "none"
        if recorded != plan.serviceProfile {
            problems.append("service profile is \(recorded), not \(plan.serviceProfile)")
        }
        let running = strings(profile["running"])
        if !running.isEmpty {
            problems.append("\(running.count) profile service(s) still running: \(running.prefix(5).joined(separator: ", "))")
        }
        let removed = Set(outcome.removedApps)
        if !removed.isEmpty {
            let listed = try (call("apps.list", [:], deadline: end)["apps"] as? [[String: Any]] ?? [])
                .compactMap { $0["bundle_id"] as? String }
            let back = listed.filter { removed.contains($0) }
            if !back.isEmpty {
                problems.append("removed apps are installed again: \(back.sorted().joined(separator: ", "))")
            }
        }
        if !machine.ping() {
            problems.append("vphoned does not answer a ping")
        }
        return problems
    }

    /// The crash reports this machine's boots left go before it is frozen:
    /// every clone would otherwise list them as its own. The first is always
    /// a `panic-full` report of `initproc failed to start … libSystem.B.dylib
    /// … (no dyld cache)`: the restore reboots into the installed system
    /// before `cfw install` has put the dyld cache on the System volume, the
    /// kernel records that panic, and iOS writes the report at the next
    /// boot, which is the setup boot. Nothing in the template panicked.
    /// Best effort: a report left behind is a warning.
    private func clearCrashReports() {
        guard plan.clearsCrashReports else { return }
        let end = deadline(timeouts.crashReports)
        do {
            let reports = try (call("logs.crashes", [:], deadline: end)["crashes"] as? [[String: Any]] ?? [])
                .compactMap { $0["path"] as? String }
                .filter(Self.isCrashReport)
            var left: [String] = []
            for path in reports {
                do {
                    _ = try call("files.remove", ["path": path], deadline: end)
                    outcome.clearedCrashReports.append((path as NSString).lastPathComponent)
                } catch {
                    left.append("\((path as NSString).lastPathComponent) (\(error))")
                }
            }
            if !outcome.clearedCrashReports.isEmpty {
                log("  cleared \(Self.summarizeCrashReports(outcome.clearedCrashReports))")
            }
            if !left.isEmpty {
                let warning = "could not delete \(left.count) crash report(s): \(left.prefix(3).joined(separator: ", "))"
                outcome.warnings.append(warning)
                log("  warning: \(warning)")
            }
        } catch {
            outcome.warnings.append("could not list the crash reports: \(error)")
            log("  warning: could not list the crash reports: \(error)")
        }
    }

    /// Only a report file in a CrashReporter folder: `logs.crashes` lists
    /// nothing else; the check keeps `files.remove` off any other path it
    /// might ever return.
    public static func isCrashReport(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("/../") && path.contains("/Logs/CrashReporter/")
            && !path.hasSuffix("/")
    }

    /// `14 crash report(s): duetexpertd ×12, panic-full ×1, …`, by process.
    public static func summarizeCrashReports(_ names: [String]) -> String {
        var counts: [String: Int] = [:]
        for name in names {
            let stem = (name as NSString).deletingPathExtension
            let process = stem.range(of: #"-\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
                .map { String(stem[..<$0.lowerBound]) } ?? stem
            counts[process, default: 0] += 1
        }
        let parts = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key) ×\($0.value)" }
        return "\(names.count) crash report(s): \(parts.joined(separator: ", "))"
    }

    /// `vphone-vm` pinned the device name to this machine's name on connect.
    /// A clone would carry that pin until its own VM pins its name, so the
    /// pin goes; the guest's own name (`iPhone`) shows in between.
    private func clearDeviceName() {
        guard plan.clearsDeviceName else { return }
        do {
            _ = try call("device.name.set", [:], deadline: deadline(timeouts.deviceName))
            outcome.deviceNameCleared = true
        } catch {
            outcome.warnings.append("could not clear the pinned device name: \(error)")
            log("  warning: could not clear the pinned device name: \(error)")
        }
    }

    // MARK: Calls

    private struct StepError: Error, CustomStringConvertible {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var description: String {
            message
        }
    }

    private func deadline(_ seconds: TimeInterval) -> Date {
        clock.now().addingTimeInterval(seconds)
    }

    private func checkMachine() throws {
        if let reason = machine.failure() {
            throw StepError(reason)
        }
    }

    /// One method, repeated while it fails in a way worth retrying and the
    /// deadline allows. Any other refusal is thrown as it came.
    private func call(
        _ method: String,
        _ params: [String: Any],
        deadline: Date,
        timeout: TimeInterval = 60,
        retryingRefusals: Bool = false,
        retryLine: ((VPhoneGuestCallError) -> String?)? = nil,
    ) throws -> [String: Any] {
        var attempts = 0
        while true {
            try checkMachine()
            do {
                return try machine.call(method, params: params, timeout: timeout)
            } catch let error as VPhoneGuestCallError where error.isRetryable || retryingRefusals {
                attempts += 1
                guard clock.now().addingTimeInterval(timeouts.retryInterval) < deadline else {
                    throw StepError("\(method): \(error.message) (\(attempts) attempt(s))")
                }
                if let line = retryLine.map({ $0(error) }) ?? "  \(method): \(error.message); retrying" {
                    log(line)
                }
                clock.sleep(timeouts.retryInterval)
            } catch let error as VPhoneGuestCallError {
                // Kept whole for a caller that reads its detail.
                if error.detail?["results"] != nil {
                    throw error
                }
                throw StepError("\(method): \(error.message)\(error.code.map { " (\($0))" } ?? "")")
            }
        }
    }

    private func strings(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }
}

// MARK: - Recording

public extension VPhoneMachineTemplates {
    /// Records a finished setup boot in the template record of the machine
    /// at `url`. Only a complete outcome is recorded: a failed setup boot
    /// leaves the record as it was, so the build is never frozen from it.
    static func recordSetupBoot(_ outcome: VPhoneTemplateSetupOutcome, inBundle url: URL) throws {
        guard outcome.isComplete else {
            throw VPhoneMachineTemplateError.failed(path: url.path, reason: "the setup boot did not finish, so nothing was recorded")
        }
        try recordSteps(inBundle: url) { steps in
            steps = outcome.applying(to: steps)
        }
    }
}
