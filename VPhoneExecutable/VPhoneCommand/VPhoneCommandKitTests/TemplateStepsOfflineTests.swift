import ArgumentParser
import Foundation
import Testing
import VPhonePatchKit
@testable import VPhoneArchiveKit
@testable import VPhoneCommandKit
@testable import VPhoneCoreKit

/// The setup-boot report, the build finisher and the offline trimmer, as far
/// as they go without a guest or a mounted disk image.
struct TemplateSetupReportTests {
    private func lines(_ outcome: VPhoneTemplateSetupOutcome) -> [String] {
        var out: [String] = []
        VPhoneTemplateSetupRun.report(outcome) { out.append($0) }
        return out
    }

    @Test("an outcome with nothing to say reports the four fixed lines")
    func minimal() {
        #expect(lines(VPhoneTemplateSetupOutcome()) == [
            "[+] Setup boot done: ",
            "    snapshots deleted: none left",
            "    services: none",
            "    apps removed: none",
        ])
    }

    @Test("durations are listed in step order, rounded to seconds")
    func durations() {
        var outcome = VPhoneTemplateSetupOutcome()
        outcome.durations = [.stop: 4.6, .boot: 61.4, .settle: 0.4]
        #expect(lines(outcome).first == "[+] Setup boot done: boot 61 s, settle 0 s, stop 5 s")
    }

    @Test("a service profile shows its groups and owned count; apps and snapshots are listed")
    func full() {
        var outcome = VPhoneTemplateSetupOutcome()
        outcome.deletedSnapshots = ["orig-fs.disabled.rn-1", "orig-fs.disabled.rn-2"]
        outcome.serviceProfile = "trimmed"
        outcome.serviceGroups = ["accounts"]
        outcome.servicesOwned = 37
        outcome.apps = [
            VPhoneTemplateSetupAppResult(bundleID: "com.apple.b", status: "removed"),
            VPhoneTemplateSetupAppResult(bundleID: "com.apple.a", status: "absent"),
            VPhoneTemplateSetupAppResult(bundleID: "com.apple.kept", status: "failed", error: "busy"),
        ]
        let out = lines(outcome)
        #expect(out[1] == "    snapshots deleted: orig-fs.disabled.rn-1, orig-fs.disabled.rn-2")
        #expect(out[2] == "    services: trimmed +accounts (37 owned)")
        #expect(out[3] == "    apps removed: com.apple.a, com.apple.b")
        #expect(out.count == 4)
    }

    @Test("crash reports, retried unregistrations (sorted) and warnings come last, in that order")
    func extras() {
        var outcome = VPhoneTemplateSetupOutcome()
        outcome.clearedCrashReports = [
            "/p/Logs/CrashReporter/vphoned-2026-01-01-000000.ips",
            "/p/Logs/CrashReporter/vphoned-2026-01-02-000000.ips",
            "/p/Logs/CrashReporter/launchd-2026-01-01-000000.ips",
        ]
        outcome.apps = [
            VPhoneTemplateSetupAppResult(bundleID: "z.app", status: "removed", unregisterAttempts: 3),
            VPhoneTemplateSetupAppResult(bundleID: "a.app", status: "removed", unregisterAttempts: 2),
            VPhoneTemplateSetupAppResult(bundleID: "m.app", status: "removed", unregisterAttempts: 1),
        ]
        outcome.warnings = ["first", "second"]
        let out = lines(outcome)
        #expect(out.count == 8)
        #expect(out[4] == "    crash reports cleared: \(VPhoneTemplateSetupBoot.summarizeCrashReports(outcome.clearedCrashReports))")
        #expect(out[4].hasPrefix("    crash reports cleared: 3 crash report(s): "))
        #expect(out[5] == "    unregistered after retries: a.app (2 attempts), z.app (3 attempts)")
        #expect(out[6] == "    warning: first")
        #expect(out[7] == "    warning: second")
    }
}

private final class FinisherLab {
    let dir: TempDir
    let library: VPhoneLibrary

    init() throws {
        dir = try TempDir("finisher")
        library = VPhoneLibrary(root: dir.url.appendingPathComponent("machines"))
    }

    deinit { dir.cleanUp() }

