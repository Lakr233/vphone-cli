import ExecutionPolicy
import Foundation
import Observation

/// The second stage: installed VPhone.bundle versions, the one in use, and
/// installing new ones from GitHub releases.
@MainActor
@Observable
final class VPhoneLaunchpadCoreBundle {
    // MARK: - Installed versions

    struct Installed: Identifiable {
        let receipt: VPhoneLaunchpadBundleReceipt
        var policy: VPhoneLaunchpadStatus = .pending
        var policyDetail = ""
        var preflight: VPhoneLaunchpadStatus = .pending
        var preflightDetail = ""

        var id: String {
            receipt.version
        }

        var version: String {
            receipt.version
        }
    }

    // MARK: - Install progress

    enum InstallStep: CaseIterable, Identifiable {
        case download
        case verify
        case install
        case policy
        case preflight

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .download: "Download"
            case .verify: "Verify SHA-256"
            case .install: "Install as root"
            case .policy: "Add execution policy exception"
            case .preflight: "Host preflight"
            }
        }
    }

    struct InstallProgress {
        let release: VPhoneLaunchpadRelease
        var steps: [InstallStep: VPhoneLaunchpadStatus] = [:]
        var received: Int64 = 0
        var error: VPhoneLaunchpadError?

        func status(_ step: InstallStep) -> VPhoneLaunchpadStatus {
            steps[step] ?? .pending
        }
    }

    private(set) var installed: [Installed] = []
    private(set) var releases: [VPhoneLaunchpadRelease] = []
    private(set) var releasesError: String?
    private(set) var progress: InstallProgress?
    var actionError: VPhoneLaunchpadError?

    private let helper: VPhoneLaunchpadHelperClient
    private let history: VPhoneLaunchpadCommandHistory
    private static let activeVersionKey = "VPhoneLaunchpadActiveBundleVersion"

    init(helper: VPhoneLaunchpadHelperClient, history: VPhoneLaunchpadCommandHistory) {
        self.helper = helper
        self.history = history
    }

    // MARK: - Active version

    var activeVersion: String? {
        get {
            access(keyPath: \.activeVersion)
            let stored = UserDefaults.standard.string(forKey: Self.activeVersionKey)
            if let stored, installed.contains(where: { $0.version == stored }) {
                return stored
            }
            return installed.first?.version
        }
        set {
            withMutation(keyPath: \.activeVersion) {
                UserDefaults.standard.set(newValue, forKey: Self.activeVersionKey)
            }
        }
    }

    var active: Installed? {
        installed.first { $0.version == activeVersion }
    }

    /// Machines appears once the active bundle has passed host preflight.
    var isReady: Bool {
        active?.preflight == .passed
    }

    var isInstalling: Bool {
        guard let progress else {
            return false
        }
        return progress.error == nil && progress.status(.preflight) != .passed
    }

    /// The newest release that is not installed yet, if it is newer than
    /// everything installed.
    var availableUpdate: VPhoneLaunchpadRelease? {
        guard let latest = releases.first, !installed.contains(where: { $0.version == latest.version }) else {
            return nil
        }
        return latest
    }

    func commandLine() -> VPhoneLaunchpadCommandLine? {
        guard let version = activeVersion else {
            return nil
        }
        return VPhoneLaunchpadCommandLine(
            executable: VPhoneLaunchpadBundleStore.executable(version: version, named: "vphone-cli"),
            history: history,
        )
    }

    // MARK: - Refresh

    func refresh() async {
        loadInstalled()
        if let version = activeVersion {
            await verify(version)
        }
        await fetchReleases()
    }

    func fetchReleases() async {
        do {
            releases = try await VPhoneLaunchpadRelease.fetch()
            releasesError = nil
        } catch {
            releasesError = error.localizedDescription
        }
    }

    private func loadInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: VPhoneLaunchpadBundleStore.root.path)) ?? []
        let receipts = names
            .filter(VPhoneLaunchpadNames.isValidVersion)
            .compactMap(VPhoneLaunchpadBundleReceipt.load)
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        installed = receipts.map { receipt in
            installed.first { $0.version == receipt.version && $0.receipt == receipt } ?? Installed(receipt: receipt)
        }
    }

    /// Adds the execution policy exception and runs host preflight.
    func verify(_ version: String) async {
        update(version) {
            $0.policy = .running
            $0.preflight = .running
        }
        let bundle = VPhoneLaunchpadBundleStore.bundle(version: version)
        do {
            try EPExecutionPolicy().addException(for: bundle)
            update(version) {
                $0.policy = .passed
                $0.policyDetail = "exception"
            }
        } catch {
            update(version) {
                $0.policy = .failed
                $0.policyDetail = "no exception"
            }
        }

        let commandLine = VPhoneLaunchpadCommandLine(
            executable: VPhoneLaunchpadBundleStore.executable(version: version, named: "vphone-cli"),
            history: history,
        )
        do {
            let result = try await commandLine.run(["host", "preflight", "--quiet"])
            update(version) {
                $0.preflight = result.succeeded ? .passed : .failed
                $0.preflightDetail = result.succeeded
                    ? "passed"
                    : (result.lines.last ?? "exit status \(result.status)")
                        .replacingOccurrences(of: "Error: ", with: "")
            }
        } catch {
            update(version) {
                $0.preflight = .failed
                $0.preflightDetail = error.localizedDescription
            }
        }
    }

    private func update(_ version: String, _ change: (inout Installed) -> Void) {
        if let index = installed.firstIndex(where: { $0.version == version }) {
            change(&installed[index])
        }
    }

    // MARK: - Install

    func install(_ release: VPhoneLaunchpadRelease) async {
        progress = InstallProgress(release: release)
        var archive: URL?
        defer {
            if let archive {
                try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            }
        }
        do {
            set(.download, .running)
            let (file, digest) = try await release.download { received in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.progress?.received = received }
                }
            }
            archive = file
            set(.download, .passed)

            set(.verify, .running)
            guard digest == release.sha256.lowercased() else {
                throw VPhoneLaunchpadError(
                    "The download does not match the published SHA-256.",
                    detail: "expected \(release.sha256)\nreceived \(digest)",
                )
            }
            set(.verify, .passed)

            set(.install, .running)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try await helper.installBundle(version: release.version, archive: handle, sha256: release.sha256)
            set(.install, .passed)

            loadInstalled()
            activeVersion = release.version
            set(.policy, .running)
            set(.preflight, .running)
            await verify(release.version)
            let installed = installed.first { $0.version == release.version }
            set(.policy, installed?.policy ?? .failed)
            set(.preflight, installed?.preflight ?? .failed)
            if installed?.preflight != .passed {
                throw VPhoneLaunchpadError(
                    "Host preflight did not pass.",
                    detail: installed?.preflightDetail,
                )
            }
        } catch {
            for step in InstallStep.allCases where progress?.status(step) == .running {
                set(step, .failed)
            }
            progress?.error = error as? VPhoneLaunchpadError
                ?? VPhoneLaunchpadError("The install failed.", detail: error.localizedDescription)
        }
    }

    func dismissProgress() {
        progress = nil
    }

    private func set(_ step: InstallStep, _ status: VPhoneLaunchpadStatus) {
        progress?.steps[step] = status
    }

    // MARK: - Use and remove

    func use(_ version: String) async {
        activeVersion = version
        await verify(version)
    }

    func remove(_ version: String) async {
        do {
            try await helper.removeBundle(version: version)
        } catch {
            actionError = VPhoneLaunchpadError("VPhone.bundle \(version) could not be removed.", detail: "\(error)")
        }
        loadInstalled()
    }
}

#if DEBUG
    extension VPhoneLaunchpadCoreBundle {
        func applyPreview(installing: Bool) {
            releases = VPhoneLaunchpadPreview.releases
            if installing {
                installed = []
                var progress = InstallProgress(release: releases[0])
                progress.steps = [.download: .running]
                progress.received = 9_400_000
                self.progress = progress
                return
            }
            progress = nil
            installed = VPhoneLaunchpadPreview.releases.dropFirst().map { release in
                var bundle = Installed(receipt: VPhoneLaunchpadBundleReceipt(
                    version: release.version,
                    sha256: release.sha256,
                    installedAt: release.publishedAt.addingTimeInterval(3600),
                    cdhashes: [:],
                ))
                bundle.policy = .passed
                bundle.policyDetail = "exception"
                bundle.preflight = .passed
                bundle.preflightDetail = "passed"
                return bundle
            }
        }
    }
#endif
