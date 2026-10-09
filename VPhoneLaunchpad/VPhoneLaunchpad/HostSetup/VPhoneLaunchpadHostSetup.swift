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
    }

    let kind: Kind
    let title: String
    var status: VPhoneLaunchpadStatus = .pending
    var detail = ""

    var id: Kind {
        kind
    }
}

// MARK: - Host setup

/// The first stage. Every check must pass, or be skipped, before a Core
/// Bundle can be installed.
@MainActor
@Observable
final class VPhoneLaunchpadHostSetup {
    private(set) var checks: [VPhoneLaunchpadHostCheck] = [
        .init(kind: .appleSilicon, title: String(localized: "Apple silicon")),
        .init(kind: .macOS, title: String(localized: "macOS 15 or later")),
        .init(kind: .physicalMac, title: String(localized: "Physical Mac")),
        .init(kind: .libraryVolume, title: String(localized: "Library on APFS")),
        .init(kind: .developerTools, title: String(localized: "Developer Tools access")),
        .init(kind: .helper, title: String(localized: "Privileged helper")),
    ]
    private(set) var isChecking = false
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

    var requiredPassed: Bool {
        checks.allSatisfy(isSatisfied)
    }

    var passedCount: Int {
        checks.count(where: isSatisfied)
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
        // The helper row keeps its last result until the helper answers, so a
        // recheck does not blank it.
        await helper.refresh()
        update(.helper, helperStatus())
    }

    /// The checks that need no helper. They run at init, so the
    /// first frame already shows them.
    private func checkLocally() {
        update(.appleSilicon, Self.appleSilicon())
        update(.macOS, Self.macOSVersion())
        update(.physicalMac, Self.physicalMac())
        update(.libraryVolume, Self.libraryVolume(libraryRoot))
        update(.developerTools, developerTools())
        update(.helper, helperStatus())
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

    /// Quits and opens this copy of Launchpad again. A shell waits for this
    /// process to exit first, so the new one can take the control socket, and
    /// gives up after 10 seconds in case the quit was cancelled. An open sheet
    /// makes AppKit refuse to terminate, so sheets are ended first.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && exit 0; sleep 0.2; done; exec /usr/bin/open \"$2\"",
            "relaunch", String(getpid()), Bundle.main.bundlePath,
        ]
        do {
            try process.run()
        } catch {
            return
        }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

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
        }
    }
#endif
