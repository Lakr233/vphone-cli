import Foundation

// MARK: - Harness

/// Checks the guest-independent parts of vphoned on the Mac: the service
/// profile lists and bookkeeping, the first-boot settle verdict (data
/// migration included), the device name rule and the pointer scroll
/// parameters. `run-logic-tests.sh` builds
/// this file with those sources.
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL line \(line): \(message())")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", line: Int = #line) {
    expect(actual == expected, "\(message) expected \(expected), got \(actual)", line: line)
}

@main
enum LogicTests {
    static func main() {
        profileCatalog()
        profileCatalog26()
        profileSelection()
        neverDisableEnforcement()
        reconciliation()
        noneRestoresOnlyRecorded()
        recordRoundTrip()
        settleVerdicts()
        dataMigrationRecord()
        deviceNameRule()
        pointerScroll()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Service Profile

    static let labelPattern = "^[A-Za-z0-9][A-Za-z0-9._:\\[\\]-]{0,200}$"

    static func profileCatalog() {
        let groups = GuestServiceProfile.groups27
        expectEqual(GuestServiceProfile.base27.count, 134, "appendix A less siriactionsd, passd and financed")
        expectEqual(Set(GuestServiceProfile.base27).count, 134, "appendix A has no duplicates")
        let all = groups.flatMap(\.labels)
        expectEqual(Set(all).count, all.count, "no label is in two groups")
        for label in all + GuestServiceProfile.neverDisable {
            expect(label.range(of: labelPattern, options: .regularExpression) != nil, "\(label) is a valid label")
        }
        expectEqual(groups.map(\.name), ["base", "app_store", "signin_followup", "accounts"])
        expectEqual(groups.filter(\.byDefault).map(\.name), ["base", "app_store", "signin_followup"])
        expect(GuestServiceProfile.base27.contains("com.apple.appstorecomponentsd"), "appstorecomponentsd is in base")
        expect(GuestServiceProfile.groups(iosMajor: 25) == nil, "no list for iOS 25")
        expect(GuestServiceProfile.groups(iosMajor: 28) == nil, "no list for iOS 28")
        expect(GuestServiceProfile.groups(iosMajor: 26) != nil, "a list for iOS 26")
        expect(GuestServiceProfile.groups(iosMajor: 27) != nil, "a list for iOS 27")
        expectEqual(GuestServiceProfile.supportedMajors, [26, 27])
    }

    static func profileCatalog26() {
        let base26 = GuestServiceProfile.base26
        expectEqual(base26.count, 128, "134 minus six 26.6.2 does not load")
        expectEqual(Set(base26).count, base26.count, "no duplicates")
        expect(Set(base26).isSubset(of: GuestServiceProfile.base27), "26 adds no label of its own")
        expect(GuestServiceProfile.notLoadedOn26.isSubset(of: GuestServiceProfile.base27), "only 27 labels are left out")
        expect(Set(base26).isDisjoint(with: GuestServiceProfile.notLoadedOn26), "what 26 does not load is left out")
        for label in ["com.apple.cloudtelemetryd", "com.apple.hybridsearchd", "com.apple.safetyalertsd"] {
            expect(!base26.contains(label), "\(label) is not in the 26 list")
        }
        let groups = GuestServiceProfile.groups26
        expectEqual(groups.map(\.name), GuestServiceProfile.groups27.map(\.name), "same groups as 27")
        expectEqual(groups.filter(\.byDefault).map(\.name), ["base", "app_store", "signin_followup"])
        expectEqual(groups.first?.labels, base26, "base is the 26 list")
        expectEqual(
            groups.dropFirst().map(\.labels), GuestServiceProfile.groups27.dropFirst().map(\.labels),
            "store, follow-up and account labels are the same on 26",
        )
        let all = groups.flatMap(\.labels)
        expectEqual(Set(all).count, all.count, "no label is in two 26 groups")
    }

    static func profileSelection() {
        let trimmed = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 27)
        expectEqual(trimmed?.labels.count, 138, "default trimmed = 134 + 2 store + 2 follow-up")
        expectEqual(trimmed?.groups, ["base", "app_store", "signin_followup"])
        expect(trimmed?.labels.contains("com.apple.followupd") == true, "followupd is in trimmed")
        expect(trimmed?.labels.contains("com.apple.akd") == false, "akd is not in trimmed by default")
        expect(trimmed?.labels.contains("com.apple.siriactionsd") == false, "siriactionsd serves App Intents controls")
        expect(GuestServiceProfile.neverDisable.contains("com.apple.siriactionsd"), "siriactionsd is never disabled")
        expect(trimmed?.labels.contains("com.apple.passd") == false && trimmed?.labels.contains("com.apple.financed") == false, "Wallet's daemons stay")
        expectEqual(trimmed?.labels, trimmed?.labels.sorted(), "labels sorted")

        let accounts = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 27, extraGroups: ["accounts"])
        expectEqual(accounts?.labels.count, 141, "accounts adds three")
        expect(accounts?.labels.contains("com.apple.amsaccountsd") == true, "amsaccountsd with accounts")

