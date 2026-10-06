import AppKit
import Darwin
import ExecutionPolicy
import Foundation
import Observation

// MARK: - Check

struct VPhoneLaunchpadHostCheck: Identifiable, Equatable {
    enum Kind: String {
        case appleSilicon
        case macOS
        case physicalMac
        case libraryVolume
        case developerTools
        case helper
        case diskSpace
        case resources
        case network
    }

    let kind: Kind
    let title: String
    let isRequired: Bool
    var status: VPhoneLaunchpadStatus = .pending
    var detail = ""

    var id: Kind {
        kind
    }
}

// MARK: - Host setup

/// The first stage. Required checks gate the Core Bundle section; advisory
/// ones only warn.
@MainActor
@Observable
final class VPhoneLaunchpadHostSetup {
    private(set) var checks: [VPhoneLaunchpadHostCheck] = [
        .init(kind: .appleSilicon, title: String(localized: "Apple silicon"), isRequired: true),
        .init(kind: .macOS, title: String(localized: "macOS 15 or later"), isRequired: true),
        .init(kind: .physicalMac, title: String(localized: "Physical Mac"), isRequired: true),
        .init(kind: .libraryVolume, title: String(localized: "Library on APFS"), isRequired: true),
        .init(kind: .developerTools, title: String(localized: "Developer Tools access"), isRequired: true),
        .init(kind: .helper, title: String(localized: "Privileged helper"), isRequired: true),
        .init(kind: .diskSpace, title: String(localized: "Free disk space"), isRequired: false),
        .init(kind: .resources, title: String(localized: "CPU and memory"), isRequired: false),
        .init(kind: .network, title: String(localized: "Network"), isRequired: false),
    ]
    private(set) var isChecking = false
    private(set) var isChangingUnattendedVMManagement = false
    var actionError: VPhoneLaunchpadError?
    /// Set once Settings was opened for Developer Tools, so a refusal then
    /// reads "Not allowed" rather than "Not requested".
    private(set) var didOpenDeveloperTools = false

    let helper: VPhoneLaunchpadHelperClient
    let libraryRoot: URL

    init(helper: VPhoneLaunchpadHelperClient, libraryRoot: URL) {
        self.helper = helper
        self.libraryRoot = libraryRoot
        checkLocally()
    }

    var required: [VPhoneLaunchpadHostCheck] {
        checks.filter(\.isRequired)
    }

    var advisory: [VPhoneLaunchpadHostCheck] {
        checks.filter { !$0.isRequired }
    }

    var requiredPassed: Bool {
        required.allSatisfy(isSatisfied)
    }

    var passedRequiredCount: Int {
        required.count(where: isSatisfied)
    }

    func isSatisfied(_ check: VPhoneLaunchpadHostCheck) -> Bool {
        check.status == .passed || isSkipped(check)
    }

    // MARK: - Skipping

    /// Checks that can misjudge an unusual host, such as a Mac mini in a
    /// rack or a library on a network volume. The user may take the risk and
    /// skip them; the bundle's own preflight still runs. Developer Tools
    /// access and the helper cannot be skipped: installing needs both.
    static let skippable: Set<VPhoneLaunchpadHostCheck.Kind> = [.macOS, .physicalMac, .libraryVolume]
    private static let skippedKey = "VPhoneLaunchpadSkippedHostChecks"

    private(set) var skipped: Set<VPhoneLaunchpadHostCheck.Kind> = Set(
        (UserDefaults.standard.stringArray(forKey: skippedKey) ?? []).compactMap(VPhoneLaunchpadHostCheck.Kind.init),
    )

    func isSkipped(_ check: VPhoneLaunchpadHostCheck) -> Bool {
        check.status != .passed && skipped.contains(check.kind)
    }

    func canSkip(_ check: VPhoneLaunchpadHostCheck) -> Bool {
        Self.skippable.contains(check.kind) && (check.status == .failed || check.status == .warning)
    }

    func setSkipped(_ kind: VPhoneLaunchpadHostCheck.Kind, _ isSkipped: Bool) {
        if isSkipped {
            skipped.insert(kind)
        } else {
            skipped.remove(kind)
        }
        UserDefaults.standard.set(skipped.map(\.rawValue).sorted(), forKey: Self.skippedKey)
    }

    /// The Developer Tools row as last checked. `refreshDeveloperTools()`
    /// checks again; the app does so whenever it becomes active.
    var isDeveloperToolAuthorized: Bool {
        checks.first { $0.kind == .developerTools }?.status == .passed
    }

