import Foundation
import Observation

/// The third stage: the VM library, driven entirely through `vphone-cli vm`.
///
/// Machines can live in several libraries: the default one, and folders
/// chosen in New Machine. Each library is listed with its own
/// `--library-root`, and every action on a machine passes the root it was
/// listed from.
@MainActor
@Observable
final class VPhoneLaunchpadMachineLibrary {
    enum RunState: Equatable {
        case stopped
        case running
        case busy(String)
    }

    typealias Path = VPhoneLaunchpadMachinePath

    private(set) var machines: [VPhoneLaunchpadMachine] = []
    private(set) var listError: String?
    private(set) var startedAt: [Path: Date] = [:]
    /// Machines whose console printed a panic since Launchpad last started
    /// them. The console text itself stays in the log file.
    private(set) var panicked: Set<Path> = []
    private(set) var creations: [Path: VPhoneLaunchpadCreationPipeline] = [:]
    private(set) var globalActivity: String?
    /// Folders chosen in New Machine, in the order they were added. The
    /// default library is not among them.
    private(set) var addedRoots: [String]
    var selection: Path?
    var actionError: VPhoneLaunchpadError?

    /// The default library, canonical. Import writes here.
    let libraryRoot: String
    private let bundles: VPhoneLaunchpadCoreBundle
    private let helper: VPhoneLaunchpadHelperClient
    private var launched: [Path: VPhoneLaunchpadChildProcess] = [:]
    private var externallyRunning: Set<Path> = []
    private var activities: [Path: String] = [:]
    private var isRefreshing = false
    private var timer: Timer?

    private static let addedRootsKey = "VPhoneLaunchpadLibraryRoots"
    private static let lastRootKey = "VPhoneLaunchpadLastLibraryRoot"

    init(bundles: VPhoneLaunchpadCoreBundle, helper: VPhoneLaunchpadHelperClient) {
        libraryRoot = VPhoneLaunchpadMachineLocations.defaultRoot
        self.bundles = bundles
        self.helper = helper
        var roots: [String] = []
        for root in UserDefaults.standard.stringArray(forKey: Self.addedRootsKey) ?? []
            where root.hasPrefix("/") && root != libraryRoot && !roots.contains(root)
        {
            roots.append(root)
        }
        addedRoots = roots
    }

    /// Every library, the default one first.
    var roots: [String] {
        [libraryRoot] + addedRoots
    }

    var selected: VPhoneLaunchpadMachine? {
        machines.first { $0.id == selection }
    }

    var runningCount: Int {
        machines.count(where: { state(of: $0.path) == .running })
    }

    var hasActiveCreation: Bool {
        creations.values.contains(where: \.isRunning)
    }

    /// True while machines from more than one library are listed.
    var spansLibraries: Bool {
        Set(machines.map(\.libraryRoot)).count > 1
    }

    func state(of machine: Path) -> RunState {
        if let creation = creations[machine], creation.isRunning, let step = creation.current {
            return .busy(String(localized: "Creating: \(step.title)"))
        }
        if let activity = activities[machine] {
            return .busy(activity)
        }
        if launched[machine]?.isRunning == true || externallyRunning.contains(machine) {
            return .running
        }
        return .stopped
    }

    func launchedProcess(_ machine: Path) -> VPhoneLaunchpadChildProcess? {
        launched[machine]
    }

    // MARK: - Locations

    /// The library New Machine offers first: the one last created in, while
    /// it is mounted and usable (even once it holds no machine), else the
    /// default library.
    var preferredRoot: String {
        if let last = UserDefaults.standard.string(forKey: Self.lastRootKey), last.hasPrefix("/"),
           VPhoneLaunchpadMachineLocations.isAvailable(last),
           VPhoneLaunchpadMachineLocations.problem(with: last) == nil
        {
            return last
        }
        return libraryRoot
    }

    /// Remembers a folder so its machines are listed with the others.
    func addLocation(_ root: String) {
        guard root != libraryRoot, !addedRoots.contains(root) else {
            return
        }
        addedRoots.append(root)
        UserDefaults.standard.set(addedRoots, forKey: Self.addedRootsKey)
        Task { await refresh() }
    }

