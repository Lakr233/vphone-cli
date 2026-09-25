import Darwin
import Foundation
import Observation

/// `vm create`, one command at a time.
///
/// `vphone-cli vm create` runs the same stages in one process and asks for
/// sudo partway through, which a GUI cannot answer. Running the stages here
/// keeps every step visible and retryable, and keeps root to the one step
/// that needs it: `cfw install`, run by the helper. The waits mirror
/// VPhoneVirtualMachineCreator: the device identity file, 90 recovery probes,
/// up to 30 seconds for the post-restore panic, 5 seconds before CFW, and up
/// to 300 seconds for vphoned to answer on first boot.
@MainActor
@Observable
final class VPhoneLaunchpadCreationPipeline {
    struct Options: Sendable {
        var name: String
        var iphoneSource: String
        var cloudOSSource: String
        var cpuCount: Int
        var memoryMB: Int
        var diskSizeGB: Int
        var network: String
        var enableFrida: Bool
        var forceDyldSharedCacheMaxSlide: Bool
        var keepArtifacts: Bool
    }

    enum Step: Int, CaseIterable, Identifiable, Comparable {
        case create
        case prepare
        case patch
        case bootDFU
        case waitDFU
        case restore
        case stopDFU
        case installCFW
        case firstBoot

        var id: Int {
            rawValue
        }

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .create: "Create bundle"
            case .prepare: "Download firmware"
            case .patch: "Patch boot chain"
            case .bootDFU: "Boot into DFU"
            case .waitDFU: "Wait for DFU"
            case .restore: "Restore"
            case .stopDFU: "Stop VM"
            case .installCFW: "Install CFW"
            case .firstBoot: "First boot"
            }
        }

        var needsRoot: Bool {
            self == .installCFW
        }
    }

    let options: Options
    private(set) var statuses: [Step: VPhoneLaunchpadStatus] = [:]
    private(set) var durations: [Step: TimeInterval] = [:]
    private(set) var current: Step?
    private(set) var log: [String] = []
    private(set) var failure: VPhoneLaunchpadError?
    private(set) var isRunning = false

    private let libraryRoot: URL
    private let bundles: VPhoneLaunchpadCoreBundle
    private let helper: VPhoneLaunchpadHelperClient
    private weak var library: VPhoneLaunchpadMachineLibrary?
    private var task: Task<Void, Never>?
    private var dfu: VPhoneLaunchpadChildProcess?
    private var dfuLines: [String] = []

    nonisolated static let panicPattern = #"(^|[^p])(panic|kernel panic|panic\.apple\.com|stackshot succeeded)"#

    init(
        options: Options,
        libraryRoot: URL,
        bundles: VPhoneLaunchpadCoreBundle,
        helper: VPhoneLaunchpadHelperClient,
        library: VPhoneLaunchpadMachineLibrary,
    ) {
        self.options = options
        self.libraryRoot = libraryRoot
        self.bundles = bundles
        self.helper = helper
        self.library = library
    }

    var isFinished: Bool {
        statuses[.firstBoot] == .passed
    }

    func status(_ step: Step) -> VPhoneLaunchpadStatus {
        statuses[step] ?? .pending
    }

    /// The step a retry starts from: the one that failed.
    var failedStep: Step? {
        Step.allCases.first { statuses[$0] == .failed }
    }

    func command(for step: Step) -> String {
        let name = options.name
        return switch step {
        case .create: "vm new \(name) --cpu \(options.cpuCount) --memory \(options.memoryMB) --disk-size \(options.diskSizeGB)"
        case .prepare: "fw prepare \(name)"
        case .patch: "fw patch \(name)" + (options.enableFrida ? " --frida" : "")
        case .bootDFU: "vm launch \(name) --dfu"
        case .waitDFU: "recovery-probe --ecid …"
        case .restore: "restore \(name)"
        case .stopDFU: "vm stop \(name)"
        case .installCFW: "cfw install \(name)"
        case .firstBoot: "vm launch \(name)"
        }
    }

    // MARK: - Control

    func start(from first: Step = .create) {
        guard !isRunning else {
            return
        }
        failure = nil
        for step in Step.allCases where step >= first {
            statuses[step] = .pending
            durations[step] = nil
        }
        isRunning = true
        task = Task { await run(from: first) }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(from first: Step) async {
        defer {
            isRunning = false
            current = nil
            dfu?.terminate()
            dfu = nil
        }
        for step in Step.allCases where step >= first {
            current = step
            statuses[step] = .running
            let began = Date()
            do {
                try await perform(step)
                try Task.checkCancellation()
                statuses[step] = .passed
                durations[step] = Date().timeIntervalSince(began)
            } catch {
                statuses[step] = .failed
                durations[step] = Date().timeIntervalSince(began)
                if error is CancellationError || Task.isCancelled {
                    failure = VPhoneLaunchpadError("Cancelled during \(step.title.lowercased()).")
                } else {
                    failure = error as? VPhoneLaunchpadError
                        ?? VPhoneLaunchpadError("\(step.title) failed.", detail: error.localizedDescription)
                }
                append("✕ \(failure?.message ?? step.title)")
                await library?.refresh()
                return
            }
        }
        append("● \(options.name) is ready.")
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 3000 {
            log.removeFirst(log.count - 3000)
        }
    }

    // MARK: - Steps

    private func perform(_ step: Step) async throws {
        guard let commandLine = bundles.commandLine() else {
            throw VPhoneLaunchpadError("No core bundle is active.")
        }
        let name = options.name
        let library = ["--library-root", libraryRoot.path]
        let machine = libraryRoot.appendingPathComponent(name, isDirectory: true)
        let output: @MainActor @Sendable (String) -> Void = { [weak self] line in self?.append(line) }

        func run(_ arguments: [String]) async throws {
            append("$ \(VPhoneLaunchpadCommandLine.display(arguments))")
            try await commandLine.runChecked(arguments, onLine: output)
        }

        switch step {
        case .create:
            try await run(["vm", "new", name, "--cpu", String(options.cpuCount),
                           "--memory", String(options.memoryMB), "--disk-size", String(options.diskSizeGB)] + library)
            if options.network != "nat" {
                try await run(["vm", "config", name, "--network", options.network] + library)
            }
            await self.library?.refresh()

        case .prepare:
            try await run(["fw", "prepare", name, "--iphone-source", options.iphoneSource,
                           "--cloudos-source", options.cloudOSSource] + library)

        case .patch:
            try await run(["fw", "patch", name] + (options.enableFrida ? ["--frida"] : []) + library)

        case .bootDFU:
            let arguments = ["vm", "launch", name, "--dfu"] + library
            append("$ \(VPhoneLaunchpadCommandLine.display(arguments))")
            dfuLines = []
            dfu = try commandLine.start(
                arguments,
                logFile: VPhoneLaunchpadMachineLibrary.consoleLog(name, suffix: "-dfu"),
            ) { [weak self] line in
                self?.dfuLines.append(line)
                self?.append("dfu  \(line)")
            }
            let identity = machine.appendingPathComponent("udid-prediction.txt")
            for _ in 0 ..< 30 {
                if FileManager.default.fileExists(atPath: identity.path) {
                    return
                }
                try requireDFURunning()
                try await Task.sleep(for: .seconds(1))
            }
            throw VPhoneLaunchpadError("The DFU boot did not write udid-prediction.txt within 30 seconds.")

        case .waitDFU:
            let ecid = try Self.ecid(in: machine)
            append("$ vphone-cli recovery-probe --ecid \(ecid) --timeout 2  (up to 90 attempts)")
            for attempt in 1 ... 90 {
                try Task.checkCancellation()
                try requireDFURunning()
                let result = try await commandLine.run(
                    ["recovery-probe", "--ecid", ecid, "--timeout", "2"],
                    recordInHistory: attempt == 1,
                )
                if result.succeeded {
                    append("device endpoint is reachable")
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw VPhoneLaunchpadError("Timed out waiting for the device to enter recovery mode.")

        case .restore:
            try requireDFURunning()
            try await run(["restore", name] + library)

        case .stopDFU:
            append("waiting up to 30s for the post-restore reboot")
            for _ in 0 ..< 30 {
                if dfu?.isRunning != true || dfuLines.contains(where: Self.isPanic) {
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            try await run(["vm", "stop", name, "--timeout", "20"] + library)
            dfu?.terminate()
            dfu = nil
            append("waiting 5s for cleanup before CFW install")
            try await Task.sleep(for: .seconds(5))

        case .installCFW:
            guard let version = bundles.activeVersion else {
                throw VPhoneLaunchpadError("No core bundle is active.")
            }
            let status = try await helper.installCustomFirmware(
                bundleVersion: version,
                machineName: name,
                libraryRoot: Self.canonicalPath(libraryRoot),
                forceDyldSharedCacheMaxSlide: options.forceDyldSharedCacheMaxSlide,
                keepArtifacts: options.keepArtifacts,
                onLine: output,
            )
            guard status == 0 else {
                throw VPhoneLaunchpadError("cfw install exited with status \(status).", detail: log.suffix(12).joined(separator: "\n"))
            }

        case .firstBoot:
            try await firstBoot(name: name, machine: machine)
        }
    }

    /// Boots with a window, as `vm create` does, and waits for vphoned to
    /// answer on the VM's automation socket. The machine keeps running.
    private func firstBoot(name: String, machine: URL) async throws {
        guard let library else {
            return
        }
        append("$ vphone-cli vm launch \(name)")
        library.start(name)
        guard let child = library.launchedProcess(name) else {
            throw VPhoneLaunchpadError("\(name) could not be started.")
        }
        let socket = machine.appendingPathComponent("vphone.sock").path
        append("waiting up to 300s for vphoned")
        for _ in 0 ..< 300 {
            try Task.checkCancellation()
            if (library.consoles[name] ?? []).contains(where: Self.isPanic) {
                throw VPhoneLaunchpadError("The guest panicked on first boot.", detail: "See the machine's console.")
            }
            guard child.isRunning else {
                throw VPhoneLaunchpadError("The VM exited before vphoned answered.")
            }
            if await Task.detached(operation: { Self.ping(socketPath: socket) }).value {
                append("vphoned answered")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw VPhoneLaunchpadError("vphoned did not answer within 300 seconds.")
    }

    private func requireDFURunning() throws {
        guard dfu?.isRunning == true else {
            throw VPhoneLaunchpadError("The DFU boot exited.", detail: dfuLines.suffix(12).joined(separator: "\n"))
        }
    }

    // MARK: - Helpers

    nonisolated static func isPanic(_ line: String) -> Bool {
        line.range(of: panicPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The ECID the DFU boot wrote into udid-prediction.txt.
    nonisolated static func ecid(in machine: URL) throws -> String {
        let text = (try? String(contentsOf: machine.appendingPathComponent("udid-prediction.txt"), encoding: .utf8)) ?? ""
        var udid = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else {
                continue
            }
            if pair[0] == "ECID", !pair[1].isEmpty {
                return pair[1]
            }
            if pair[0] == "UDID" {
                udid = pair[1]
            }
        }
        if let suffix = udid.split(separator: "-", maxSplits: 1).last, udid.contains("-") {
            return String(suffix)
        }
        throw VPhoneLaunchpadError("udid-prediction.txt has no ECID.")
    }

    nonisolated static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            return url.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The probe `vm create` uses: a ping over vphone.sock that vphoned
    /// answers with `"ok": true`.
    nonisolated static func ping(socketPath: String) -> Bool {
        let path = socketPath.utf8CString
        var address = sockaddr_un()
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { destination in
                for (index, byte) in path.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            return false
        }
        let request = Data("{\"t\":\"ping\",\"screen\":false}\n".utf8)
        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else {
            return false
        }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while reply.count < 4096 {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else {
                return false
            }
            reply.append(contentsOf: buffer.prefix(count))
            if let newline = reply.firstIndex(of: 0x0A),
               let json = try? JSONSerialization.jsonObject(with: Data(reply[..<newline])) as? [String: Any]
            {
                return json["ok"] as? Bool == true
            }
        }
        return false
    }
}
