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
    var actionError: VPhoneLaunchpadError?
    /// Set once Settings was opened for Developer Tools. The status the
    /// system reports can lag the switch, so Reopen is offered from then on.
    private(set) var didOpenDeveloperTools = false

    /// Developer Tools access applies to processes launched after it is
    /// granted. This process keeps the access it started with.
    @ObservationIgnored private let launchDeveloperToolStatus = EPDeveloperTool().authorizationStatus

    let helper: VPhoneLaunchpadHelperClient
    let libraryRoot: URL

    init(helper: VPhoneLaunchpadHelperClient, libraryRoot: URL) {
        self.helper = helper
        self.libraryRoot = libraryRoot
    }

    var required: [VPhoneLaunchpadHostCheck] {
        checks.filter(\.isRequired)
    }

    var advisory: [VPhoneLaunchpadHostCheck] {
        checks.filter { !$0.isRequired }
    }

    var requiredPassed: Bool {
        required.allSatisfy { $0.status == .passed }
    }

    var passedRequiredCount: Int {
        required.count(where: { $0.status == .passed })
    }

    var isDeveloperToolAuthorized: Bool {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return checks.first { $0.kind == .developerTools }?.status == .passed
            }
        #endif
        return launchDeveloperToolStatus == .authorized && EPDeveloperTool().authorizationStatus == .authorized
    }

    /// False once the system reports the grant, even before a relaunch.
    var canRequestDeveloperTools: Bool {
        EPDeveloperTool().authorizationStatus != .authorized
    }

    /// True when a grant made after launch needs a relaunch to apply.
    var needsRelaunch: Bool {
        launchDeveloperToolStatus != .authorized
            && (didOpenDeveloperTools || EPDeveloperTool().authorizationStatus == .authorized)
    }

    // MARK: - Checking

    func refresh() async {
        guard !isChecking else {
            return
        }
        isChecking = true
        defer { isChecking = false }

        update(.appleSilicon, Self.appleSilicon())
        update(.macOS, Self.macOSVersion())
        update(.physicalMac, Self.physicalMac())
        update(.libraryVolume, Self.libraryVolume(libraryRoot))
        update(.developerTools, developerTools())
        update(.helper, (.running, String(localized: "Checking…")))
        update(.diskSpace, Self.diskSpace(libraryRoot))
        update(.resources, Self.resources())
        update(.network, (.running, String(localized: "Checking…")))

        await helper.refresh()
        update(.helper, helperStatus())
        update(.network, await Self.network())
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

    /// Quits and opens Launchpad again so a new Developer Tools grant
    /// applies. A detached waiter opens the app once this process has exited.
    /// No machine can be in creation here: Core Bundle needs this access.
    func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh",
            String(getpid()),
            Bundle.main.bundlePath,
        ]
        do {
            try waiter.run()
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Reopen"), detail: String(localized: "Quit vphone-launchpad and open it again."))
            return
        }
        NSApp.terminate(nil)
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

    private func developerTools() -> (VPhoneLaunchpadStatus, String) {
        switch EPDeveloperTool().authorizationStatus {
        case .authorized where launchDeveloperToolStatus == .authorized:
            (.passed, String(localized: "Allowed"))
        case .authorized:
            (.pending, String(localized: "Reopen to apply"))
        case .denied:
            (.failed, String(localized: "Not allowed"))
        case .restricted:
            (.failed, String(localized: "Restricted by the system"))
        default:
            (.pending, String(localized: "Not requested"))
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
            (.failed, String(localized: "No signing team in this build"))
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

    nonisolated private static func appleSilicon() -> (VPhoneLaunchpadStatus, String) {
        sysctlInt("hw.optional.arm64") == 1 ? (.passed, "arm64") : (.failed, String(localized: "Intel Macs are not supported"))
    }

    nonisolated private static func macOSVersion() -> (VPhoneLaunchpadStatus, String) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(version.majorVersion).\(version.minorVersion)"
        return version.majorVersion >= 15 ? (.passed, text) : (.failed, String(localized: "macOS \(text) is not supported"))
    }

    nonisolated private static func physicalMac() -> (VPhoneLaunchpadStatus, String) {
        let present = sysctlInt("kern.hv_vmm_present") ?? 0
        return present == 0
            ? (.passed, String(localized: "Not a virtual machine"))
            : (.failed, String(localized: "Running in a virtual machine"))
    }

    nonisolated private static func libraryVolume(_ root: URL) -> (VPhoneLaunchpadStatus, String) {
        let path = existingAncestor(of: root).path
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            return (.failed, String(localized: "Cannot read the volume of \(abbreviated(root))"))
        }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "apfs"
            ? (.passed, abbreviated(root))
            : (.failed, String(localized: "\(abbreviated(root)) is on \(type)"))
    }

    nonisolated private static func diskSpace(_ root: URL) -> (VPhoneLaunchpadStatus, String) {
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

    nonisolated private static func resources() -> (VPhoneLaunchpadStatus, String) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let memory = ProcessInfo.processInfo.physicalMemory / (1 << 30)
        let text = String(localized: "\(cores) cores, \(memory) GB")
        return cores >= 8 && memory >= 16 ? (.passed, text) : (.warning, String(localized: "\(text); 8 cores, 16 GB recommended"))
    }

    nonisolated private static func network() async -> (VPhoneLaunchpadStatus, String) {
        let hosts = ["updates.cdn-apple.com", "api.github.com"]
        var unreachable: [String] = []
        for host in hosts {
            var request = URLRequest(url: URL(string: "https://\(host)/")!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 6
            if (try? await URLSession.shared.data(for: request)) == nil {
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