    /// Settings cannot lift a restriction set by the system or a profile.
    var canRequestDeveloperTools: Bool {
        EPDeveloperTool().authorizationStatus != .restricted
    }

    // MARK: - Checking

    func refresh() async {
        guard !isChecking else {
            return
        }
        isChecking = true
        defer { isChecking = false }

        checkLocally()
        if checks.first(where: { $0.kind == .network })?.status == .pending {
            update(.network, (.running, String(localized: "Checking…")))
        }
        // The helper and network rows keep their last result until these
        // answer, so a recheck does not blank them.
        await helper.refresh()
        update(.helper, helperStatus())
        await update(.network, Self.network())
    }

    /// The checks that need no helper or network. They run at init, so the
    /// first frame already shows them.
    private func checkLocally() {
        update(.appleSilicon, Self.appleSilicon())
        update(.macOS, Self.macOSVersion())
        update(.physicalMac, Self.physicalMac())
        update(.libraryVolume, Self.libraryVolume(libraryRoot))
        update(.developerTools, developerTools())
        update(.helper, helperStatus())
        update(.diskSpace, Self.diskSpace(libraryRoot))
        update(.resources, Self.resources())
    }

    /// Re-reads Developer Tools access alone, for when the app comes back
    /// from Settings.
    func refreshDeveloperTools() {
        update(.developerTools, developerTools())
    }

    private func update(_ kind: VPhoneLaunchpadHostCheck.Kind, _ result: (VPhoneLaunchpadStatus, String)) {
        guard let index = checks.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        checks[index].status = result.0
        checks[index].detail = result.1
    }

    // MARK: - Actions

    /// Opens Privacy & Security → Developer Tools with Launchpad listed.
    /// `requestAccess()` only adds the row to Settings and shows no UI, so
    /// the pane is opened explicitly.
    func requestDeveloperTools() async {
        _ = await EPDeveloperTool().requestAccess()
        didOpenDeveloperTools = true
        update(.developerTools, developerTools())
        NSWorkspace.shared.open(Self.developerToolsSettings)
    }

