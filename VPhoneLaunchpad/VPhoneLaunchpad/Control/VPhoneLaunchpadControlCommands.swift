import Foundation

/// Runs `vphone-launchpad-cli` requests against the same model the window
/// shows. Every command goes through the methods the UI calls, so what the
/// CLI does appears in the window and the command history, and root still
/// comes only from the helper's fixed verbs.
@MainActor
struct VPhoneLaunchpadControlCommands {
    typealias Emit = VPhoneLaunchpadControlServer.Emit

    let model: VPhoneLaunchpadModel

    private var bundles: VPhoneLaunchpadCoreBundle {
        model.bundles
    }

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    func handle(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async -> VPhoneLaunchpadControlEvent {
        do {
            let result = try await perform(request, emit: emit)
            let data = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed],
            )
            return .success(String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            return .failure("Cancelled.")
        } catch {
            return .failure(error.localizedDescription, detail: (error as? VPhoneLaunchpadError)?.detail)
        }
    }

    private func perform(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        guard let command = VPhoneLaunchpadControlCommand.named(request.command) else {
            throw VPhoneLaunchpadError("Unknown command \(request.command).")
        }
        let minimum = command.takesRest ? command.arguments.count - 1 : command.arguments.count
        guard request.arguments.count >= minimum else {
            throw VPhoneLaunchpadError("Usage: \(command.usage)")
        }
        switch command.name {
        case "status": return status()
        case "bundle.list": return bundles.installed.map(report)
        case "bundle.install-local": return try await installLocal(request, emit: emit)
        case "bundle.install-release": return try await installRelease(request, emit: emit)
        case "bundle.use": return try await use(request)
        case "bundle.verify": return try await verify(request)
        case "bundle.accept": return try accept(request)
        case "bundle.remove": return try await remove(request)
        case "vm.list": return await listMachines()
        case "vm.start": return try await startMachine(request, emit: emit)
        case "vm.stop": return try await stopMachine(request)
        case "vm.wait": return try await waitMachine(request, emit: emit)
        case "vm.log": return try await log(request)
        case "vm.create": return try await create(request, emit: emit)
        case "cfw.install": return try await installCustomFirmware(request, emit: emit)
        case "guest.send": return try await sendToGuest(request)
        case "guest.rpc": return try await callGuest(request)
        case "exec": return try await exec(request, emit: emit)
        default: throw VPhoneLaunchpadError("\(command.name) is not handled by this Launchpad.")
        }
    }

    // MARK: - Status

    private func status() -> [String: Any] {
        let helper = switch model.helper.state {
        case .unknown: "unknown"
        case .notInstalled: "not installed"
        case let .outdated(installed, bundled): "outdated (\(installed), app has \(bundled))"
        case let .ready(version): "ready (\(version))"
        case .unconfigured: "unconfigured (built without a team)"
        }
        return [
            "helper": helper,
            "hostReady": model.host.requiredPassed,
            "developerTools": model.host.isDeveloperToolAuthorized,
            "canInstallBundles": model.canInstallBundles,
            "activeBundle": bundles.activeVersion ?? NSNull(),
            "bundleReady": bundles.isReady,
            "installing": bundles.isInstalling,
            "machines": library.machines.count,
            "running": library.runningCount,
            "libraries": library.roots,
        ]
    }

    // MARK: - Bundles

    private func report(_ item: VPhoneLaunchpadCoreBundle.Installed) -> [String: Any] {
        [
            "version": item.version,
            "active": item.version == bundles.activeVersion,
            "accepted": bundles.isAccepted(item.version),
            "policy": item.policy.rawValue,
            "preflight": item.preflight.rawValue,
            "preflightDetail": item.preflightDetail,
            "sha256": item.receipt.sha256,
            "installedAt": ISO8601DateFormatter().string(from: item.receipt.installedAt),
            "cdhashes": item.receipt.cdhashes,
            "path": VPhoneLaunchpadBundleStore.bundle(version: item.version).path,
        ]
    }

    private func installed(_ version: String) throws -> VPhoneLaunchpadCoreBundle.Installed {
        guard let item = bundles.installed.first(where: { $0.version == version }) else {
            throw VPhoneLaunchpadError("VPhone.bundle \(version) is not installed.")
        }
        return item
    }