    /// Forgets added folders that were listed and hold no machine. A folder
    /// that is missing, or could not be listed, is kept: its volume may just
    /// not be mounted.
    private func forgetEmptyLocations(listed: Set<String>) {
        let kept = addedRoots.filter { root in
            !listed.contains(root)
                || machines.contains { $0.libraryRoot == root }
                || creations.keys.contains { $0.libraryRoot == root }
        }
        if kept != addedRoots {
            addedRoots = kept
            UserDefaults.standard.set(kept, forKey: Self.addedRootsKey)
        }
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
        var found: [VPhoneLaunchpadMachine] = []
        var listed: Set<String> = []
        var errors: [String] = []
        for root in roots {
            // vm list reports an empty library for a missing default root;
            // a missing added folder is skipped, and its machines go with it.
            guard root == libraryRoot || VPhoneLaunchpadMachineLocations.isAvailable(root) else {
                continue
            }
            do {
                let result = try await commandLine.run(["vm", "list", "--json", "--library-root", root], recordInHistory: false)
                if result.succeeded, let data = result.jsonData {
                    var machines = try JSONDecoder().decode([VPhoneLaunchpadMachine].self, from: data)
                    for index in machines.indices {
                        machines[index].libraryRoot = root
                    }
                    found += machines
                    listed.insert(root)
                    continue
                }
                errors.append(result.tail)
            } catch {
                errors.append(error.localizedDescription)
            }
            // Keep what this library listed last time, as before.
            found += machines.filter { $0.libraryRoot == root }
        }
        machines = found
        listError = errors.first
        forgetEmptyLocations(listed: listed)
        if selection == nil || !machines.contains(where: { $0.id == selection }) {
            selection = machines.first?.id
        }
        let paths = machines.map(\.path)
        externallyRunning = await Task.detached { Self.machinesHoldingDisks(paths) }.value
    }

    /// The same test `vm stop` uses: a machine runs while some process holds
    /// its disk image open. This also finds guests started outside Launchpad.
    private nonisolated static func machinesHoldingDisks(_ machines: [Path]) -> Set<Path> {
        var diskOwners: [String: Path] = [:]
        for machine in machines {
            let bundle = machine.url
            let manifest = NSDictionary(contentsOf: bundle.appendingPathComponent("config.plist"))
            // Only a plain file name inside the bundle: a crafted manifest must
            // not point lsof, and then `vm stop`, at another path.
            let disk = (manifest?["diskImage"] as? String).flatMap(Self.plainFileName) ?? "Disk.img"
            diskOwners[bundle.appendingPathComponent(disk).path] = machine
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
        var running: Set<Path> = []
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            if let machine = diskOwners[String(line.dropFirst())] {
                running.insert(machine)
            }
        }
        return running
    }

