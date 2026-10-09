import Darwin
import Foundation
import Observation

/// `vm create`, one command at a time.
///
/// `vphone-cli vm create` runs the same stages in one process and asks for
/// sudo partway through, which a GUI cannot answer. Running the stages here
/// keeps every step visible and retryable, and keeps root to the one step
/// that needs it: `cfw install`, run by the helper. The waits mirror
/// VPhoneVirtualMachineCreator: the device identity file, 90 recovery probes,
/// up to 30 seconds for the post-restore panic, 5 seconds before CFW, and up
/// to 300 seconds for vphoned to answer on first boot.
///
/// By default the machine is cloned from a template (`VPhoneLaunchpadCreationPlan`
/// lists the steps). A template that is missing is built first in a
/// temporary machine of the same library, by the same restore steps, then
/// `vm template trim`, `vm template setup` and `vm template adopt`. The
/// helper's root surface stays `cfw install`: it runs on that temporary
/// machine before it is adopted, and the trim, the setup boot and the adopt
/// run as the user. The setup boot's `vphone-vm` is started by `vphone-cli`,
/// a child of Launchpad like the DFU boot, not through the launcher, so it
/// is Launchpad's responsibility while it runs, headless.
///
/// The template is built with the boot-chain patch overrides only. Guest
/// patch overrides are recorded on the clone with `fw set-patches` and
/// written by `cfw update-environment`, through the helper like `cfw
/// install`, before its first boot.
@MainActor
@Observable
final class VPhoneLaunchpadCreationPipeline {
    typealias Step = VPhoneLaunchpadCreationStep

    struct Options: Sendable {
        var name: String
        /// The canonical library the machine is created in.
        var libraryRoot: String
        /// The installed Core Bundle every step runs with. The machine is
        /// bound to it once `vm new` has made its folder.
        var bundleVersion: String
        var iphoneSource: String
        var cloudOSSource: String
        /// The model `fw prepare --device` picks from an IPSW that covers
        /// several, such as the 13-inch iPad; nil takes the first.
        var device: String?
        var cpuCount: Int
        var memoryMB: Int
        var diskSizeGB: Int
        var network: String
        /// The preset and per-patch overrides the boot chain is built with.
        var patches: VPhoneLaunchpadPatchSelection
        /// The overrides of `patches` the guest half of an install writes,
        /// as the bundle's catalog places them.
        var guestPatches: Set<String> = []
        var keepArtifacts: Bool
        /// Clone the machine from a template (built first when missing).
        /// Off restores the machine on its own, with SEP and Data volume keys
        /// of its own.
        var usesTemplate = true
        var slimming = VPhoneLaunchpadSlimming()

        var machine: VPhoneLaunchpadMachinePath {
            VPhoneLaunchpadMachinePath(libraryRoot: libraryRoot, name: name)
        }

        var patchOverrides: VPhoneLaunchpadPatchOverrides {
            VPhoneLaunchpadPatchOverrides(
                preset: patches.preset,
                blocked: patches.blocked,
                allowed: patches.allowed,
                guestPatches: guestPatches,
            )
        }

        /// The template key's options: the boot-chain overrides only.
        var templateRequest: VPhoneLaunchpadTemplateCommands.Request {
            VPhoneLaunchpadTemplateCommands.Request(
                iphoneSource: iphoneSource,
                cloudOSSource: cloudOSSource,
                device: device,
                preset: patches.preset,
                blocked: patchOverrides.bootChainBlocked,
                allowed: patchOverrides.bootChainAllowed,
                diskSizeGB: diskSizeGB,
                slimming: slimming,
            )
        }
    }

    let options: Options
    private(set) var plan: VPhoneLaunchpadCreationPlan
    private(set) var statuses: [Step: VPhoneLaunchpadStatus] = [:]
    private(set) var durations: [Step: TimeInterval] = [:]
    private(set) var current: Step?
    /// How far the IPSW `fw prepare` is downloading has come, while one is
    /// downloading. Each of the two IPSWs counts from zero; a cached one and
    /// a Core Bundle that reports no progress leave it nil.
    private(set) var downloadFraction: Double?
    /// The setup boot's own step while it runs (`b. wait for first-boot
    /// work`), from its `[setup]` lines.
    private(set) var setupStage: String?
    /// The template the machine is cloned from, once found or adopted.
    private(set) var template: VPhoneLaunchpadTemplate?
    private(set) var templateID: String?
    /// The id Find Template computed for these options, which the adopt
    /// must save the build under.
    private(set) var expectedTemplateID: String?
    /// True when this creation built the template it cloned from, rather
    /// than finding one.
    private(set) var builtTemplate = false
    /// The creation log. The sheet shows it in a terminal; the model keeps
    /// only the last few lines, for error details.
    private let log: VPhoneLaunchpadLogWriter
    private(set) var failure: VPhoneLaunchpadError?
    private(set) var isRunning = false