    private func requireInstallable() throws {
        guard !model.canInstallBundles else {
            return
        }
        if bundles.isInstalling {
            throw VPhoneLaunchpadError("Another bundle install is running.")
        }
        guard case .ready = model.helper.state else {
            throw VPhoneLaunchpadError("The helper is not installed or is outdated. Install it in Host Setup.")
        }
        throw VPhoneLaunchpadError("Launchpad does not have Developer Tools access. Allow it in Host Setup, then relaunch Launchpad.")
    }

    private func installLocal(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let path = request.arguments[0]
        guard path.hasPrefix("/") else {
            throw VPhoneLaunchpadError("The bundle path must be absolute.")
        }
        try requireInstallable()
        return try await watchInstall(emit: emit) {
            await model.installLocalBundle(URL(fileURLWithPath: path))
        }
    }

    private func installRelease(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        try requireInstallable()
        let wanted = request.arguments[0]
        if bundles.releases.isEmpty {
            await bundles.fetchReleases()
        }
        let release = wanted == "latest"
            ? bundles.releases.first
            : bundles.releases.first { $0.version == wanted }
        guard let release else {
            throw VPhoneLaunchpadError("No release \(wanted) was found.", detail: bundles.releasesError)
        }
        return try await watchInstall(emit: emit) {
            await model.installBundle(release)
        }
    }

    /// Runs an install and reports each step as it changes. The install is
    /// the window's own, so it goes on if the CLI is interrupted.
    private func watchInstall(emit: @escaping Emit, _ install: () async -> Void) async throws -> Any {
        let watcher = Task { @MainActor in
            var reported: [VPhoneLaunchpadCoreBundle.InstallStep: VPhoneLaunchpadStatus] = [:]
            while !Task.isCancelled {
                reportSteps(&reported, emit: emit)
                try? await Task.sleep(for: .milliseconds(300))
            }
            reportSteps(&reported, emit: emit)
        }
        await install()
        watcher.cancel()
        await watcher.value
        guard let progress = bundles.progress else {
            throw VPhoneLaunchpadError("The install did not start.")
        }
        if let error = progress.error {
            throw error
        }
        guard let version = progress.version else {
            throw VPhoneLaunchpadError("The install did not report a version.")
        }
        return try report(installed(version))
    }

    private func reportSteps(
        _ reported: inout [VPhoneLaunchpadCoreBundle.InstallStep: VPhoneLaunchpadStatus],
        emit: Emit,
    ) {
        guard let progress = bundles.progress else {
            return
        }
        for step in progress.plan where reported[step] != progress.status(step) && progress.status(step) != .pending {
            reported[step] = progress.status(step)
            emit("\(progress.status(step).rawValue): \(step.title)")
        }
    }

    private func use(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let version = request.arguments[0]
        _ = try installed(version)
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else {
            throw VPhoneLaunchpadError("VPhone.bundle \(version) is older than \(VPhoneLaunchpadNames.minimumBundleVersion).")
        }
        await bundles.use(version)
        await library.refresh()
        return try checked(version)
    }

    private func verify(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let version = request.arguments[0]
        _ = try installed(version)
        await bundles.verify(version)
        return try checked(version)
    }

    /// The bundle's report, or its preflight failure unless it was accepted.
    private func checked(_ version: String) throws -> Any {
        let item = try installed(version)
        if item.preflight != .passed, !bundles.isAccepted(version) {
            throw VPhoneLaunchpadError("VPhone.bundle \(version) did not pass its checks.", detail: item.preflightDetail)
        }
        return report(item)
    }

    private func accept(_ request: VPhoneLaunchpadControlRequest) throws -> Any {
        let version = request.arguments[0]
        let item = try installed(version)
        bundles.setAccepted(version, !request.flag("off"))
        return report(item)
    }

    private func remove(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let version = request.arguments[0]
        _ = try installed(version)
        bundles.actionError = nil
        await model.removeBundle(version)
        if let error = bundles.actionError {
            bundles.actionError = nil
            throw error
        }
        return ["removed": version]
    }

    // MARK: - Machines

    private func listMachines() async -> Any {
        await refreshMachines()
        return library.machines.map(report)
    }