    private static let developerToolsSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_DevTools",
    )!

    func installHelper() async {
        update(.helper, (.running, String(localized: "Waiting for administrator approval…")))
        do {
            try await helper.install()
        } catch is CancellationError {
        } catch let error as VPhoneLaunchpadError {
            actionError = error
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Install Helper"), detail: String(localized: "Try again."))
        }
        update(.helper, helperStatus())
    }

    func setUnattendedVMManagement(_ enabled: Bool) async {
        guard !isChangingUnattendedVMManagement else { return }
        isChangingUnattendedVMManagement = true
        defer { isChangingUnattendedVMManagement = false }
        do {
            if enabled {
                try await helper.enableUnattendedVMManagement()
            } else {
                try await helper.disableUnattendedVMManagement()
            }
        } catch is CancellationError {
        } catch let error as VPhoneLaunchpadError {
            actionError = error
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Change Unattended VM Management"), detail: error.localizedDescription)
        }
    }

    /// `EPDeveloperTool.authorizationStatus` keeps the answer this process
    /// launched with: a grant or a revocation in Settings does not reach it
    /// until a relaunch. syspolicyd checks the grant itself on every exception
    /// request, so that request is what decides; the reported status only
    /// names a refusal, or answers when syspolicyd could not be asked.
    private func developerTools() -> (VPhoneLaunchpadStatus, String) {
        let reported = EPDeveloperTool().authorizationStatus
        switch Self.developerToolGrant() {
        case true?:
            return (.passed, String(localized: "Allowed"))
        case false? where reported == .restricted:
            return (.failed, String(localized: "Restricted by the system"))
        case false? where reported == .notDetermined && !didOpenDeveloperTools:
            return (.pending, String(localized: "Not requested"))
        case false?:
            return (.failed, String(localized: "Not allowed"))
        case nil:
            switch reported {
            case .authorized: return (.passed, String(localized: "Allowed"))
            case .denied: return (.failed, String(localized: "Not allowed"))
            case .restricted: return (.failed, String(localized: "Restricted by the system"))
            default: return (.pending, String(localized: "Not requested"))
            }
        }
    }

    /// Whether syspolicyd takes this process for a developer tool now: it
    /// refuses an execution policy exception to any other caller. The
    /// exception asked for is for Launchpad's own running executable, which
    /// it already lets run, so granting it changes nothing. Nil when the
    /// request failed for another reason.
    private nonisolated static func developerToolGrant() -> Bool? {
        guard let executable = Bundle.main.executableURL else {
            return nil
        }
        do {
            try EPExecutionPolicy().addException(for: executable)
            return true
        } catch let error as EPError where error.code == .notADeveloperTool {
            return false
        } catch {
            return nil
        }
    }

    private func helperStatus() -> (VPhoneLaunchpadStatus, String) {
        switch helper.state {
        case .unknown:
            (.running, String(localized: "Checking…"))
        case .notInstalled:
            (.pending, String(localized: "Not installed"))
        case let .outdated(installed, bundled):
            (.pending, String(localized: "Version \(installed) installed, \(bundled) available"))
        case let .ready(version):
            (.passed, String(localized: "Version \(version)"))
        case .unconfigured:
            (.failed, String(localized: "Not available in this build"))
        }
    }

    // MARK: - Probes

    nonisolated static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
    }

    private nonisolated static func appleSilicon() -> (VPhoneLaunchpadStatus, String) {
        sysctlInt("hw.optional.arm64") == 1 ? (.passed, "arm64") : (.failed, String(localized: "Intel Macs are not supported"))
    }

    private nonisolated static func macOSVersion() -> (VPhoneLaunchpadStatus, String) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(version.majorVersion).\(version.minorVersion)"
        return version.majorVersion >= 15 ? (.passed, text) : (.failed, String(localized: "macOS \(text) is not supported"))
    }

    private nonisolated static func physicalMac() -> (VPhoneLaunchpadStatus, String) {
        let present = sysctlInt("kern.hv_vmm_present") ?? 0
        return present == 0
            ? (.passed, String(localized: "Not a virtual machine"))
            : (.failed, String(localized: "Running in a virtual machine"))
    }

    private nonisolated static func libraryVolume(_ root: URL) -> (VPhoneLaunchpadStatus, String) {
        let path = existingAncestor(of: root).path
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            return (.failed, String(localized: "Cannot read the volume of \(abbreviated(root))"))
        }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "apfs"
            ? (.passed, abbreviated(root))
            : (.failed, String(localized: "\(abbreviated(root)) is on \(type), not APFS"))
    }

    private nonisolated static func diskSpace(_ root: URL) -> (VPhoneLaunchpadStatus, String) {
        let url = existingAncestor(of: root)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return (.warning, String(localized: "Unknown"))
        }
        let gigabytes = available / 1_000_000_000
        return gigabytes >= 100
            ? (.passed, String(localized: "\(gigabytes) GB free"))
            : (.warning, String(localized: "\(gigabytes) GB free, 100 GB recommended"))
    }

    private nonisolated static func resources() -> (VPhoneLaunchpadStatus, String) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let memory = ProcessInfo.processInfo.physicalMemory / (1 << 30)
        let text = String(localized: "\(cores) cores, \(memory) GB")
        return cores >= 8 && memory >= 16 ? (.passed, text) : (.warning, String(localized: "\(text); 8 cores, 16 GB recommended"))
    }

    private nonisolated static func network() async -> (VPhoneLaunchpadStatus, String) {
        let hosts = ["updates.cdn-apple.com", "api.github.com"]
        var unreachable: [String] = []
        for host in hosts {
            var request = URLRequest(url: URL(string: "https://\(host)/")!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 6
            if await (try? URLSession.shared.data(for: request)) == nil {
                unreachable.append(host)
            }
        }
        return unreachable.isEmpty
            ? (.passed, hosts.joined(separator: ", "))
            : (.warning, String(localized: "Cannot reach \(unreachable.joined(separator: ", "))"))
    }

    nonisolated static func existingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    nonisolated static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

#if DEBUG
    extension VPhoneLaunchpadHostSetup {
        func applyPreview(blocked: Bool) {
            update(.appleSilicon, (.passed, "arm64"))
            update(.macOS, (.passed, "27.0"))
            update(.physicalMac, (.passed, String(localized: "Not a virtual machine")))
            update(.libraryVolume, (.passed, "~/.vphone/machines"))
            update(.developerTools, blocked ? (.pending, String(localized: "Not requested")) : (.passed, String(localized: "Allowed")))
            update(.helper, blocked ? (.pending, String(localized: "Not installed")) : (.passed, String(localized: "Version \("1")")))
            update(.diskSpace, (.warning, String(localized: "\(84) GB free, 100 GB recommended")))
            update(.resources, (.passed, String(localized: "\(12) cores, \(UInt64(36)) GB")))
            update(.network, (.passed, "updates.cdn-apple.com, api.github.com"))
        }
    }
#endif
