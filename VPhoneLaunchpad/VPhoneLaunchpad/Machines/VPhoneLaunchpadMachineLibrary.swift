import Foundation
import Observation

/// The third stage: the VM library, driven entirely through `vphone-cli vm`.
@MainActor
@Observable
final class VPhoneLaunchpadMachineLibrary {
    enum RunState: Equatable {
        case stopped
        case running
        case busy(String)
    }

    private(set) var machines: [VPhoneLaunchpadMachine] = []
    private(set) var listError: String?
    private(set) var startedAt: [String: Date] = [:]
    /// Machines whose console printed a panic since Launchpad last started
    /// them. The console text itself stays in the log file.
    private(set) var panicked: Set<String> = []
    private(set) var creations: [String: VPhoneLaunchpadCreationPipeline] = [:]
    private(set) var globalActivity: String?
    var selection: String?
    var actionError: VPhoneLaunchpadError?

    let libraryRoot: URL
    private let bundles: VPhoneLaunchpadCoreBundle
    private let helper: VPhoneLaunchpadHelperClient
    private var launched: [String: VPhoneLaunchpadChildProcess] = [:]
    private var externallyRunning: Set<String> = []
    private var activities: [String: String] = [:]
    private var isRefreshing = false
    private var timer: Timer?

    init(libraryRoot: URL, bundles: VPhoneLaunchpadCoreBundle, helper: VPhoneLaunchpadHelperClient) {
        self.libraryRoot = libraryRoot
        self.bundles = bundles
        self.helper = helper
    }

    var libraryArguments: [String] {
        ["--library-root", libraryRoot.path]
    }

    var selected: VPhoneLaunchpadMachine? {
        machines.first { $0.name == selection }
    }

    var runningCount: Int {
        machines.count(where: { state(of: $0.name) == .running })
    }

    var hasActiveCreation: Bool {
        creations.values.contains(where: \.isRunning)
    }

    func state(of name: String) -> RunState {
        if let creation = creations[name], creation.isRunning, let step = creation.current {
            return .busy(String(localized: "Creating: \(step.title)"))
        }
        if let activity = activities[name] {
            return .busy(activity)
        }
        if launched[name]?.isRunning == true || externallyRunning.contains(name) {
            return .running
        }
        return .stopped
    }

    func launchedProcess(_ name: String) -> VPhoneLaunchpadChildProcess? {
        launched[name]
    }

    // MARK: - Refresh

    func startMonitoring() {
        guard timer == nil else {
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard let commandLine = bundles.commandLine(), !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await commandLine.run(["vm", "list", "--json"] + libraryArguments, recordInHistory: false)
            if result.succeeded, let data = result.jsonData {
                machines = try JSONDecoder().decode([VPhoneLaunchpadMachine].self, from: data)
                listError = nil
            } else {
                listError = result.tail
            }
        } catch {
            listError = error.localizedDescription
        }
        if selection == nil || !machines.contains(where: { $0.name == selection }) {
            selection = machines.first?.name
        }
        let root = libraryRoot
        let names = machines.map(\.name)
        externallyRunning = await Task.detached { Self.machinesHoldingDisks(root: root, names: names) }.value
    }

    /// The same test `vm stop` uses: a machine runs while some process holds
    /// its disk image open. This also finds guests started outside Launchpad.
    nonisolated private static func machinesHoldingDisks(root: URL, names: [String]) -> Set<String> {
        var diskOwners: [String: String] = [:]
        for name in names {
            let bundle = root.appendingPathComponent(name, isDirectory: true)
            let manifest = NSDictionary(contentsOf: bundle.appendingPathComponent("config.plist"))
            let disk = manifest?["diskImage"] as? String ?? "Disk.img"
            diskOwners[bundle.appendingPathComponent(disk).path] = name
        }
        guard !diskOwners.isEmpty else {
            return []
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-F", "n", "--"] + diskOwners.keys.sorted()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return []
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var running: Set<String> = []
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            if let name = diskOwners[String(line.dropFirst())] {
                running.insert(name)
            }
        }
        return running
    }

    // MARK: - Console