    /// A refresh returns at once while another is running, as the one at
    /// launch is when the CLI has just started Launchpad; wait for the first
    /// listing then.
    private func refreshMachines() async {
        await library.refresh()
        for _ in 0 ..< 100 where !library.hasListed {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func report(_ machine: VPhoneLaunchpadMachine) -> [String: Any] {
        let path = machine.path
        let state = switch library.state(of: path) {
        case .stopped: "stopped"
        case .running: "running"
        case let .busy(activity): "busy: \(activity)"
        }
        var report: [String: Any] = [
            "name": machine.name,
            "libraryRoot": machine.libraryRoot,
            "state": state,
            "cpuCount": machine.cpuCount,
            "memoryMB": machine.memoryMB,
            "network": machine.network.mode,
            "panicked": library.panicked.contains(path),
            "log": VPhoneLaunchpadMachineLibrary.consoleLog(path).path,
            "controlSocket": FileManager.default.fileExists(atPath: Self.controlSocket(path))
                ? Self.controlSocket(path) : NSNull(),
        ]
        if let udid = machine.udid {
            report["udid"] = udid
        }
        if let info = machine.restoreInfo {
            report["ios"] = "\(info.ios.version) (\(info.ios.build))"
            report["cloudOS"] = "\(info.cloudOS.version) (\(info.cloudOS.build))"
        }
        return report
    }

    private static func controlSocket(_ machine: VPhoneLaunchpadMachinePath) -> String {
        machine.url.appendingPathComponent("vphone.sock").path
    }

    /// The machine named by the first argument, in `--root` when given. A
    /// name that two libraries share needs `--root`.
    private func machine(_ request: VPhoneLaunchpadControlRequest) async throws -> VPhoneLaunchpadMachinePath {
        let name = request.arguments[0]
        let root = request.option("root").map { VPhoneLaunchpadMachineLocations.canonical(URL(fileURLWithPath: $0, isDirectory: true)) }
        func matches() -> [VPhoneLaunchpadMachinePath] {
            library.machines.map(\.path).filter { $0.name == name && (root == nil || $0.libraryRoot == root) }
        }
        var found = matches()
        if found.isEmpty {
            await refreshMachines()
            found = matches()
        }
        guard let first = found.first else {
            throw VPhoneLaunchpadError("No machine named \(name) was found.")
        }
        guard found.count == 1 else {
            throw VPhoneLaunchpadError(
                "\(name) exists in more than one library. Pass --root.",
                detail: found.map(\.libraryRoot).joined(separator: "\n"),
            )
        }
        return first
    }

    /// Returns and clears the error an action left for the window's alert.
    private func takeLibraryError() -> VPhoneLaunchpadError? {
        defer { library.actionError = nil }
        return library.actionError
    }

    private func startMachine(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let machine = try await machine(request)
        guard library.state(of: machine) == .stopped else {
            throw VPhoneLaunchpadError("\(machine.name) is already running or busy.")
        }
        guard bundles.isReady else {
            throw VPhoneLaunchpadError("The active VPhone.bundle has not passed its checks. Run bundle verify.")
        }
        library.actionError = nil
        library.start(machine, headless: request.flag("headless"))
        guard library.launchedProcess(machine) != nil else {
            throw takeLibraryError() ?? VPhoneLaunchpadError("\(machine.name) could not be started.")
        }
        emit("launched \(machine.name); console log: \(VPhoneLaunchpadMachineLibrary.consoleLog(machine).path)")
        if request.flag("wait") {
            try await waitReady(machine, timeout: timeout(request), emit: emit)
        }
        return report(machine)
    }

    private func report(_ machine: VPhoneLaunchpadMachinePath) -> Any {
        library.machines.first { $0.path == machine }.map(report) ?? ["name": machine.name, "libraryRoot": machine.libraryRoot]
    }

    private func stopMachine(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let machine = try await machine(request)
        library.actionError = nil
        await library.stop(machine)
        if let error = takeLibraryError() {
            throw error
        }
        return report(machine)
    }

    private func timeout(_ request: VPhoneLaunchpadControlRequest) throws -> Int {
        guard let text = request.option("timeout") else {
            return 300
        }
        guard let seconds = Int(text), seconds > 0 else {
            throw VPhoneLaunchpadError("--timeout takes a number of seconds.")
        }
        return seconds
    }

    private func waitMachine(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let machine = try await machine(request)
        try await waitReady(machine, timeout: timeout(request), emit: emit)
        return report(machine)
    }

    /// The first-boot probe: a ping over vphone.sock that vphoned answers.
    private func waitReady(_ machine: VPhoneLaunchpadMachinePath, timeout: Int, emit: Emit) async throws {
        let socket = Self.controlSocket(machine)
        emit("waiting up to \(timeout)s for vphoned")
        let started = Date()
        while Date().timeIntervalSince(started) < Double(timeout) {
            try Task.checkCancellation()
            if library.panicked.contains(machine) {
                throw VPhoneLaunchpadError("\(machine.name) had a kernel panic.", detail: VPhoneLaunchpadMachineLibrary.consoleLog(machine).path)
            }
            if let child = library.launchedProcess(machine), !child.isRunning {
                throw VPhoneLaunchpadError("\(machine.name) stopped before vphoned answered.")
            }
            if await Task.detached(operation: { VPhoneLaunchpadCreationPipeline.ping(socketPath: socket) }).value {
                emit("vphoned answered after \(Int(Date().timeIntervalSince(started)))s")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw VPhoneLaunchpadError(
            "vphoned did not answer within \(timeout)s.",
            detail: "Bundles up to 2.0.9 serve vphone.sock only for machines launched with a window.",
        )
    }

    private func log(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let machine = try await machine(request)
        let suffix = switch request.option("kind") {
        case nil, "console": ""
        case "create": "-create"
        case "dfu": "-dfu"
        case "patch": "-patch"
        case let kind?: throw VPhoneLaunchpadError("--kind is console, create, dfu or patch, not \(kind).")
        }
        var count = 200
        if let text = request.option("lines") {
            guard let lines = Int(text), lines > 0 else {
                throw VPhoneLaunchpadError("--lines takes a positive number.")
            }
            count = lines
        }
        let file = VPhoneLaunchpadMachineLibrary.consoleLog(machine, suffix: suffix)
        let lines = await Task.detached { Self.tail(file, lines: count) }.value
        guard let lines else {
            throw VPhoneLaunchpadError("There is no log at \(file.path).")
        }
        return ["path": file.path, "lines": lines]
    }

    /// The last `lines` lines, read from at most the last 1 MiB.
    private nonisolated static func tail(_ file: URL, lines: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 1 << 20 ? end - (1 << 20) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var result: [String] = []
        var splitter = VPhoneLaunchpadLineSplitter()
        splitter.feed(data) { result.append($0) }
        splitter.flush { result.append($0) }
        return Array(result.suffix(max(lines, 1)))
    }

    // MARK: - Create

    private func create(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let name = request.arguments[0]
        let root = VPhoneLaunchpadMachineLocations.canonical(URL(
            fileURLWithPath: request.option("root") ?? library.libraryRoot,
            isDirectory: true,
        ))
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: root, name: name)

        let pipeline: VPhoneLaunchpadCreationPipeline
        if let from = request.option("from") {
            guard let step = VPhoneLaunchpadCreationPipeline.Step.allCases.first(where: { from == "\($0)" }) else {
                let steps = VPhoneLaunchpadCreationPipeline.Step.allCases.map { "\($0)" }.joined(separator: ", ")
                throw VPhoneLaunchpadError("--from takes one of: \(steps).")
            }
            guard let existing = library.creations[machine] else {
                throw VPhoneLaunchpadError("This Launchpad has not created \(name) since it started, so there is nothing to retry.")
            }
            guard !existing.isRunning else {
                throw VPhoneLaunchpadError("\(name) is still being created.")
            }
            existing.start(from: step)
            pipeline = existing
        } else {
            pipeline = try await startCreation(machine, request, emit: emit)
        }

        if request.flag("no-wait") {
            return creationReport(pipeline)
        }
        try await watchCreation(pipeline, emit: emit)
        return creationReport(pipeline)
    }

    private func startCreation(
        _ machine: VPhoneLaunchpadMachinePath,
        _ request: VPhoneLaunchpadControlRequest,
        emit: Emit,
    ) async throws -> VPhoneLaunchpadCreationPipeline {
        guard VPhoneLaunchpadNames.isValidMachineName(machine.name) else {
            throw VPhoneLaunchpadError("Use letters, numbers, periods, hyphens, and underscores in the name.")
        }
        guard !FileManager.default.fileExists(atPath: machine.url.path), library.creations[machine]?.isRunning != true else {
            throw VPhoneLaunchpadError("\(machine.name) already exists in \(machine.libraryRoot).")
        }
        guard VPhoneLaunchpadMachineLocations.socketPathFits(root: machine.libraryRoot, name: machine.name) else {
            throw VPhoneLaunchpadError("The machine path is too long for its vphone.sock. Use a shorter name or library path.")
        }
        guard bundles.isReady, let commandLine = bundles.commandLine() else {
            throw VPhoneLaunchpadError("The active VPhone.bundle has not passed its checks. Run bundle verify.")
        }

        var iphone = request.option("iphone-source")
        var cloudOS = request.option("cloudos-source")
        if iphone == nil || cloudOS == nil {
            let result = try await commandLine.run(["fw", "catalog", "--json"], recordInHistory: false)
            guard result.succeeded, let data = result.jsonData,
                  let pairing = try JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: data).pairings.last
            else {
                throw VPhoneLaunchpadError("Unable to read the firmware catalog. Pass --iphone-source and --cloudos-source.", detail: result.tail)
            }
            iphone = iphone ?? pairing.ios.url
            cloudOS = cloudOS ?? pairing.recommendedCloudOS.url
            emit("firmware: \(iphone ?? "") + \(cloudOS ?? "")")
        }

        func number(_ option: String, _ fallback: Int) throws -> Int {
            guard let text = request.option(option) else {
                return fallback
            }
            guard let value = Int(text), value > 0 else {
                throw VPhoneLaunchpadError("--\(option) takes a positive number.")
            }
            return value
        }
        var patches = VPhoneLaunchpadPatchSelection()
        if let preset = request.option("preset") {
            patches.preset = preset
        }
        let options = try VPhoneLaunchpadCreationPipeline.Options(
            name: machine.name,
            libraryRoot: machine.libraryRoot,
            iphoneSource: iphone ?? "",
            cloudOSSource: cloudOS ?? "",
            cpuCount: number("cpu", 8),
            memoryMB: number("memory", 8192),
            diskSizeGB: number("disk-size", 64),
            network: request.option("network") ?? "nat",
            patches: patches,
            keepArtifacts: request.flag("keep-artifacts"),
        )
        return library.create(options)
    }

    /// Streams the creation log and each step until the pipeline stops. The
    /// creation is the window's own, so interrupting the CLI only stops
    /// watching it.
    private func watchCreation(_ pipeline: VPhoneLaunchpadCreationPipeline, emit: @escaping Emit) async throws {
        let follower = VPhoneLaunchpadLogFollower(url: pipeline.logFile)
        while pipeline.isRunning {
            try Task.checkCancellation()
            await Task.detached { follower.drain(emit) }.value
            try await Task.sleep(for: .milliseconds(500))
        }
        await Task.detached { follower.drain(emit) }.value
        if let failure = pipeline.failure {
            throw failure
        }
    }

    private func creationReport(_ pipeline: VPhoneLaunchpadCreationPipeline) -> [String: Any] {
        [
            "name": pipeline.machine.name,
            "libraryRoot": pipeline.machine.libraryRoot,
            "running": pipeline.isRunning,
            "log": pipeline.logFile.path,
            "steps": VPhoneLaunchpadCreationPipeline.Step.allCases.map { step -> [String: Any] in
                var item: [String: Any] = ["step": "\(step)", "status": pipeline.status(step).rawValue]
                if let duration = pipeline.durations[step] {
                    item["seconds"] = Int(duration)
                }
                return item
            },
        ]
    }

    // MARK: - CFW

    private func installCustomFirmware(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let machine = try await machine(request)
        guard let version = bundles.activeVersion else {
            throw VPhoneLaunchpadError("No Core Bundle version is in use.")
        }
        guard library.state(of: machine) == .stopped else {
            throw VPhoneLaunchpadError("Stop \(machine.name) before installing CFW.")
        }
        let status = try await model.helper.installCustomFirmware(
            bundleVersion: version,
            machineName: machine.name,
            libraryRoot: machine.libraryRoot,
            keepArtifacts: request.flag("keep-artifacts"),
            onLine: emit,
        )
        guard status == 0 else {
            throw VPhoneLaunchpadError("Unable to install custom firmware. Check the log for details.")
        }
        return ["name": machine.name, "bundle": version, "status": status]
    }

    // MARK: - Guest

    private func sendToGuest(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let machine = try await machine(request)
        guard let object = try? JSONSerialization.jsonObject(with: Data(request.arguments[1].utf8)) as? [String: Any] else {
            throw VPhoneLaunchpadError("The request must be one JSON object.")
        }
        return try await VPhoneLaunchpadGuestSocket.send(object, socketPath: Self.controlSocket(machine))
    }

    private func callGuest(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let machine = try await machine(request)
        let text = request.arguments.dropFirst(2).joined(separator: " ")
        var params: [String: Any] = [:]
        if !text.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw VPhoneLaunchpadError("params must be one JSON object.")
            }
            params = object
        }
        let object: [String: Any] = [
            "t": "rpc",
            "method": request.arguments[1],
            "params": params,
            "screen": request.flag("screen"),
        ]
        return try await VPhoneLaunchpadGuestSocket.send(object, socketPath: Self.controlSocket(machine))
    }

