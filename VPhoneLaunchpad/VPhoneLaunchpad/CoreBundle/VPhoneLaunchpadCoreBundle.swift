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
        case prepare
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
            case .prepare: String(localized: "Read local build")
            case .download: String(localized: "Download")
            case .verify: String(localized: "Verify SHA-256")
            case .install: String(localized: "Install as root")
            case .policy: String(localized: "Add execution policy exception")
            case .preflight: String(localized: "Host preflight")
            }
        }
    }

    struct InstallProgress {
        /// The store version, once known. A local build's comes from its
        /// Info.plist in the prepare step.
        var version: String?
        let source: String
        let size: Int64
        let plan: [InstallStep]
        var steps: [InstallStep: VPhoneLaunchpadStatus] = [:]
        var received: Int64 = 0
        var error: VPhoneLaunchpadError?

        init(release: VPhoneLaunchpadRelease) {
            version = release.version
            source = release.assetName
            size = release.size
            plan = [.download, .verify, .install, .policy, .preflight]
        }

        init(local: URL) {
            source = local.lastPathComponent
            size = 0
            plan = [.prepare, .install, .policy, .preflight]
        }

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
            if let stored, installed.contains(where: { $0.version == stored && VPhoneLaunchpadNames.isCompatibleBundleVersion($0.version) }) {
                return stored
            }
            return installed.first { VPhoneLaunchpadNames.isCompatibleBundleVersion($0.version) }?.version
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
            var item = installed.first { $0.version == receipt.version && $0.receipt == receipt }
                ?? Installed(receipt: receipt)
            if !VPhoneLaunchpadNames.isCompatibleBundleVersion(receipt.version) {
                item.policy = .failed
                item.preflight = .failed
                item.preflightDetail = String(localized: "Requires VPhone.bundle \(VPhoneLaunchpadNames.minimumBundleVersion) or newer.")
            }
            return item
        }
    }

    /// Adds the execution policy exception, allows an AMFI-refused VM through
    /// the root helper, and runs host preflight again for confirmation.
    func verify(_ version: String) async {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else {
            update(version) {
                $0.policy = .failed
                $0.preflight = .failed
                $0.preflightDetail = String(localized: "Requires VPhone.bundle \(VPhoneLaunchpadNames.minimumBundleVersion) or newer.")
            }
            return
        }
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
            try await Task.detached { try VPhoneLaunchpadHostPolicy.requireReady() }.value
            var result = try await commandLine.run(["host", "preflight", "--quiet"])
            if result.lines.contains(where: { $0.hasPrefix("Error: AMFI blocked vphone-vm") }) {
                try await helper.allowVirtualMachine(bundleVersion: version)
                result = try await commandLine.run(["host", "preflight", "--quiet"])
            }
            let failure = result.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            update(version) {
                $0.preflight = result.succeeded ? .passed : .failed
                $0.preflightDetail = result.succeeded
                    ? String(localized: "Passed")
                    : (failure.isEmpty ? String(localized: "Preflight failed") : failure)
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
                    String(localized: "The download could not be verified. Try again."),
                    detail: String(localized: "Expected \(release.sha256)\nReceived \(digest)"),
                )
            }
            set(.verify, .passed)

            try await installAndVerify(version: release.version, archive: file, sha256: release.sha256)
        } catch {
            fail(error)
        }
    }

    /// Installs a VPhone.bundle folder or .zip built on this Mac as
    /// `<version>-local`.
    func installLocal(_ source: URL) async {
        progress = InstallProgress(local: source)
        var work: URL?
        defer {
            if let work {
                try? FileManager.default.removeItem(at: work)
            }
        }
        do {
            set(.prepare, .running)
            let local = try await VPhoneLaunchpadLocalBundle.prepare(source)
            work = local.workDirectory
            progress?.version = local.version
            set(.prepare, .passed)

            try await installAndVerify(version: local.version, archive: local.archive, sha256: local.sha256)
        } catch {
            fail(error)
        }
    }

    /// The steps a release and a local build share: the helper installs the
    /// archive as root, then the new version becomes active and is checked.
    private func installAndVerify(version: String, archive: URL, sha256: String) async throws {
        set(.install, .running)
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        try await helper.installBundle(version: version, archive: handle, sha256: sha256)
        set(.install, .passed)

        loadInstalled()
        activeVersion = version
        set(.policy, .running)
        set(.preflight, .running)
        await verify(version)
        let installed = installed.first { $0.version == version }
        set(.policy, installed?.policy ?? .failed)
        set(.preflight, installed?.preflight ?? .failed)
        if installed?.preflight != .passed {
            throw VPhoneLaunchpadError(
                String(localized: "Host preflight failed. Fix the issue below, then choose Run Preflight Again."),
                detail: installed?.preflightDetail,
            )
        }
    }

    private func fail(_ error: Error) {
        for step in InstallStep.allCases where progress?.status(step) == .running {
            set(step, .failed)
        }
        progress?.error = error as? VPhoneLaunchpadError
            ?? VPhoneLaunchpadError(String(localized: "Unable to install the bundle. Try again."), detail: error.localizedDescription)
    }

    func dismissProgress() {
        progress = nil
    }

    private func set(_ step: InstallStep, _ status: VPhoneLaunchpadStatus) {
        progress?.steps[step] = status
    }

    // MARK: - Use and remove

    func use(_ version: String) async {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else { return }
        activeVersion = version
        await verify(version)
    }

    func remove(_ version: String) async {
        do {
            try await helper.removeBundle(version: version)
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Remove VPhone.bundle \(version)"), detail: error.localizedDescription)
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
                bundle.preflightDetail = String(localized: "Passed")
                return bundle
            }
        }
    }
#endif
