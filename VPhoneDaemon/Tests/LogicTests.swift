import Foundation
import MachO

// MARK: - Harness

/// Checks the guest-independent parts of vphoned on the Mac: the service
/// profile lists and bookkeeping, the first-boot settle verdict (data
/// migration included), the device name rule, the pointer scroll
/// parameters, the Irisin package a guest takes and the MobileGestalt
/// answers vphoned adds. `run-logic-tests.sh`
/// builds this file with those sources.
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
        processSpawnPolicy()
        bootstrapPlatform()
        setupAssistantState()
        homeViewDistancePolicy()
        mobileGestaltAnswers()
        settingsValue()
        methodDispatch()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func settingsValue() {
        // Decoded the way the daemon gets its params; nil is no `value` at all.
        func typedText(_ json: String?, _ type: String?) -> String? {
            let body = json.map { "{\"value\":\($0)}" } ?? "{}"
            guard let params = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let result = GuestSettingsValue.typedText(params["value"], type: type)
            else { return nil }
            return "\(result.text)|\(result.type)"
        }
        expectEqual(typedText(nil, nil), nil, "no value")
        expectEqual(typedText("null", nil), nil, "null")
        expectEqual(typedText(nil, "string"), nil, "no value, type string")
        expectEqual(typedText("null", "string"), nil, "null, type string")
        expectEqual(typedText("5", "json"), nil, "number, type json")
        expectEqual(typedText("\"x\"", "json"), nil, "string, type json")
        expectEqual(typedText("true", nil), "1|bool")
        expectEqual(typedText("5", nil), "5|float")
        expectEqual(typedText("\"x\"", nil), "x|string")
        expectEqual(typedText("[1]", nil), "[1]|json")
        expectEqual(typedText("{\"a\":1}", nil), "{\"a\":1}|json")
        expectEqual(typedText("true", "string"), "1|string")
        expectEqual(typedText("5", "string"), "5|string")
        expectEqual(typedText("\"x\"", "string"), "x|string")
        expectEqual(typedText("[1]", "json"), "[1]|json")
        expectEqual(typedText("{\"a\":1}", "json"), "{\"a\":1}|json")
        expectEqual(typedText("\"\"", nil), "|string")
        expectEqual(typedText("false", nil), "0|bool")
        expectEqual(typedText("0", "float"), "0|float")
        expectEqual(typedText("[]", nil), "[]|json")
        expectEqual(typedText("{}", nil), "{}|json")
        // A decoded 1 or 0 is also a Bool, as it always was here.
        expectEqual(typedText("1", nil), "1|bool")
        expectEqual(typedText("0", nil), "0|bool")
    }

    static func mobileGestaltAnswers() {
        let answers = GuestMobileGestaltAnswers.alwaysOnDisplay
        func cache(_ extra: [String: Any]) -> Data {
            try! PropertyListSerialization.data(fromPropertyList: [
                "CacheData": Data([1, 2, 3]), "CacheExtra": extra, "CacheUUID": "u", "CacheVersion": "24A446",
            ], format: .binary, options: 0)
        }
        let original = cache(["ybGkijAwLTwevankfVzsDQ": Data(count: 16), "aoJSd/MXk7M40NgXTM6x+g": false])
        guard case let .updated(data) = GuestMobileGestaltAnswers.answeringYes(answers, in: original) else {
            expect(false, "a cache without the answers is updated")
            return
        }
        let plist = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let extra = plist["CacheExtra"] as! [String: Any]
        expectEqual(extra["2OOJf1VhaM7NxfRok3HbWQ"] as? Bool, true, "DeviceSupportsAlwaysOnDisplay")
        expectEqual(extra["j8/Omm6s1lsmTDFsXjsBfA"] as? Bool, true, "DeviceSupportsAlwaysOnTime")
        expectEqual(extra["aoJSd/MXk7M40NgXTM6x+g"] as? Bool, false, "the flipbook answer is left as it was")
        expectEqual(extra["ybGkijAwLTwevankfVzsDQ"] as? Data, Data(count: 16), "other answers are kept")
        expectEqual(plist["CacheData"] as? Data, Data([1, 2, 3]), "the computed answers are kept")
        expectEqual(plist["CacheVersion"] as? String, "24A446")
        expectEqual(GuestMobileGestaltAnswers.answeringYes(answers, in: data), .present, "a second pass changes nothing")
        expectEqual(GuestMobileGestaltAnswers.answeringYes(answers, in: Data("half a fi".utf8)), .unreadable)
        let noExtra = try! PropertyListSerialization.data(fromPropertyList: ["CacheVersion": "24A446"], format: .binary, options: 0)
        expectEqual(GuestMobileGestaltAnswers.answeringYes(answers, in: noExtra), .unreadable, "a cache needs CacheExtra")
    }

    static func homeViewDistancePolicy() {
        expect(GuestHomeViewDistancePolicy.rejection(mode: "automatic", resetEnvironment: false) != nil,
            "environment-wide reset requires explicit acknowledgement before native transport")
        expect(GuestHomeViewDistancePolicy.rejection(mode: "automatic", resetEnvironment: true) == nil,
            "acknowledged environment-wide reset is admitted")
        for mode in ["near", "standard", "far"] {
            expect(GuestHomeViewDistancePolicy.rejection(mode: mode, resetEnvironment: false) == nil,
                "detail-only override preserves unrelated fields without a reset acknowledgement")
        }
        for mode in ["", "Near", "middle", "3", "automatic "] {
            expect(GuestHomeViewDistancePolicy.rejection(mode: mode, resetEnvironment: true) != nil,
                "strict native enum mapping rejects unsupported mode \(mode)")
        }
    }

    static func processSpawnPolicy() {
        let valid = GuestProcessSpawnPolicy.validate(executable: "ps", arguments: ["-axo", "pid=,ppid=,args="], timeout: 3)
        expect(valid == nil, "standard ps discovery request is accepted")
        expect(GuestProcessSpawnPolicy.validate(executable: "sh", arguments: [], timeout: 3) != nil, "shell is refused")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: Array(repeating: "x", count: 17), timeout: 3) != nil, "argument count is bounded")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [String(repeating: "x", count: 257)], timeout: 3) != nil, "argument length is bounded")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: ["x\n"], timeout: 3) != nil, "control characters are refused")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 0.09) != nil, "short timeout is refused")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 10.01) != nil, "long timeout is refused")
    }

    // MARK: - Setup Assistant

    static func setupAssistantState() {
        for machine in ["AppleTV5,3", "AppleTV18,1"] {
            expect(GuestSetupAssistantState.usesTVPolicy(machine: machine), "TV policy for \(machine)")
        }
        for machine in ["iPhone17,3", "iPad16,1", "AudioAccessory5,1", ""] {
            expect(!GuestSetupAssistantState.usesTVPolicy(machine: machine), "existing policy for \(machine)")
        }
        expect(GuestSetupAssistantState.usesHomeViewPolicy(machine: "HomeAccessory17,1"), "HomeView native setup policy")
        expect(!GuestSetupAssistantState.usesHomeViewPolicy(machine: "AudioAccessory5,1"), "HomePod keeps its policy")
        for done in [false, true] {
            for bypass in [false, true] {
                let home = GuestSetupAssistantState(setupDone: done, version: nil, currentVersion: nil,
                    requiresTVCompletion: false, tvCompleted: false,
                    requiresHomeViewCompletion: true, forceNoBuddy: bypass)
                expect(home.pending == (!done && !bypass), "HomeView reads native completion or ForceNoBuddy without an iOS version")
            }
        }
        func state(_ done: Bool, _ version: Int?, _ current: Int?, tv: Bool = true, completed: Bool = true) -> GuestSetupAssistantState {
            GuestSetupAssistantState(setupDone: done, version: version, currentVersion: current, requiresTVCompletion: tv, tvCompleted: completed)
        }
        expect(!state(true, 15, 15).pending, "native TV completion with its current version")
        expect(!state(true, 16, 15).pending, "newer recorded TV version")
        expect(state(false, 15, 15).pending, "TV SetupDone remains required")
        expect(state(true, 14, 15).pending, "TV update setup remains pending")
        expect(state(true, nil, 15).pending, "missing TV version is pending")
        expect(state(true, 15, 15, completed: false).pending, "native TV success flag remains required")
        expect(state(true, 15, nil).pending, "unknown TV current version cannot prove completion")
        expect(!state(true, 11, 11, tv: false, completed: false).pending, "iPhone ignores the TV flag")
        expect(state(false, 11, 11, tv: false).pending, "iPhone SetupDone remains required")
        expect(state(true, 10, 11, tv: false).pending, "iPhone update version remains required")
        expect(!state(true, nil, nil, tv: false).pending, "existing unknown-version fallback")
        expect(state(true, nil, 11, tv: false).pending, "HomePod keeps its existing version policy")
    }

    // MARK: - Service Profile

    static let labelPattern = "^[A-Za-z0-9][A-Za-z0-9._:\\[\\]-]{0,200}$"

    static func profileCatalog() {
        let groups = GuestServiceProfile.groups27
        expectEqual(GuestServiceProfile.base27.count, 133, "appendix A less siriactionsd, passd, financed and generativeexperiencesd")
        expectEqual(Set(GuestServiceProfile.base27).count, 133, "appendix A has no duplicates")
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
        expectEqual(base26.count, 127, "133 minus six 26.6.2 does not load")
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
        expectEqual(trimmed?.labels.count, 137, "default trimmed = 133 + 2 store + 2 follow-up")
        expectEqual(trimmed?.groups, ["base", "app_store", "signin_followup"])
        expect(trimmed?.labels.contains("com.apple.followupd") == true, "followupd is in trimmed")
        expect(trimmed?.labels.contains("com.apple.akd") == false, "akd is not in trimmed by default")
        expect(trimmed?.labels.contains("com.apple.siriactionsd") == false, "siriactionsd serves App Intents controls")
        expect(GuestServiceProfile.neverDisable.contains("com.apple.siriactionsd"), "siriactionsd is never disabled")
        expect(trimmed?.labels.contains("com.apple.passd") == false && trimmed?.labels.contains("com.apple.financed") == false, "Wallet's daemons stay")
        expect(trimmed?.labels.contains("com.apple.generativeexperiencesd") == false, "BackgroundShortcutRunner spins without it")
        if let labels = trimmed?.labels {
            // A guest trimmed by list version 3 owns it; applying again turns it back on.
            let v3 = labels + ["com.apple.generativeexperiencesd"]
            let change = GuestServiceProfile.reconcile(
                target: labels, owned: v3, overrides: Dictionary(uniqueKeysWithValues: v3.map { ($0, true) }),
            )
            expectEqual(change.enable, ["com.apple.generativeexperiencesd"], "list version 3 guests get it back")
        }
        expectEqual(trimmed?.labels, trimmed?.labels.sorted(), "labels sorted")

        let accounts = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 27, extraGroups: ["accounts"])
        expectEqual(accounts?.labels.count, 140, "accounts adds three")
        expect(accounts?.labels.contains("com.apple.amsaccountsd") == true, "amsaccountsd with accounts")

        let allowed = try? GuestServiceProfile.select(
            profile: "trimmed", iosMajor: 27, allow: ["com.apple.weatherd", "com.example.not-listed"],
        )
        expectEqual(allowed?.labels.count, 136, "allow removes one")
        expectEqual(allowed?.allowed, ["com.apple.weatherd"], "only catalog labels are reported as allowed")
        expect(allowed?.labels.contains("com.apple.weatherd") == false, "weatherd kept")

        let trimmed26 = try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 26)
        expectEqual(trimmed26?.labels.count, 131, "26 trimmed = 127 + 2 store + 2 follow-up")
        expectEqual(trimmed26?.groups, ["base", "app_store", "signin_followup"])
        expect(trimmed26?.refused.isEmpty == true, "the 26 list names nothing never disabled")
        expectEqual(
            (try? GuestServiceProfile.select(profile: "trimmed", iosMajor: 26, extraGroups: ["accounts"]))?.labels.count,
            134, "accounts adds three on 26",
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
            "com.apple.sleepd", "com.apple.generativeexperiencesd", "com.apple.CommCenter",
            "com.apple.CommCenterMobileHelper", "com.apple.CommCenterRootHelper", "com.apple.cloudd", "com.apple.nanoregistryd",
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
        expectEqual(apply.disable.count, 134, "137 minus the three already disabled")
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

    // MARK: - Bootstrap Platform

    static func bootstrapPlatform() {
        let architecture = GuestBootstrapPlatform.packageArchitecture
        expectEqual(architecture("roothide", false), "iphoneos-arm64e")
        expectEqual(architecture("rootless", false), "iphoneos-arm64")
        expectEqual(architecture("roothide", true), "appletvos-arm64e", "an Apple TV takes Irisin's Apple TV package")
        expectEqual(architecture("rootless", true), nil, "Irisin serves no rootless Apple TV")
        expectEqual(architecture("rootful", false), nil)
        expect(GuestBootstrapPlatform.packageRequiresApp(architecture: "iphoneos-arm64e"), "the iOS packages carry the app")
        expect(GuestBootstrapPlatform.packageRequiresApp(architecture: "iphoneos-arm64"), "the iOS packages carry the app")
        expect(!GuestBootstrapPlatform.packageRequiresApp(architecture: "appletvos-arm64e"), "the Apple TV package has none")
        expectEqual(GuestBootstrapPlatform.mainExecutablePlatform(), UInt32(PLATFORM_MACOS), "this test runs as macOS")
        expect(!GuestBootstrapPlatform.isTVOS, "the Mac is not tvOS")

        // Irisin 5.1.4's roothide list
        let roothide: [[String: Any]] = [
            ["source": "deb https://roothide.github.io/procursus iphoneos-arm64e/1800 main", "maximumSystemVersion": 15],
            ["source": "deb https://stripe.owngoal.dev 1900 main", "minimumSystemVersion": 16],
            ["source": "https://apt.owngoal.dev"],
        ]
        let sources = GuestBootstrapPlatform.recommendedSources
        expectEqual(sources([], roothide, 27), ["deb https://stripe.owngoal.dev 1900 main", "https://apt.owngoal.dev"])
        expectEqual(sources(nil, roothide, 15), ["deb https://roothide.github.io/procursus iphoneos-arm64e/1800 main", "https://apt.owngoal.dev"])
        expectEqual(sources([["source": "https://repo.example"]], roothide, 27), ["https://repo.example"], "a managed list with entries wins")
        expectEqual(sources(nil, nil, 27), [], "no list recommends nothing")
    }

    // MARK: Method dispatch

    enum FixtureMethod: String, GuestMethod {
        case echo = "fixture.echo"
        case always = "fixture.always"
        case when = "fixture.when"
        case varies = "fixture.varies"
        case declared = "fixture.declared"
        case empty = "fixture.empty"

        var spec: MethodSpec {
            switch self {
            case .echo: MethodSpec(.required("a", .string), .optional("b", .integer))
            case .always:
                MethodSpec(.required("a", .string), force: .always { p in
                    guard let a = p["a"] as? String, !a.isEmpty else { throw GuestAPIError.invalidRequest("a is required") }
                    return "act on \(a)"
                })
            case .when: MethodSpec(.optional("kill", .boolean), force: .when("kill") { _ in "kill fixture" })
            case .varies:
                MethodSpec(.optional("userspace", .boolean), force: .always { p in
                    GuestMethodArea.flag(p, "userspace") ? "restart fixture userspace" : "reboot fixture"
                })
            case .declared:
                MethodSpec(.required("a", .string), result: [
                    .optional("z", .boolean), .required("x", .integer), .hidden("y", .string), .required("e", .object).open(),
                ])
            case .empty: MethodSpec(result: [])
            }
        }
    }

    nonisolated(unsafe) static var specCount = 0

    enum CountedMethod: String, GuestMethod {
        case one = "counted.one"
        case two = "counted.two"

        var spec: MethodSpec {
            LogicTests.specCount += 1
            return MethodSpec()
        }
    }

    static func json(_ value: [String: Any]?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func methodDispatch() {
        let area = GuestMethodArea.make(FixtureMethod.self) { _, params in params }
        func run(_ method: String, _ params: [String: Any]) -> (result: [String: Any]?, error: String?, code: String?) {
            do { return (try area.execute(method, params), nil, nil) } catch let error as GuestAPIError {
                return (nil, String(describing: error), error.code)
            } catch { return (nil, "\(error)", nil) }
        }

        expect(run("other", [:]).result == nil && run("other", [:]).error == nil, "an unknown name is not this area's")
        expectEqual(json(run("fixture.echo", ["a": "x", "b": 1, "z": 9]).result), json(["a": "x", "b": 1]), "undeclared keys are dropped")
        expectEqual(json(run("fixture.echo", ["z": 9]).result), "{}", "no declared key leaves nothing")

        let refusal = "Pass force: true to act on x"
        let refused = run("fixture.always", ["a": "x"])
        expectEqual(refused.error ?? "", refusal)
        expectEqual(refused.code ?? "", "invalid_operation")
        expectEqual(run("fixture.always", ["a": "x", "force": false]).error ?? "", refusal)
        expectEqual(run("fixture.always", ["a": "x", "force": "yes"]).error ?? "", refusal)
        expectEqual(json(run("fixture.always", ["a": "x", "force": true]).result), json(["a": "x"]), "force: true admits")
        expectEqual(json(run("fixture.always", ["a": "x", "force": 1]).result), json(["a": "x"]), "force: 1 admits")
        expectEqual(run("fixture.always", [:]).error ?? "", "a is required", "invalid and unforced fails validation first")

        expectEqual(run("fixture.varies", [:]).error ?? "", "Pass force: true to reboot fixture")
        expectEqual(run("fixture.varies", ["userspace": true]).error ?? "", "Pass force: true to restart fixture userspace", "the action text follows the params")
        expectEqual(json(run("fixture.varies", ["userspace": true, "force": true]).result), json(["userspace": true]), "forced action runs")

        expectEqual(json(run("fixture.when", ["kill": false]).result), json(["kill": false]), "kill: false needs no force")
        expectEqual(json(run("fixture.when", [:]).result), "{}", "no kill needs no force")
        expectEqual(run("fixture.when", ["kill": true]).error ?? "", "Pass force: true to kill fixture")
        expectEqual(json(run("fixture.when", ["kill": true, "force": true]).result), json(["kill": true]), "forced kill admits")

        // ResultKey storage: undeclared is nil, declared empty is []
        expect(FixtureMethod.echo.spec.result == nil, "no result: reads back nil")
        expectEqual(FixtureMethod.empty.spec.result?.count ?? -1, 0, "result: [] reads back empty")

        let catalog = GuestMethodArea.catalog([area])
        let expected: [String: Any] = ["methods": [
            ["name": "fixture.echo", "params": [
                ["name": "a", "type": "string", "required": true],
                ["name": "b", "type": "integer", "required": false],
            ], "force": "never"],
            ["name": "fixture.always", "params": [["name": "a", "type": "string", "required": true]], "force": "always"],
            ["name": "fixture.when", "params": [["name": "kill", "type": "boolean", "required": false]], "force": "when:kill"],
            ["name": "fixture.varies", "params": [["name": "userspace", "type": "boolean", "required": false]], "force": "always"],
            ["name": "fixture.declared", "params": [["name": "a", "type": "string", "required": true]], "force": "never", "result": [
                ["name": "e", "type": "object", "required": true, "open": true],
                ["name": "x", "type": "integer", "required": true, "open": false],
                ["name": "z", "type": "boolean", "required": false, "open": false],
            ]],
            ["name": "fixture.empty", "params": [] as [[String: Any]], "force": "never", "result": [] as [[String: Any]]],
        ]]
        expectEqual(json(catalog), json(expected), "catalog")

        // catalog and dispatcher agree
        let listed = (catalog["methods"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let dispatched = FixtureMethod.allCases.map(\.rawValue).filter { (try? area.execute($0, ["a": "x", "force": true])) != nil }
        expectEqual(listed, dispatched, "catalog names equal dispatched names")
        expectEqual(Set(listed).count, listed.count, "catalog names are unique")

        // specs are built lazily
        let counted = GuestMethodArea.make(CountedMethod.self) { _, params in params }
        specCount = 0
        for _ in 0 ..< 1000 { _ = try? counted.execute("other", [:]) }
        expectEqual(specCount, 0, "no spec is built for a foreign name")
        for _ in 0 ..< 1000 { _ = try? counted.execute("counted.one", [:]) }
        expectEqual(specCount, 1000, "one spec per dispatch")
        _ = GuestMethodArea.catalog([counted])
        expectEqual(specCount, 1002, "catalog builds each spec once")

        // methods.list reaches the dispatch through the same walk GuestAPI.execute uses
        enum FixtureCore: String, GuestMethod {
            case methodsList = "methods.list"
            var spec: MethodSpec { MethodSpec() }
        }
        nonisolated(unsafe) var table: [GuestMethodArea] = []
        table = [
            .make(FixtureCore.self) { _, _ in GuestMethodArea.catalog(table) },
            GuestMethodArea.make(FixtureMethod.self) { _, params in params },
        ]
        func call(_ params: [String: Any]) -> [String: Any]? {
            try? GuestMethodArea.dispatch(table, method: "methods.list", params: params)
        }
        let answer = call([:])
        let names = (answer?["methods"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        expect(names.contains("methods.list") && names.contains("fixture.echo"), "methods.list lists itself and the other areas")
        expectEqual(json(call(["x": 1])), json(answer), "methods.list ignores params")
        expectEqual(json(call([:])), json(answer), "two calls are byte-identical")
        expect(json(answer).utf8.count < 1 << 20, "the answer is far below the 1 MiB body limit")
        var unknown = ""
        do { _ = try GuestMethodArea.dispatch(table, method: "nope.nothing", params: [:]) } catch { unknown = String(describing: error) }
        expectEqual(unknown, "Unknown method: nope.nothing", "no area answering is an unknown method")
    }
}
