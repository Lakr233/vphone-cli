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
        .init(kind: .appleSilicon, title: "Apple silicon", isRequired: true),
        .init(kind: .macOS, title: "macOS 15 or later", isRequired: true),
        .init(kind: .physicalMac, title: "Physical Mac", isRequired: true),
        .init(kind: .libraryVolume, title: "Library on APFS", isRequired: true),
        .init(kind: .developerTools, title: "Developer Tools access", isRequired: true),
        .init(kind: .helper, title: "Privileged helper", isRequired: true),
        .init(kind: .diskSpace, title: "Free disk space", isRequired: false),
        .init(kind: .resources, title: "CPU and memory", isRequired: false),
        .init(kind: .network, title: "Network", isRequired: false),
    ]
    private(set) var isChecking = false
    var actionError: VPhoneLaunchpadError?

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
        return EPDeveloperTool().authorizationStatus == .authorized
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
        update(.helper, (.running, "Checking…"))
        update(.diskSpace, Self.diskSpace(libraryRoot))
        update(.resources, Self.resources())
        update(.network, (.running, "Checking…"))

        await helper.refresh()
        update(.helper, helperStatus())
        update(.network, await Self.network())
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
    func requestDeveloperTools() async {
        _ = await EPDeveloperTool().requestAccess()
        update(.developerTools, developerTools())
    }

    func installHelper() async {
        update(.helper, (.running, "Waiting for an administrator…"))
        do {
            try await helper.install()
        } catch is CancellationError {
        } catch let error as VPhoneLaunchpadError {
            actionError = error
        } catch {
            actionError = VPhoneLaunchpadError("The helper could not be installed.", detail: "\(error)")
        }
        update(.helper, helperStatus())
    }

    private func developerTools() -> (VPhoneLaunchpadStatus, String) {
        switch EPDeveloperTool().authorizationStatus {
        case .authorized:
            (.passed, "Allowed")
        case .denied:
            (.failed, "Not allowed")
        case .restricted:
            (.failed, "Restricted by the system")
        default:
            (.pending, "Not requested")
        }
    }

    private func helperStatus() -> (VPhoneLaunchpadStatus, String) {
        switch helper.state {
        case .unknown:
            (.running, "Checking…")
        case .notInstalled:
            (.pending, "Not installed")
        case let .outdated(installed, bundled):
            (.pending, "Version \(installed) installed, \(bundled) available")
        case let .ready(version):
            (.passed, "Version \(version)")
        case .unconfigured:
            (.failed, "No signing team in this build")
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
        sysctlInt("hw.optional.arm64") == 1 ? (.passed, "arm64") : (.failed, "Intel Macs are not supported")
    }

    nonisolated private static func macOSVersion() -> (VPhoneLaunchpadStatus, String) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(version.majorVersion).\(version.minorVersion)"
        return version.majorVersion >= 15 ? (.passed, text) : (.failed, "\(text) is too old")
    }

    nonisolated private static func physicalMac() -> (VPhoneLaunchpadStatus, String) {
        let present = sysctlInt("kern.hv_vmm_present") ?? 0
        return present == 0
            ? (.passed, "kern.hv_vmm_present = 0")
            : (.failed, "Running in a virtual machine")
    }

    nonisolated private static func libraryVolume(_ root: URL) -> (VPhoneLaunchpadStatus, String) {
        let path = existingAncestor(of: root).path
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            return (.failed, "Cannot read the volume of \(abbreviated(root))")
        }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "apfs"
            ? (.passed, abbreviated(root))
            : (.failed, "\(abbreviated(root)) is on \(type)")
    }

    nonisolated private static func diskSpace(_ root: URL) -> (VPhoneLaunchpadStatus, String) {
        let url = existingAncestor(of: root)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return (.warning, "Unknown")
        }
        let gigabytes = available / 1_000_000_000
        return gigabytes >= 100
            ? (.passed, "\(gigabytes) GB free")
            : (.warning, "\(gigabytes) GB free, 100 GB recommended")
    }

    nonisolated private static func resources() -> (VPhoneLaunchpadStatus, String) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let memory = ProcessInfo.processInfo.physicalMemory / (1 << 30)
        let text = "\(cores) cores, \(memory) GB"
        return cores >= 8 && memory >= 16 ? (.passed, text) : (.warning, "\(text); 8 cores, 16 GB recommended")
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
            : (.warning, "Cannot reach \(unreachable.joined(separator: ", "))")
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
            update(.physicalMac, (.passed, "kern.hv_vmm_present = 0"))
            update(.libraryVolume, (.passed, "~/.vphone/machines"))
            update(.developerTools, blocked ? (.pending, "Not requested") : (.passed, "Allowed"))
            update(.helper, blocked ? (.pending, "Not installed") : (.passed, "Version 1"))
            update(.diskSpace, (.warning, "84 GB free, 100 GB recommended"))
            update(.resources, (.passed, "12 cores, 36 GB"))
            update(.network, (.passed, "updates.cdn-apple.com, api.github.com"))
        }
    }
#endif
