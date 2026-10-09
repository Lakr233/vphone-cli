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
        case "bundle.list": return await listBundles()
        case "bundle.install-local": return try await installLocal(request, emit: emit)
        case "bundle.install-release": return try await installRelease(request, emit: emit)
        case "bundle.set-default", "bundle.use": return try await setDefault(request)
        case "bundle.verify": return try await verify(request)
        case "bundle.accept": return try accept(request)
        case "bundle.remove": return try await remove(request)
        case "vm.list": return await listMachines()
        case "vm.start": return try await startMachine(request, emit: emit)
        case "vm.stop": return try await stopMachine(request)
        case "vm.wait": return try await waitMachine(request, emit: emit)
        case "vm.log": return try await log(request)
        case "vm.create": return try await create(request, emit: emit)
        case "vm.set-bundle": return try await setBundle(request, emit: emit)
        case "vm.leases": return try await leases(request)
        case "cfw.install": return try await installCustomFirmware(request, emit: emit)
        case "cfw.update-environment": return try await updateGuestEnvironment(request, emit: emit)
        case "cfw.update-kernel": return try await updateKernelControl(request, emit: emit)
        case "guest.send": return try await sendToGuest(request)
        case "guest.rpc": return try await callGuest(request)
        case "guest.unlock": return try await unlockGuest(request)
        case "exec": return try await exec(request, emit: emit)
        default: throw VPhoneLaunchpadError("\(command.name) is not handled by this Launchpad.")
        }
    }

    // MARK: - Status

    private func status() -> [String: Any] {
        // A grant made in Settings while the app stayed in the background.
        model.host.refreshDeveloperTools()
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
            "defaultBundle": bundles.defaultVersion ?? NSNull(),
            // The name before machines had their own bundle, kept for scripts.
            "activeBundle": bundles.defaultVersion ?? NSNull(),
            "bundleReady": bundles.isReady,
            "installing": bundles.isInstalling,
            "machines": library.machines.count,
            "running": library.runningCount,
            "libraries": library.roots,
        ]
    }

    // MARK: - Bundles

    private func listBundles() async -> Any {
        await refreshMachines()
        return bundles.installed.map(report)
    }

    private func report(_ item: VPhoneLaunchpadCoreBundle.Installed) -> [String: Any] {
        let isDefault = item.version == bundles.defaultVersion
        return [
            "version": item.version,
            "default": isDefault,
            // The name before machines had their own bundle, kept for scripts.
            "active": isDefault,
            "machines": library.machineNames(boundTo: item.version),
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
        model.host.refreshDeveloperTools()
        guard !model.canInstallBundles else {
            return
        }
        if bundles.isInstalling {
            throw VPhoneLaunchpadError("Another bundle install is running.")
        }
        guard case .ready = model.helper.state else {
            throw VPhoneLaunchpadError("The helper is not installed or is outdated. Install it in Host Setup.")
        }
        throw VPhoneLaunchpadError("Launchpad does not have Developer Tools access. Allow it in Host Setup.")
    }

    private func installLocal(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let path = request.arguments[0]
        guard path.hasPrefix("/") else {
            throw VPhoneLaunchpadError("The bundle path must be absolute.")
        }
        try requireInstallable()
        let keepsDefault = request.flag("keep-default")
        return try await watchInstall(emit: emit) {
            await model.installLocalBundle(URL(fileURLWithPath: path), keepsDefault: keepsDefault)
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
        let keepsDefault = request.flag("keep-default")
        return try await watchInstall(emit: emit) {
            await model.installBundle(release, keepsDefault: keepsDefault)
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

    /// The default only picks what new machines bind and what library-wide
    /// commands run with; bound machines keep their version.
    private func setDefault(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let version = request.arguments[0]
        _ = try installed(version)
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else {
            throw VPhoneLaunchpadError("VPhone.bundle \(version) is older than \(VPhoneLaunchpadNames.minimumBundleVersion).")
        }
        await bundles.setDefault(version)
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
        // Host programs come from `bundle` at each start; the other two were
        // written by the bundles named, and stay until replaced.
        let binding = library.bindings[path]
        report["bundle"] = library.bundleVersion(for: path) ?? NSNull()
        report["bootChainBundle"] = binding?.bootChain ?? NSNull()
        report["guestEnvironmentBundle"] = binding?.guestEnvironment ?? NSNull()
        if let udid = machine.udid {
            report["udid"] = udid
        }
        // Processes that have the disk open without running the machine, as
        // `vm stop` names them: `12925 tail`. The state stays `stopped`.
        let others = library.otherDiskHolders(of: path)
        if !others.isEmpty {
            report["diskOpenIn"] = others.map(\.description)
        }
        report["unlocksAtStartup"] = machine.unlocksAtStartup ?? false
        report["syncsHostLocation"] = machine.syncsHostLocation ?? false
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
        switch library.state(of: machine) {
        case .stopped:
            break
        case .running:
            throw VPhoneLaunchpadError("\(machine.name) is already running.")
        case let .busy(activity):
            throw VPhoneLaunchpadError("\(machine.name) is busy: \(activity)")
        }
        // A process that has the disk open without running the machine does
        // not stop the start, as it does not stop `vphone-cli vm launch`:
        // Virtualization opens the disk itself and fails the start if it
        // cannot. It is named, so a start that fails is not a mystery.
        let others = await library.currentOtherDiskHolders(of: machine)
        if !others.isEmpty {
            emit("note: the disk of \(machine.name) is open in \(VPhoneLaunchpadDiskHolder.describe(others)), which does not run it")
        }
        library.actionError = nil
        // Checks the machine's own bundle first, once per Launchpad session.
        await library.start(machine, headless: request.flag("headless"))
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
            // A retry runs with the options the creation started with.
            guard request.values("block").isEmpty, request.values("allow").isEmpty else {
                throw VPhoneLaunchpadError("--from retries with the patches the creation started with; --block and --allow cannot change them.")
            }
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
        guard let version = request.option("bundle") ?? bundles.defaultVersion else {
            throw VPhoneLaunchpadError("No Core Bundle version is installed. Run bundle install-local or bundle install-release.")
        }
        guard bundles.selectableVersions.contains(version) else {
            throw VPhoneLaunchpadError(
                "VPhone.bundle \(version) is not installed or not supported.",
                detail: "Installed: \(bundles.selectableVersions.joined(separator: ", "))",
            )
        }
        try await bundles.prepare(version)
        guard let commandLine = bundles.commandLine(version: version) else {
            throw VPhoneLaunchpadError("VPhone.bundle \(version) is not installed.")
        }
        emit("Core Bundle: \(version)")

        var iphone = request.option("iphone-source")
        var cloudOS = request.option("cloudos-source")
        let device = request.option("device")
        if iphone == nil || cloudOS == nil {
            let result = try await commandLine.run(["fw", "catalog", "--json"], recordInHistory: false)
            guard result.succeeded, let data = result.jsonData else {
                throw VPhoneLaunchpadError("Unable to read the firmware catalog. Pass --iphone-source and --cloudos-source.", detail: result.tail)
            }
            let catalog = try JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: data)
            let guest = if let device {
                catalog.guests.first { $0.productType == device }
            } else {
                catalog.guests.first
            }
            guard let guest else {
                let known = catalog.guests.map(\.productType).joined(separator: ", ")
                throw VPhoneLaunchpadError("The firmware catalog has no \(device ?? ""). Choose one of \(known), or pass --iphone-source and --cloudos-source.")
            }
            guard let pairing = guest.defaultPairing else {
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
        let (patches, guestPatches) = try await Self.patches(request, commandLine: commandLine, emit: emit)
        let usesTemplate = !request.flag("no-template")
        let slimming = try Self.slimming(request, usesTemplate: usesTemplate)
        let options = try VPhoneLaunchpadCreationPipeline.Options(
            name: machine.name,
            libraryRoot: machine.libraryRoot,
            bundleVersion: version,
            iphoneSource: iphone ?? "",
            cloudOSSource: cloudOS ?? "",
            device: device,
            cpuCount: number("cpu", 8),
            memoryMB: number("memory", 8192),
            diskSizeGB: number("disk-size", 64),
            network: request.option("network") ?? "nat",
            patches: patches,
            guestPatches: guestPatches,
            keepArtifacts: request.flag("keep-artifacts"),
            usesTemplate: usesTemplate,
            slimming: slimming,
        )
        return library.create(options)
    }

    /// The preset and the per-patch overrides of `--block` and `--allow`,
    /// split as New Machine splits them: the bundle's catalog for the preset
    /// says which patches it turns on and which lie outside the boot chain.
    /// The boot-chain overrides go into the template's key and build; the
    /// guest ones are applied to the clone in Apply Guest Patches.
    private static func patches(
        _ request: VPhoneLaunchpadControlRequest,
        commandLine: VPhoneLaunchpadCommandLine,
        emit: Emit,
    ) async throws -> (VPhoneLaunchpadPatchSelection, guest: Set<String>) {
        var selection = VPhoneLaunchpadPatchSelection()
        if let preset = request.option("preset") {
            selection.preset = preset
        }
        let block = request.values("block")
        let allow = request.values("allow")
        guard !block.isEmpty || !allow.isEmpty else {
            return (selection, [])
        }
        let catalog = try await VPhoneLaunchpadPatchCatalog.read(using: commandLine, machine: nil, preset: selection.preset)
        let overrides: VPhoneLaunchpadPatchOverrides
        do {
            overrides = try VPhoneLaunchpadPatchOverrides.requested(
                preset: selection.preset,
                block: block,
                allow: allow,
                declared: Set(catalog.patches.map(\.identifier)),
                inPreset: Set(catalog.patches.filter(\.inPreset).map(\.identifier)),
                guest: Set(catalog.patches.filter { !$0.isBootChain }.map(\.identifier)),
            )
        } catch {
            throw VPhoneLaunchpadError(error.message)
        }
        selection.blocked = overrides.blocked
        selection.allowed = overrides.allowed
        let unchanged = Set(block + allow).subtracting(overrides.blocked).subtracting(overrides.allowed)
        if !unchanged.isEmpty {
            emit("note: preset \(selection.preset) already has \(unchanged.sorted().joined(separator: ", ")) that way")
        }
        let essentialOff = selection.bootEssentialOff(in: catalog).map(\.identifier)
        if !essentialOff.isEmpty {
            emit("warning: \(essentialOff.count) boot-essential patch(es) are off — the machine may not boot: \(essentialOff.joined(separator: ", "))")
        }
        let bootChain = overrides.bootChainBlocked.map { "-\($0)" } + overrides.bootChainAllowed.map { "+\($0)" }
        let guest = overrides.blocked.intersection(overrides.guestPatches).map { "-\($0)" }
            + overrides.allowed.intersection(overrides.guestPatches).map { "+\($0)" }
        emit("patches: preset \(selection.preset); boot chain \(bootChain.isEmpty ? "as the preset" : bootChain.sorted().joined(separator: " ")); guest \(guest.isEmpty ? "as the preset" : guest.sorted().joined(separator: " "))")
        return (selection, overrides.guestPatches)
    }

    /// The template switches, refused where `vphone-cli vm create` refuses
    /// them: with `--no-template`, after `--slim off`, `--accounts-off`
    /// without the trimmed profile, an app outside the removable list.
    private static func slimming(_ request: VPhoneLaunchpadControlRequest, usesTemplate: Bool) throws -> VPhoneLaunchpadSlimming {
        func onOff(_ option: String) throws -> Bool? {
            guard let value = request.option(option) else {
                return nil
            }
            switch value {
            case "on": return true
            case "off": return false
            default: throw VPhoneLaunchpadError("--\(option) takes on or off, not \(value).")
            }
        }
        let parts = ["trim", "keep-languages", "service-profile", "remove-apps", "keep-apps"].filter { request.option($0) != nil }
            + (request.flag("accounts-off") ? ["accounts-off"] : [])
        if !usesTemplate, !parts.isEmpty || request.option("slim") != nil {
            throw VPhoneLaunchpadError("The slimming switches shape a template; --no-template creates the machine without one.")
        }
        var slimming = VPhoneLaunchpadSlimming()
        slimming.slim = try onOff("slim") ?? true
        if !slimming.slim, !parts.isEmpty {
            throw VPhoneLaunchpadError("--slim off turns slimming off; it cannot be combined with --\(parts.joined(separator: ", --")).")
        }
        if let trim = request.option("trim") {
            guard let tier = VPhoneLaunchpadSlimming.TrimTier(rawValue: trim) else {
                throw VPhoneLaunchpadError("--trim takes none, conservative or standard, not \(trim).")
            }
            slimming.trim = tier
        }
        if let languages = request.option("keep-languages") {
            guard slimming.trim == .standard else {
                throw VPhoneLaunchpadError("--keep-languages needs --trim standard.")
            }
            slimming.keptLanguages = languages
        }
        if let profile = request.option("service-profile") {
            guard profile == "trimmed" || profile == "none" else {
                throw VPhoneLaunchpadError("--service-profile takes trimmed or none, not \(profile).")
            }
            slimming.trimsServices = profile == "trimmed"
        }
        slimming.removesApps = try onOff("remove-apps") ?? true
        if let kept = request.option("keep-apps") {
            let identifiers = Set(VPhoneLaunchpadSlimming.languageList(kept))
            let known = Set(VPhoneLaunchpadSlimming.removableApps.map(\.id))
            let unknown = identifiers.subtracting(known)
            guard unknown.isEmpty else {
                throw VPhoneLaunchpadError("--keep-apps \(unknown.sorted().joined(separator: ",")): only apps removed by default can be kept (\(known.sorted().joined(separator: ", "))).")
            }
            guard slimming.removesApps else {
                throw VPhoneLaunchpadError("--keep-apps has nothing to keep with --remove-apps off.")
            }
            slimming.keptApps = identifiers
        }
        // The Apple Account daemons go with the trimmed profile whether or
        // not the flag is given; it is still refused where the CLI refuses it.
        if request.flag("accounts-off"), !slimming.trimsServices {
            throw VPhoneLaunchpadError("--accounts-off needs --service-profile trimmed.")
        }
        if let problem = slimming.problem {
            throw VPhoneLaunchpadError(problem)
        }
        return slimming
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
            "bundle": pipeline.options.bundleVersion,
            "running": pipeline.isRunning,
            "log": pipeline.logFile.path,
            "template": pipeline.templateID ?? NSNull(),
            "builtTemplate": pipeline.builtTemplate,
            // Only once Find Template has decided to build: a creation that
            // clones a template it found never makes this machine.
            "buildMachine": pipeline.plan.buildingName ?? NSNull(),
            "patches": [
                "preset": pipeline.options.patches.preset,
                "blocked": pipeline.options.patches.blocked.sorted(),
                "allowed": pipeline.options.patches.allowed.sorted(),
                // Applied to the clone; the others went into the template.
                "guest": pipeline.options.guestPatches.sorted(),
            ],
            "steps": pipeline.steps.map { step -> [String: Any] in
                var item: [String: Any] = ["step": "\(step)", "status": pipeline.status(step).rawValue]
                if let duration = pipeline.durations[step] {
                    item["seconds"] = Int(duration)
                }
                return item
            },
        ]
    }

    // MARK: - Core Bundle of a machine

    /// Rebinds one machine. `setBundle` skips the environment update of a
    /// running machine without saying so, so that is refused here instead.
    /// A disk held by another process it refuses itself, before rebinding;
    /// an update that fails after rebinding is reported as such.
    private func setBundle(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let machine = try await machine(request)
        let version = request.arguments[1]
        guard bundles.selectableVersions.contains(version) else {
            throw VPhoneLaunchpadError(
                "VPhone.bundle \(version) is not installed or not supported.",
                detail: "Installed: \(bundles.selectableVersions.joined(separator: ", "))",
            )
        }
        guard library.creations[machine]?.isRunning != true else {
            throw VPhoneLaunchpadError("\(machine.name) is still being created.")
        }
        let updatesEnvironment = request.flag("update-environment")
        let state = library.state(of: machine)
        if updatesEnvironment, state != .stopped {
            throw VPhoneLaunchpadError("Stop \(machine.name) before updating its guest environment.")
        }
        library.actionError = nil
        // Only once the update starts: a held disk refuses the change first.
        await library.setBundle(version, for: [machine], updateEnvironment: updatesEnvironment) { machine in
            emit("updating the guest environment; console log: \(VPhoneLaunchpadMachineLibrary.consoleLog(machine).path)")
        }
        if let error = takeLibraryError() {
            throw error
        }
        if state == .running {
            emit("\(machine.name) is running; it uses \(version) from its next start")
        }
        await library.refresh()
        return report(machine)
    }

    // MARK: - CFW

    /// The version a machine's own commands run with: its binding, else the
    /// default.
    private func bundleVersion(of machine: VPhoneLaunchpadMachinePath) throws -> String {
        guard let version = library.bundleVersion(for: machine) else {
            throw VPhoneLaunchpadError("No Core Bundle version is installed. Run bundle install-local or bundle install-release.")
        }
        return version
    }

    /// `cfw install` and the updates need the disk to themselves and refuse
    /// any other holder, so a process that only reads it refuses them here
    /// too, by name, before the helper is asked.
    private func requireDiskUnheld(_ machine: VPhoneLaunchpadMachinePath) async throws {
        let others = await library.currentOtherDiskHolders(of: machine)
        guard others.isEmpty else {
            throw VPhoneLaunchpadError(
                "The disk of \(machine.name) is open in \(VPhoneLaunchpadDiskHolder.describe(others)), which does not run it. "
                    + "Try again once that process closes it.",
            )
        }
    }

    private func installCustomFirmware(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let machine = try await machine(request)
        let version = try bundleVersion(of: machine)
        guard library.state(of: machine) == .stopped else {
            throw VPhoneLaunchpadError("Stop \(machine.name) before installing CFW.")
        }
        try await requireDiskUnheld(machine)
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
        library.recordGuestEnvironment(machine, version)
        return ["name": machine.name, "bundle": version, "status": status]
    }

    private func updateGuestEnvironment(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let machine = try await machine(request)
        let version = try bundleVersion(of: machine)
        guard library.state(of: machine) == .stopped else {
            throw VPhoneLaunchpadError("Stop \(machine.name) before updating its guest environment.")
        }
        try await requireDiskUnheld(machine)
        let status = try await model.helper.updateGuestEnvironment(
            bundleVersion: version,
            machineName: machine.name,
            libraryRoot: machine.libraryRoot,
            onLine: emit,
        )
        guard status == 0 else {
            throw VPhoneLaunchpadError("Unable to update the guest environment. Check the log for details.")
        }
        library.recordGuestEnvironment(machine, version)
        return ["name": machine.name, "bundle": version, "status": status]
    }

    private func updateKernelControl(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        let machine = try await machine(request)
        let version = try bundleVersion(of: machine)
        guard library.state(of: machine) == .stopped else {
            throw VPhoneLaunchpadError("Stop \(machine.name) before updating its kernel.")
        }
        try await requireDiskUnheld(machine)
        let status = try await model.helper.updateKernel(
            bundleVersion: version,
            machineName: machine.name,
            libraryRoot: machine.libraryRoot,
            onLine: emit,
        )
        guard status == 0 else {
            throw VPhoneLaunchpadError("Unable to update the kernel. Check the log for details.")
        }
        return ["name": machine.name, "bundle": version, "status": status]
    }

    // MARK: - DHCP leases

    private func leases(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let leases = model.leases
        // The release compares against the machines listed now, so list first.
        await refreshMachines()
        if request.flag("release") {
            let released = try await leases.release()
            return ["released": released.map(report)]
        }
        await leases.refresh()
        switch leases.state {
        case let .unavailable(reason), let .failed(reason):
            throw VPhoneLaunchpadError(reason)
        default:
            return leases.leases.map(report)
        }
    }

    private func report(_ lease: VPhoneLaunchpadLeases.Lease) -> [String: Any] {
        var report: [String: Any] = [:]
        report["address"] = lease.address
        report["mac"] = lease.mac
        report["name"] = lease.name
        report["owner"] = lease.owner
        report["machine"] = lease.machine
        return report
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

    /// vphoned's `screen.unlock`: the display on and the Lock Screen passed,
    /// whatever state the guest was in.
    private func unlockGuest(_ request: VPhoneLaunchpadControlRequest) async throws -> Any {
        let machine = try await machine(request)
        var params: [String: Any] = [:]
        if let passcode = request.option("passcode") {
            params["passcode"] = passcode
        }
        if let text = request.option("timeout") {
            guard let seconds = Double(text), (1 ... 60).contains(seconds) else {
                throw VPhoneLaunchpadError("--timeout takes 1 to 60 seconds.")
            }
            params["timeout"] = seconds
        }
        let object: [String: Any] = ["t": "rpc", "method": "screen.unlock", "params": params]
        do {
            return try await VPhoneLaunchpadGuestSocket.send(object, socketPath: Self.controlSocket(machine))
        } catch let error as VPhoneLaunchpadError where error.detail?.contains("Unknown method") == true {
            // The guest environment is its own layer; an older vphoned stays
            // in a machine until it is redeployed.
            throw VPhoneLaunchpadError(
                "The vphoned in \(machine.name) cannot unlock the screen.",
                detail: "Its guest environment is older than screen.unlock. Stop the machine and run cfw update-environment with a Core Bundle that has it.",
            )
        }
    }

    // MARK: - vphone-cli

    /// Runs the default bundle's `vphone-cli`, or that of `--bundle`. A
    /// command on one machine should name that machine's own version, which
    /// `vm list` reports.
    private func exec(_ request: VPhoneLaunchpadControlRequest, emit: @escaping Emit) async throws -> Any {
        guard let version = request.option("bundle") ?? bundles.defaultVersion else {
            throw VPhoneLaunchpadError("No Core Bundle version is installed. Run bundle install-local or bundle install-release.")
        }
        guard let commandLine = bundles.commandLine(version: version) else {
            throw VPhoneLaunchpadError(
                "VPhone.bundle \(version) is not installed or not supported.",
                detail: "Installed: \(bundles.selectableVersions.joined(separator: ", "))",
            )
        }
        let result = try await commandLine.run(request.arguments, onLine: emit)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw VPhoneLaunchpadError("vphone-cli exited with status \(result.status).")
        }
        return ["status": result.status, "bundle": version]
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
    /// `timeout` is how long to wait for the reply, in seconds. vphone-vm
    /// waits on vphoned for up to its own limit, and an rpc such as a package
    /// install can take a while, so the default is long.
    static func send(_ object: [String: Any], socketPath: String, timeout: Int = 120) async throws -> Any {
        let line = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        let response = try await Task.detached { try exchange(line, socketPath: socketPath, timeout: timeout) }.value
        guard let json = try? JSONSerialization.jsonObject(with: response) else {
            throw VPhoneLaunchpadError("The machine sent a reply that could not be read. Try again.", detail: String(decoding: response.prefix(512), as: UTF8.self))
        }
        if let dictionary = json as? [String: Any], dictionary["ok"] as? Bool == false {
            // Newer bundles add vphoned's whole error object to a refused
            // rpc; its last line is that object as JSON, for scripts.
            let guestError = (dictionary["guest_error"] as? [String: Any]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])
            }
            let detail = [dictionary["error"] as? String, guestError.map { String(decoding: $0, as: UTF8.self) }]
                .compactMap(\.self).joined(separator: "\n")
            throw VPhoneLaunchpadError("The machine refused the request. Try again.", detail: detail.isEmpty ? nil : detail)
        }
        return json
    }

    private static func exchange(_ line: Data, socketPath: String, timeout seconds: Int) throws -> Data {
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
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
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