    func key(slimming: VPhoneMachineTemplateSlimming = .none, diskSizeGB: UInt64 = 1) throws -> VPhoneMachineTemplateKey {
        let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
        return try VPhoneMachineTemplateKeys.key(
            device: "iPhone17,3", ios: OfflineFixtures.fixtureIOS, cloudOS: OfflineFixtures.fixtureCloudOS,
            preset: preset, diskSizeGB: diskSizeGB, slimming: slimming,
        )
    }

    /// A build in `.templates` whose machine records everything a finished
    /// `cfw install` leaves: restore-info with a variant, and the patch plan.
    func makeBuild(_ key: VPhoneMachineTemplateKey) throws -> VPhoneMachineTemplateBuild {
        let rom = dir.url.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let build = try VPhoneMachineTemplates.beginBuild(key, in: library)
        let bundle = try VPhoneBundleOperations.create(
            .init(name: key.identifier, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: build.library,
        )
        try VPhoneMachineTemplates.writeRecord(VPhoneMachineTemplateRecord(key: key), inBundle: bundle.url)
        try VPhoneRestoreInfo(
            ios: OfflineFixtures.fixtureIOS, cloudOS: OfflineFixtures.fixtureCloudOS, variant: "exp", device: "iPhone17,3",
        ).write(toBundle: bundle)
        let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
        let plan = try VPhoneMachineTemplateKeys.plan(
            preset: preset, iOSVersion: OfflineFixtures.fixtureIOS.version, cloudOSVersion: OfflineFixtures.fixtureCloudOS.version,
        )
        try VPhonePatchPresetStore.write(
            VPhoneVirtualMachinePatchPlan(
                plan: plan, iOSBase: VPhoneVersion(OfflineFixtures.fixtureIOS.version),
                cloudOS: VPhoneVersion(OfflineFixtures.fixtureCloudOS.version),
            ),
            forVM: bundle.url,
        )
        return build
    }
}

struct TemplateBuildFinisherTests {
    @Test("a build whose records give its key is frozen into .templates in one step")
    func freezes() throws {
        let lab = try FinisherLab()
        let key = try lab.key()
        let build = try lab.makeBuild(key)
        let template = try VPhoneTemplateBuildFinisher.freeze(build, key: key)
        #expect(template.identifier == key.identifier)
        #expect(template.record.frozen)
        #expect(template.record.key == key)
        #expect(template.url == VPhoneMachineTemplates.directory(in: lab.library).appendingPathComponent(key.identifier))
        #expect(!FileManager.default.fileExists(atPath: build.stagingURL.path))
        let found = try VPhoneMachineTemplates.template(for: key, in: lab.library)
        #expect(found?.record.build == template.record.build)
        #expect(template.record.build != nil)
    }

    @Test("a build whose records give another key than requested is refused, naming the field, and stays unfrozen")
    func keyMismatch() throws {
        let lab = try FinisherLab()
        let key = try lab.key()
        let build = try lab.makeBuild(key)
        let requested = try lab.key(diskSizeGB: 2)
        var text: String?
        do { _ = try VPhoneTemplateBuildFinisher.freeze(build, key: requested) } catch let error as ValidationError { text = error.message }
        #expect(text == "The built template's records give another key than requested (disk size: 2 GB → 1 GB).")
        #expect(FileManager.default.fileExists(atPath: build.bundleURL.path))
        #expect(try VPhoneMachineTemplates.template(for: key, in: lab.library) == nil)
    }

    @Test("a machine without a finished CFW install, restore versions or plan cannot be finished")
    func missingRecords() throws {
        let lab = try FinisherLab()
        let key = try lab.key()
        let build = try lab.makeBuild(key)
        func message() -> String? {
            do { try VPhoneTemplateBuildFinisher.requireRecordedKey(build, key: key) } catch let error as ValidationError { return error.message }
            catch { return "\(error)" }
            return nil
        }
        #expect(message() == nil)
        let plan = build.bundleURL.appendingPathComponent(VPhonePatchPresetStore.planFileName)
        let planData = try Data(contentsOf: plan)
        try FileManager.default.removeItem(at: plan)
        #expect(message() == "VM '\(key.identifier)' has no PatchPlan.plist: its boot chain is not described.")
        try planData.write(to: plan)

        // restore-info without a variant: the CFW install did not finish.
        let info = build.bundleURL.appendingPathComponent("restore-info.json")
        let infoData = try Data(contentsOf: info)
        try VPhoneRestoreInfo(ios: OfflineFixtures.fixtureIOS, cloudOS: OfflineFixtures.fixtureCloudOS)
            .write(toBundle: VPhoneBundle.load(at: build.bundleURL))
        #expect(message() == "VM '\(key.identifier)' has no completed CFW install, so it cannot be a template.")
        try FileManager.default.removeItem(at: info)
        #expect(message() == "VM '\(key.identifier)' has no completed CFW install, so it cannot be a template.")
        try infoData.write(to: info)
        #expect(message() == nil)
    }

