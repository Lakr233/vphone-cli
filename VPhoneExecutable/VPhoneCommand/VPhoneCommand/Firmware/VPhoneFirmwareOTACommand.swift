import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCommandKit
import VPhoneCoreKit
import VPhonePatchKit

/// Durable phases for Launchpad and other coordinators. Privilege remains in
/// the existing cfw install helper; this command never obtains root or restores
/// a guest. Starting/stopping is the coordinator's responsibility.
struct VPhoneFirmwareOTACommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ota",
        abstract: "Checkpoint, prepare, verify or roll back a data-preserving full OTA",
        discussion: """
        Sequence: capture (running), checkpoint (stopped), quiesce (running),
        prepare (stopped), cfw install (stopped, existing root helper), then
        complete (running). rollback requires a stopped machine and restores
        disk/SEP/NVRAM plus host configuration. A journal and one APFS snapshot
        are retained. Memory and network settings are preserved.
        """
    )

    enum Action: String, ExpressibleByArgument {
        case capture, checkpoint, isolate, quiesce, prepare, complete, commit, verify, rollback, status
    }
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument var action: Action
    @Argument var name: String
    @Option(help: "Pinned target build (capture; default 24A446)") var build: String?
    @Option(help: "Pinned target version (capture; default 27.0.1)") var version: String?
    @Option(name: .customLong("app"), help: "Protect this app's bundle, data and group containers (repeatable)")
    var apps: [String] = []
    @Option(help: "Target device IPSW, local path or HTTPS URL (prepare)") var iphoneSource: String?
    @Option(help: "Source-compatible cloudOS IPSW (prepare)") var cloudosSource: String?
    @Option(help: "Full OTA archive, local path or HTTPS URL (prepare)") var source: String?
    @Option(help: "Public AEA symmetric key; not persisted") var key: String?
    @Option(help: "Coordinator operation ID; every phase must match the captured owner") var operationID: String?
    @Flag(help: "Allow rollback of even a completed update, discarding subsequent guest writes") var force = false
    @Flag(help: "Explicitly discard writes after networking resumed; only for manual recovery with --force") var discardOnlineWrites = false

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let bundle = try lib.library.bundle(named: name)
        if let operationID {
            guard !operationID.isEmpty, operationID.count <= 64,
                  operationID.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains) else {
                throw ValidationError("Invalid coordinator operation ID.")
            }
        }
        try VPhoneOTAUpdate.withLock(of: bundle) {
            if action != .capture {
                try VPhoneOTAUpdate.requireOperation(operationID, record: VPhoneOTAUpdate.read(of: bundle))
            }
            switch action {
            case .capture: try capture(bundle)
            case .checkpoint: try VPhoneOTAUpdate.checkpoint(of: bundle)
            case .isolate: try VPhoneOTAUpdate.isolateNetwork(of: bundle)
            case .quiesce: try quiesce(bundle)
            case .prepare: try prepare(bundle)
            case .complete: try complete(bundle)
            case .commit:
                try verifyRemovedSystemApps(bundle, source: sourceState(VPhoneOTAUpdate.read(of: bundle)))
                try VPhoneOTAUpdate.commit(of: bundle)
            case .verify: try verifyCommitted(bundle)
            case .rollback:
                if try VPhoneOTAUpdate.read(of: bundle).phase == .completed, !force {
                    throw ValidationError("Completed OTA rollback discards later guest writes; pass --force to request it explicitly.")
                }
                guard !discardOnlineWrites || force else { throw ValidationError("--discard-online-writes also requires --force.") }
                try VPhoneOTAUpdate.rollback(of: bundle, discardOnlineWrites: discardOnlineWrites)
            case .status: break
            }
            let record = try VPhoneOTAUpdate.read(of: bundle)
            let result: [String: Any] = [
                "machine": name, "phase": record.phase.rawValue,
                "version": record.targetVersion, "build": record.targetBuild,
                "snapshot": record.snapshot, "journal": VPhoneOTAUpdate.directory(of: bundle).path,
                "operation_id": record.operationID.map { $0 as Any } ?? NSNull(),
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
    }

    private func call(_ bundle: VPhoneBundle, _ method: String, _ params: [String: Any] = [:], timeout: Int = 30) throws -> [String: Any] {
        try Self.guestCall(bundle, method, params, timeout: timeout, note: "Its OTA checkpoint is retained.")
    }

    /// One vphoned RPC over the VM process's control socket; `note` ends
    /// every error so the caller can say what state was left behind.
    static func guestCall(_ bundle: VPhoneBundle, _ method: String, _ params: [String: Any] = [:],
                          timeout: Int = 30, note: String) throws -> [String: Any] {
        do {
            return try VPhoneHostAutomationProbe.rpc(method, params: params,
                                                     socketPath: bundle.url.appendingPathComponent("vphone.sock").path,
                                                     timeout: timeout)
        } catch let error as VPhoneGuestCallError {
            let outcome = error.kind == .refused ? "Guest refused \(method)" : "Guest did not complete \(method)"
            throw ValidationError("\(outcome): \(error.message). \(note)")
        }
    }

    private func sourceState(_ record: VPhoneOTAUpdate.Record) throws -> [String: Any] {
        guard let state = try JSONSerialization.jsonObject(with: record.source) as? [String: Any] else {
            throw ValidationError("Invalid OTA source state.")
        }
        return state
    }

    /// The only target this path is qualified for; --version/--build default to it.
    static let qualifiedVersion = "27.0.1"
    static let qualifiedBuild = "24A446"

    private func capture(_ bundle: VPhoneBundle) throws {
        let build = build ?? Self.qualifiedBuild
        let version = version ?? Self.qualifiedVersion
        // An engine retry has the same operation ID. Reuse its source record,
        // never recapture a quiesced or partly migrated guest as the source.
        if let operationID, let existing = try? VPhoneOTAUpdate.read(of: bundle),
           existing.operationID == operationID, existing.targetBuild == build,
           existing.targetVersion == version, existing.phase != .rolledBack {
            return
        }
        guard version == Self.qualifiedVersion, build == Self.qualifiedBuild,
              let device = VPhoneGuestDevice.named(bundle.manifest.guestProductType ?? ""),
              device.family == .iPhone || device.family == .iPad else {
            throw ValidationError("This OTA path is qualified only for iPhone/iPad \(Self.qualifiedVersion) (\(Self.qualifiedBuild)).")
        }
        let info = try call(bundle, "device.info")
        guard info["model"] as? String == device.productType,
              (info["ios_version"] as? String)?.hasPrefix("26.") == true else {
            throw ValidationError("Capture needs a responsive configured iPhone/iPad on iOS 26.")
        }
        let setup = try call(bundle, "setup.status")
        let migration = try call(bundle, "settings.get", ["domain": "com.apple.migration"])
        guard Self.sourceFinishedMigration(setup: setup, migration: migration) else {
            throw ValidationError("The source guest has not successfully finished migration and Setup Assistant.")
        }
        let profile = try call(bundle, "services.profile")
        let disabled = try call(bundle, "services.disabled")
        try requireMigrationServices(profile: profile, disabled: disabled)
        let autoLock = try call(bundle, "display.auto_lock")
        guard autoLock["auto_lock_seconds"] as? Int != nil else {
            throw ValidationError("Cannot capture the source Auto-Lock policy.")
        }
        var protected: [[String: Any]] = []
        for id in Set(apps).sorted() {
            let app = try call(bundle, "apps.info", ["bundle_id": id])
            let entitlements = app["entitlements"] as? [String: Any] ?? [:]
            guard app["bundle_id"] as? String == id, let dataPath = app["data_path"] as? String else {
                throw ValidationError("\(id) has no data container to protect.")
            }
            // 27 selects the data container by this entitlement, not by the
            // signing identifier 26 used. It must name the existing container,
            // which for a legacy re-signed app is not its bundle ID.
            let metadata = try call(bundle, "files.plist", ["path": dataPath + "/.com.apple.mobile_container_manager.metadata.plist"])
            let container = (metadata["plist"] as? [String: Any])?["MCMMetadataIdentifier"] as? String
            guard let required = entitlements["com.apple.private.security.container-required"] as? String,
                  !required.isEmpty, required == container else {
                throw ValidationError("\(id) lacks a container-required entitlement naming its existing data container (\(container ?? "unknown")). Normalize its signing policy before OTA; no app is silently re-signed.")
            }
            protected.append(app)
        }
        let restore = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.url.appendingPathComponent("restore-info.json")))
        let removed = try VPhoneOTAUpdate.removedSystemAppIDs(call(bundle, "apps.removed_system"))
        let state: [String: Any] = ["device": info, "profile": profile, "auto_lock": autoLock,
                                   "apps": protected, "restore": restore, "removed_system_apps": removed]
        var record = VPhoneOTAUpdate.Record(bundle: bundle, build: build, version: version,
                                           source: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]))
        record.operationID = operationID
        try VPhoneOTAUpdate.capture(record, of: bundle)
    }

    private func quiesce(_ bundle: VPhoneBundle) throws {
        var record = try VPhoneOTAUpdate.read(of: bundle)
        guard record.phase == .checkpointed || record.phase == .quiesced else {
            throw ValidationError("Quiesce needs a completed stopped checkpoint first.")
        }
        guard record.networkIsolated == true, bundle.manifest.networkConfig.mode == .off else {
            throw ValidationError("Stop the source and run fw ota isolate before quiescing it.")
        }
        let source = try sourceState(record)
        let old = source["device"] as? [String: Any] ?? [:]
        let current = try call(bundle, "device.info")
        guard current["ios_version"] as? String == old["ios_version"] as? String else {
            throw ValidationError("The source OS changed since capture.")
        }
        let result = try call(bundle, "services.profile.apply", ["profile": "none", "force": true])
        guard (result["failed"] as? [[String: Any]])?.isEmpty == true else {
            throw ValidationError("Could not re-enable every profile-owned migration dependency; roll back the checkpoint.")
        }
        let profile = try call(bundle, "services.profile")
        try requireMigrationServices(profile: profile, disabled: call(bundle, "services.disabled"))
        record.phase = .quiesced
        try VPhoneOTAUpdate.write(record, of: bundle)
    }

    private func prepare(_ original: VPhoneBundle) throws {
        guard let iphoneSource, let cloudosSource, let source else {
            throw ValidationError("prepare requires --iphone-source, --cloudos-source and --source (full OTA).")
        }
        let record = try VPhoneOTAUpdate.read(of: original)
        if record.phase == .prepared { return }
        guard record.networkIsolated == true, original.manifest.networkConfig.mode == .off else {
            throw ValidationError("OTA preparation requires the saved source network to remain isolated.")
        }
        let state = try sourceState(record)
        let restore = state["restore"] as? [String: Any] ?? [:]
        let cloud = restore["cloudOS"] as? [String: String] ?? [:]
        let resolved = try VPhoneFirmwarePreparer.resolveSources(iPhoneSource: iphoneSource, cloudOSSource: cloudosSource,
                                                                 device: original.manifest.guestProductType)
        guard resolved.phone.build == record.targetBuild, resolved.phone.version == record.targetVersion,
              resolved.cloud.build == cloud["build"], resolved.cloud.version == cloud["version"] else {
            throw ValidationError("Target IPSW must match the pinned OTA; cloudOS must remain at the source build.")
        }
        let full = try VPhoneFirmwarePreparer.resolveOTA(source, key: key, device: resolved.device,
                                                        build: record.targetBuild,
                                                        ipswCacheDirectory: VPhoneResources.ipswCacheDirectory(),
                                                        downloadConnections: VPhoneIPSWCache.defaultDownloadConnections)
        try VPhoneOTAUpdate.beginPreparation(of: original)
        let resources = VPhoneResources.resolve()
        // Both ROMs load the existing guest's personalized boot/SEP firmware.
        // Their old bytes and configuration are in the OTA host checkpoint.
        var bundle = try VPhoneBundleOperations.installBootROM(from: resources.base.appendingPathComponent("OpenAVB/OpenAVB.bin"), in: original)
        bundle = try VPhoneBundleOperations.installSEPROM(from: resources.base.appendingPathComponent("OpenSEP/OpenSEP.bin"), in: bundle)
        var selection = VPhonePatchPresetStore.selection(forVM: bundle.url)
        selection.blockedPatches.removeAll { $0 == FirmwareGuestSystemPatchSet.otaUserland }
        selection.allowedPatches = Set(selection.allowedPatches + [FirmwareGuestSystemPatchSet.otaUserland]).sorted()
        try VPhonePatchPresetStore.write(selection, forVM: bundle.url)
        try VPhoneFirmwarePreparer.prepare(iPhoneSource: iphoneSource, cloudOSSource: cloudosSource,
                                           device: bundle.manifest.guestProductType, bundle: bundle, resources: resources)
        let libraryArguments = lib.libraryRoot.map { ["--library-root", $0] } ?? []
        // ArgumentParser's wrappers, including optional/defaulted properties,
        // are definitions until parsed; a default initializer is not a command.
        let patch = try VPhoneFirmwarePatchCommand.parse([name] + libraryArguments)
        try patch.run()
        var stageArguments = [name, "--build", record.targetBuild, "--source", full.file.path] + libraryArguments
        if let key = full.key { stageArguments += ["--key", key] }
        let stage = try VPhoneFirmwareOTAStageCommand.parse(stageArguments)
        try stage.run()
        var updated = try VPhoneOTAUpdate.read(of: bundle)
        updated.phase = .prepared
        try VPhoneOTAUpdate.write(updated, of: bundle)
    }

    private func complete(_ bundle: VPhoneBundle) throws {
        var record = try VPhoneOTAUpdate.read(of: bundle)
        guard [.prepared, .installed, .completed].contains(record.phase) else {
            throw ValidationError("No prepared OTA to verify.")
        }
        guard record.networkIsolated == true, bundle.manifest.networkConfig.mode == .off else {
            throw ValidationError("Offline verification requires the guest network to remain isolated until commit.")
        }
        let setup = try requireTargetMigration(bundle, record)
        // Never move a completed journal back: rollback of a completed update
        // must keep requiring --force when a repeated complete fails later.
        if record.phase == .prepared {
            record.phase = .installed
            try VPhoneOTAUpdate.write(record, of: bundle)
        }
        let source = try sourceState(record)
        var appParams: [String: Any] = ["force": true]
        if let removed = source["removed_system_apps"] as? [String] { appParams["removed_bundle_ids"] = removed }
        let systemApps = try call(bundle, "ota.apps.apply", appParams, timeout: 180)
        guard systemApps["pending"] as? Int == 0,
              (systemApps["removed_pending"] as? [String])?.isEmpty == true else {
            throw ValidationError("Retained Apple app programs have not finished updating.")
        }
        try verifyRemovedSystemApps(bundle, source: source)
        for app in source["apps"] as? [[String: Any]] ?? [] {
            guard let id = app["bundle_id"] as? String else { throw ValidationError("Invalid protected app record.") }
            try requireUnchanged(bundle, app: app, id: id, fields: ["bundle_path", "data_path", "group_containers", "version", "build"]) {
                "\(id) changed \($0) during OTA; its checkpoint is retained."
            }
        }
        if setup["pending"] as? Bool == true || setup["running"] as? Bool == true {
            _ = try call(bundle, "setup.skip", ["force": true])
            throw ValidationError("Migration succeeded; Setup Assistant was dismissed. Wait for SpringBoard, then retry complete.")
        }
        let oldLock = source["auto_lock"] as? [String: Any] ?? [:]
        guard let seconds = oldLock["auto_lock_seconds"] as? Int else {
            throw ValidationError("Source Auto-Lock was not captured.")
        }
        func autoLockRestored() throws -> Bool {
            try call(bundle, "display.auto_lock")["auto_lock_seconds"] as? Int == seconds
        }
        func requestAutoLock() throws {
            _ = try call(bundle, "display.auto_lock.set", ["seconds": seconds])
        }
        if try !autoLockRestored() {
            if record.autoLockRestorationRequested != true {
                try requestAutoLock()
                record.autoLockRestorationRequested = true
                try VPhoneOTAUpdate.write(record, of: bundle)
            }
            // profiled publishes the effective file asynchronously. The next
            // complete retries its read, never assuming a successful tap was
            // a successful policy change.
            if try !autoLockRestored(), record.autoLockRebootRequested != true {
                _ = try call(bundle, "system.reboot", ["force": true])
                record.autoLockRebootRequested = true
                try VPhoneOTAUpdate.write(record, of: bundle)
                throw ValidationError("Auto-Lock was selected but profiled had not converged; reboot requested. Retry complete after vphoned reconnects.")
            }
            if try !autoLockRestored() {
                try requestAutoLock()
            }
            guard try autoLockRestored() else {
                throw ValidationError("Settings is restoring Auto-Lock; its effective policy has not converged. Retry complete after profiled settles.")
            }
        }
        let profile = source["profile"] as? [String: Any] ?? [:]
        let saved = profile["record"] as? [String: Any] ?? [:]
        let result = try call(bundle, "services.profile.apply", [
            "profile": saved["profile"] ?? "none", "groups": saved["groups"] ?? [], "allow": saved["allow"] ?? [], "force": true,
        ])
        guard (result["failed"] as? [[String: Any]])?.isEmpty == true else {
            throw ValidationError("Migration passed but the saved service profile could not be restored.")
        }
        for app in source["apps"] as? [[String: Any]] ?? [] {
            guard let id = app["bundle_id"] as? String else { continue }
            let launched = try call(bundle, "apps.launch", ["bundle_id": id])
            guard launched["frontmost_verified"] as? Bool == true else {
                throw ValidationError("Protected app \(id) did not reach the foreground after OTA.")
            }
        }
        record.phase = .completed
        try VPhoneOTAUpdate.write(record, of: bundle)
    }

    /// The running target's version and this boot's migration result;
    /// returns setup.status, which complete still needs.
    private func requireTargetMigration(_ bundle: VPhoneBundle, _ record: VPhoneOTAUpdate.Record) throws -> [String: Any] {
        let info = try call(bundle, "device.info")
        let migration = try call(bundle, "settings.get", ["domain": "com.apple.migration"])
        let setup = try call(bundle, "setup.status")
        try VPhoneOTAUpdate.requireMigration(version: record.targetVersion, build: record.targetBuild,
                                             actualVersion: info["ios_version"] as? String,
                                             migrationDone: setup["data_migration_done"] as? Bool,
                                             result: Self.migrationResult(migration))
        return setup
    }

    /// The protected app's current `apps.info` must match its captured
    /// values for every field; `message` names the first that differs.
    private func requireUnchanged(_ bundle: VPhoneBundle, app: [String: Any], id: String, fields: [String],
                                  message: (String) -> String) throws {
        let current = try call(bundle, "apps.info", ["bundle_id": id])
        for field in fields where !NSDictionary(dictionary: ["v": current[field] ?? NSNull()])
            .isEqual(to: ["v": app[field] ?? NSNull()]) {
            throw ValidationError(message(field))
        }
    }

    static func migrationResult(_ reply: [String: Any]) -> [String: Any]? {
        let values = reply["values"] as? [String: Any]
        return (values?["DMLastMigrationResults"] as? [String: Any])?["value"] as? [String: Any]
    }

    /// The source gate shared by capture and ota-preflight: an unknown
    /// migration result is not success.
    static func sourceFinishedMigration(setup: [String: Any], migration: [String: Any]) -> Bool {
        setup["data_migration_done"] as? Bool == true
            && migrationResult(migration)?["success"] as? Bool == true
            && setup["pending"] as? Bool == false
    }

    private func verifyCommitted(_ bundle: VPhoneBundle) throws {
        let record = try VPhoneOTAUpdate.read(of: bundle)
        guard record.phase == .committed else { throw ValidationError("OTA networking has not been committed.") }
        let original = try VPhoneOTAUpdate.sourceManifest(of: bundle)
        guard bundle.manifest.networkConfig == original.networkConfig,
              bundle.manifest.cpuCount == original.cpuCount, bundle.manifest.memorySize == original.memorySize else {
            throw ValidationError("OTA changed the source network, CPU or memory configuration.")
        }
        _ = try requireTargetMigration(bundle, record)
        let state = try sourceState(record)
        try verifyRemovedSystemApps(bundle, source: state)
        for app in state["apps"] as? [[String: Any]] ?? [] {
            guard let id = app["bundle_id"] as? String else { continue }
            try requireUnchanged(bundle, app: app, id: id, fields: ["bundle_path", "data_path", "group_containers"]) {
                "Committed app \(id) changed \($0); target data was retained."
            }
            guard try call(bundle, "apps.launch", ["bundle_id": id])["frontmost_verified"] as? Bool == true else {
                throw ValidationError("Committed app \(id) could not reach the foreground; target data was retained.")
            }
        }
    }

    private func verifyRemovedSystemApps(_ bundle: VPhoneBundle, source: [String: Any]) throws {
        let inventory = try call(bundle, "apps.removed_system")
        // Legacy journals lack this baseline. Still reject any remaining
        // placeholders backed by a removal record; never remove an installed
        // app just because a historical backup exists.
        let ids = try source["removed_system_apps"] as? [String]
            ?? VPhoneOTAUpdate.removedSystemAppIDs(inventory)
        try VPhoneOTAUpdate.requireRemovedSystemApps(ids, inventory: inventory)
    }

    /// Services DataMigrator needs that a trimmed source may have disabled.
    static let migrationDependencies = [
        "com.apple.siriactionsd", "com.apple.assistantd", "com.apple.SpringBoard",
        "com.apple.backboardd", "com.apple.runningboardd", "com.apple.mobile.installd",
        "com.apple.lsd", "com.apple.lsd.system", "com.apple.containermanagerd", "com.apple.containermanagerd.system",
    ]

    /// Migration dependencies disabled by an override the service profile
    /// does not own, so neither quiesce nor the profile may re-enable them.
    static func externallyDisabledDependencies(profile: [String: Any], disabled: [String: Any]) -> [String] {
        let owned = Set((profile["record"] as? [String: Any])?["labels"] as? [String] ?? [])
        let overrides = disabled["disabled"] as? [String: Bool] ?? [:]
        return migrationDependencies.filter { overrides[$0] == true && !owned.contains($0) }.sorted()
    }

    private func requireMigrationServices(profile: [String: Any], disabled: [String: Any]) throws {
        let blocked = Self.externallyDisabledDependencies(profile: profile, disabled: disabled)
        guard blocked.isEmpty else {
            throw ValidationError("User-owned service overrides block migration: \(blocked.joined(separator: ", ")). They were left unchanged.")
        }
    }
}
