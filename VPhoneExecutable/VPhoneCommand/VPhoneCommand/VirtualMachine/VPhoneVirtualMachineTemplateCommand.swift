import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit

// MARK: - Command group

struct VPhoneVirtualMachineTemplateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: "Manage machine templates (vm create clones new machines from them)",
        discussion: """
        A template is a complete machine that never boots, kept in <library>/.templates/<id>. \
        vm create clones a new machine from the template whose key matches what it was asked \
        for, with a new identity, in a fraction of a second and almost no disk space: the clone \
        shares every block it does not change with the template. The key is the guest device, \
        the iOS and cloudOS builds, the patch preset and the boot-chain patches it resolves to, \
        the bundle series, the disk size and what was trimmed. CPU, memory, screen and network \
        are not part of it; they are set on each clone.

        Every machine cloned from one template shares its SEP root secret and the keys of its \
        Data volume. Create a machine with --no-template when it needs keys of its own.

        A template is never listed by vm list and cannot be booted: a boot would write state \
        every later clone inherits. Before it is frozen it gets one setup boot (vm template setup): \
        Setup skipped, first-boot work finished, system apps and services slimmed, then a clean \
        shutdown, so every clone starts at the Lock Screen.
        """,
        subcommands: [
            VPhoneVirtualMachineTemplateListCommand.self,
            VPhoneVirtualMachineTemplateShowCommand.self,
            VPhoneVirtualMachineTemplateFindCommand.self,
            VPhoneVirtualMachineTemplateSetupCommand.self,
            VPhoneVirtualMachineTemplateAdoptCommand.self,
            VPhoneVirtualMachineTemplateTrimCommand.self,
            VPhoneVirtualMachineTemplateDeleteCommand.self,
        ],
    )
}

// MARK: - Report

/// One template as `list --json` and `show --json` print it.
struct VPhoneMachineTemplateReport: Encodable {
    var id: String
    var path: String
    var key: VPhoneMachineTemplateKey
    var created: Date
    var builtWithBundleVersion: String?
    var bootChainBundleVersion: String?
    var sourceMachine: String?
    var steps: VPhoneMachineTemplateSteps
    var diskSizeBytes: Int64
    /// What the template's files take on disk (`st_blocks`): what deleting
    /// it frees once no machine shares its blocks.
    var allocatedBytes: UInt64
    /// Machines cloned from this build of it (their `TemplateSource.plist`),
    /// sorted. Machines cloned from an earlier template with the same key
    /// are not listed: they share none of its blocks.
    var machines: [String]
    var stale: Bool
    var staleReasons: [String]
    /// The IPSW sources it was built from, when its build named them.
    var sources: VPhoneMachineTemplateSources?
    /// The build's UUID, copied into each clone's `TemplateSource.plist`;
    /// nil for a template frozen before builds were recorded.
    var build: String?
    var frozenAt: Date?

    init(_ template: VPhoneMachineTemplate, usage: [String: [String]]) {
        let record = template.record
        id = record.identifier
        path = template.url.path
        key = record.key
        created = record.created
        builtWithBundleVersion = record.builtWithBundleVersion
        bootChainBundleVersion = record.bootChainBundleVersion
        sourceMachine = record.sourceMachine
        steps = record.steps
        diskSizeBytes = (try? template.bundle().diskSizeBytes) ?? 0
        allocatedBytes = VPhoneMachineTemplates.allocatedBytes(of: template.url)
        machines = usage[template.identifier] ?? []
        staleReasons = VPhoneMachineTemplateKeys.staleReasons(template)
        stale = !staleReasons.isEmpty
        sources = record.sources
        build = record.build
        frozenAt = record.frozenAt
    }
}

struct VPhoneMachineTemplateStagingReport: Encodable {
    var name: String
    var path: String
    var id: String?
    var active: Bool
}

struct VPhoneMachineTemplateListReport: Encodable {
    var templates: [VPhoneMachineTemplateReport]
    var building: [VPhoneMachineTemplateStagingReport]
    var damaged: [[String: String]]
}

private func encodeJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try String(decoding: encoder.encode(value), as: UTF8.self)
}