    @Test("steps that fall short of the key, or leave a trim without its snapshot deletion, are not frozen")
    func stepsShortOfKey() throws {
        let lab = try FinisherLab()
        let slimmed = VPhoneMachineTemplateSlimming(setupBoot: true)
        let key = try lab.key(slimming: slimmed)
        let build = try lab.makeBuild(key)
        var thrown: (any Error)?
        do { _ = try VPhoneTemplateBuildFinisher.freeze(build, key: key) } catch { thrown = error }
        guard case let .stepsDoNotMatchKey(identifier, differences)? = thrown as? VPhoneMachineTemplateError else {
            Issue.record("expected stepsDoNotMatchKey, got \(String(describing: thrown))")
            return
        }
        #expect(identifier == key.identifier)
        #expect(differences.count == 1)
        #expect(differences.first?.contains("setup boot") == true)
        #expect(try VPhoneMachineTemplates.template(for: key, in: lab.library) == nil)

        // The setup boot recorded, but the trim's snapshot was not deleted.
        try VPhoneMachineTemplates.recordSteps(inBundle: build.bundleURL) { $0.setupDone = true }
        // The key promises no trim, so the steps now match and the template freezes.
        let template = try VPhoneTemplateBuildFinisher.freeze(build, key: key)
        #expect(template.record.steps.setupDone)
    }

    @Test("a trimmed key whose steps lack the snapshot deletion is incomplete")
    func trimWithoutSnapshotDeletion() throws {
        let lab = try FinisherLab()
        let key = try lab.key(slimming: VPhoneMachineTemplateSlimming(trimTier: "conservative/1", setupBoot: true))
        let build = try lab.makeBuild(key)
        try VPhoneMachineTemplates.recordSteps(inBundle: build.bundleURL) {
            $0.setupDone = true
            $0.trimTier = "conservative/1"
        }
        var thrown: (any Error)?
        do { _ = try VPhoneTemplateBuildFinisher.freeze(build, key: key) } catch { thrown = error }
        #expect(thrown as? VPhoneMachineTemplateError == .incomplete(identifier: key.identifier, problems: [
            "trim conservative/1 frees nothing while the guest's orig-fs snapshot exists; the setup boot deletes it (apfs.snapshot.delete)",
        ]))
        try VPhoneMachineTemplates.recordSteps(inBundle: build.bundleURL) { $0.snapshotDeleted = true }
        #expect(try VPhoneTemplateBuildFinisher.freeze(build, key: key).record.frozen)
    }
}

struct TemplateTrimmerOfflineTests {
    private func machine(_ lab: TempDir, name: String = "m") throws -> VPhoneBundle {
        try lab.makeBundle(name: name)
    }

    private func message(_ body: () throws -> Void) -> String? {
        do { try body() } catch let error as ValidationError { return error.message } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        return nil
    }

