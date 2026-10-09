import ExecutionPolicy
import Foundation
import Observation

/// The second stage: installed VPhone.bundle versions, the default one, and
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

    enum InstallStep: String, CaseIterable, Identifiable, Codable {
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
            case .prepare: String(localized: "Prepare bundle")
            case .download: String(localized: "Download")
            case .verify: String(localized: "Verify SHA-256")
            case .install: String(localized: "Install with administrator access")
            case .policy: String(localized: "Allow bundle to run")
            case .preflight: String(localized: "Host preflight")
            }
        }
    }

    /// Where an install came from, kept so Retry can start it again after a
    /// relaunch, when the downloaded files are gone.
    enum InstallSource: Codable {
        case release(VPhoneLaunchpadRelease)
        case local(path: String)
    }

    /// The last install and how far it got. It is written to disk on every
    /// change, so it survives quitting Launchpad; a step that was running
    /// then comes back as failed and can be retried.
    struct InstallProgress: Codable {
        /// The store version, once known. A local build's comes from its
        /// Info.plist in the prepare step.
        var version: String?
        let source: InstallSource
        let name: String
        let size: Int64
        let plan: [InstallStep]
        var steps: [InstallStep: VPhoneLaunchpadStatus] = [:]
        var received: Int64 = 0
        var errorMessage: String?
        var errorDetail: String?
        var startedAt = Date()
        /// True when the installed version must not become the default, as
        /// `vphone-launchpad-cli bundle install-local --keep-default` asks.
        /// Optional so a progress file from an older Launchpad still reads.
        var keepsDefault: Bool?

        init(release: VPhoneLaunchpadRelease) {
            version = release.version
            source = .release(release)
            name = release.assetName
            size = release.size
            plan = [.download, .verify, .install, .policy, .preflight]
        }

        init(local: URL) {
            source = .local(path: local.path)
            name = local.lastPathComponent
            size = 0
            plan = [.prepare, .install, .policy, .preflight]
        }

        func status(_ step: InstallStep) -> VPhoneLaunchpadStatus {
            steps[step] ?? .pending
        }

        var error: VPhoneLaunchpadError? {
            get { errorMessage.map { VPhoneLaunchpadError($0, detail: errorDetail) } }
            set {
                errorMessage = newValue?.message
                errorDetail = newValue?.detail
            }
        }

        /// Every step passed, or was skipped.
        var isFinished: Bool {
            plan.allSatisfy { status($0) == .passed || status($0) == .warning }
        }

        /// Once the bundle is in the store, only the checks after it failed,
        /// and those may be skipped.
        var canSkip: Bool {
            error != nil && status(.install) == .passed
        }

        var overall: VPhoneLaunchpadStatus {
            if error != nil {
                return .failed
            }
            if !isFinished {
                return .running
            }
            return plan.contains { status($0) == .warning } ? .warning : .passed
        }
    }

    private(set) var installed: [Installed] = []
    private(set) var releases: [VPhoneLaunchpadRelease] = []
    private(set) var releasesError: String?
    private(set) var isFetchingReleases = false
    private(set) var progress: InstallProgress? {
        didSet { Self.saveProgress(progress) }
    }

    var actionError: VPhoneLaunchpadError?

    private let helper: VPhoneLaunchpadHelperClient
    private let history: VPhoneLaunchpadCommandHistory
    private static let defaultVersionKey = "VPhoneLaunchpadActiveBundleVersion"
    private static let acceptedVersionsKey = "VPhoneLaunchpadAcceptedBundleVersions"
    /// Version → receipt SHA-256 of bundles whose last check passed.
    private static let passedVersionsKey = "VPhoneLaunchpadPassedBundleVersions"

    /// Lists the store at once, showing each bundle as its last check left
    /// it, so the window opens ready. The launch check confirms it later.
    init(helper: VPhoneLaunchpadHelperClient, history: VPhoneLaunchpadCommandHistory) {
        self.helper = helper
        self.history = history
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return
            }
        #endif
        progress = Self.loadProgress()
        loadInstalled()
        let passed = UserDefaults.standard.dictionary(forKey: Self.passedVersionsKey) as? [String: String] ?? [:]
        for index in installed.indices
            where VPhoneLaunchpadNames.isCompatibleBundleVersion(installed[index].version)
            && passed[installed[index].version] == installed[index].receipt.sha256
        {
            installed[index].policy = .passed
            installed[index].policyDetail = "exception"
            installed[index].preflight = .passed
            installed[index].preflightDetail = String(localized: "Passed")
        }
    }

    private func recordCheck(_ version: String) {
        var passed = UserDefaults.standard.dictionary(forKey: Self.passedVersionsKey) as? [String: String] ?? [:]
        let item = installed.first { $0.version == version }
        if let item, item.policy == .passed, item.preflight == .passed {
            passed[version] = item.receipt.sha256
        } else {
            passed[version] = nil
        }
        UserDefaults.standard.set(passed, forKey: Self.passedVersionsKey)
        if isUsable(version) {
            checkedThisSession.insert(version)
        } else {
            checkedThisSession.remove(version)
        }
    }

    // MARK: - Default version

    /// The version New Machine offers first, and the one library-wide
    /// commands such as `vm list` run with. Each machine runs with the
    /// version in its own binding (`VPhoneLaunchpadMachineBinding`), so
    /// changing the default, or installing a bundle, leaves existing
    /// machines alone. The defaults key keeps its old name.
    var defaultVersion: String? {
        get {
            access(keyPath: \.defaultVersion)
            let stored = UserDefaults.standard.string(forKey: Self.defaultVersionKey)
            if let stored, installed.contains(where: { $0.version == stored && VPhoneLaunchpadNames.isCompatibleBundleVersion($0.version) }) {
                return stored
            }
            return installed.first { VPhoneLaunchpadNames.isCompatibleBundleVersion($0.version) }?.version
        }
        set {
            withMutation(keyPath: \.defaultVersion) {
                UserDefaults.standard.set(newValue, forKey: Self.defaultVersionKey)
            }
        }
    }

    var defaultBundle: Installed? {
        installed.first { $0.version == defaultVersion }
    }

    /// The default bundle passed host preflight, or the user chose to use it
    /// without.
    var isReady: Bool {
        guard let defaultVersion else {
            return false
        }
        return isUsable(defaultVersion)
    }

    /// `version` is installed, supported, and passed host preflight or was
    /// accepted without.
    func isUsable(_ version: String) -> Bool {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version),
              let item = installed.first(where: { $0.version == version })
        else {
            return false
        }
        return item.preflight == .passed || isAccepted(version)
    }

    /// Versions offered for a machine: installed and supported, newest first.
    var selectableVersions: [String] {
        installed.map(\.version).filter(VPhoneLaunchpadNames.isCompatibleBundleVersion)
    }

    var isInstalling: Bool {
        guard let progress else {
            return false
        }
        return progress.error == nil && !progress.isFinished
    }

    // MARK: - Accepted versions

    /// Versions whose failed preflight the user chose to skip.
    private var acceptedVersions: Set<String> {
        get {
            access(keyPath: \.acceptedVersions)
            return Set(UserDefaults.standard.stringArray(forKey: Self.acceptedVersionsKey) ?? [])
        }
        set {
            withMutation(keyPath: \.acceptedVersions) {
                UserDefaults.standard.set(newValue.sorted(), forKey: Self.acceptedVersionsKey)
            }
        }
    }

    func isAccepted(_ version: String) -> Bool {
        acceptedVersions.contains(version)
    }

    func setAccepted(_ version: String, _ isAccepted: Bool) {
        if isAccepted {
            acceptedVersions.insert(version)
        } else {
            acceptedVersions.remove(version)
        }
    }

    /// The newest release that is not installed yet, if it is newer than
    /// everything installed.
    var availableUpdate: VPhoneLaunchpadRelease? {
        guard let latest = releases.first, !installed.contains(where: { $0.version == latest.version }) else {
            return nil
        }
        return latest
    }

    /// The default version's `vphone-cli`, for commands that belong to no
    /// machine. A machine's own commands go through
    /// `VPhoneLaunchpadMachineLibrary.commandLine(for:)`.
    func commandLine() -> VPhoneLaunchpadCommandLine? {
        defaultVersion.flatMap(commandLine(version:))
    }

    /// `vphone-cli` of one installed, supported version.
    func commandLine(version: String) -> VPhoneLaunchpadCommandLine? {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version),
              installed.contains(where: { $0.version == version })
        else {
            return nil
        }
        return VPhoneLaunchpadCommandLine(
            executable: VPhoneLaunchpadBundleStore.executable(version: version, named: "vphone-cli"),
            history: history,
        )
    }

    // MARK: - Readiness

    /// Versions checked since Launchpad started that passed, or were
    /// accepted. The default is checked at launch; another version is
    /// checked the first time a machine needs it, since its policy exception
    /// or AMFI admission may be gone after a restart.
    private var checkedThisSession: Set<String> = []
    private var checks: [String: Task<Void, Never>] = [:]

    /// True when `version` passed, or was accepted, since Launchpad started,
    /// so `prepare` returns without checking it again.
    func isChecked(_ version: String) -> Bool {
        checkedThisSession.contains(version) && checks[version] == nil
    }

    /// Makes sure `version` can run a machine: installed, supported, and
    /// checked in this session. Checks of one version are shared by every
    /// caller waiting on it.
    func prepare(_ version: String) async throws {
        guard installed.contains(where: { $0.version == version }) else {
            throw VPhoneLaunchpadError(
                String(localized: "VPhone.bundle \(version) is not installed."),
                detail: String(localized: "Install it in Core Bundle, or choose another version for this machine."),
            )
        }
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else {
            throw VPhoneLaunchpadError(String(localized: "Requires VPhone.bundle \(VPhoneLaunchpadNames.minimumBundleVersion) or newer."))
        }
        if checks[version] != nil || !checkedThisSession.contains(version) {
            await check(version)
        }
        guard isUsable(version) else {
            throw VPhoneLaunchpadError(
                String(localized: "VPhone.bundle \(version) did not pass host preflight."),
                detail: installed.first { $0.version == version }?.preflightDetail,
            )
        }
    }

    // MARK: - Refresh

    func refresh() async {
        await checkDefault()
        await fetchReleases()
    }

    /// Rereads the store and checks the default bundle again. A bundle that
    /// passed keeps showing so while the check runs.
    func checkDefault() async {
        loadInstalled()
        if let version = defaultVersion {
            await check(version)
        }
    }

    /// Verifies `version` without showing progress, or waits for the check
    /// of it already running, so a machine started during the launch check
    /// does not run a second preflight beside it.
    private func check(_ version: String) async {
        if let running = checks[version] {
            await running.value
            return
        }
        let check = Task { await verify(version, showsProgress: false) }
        checks[version] = check
        await check.value
        checks[version] = nil
    }

    func fetchReleases() async {
        isFetchingReleases = true
        defer { isFetchingReleases = false }
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
    /// Without `showsProgress`, a bundle that passed before is not marked
    /// running meanwhile.
    func verify(_ version: String, showsProgress: Bool = true) async {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else {
            update(version) {
                $0.policy = .failed
                $0.preflight = .failed
                $0.preflightDetail = String(localized: "Requires VPhone.bundle \(VPhoneLaunchpadNames.minimumBundleVersion) or newer.")
            }
            return
        }
        defer { recordCheck(version) }
        update(version) {
            if showsProgress || $0.policy != .passed || $0.preflight != .passed {
                $0.policy = .running
                $0.preflight = .running
            }
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

    func install(_ release: VPhoneLaunchpadRelease, keepsDefault: Bool = false) async {
        progress = InstallProgress(release: release)
        progress?.keepsDefault = keepsDefault
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
    /// `<version>-local.<build>`.
    func installLocal(_ source: URL, keepsDefault: Bool = false) async {
        progress = InstallProgress(local: source)
        progress?.keepsDefault = keepsDefault
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

    /// The steps every source shares: the helper installs the archive as
    /// root, then the new version becomes the default, unless the install
    /// keeps it, and is checked. Machines bound to other versions stay on
    /// them.
    ///
    /// A local build already in the store under the same name is the same
    /// build, since the name comes from its code signature seal, so it is not
    /// installed again: replacing it would pull the files from under the
    /// machines running from it.
    private func installAndVerify(version: String, archive: URL, sha256: String) async throws {
        set(.install, .running)
        loadInstalled()
        // A bare `-local` from an older Launchpad names no build, so it is
        // replaced as before.
        let isSameBuild = VPhoneLaunchpadNames.isLocalBuild(version)
            && !version.hasSuffix(VPhoneLaunchpadLocalBundle.versionSuffix)
            && installed.contains { $0.version == version }
        if !isSameBuild {
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            try await helper.installBundle(version: version, archive: handle, sha256: sha256)
            loadInstalled()
        }
        set(.install, .passed)

        if progress?.keepsDefault != true {
            defaultVersion = version
        }
        try await checkInstalled(version)
    }

    /// The policy exception and host preflight for a bundle already in the
    /// store.
    private func checkInstalled(_ version: String) async throws {
        set(.policy, .running)
        set(.preflight, .running)
        await verify(version)
        let installed = installed.first { $0.version == version }
        set(.policy, installed?.policy ?? .failed)
        set(.preflight, installed?.preflight ?? .failed)
        if installed?.preflight != .passed {
            throw VPhoneLaunchpadError(
                String(localized: "Host preflight failed. Fix the issue and retry, or skip to use this version anyway."),
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

    // MARK: - Retry and skip

    /// Runs the failed install again. Once the bundle is in the store only
    /// the checks after it run again; before that the whole install starts
    /// over, since a download does not outlive the attempt.
    func retry() async {
        guard let progress, !isInstalling else {
            return
        }
        if progress.status(.install) == .passed, let version = progress.version,
           installed.contains(where: { $0.version == version })
        {
            self.progress?.error = nil
            do {
                try await checkInstalled(version)
            } catch {
                fail(error)
            }
            return
        }
        let keepsDefault = progress.keepsDefault ?? false
        switch progress.source {
        case let .release(release):
            await install(release, keepsDefault: keepsDefault)
        case let .local(path):
            await installLocal(URL(fileURLWithPath: path), keepsDefault: keepsDefault)
        }
    }

    /// Accepts a bundle whose policy exception or preflight failed, so it can
    /// be used anyway. The choice is remembered for that version.
    func skipFailedChecks() {
        guard let current = progress, current.canSkip, let version = current.version else {
            return
        }
        for step in current.plan where current.status(step) != .passed {
            set(step, .warning)
        }
        progress?.error = nil
        setAccepted(version, true)
    }

    func dismissProgress() {
        progress = nil
    }

    // MARK: - Persistence

    private static var progressFile: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("vphone-launchpad", isDirectory: true)
            .appendingPathComponent("bundle-install.json")
    }

    private static func saveProgress(_ progress: InstallProgress?) {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return
            }
        #endif
        let file = progressFile
        guard let progress else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? VPhoneLaunchpadBundleReceipt.encoder.encode(progress).write(to: file, options: .atomic)
    }

    /// A step still marked running belonged to a Launchpad that quit.
    private static func loadProgress() -> InstallProgress? {
        guard let data = try? Data(contentsOf: progressFile),
              var progress = try? VPhoneLaunchpadBundleReceipt.decoder.decode(InstallProgress.self, from: data)
        else {
            return nil
        }
        let interrupted = progress.plan.filter { progress.status($0) == .running }
        guard !interrupted.isEmpty else {
            return progress
        }
        for step in interrupted {
            progress.steps[step] = .failed
        }
        progress.error = VPhoneLaunchpadError(String(localized: "Launchpad quit before the install finished. Retry to continue."))
        return progress
    }

    private func set(_ step: InstallStep, _ status: VPhoneLaunchpadStatus) {
        progress?.steps[step] = status
    }

    // MARK: - Default and remove

    /// Makes `version` the default for new machines and library-wide
    /// commands. Machines keep the version they are bound to.
    func setDefault(_ version: String) async {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else { return }
        defaultVersion = version
        await verify(version)
    }

    /// The machines bound to a version that are running or busy, by name. The
    /// model connects this to the machine library, which knows the bindings.
    var activeMachines: @MainActor (String) -> [String] = { _ in [] }

    /// Refuses a version a running or busy machine uses, since its files are
    /// in use. Stopped machines bound to it are left damaged until they are
    /// given another Core Bundle.
    func remove(_ version: String) async {
        let active = activeMachines(version)
        guard active.isEmpty else {
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Remove VPhone.bundle \(version)"),
                detail: String(localized: "These machines are running from it: \(active.joined(separator: ", ")). Stop them first."),
            )
            return
        }
        do {
            try await helper.removeBundle(version: version)
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Remove VPhone.bundle \(version)"), detail: error.localizedDescription)
        }
        loadInstalled()
        if !installed.contains(where: { $0.version == version }) {
            setAccepted(version, false)
        }
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
            var progress = InstallProgress(release: releases[1])
            progress.steps = [.download: .passed, .verify: .passed, .install: .passed, .policy: .passed, .preflight: .failed]
            progress.error = VPhoneLaunchpadError(
                String(localized: "Host preflight failed. Fix the issue and retry, or skip to use this version anyway."),
                detail: "AMFI blocked vphone-vm",
            )
            self.progress = progress
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
