import ArgumentParser
import Foundation
import VPhoneCoreKit

// MARK: - Slimming switches

/// The slimming switches `vm create` and `vm template setup` share.
struct VPhoneTemplateSlimmingOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Slim the template: on (default) | off. off keeps every service and app; Setup is skipped either way",
        valueName: "on|off",
    ))
    var slim: String?
    @Option(help: ArgumentHelp(
        "System files the template deletes offline: standard (default) | conservative | none. Part of the template key; vm template trim describes the tiers",
        valueName: "tier",
    ))
    var trim: String?
    @Option(help: ArgumentHelp("Languages whose linguistic data --trim standard keeps (en is always kept)", valueName: "en,zh-Hans,zh"))
    var keepLanguages: String?
    @Option(help: ArgumentHelp("Service profile the template applies: trimmed (default) | none", valueName: "profile"))
    var serviceProfile: String?
    @Option(help: ArgumentHelp("Remove the default system apps (App Store, TV, News, …): on (default) | off", valueName: "on|off"))
    var removeApps: String?
    @Option(
        help: ArgumentHelp("Bundle IDs of default-removed apps to keep, comma-separated (com.apple.findmy,com.apple.Passbook)", valueName: "ids"),
        transform: { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } },
    )
    var keepApps: [String] = []
    @Flag(help: "Also turn off the Apple Account daemons (akd, amsaccountsd, appleaccountd); the guest then cannot sign in")
    var accountsOff = false

    var request: VPhoneTemplateSlimmingRequest {
        get throws {
            try VPhoneTemplateSlimmingRequest(
                slim: slim.map { try VPhoneVirtualMachineConfigCommand.parseSwitch($0, option: "--slim") },
                trimTier: trim,
                keepLanguages: keepLanguages,
                serviceProfile: serviceProfile,
                removeApps: removeApps.map { try VPhoneVirtualMachineConfigCommand.parseSwitch($0, option: "--remove-apps") },
                keepApps: keepApps,
                accountsOff: accountsOff,
            )
        }
    }

    /// The slimming asked for, as a ValidationError when switches disagree.
    func resolve() throws -> VPhoneMachineTemplateSlimming {
        do {
            return try request.resolve()
        } catch let error as VPhoneTemplateSlimmingError {
            throw ValidationError(error.description)
        }
    }
}

// MARK: - The VM a setup boot drives

/// `vphone-vm` started for a setup boot, driven through its `vphone.sock`.
/// Booted the way `vm launch` boots: refused for a frozen template or a
/// running machine, with this bundle's vphoned staged, and through the same
/// `VPhoneBootCommand` validation `vphone-vm` repeats.
final class VPhoneTemplateSetupVirtualMachine: VPhoneTemplateSetupMachine {
    private let bundle: VPhoneBundle
    private let launcher: VPhoneGuestLaunchPlanner
    private let resources: VPhoneResources
    private let headless: Bool
    private let verbosity: VPhoneVerbosity
    private var process: VPhoneManagedProcess?

    init(bundle: VPhoneBundle, launcher: VPhoneGuestLaunchPlanner, resources: VPhoneResources, headless: Bool, verbosity: VPhoneVerbosity) {
        self.bundle = bundle
        self.launcher = launcher
        self.resources = resources
        self.headless = headless
        self.verbosity = verbosity
    }

    private var socketPath: String {
        bundle.url.appendingPathComponent("vphone.sock").path
    }

    func start() throws {
        try VPhoneMachineTemplates.requireBootable(bundleURL: bundle.url)
        try VPhoneBundleActivity.requireStopped(bundle)
        _ = try VPhoneLaunchLayout(resources: resources).stageVphoned(into: bundle)
        var boot = VPhoneBootCommand(config: bundle.configURL, headless: headless)
        try boot.validate()
        let (executable, arguments) = launcher.plan(boot.bootArguments)
        if verbosity.tracesInternals {
            print("[trace] spawn \(executable.path) \(arguments.joined(separator: " ")) (guest serial: off)")
        }
        let process = VPhoneManagedProcess(executable, arguments, cwd: bundle.url, echo: false)
        try process.start()
        self.process = process
    }

    func failure() -> String? {
        guard let process else { return "the VM was not started" }
        switch process.waitForOutput(matching: "(?i:\(VPhoneBootPatterns.panicRegex))", timeout: 0) {
        case .matched:
            return "the guest panicked"
        case let .exited(code):
            return "vphone-vm exited with status \(code)"
        case .timedOut:
            return nil
        }
    }