    /// `name` when it is one path component, otherwise nil.
    private nonisolated static func plainFileName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        return name
    }

    // MARK: - Console

    /// Machines in the default library keep their log names. Elsewhere the
    /// name gains a digest of the library, since two libraries may each hold
    /// a machine with the same name.
    static func consoleLog(_ machine: Path, suffix: String = "") -> URL {
        let stem = machine.libraryRoot == VPhoneLaunchpadMachineLocations.defaultRoot
            ? machine.name
            : "\(machine.name)-\(VPhoneLaunchpadMachineLocations.digest(machine.libraryRoot))"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/vphone-launchpad", isDirectory: true)
            .appendingPathComponent("\(stem)\(suffix).log")
    }

    /// Adds a line of Launchpad's own to the console log, after the process
    /// that wrote it has exited.
    private func appendConsoleLog(_ machine: Path, _ line: String) {
        guard let handle = try? FileHandle(forWritingTo: Self.consoleLog(machine)) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n\(line)\n".utf8))
    }

    // MARK: - Start and stop

    func start(_ machine: Path, headless: Bool = false) {
        guard let commandLine = bundles.commandLine() else {
            return
        }
        var arguments = ["vm", "launch", machine.name] + machine.libraryArguments
        if headless {
            arguments.append("--headless")
        }
        panicked.remove(machine)
        do {
            let child = try commandLine.start(arguments, logFile: Self.consoleLog(machine)) { [weak self] line in
                if VPhoneLaunchpadCreationPipeline.isPanic(line) {
                    Task { @MainActor in self?.panicked.insert(machine) }
                }
            }
            launched[machine] = child
            startedAt[machine] = Date()
            Task {
                let status = await child.wait()
                if launched[machine] === child {
                    launched[machine] = nil
                    startedAt[machine] = nil
                    appendConsoleLog(machine, "vm launch exited with status \(status)")
                }
                await refresh()
            }
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Start \(machine.name)"), detail: error.localizedDescription)
        }
    }

    func stop(_ machine: Path) async {
        await perform(String(localized: "Stopping…"), on: machine, ["vm", "stop", machine.name] + machine.libraryArguments)
        launched[machine]?.interrupt()
    }

    // MARK: - Edits

    func configure(_ machine: Path, cpu: Int?, memoryMB: Int?, network: String?, bridgeInterface: String?) async {
        var arguments = ["vm", "config", machine.name] + machine.libraryArguments
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
        await perform(String(localized: "Saving settings…"), on: machine, arguments)
    }

    func rename(_ machine: Path, to newName: String) async {
        if await perform(String(localized: "Renaming…"), on: machine, ["vm", "rename", machine.name, newName] + machine.libraryArguments) {
            selection = Path(libraryRoot: machine.libraryRoot, name: newName)
        }
    }

    func clone(_ machine: Path, as newName: String) async {
        if await perform(String(localized: "Cloning…"), on: machine, ["vm", "clone", machine.name, newName] + machine.libraryArguments) {
            selection = Path(libraryRoot: machine.libraryRoot, name: newName)
        }
    }

    func delete(_ machine: Path) async {
        await perform(String(localized: "Deleting…"), on: machine, ["vm", "delete", machine.name, "--force"] + machine.libraryArguments)
    }

    func export(_ machine: Path, to destination: URL, densest: Bool, includeIPSW: Bool) async {
        var arguments = ["vm", "export", machine.name, "--out", destination.path] + machine.libraryArguments
        if densest {
            arguments.append("--max")
        }
        if includeIPSW {
            arguments.append("--include-ipsw")
        }
        await perform(String(localized: "Exporting…"), on: machine, arguments)
    }

    func importArchive(_ archive: URL) async {
        await perform(
            String(localized: "Importing \(archive.lastPathComponent)"),
            on: nil,
            ["vm", "import", archive.path, "--library-root", libraryRoot],
        )
    }

    @discardableResult
    private func perform(_ activity: String, on machine: Path?, _ arguments: [String]) async -> Bool {
        guard let commandLine = bundles.commandLine() else {
            return false
        }
        if let machine {
            activities[machine] = activity
        } else {
            globalActivity = activity
        }
        defer {
            if let machine {
                activities[machine] = nil
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
            bundles: bundles,
            helper: helper,
            library: self,
        )
        creations[pipeline.machine] = pipeline
        UserDefaults.standard.set(options.libraryRoot, forKey: Self.lastRootKey)
        addLocation(options.libraryRoot)
        pipeline.start()
        return pipeline
    }

    func discardCreation(_ machine: Path) {
        if creations[machine]?.isRunning == false {
            creations[machine] = nil
        }
    }
}

#if DEBUG
    extension VPhoneLaunchpadMachineLibrary {
        func applyPreview(creation: VPhoneLaunchpadCreationPipeline) {
            machines = VPhoneLaunchpadPreview.machines
            externallyRunning = [VPhoneLaunchpadPreview.path("research-01")]
            startedAt = [VPhoneLaunchpadPreview.path("research-01"): Date().addingTimeInterval(-6130)]
            creations = [creation.machine: creation]
            selection = VPhoneLaunchpadPreview.path("research-01")
        }
    }
#endif
