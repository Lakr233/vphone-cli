import CoreGraphics
import Foundation
import ImageIO
import MachO

// MARK: - Harness

/// Checks the guest-independent parts of vphoned on the Mac: the service
/// profile lists and bookkeeping, the first-boot settle verdict (data
/// migration included), the device name rule, the pointer scroll
/// parameters, the Irisin package a guest takes and the MobileGestalt
/// answers vphoned adds, and the screenshot crop, scale and encode.
/// `run-logic-tests.sh` builds this file with those sources.
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
        locationServicesOffError()
        mobileGestaltAnswers()
        settingsValue()
        screenshotSizing()
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

    static func locationServicesOffError() {
        let error = GuestAPIError.locationServicesOff
        expectEqual(error.code, "location_services_off")
        expect(error.description.contains("location.services {enabled:true}"), "the message names the RPC that turns Location Services on")
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
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 0.09) == "timeout_ms must be 100–10000", "short timeout is refused with the range")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 10.01) == "timeout_ms must be 100–10000", "long timeout is refused with the range")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 0.1) == nil, "100 ms timeout is accepted")
        expect(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 10) == nil, "10000 ms timeout is accepted")
        let refusal = GuestAPIError.invalidRequest(GuestProcessSpawnPolicy.validate(executable: "ps", arguments: [], timeout: 10.001) ?? "").wireBody
        expect(refusal["code"] as? String == "invalid_param" && refusal["message"] as? String == "timeout_ms must be 100–10000" && refusal["hint"] == nil,
               "timeout refusal is a hintless invalid_param naming the range")
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

    static func screenshotSizing() {
        typealias Sizing = GuestScreenshotSizing
        let pointSize = (width: 100.0, height: 50.0)

        // 200x100 px, two per point: red top-left, green top-right, blue
        // bottom-left, yellow bottom-right.
        let colors: [(r: Double, g: Double, b: Double)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
        func jpeg(_ image: CGImage, quality: Double) -> Data {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            _ = CGImageDestinationFinalize(destination)
            return data as Data
        }
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (index, color) in colors.enumerated() {
            context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
            // CoreGraphics counts y from the bottom.
            context.fill(CGRect(x: (index % 2) * 100, y: index < 2 ? 50 : 0, width: 100, height: 50))
        }
        let original = jpeg(context.makeImage()!, quality: 1.0)

        func isColor(_ data: Data, _ x: Int, _ y: Int, _ color: (r: Double, g: Double, b: Double)) -> Bool {
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
            let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = canvas.data!.assumingMemoryBound(to: UInt8.self) + y * canvas.bytesPerRow + x * 4
            return abs(Int(bytes[0]) - Int(color.r * 255)) < 40 && abs(Int(bytes[1]) - Int(color.g * 255)) < 40
                && abs(Int(bytes[2]) - Int(color.b * 255)) < 40
        }
        func region(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
            ["x": x, "y": y, "width": width, "height": height]
        }
        func run(_ params: [String: Any]) -> (jpeg: Data, width: Int, height: Int, region: Sizing.Region)? {
            guard let options = try? Sizing.parse(params) else { return nil }
            return try? Sizing.apply(options, jpeg: original, pointSize: pointSize)
        }
        func parseError(_ params: [String: Any]) -> GuestAPIError? {
            do { _ = try Sizing.parse(params) } catch let error as GuestAPIError { return error } catch {}
            return nil
        }
        func applyError(_ params: [String: Any], _ data: Data? = nil) -> GuestAPIError? {
            do { _ = try Sizing.apply(Sizing.parse(params), jpeg: data ?? original, pointSize: pointSize) }
            catch let error as GuestAPIError { return error } catch {}
            return nil
        }

        // no params: nothing to do, so the daemon never decodes
        expect((try? Sizing.parse([:]))?.isEmpty == true, "no param is an empty option set")
        expect((try? Sizing.parse(["quality": 0.5]))?.isEmpty == false, "quality alone is not empty")

        // crop alone: the bottom-right quarter
        let crop = run(["region": region(50, 25, 50, 25)])
        expectEqual(crop.map { [$0.width, $0.height] } ?? [], [100, 50], "crop size")
        expectEqual(crop?.region, Sizing.Region(x: 50, y: 25, width: 50, height: 25), "crop reports the requested region")
        expect(crop.map { isColor($0.jpeg, 50, 25, colors[3]) && isColor($0.jpeg, 2, 2, colors[3]) } ?? false, "crop shows yellow")

        // a fractional region rounds each edge to whole pixels
        let fractional = run(["region": region(10.3, 5.2, 20.4, 10.1)])
        expectEqual(fractional.map { [$0.width, $0.height] } ?? [], [40, 21], "edge-rounded crop size")

        // scale alone
        let scaled = run(["max_dimension": 100])
        expectEqual(scaled.map { [$0.width, $0.height] } ?? [], [100, 50], "scale keeps the aspect ratio")
        expectEqual(scaled?.region, Sizing.Region(x: 0, y: 0, width: 100, height: 50), "no region is the full screen")
        expect(scaled.map { isColor($0.jpeg, 10, 10, colors[0]) && isColor($0.jpeg, 90, 40, colors[3]) } ?? false, "scale keeps the quadrants")
        expectEqual(run(["max_dimension": 5000]).map { [$0.width, $0.height] } ?? [], [200, 100], "never scales up")
        expectEqual(run(["max_dimension": 200])?.width, 200, "at the longer side is unchanged")

        // both: the crop is scaled
        let both = run(["region": region(0, 0, 50, 25), "max_dimension": 50])
        expectEqual(both.map { [$0.width, $0.height] } ?? [], [50, 25], "crop then scale")
        expect(both.map { isColor($0.jpeg, 25, 12, colors[0]) } ?? false, "crop then scale shows red")

        // quality changes the byte size, not the image size
        let low = run(["quality": 0.5])
        let high = run(["quality": 0.9])
        expect((low?.jpeg.count ?? Int.max) < (high?.jpeg.count ?? 0), "quality 0.5 is smaller than quality 0.9")
        let cropExplicit = run(["region": region(50, 25, 50, 25), "quality": 0.8])
        expect(crop != nil && crop?.jpeg == cropExplicit?.jpeg, "a crop without quality encodes at 0.8")
        let scaleExplicit = run(["max_dimension": 100, "quality": 0.8])
        expect(scaled != nil && scaled?.jpeg == scaleExplicit?.jpeg, "a scale without quality encodes at 0.8")
        expectEqual(low.map { [$0.width, $0.height] } ?? [], [200, 100], "quality alone keeps the size")

        // the coordinate mapping: pixel (px, py) is point (x + px / scale, y + py / scale)
        // a crop across the red/green edge (point 50) puts the edge at (50 - region.x) * scale
        for maxDimension in [nil, 20] as [Int?] {
            var params: [String: Any] = ["region": region(40, 0, 20, 25)]
            if let maxDimension { params["max_dimension"] = maxDimension }
            guard let edge = run(params) else { expect(false, "the edge crop ran"); continue }
            let scale = Double(edge.width) / edge.region.width
            let expected = (50 - edge.region.x) * scale
            let row = edge.height / 4
            let boundary = (0 ..< edge.width).first { !isColor(edge.jpeg, $0, row, colors[0]) } ?? -1
            expect(abs(Double(boundary) - expected) <= 1, "the red/green edge is at pixel \(boundary), expected \(expected)")
        }

        let tiny = run(["max_dimension": 1])
        expectEqual(tiny.map { [$0.width, $0.height] } ?? [], [1, 1], "max_dimension 1 on a 2:1 image")
        if let tiny {
            let scale = Double(tiny.width) / tiny.region.width
            expectEqual(scale, 0.01, "1 pixel over 100 points")
            expectEqual(tiny.region.x + 1 / scale, 100, "the pixel's far edge is the screen's")
        }

        // the reply: empty options keep the image bytes and add the point keys
        let capture: [String: Any] = ["bytes": original.count, "mime_type": "image/jpeg", "width": 200, "height": 100,
                                      "coordinate_scale": 2.0, "data": original.base64EncodedString(),
                                      "jpeg": original]
        func reply(_ params: [String: Any], _ input: [String: Any]) -> [String: Any]? {
            guard let options = try? Sizing.parse(params) else { return nil }
            return try? Sizing.reply(capture: input, options: options, pointSize: pointSize)
        }
        if let plain = reply([:], capture) {
            expect(plain["data"] as? String == original.base64EncodedString(), "empty options leave the data identical")
            expectEqual(plain["bytes"] as? Int, original.count, "empty options leave bytes identical")
            expectEqual(plain["point_width"] as? Double, 100, "empty options add point_width")
            expectEqual(plain["point_height"] as? Double, 50, "empty options add point_height")
            expectEqual((plain["region"] as? [String: Double])?["width"], 100, "empty options add the full-screen region")
        } else {
            expect(false, "the empty-options reply ran")
        }
        // pinned replies on the 200x100 px, 100x50 pt fixture: width, height, region, pixels per point
        let sizedCases: [(params: [String: Any], width: Int, height: Int, region: [String: Double], scale: Double)] = [
            (["quality": 0.5], 200, 100, ["x": 0, "y": 0, "width": 100, "height": 50], 2),
            (["region": region(50, 25, 50, 25)], 100, 50, ["x": 50, "y": 25, "width": 50, "height": 25], 2),
            (["max_dimension": 100], 100, 50, ["x": 0, "y": 0, "width": 100, "height": 50], 1),
            // 40x21 px crop scaled to 30 wide: 21 * 30 / 40 rounds to 16
            (["region": region(10.3, 5.2, 20.4, 10.1), "max_dimension": 30], 30, 16,
             ["x": 10.3, "y": 5.2, "width": 20.4, "height": 10.1], 30 / 20.4),
        ]
        for testCase in sizedCases {
            let label = "\(testCase.params)"
            guard let out = reply(testCase.params, capture) else { expect(false, "reply ran for \(label)"); continue }
            expectEqual(out["width"] as? Int, testCase.width, "\(label) width")
            expectEqual(out["height"] as? Int, testCase.height, "\(label) height")
            expectEqual(out["point_width"] as? Double, 100, "\(label) point_width")
            expectEqual(out["point_height"] as? Double, 50, "\(label) point_height")
            expectEqual(out["region"] as? [String: Double], testCase.region, "\(label) region")
            expectEqual(out["coordinate_scale"] as? Double, testCase.scale, "\(label) coordinate_scale")
        }

        // one-past-bound rejections: the code, and a message naming param, value and range
        func rejected(_ error: GuestAPIError?, _ parts: [String], _ label: String, line: Int = #line) {
            guard let error else { expect(false, "\(label) is rejected", line: line); return }
            expectEqual(error.code, "invalid_param", label, line: line)
            guard case .invalidRequest = error else { expect(false, "\(label) is invalidRequest", line: line); return }
            for part in parts {
                expect(error.description.contains(part), "\(label): \"\(error.description)\" names \(part)", line: line)
            }
        }
        rejected(parseError(["max_dimension": 0]), ["max_dimension", "0", "1 or more"], "max_dimension 0")
        rejected(parseError(["max_dimension": 1.5]), ["max_dimension", "1.5"], "max_dimension fraction")
        rejected(parseError(["max_dimension": "9"]), ["max_dimension", "9"], "max_dimension text")
        rejected(parseError(["quality": 0.09]), ["quality", "0.09", "0.1 to 1.0"], "quality 0.09")
        rejected(parseError(["quality": 1.01]), ["quality", "1.01", "0.1 to 1.0"], "quality 1.01")
        rejected(parseError(["quality": true]), ["quality", "true"], "quality boolean")
        rejected(parseError(["region": region(0, 0, 0, 10)]), ["region.width", "0", "above 0"], "width 0")
        rejected(parseError(["region": region(0, 0, 10, -1)]), ["region.height", "-1", "above 0"], "height -1")
        rejected(parseError(["region": region(-1, 0, 10, 10)]), ["region.x", "-1", "0 or more"], "x -1")
        rejected(parseError(["region": region(0, -1, 10, 10)]), ["region.y", "-1", "0 or more"], "y -1")
        rejected(parseError(["region": ["x": 0, "y": 0, "width": 10]]), ["region.height", "missing"], "missing field")
        rejected(parseError(["region": ["x": 0, "y": 0, "width": 10, "height": "ten"]]), ["region.height", "ten"], "non-numeric field")
        rejected(parseError(["region": "all"]), ["region", "all"], "region not an object")
        rejected(applyError(["region": region(50, 0, 50.1, 10)]), ["x + width", "100.1", "at most 100"], "x + width one past the edge")
        rejected(applyError(["region": region(0, 40, 10, 10.5)]), ["y + height", "50.5", "at most 50"], "y + height past the edge")
        rejected(applyError(["region": region(10, 10, 0.1, 10)]), ["region.width", "0.1", "at least 0.5"], "0.1-point region")
        expect(applyError(["region": region(0, 0, 100, 50)]) == nil, "the whole screen is inside")

        // an image that does not decode fails the operation, never succeeds
        if let error = applyError(["quality": 0.5], Data("not a jpeg".utf8)) {
            expectEqual(error.code, "invalid_operation")
            if case .operationFailed = error {} else { expect(false, "non-JPEG is operationFailed") }
            expect(error.description.contains("decode"), "the message names the decode step: \(error.description)")
        } else {
            expect(false, "non-JPEG bytes are rejected")
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
            case .echo: MethodSpec(.required("a", .string, "a"), .optional("b", .integer, "b"), summary: "echo fixture")
            case .always:
                MethodSpec(.required("a", .string, "a"), summary: "always fixture", force: .always("act on <a>") { p in
                    guard let a = p["a"] as? String, !a.isEmpty else { throw GuestAPIError.invalidRequest("a is required") }
                    return "act on \(a)"
                })
            case .when: MethodSpec(.optional("kill", .boolean, "kill"), summary: "when fixture", force: .when("kill", "kill fixture") { _ in "kill fixture" })
            case .varies:
                MethodSpec(.optional("userspace", .boolean, "userspace"), summary: "varies fixture", force: .always("reboot fixture") { p in
                    GuestMethodArea.flag(p, "userspace") ? "restart fixture userspace" : "reboot fixture"
                })
            case .declared:
                MethodSpec(.required("a", .string, "a"), summary: "declared fixture", result: [
                    .optional("z", .boolean), .required("x", .integer), .hidden("y", .string), .required("e", .object).open(),
                ])
            case .empty: MethodSpec(summary: "empty fixture", result: [])
            }
        }
    }

    nonisolated(unsafe) static var specCount = 0

    enum CountedMethod: String, GuestMethod {
        case one = "counted.one"
        case two = "counted.two"

        var spec: MethodSpec {
            LogicTests.specCount += 1
            return MethodSpec(summary: "counted fixture")
        }
    }

    static func json(_ value: [String: Any]?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func methodDispatch() {
        methodDispatchBody()
        rpcErrorEnvelope()
        inBandFailures()
    }

    static func methodDispatchBody() {
        let area = GuestMethodArea.make(FixtureMethod.self) { _, params in params }
        func run(_ method: String, _ params: [String: Any]) -> (result: [String: Any]?, error: String?, code: String?, hint: String?) {
            do { return (try area.execute(method, params), nil, nil, nil) } catch let error as GuestAPIError {
                return (nil, String(describing: error), error.code, error.hint)
            } catch { return (nil, "\(error)", nil, nil) }
        }

        expect(run("other", [:]).result == nil && run("other", [:]).error == nil, "an unknown name is not this area's")
        let extra = run("fixture.echo", ["a": "x", "b": 1, "z": 9])
        expectEqual(extra.result == nil, true, "an undeclared key fails the call")
        expectEqual(extra.code ?? "", "invalid_param")
        expectEqual(extra.error ?? "", "Unknown param: z")
        expectEqual(extra.hint ?? "", "Did you mean `a`? Valid params: a, b")
        expectEqual(json(run("fixture.echo", ["a": "x", "b": 1]).result), json(["a": "x", "b": 1]), "declared keys pass")
        expectEqual(run("fixture.echo", ["z": 9]).error ?? "", "Unknown param: z", "no declared key still fails on the extra")

        let refusal = "Pass force: true to act on x"
        let refused = run("fixture.always", ["a": "x"])
        expectEqual(refused.error ?? "", refusal)
        expectEqual(refused.code ?? "", "force_required")
        expectEqual(refused.hint ?? "", "Confirm with the user, then repeat the call with force: true")
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
            ["name": "fixture.echo", "description": "echo fixture", "params": [
                ["name": "a", "type": "string", "required": true, "description": "a"],
                ["name": "b", "type": "integer", "required": false, "description": "b"],
            ], "force": "never"],
            ["name": "fixture.always", "description": "always fixture", "params": [["name": "a", "type": "string", "required": true, "description": "a"]], "force": "always", "force_action": "act on <a>"],
            ["name": "fixture.when", "description": "when fixture", "params": [["name": "kill", "type": "boolean", "required": false, "description": "kill"]], "force": "when:kill", "force_action": "kill fixture"],
            ["name": "fixture.varies", "description": "varies fixture", "params": [["name": "userspace", "type": "boolean", "required": false, "description": "userspace"]], "force": "always", "force_action": "reboot fixture"],
            ["name": "fixture.declared", "description": "declared fixture", "params": [["name": "a", "type": "string", "required": true, "description": "a"]], "force": "never", "result": [
                ["name": "e", "type": "object", "required": true, "open": true, "nullable": false],
                ["name": "x", "type": "integer", "required": true, "open": false, "nullable": false],
                ["name": "z", "type": "boolean", "required": false, "open": false, "nullable": false],
            ]],
            ["name": "fixture.empty", "description": "empty fixture", "params": [] as [[String: Any]], "force": "never", "result": [] as [[String: Any]]],
        ]]
        expectEqual(json(catalog), json(expected), "catalog")

        // catalog and dispatcher agree
        let listed = (catalog["methods"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let dispatched = FixtureMethod.allCases.map(\.rawValue).filter { name in
            var params: [String: Any] = ["force": true]
            for declared in FixtureMethod(rawValue: name)?.spec.params ?? [] { params[declared.name] = "x" }
            return (try? area.execute(name, params)) != nil
        }
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
            var spec: MethodSpec { MethodSpec(summary: "core fixture") }
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
        expectEqual(call(["x": 1]) == nil, true, "methods.list takes no params")
        expectEqual(json(call([:])), json(answer), "two calls are byte-identical")
        expect(json(answer).utf8.count < 1 << 20, "the answer is far below the 1 MiB body limit")
        // every param methods.list describes is admitted by the unknown-param check
        for entry in answer?["methods"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String, name.hasPrefix("fixture.") else { continue }
            var all: [String: Any] = ["force": true]
            for param in entry["params"] as? [[String: Any]] ?? [] { all[param["name"] as? String ?? ""] = "x" }
            var rejected = false
            do { _ = try GuestMethodArea.dispatch(table, method: name, params: all) } catch { rejected = String(describing: error).hasPrefix("Unknown param") }
            expect(!rejected, "\(name): every listed param is admitted")
        }
        var unknown = ""
        do { _ = try GuestMethodArea.dispatch(table, method: "nope.nothing", params: [:]) } catch { unknown = String(describing: error) }
        expectEqual(unknown, "Unknown method: nope.nothing", "no area answering is an unknown method")
    }

    // MARK: RPC error envelope

    /// The wire body of one failure as JSON text, as APIWire.execute sends it (it uses `GuestAPIError.wireBody`).
    static func wire(_ error: GuestAPIError) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: error.wireBody, options: [.sortedKeys])
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// inBandFailure turns a producer's error map into the thrown error the caller's closure builds, and passes a clean result through.
    /// Which code each of the three handlers picks is not asserted here: they need a guest.
    static func inBandFailures() {
        var thrown: GuestAPIError?
        var returned: [String: Any]?
        do { returned = try GuestAPIError.inBandFailure(["entries": [Any](), "error": "no io registry"], as: { .operationFailed($0) }) }
        catch let error as GuestAPIError { thrown = error } catch {}
        expect(returned == nil, "no success body")
        let body = thrown.map(wire) ?? [:]
        expectEqual(body["code"] as? String ?? "", "invalid_operation")
        expectEqual(body["message"] as? String ?? "", "no io registry")
        expect(body["hint"] == nil, "no hint key")
        let ok = try? GuestAPIError.inBandFailure(["enabled": true, "ok": true], as: { .operationFailed($0) })
        expect(ok?["enabled"] as? Bool == true, "a result without an error key passes through")
    }

    static func rpcErrorEnvelope() {
        // Wire: code, message, hint; the hint key is absent (not null) without one.
        let withHint = wire(.notFound("No such file", hint: "List the directory first"))
        expectEqual(withHint["code"] as? String ?? "", "not_found")
        expectEqual(withHint["message"] as? String ?? "", "No such file")
        expectEqual(withHint["hint"] as? String ?? "", "List the directory first")
        // Each constructor maps to one code; none carries a hint key without one.
        let codes: [(GuestAPIError, String)] = [
            (.notFound("x"), "not_found"), (.unavailable("x"), "unavailable"), (.permission("x"), "permission"),
            (.forceRequired("x"), "force_required"), (.invalidRequest("x"), "invalid_param"),
            (.operationFailed("x"), "invalid_operation"), (.unsupportedMethod("x"), "not_found"),
            (.locationServicesOff, "location_services_off"), (.alreadyDone(code: "already_done", message: "x"), "already_done"),
        ]
        for (error, code) in codes {
            let body = wire(error)
            expectEqual(body["code"] as? String ?? "", code, "code of \(error.code)")
            expect(body["hint"] == nil, "no hint key on \(error.code)")
            expect(!json(body).contains("hint"), "no hint text on \(error.code)")
        }

        enum Wide: String, GuestMethod {
            case wide = "wide.call"
            case none = "wide.none"
            var spec: MethodSpec {
                switch self {
                case .wide: MethodSpec(.optional("alpha", .string, "alpha"), .optional("beta", .string, "beta"), .optional("gamma", .string, "gamma"), summary: "fixture")
                case .none: MethodSpec(summary: "fixture")
                }
            }
        }
        let area = GuestMethodArea.make(Wide.self) { _, params in params }
        func failure(_ method: String, _ params: [String: Any]) -> [String: Any] {
            do { _ = try area.execute(method, params) } catch let error as GuestAPIError { return wire(error) } catch {}
            return [:]
        }

        // Unknown params
        var body = failure("wide.call", ["alpa": 1])
        expectEqual(body["code"] as? String ?? "", "invalid_param")
        expectEqual(body["message"] as? String ?? "", "Unknown param: alpa")
        expectEqual(body["hint"] as? String ?? "", "Did you mean `alpha`? Valid params: alpha, beta, gamma")
        body = failure("wide.call", ["zzzzzzzz": 1])
        expectEqual(body["hint"] as? String ?? "", "Valid params: alpha, beta, gamma", "no near param, no suggestion")
        body = failure("wide.call", ["zeta": 1, "alpa": 1])
        expectEqual(body["message"] as? String ?? "", "Unknown param: alpa, zeta", "two extras are sorted")
        expectEqual(body["hint"] as? String ?? "", "Did you mean `alpha`? Valid params: alpha, beta, gamma", "the first sorted extra drives the suggestion")
        body = failure("wide.none", ["a": 1])
        expectEqual(body["message"] as? String ?? "", "Unknown param: a")
        expectEqual(body["hint"] as? String ?? "", "This method takes no params")
        expectEqual(failure("wide.call", ["alpha": 1, "force": true]).isEmpty, true, "force is always admitted")

        // 5 extras list all, 6 add " and 1 more"; 1000 extras stay bounded
        func extras(_ n: Int) -> [String: Any] { Dictionary(uniqueKeysWithValues: (0 ..< n).map { (String(format: "k%04d", $0), 1) }) }
        expectEqual(failure("wide.call", extras(5))["message"] as? String ?? "", "Unknown param: k0000, k0001, k0002, k0003, k0004")
        expectEqual(failure("wide.call", extras(6))["message"] as? String ?? "", "Unknown param: k0000, k0001, k0002, k0003, k0004 and 1 more")
        body = failure("wide.call", extras(1000))
        expectEqual(body["message"] as? String ?? "", "Unknown param: k0000, k0001, k0002, k0003, k0004 and 995 more")
        expect((body["message"] as? String ?? "").count < 500, "1000 extras: bounded message")

        // closest: bounds and ties
        let sixtyFour = String(repeating: "a", count: 64)
        let sixtyFive = String(repeating: "a", count: 65)
        expectEqual(GuestAPIError.closest(sixtyFour, [sixtyFour + "bb"]) ?? "", sixtyFour + "bb", "a 64-character name is matched")
        expect(GuestAPIError.closest(sixtyFive, [sixtyFive]) == nil, "a 65-character name is not")
        expect(GuestAPIError.closest(String(repeating: "a", count: 10_000), ["a"]) == nil, "a 10,000-character name is not")
        expectEqual(GuestAPIError.closest("cat", ["cap", "car"]) ?? "", "cap", "equidistant: the first candidate wins")
        expectEqual(GuestAPIError.closest("cat", ["car", "cap"]) ?? "", "car", "equidistant: order decides")
        expectEqual(GuestAPIError.closest("abcdef", ["abcdxx"]) ?? "", "abcdxx", "distance 2 is within the bound")
        expect(GuestAPIError.closest("abcdef", ["abcxxx"]) == nil, "distance 3 over a 6-character name is out")
        expectEqual(GuestAPIError.closest("abcdefghi", ["abcdefxxx"]) ?? "", "abcdefxxx", "9 characters allow distance 3")
        expect(GuestAPIError.closest("x", ["abc"]) == nil, "nothing near")

        // Unknown method: hint only with a near method
        func unknownMethod(_ name: String) -> [String: Any] {
            do { _ = try GuestMethodArea.dispatch([area], method: name, params: [:]) } catch let error as GuestAPIError { return wire(error) } catch {}
            return [:]
        }
        body = unknownMethod("wide.cal")
        expectEqual(body["code"] as? String ?? "", "not_found")
        expectEqual(body["message"] as? String ?? "", "Unknown method: wide.cal")
        expectEqual(body["hint"] as? String ?? "", "Did you mean `wide.call`?")
        expect(unknownMethod("nothing.like.it")["hint"] == nil, "no near method: no hint key")
        body = unknownMethod(String(repeating: "m", count: 10_000))
        expect(body["hint"] == nil, "no Did you mean for a 10,000-character name")
        expect((body["message"] as? String ?? "").count < 500, "a 10,000-character name keeps the message under 500 characters")
        expectEqual(body["message"] as? String ?? "", "Unknown method: " + String(repeating: "m", count: 64) + "…", "the name is cut at 64 characters")
        expectEqual(unknownMethod(String(repeating: "m", count: 64))["message"] as? String ?? "", "Unknown method: " + String(repeating: "m", count: 64), "a 64-character name is shown whole")
        expectEqual(unknownMethod("wide.nonf")["hint"] as? String ?? "", "Did you mean `wide.none`?")

        errnoClassification()
    }

    /// `fromErrno` is the one reclassification helper the handlers share (kill, posix_spawn, shutdown);
    /// the handlers themselves need a guest, so the mapping is proven here.
    static func errnoClassification() {
        let cases: [(errno: Int32, code: String)] = [
            (ENOENT, "not_found"), (ESRCH, "not_found"), (EACCES, "permission"), (EPERM, "permission"),
            (EIO, "invalid_operation"), (EINVAL, "invalid_operation"), (0, "invalid_operation"),
        ]
        for c in cases {
            let body = wire(GuestAPIError.fromErrno(c.errno, "boom \(c.errno)"))
            expectEqual(body["code"] as? String ?? "", c.code, "errno \(c.errno)")
            expectEqual(body["message"] as? String ?? "", "boom \(c.errno)", "errno \(c.errno) keeps the message")
            expect(body["hint"] == nil, "errno \(c.errno): no hint key")
        }
    }
}