        let allowed = try? GuestServiceProfile.select(
            profile: "trimmed", iosMajor: 27, allow: ["com.apple.weatherd", "com.example.not-listed"],
        )
        expectEqual(allowed?.labels.count, 137, "allow removes one")
        expectEqual(allowed?.allowed, ["com.apple.weatherd"], "only catalog labels are reported as allowed")
        expect(allowed?.labels.contains("com.apple.weatherd") == false, "weatherd kept")

        let trimmed26 = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 26)
        expectEqual(trimmed26?.labels.count, 132, "26 trimmed = 128 + 2 store + 2 follow-up")
        expectEqual(trimmed26?.groups, ["base", "app_store", "signin_followup"])
        expect(trimmed26?.refused.isEmpty == true, "the 26 list names nothing never disabled")
        expectEqual(
            (try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 26, extraGroups: ["accounts"]))?.labels.count,
            135, "accounts adds three on 26",
        )

        expectEqual(try? GuestServiceProfile.select(profile: "none", iosMajor: 25), GuestServiceProfile.Selection())
        expectThrows(.unsupported(iosMajor: 25)) { try GuestServiceProfile.select(profile: "trimmed", iosMajor: 25) }
        expectEqual(
            GuestServiceProfile.Failure.unsupported(iosMajor: 25).description,
            "No trimmed service list for iOS 25; lists exist for iOS 26, 27",
        )
        expectThrows(.unknownGroup("bogus")) {
            try GuestServiceProfile.select(profile: "trimmed", iosMajor: 27, extraGroups: ["bogus"])
        }
        expectThrows(.unknownProfile("lean")) { try GuestServiceProfile.select(profile: "lean", iosMajor: 27) }
    }

    static func expectThrows(_ expected: GuestServiceProfile.Failure, line: Int = #line, _ body: () throws -> Any) {
        do {
            _ = try body()
            expect(false, "expected \(expected)", line: line)
        } catch let failure as GuestServiceProfile.Failure {
            expectEqual(failure, expected, line: line)
        } catch {
            expect(false, "unexpected \(error)", line: line)
        }
    }

    static func neverDisableEnforcement() {
        for group in GuestServiceProfile.groups27 + GuestServiceProfile.groups26 {
            let overlap = Set(group.labels).intersection(GuestServiceProfile.neverDisable)
            expect(overlap.isEmpty, "\(group.name) names never-disabled \(overlap.sorted())")
        }
        for trap in [
            "com.apple.sleepd", "com.apple.CommCenter", "com.apple.CommCenterMobileHelper",
            "com.apple.CommCenterRootHelper", "com.apple.cloudd", "com.apple.nanoregistryd",
            "com.apple.nanoregistrylaunchd", "com.apple.mobileassetd", "com.apple.storekitd",
            "com.apple.cfprefsd.xpc.daemon", "com.apple.SpringBoard", "com.apple.backboardd",
            "com.apple.mobile.installd", "com.apple.lsd", "com.apple.mobileactivationd",
            "com.apple.locationd", "com.apple.bluetoothd", "com.vphone.vphoned",
        ] {
            expect(GuestServiceProfile.neverDisable.contains(trap), "\(trap) is never disabled")
        }
        // Even a target that names them, as a future list might, leaves them alone.
        let change = GuestServiceProfile.reconcile(
            target: ["com.apple.sleepd", "com.apple.tipsd"], owned: [], overrides: [:],
        )
        expectEqual(change.disable, ["com.apple.tipsd"])
        expectEqual(change.skipped, [GuestServiceProfile.Skip(label: "com.apple.sleepd", reason: "never disabled")])
    }

    static func reconciliation() {
        let overrides = [
            "com.apple.a": true, // disabled by the profile earlier
            "com.apple.b": true, // disabled by somebody else (the OTA block)
            "com.apple.d": true, // owned, no longer selected
            "com.apple.e": false, // owned, re-enabled by the user
        ]
        let change = GuestServiceProfile.reconcile(
            target: ["com.apple.a", "com.apple.b", "com.apple.c"],
            owned: ["com.apple.a", "com.apple.d", "com.apple.e"],
            overrides: overrides,
        )
        expectEqual(change.keep, ["com.apple.a"])
        expectEqual(change.disable, ["com.apple.c"])
        expectEqual(change.enable, ["com.apple.d"])
        expectEqual(change.skipped, [
            GuestServiceProfile.Skip(label: "com.apple.b", reason: GuestServiceProfile.disabledElsewhere),
            GuestServiceProfile.Skip(label: "com.apple.e", reason: GuestServiceProfile.enabledElsewhere),
        ])
        expectEqual(
            GuestServiceProfile.owned(after: change, failedDisable: [], failedEnable: []),
            ["com.apple.a", "com.apple.c"], "owned after success",
        )
        expectEqual(
            GuestServiceProfile.owned(after: change, failedDisable: ["com.apple.c"], failedEnable: ["com.apple.d"]),
            ["com.apple.a", "com.apple.d"], "a failed disable is not owned; a failed enable stays owned",
        )

        // Applying again once the overrides reflect the first apply changes nothing.
        let after = ["com.apple.a": true, "com.apple.b": true, "com.apple.c": true, "com.apple.e": false]
        let again = GuestServiceProfile.reconcile(
            target: ["com.apple.a", "com.apple.b", "com.apple.c"], owned: ["com.apple.a", "com.apple.c"], overrides: after,
        )
        expect(again.disable.isEmpty && again.enable.isEmpty, "idempotent")
        expectEqual(again.keep, ["com.apple.a", "com.apple.c"])
    }

    static func noneRestoresOnlyRecorded() {
        // The OTA trio was disabled before the profile ran, so it was never owned.
        let ota = ["com.apple.mobile.softwareupdated", "com.apple.OTATaskingAgent", "com.apple.softwareupdateservicesd"]
        guard let trimmed = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 27) else {
            return expect(false, "trimmed selects")
        }
        var overrides = Dictionary(uniqueKeysWithValues: ota.map { ($0, true) })
        overrides["com.apple.user-choice"] = true
        let apply = GuestServiceProfile.reconcile(target: trimmed.labels, owned: [], overrides: overrides)
        expectEqual(apply.disable.count, 135, "138 minus the three already disabled")
        expectEqual(apply.skipped.map(\.label), ota.sorted())
        let owned = GuestServiceProfile.owned(after: apply, failedDisable: [], failedEnable: [])
        for label in apply.disable {
            overrides[label] = true
        }

        let restore = GuestServiceProfile.reconcile(target: [], owned: owned, overrides: overrides)
        expectEqual(restore.enable, owned, "none enables exactly what the profile owned")
        expect(Set(restore.enable).isDisjoint(with: ota), "the OTA trio stays disabled")
        expect(!restore.enable.contains("com.apple.user-choice"), "a user's override stays")
        expectEqual(GuestServiceProfile.owned(after: restore, failedDisable: [], failedEnable: []), [])
    }

    static func recordRoundTrip() {
        let directory = NSTemporaryDirectory() + "vphoned-logic-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/db/service-profile.plist"
        expect(GuestServiceProfile.readRecord(at: path) == nil, "no record yet")
        let record = GuestServiceProfile.Record(
            profile: "trimmed", listVersion: 1, iosMajor: 27, groups: ["base"], allow: ["com.apple.weatherd"],
            labels: ["com.apple.tipsd"], updated: Date(timeIntervalSince1970: 1_791_331_200),
        )
        do {
            try GuestServiceProfile.writeRecord(record, to: path)
        } catch {
            return expect(false, "write: \(error)")
        }
        expectEqual(GuestServiceProfile.readRecord(at: path), record, "record round-trips")
        expect(GuestServiceProfile.Record(propertyList: ["Profile": "none"]) == nil, "a record needs Labels")
        expectEqual(record.json["updated"] as? String, "2026-10-07T00:00:00Z")
    }

    // MARK: - First-Boot Settle

    typealias Sample = GuestFirstBootSettle.Sample

    static func sample(_ time: Double, staged: Int? = 0, apps: Int? = 248, pid: Int? = 90, cpu: Double? = 1.0) -> Sample {
        Sample(time: time, stagedSystemApps: staged, appCount: apps, installdPID: pid, installdCPUSeconds: cpu)
    }

    static func settleVerdicts() {
        let quiet = [sample(0), sample(5, cpu: 1.05), sample(10, cpu: 1.1)]
        let verdict = GuestFirstBootSettle.evaluate(quiet, stablePolls: 3)
        expect(verdict.settled, "quiet polls settle: \(verdict.reasons)")
        expectEqual(verdict.installdCPUDelta.map { ($0 * 100).rounded() }, 5)

        expect(!GuestFirstBootSettle.evaluate(Array(quiet.prefix(2)), stablePolls: 3).settled, "too few polls")
        expect(GuestFirstBootSettle.evaluate(quiet, stablePolls: 1).settled, "at least two polls even when asked for one")

        let staged = GuestFirstBootSettle.evaluate([sample(0), sample(5), sample(10, staged: 4)], stablePolls: 3)
        expect(!staged.settled && staged.reasons == ["staged_system_apps has 4 entries"], "\(staged.reasons)")

        let emptied = GuestFirstBootSettle.evaluate([sample(0, staged: 2), sample(5), sample(10)], stablePolls: 3)
        expectEqual(emptied.reasons, ["staged_system_apps only just emptied"])

        let unreadable = GuestFirstBootSettle.evaluate([sample(0), sample(5), sample(10, staged: nil)], stablePolls: 3)
        expectEqual(unreadable.reasons, ["staged_system_apps could not be read"])

        let growing = GuestFirstBootSettle.evaluate([sample(0, apps: 250), sample(5, apps: 258), sample(10, apps: 258)], stablePolls: 3)
        expectEqual(growing.reasons, ["app count changed: 250 → 258 → 258"])

        let unknownApps = GuestFirstBootSettle.evaluate([sample(0), sample(5, apps: nil), sample(10)], stablePolls: 3)
        expectEqual(unknownApps.reasons, ["app count unavailable"])

        let busy = GuestFirstBootSettle.evaluate([sample(0), sample(5, cpu: 3.0), sample(10, cpu: 3.1)], stablePolls: 3)
        expectEqual(busy.reasons, ["installd used 2.00 s CPU between polls"])

        // An older busy poll outside the window no longer counts.
        let recovered = GuestFirstBootSettle.evaluate(
            [sample(0), sample(5, cpu: 3.0), sample(10, cpu: 3.05), sample(15, cpu: 3.1)], stablePolls: 2,
        )
        expect(recovered.settled, "window of two: \(recovered.reasons)")

        // installd exiting counts as idle; a new installd counts all of its CPU.
        let exited = [sample(0), sample(5, pid: nil, cpu: nil), sample(10, pid: nil, cpu: nil)]
        expect(GuestFirstBootSettle.evaluate(exited, stablePolls: 3).settled, "installd gone is idle")
        let restarted = GuestFirstBootSettle.evaluate([sample(0), sample(5, pid: nil, cpu: nil), sample(10, pid: 120, cpu: 0.9)], stablePolls: 3)
        expectEqual(restarted.reasons, ["installd used 0.90 s CPU between polls"])
        let restartedIdle = GuestFirstBootSettle.evaluate([sample(0), sample(5, pid: 120, cpu: 0.05), sample(10, pid: 120, cpu: 0.06)], stablePolls: 3)
        expect(restartedIdle.settled, "a new, idle installd: \(restartedIdle.reasons)")

        // Data migration holds the verdict back until the latest poll has it
        // done; an unknown state (no build version) does not.
        func migrating(_ time: Double, _ done: Bool?) -> Sample {
            var polled = sample(time)
            polled.dataMigrationDone = done
            return polled
        }
        let pending = GuestFirstBootSettle.evaluate([migrating(0, false), migrating(5, false), migrating(10, false)], stablePolls: 3)
        expectEqual(pending.reasons, ["data migration has not finished"])
        let finished = GuestFirstBootSettle.evaluate([migrating(0, false), migrating(5, false), migrating(10, true)], stablePolls: 3)
        expect(finished.settled, "migration done in the latest poll: \(finished.reasons)")
        expect(GuestFirstBootSettle.evaluate([migrating(0, nil), migrating(5, nil), migrating(10, nil)], stablePolls: 3).settled, "unknown is not pending")
        let stillStaging = GuestFirstBootSettle.evaluate([migrating(0, false), migrating(5, false), {
            var polled = migrating(10, false)
            polled.stagedSystemApps = 30
            return polled
        }()], stablePolls: 3)
        expectEqual(stillStaging.reasons, ["staged_system_apps has 30 entries", "data migration has not finished"])
    }

    static func dataMigrationRecord() {
        func done(_ build: String?, _ last: String?, _ results: String?, running: Bool = true) -> Bool? {
            GuestFirstBootSettle.dataMigrationDone(
                build: build, lastSystemVersion: last, lastResultsBuild: results, migratorRunning: running,
            )
        }
        // A fresh restore: com.apple.migration is empty until DataMigrator ends.
        expectEqual(done("24A435", nil, nil), false)
        expectEqual(done("24A435", "24A435", "24A435"), true)
        expectEqual(done("24A435", "24A435", nil), true)
        expectEqual(done("24A435", nil, "24A435"), true)
        expectEqual(done("24A435", "24A435", "24A435", running: false), true)
        // The build changed (an update): the old record is not this build's.
        expectEqual(done("24A446", "24A435", "24A435"), false)
        // Nothing recorded and DataMigrator not running: unknown, never waited for.
        expectEqual(done("24A435", nil, nil, running: false), nil)
        expectEqual(done(nil, "24A435", "24A435"), nil)
        expectEqual(done("", nil, nil), nil)
        let migrator = "/System/Library/PrivateFrameworks/DataMigration.framework/XPCServices/com.apple.datamigrator.xpc/com.apple.datamigrator"
        expect(migrator.hasSuffix(GuestFirstBootSettle.dataMigratorSuffix), "the path seen on 27.0")
    }

    // MARK: - Device Name

    static func deviceNameRule() {
        expect(GuestDeviceNameRule.problem("p0-a") == nil, "plain name")
        expect(GuestDeviceNameRule.problem("dhtest 27 测试") == nil, "spaces and CJK")
        expect(GuestDeviceNameRule.problem("Jacky’s iPhone") == nil, "typographic apostrophe")
        expectEqual(GuestDeviceNameRule.problem(""), "name must not be blank")
        expectEqual(GuestDeviceNameRule.problem(" \n\t"), "name must not be blank")
        expectEqual(GuestDeviceNameRule.problem("a\u{7}b"), "name must not contain a control character")
        expectEqual(GuestDeviceNameRule.problem("line\nbreak"), "name must not contain a control character")
        expect(GuestDeviceNameRule.problem(String(repeating: "a", count: 255)) == nil, "255 bytes")
        expectEqual(GuestDeviceNameRule.problem(String(repeating: "a", count: 256)), "name must be at most 255 bytes in UTF-8")
        // 85 three-byte characters are 255 bytes; one more is 258.
        expect(GuestDeviceNameRule.problem(String(repeating: "测", count: 85)) == nil, "255 bytes of CJK")
        expect(GuestDeviceNameRule.problem(String(repeating: "测", count: 86)) != nil, "258 bytes of CJK")
    }

    // MARK: - Pointer Scroll

    static func scrollProblem(_ params: [String: Any]) -> String? {
        do {
            _ = try GuestPointerScroll.scroll(params)
            return nil
        } catch {
            return error.message
        }
    }

    static func pointerScroll() {
        typealias Scroll = GuestPointerScroll.Scroll
        expectEqual(try? GuestPointerScroll.scroll(["phase": "changed", "dx": 1.5, "dy": -20]),
                    Scroll(phase: .changed, dx: 1.5, dy: -20, pointer: nil))
        expectEqual(try? GuestPointerScroll.scroll(["phase": "began"]),
                    Scroll(phase: .began, dx: 0, dy: 0, pointer: nil), "deltas default to 0")
        expectEqual(try? GuestPointerScroll.scroll(["phase": "began", "x": 0, "y": 1]),
                    Scroll(phase: .began, dx: 0, dy: 0, pointer: .init(x: 0, y: 1)), "a pointer position comes with it")
        expectEqual(GuestPointerScroll.Phase.allCases.map(\.rawValue), ["began", "changed", "ended", "cancelled"],
                    "the names IcliKit's ScrollPhase takes")
        let phase = "phase must be began, changed, ended or cancelled"
        expectEqual(scrollProblem([:]), phase)
        expectEqual(scrollProblem(["phase": "move"]), phase)
        expectEqual(scrollProblem(["phase": 2]), phase)
        let delta = "must be a number within ±10000"
        expectEqual(scrollProblem(["phase": "changed", "dy": "20"]), "dy \(delta)")
        expectEqual(scrollProblem(["phase": "changed", "dx": true]), "dx \(delta)", "a boolean is not a number")
        expectEqual(scrollProblem(["phase": "changed", "dy": 10001]), "dy \(delta)")
        expectEqual(scrollProblem(["phase": "changed", "dy": Double.infinity]), "dy \(delta)")
        let point = "x and y must be numbers within 0...1"
        expectEqual(scrollProblem(["phase": "began", "x": 0.5]), point, "x without y")
        expectEqual(scrollProblem(["phase": "began", "x": 0.5, "y": 1.01]), point)
        expectEqual(scrollProblem(["phase": "began", "x": -0.1, "y": 0.5]), point)
        expectEqual(try? GuestPointerScroll.point(["x": 0.25, "y": 0.75]), GuestPointerScroll.Point(x: 0.25, y: 0.75))
        expect((try? GuestPointerScroll.point(["x": false, "y": 0])) == nil, "a boolean is not a coordinate")
        expectEqual(try? GuestPointerScroll.sequence([:]), 0, "no seq always moves")
        expectEqual(try? GuestPointerScroll.sequence(["seq": 42]), 42)
        expectEqual(try? GuestPointerScroll.sequence(["seq": 9_007_199_254_740_992.0]), 1 << 53)
        for bad: Any in [-1, 1.5, true, "7", 9_007_199_254_740_994.0] {
            expect((try? GuestPointerScroll.sequence(["seq": bad])) == nil, "seq \(bad) is refused")
        }
        expectEqual(try? GuestPointerScroll.buttons([:]), 0, "no buttons held when there are none")
        expectEqual(try? GuestPointerScroll.buttons(["buttons": 1]), 1)
        expectEqual(try? GuestPointerScroll.buttons(["buttons": 7]), 7)
        for bad: Any in [-1, 8, 1.5, true, "1"] {
            expect((try? GuestPointerScroll.buttons(["buttons": bad])) == nil, "buttons \(bad) is refused")
        }
    }
}
