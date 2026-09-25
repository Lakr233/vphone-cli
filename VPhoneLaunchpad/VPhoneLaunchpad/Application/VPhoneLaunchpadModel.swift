import Foundation
import Observation

/// Owns the three stages and decides which of them the segmented control
/// shows. Host Setup is always there; Core Bundle appears once the required
/// host checks pass; Machines appears once the active bundle passes host
/// preflight. After setup has completed once, all three stay visible and a
/// regression only marks Host Setup, so machines are never hidden by, say,
/// a helper that needs updating.
@MainActor
@Observable
final class VPhoneLaunchpadModel {
    enum Section: String, CaseIterable, Identifiable {
        case hostSetup
        case coreBundle
        case machines

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .hostSetup: String(localized: "Host Setup")
            case .coreBundle: String(localized: "Core Bundle")
            case .machines: String(localized: "Machines")
            }
        }
    }

    let history = VPhoneLaunchpadCommandHistory()
    let helper = VPhoneLaunchpadHelperClient()
    let libraryRoot: URL
    let host: VPhoneLaunchpadHostSetup
    let bundles: VPhoneLaunchpadCoreBundle
    let machines: VPhoneLaunchpadMachineLibrary

    var selection: Section = .hostSetup
    private(set) var isStarted = false

    private static let setupCompletedKey = "VPhoneLaunchpadSetupCompleted"
    private static let showAllSectionsKey = "VPhoneLaunchpadShowAllSections"

    init() {
        let environment = ProcessInfo.processInfo.environment["VPHONE_LIBRARY_ROOT"]
        libraryRoot = environment.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/machines", isDirectory: true)
        host = VPhoneLaunchpadHostSetup(helper: helper, libraryRoot: libraryRoot)
        bundles = VPhoneLaunchpadCoreBundle(helper: helper, history: history)
        machines = VPhoneLaunchpadMachineLibrary(libraryRoot: libraryRoot, bundles: bundles, helper: helper)
    }

    // MARK: - Sections

    #if DEBUG
        /// Snapshot mode keeps setup state in memory, off the real defaults.
        var previewSetupCompleted: Bool?
    #endif

    private var setupCompleted: Bool {
        get {
            access(keyPath: \.setupCompleted)
            #if DEBUG
                if let previewSetupCompleted {
                    return previewSetupCompleted
                }
            #endif
            return UserDefaults.standard.bool(forKey: Self.setupCompletedKey)
        }
        set {
            withMutation(keyPath: \.setupCompleted) {
                UserDefaults.standard.set(newValue, forKey: Self.setupCompletedKey)
            }
        }
    }

    var sections: [Section] {
        #if DEBUG
            if UserDefaults.standard.bool(forKey: Self.showAllSectionsKey) {
                return Section.allCases
            }
        #endif
        if setupCompleted {
            return Section.allCases
        }
        var sections: [Section] = [.hostSetup]
        if host.requiredPassed {
            sections.append(.coreBundle)
            if bundles.isReady {
                sections.append(.machines)
            }
        }
        return sections
    }

    func title(for section: Section) -> String {
        switch section {
        case .hostSetup where setupCompleted && !host.isChecking && !host.requiredPassed:
            "\(section.title) ▲"
        case .coreBundle where setupCompleted && !bundles.isReady && !bundles.installed.isEmpty:
            "\(section.title) ▲"
        default:
            section.title
        }
    }

    /// Installing a bundle needs the helper (root-owned store) and Developer
    /// Tools access (the execution policy exception).
    var canInstallBundles: Bool {
        guard case .ready = helper.state else {
            return false
        }
        return host.isDeveloperToolAuthorized && !bundles.isInstalling
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
        await host.refresh()
        await bundles.refresh()
        await machines.refresh()
        machines.startMonitoring()
        advance(selectNewest: true)
    }

    func refreshHost() async {
        await host.refresh()
        advance(selectNewest: true)
    }

    func installBundle(_ release: VPhoneLaunchpadRelease) async {
        await bundles.install(release)
        await machines.refresh()
        advance(selectNewest: false)
    }

    func removeBundle(_ version: String) async {
        await bundles.remove(version)
        if let active = bundles.activeVersion, bundles.active?.preflight == .pending {
            await bundles.verify(active)
        }
        advance(selectNewest: false)
    }

    /// Records completed setup and moves the selection to a newly revealed
    /// section, or back to one that still exists.
    private func advance(selectNewest: Bool) {
        let before = sections
        if host.requiredPassed, bundles.isReady {
            setupCompleted = true
        }
        let after = sections
        if selectNewest || after.count > before.count || !after.contains(selection) {
            selection = after.last ?? .hostSetup
        }
    }
}
