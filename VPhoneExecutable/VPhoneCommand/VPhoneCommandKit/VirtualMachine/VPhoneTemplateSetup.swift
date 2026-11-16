import ArgumentParser
import Foundation
import VPhoneCoreKit

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

public enum VPhoneTemplateSetupRun {
    /// Runs the setup boot on the machine folder at `bundleURL` and records
    /// what it did in that folder's `Template.plist`, which must exist.
    /// Throws ``VPhoneTemplateSetupFailure`` and records nothing on failure.
    @discardableResult
    public static func run(
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

    static func report(_ outcome: VPhoneTemplateSetupOutcome, log: (String) -> Void = { print($0) }) {
        let order = VPhoneTemplateSetupStep.allCases
        let times = order.compactMap { step in outcome.durations[step].map { "\(step.rawValue) \(Int($0.rounded())) s" } }
        log("[+] Setup boot done: \(times.joined(separator: ", "))")
        log("    snapshots deleted: \(outcome.deletedSnapshots.isEmpty ? "none left" : outcome.deletedSnapshots.joined(separator: ", "))")
        var services = outcome.serviceProfile
        if !outcome.serviceGroups.isEmpty {
            services += " +" + outcome.serviceGroups.joined(separator: ",")
        }
        log("    services: \(services)\(outcome.serviceProfile == "none" ? "" : " (\(outcome.servicesOwned) owned)")")
        log("    apps removed: \(outcome.removedApps.isEmpty ? "none" : outcome.removedApps.joined(separator: ", "))")
        if !outcome.clearedCrashReports.isEmpty {
            log("    crash reports cleared: \(VPhoneTemplateSetupBoot.summarizeCrashReports(outcome.clearedCrashReports))")
        }
        let retried = outcome.retriedUnregistrations.sorted { $0.key < $1.key }
        if !retried.isEmpty {
            log("    unregistered after retries: \(retried.map { "\($0.key) (\($0.value) attempts)" }.joined(separator: ", "))")
        }
        for warning in outcome.warnings {
            log("    warning: \(warning)")
        }
    }
}

// MARK: - Finishing a build

public enum VPhoneTemplateBuildFinisher {
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
    public static func freeze(_ build: VPhoneMachineTemplateBuild, key: VPhoneMachineTemplateKey) throws -> VPhoneMachineTemplate {
        try requireRecordedKey(build, key: key)
        return try VPhoneMachineTemplates.freeze(build)
    }
}
