import Darwin
import Foundation
import IcliKit
import IcliSystem

// MARK: - Setup Assistant

/// Setup Assistant (Setup.app) keeps its state in `com.apple.purplebuddy`
/// for user mobile. SpringBoard reads it once, when it starts: it runs the
/// full flow while `SetupDone` is not true, and the flow shown after a
/// software update while `SetupVersion` is below SetupAssistant.framework's
/// `BYBuddyIOSCurrentVersion`. Writing the keys while Setup is on screen does
/// not dismiss it, and killing Setup only makes SpringBoard start it again,
/// so a skip writes the keys and then restarts SpringBoard.
///
/// On the first boot after a restore, SpringBoard decides only once data
/// migration has finished (FrontBoard's `DataMigrationCompleted` milestone),
/// and FrontBoard ignores a relaunch request until then. The keys written
/// before that point are read when it decides, so the skip writes them and
/// leaves SpringBoard alone. `Research/Guest/setup_assistant_skip.md` has the
/// experiments behind this.
extension GuestAPI {
    static func executeSetupAssistant(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "setup.status":
            return try setupAssistantStatus()
        case "setup.skip":
            try requireForce(params, "skip Setup Assistant")
            return try skipSetupAssistant()
        default:
            return nil
        }
    }

    private static let buddyDomain = "com.apple.purplebuddy"

    /// Keep the iOS constant for the existing skip operation. TV status is
    /// read independently; this correction never writes TV completion state.
    static let setupAssistantCurrentVersion = setupAssistantVersion(symbol: "BYBuddyIOSCurrentVersion")
    private static let tvSetupAssistantCurrentVersion = setupAssistantVersion(symbol: "BYBuddyTVOSCurrentVersion")
    private static let usesHomeViewSetupState = GuestSetupAssistantState.usesHomeViewPolicy(machine: GuestVirtualAudioProduct.machine())
    private static let usesTVSetupState = GuestSetupAssistantState.usesTVPolicy(machine: GuestVirtualAudioProduct.machine())

    private static func setupAssistantVersion(symbol name: String) -> Int? {
        let path = "/System/Library/PrivateFrameworks/SetupAssistant.framework/SetupAssistant"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, name)
        else { return nil }
        return Int(symbol.assumingMemoryBound(to: Int32.self).pointee)
    }

    private static func buddyValue(_ key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, buddyDomain as CFString, "mobile" as CFString, kCFPreferencesAnyHost)
    }

    private static var buddySetupVersion: Int? {
        (buddyValue("SetupVersion") as? NSNumber)?.intValue
    }

    private static var setupAssistantState: GuestSetupAssistantState {
        GuestSetupAssistantState(
            setupDone: buddyValue("SetupDone") as? Bool ?? false,
            version: usesHomeViewSetupState ? nil : usesTVSetupState ? (buddyValue("TVSetupVersion") as? NSNumber)?.intValue : buddySetupVersion,
            currentVersion: usesHomeViewSetupState ? nil : usesTVSetupState ? tvSetupAssistantCurrentVersion : setupAssistantCurrentVersion,
            requiresTVCompletion: usesTVSetupState,
            tvCompleted: usesTVSetupState && (buddyValue("TVBuddyCompletedSuccessfully") as? Bool == true),
            requiresHomeViewCompletion: usesHomeViewSetupState,
            forceNoBuddy: usesHomeViewSetupState && (buddyValue("ForceNoBuddy") as? Bool == true),
        )
    }

    /// Native preference policy, cheap enough for `/v1/health`. PineBoard
    /// requires the TV version and completion flag, not BYBuddyIOSCurrentVersion.
    static func setupAssistantPending() -> Bool { setupAssistantState.pending }

    private static func setupAssistantStatus() throws -> [String: Any] {
        let processes = try listProcesses(filter: "Setup")["processes"] as? [[String: Any]] ?? []
        let pid = processes.first { $0["executable"] as? String == "/Applications/Setup.app/Setup" }?["pid"]
        let state = setupAssistantState
        return [
            "pending": state.pending,
            "running": pid != nil,
            "pid": pid ?? 0,
            "setup_done": state.setupDone,
            "setup_version": state.version.map { $0 as Any } ?? NSNull(),
            "current_version": state.currentVersion.map { $0 as Any } ?? NSNull(),
            "data_migration_done": dataMigrationDone().map { $0 as Any } ?? NSNull(),
        ]
    }

    /// `kern.osversion`, the running build (`24A435`).
    static let systemBuildVersion: String? = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        let build = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return build.isEmpty ? nil : build
    }()

    /// Whether DataMigrator finished migrating for the running build; nil when
    /// that cannot be told. See `GuestFirstBootSettle.dataMigrationDone`.
    static func dataMigrationDone() -> Bool? {
        func value(_ key: String) -> Any? {
            CFPreferencesCopyValue(
                key as CFString, GuestFirstBootSettle.migrationDomain as CFString,
                "mobile" as CFString, kCFPreferencesAnyHost,
            )
        }
        let results = value(GuestFirstBootSettle.migrationResultsKey) as? [String: Any]
        return GuestFirstBootSettle.dataMigrationDone(
            build: systemBuildVersion,
            lastSystemVersion: value(GuestFirstBootSettle.migrationLastSystemVersionKey) as? String,
            lastResultsBuild: results?["buildVersion"] as? String,
            migratorRunning: dataMigratorRunning(),
        )
    }

    /// The process name is cut to `com.apple.datami`; the path is not.
    private static func dataMigratorRunning() -> Bool {
        let processes = (try? listProcesses(filter: "com.apple.datami"))?["processes"] as? [[String: Any]] ?? []
        return processes.contains { ($0["executable"] as? String)?.hasSuffix(GuestFirstBootSettle.dataMigratorSuffix) == true }
    }

    /// Marks setup finished for this iOS version and restarts SpringBoard.
    /// These three keys are all Setup needs: with every other key absent,
    /// SpringBoard starts to the Home Screen and no later panes appear.
    /// While data migration is still running SpringBoard has not decided yet
    /// and would ignore the restart, so it is not restarted; `respring` then
    /// says so.
    private static func skipSetupAssistant() throws -> [String: Any] {
        guard let current = setupAssistantCurrentVersion else {
            throw GuestAPIError.operationFailed("SetupAssistant.framework does not export BYBuddyIOSCurrentVersion")
        }
        let version = max(buddySetupVersion ?? 0, current)
        _ = try writePreference(domain: buddyDomain, key: "SetupDone", value: .bool(true))
        _ = try writePreference(domain: buddyDomain, key: "SetupFinishedAllSteps", value: .bool(true))
        _ = try writePreference(domain: buddyDomain, key: "SetupVersion", value: .int(Int64(version)))
        let springBoard: [String: Any]
        if dataMigrationDone() == false {
            springBoard = ["restarted": false, "reason": "data_migration_pending"]
        } else {
            do {
                springBoard = try respring()
            } catch let error as IcliError {
                // FrontBoard ignored the relaunch and launchd refused to stop
                // SpringBoard (status 144 on the guest). The keys are written;
                // asking again restarts it once FrontBoard takes the request.
                throw IcliError.commandFailed([
                    "error": "springboard_restart_failed",
                    "message": "Setup Assistant's keys are written, but SpringBoard did not restart: \(error.message)",
                    "reason": "busy",
                    "retryable": true,
                ])
            }
        }
        var status = try setupAssistantStatus()
        status["respring"] = springBoard
        return status
    }
}