    private let bundles: VPhoneLaunchpadCoreBundle
    private let helper: VPhoneLaunchpadHelperClient
    private weak var library: VPhoneLaunchpadMachineLibrary?
    private var task: Task<Void, Never>?
    private var dfu: VPhoneLaunchpadChildProcess?
    private var dfuPanicked = false

    init(
        options: Options,
        bundles: VPhoneLaunchpadCoreBundle,
        helper: VPhoneLaunchpadHelperClient,
        library: VPhoneLaunchpadMachineLibrary,
    ) {
        self.options = options
        plan = VPhoneLaunchpadCreationPlan(
            name: options.name,
            buildName: options.usesTemplate ? VPhoneLaunchpadCreationPlan.newBuildName() : nil,
            slimming: options.slimming,
            appliesGuestPatches: options.usesTemplate && options.patchOverrides.hasGuestOverrides,
        )
        self.bundles = bundles
        self.helper = helper
        self.library = library
        log = VPhoneLaunchpadLogWriter(url: VPhoneLaunchpadMachineLibrary.consoleLog(options.machine, suffix: "-create"))
    }

    var logFile: URL {
        log.url
    }

    /// The machine asked for.
    var machine: VPhoneLaunchpadMachinePath {
        options.machine
    }

    /// The temporary machine a template is built in, while this creation
    /// may build one.
    var buildMachine: VPhoneLaunchpadMachinePath? {
        plan.buildName.map { VPhoneLaunchpadMachinePath(libraryRoot: options.libraryRoot, name: $0) }
    }

    var steps: [Step] {
        plan.steps
    }

    var isFinished: Bool {
        statuses[.firstBoot] == .passed
    }

    func status(_ step: Step) -> VPhoneLaunchpadStatus {
        statuses[step] ?? .pending
    }

    /// The step a retry starts from: the one that failed.
    var failedStep: Step? {
        steps.first { statuses[$0] == .failed }
    }