// MARK: - list

struct VPhoneVirtualMachineTemplateListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List templates")

    @OptionGroup var lib: VPhoneLibraryOption
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let listing = try VPhoneMachineTemplates.list(in: lib.library)
        let usage = VPhoneMachineTemplates.usage(in: lib.library)
        let reports = listing.templates.map { VPhoneMachineTemplateReport($0, usage: usage) }
        if json {
            try print(encodeJSON(VPhoneMachineTemplateListReport(
                templates: reports,
                building: listing.staging.map {
                    VPhoneMachineTemplateStagingReport(name: $0.name, path: $0.url.path, id: $0.identifier, active: $0.isActive)
                },
                damaged: listing.damaged.map { ["name": $0.name, "reason": $0.reason] },
            )))
            return
        }
        if reports.isEmpty, listing.staging.isEmpty, listing.damaged.isEmpty {
            print("No templates in \(VPhoneMachineTemplates.directory(in: lib.library).path).")
            return
        }
        for report in reports {
            let state = report.stale ? "  STALE" : ""
            print("\(report.id)  \(report.key.summary)\(state)")
            print("    \(VPhoneSystemTrim.formatBytes(report.allocatedBytes)) on disk; "
                + "machines using it: \(report.machines.isEmpty ? "none" : report.machines.joined(separator: ", "))")
            for reason in report.staleReasons {
                print("    stale: \(reason)")
            }
        }
        for staging in listing.staging {
            print("\(staging.name)  \(staging.isActive ? "building" : "unfinished; vm template delete \(staging.name) removes it")")
        }
        for skip in listing.damaged {
            print("\(skip.name)  damaged: \(skip.reason)")
        }
    }
}

// MARK: - show

struct VPhoneVirtualMachineTemplateShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one template")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "template id (or a unique prefix of at least 4 digits)") var id: String
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let report = try VPhoneMachineTemplateReport(
            VPhoneMachineTemplates.template(id, in: lib.library),
            usage: VPhoneMachineTemplates.usage(in: lib.library),
        )
        if json {
            try print(encodeJSON(report))
            return
        }
        let key = report.key
        print("id:        \(report.id)")
        print("path:      \(report.path)")
        print("device:    \(key.device)")
        print("iOS:       \(key.iOSVersion) (\(key.iOSBuild))")
        print("cloudOS:   \(key.cloudOSVersion) (\(key.cloudOSBuild))")
        print("preset:    \(key.patchPreset)  boot chain \(key.bootChainPlanDigest.prefix(12))")
        print("bundle:    series \(key.bundleSeries), boot chain \(report.bootChainBundleVersion ?? "unknown"), "
            + "built with \(report.builtWithBundleVersion ?? "unknown")")
        print("disk:      \(key.diskSizeGB) GB, \(VPhoneSystemTrim.formatBytes(report.allocatedBytes)) on disk")
        print("machines:  \(report.machines.isEmpty ? "none" : report.machines.joined(separator: ", "))")
        print("slimming:  \(key.slimming.summary)")
        if !key.slimming.removedApps.isEmpty {
            print("removed:   \(key.slimming.removedApps.joined(separator: ","))")
        }
        print("steps:     snapshot deleted \(report.steps.snapshotDeleted ? "yes" : "no"), setup done \(report.steps.setupDone ? "yes" : "no")")
        let retried = report.steps.unregisterAttempts.sorted { $0.key < $1.key }
        if !retried.isEmpty {
            print("retried:   \(retried.map { "\($0.key) unregistered after \($0.value) attempts" }.joined(separator: ", "))")
        }
        print("created:   \(report.created.formatted(.iso8601))")
        if let frozenAt = report.frozenAt {
            print("frozen:    \(frozenAt.formatted(.iso8601))\(report.build.map { ", build \($0)" } ?? "")")
        }
        if let source = report.sourceMachine {
            print("source:    \(source)")
        }
        print("state:     \(report.stale ? "stale" : "current")")
        for reason in report.staleReasons {
            print("  \(reason)")
        }
    }
}

// MARK: - find

