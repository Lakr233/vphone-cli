import Foundation
import IcliKit
import IcliSystem
import VphonedNative

// MARK: - First-Boot Settle

/// `setup.settle`: waits, read-only, until the guest's first-boot work has
/// settled (`GuestFirstBootSettle` has the conditions), or until the timeout.
/// A timeout is an answer, not an error: `settled: false` with the last
/// signals and the conditions still unmet.
extension GuestAPI {
    static func executeFirstBoot(_ m: FirstBootMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .setupSettle:
            try waitForFirstBootSettle(params)
        }
    }

    /// The host gives one answer at most 120 s (`VPhoneHTTPTransaction`'s
    /// read timeout), so one call waits at most 110 s; a caller that needs
    /// longer calls again.
    static let settleMaximumTimeout = 110.0

    private static func waitForFirstBootSettle(_ params: [String: Any]) throws -> [String: Any] {
        for key in ["timeout_ms", "poll_ms", "stable_polls"] where params[key] != nil && !(params[key] is NSNumber) {
            throw GuestAPIError.invalidRequest("\(key) must be a number")
        }
        let timeout = min(max(number(params, "timeout_ms", default: 90000) / 1000, 0), settleMaximumTimeout)
        let poll = min(max(number(params, "poll_ms", default: 5000), 1000), 30000) / 1000
        let stablePolls = Int(min(max(number(params, "stable_polls", default: 3), 2), 20))

        let start = Date()
        var samples: [GuestFirstBootSettle.Sample] = []
        var verdict: GuestFirstBootSettle.Verdict
        while true {
            samples.append(firstBootSample(time: Date().timeIntervalSince(start)))
            verdict = GuestFirstBootSettle.evaluate(samples, stablePolls: stablePolls)
            if verdict.settled || Date().timeIntervalSince(start) + poll > timeout {
                break
            }
            Thread.sleep(forTimeInterval: poll)
        }

        let latest = samples[samples.count - 1]
        return [
            "settled": verdict.settled,
            "elapsed_ms": (Date().timeIntervalSince(start) * 1000).rounded(),
            "polls": samples.count,
            "timeout_ms": timeout * 1000,
            "poll_ms": poll * 1000,
            "stable_polls": stablePolls,
            "reasons": verdict.reasons,
            "signals": [
                "staged_system_apps": latest.stagedSystemApps.map { $0 as Any } ?? NSNull(),
                "app_count": latest.appCount.map { $0 as Any } ?? NSNull(),
                "app_counts": samples.suffix(stablePolls).map { $0.appCount.map { $0 as Any } ?? NSNull() },
                "installd_pid": latest.installdPID.map { $0 as Any } ?? NSNull(),
                "installd_cpu_seconds": latest.installdCPUSeconds.map { $0 as Any } ?? NSNull(),
                "installd_cpu_delta": verdict.installdCPUDelta.map { $0 as Any } ?? NSNull(),
                "setup_pending": setupAssistantPending(),
                "data_migration_done": latest.dataMigrationDone.map { $0 as Any } ?? NSNull(),
            ] as [String: Any],
        ]
    }

    private static func firstBootSample(time: Double) -> GuestFirstBootSettle.Sample {
        var sample = GuestFirstBootSettle.Sample(time: time)
        sample.dataMigrationDone = dataMigrationDone()
        let staged = GuestFirstBootSettle.stagedSystemAppsPath
        if !FileManager.default.fileExists(atPath: staged) {
            sample.stagedSystemApps = 0
        } else if let entries = try? FileManager.default.contentsOfDirectory(atPath: staged) {
            sample.stagedSystemApps = entries.filter { !$0.hasPrefix(".") }.count
        }
        if let apps = try? listedApps() {
            sample.appCount = apps.count
        }
        let processes = (try? listProcesses(filter: "installd"))?["processes"] as? [[String: Any]] ?? []
        if let pid = processes.first(where: { ($0["executable"] as? String)?.hasSuffix("/installd") == true })?["pid"] as? Int {
            var usage = VPProcessUsage()
            if vp_process_usage(Int32(pid), &usage), usage.has_task_info {
                sample.installdPID = pid
                sample.installdCPUSeconds = usage.cpu_seconds
            }
        }
        return sample
    }
}