    @Test("a real tier on a machine whose Disk.img is not a plain file is refused before any disk is attached")
    func diskImageNotPlain() throws {
        let dir = try TempDir("trim")
        defer { dir.cleanUp() }
        let bundle = try machine(dir)
        var logged: [String] = []
        let disk = bundle.url.appendingPathComponent("Disk.img")
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
        #expect(message { _ = try VPhoneMachineTemplateTrimmer.trim(bundle, label: "m", spec: .standard, newRecord: nil) { logged.append($0) } }
            == "\(disk.path) is not a plain disk image file.")
        try FileManager.default.removeItem(at: disk)
        try Data("x".utf8).write(to: dir.url.appendingPathComponent("elsewhere.img"))
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: dir.url.appendingPathComponent("elsewhere.img"))
        #expect(message { _ = try VPhoneMachineTemplateTrimmer.trim(bundle, label: "m", spec: .standard, newRecord: nil) { logged.append($0) } }
            == "\(disk.path) is not a plain disk image file.")
        // Hard-linked: more than one link.
        try FileManager.default.removeItem(at: disk)
        try Data("x".utf8).write(to: disk)
        try FileManager.default.linkItem(at: disk, to: dir.url.appendingPathComponent("second.img"))
        #expect(message { _ = try VPhoneMachineTemplateTrimmer.trim(bundle, label: "m", spec: .standard, newRecord: nil) { logged.append($0) } }
            == "\(disk.path) is not a plain disk image file.")
        #expect(logged.isEmpty)
        #expect(try VPhoneMachineTemplates.readRecord(inBundle: bundle.url) == nil)
    }

    @Test("trim none deletes nothing and records the tier, creating the record the caller passed")
    func trimNone() throws {
        let dir = try TempDir("trim")
        defer { dir.cleanUp() }
        let bundle = try machine(dir)
        let key = try FinisherLab().key()
        var logged: [String] = []
        let result = try VPhoneMachineTemplateTrimmer.trim(
            bundle, label: "m", spec: .none, newRecord: VPhoneMachineTemplateRecord(key: key),
        ) { logged.append($0) }
        #expect(logged == ["[*] Trim none: nothing to delete"])
        #expect(result.entries.isEmpty)
        #expect(result.trim == "none")
        let recorded = try VPhoneMachineTemplates.readRecord(inBundle: bundle.url)
        let record = try #require(recorded)
        #expect(record.steps.trimTier == "none")
        #expect(!record.frozen)
        // Without a record to create, a plain machine is refused.
        let other = try machine(dir, name: "other")
        #expect(message { _ = try VPhoneMachineTemplateTrimmer.trim(other, label: "other", spec: .none, newRecord: nil) }
            == VPhoneMachineTemplateError.notBeingBuilt(path: other.url.path).description)
    }

    @Test("a frozen template, a template's clone and a narrowing trim are refused")
    func requireTrimmable() throws {
        let lab = try CreatorLab()
        let template = try lab.makeTemplate(lab.key())
        var thrown: (any Error)?
        do { try VPhoneMachineTemplateTrimmer.requireTrimmable(template.bundle(), label: "t", spec: .standard) } catch { thrown = error }
        #expect(thrown as? VPhoneMachineTemplateError == .frozen(identifier: template.identifier))

        let clone = try VPhoneMachineTemplates.cloneMachine(from: template, to: "clone", in: lab.library)
        do { try VPhoneMachineTemplateTrimmer.requireTrimmable(clone, label: "clone", spec: .standard) } catch { thrown = error }
        #expect(thrown as? VPhoneSystemTrimError == .clonedFromTemplate(machine: "clone", template: template.identifier))

        let plain = try lab.dir.makeBundle(name: "plain")
        try VPhoneMachineTemplates.writeRecord(VPhoneMachineTemplateRecord(key: lab.key()), inBundle: plain.url)
        try VPhoneMachineTemplates.recordSteps(inBundle: plain.url) { $0.trimTier = VPhoneSystemTrimSpec.standard.keyValue }
        let conservative = try VPhoneSystemTrimSpec(tier: .conservative)
        do { try VPhoneMachineTemplateTrimmer.requireTrimmable(plain, label: "plain", spec: conservative) } catch { thrown = error }
        #expect(thrown as? VPhoneSystemTrimError == .downgrade(
            machine: "plain", recorded: VPhoneSystemTrimSpec.standard.keyValue, requested: conservative.keyValue,
        ))
        // Widening from conservative is allowed, and the same tier again is too.
        try VPhoneMachineTemplates.recordSteps(inBundle: plain.url) { $0.trimTier = conservative.keyValue }
        try VPhoneMachineTemplateTrimmer.requireTrimmable(plain, label: "plain", spec: .standard)
        try VPhoneMachineTemplateTrimmer.requireTrimmable(plain, label: "plain", spec: conservative)
    }
}
