import Foundation
import Observation

/// Owns the host checks, the installed bundles and the machine library. The
/// window always shows the machines; Host Setup and Core Bundle are sheets
/// over it. On launch the first stage that is not ready opens by itself, and
/// a toolbar button marks a stage that regresses later.
@MainActor
@Observable
final class VPhoneLaunchpadModel {
    enum Panel: String, Identifiable {
        case hostSetup
        case coreBundle
        case bundleInstall
        case ipswCache
        case templates

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .hostSetup: String(localized: "Host Setup")
            case .coreBundle: String(localized: "Core Bundle")
            case .bundleInstall: String(localized: "Core Bundle Install")
            case .ipswCache: String(localized: "Downloaded Firmware")
            case .templates: String(localized: "Templates")
            }
        }
    }

    let history = VPhoneLaunchpadCommandHistory()
    let helper = VPhoneLaunchpadHelperClient()
    let libraryRoot: URL
    let host: VPhoneLaunchpadHostSetup
    let bundles: VPhoneLaunchpadCoreBundle
    let machines: VPhoneLaunchpadMachineLibrary
    let leases: VPhoneLaunchpadLeases
    /// IPSWs dropped on the window or opened with Launchpad, copied into the cache.
    let ipswImport = VPhoneLaunchpadIPSWImport()

    var panel: Panel?
    /// The panel to open once the sheet on screen has closed.
    private var queuedPanel: Panel?
    private(set) var isStarted = false

    init() {
        libraryRoot = URL(fileURLWithPath: VPhoneLaunchpadMachineLocations.defaultRoot, isDirectory: true)
        host = VPhoneLaunchpadHostSetup(helper: helper, libraryRoot: libraryRoot)
        bundles = VPhoneLaunchpadCoreBundle(helper: helper, history: history)
        machines = VPhoneLaunchpadMachineLibrary(bundles: bundles, helper: helper)
        leases = VPhoneLaunchpadLeases(bundles: bundles, machines: machines, helper: helper)
        bundles.activeMachines = { [machines] version in machines.activeMachineNames(boundTo: version) }
    }

    // MARK: - Panels

    /// Opens `next`. Another panel on screen closes first, so `next` arrives
    /// as a sheet of its own instead of replacing that sheet's content.
    func present(_ next: Panel) {
        guard let current = panel, current != next else {
            panel = next
            return
        }
        queuedPanel = next
        panel = nil
    }

    /// Called when a panel's sheet starts to close. On macOS that is the same
    /// update that cleared `panel`, while the sheet is still attached; setting
    /// `next` here would swap it into the closing sheet. The next turn of the
    /// main actor runs after the sheet has gone.
    func panelDidDismiss() {
        guard let next = queuedPanel else {
            return
        }
        queuedPanel = nil
        Task { panel = next }
    }

    // MARK: - Attention

    var hostNeedsAttention: Bool {
        !host.isChecking && !host.requiredPassed
    }

    var bundleNeedsAttention: Bool {
        host.requiredPassed && !bundles.isReady && !bundles.isInstalling && bundles.progress?.canSkip != true
    }

    /// Installing a bundle needs the helper (root-owned store) and Developer
    /// Tools access (the execution policy exception).
    var canInstallBundles: Bool {
        guard case .ready = helper.state else {
            return false
        }
        return host.isDeveloperToolAuthorized && !bundles.isInstalling
    }

    /// Releasing DHCP leases runs through the helper; an outdated one is
    /// replaced on the way.
    var canReleaseLeases: Bool {
        switch helper.state {
        case .ready, .outdated: true
        default: false
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isStarted else {
            return
        }
        isStarted = true
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                await VPhoneLaunchpadPreview.run(self)
                return
            }
        #endif
        startControl()
        // Host checks, installed bundles and the helper state were read at
        // init. These confirm them without holding up the machine list; the
        // network probe and the GitHub lists come last.
        machines.startMonitoring()
        async let listed: Void = machines.refresh()
        async let hostChecked: Void = host.refresh()
        await bundles.checkDefault()
        await hostChecked
        if case .outdated = helper.state {
            await host.installHelper()
            await host.refresh()
            await bundles.checkDefault()
        }
        await listed
        // An unfinished install reopens its own sheet instead.
        if panel == nil {
            if bundles.progress == nil || bundles.progress?.isFinished == true {
                panel = !host.requiredPassed ? .hostSetup : !bundles.isReady ? .coreBundle : nil
            } else {
                panel = .bundleInstall
            }
        }
        await bundles.fetchReleases()
    }

    // MARK: - Command line

    /// Serves `vphone-launchpad-cli` for as long as the app runs. Without the
    /// socket the window works as before; the CLI then says it cannot connect.
    private var control: VPhoneLaunchpadControlServer?

    private func startControl() {
        let commands = VPhoneLaunchpadControlCommands(model: self)
        let server = VPhoneLaunchpadControlServer { request, emit in
            await commands.handle(request, emit: emit)
        }
        do {
            try server.start()
            control = server
        } catch {
            print("[control] \(VPhoneLaunchpadError.message(for: error))")
        }
    }

    func refreshHost() async {
        await host.refresh()
        await leases.refresh()
    }

    // MARK: - Machine requests

    /// A sheet or a delete confirmation the shared actions menu asked for,
    /// possibly from the menu bar. The machine list presents it and clears it.
    var machineSheetRequest: VPhoneLaunchpadMachinesView.Sheet?
    var deletionRequest: [VPhoneLaunchpadMachinePath] = []

    // MARK: - Bundle install

    /// An install shows its progress in a sheet of its own, which replaces
    /// the Core Bundle sheet it started from.
    /// `keepsDefault` leaves the default version as it is, as
    /// `vphone-launchpad-cli bundle install-* --keep-default` asks.
    func installBundle(_ release: VPhoneLaunchpadRelease, keepsDefault: Bool = false) async {
        revealInstall()
        await bundles.install(release, keepsDefault: keepsDefault)
        await machines.refresh()
    }

    func installLocalBundle(_ source: URL, keepsDefault: Bool = false) async {
        revealInstall()
        await bundles.installLocal(source, keepsDefault: keepsDefault)
        await machines.refresh()
    }

    func retryInstall() async {
        await bundles.retry()
        await machines.refresh()
    }

    private func revealInstall() {
        present(.bundleInstall)
    }

    /// Refused while a machine is bound to the version; the error lands in
    /// `bundles.actionError`.
    func removeBundle(_ version: String) async {
        await machines.refresh()
        await bundles.remove(version)
        if let fallback = bundles.defaultVersion, bundles.defaultBundle?.preflight == .pending {
            await bundles.verify(fallback)
        }
    }
}