/// What `find --json` prints. `resolved` is false when neither the IPSWs nor
/// a template's recorded sources give the builds, and then only `reason`
/// follows.
struct VPhoneMachineTemplateFindReport: Encodable {
    var resolved = false
    /// `ipsw` (read from the IPSWs, local or cached) or `template` (taken
    /// from a template built from the same sources).
    var resolvedBy: String?
    var id: String?
    var summary: String?
    var key: VPhoneMachineTemplateKey?
    /// The template with this key, current or stale.
    var template: VPhoneMachineTemplateReport?
    /// True when `template` is there and current: `vm create --template`
    /// with `id` clones from it.
    var usable = false
    /// A create is building this key right now.
    var building = false
    var reason: String?
}

struct VPhoneVirtualMachineTemplateFindCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find the template a vm create with these options would clone from",
        discussion: """
        Resolves the template key the way vm create does, without downloading anything or \
        changing the library, and reports whether that template exists and is current. The \
        builds come from the IPSWs when they are local files or in the IPSW cache; otherwise \
        from a template whose record says it was built from the same two sources, so a key \
        still resolves after its IPSWs were deleted. When neither works the key is unresolved \
        and a create would download the IPSWs.

        --block and --allow are the per-patch overrides fw set-patches records; a machine \
        built with them has a boot-chain digest of its own.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String
    @Option(help: "Directory for downloaded IPSWs (default: ~/.vphone/ipsws or $VPHONE_ROOT/ipsws)")
    var ipswCache: String?
    @Option(help: ArgumentHelp("Guest device, when the IPSW covers several models", valueName: "product-type"))
    var device: String?
    @Option(name: .customLong("preset"), help: "Patch preset name or preset plist path (default: the guest's, as vm create)") var preset: String?
    @Option(name: .shortAndLong, help: "Disk size (GB, default 64)") var diskSize: UInt64?
    @Option(name: .customLong("block"), help: ArgumentHelp("A patch the preset turns on, turned off", valueName: "id"))
    var blocked: [String] = []
    @Option(name: .customLong("allow"), help: ArgumentHelp("A patch the preset leaves off, turned on", valueName: "id"))
    var allowed: [String] = []
    @OptionGroup(title: "Template slimming") var slimming: VPhoneTemplateSlimmingOptions
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        if let device, VPhoneGuestDevice.named(device) == nil {
            throw ValidationError("vphone runs \(VPhoneGuestDevice.known.map(\.productType).joined(separator: ", ")) guests, not \(device).")
        }
        let wanted = try slimming.resolve()
        guard wanted.problems.isEmpty else {
            throw ValidationError("No template can be built with this slimming: \(wanted.problems.joined(separator: "; ")).")
        }
        let library = lib.library
        var report = VPhoneMachineTemplateFindReport()
        if let builds = try resolveBuilds(in: library, report: &report) {
            let key = try VPhoneMachineTemplateKeys.key(
                device: builds.device,
                ios: builds.ios,
                cloudOS: builds.cloudOS,
                preset: VPhonePatchPresetStore.resolve(preset ?? VPhoneGuestDevice.defaultPresetIdentifier(for: VPhoneGuestDevice.named(device ?? builds.device))).preset,
                blocked: blocked,
                allowed: allowed,
                diskSizeGB: diskSize ?? 64,
                slimming: wanted,
            )
            report.resolved = true
            report.id = key.identifier
            report.summary = key.summary
            report.key = key
            let listing = try VPhoneMachineTemplates.list(in: library)
            report.building = listing.staging.contains { $0.identifier == key.identifier && $0.isActive }
            if let template = try VPhoneMachineTemplates.template(for: key, in: library) {
                let found = VPhoneMachineTemplateReport(template, usage: VPhoneMachineTemplates.usage(in: library))
                report.template = found
                report.usable = !found.stale
            }
        }
        if json {
            try print(encodeJSON(report))
            return
        }
        guard report.resolved, let id = report.id else {
            print("unresolved: \(report.reason ?? "unknown")")
            return
        }
        print("key:       \(id)  \(report.summary ?? "")")
        print("builds:    from \(report.resolvedBy == "ipsw" ? "the IPSWs" : "a template built from the same sources")")
        if let template = report.template {
            print("template:  \(template.id)  \(template.stale ? "STALE" : "current"), "
                + "\(VPhoneSystemTrim.formatBytes(template.allocatedBytes)) on disk")
            for reason in template.staleReasons {
                print("  stale: \(reason)")
            }
        } else {
            print("template:  none\(report.building ? " (a create is building it)" : "")")
        }
    }

    /// The device and builds, from the IPSWs when they are here, else from a
    /// template built from the same sources; nil with `report.reason` set.
    private func resolveBuilds(in library: VPhoneLibrary, report: inout VPhoneMachineTemplateFindReport) throws -> VPhoneMachineTemplateBuilds? {
        let cache = ipswCache.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? VPhoneResources.ipswCacheDirectory()
        guard let builds = try VPhoneMachineTemplateKeys.resolveBuilds(
            iPhoneSource: iphoneSource,
            cloudOSSource: cloudosSource,
            cache: cache,
            device: device,
            in: library,
        ) else {
            report.reason = VPhoneMachineTemplates.unresolvedBuildsReason
            return nil
        }
        report.resolvedBy = builds.origin.rawValue
        return builds
    }
}

// MARK: - setup

struct VPhoneVirtualMachineTemplateSetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Boot a VM (or an unfinished template build) once to finish it as a template",
        discussion: """
        Boots the target once without a window and, through vphoned, in this order: deletes the \
        orig-fs APFS snapshot CFW install left, skips Setup Assistant, waits for first-boot work \
        to settle, removes the system apps, applies the service profile (its sign-in follow-up \
        group included), reboots, checks the result (no snapshot, Setup done, no profile service \
        running, the apps gone, vphoned answering), clears the device name the boot pinned and \
        shuts the guest down cleanly. Every step has a deadline; a failed step stops the VM and \
        records nothing.

        A VM: stop it first (a machine Launchpad created sits at Setup after its first boot; that \
        is fine), and trim it with vm template trim beforehand: the snapshot deletion here is what \
        frees the trimmed files, and this boot trims nothing. --trim, when given, must match the \
        tier vm template trim recorded. Then vm template adopt <name> freezes it with what this \
        recorded. An app that will not go is reported and left out of the template's key.

        --strict: anything short of the requested slimming, an app vphoned does not remove above \
        all, fails the setup boot and records nothing, instead of being reported and left out of \
        the key. Use it when the machine is to be adopted under a key worked out beforehand \
        (vm template find, then vm template adopt --expect), as Launchpad does.

        A .building-… name from vm template list: a vm create whose template build failed. Its \
        key fixes the slimming, so switches that disagree are refused, every app must go (strict \
        whether --strict is given or not), and on success the template is frozen and vm create \
        uses it.

        Slimming: --slim off skips the app removal and the service profile; the setup boot still \
        skips Setup and deletes the snapshot, so a trim recorded before it is kept.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name, or a .building-… name from vm template list") var target: String
    @OptionGroup var slimming: VPhoneTemplateSlimmingOptions
    @Flag(help: "Show the VM window while it boots") var window = false
    @Flag(help: "Fail instead of warning when the setup boot falls short of the requested slimming (an app not removed)")
    var strict = false
    @Flag(name: .customShort("v"), help: "Increase verbosity: -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        // Each step's line as it starts, also through a pipe (Launchpad).
        setvbuf(stdout, nil, _IOLBF, 0)
        let library = lib.library
        let resources = VPhoneResources.resolve()
        let verbosity = VPhoneVerbosity(count: verboseCount)
        if target.hasPrefix(".building-") {
            try finishBuild(in: library, resources: resources, verbosity: verbosity)
        } else {
            try setUpMachine(in: library, resources: resources, verbosity: verbosity)
        }
    }

    /// A machine of the library, to be adopted afterwards.
    private func setUpMachine(in library: VPhoneLibrary, resources: VPhoneResources, verbosity: VPhoneVerbosity) throws {
        let bundle = try library.bundle(named: target)
        try VPhoneMachineTemplates.requireBootable(bundleURL: bundle.url)
        try VPhoneBundleActivity.requireStopped(bundle)
        var wanted = try slimming.resolve()
        // The setup boot trims nothing. A machine is trimmed beforehand by
        // vm template trim, which records its tier; this boot's snapshot
        // deletion is what frees it. --trim here only states what the caller
        // expects that record to say.
        let trimmed = try VPhoneMachineTemplates.readRecord(inBundle: bundle.url)?.steps.trimTier ?? "none"
        let request = try slimming.request
        if request.trimTier != nil || request.keepLanguages != nil, wanted.trimTier != trimmed {
            throw ValidationError(
                "\(target) is trimmed \(trimmed), not \(wanted.trimTier). The setup boot trims nothing: "
                    + "stop it and run vm template trim \(target) first, or leave --trim out.",
            )
        }
        if trimmed == "none" {
            print("note: \(target) is not trimmed; vm template trim \(target) before this boot frees about 1.2 GB")
        }
        wanted.trimTier = trimmed
        // Checked before booting: a machine adopt would refuse is not worth it.
        let recorded = try VPhoneMachineTemplateKeys.recorded(bundle)
        wanted = try VPhoneMachineTemplateKeys.fitted(wanted, toIOSVersion: recorded.key.iOSVersion)
        if let snapshots = try? VPhoneMachineSnapshots.list(of: bundle), !snapshots.isEmpty {
            print("warning: \(target) has \(snapshots.count) snapshot(s); vm template adopt refuses it until they are deleted")
        }
        if try VPhoneMachineTemplates.readRecord(inBundle: bundle.url) == nil {
            try VPhoneMachineTemplates.writeRecord(
                VPhoneMachineTemplateRecord(
                    key: recorded.key,
                    builtWithBundleVersion: VPhoneBundleVersion.current(),
                    bootChainBundleVersion: recorded.bootChainBundleVersion,
                    sourceMachine: target,
                ),
                inBundle: bundle.url,
            )
        }
        try VPhoneTemplateSetupRun.run(
            bundleURL: bundle.url,
            plan: VPhoneTemplateSetupPlan(slimming: wanted, requiresEveryApp: strict),
            launcher: VPhoneHostPreflight.check(),
            resources: resources,
            headless: !window,
            verbosity: verbosity,
        )
        print("freeze it into a template with: vphone-cli vm template adopt \(target)")
    }

    /// An unfinished template build: set up to its key, then frozen.
    private func finishBuild(in library: VPhoneLibrary, resources: VPhoneResources, verbosity: VPhoneVerbosity) throws {
        guard let staging = try VPhoneMachineTemplates.list(in: library).staging.first(where: { $0.name == target }),
              let identifier = staging.identifier
        else {
            throw VPhoneMachineTemplateError.notFound(target)
        }
        let lock = try VPhoneMachineTemplates.lock(identifier, in: library, wait: false)
        defer { lock.release() }
        let build = VPhoneMachineTemplateBuild(identifier: identifier, stagingURL: staging.url)
        guard let record = try VPhoneMachineTemplates.readRecord(inBundle: build.bundleURL) else {
            throw VPhoneMachineTemplateError.notBeingBuilt(path: build.bundleURL.path)
        }
        let request = try slimming.request
        if !request.isEmpty {
            let wanted = try VPhoneMachineTemplateKeys.fitted(slimming.resolve(), toIOSVersion: record.key.iOSVersion)
            guard wanted == record.key.slimming else {
                throw ValidationError("\(target) is built to its key: \(record.key.slimming.summary). Leave the slimming switches out.")
            }
        }
        if record.steps.trimTier != record.key.slimming.trimTier {
            // The build stopped in or before its offline trim: finish that
            // first, as vm create would have, before the snapshot goes.
            try VPhoneMachineTemplateTrimmer.trim(
                VPhoneBundle.load(at: build.bundleURL),
                label: target,
                spec: VPhoneSystemTrimSpec(keyValue: record.key.slimming.trimTier),
                newRecord: nil,
            )
        }
        if !record.steps.setupDone {
            try VPhoneTemplateSetupRun.run(
                bundleURL: build.bundleURL,
                plan: VPhoneTemplateSetupPlan(slimming: record.key.slimming, requiresEveryApp: true),
                launcher: VPhoneHostPreflight.check(),
                resources: resources,
                headless: !window,
                verbosity: verbosity,
            )
        }
        let template = try VPhoneTemplateBuildFinisher.freeze(build, key: record.key)
        print("[+] Template \(template.identifier) frozen at \(template.url.path)")
    }

}