    static func consoleLog(_ name: String, suffix: String = "") -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/vphone-launchpad", isDirectory: true)
            .appendingPathComponent("\(name)\(suffix).log")
    }

    /// Adds a line of Launchpad's own to the console log, after the process
    /// that wrote it has exited.
    private func appendConsoleLog(_ name: String, _ line: String) {
        guard let handle = try? FileHandle(forWritingTo: Self.consoleLog(name)) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n\(line)\n".utf8))
    }

    // MARK: - Start and stop

    func start(_ name: String, headless: Bool = false) {
        guard let commandLine = bundles.commandLine() else {
            return
        }
        var arguments = ["vm", "launch", name] + libraryArguments
        if headless {
            arguments.append("--headless")
        }
        panicked.remove(name)
        do {
            let child = try commandLine.start(arguments, logFile: Self.consoleLog(name)) { [weak self] line in
                if VPhoneLaunchpadCreationPipeline.isPanic(line) {
                    Task { @MainActor in self?.panicked.insert(name) }
                }
            }
            launched[name] = child
            startedAt[name] = Date()
            Task {
                let status = await child.wait()
                if launched[name] === child {
                    launched[name] = nil
                    startedAt[name] = nil
                    appendConsoleLog(name, "vm launch exited with status \(status)")
                }
                await refresh()
            }
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Start \(name)"), detail: error.localizedDescription)
        }
    }

    func stop(_ name: String) async {
        await perform(String(localized: "Stopping…"), on: name, ["vm", "stop", name] + libraryArguments)
        launched[name]?.interrupt()
    }

    // MARK: - Edits

    func configure(_ name: String, cpu: Int?, memoryMB: Int?, network: String?, bridgeInterface: String?) async {
        var arguments = ["vm", "config", name] + libraryArguments
        if let cpu {
            arguments += ["--cpu", String(cpu)]
        }
        if let memoryMB {
            arguments += ["--memory", String(memoryMB)]
        }
        if let network {
            arguments += ["--network", network]
        }
        if let bridgeInterface, !bridgeInterface.isEmpty {
            arguments += ["--bridge-interface", bridgeInterface]
        }
        await perform(String(localized: "Saving settings…"), on: name, arguments)
    }

    func rename(_ name: String, to newName: String) async {
        if await perform(String(localized: "Renaming…"), on: name, ["vm", "rename", name, newName] + libraryArguments) {
            selection = newName
        }
    }

    func clone(_ name: String, as newName: String) async {
        if await perform(String(localized: "Cloning…"), on: name, ["vm", "clone", name, newName] + libraryArguments) {
            selection = newName
        }
    }

    func delete(_ name: String) async {
        await perform(String(localized: "Deleting…"), on: name, ["vm", "delete", name, "--force"] + libraryArguments)
    }

    func export(_ name: String, to destination: URL, densest: Bool, includeIPSW: Bool) async {
        var arguments = ["vm", "export", name, "--out", destination.path] + libraryArguments
        if densest {
            arguments.append("--max")
        }
        if includeIPSW {
            arguments.append("--include-ipsw")
        }
        await perform(String(localized: "Exporting…"), on: name, arguments)
    }

    func importArchive(_ archive: URL) async {
        await perform(String(localized: "Importing \(archive.lastPathComponent)"), on: nil, ["vm", "import", archive.path] + libraryArguments)
    }

    @discardableResult
    private func perform(_ activity: String, on name: String?, _ arguments: [String]) async -> Bool {
        guard let commandLine = bundles.commandLine() else {
            return false
        }
        if let name {
            activities[name] = activity
        } else {
            globalActivity = activity
        }
        defer {
            if let name {
                activities[name] = nil
            } else {
                globalActivity = nil
            }
        }
        do {
            try await commandLine.runChecked(arguments)
            await refresh()
            return true
        } catch {
            actionError = error as? VPhoneLaunchpadError
                ?? VPhoneLaunchpadError(String(localized: "Unable to Complete Action"), detail: error.localizedDescription)
            await refresh()
            return false
        }
    }

    // MARK: - Create

    func create(_ options: VPhoneLaunchpadCreationPipeline.Options) -> VPhoneLaunchpadCreationPipeline {
        let pipeline = VPhoneLaunchpadCreationPipeline(
            options: options,
            libraryRoot: libraryRoot,
            bundles: bundles,
            helper: helper,
            library: self,
        )
        creations[options.name] = pipeline
        pipeline.start()
        return pipeline
    }

    func discardCreation(_ name: String) {
        if creations[name]?.isRunning == false {
            creations[name] = nil
        }
    }
}

#if DEBUG
    extension VPhoneLaunchpadMachineLibrary {
        func applyPreview(creation: VPhoneLaunchpadCreationPipeline) {
            machines = VPhoneLaunchpadPreview.machines
            externallyRunning = ["research-01"]
            startedAt = ["research-01": Date().addingTimeInterval(-6130)]
            creations = ["ios27-rc": creation]
            selection = "research-01"
        }
    }
#endif