    /// The machine a step works on.
    private func path(for step: Step) -> VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: options.libraryRoot, name: plan.machineName(for: step))
    }

    /// `fw patch`, as both the step's log line and the run build it. One array so
    /// the command the sheet shows cannot drift from the command that runs.
    private func patchArguments(_ name: String) -> [String] {
        ["fw", "patch", name] + options.patches.presetArguments
    }

    private var deviceArguments: [String] {
        options.device.map { ["--device", $0] } ?? []
    }

    func command(for step: Step) -> String {
        let name = plan.machineName(for: step)
        let template = templateID ?? "<id>"
        return switch step {
        case .findTemplate: VPhoneLaunchpadTemplateCommands.find(options.templateRequest).joined(separator: " ")
        case .create: "vm new \(name) --cpu \(options.cpuCount) --memory \(options.memoryMB) --disk-size \(options.diskSizeGB)"
        case .prepare: (["fw", "prepare", name] + deviceArguments).joined(separator: " ")
        case .patch: patchArguments(name).joined(separator: " ")
        case .bootDFU: "vm launch \(name) --dfu"
        case .waitDFU: "recovery-probe --ecid …"
        case .restore: "restore \(name)"
        case .stopDFU: "vm stop \(name)"
        case .installCFW: "cfw install \(name)"
        case .trimTemplate: (VPhoneLaunchpadTemplateCommands.trim(name, options.slimming) ?? []).joined(separator: " ")
        case .setUpTemplate: VPhoneLaunchpadTemplateCommands.setup(name, options.slimming).joined(separator: " ")
        case .adoptTemplate: "vm template adopt \(name) --json --iphone-source … --cloudos-source …"
            + (expectedTemplateID.map { " --expect \($0)" } ?? "")
        case .cloneTemplate: VPhoneLaunchpadTemplateCommands.clone(
                name, template: template, cpuCount: options.cpuCount, memoryMB: options.memoryMB, network: options.network,
            ).joined(separator: " ")
        case .applyGuestPatches: VPhoneLaunchpadTemplateCommands.setPatches(name, options.patchOverrides, includingGuest: true)
            .joined(separator: " ") + "; cfw update-environment \(name)"
        case .firstBoot: "vm launch \(name)"
        }
    }

    // MARK: - Control

    func start(from first: Step? = nil) {
        guard !isRunning, let first = first ?? steps.first else {
            return
        }
        failure = nil
        // Find again decides what follows it.
        if first <= .findTemplate {
            plan.foundTemplate = nil
            templateID = nil
            expectedTemplateID = nil
            template = nil
            builtTemplate = false
        }
        for step in Step.allCases where step >= first {
            statuses[step] = .pending
            durations[step] = nil
        }
        isRunning = true
        task = Task { await run(from: first) }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(from first: Step) async {
        defer {
            isRunning = false
            current = nil
            downloadFraction = nil
            setupStage = nil
            dfu?.terminate()
            dfu = nil
        }
        var next: Step? = first
        while let step = next {
            current = step
            statuses[step] = .running
            let began = Date()
            do {
                // `vm launch --dfu` needs the bundle's policy exception and
                // AMFI admission, so the version is checked before any step
                // runs. A failure shows on the step that was about to run.
                if step == first {
                    try await prepareBundle()
                }
                try await perform(step)
                try Task.checkCancellation()
                statuses[step] = .passed
                durations[step] = Date().timeIntervalSince(began)
            } catch {
                statuses[step] = .failed
                durations[step] = Date().timeIntervalSince(began)
                if error is CancellationError || Task.isCancelled {
                    failure = VPhoneLaunchpadError(String(localized: "\(step.title) was cancelled."))
                } else {
                    failure = error as? VPhoneLaunchpadError
                        ?? VPhoneLaunchpadError(String(localized: "\(step.title) failed."), detail: error.localizedDescription)
                }
                append("✕ \(failure?.message ?? step.title)")
                if let detail = failure?.detail, plan.buildsTemplate(step) || step == .findTemplate || step == .cloneTemplate || step == .applyGuestPatches {
                    append("  \(detail.replacingOccurrences(of: "\n", with: "\n  "))")
                }
                await library?.refresh()
                return
            }
            // Read after the step: Find Template decides what follows.
            next = plan.step(after: step)
        }
        if !options.keepArtifacts, !plan.usesTemplate {
            await removeRestoreFiles()
        }
        append("● \(options.name) is ready.")
    }

    /// Removes the `iPhone*_Restore` tree once the machine has booted, as
    /// `cfw install` does without `--keep-artifacts`. Only a real folder is
    /// removed; a link by that name is left alone. A failure here does not
    /// fail the creation. A template build needs none of this: adopting it
    /// removes the tree.
    private func removeRestoreFiles() async {
        let bundle = machine.url
        let lines = await Task.detached { () -> [String] in
            let manager = FileManager.default
            let entries = (try? manager.contentsOfDirectory(atPath: bundle.path)) ?? []
            var lines: [String] = []
            for name in entries where name.hasPrefix("iPhone") && name.hasSuffix("_Restore") {
                let url = bundle.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values?.isDirectory == true, values?.isSymbolicLink == false else {
                    continue
                }
                do {
                    try manager.removeItem(at: url)
                    lines.append("removed restore files \(name)/ to save space")
                } catch {
                    lines.append("warning: could not remove \(name)/: \(error.localizedDescription)")
                }
            }
            return lines
        }.value
        lines.forEach(append)
    }

    private func append(_ line: String) {
        log.write(line)
    }

    // MARK: - Steps

    /// Checks the machine's Core Bundle once per Launchpad session; later
    /// runs return at once.
    private func prepareBundle() async throws {
        let version = options.bundleVersion
        if !bundles.isChecked(version) {
            append("checking Core Bundle \(version)")
        }
        try await bundles.prepare(version)
    }

    private func perform(_ step: Step) async throws {
        let version = options.bundleVersion
        guard let commandLine = bundles.commandLine(version: version) else {
            throw VPhoneLaunchpadError(String(localized: "VPhone.bundle \(version) is not installed."))
        }
        let target = path(for: step)
        let name = target.name
        let library = target.libraryArguments
        let bundle = target.url
        let log = log
        let output: @Sendable (String) -> Void = { line in log.write(line) }

        func run(
            _ arguments: [String],
            onLine: @escaping @Sendable (String) -> Void = output,
            onProgress: (@Sendable (Double) -> Void)? = nil,
        ) async throws {
            onLine("$ \(VPhoneLaunchpadCommandLine.display(arguments))")
            try await commandLine.runChecked(arguments, onLine: onLine, onProgress: onProgress)
        }

        // For the template steps: a failure names the step and carries the
        // line `vphone-cli` ended with, which says why.
        func runReporting(
            _ arguments: [String],
            onLine: @escaping @Sendable (String) -> Void = output,
        ) async throws -> VPhoneLaunchpadCommandResult {
            onLine("$ \(VPhoneLaunchpadCommandLine.display(arguments))")
            let result = try await commandLine.run(arguments, onLine: onLine)
            try Task.checkCancellation()
            guard result.succeeded else {
                let reason = VPhoneLaunchpadTemplateCommands.failureLine(result.lines)
                throw VPhoneLaunchpadError(
                    String(localized: "\(step.title) failed."),
                    detail: [reason, result.tail].compactMap(\.self).joined(separator: "\n\n"),
                )
            }
            return result
        }

        switch step {
        case .findTemplate:
            try await findTemplate(runReporting)

        case .create:
            try await run(["vm", "new", name, "--cpu", String(options.cpuCount),
                           "--memory", String(options.memoryMB), "--disk-size", String(options.diskSizeGB)] + library)
            // The folder exists now. Every later command, here and after
            // creation, runs with the version recorded in it.
            do {
                try self.library?.bind(target, VPhoneLaunchpadMachineBinding(bundle: version, bootChain: version))
            } catch {
                throw VPhoneLaunchpadError(
                    String(localized: "Unable to record the Core Bundle of \(name)."),
                    detail: error.localizedDescription,
                )
            }
            // A template keeps the default network; its clone gets this one.
            if options.network != "nat", !plan.usesTemplate {
                try await run(["vm", "config", name, "--network", options.network] + library)
            }
            await self.library?.refresh()

        case .prepare:
            // Progress arrives on the reader thread and may land after the
            // step has moved on, so only the firmware step takes it. A finished
            // download clears it: extraction follows with no progress of its own.
            defer { downloadFraction = nil }
            try await run(["fw", "prepare", name, "--iphone-source", options.iphoneSource,
                           "--cloudos-source", options.cloudOSSource] + deviceArguments + library,
                          onProgress: { [weak self] fraction in
                              Task { @MainActor in
                                  guard let self, self.current == .prepare else { return }
                                  self.downloadFraction = fraction < 1 ? fraction : nil
                              }
                          })

        case .patch:
            // The preset rides on `fw patch` itself; per-patch overrides are
            // recorded first, the way `vm config` follows `vm new` above. Both
            // lines reach the log. The creation log starts over on a retry, so
            // the patch output is also kept in a log of its own for later
            // diagnosis.
            let patchLog = VPhoneLaunchpadLogWriter(url: VPhoneLaunchpadMachineLibrary.consoleLog(target, suffix: "-patch"))
            patchLog.write("# \(name), \(Date().formatted(.iso8601)), Core Bundle \(version)")
            let tee: @Sendable (String) -> Void = { line in
                log.write(line)
                patchLog.write(line)
            }
            // A template build takes the boot-chain overrides only: they are
            // what its key holds. The guest ones go to the clone.
            let overrides = options.patchOverrides
            let includesGuest = !plan.usesTemplate
            if includesGuest ? options.patches.hasOverrides : overrides.hasBootChainOverrides {
                try await run(
                    VPhoneLaunchpadTemplateCommands.setPatches(name, overrides, includingGuest: includesGuest) + library,
                    onLine: tee,
                )
            }
            try await run(patchArguments(name) + library, onLine: tee)

        case .bootDFU:
            let arguments = ["vm", "launch", name, "--dfu"] + library
            append("$ \(VPhoneLaunchpadCommandLine.display(arguments))")
            dfuPanicked = false
            dfu = try commandLine.start(
                arguments,
                logFile: VPhoneLaunchpadMachineLibrary.consoleLog(target, suffix: "-dfu"),
            ) { [weak self] line in
                log.write("dfu  \(line)")
                if Self.isPanic(line) {
                    Task { @MainActor in self?.dfuPanicked = true }
                }
            }
            let identity = bundle.appendingPathComponent("udid-prediction.txt")
            for _ in 0 ..< 30 {
                if FileManager.default.fileExists(atPath: identity.path) {
                    return
                }
                try requireDFURunning()
                try await Task.sleep(for: .seconds(1))
            }
            throw VPhoneLaunchpadError(String(localized: "The machine did not enter DFU mode within 30 seconds."))

        case .waitDFU:
            let ecid = try Self.ecid(in: bundle)
            append("$ vphone-cli recovery-probe --ecid \(ecid) --timeout 2  (up to 90 attempts)")
            for attempt in 1 ... 90 {
                try Task.checkCancellation()
                try requireDFURunning()
                let result = try await commandLine.run(
                    ["recovery-probe", "--ecid", ecid, "--timeout", "2"],
                    recordInHistory: attempt == 1,
                )
                if result.succeeded {
                    append("device endpoint is reachable")
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw VPhoneLaunchpadError(String(localized: "The machine did not respond in DFU mode."))

        case .restore:
            try requireDFURunning()
            try await run(["restore", name] + library)

        case .stopDFU:
            append("waiting up to 30s for the post-restore reboot")
            for _ in 0 ..< 30 {
                if dfu?.isRunning != true || dfuPanicked {
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            try await run(["vm", "stop", name, "--timeout", "20"] + library)
            dfu?.terminate()
            dfu = nil
            append("waiting 5s for cleanup before CFW install")
            try await Task.sleep(for: .seconds(5))

        case .installCFW:
            let status = try await helper.installCustomFirmware(
                bundleVersion: version,
                machineName: name,
                libraryRoot: Self.canonicalPath(URL(fileURLWithPath: options.libraryRoot, isDirectory: true)),
                // The restore tree stays until first boot succeeds, so a
                // failed boot can still be restored again without preparing
                // the firmware anew. `removeRestoreFiles()` reclaims it then;
                // for a template build, adopting it does.
                keepArtifacts: true,
                onLine: output,
            )
            guard status == 0 else {
                throw VPhoneLaunchpadError(String(localized: "Unable to install custom firmware. Check the log for details."), detail: log.tail)
            }
            self.library?.recordGuestEnvironment(target, version)

        case .trimTemplate:
            try await stopIfRunning(target, commandLine: commandLine)
            if let arguments = VPhoneLaunchpadTemplateCommands.trim(name, options.slimming) {
                _ = try await runReporting(arguments + library)
            }

        case .setUpTemplate:
            try await stopIfRunning(target, commandLine: commandLine)
            // `[setup] b. wait for first-boot work`: the stage the sheet shows.
            let stage: @Sendable (String) -> Void = { [weak self] line in
                log.write(line)
                guard line.hasPrefix("[setup] ") else { return }
                let text = String(line.dropFirst("[setup] ".count))
                Task { @MainActor in self?.setupStage = text }
            }
            defer { setupStage = nil }
            _ = try await runReporting(VPhoneLaunchpadTemplateCommands.setup(name, options.slimming) + library, onLine: stage)
            // Slimmed without a template: the record the setup boot wrote is
            // for adopting, which this machine is not, so it goes and the
            // machine is an ordinary one, as a clone is.
            if !plan.usesTemplate {
                try? FileManager.default.removeItem(at: target.url.appendingPathComponent("Template.plist"))
            }

        case .adoptTemplate:
            try await adoptTemplate(target, runReporting, commandLine: commandLine)

        case .cloneTemplate:
            guard let templateID else {
                throw VPhoneLaunchpadError(String(localized: "No template to create the machine from. Retry from Find Template."))
            }
            _ = try await runReporting(VPhoneLaunchpadTemplateCommands.clone(
                name, template: templateID, cpuCount: options.cpuCount, memoryMB: options.memoryMB, network: options.network,
            ) + library)
            bindClone(target, version: version)
            await self.library?.refresh()
            self.library?.selection = [target]

        case .applyGuestPatches:
            try await stopIfRunning(target, commandLine: commandLine)
            try await run(VPhoneLaunchpadTemplateCommands.setPatches(name, options.patchOverrides, includingGuest: true) + library)
            output("$ vphone-cli cfw update-environment \(name)")
            let status = try await helper.updateGuestEnvironment(
                bundleVersion: version,
                machineName: name,
                libraryRoot: Self.canonicalPath(URL(fileURLWithPath: options.libraryRoot, isDirectory: true)),
                onLine: output,
            )
            guard status == 0 else {
                throw VPhoneLaunchpadError(String(localized: "Unable to apply the guest patches. Check the log for details."), detail: log.tail)
            }
            self.library?.recordGuestEnvironment(target, version)

        case .firstBoot:
            try await firstBoot()
        }
    }

    // MARK: - Template steps

    /// `vm template find`: a usable template skips the build. A stale one
    /// with the same key would make the adopt fail at the end, so it is
    /// reported at once.
    private func findTemplate(
        _ run: ([String], @escaping @Sendable (String) -> Void) async throws -> VPhoneLaunchpadCommandResult,
    ) async throws {
        let log = log
        let result = try await run(
            VPhoneLaunchpadTemplateCommands.find(options.templateRequest) + options.machine.libraryArguments,
            { line in log.write(line) },
        )
        guard let data = result.jsonData, let found = try? VPhoneLaunchpadTemplateFind.decode(data) else {
            throw VPhoneLaunchpadError(String(localized: "Unable to read the template search."), detail: result.tail)
        }
        expectedTemplateID = found.id
        if found.usable, let id = found.id {
            templateID = id
            template = found.template
            builtTemplate = false
            plan.foundTemplate = true
            append("● using template \(id)\(found.template.map { ", \($0.machines.count) machine(s) use it" } ?? "")")
            return
        }
        if let stale = found.template {
            throw VPhoneLaunchpadError(
                String(localized: "An outdated template has the key this machine needs."),
                detail: String(localized: "Delete template \(stale.id) in Templates, then retry. Machines created from it keep working.")
                    + "\n" + stale.staleReasons.joined(separator: "\n"),
            )
        }
        if found.building {
            throw VPhoneLaunchpadError(
                String(localized: "Another creation is building this template."),
                detail: String(localized: "Retry once it has finished; the machine is then created from that template."),
            )
        }
        plan.foundTemplate = false
        append("● no template yet (\(found.reason ?? found.id ?? "")); building one in \(plan.buildName ?? "")")
    }

    /// `vm template adopt`, expecting the id Find Template computed: a build
    /// that came out with another key (an app its setup boot could not
    /// remove) fails here, saying why, instead of being saved under an id no
    /// later creation finds. When another creation saved the same template
    /// first, this build is not needed: it is deleted and that template used.
    private func adoptTemplate(
        _ target: VPhoneLaunchpadMachinePath,
        _ run: ([String], @escaping @Sendable (String) -> Void) async throws -> VPhoneLaunchpadCommandResult,
        commandLine: VPhoneLaunchpadCommandLine,
    ) async throws {
        let log = log
        let output: @Sendable (String) -> Void = { line in log.write(line) }
        // Find could not compute the key while the IPSWs were not downloaded
        // and no template recorded them; the restore has downloaded them.
        if expectedTemplateID == nil {
            let again = try? await commandLine.run(
                VPhoneLaunchpadTemplateCommands.find(options.templateRequest) + target.libraryArguments,
                recordInHistory: false,
            )
            expectedTemplateID = again?.jsonData.flatMap { try? VPhoneLaunchpadTemplateFind.decode($0) }?.id
        }
        do {
            let result = try await run(VPhoneLaunchpadTemplateCommands.adopt(
                target.name, iphoneSource: options.iphoneSource, cloudOSSource: options.cloudOSSource, expect: expectedTemplateID,
            ) + target.libraryArguments, output)
            guard let data = result.jsonData, let adopted = try? VPhoneLaunchpadTemplate.decoder().decode(VPhoneLaunchpadTemplate.self, from: data)
            else {
                throw VPhoneLaunchpadError(String(localized: "Unable to read the saved template."), detail: result.tail)
            }
            templateID = adopted.id
            template = adopted
            builtTemplate = true
            append("● template \(adopted.id) saved")
        } catch {
            let again = try? await commandLine.run(
                VPhoneLaunchpadTemplateCommands.find(options.templateRequest) + target.libraryArguments,
                recordInHistory: false,
            )
            guard let data = again?.jsonData, let found = try? VPhoneLaunchpadTemplateFind.decode(data), found.usable, let id = found.id else {
                throw error
            }
            append("● template \(id) was saved by another creation meanwhile; removing \(target.name)")
            _ = try? await commandLine.run(["vm", "delete", target.name, "--force"] + target.libraryArguments)
            templateID = id
            template = found.template
            builtTemplate = false
        }
        await library?.refresh()
    }

    /// The clone carries the template's `launchpad.json`, if Launchpad built
    /// it; it runs with this creation's bundle either way. A template the CLI
    /// built has none: its record names the bundles.
    private func bindClone(_ target: VPhoneLaunchpadMachinePath, version: String) {
        var binding = VPhoneLaunchpadMachineBinding.load(target) ?? VPhoneLaunchpadMachineBinding(
            bundle: version,
            bootChain: template?.bootChainBundleVersion,
            guestEnvironment: template?.builtWithBundleVersion,
        )
        binding.bundle = version
        try? library?.bind(target, binding)
    }

    /// The trim and the setup boot need the build stopped; a retry may find
    /// it started since.
    private func stopIfRunning(_ target: VPhoneLaunchpadMachinePath, commandLine: VPhoneLaunchpadCommandLine) async throws {
        guard let library, await library.isMachineRunning(target) else {
            return
        }
        let arguments = ["vm", "stop", target.name, "--timeout", "20"] + target.libraryArguments
        append("$ \(VPhoneLaunchpadCommandLine.display(arguments))")
        try await commandLine.runChecked(arguments, onLine: { [log] line in log.write(line) })
    }

    /// Boots with a window, as `vm create` does, and waits for vphoned to
    /// answer on the VM's automation socket. The machine keeps running.
    private func firstBoot() async throws {
        guard let library else {
            return
        }
        let name = options.name
        append("$ vphone-cli vm launch \(name)")
        await library.start(machine)
        guard let child = library.launchedProcess(machine) else {
            throw VPhoneLaunchpadError(String(localized: "\(name) could not be started."))
        }
        let socket = machine.url.appendingPathComponent("vphone.sock").path
        append("waiting up to 300s for vphoned")
        for _ in 0 ..< 300 {
            try Task.checkCancellation()
            if library.panicked.contains(machine) {
                throw VPhoneLaunchpadError(String(localized: "The machine had a kernel panic during first boot."), detail: String(localized: "See the machine's console."))
            }
            guard child.isRunning else {
                throw VPhoneLaunchpadError(String(localized: "The machine stopped before first boot finished."))
            }
            if await Task.detached(operation: { Self.ping(socketPath: socket) }).value {
                append("vphoned answered")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw VPhoneLaunchpadError(String(localized: "The machine did not finish starting within 5 minutes."))
    }

    private func requireDFURunning() throws {
        guard dfu?.isRunning == true else {
            throw VPhoneLaunchpadError(String(localized: "The machine stopped while in DFU mode."), detail: log.tail)
        }
    }

    // MARK: - Helpers

    nonisolated static func isPanic(_ line: String) -> Bool {
        VPhoneLaunchpadPanicLine.matches(line)
    }

    /// The ECID the DFU boot wrote into udid-prediction.txt.
    nonisolated static func ecid(in machine: URL) throws -> String {
        let text = (try? String(contentsOf: machine.appendingPathComponent("udid-prediction.txt"), encoding: .utf8)) ?? ""
        var udid = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else {
                continue
            }
            if pair[0] == "ECID", !pair[1].isEmpty {
                return pair[1]
            }
            if pair[0] == "UDID" {
                udid = pair[1]
            }
        }
        if let suffix = udid.split(separator: "-", maxSplits: 1).last, udid.contains("-") {
            return String(suffix)
        }
        throw VPhoneLaunchpadError(String(localized: "Unable to read the device ECID. Try again."))
    }

    nonisolated static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            return url.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The probe `vm create` uses: a ping over vphone.sock that vphoned
    /// answers with `"ok": true`.
    nonisolated static func ping(socketPath: String) -> Bool {
        let path = socketPath.utf8CString
        var address = sockaddr_un()
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { destination in
                for (index, byte) in path.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            return false
        }
        let request = Data("{\"t\":\"ping\",\"screen\":false}\n".utf8)
        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else {
            return false
        }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while reply.count < 4096 {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else {
                return false
            }
            reply.append(contentsOf: buffer.prefix(count))
            if let newline = reply.firstIndex(of: 0x0A),
               let json = try? JSONSerialization.jsonObject(with: Data(reply[..<newline])) as? [String: Any]
            {
                return json["ok"] as? Bool == true
            }
        }
        return false
    }
}

#if DEBUG
    extension VPhoneLaunchpadCreationPipeline {
        enum PreviewState {
            /// Restoring the machine itself, without a template.
            case restoring
            /// Failed while preparing firmware.
            case failed
            /// Partway through downloading an IPSW.
            case downloading(Double)
            /// Building a template: in its setup boot.
            case settingUpTemplate
            /// Built a template, cloned the machine and booted it.
            case builtTemplate
            /// Found a template and cloned from it.
            case clonedFromTemplate
            /// Cloned from a template, writing guest patch overrides into
            /// the clone.
            case applyingGuestPatches
            /// The setup boot failed.
            case setupFailed
        }

        func applyPreview(_ state: PreviewState) {
            statuses = [:]
            durations = [:]
            downloadFraction = nil
            setupStage = nil
            failure = nil
            current = nil
            isRunning = false
            templateID = nil
            expectedTemplateID = nil
            template = nil
            builtTemplate = false
            plan.appliesGuestPatches = false
            func passed(_ steps: [(Step, TimeInterval)]) {
                for (step, duration) in steps {
                    statuses[step] = .passed
                    durations[step] = duration
                }
            }
            let restored: [(Step, TimeInterval)] = [
                (.create, 1), (.prepare, 862), (.patch, 48), (.bootDFU, 6), (.waitDFU, 3), (.restore, 87), (.stopDFU, 10), (.installCFW, 61),
            ]
            switch state {
            case .restoring:
                plan.foundTemplate = plan.usesTemplate ? false : nil
                passed((plan.usesTemplate ? [(.findTemplate, 0)] : []) + Array(restored.prefix(5)))
                statuses[.restore] = .running
                current = .restore
                isRunning = true
            case .failed:
                passed([(.findTemplate, 0), (.create, 0)])
                plan.foundTemplate = false
                statuses[.prepare] = .failed
                durations[.prepare] = 6
                failure = VPhoneLaunchpadError(String(localized: "\(Step.prepare.title) failed."), detail: "Unable to download the IPSW from https://updates.cdn-apple.com/. Try again later.")
            case let .downloading(fraction):
                plan.foundTemplate = false
                passed([(.findTemplate, 0), (.create, 1)])
                statuses[.prepare] = .running
                downloadFraction = fraction
                current = .prepare
                isRunning = true
            case .settingUpTemplate:
                plan.foundTemplate = false
                passed([(.findTemplate, 0)] + restored + [(.trimTemplate, 3)])
                statuses[.setUpTemplate] = .running
                setupStage = "b. wait for first-boot work"
                current = .setUpTemplate
                isRunning = true
            case .builtTemplate:
                plan.foundTemplate = false
                passed([(.findTemplate, 0)] + restored + [(.trimTemplate, 3), (.setUpTemplate, 121), (.adoptTemplate, 0), (.cloneTemplate, 1), (.firstBoot, 9)])
                templateID = VPhoneLaunchpadPreview.templates.first?.id
                template = VPhoneLaunchpadPreview.templates.first
                builtTemplate = true
            case .clonedFromTemplate:
                plan.foundTemplate = true
                passed([(.findTemplate, 0), (.cloneTemplate, 1)])
                statuses[.firstBoot] = .running
                templateID = VPhoneLaunchpadPreview.templates.first?.id
                template = VPhoneLaunchpadPreview.templates.first
                current = .firstBoot
                isRunning = true
            case .applyingGuestPatches:
                plan.foundTemplate = true
                plan.appliesGuestPatches = true
                passed([(.findTemplate, 0), (.cloneTemplate, 1)])
                statuses[.applyGuestPatches] = .running
                templateID = VPhoneLaunchpadPreview.templates.first?.id
                template = VPhoneLaunchpadPreview.templates.first
                current = .applyGuestPatches
                isRunning = true
            case .setupFailed:
                plan.foundTemplate = false
                passed([(.findTemplate, 0)] + restored + [(.trimTemplate, 3)])
                statuses[.setUpTemplate] = .failed
                durations[.setUpTemplate] = 214
                failure = VPhoneLaunchpadError(
                    String(localized: "\(Step.setUpTemplate.title) failed."),
                    detail: "Setup boot failed at step settle (b. wait for first-boot work): not settled within 300 s: staged_system_apps not empty",
                )
            }
        }
    }
#endif