// MARK: - adopt

struct VPhoneVirtualMachineTemplateAdoptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Freeze a stopped, newly created VM into a template",
        discussion: """
        Moves the VM's folder into <library>/.templates/<id>: it leaves vm list, can no longer \
        boot, and vm create clones new machines from it. Its key is read from its records \
        (restore-info.json, PatchPlan.plist, config.plist and the disk). Adopt a machine straight \
        after creating it: whatever it has done since its first boot, every clone inherits.

        Refused while the VM runs, while it has snapshots, or when a template with its key \
        exists. --force adopts a machine whose boot chain was built by another bundle series \
        than this vphone-cli's, or whose patch receipt differs from its plan; such a template \
        is listed as stale.

        --iphone-source and --cloudos-source record the IPSWs the machine was created from, \
        so vm template find resolves a request from the same sources after they are deleted.

        --expect <id> refuses, and leaves the machine where it is, unless the key its records \
        give has that identifier: the one vm template find printed for the request the machine \
        was built for. A template under another identifier would never be found by that request. \
        The refusal names the fields that differ when the expected key is known (a template or \
        build in the library has it, or it differs only in slimming, as when an app was not \
        removed); with --json it is also printed to stdout as an object with adopted false, \
        the computed id and the expected one.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String
    @Flag(help: "adopt even when the template would be stale") var force = false
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or path the machine was created from") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or path the machine was created from") var cloudosSource: String?
    @Option(help: ArgumentHelp("Refuse unless the template's identifier is this one (from vm template find)", valueName: "id"))
    var expect: String?
    @Flag(name: .shortAndLong, help: "Emit the new template as JSON (as vm template show --json)") var json = false

    func validate() throws {
        if (iphoneSource == nil) != (cloudosSource == nil) {
            throw ValidationError("Give both --iphone-source and --cloudos-source, or neither.")
        }
        if let expect, !VPhoneMachineTemplateKey.isIdentifier(expect.lowercased()) {
            throw ValidationError("--expect takes a template identifier of \(VPhoneMachineTemplateKey.identifierLength) hex digits, not \(expect).")
        }
    }

    func run() throws {
        // With --json, progress goes to stderr and stdout carries the report.
        let say: (String) -> Void = json
            ? { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            : { print($0) }
        let bundle = try lib.library.bundle(named: name)
        try VPhoneBundleActivity.requireStopped(bundle)
        let previous = try VPhoneMachineTemplates.readRecord(inBundle: bundle.url)
        let steps = previous?.steps ?? VPhoneMachineTemplateSteps()
        let recorded = try VPhoneMachineTemplateKeys.recorded(bundle, slimming: steps.slimming)
        if let expect, recorded.key.identifier != expect.lowercased(),
           let mismatch = recorded.key.mismatch(expecting: expect, known: knownKeys())
        {
            if json {
                try print(encodeJSON(VPhoneMachineTemplateAdoptRefusal(mismatch, steps: steps)))
            }
            throw mismatch
        }
        var problems: [String] = []
        let series = VPhoneMachineTemplateKeys.currentSeries
        if recorded.key.bundleSeries != series {
            problems.append("its boot chain was built by bundle series \(recorded.key.bundleSeries); this vphone-cli is \(series)")
        }
        if !recorded.drift.isEmpty {
            problems.append("its patch receipt differs from its plan: \(recorded.drift.joined(separator: ", "))")
        }
        if !problems.isEmpty {
            guard force else {
                throw ValidationError("VM '\(name)' would be a stale template: \(problems.joined(separator: "; ")). Pass --force to adopt it anyway.")
            }
            for problem in problems {
                say("warning: \(problem)")
            }
        }
        let sources = iphoneSource.flatMap { phone in
            cloudosSource.map { VPhoneMachineTemplateSources(iPhone: phone, cloudOS: $0) }
        }
        let record = VPhoneMachineTemplateRecord(
            key: recorded.key,
            created: previous?.created ?? Date(),
            builtWithBundleVersion: VPhoneBundleVersion.current(),
            bootChainBundleVersion: recorded.bootChainBundleVersion,
            sourceMachine: name,
            steps: steps,
            sources: sources ?? previous?.sources,
        )
        if let tree = VPhoneMachineTemplates.restoreTree(of: bundle) {
            say("[*] Removing the restore tree \(tree)/: a template never keeps it")
        }
        let template = try VPhoneMachineTemplates.adopt(machineNamed: name, in: lib.library, record: record)
        if json {
            try print(encodeJSON(VPhoneMachineTemplateReport(template, usage: VPhoneMachineTemplates.usage(in: lib.library))))
            return
        }
        print("adopted \(name) as template \(template.identifier)")
        print("  \(template.key.summary)")
        print("create machines from it with: vphone-cli vm create <name> --template \(template.identifier)")
    }

    /// The keys of the library's templates and builds, to name the one an
    /// `--expect` identifier stands for.
    private func knownKeys() -> [VPhoneMachineTemplateKey] {
        guard let listing = try? VPhoneMachineTemplates.list(in: lib.library) else { return [] }
        let builds = listing.staging.compactMap { staging -> VPhoneMachineTemplateKey? in
            guard let identifier = staging.identifier else { return nil }
            let url = staging.url.appendingPathComponent(identifier, isDirectory: true)
            return (try? VPhoneMachineTemplates.readRecord(inBundle: url))?.key
        }
        return listing.templates.map(\.key) + builds
    }
}

/// What `adopt --expect <id> --json` prints when it refuses.
struct VPhoneMachineTemplateAdoptRefusal: Encodable {
    var adopted = false
    var error = "unexpected_template"
    var message: String
    /// The identifier the machine's records give.
    var id: String
    var expected: String
    var key: VPhoneMachineTemplateKey
    /// The key `expected` stands for, when known.
    var expectedKey: VPhoneMachineTemplateKey?
    var differences: [String]
    var canonicalDescription: String
    var steps: VPhoneMachineTemplateSteps

    init(_ mismatch: VPhoneMachineTemplateKeyMismatch, steps: VPhoneMachineTemplateSteps) {
        message = mismatch.description
        id = mismatch.identifier
        expected = mismatch.expected
        key = mismatch.key
        expectedKey = mismatch.expectedKey
        differences = mismatch.differences
        canonicalDescription = mismatch.key.canonicalDescription
        self.steps = steps
    }
}

// MARK: - trim

struct VPhoneVirtualMachineTemplateTrimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trim",
        abstract: "Delete a trim tier's files from a stopped machine that is being built into a template",
        discussion: """
        Attaches the machine's Disk.img, mounts its guest System volume read-write (no root \
        needed), deletes the tier's files and records the trim in its Template.plist, so \
        vm template adopt keys the template by it. The target is a stopped VM of the library \
        that will be adopted, or a .building-… folder from vm template list that no build holds.

        Tiers: none; conservative (usr/standalone/update); standard (conservative, plus the \
        AirPods/Beats pairing assets, the watch faces, and the linguistic data of languages not \
        kept: --keep-languages, default en,zh-Hans,zh; English is always kept). aggressive is \
        reserved and refused.

        The deleted files stay allocated until the guest deletes its orig-fs snapshot during \
        the template's setup boot, and a trimmed template is frozen only after that. Trimming \
        cannot be undone: a machine already trimmed only takes the same trim again or a heavier \
        one after conservative. Refused for a running machine, a frozen template, and a machine \
        cloned from a template.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name, or a .building-… name from vm template list") var target: String
    @Option(help: "Trim tier: none | conservative | standard") var tier = "standard"
    @Option(help: ArgumentHelp("Languages whose linguistic data the standard tier keeps", valueName: "en,zh-Hans,zh"))
    var keepLanguages: String?
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let spec = try VPhoneSystemTrimSpec.parse(tier: tier, keptLanguages: keepLanguages)
        let library = lib.library
        let bundle: VPhoneBundle
        var newRecord: VPhoneMachineTemplateRecord?
        if target.hasPrefix(".building-") {
            guard let staging = try VPhoneMachineTemplates.list(in: library).staging.first(where: { $0.name == target }),
                  let identifier = staging.identifier
            else {
                throw VPhoneMachineTemplateError.notFound(target)
            }
            guard !staging.isActive else {
                throw VPhoneMachineTemplateError.busy(identifier: identifier)
            }
            bundle = try VPhoneBundle.load(at: staging.url.appendingPathComponent(identifier, isDirectory: true))
        } else {
            bundle = try library.bundle(named: target)
            if try VPhoneMachineTemplates.readRecord(inBundle: bundle.url) == nil {
                // Resolved before anything is deleted: a machine without a
                // finished CFW install or its records cannot become a template.
                let recorded = try VPhoneMachineTemplateKeys.recorded(bundle)
                newRecord = VPhoneMachineTemplateRecord(
                    key: recorded.key,
                    builtWithBundleVersion: VPhoneBundleVersion.current(),
                    bootChainBundleVersion: recorded.bootChainBundleVersion,
                    sourceMachine: target,
                )
            }
        }
        let result = try VPhoneMachineTemplateTrimmer.trim(
            bundle,
            label: target,
            spec: spec,
            newRecord: newRecord,
            log: { line in
                if json {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                } else {
                    print(line)
                }
            },
        )
        if json {
            try print(encodeJSON(result))
        }
    }
}