    func exitedCleanly() -> Bool {
        guard let process, !process.isRunning else { return false }
        if case .exited(0) = process.waitForOutput(matching: "(?i:\(VPhoneBootPatterns.panicRegex))", timeout: 0) {
            return true
        }
        return false
    }

    func ping() -> Bool {
        VPhoneHostAutomationProbe.ping(socketPath: socketPath)
    }

    func call(_ method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        try VPhoneHostAutomationProbe.rpc(method, params: params, socketPath: socketPath, timeout: Int(timeout.rounded(.up)))
    }

    /// SIGINT makes `vphone-vm` ask the guest to shut down and exit once it
    /// has; it turns the guest off after 15 s and says so.
    func stop(timeout: TimeInterval) -> Bool {
        guard let process else { return true }
        guard process.interrupt(waitingUpTo: timeout) else {
            process.terminate()
            return false
        }
        return !process.outputText.contains("turning it off")
    }

    func kill() {
        process?.terminate()
    }
}

// MARK: - Running a setup boot

enum VPhoneTemplateSetupRun {
    /// Runs the setup boot on the machine folder at `bundleURL` and records
    /// what it did in that folder's `Template.plist`, which must exist.
    /// Throws ``VPhoneTemplateSetupFailure`` and records nothing on failure.
    @discardableResult
    static func run(
        bundleURL: URL,
        plan: VPhoneTemplateSetupPlan,
        launcher: VPhoneGuestLaunchPlanner,
        resources: VPhoneResources,
        headless: Bool,
        verbosity: VPhoneVerbosity,
    ) throws -> VPhoneTemplateSetupOutcome {
        let bundle = try VPhoneBundle.load(at: bundleURL)
        let machine = VPhoneTemplateSetupVirtualMachine(
            bundle: bundle,
            launcher: launcher,
            resources: resources,
            headless: headless,
            verbosity: verbosity,
        )
        let outcome = try VPhoneTemplateSetupBoot(machine: machine, plan: plan).run()
        try VPhoneMachineTemplates.recordSetupBoot(outcome, inBundle: bundleURL)
        report(outcome)
        return outcome
    }

    static func report(_ outcome: VPhoneTemplateSetupOutcome) {
        let order = VPhoneTemplateSetupStep.allCases
        let times = order.compactMap { step in outcome.durations[step].map { "\(step.rawValue) \(Int($0.rounded())) s" } }
        print("[+] Setup boot done: \(times.joined(separator: ", "))")
        print("    snapshots deleted: \(outcome.deletedSnapshots.isEmpty ? "none left" : outcome.deletedSnapshots.joined(separator: ", "))")
        var services = outcome.serviceProfile
        if !outcome.serviceGroups.isEmpty {
            services += " +" + outcome.serviceGroups.joined(separator: ",")
        }
        print("    services: \(services)\(outcome.serviceProfile == "none" ? "" : " (\(outcome.servicesOwned) owned)")")
        print("    apps removed: \(outcome.removedApps.isEmpty ? "none" : outcome.removedApps.joined(separator: ", "))")
        if !outcome.clearedCrashReports.isEmpty {
            print("    crash reports cleared: \(VPhoneTemplateSetupBoot.summarizeCrashReports(outcome.clearedCrashReports))")
        }
        let retried = outcome.retriedUnregistrations.sorted { $0.key < $1.key }
        if !retried.isEmpty {
            print("    unregistered after retries: \(retried.map { "\($0.key) (\($0.value) attempts)" }.joined(separator: ", "))")
        }
        for warning in outcome.warnings {
            print("    warning: \(warning)")
        }
    }
}

// MARK: - Finishing a build

enum VPhoneTemplateBuildFinisher {
    /// The key a build's own records give must be the one it is filed under,
    /// or no later create (or adopt) would find it.
    static func requireRecordedKey(_ build: VPhoneMachineTemplateBuild, key: VPhoneMachineTemplateKey) throws {
        let recorded = try VPhoneMachineTemplateKeys.recorded(VPhoneBundle.load(at: build.bundleURL), slimming: key.slimming)
        guard recorded.key == key else {
            throw ValidationError(
                "The built template's records give another key than requested (\(key.differences(from: recorded.key).joined(separator: "; "))).",
            )
        }
    }

    /// Checks the recorded key and freezes the build; `freeze` refuses steps
    /// that fell short of the key.
    static func freeze(_ build: VPhoneMachineTemplateBuild, key: VPhoneMachineTemplateKey) throws -> VPhoneMachineTemplate {
        try requireRecordedKey(build, key: key)
        return try VPhoneMachineTemplates.freeze(build)
    }
}