    // MARK: - vphone-cli

    private func exec(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        guard let commandLine = bundles.commandLine() else {
            throw VPhoneLaunchpadError("No Core Bundle version is in use.")
        }
        let result = try await commandLine.run(request.arguments, onLine: emit)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw VPhoneLaunchpadError("vphone-cli exited with status \(result.status).")
        }
        return ["status": result.status, "bundle": bundles.activeVersion ?? ""]
    }
}

// MARK: - Log follower

/// Emits the lines appended to a log file since the last drain.
final nonisolated class VPhoneLaunchpadLogFollower: @unchecked Sendable {
    private let url: URL
    private var offset: UInt64 = 0
    private var splitter = VPhoneLaunchpadLineSplitter()

    init(url: URL) {
        self.url = url
    }

    func drain(_ emit: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        splitter.feed(data, emit)
    }
}

// MARK: - Guest socket

/// One request to a machine's vphone.sock: a JSON line in, a JSON line out.
nonisolated enum VPhoneLaunchpadGuestSocket {
    static func send(_ object: [String: Any], socketPath: String) async throws -> Any {
        let line = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        let response = try await Task.detached { try exchange(line, socketPath: socketPath) }.value
        guard let json = try? JSONSerialization.jsonObject(with: response) else {
            throw VPhoneLaunchpadError("The machine sent a reply that could not be read. Try again.", detail: String(decoding: response.prefix(512), as: UTF8.self))
        }
        if let dictionary = json as? [String: Any], dictionary["ok"] as? Bool == false {
            throw VPhoneLaunchpadError("The machine refused the request. Try again.", detail: dictionary["error"] as? String)
        }
        return json
    }

    private static func exchange(_ line: Data, socketPath: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw VPhoneLaunchpadError(
                "The machine has no vphone.sock.",
                detail: "Only a running machine serves it; bundles up to 2.0.9 serve it only with a window.",
            )
        }
        var address = sockaddr_un()
        guard VPhoneLaunchpadControl.address(socketPath, into: &address) else {
            throw VPhoneLaunchpadError("The vphone.sock path is too long.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VPhoneLaunchpadError("Unable to open a socket.")
        }
        defer { close(fd) }
        // vphone-vm waits on vphoned for up to its own limit; an rpc such as
        // a package install can take a while.
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw VPhoneLaunchpadError("The machine is not responding. Make sure it is running, then try again.", detail: String(cString: strerror(errno)))
        }
        guard VPhoneLaunchpadControl.write(line, to: fd) else {
            throw VPhoneLaunchpadError("Unable to send the request to the machine.")
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                break
            }
            response.append(contentsOf: buffer[0 ..< count])
        }
        guard !response.isEmpty else {
            throw VPhoneLaunchpadError("The machine closed the connection without answering.")
        }
        return response
    }
}