// MARK: - delete

struct VPhoneVirtualMachineTemplateDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a template or an unfinished template build",
        discussion: """
        Machines cloned from the template keep working: they share its blocks but do not refer \
        to it. The space those shared blocks take is freed only when no clone uses them either. \
        A local Time Machine snapshot taken while the template existed keeps its blocks until \
        the snapshot expires.

        --json prints what was deleted and the machines that used it; it needs --force.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "template id (or unique prefix), or a .building-… name from vm template list") var id: String
    @Flag(name: .shortAndLong, help: "Do not prompt") var force = false
    @Flag(name: .shortAndLong, help: "Emit the result as JSON (needs --force)") var json = false

    func validate() throws {
        if json, !force {
            throw ValidationError("--json does not prompt: pass --force with it.")
        }
    }

    func run() throws {
        let library = lib.library
        if !force {
            // A damaged template has no summary to show, and is deleted all the same.
            let what = (try? VPhoneMachineTemplates.template(id, in: library)).map { "template \($0.identifier) (\($0.key.summary))" }
                ?? "'\(id)'"
            print("Delete \(what)? [y/N] ", terminator: "")
            guard (readLine() ?? "").lowercased() == "y" else {
                print("Canceled. Nothing was deleted.")
                return
            }
        }
        // Who uses it, read before it goes: the note depends on it.
        let identifier = (try? VPhoneMachineTemplates.template(id, in: library).identifier) ?? id
        let machines = id.hasPrefix(".building-") ? [] : VPhoneMachineTemplates.usage(in: library)[identifier] ?? []
        let removed = try VPhoneMachineTemplates.delete(id, in: library)
        let note = VPhoneMachineTemplates.deletionNote(machines: machines)
        if json {
            try print(encodeJSON(VPhoneMachineTemplateDeleteReport(
                deleted: removed.lastPathComponent,
                path: removed.path,
                machines: machines,
                blocksFreed: machines.isEmpty,
                note: note,
            )))
            return
        }
        print("deleted \(removed.lastPathComponent)")
        print("note: \(note)")
    }
}

/// What `vm template delete --json` prints.
struct VPhoneMachineTemplateDeleteReport: Encodable {
    /// The template identifier or `.building-…` name removed.
    var deleted: String
    var path: String
    /// The machines that used the template when it was deleted; their shared
    /// blocks stay allocated until they change them or are deleted.
    var machines: [String]
    /// True when no machine used it, so its blocks are freed, unless a local
    /// Time Machine snapshot keeps them until it expires.
    var blocksFreed: Bool
    /// The same note the text output prints.
    var note: String
}
