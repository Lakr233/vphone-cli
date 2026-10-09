import Foundation
import Observation
import UniformTypeIdentifiers

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
    /// False until the first `vm list` answers, so the window does not show
    /// "No Machines" before it knows.
    private(set) var hasListed = false
    private(set) var startedAt: [Path: Date] = [:]
    /// Machines whose console printed a panic since Launchpad last started
    /// them. The console text itself stays in the log file.
    private(set) var panicked: Set<Path> = []
    private(set) var creations: [Path: VPhoneLaunchpadCreationPipeline] = [:]
    /// Each listed machine's Core Bundle, read from its `launchpad.json`.
    private(set) var bindings: [Path: VPhoneLaunchpadMachineBinding] = [:]
    /// Folders chosen in New Machine, in the order they were added. The
    /// default library is not among them.
    private(set) var addedRoots: [String]
    var selection: Set<Path> = []
    var actionError: VPhoneLaunchpadError?

    /// The default library, canonical. Import writes here.
    let libraryRoot: String
    private let bundles: VPhoneLaunchpadCoreBundle
    private let helper: VPhoneLaunchpadHelperClient
    private var launched: [Path: VPhoneLaunchpadChildProcess] = [:]
    /// The processes other than Launchpad that the last `lsof` listed for each
    /// machine's disk image, the machine's own VM included.
    private var diskHolders: [Path: [VPhoneLaunchpadDiskHolder]] = [:]
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

    /// The selected machines, in list order.
    var selectedMachines: [VPhoneLaunchpadMachine] {
        machines.filter { selection.contains($0.id) }
    }

    /// The selected machine when exactly one is selected.
    var selected: VPhoneLaunchpadMachine? {
        let selected = selectedMachines
        return selected.count == 1 ? selected[0] : nil
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

    /// The bar the state label shows in place of its text: an export's
    /// progress, or the IPSW download of a creation.
    func progress(of machine: Path) -> Double? {
        exports[machine]?.fraction ?? creation(for: machine)?.downloadFraction
    }

    /// A creation shows only its current step: the spinner says it is busy,
    /// and the inspector says what is being created.
    func state(of machine: Path) -> RunState {
        // The machine, or the temporary machine a template is built in.
        if let creation = creation(for: machine), creation.isRunning, let step = creation.current {
            return .busy(step.title)
        }
        if let activity = activities[machine] {
            return .busy(activity)
        }
        if exports[machine]?.isWaiting == true {
            return .busy(String(localized: "Waiting to export…"))
        }
        // Only a VM process holding the disk runs the machine; a reader such
        // as `tail` or a backup tool leaves it stopped (see `otherDiskHolders`).
        if launched[machine]?.isRunning == true || diskHolders[machine]?.contains(where: \.runsMachine) == true {
            return .running
        }
        return .stopped
    }

    /// The processes the last `lsof` listed for the machine's disk that do not
    /// run it. The machine is not running for them, but its disk is not
    /// standing still either: the meter leaves it alone, and operations that
    /// need the disk to themselves refuse.
    func otherDiskHolders(of machine: Path) -> [VPhoneLaunchpadDiskHolder] {
        diskHolders[machine, default: []].filter { !$0.runsMachine }
    }

    /// `otherDiskHolders`, asked of `lsof` now rather than at the last refresh.
    func currentOtherDiskHolders(of machine: Path) async -> [VPhoneLaunchpadDiskHolder] {
        await Task.detached { Self.diskHolders([machine])[machine, default: []] }.value.filter { !$0.runsMachine }
    }

    func launchedProcess(_ machine: Path) -> VPhoneLaunchpadChildProcess? {
        launched[machine]
    }

    /// The creation of a machine, or the one building a template in it.
    func creation(for machine: Path) -> VPhoneLaunchpadCreationPipeline? {
        creations[machine] ?? creations.values.first { $0.buildMachine == machine }
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
                        machines[index].guestProductType = VPhoneLaunchpadMachine.guestProductType(in: machines[index].path.url)
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
        hasListed = true
        forgetEmptyLocations(listed: listed)
        selection.formIntersection(machines.map(\.id) + imports.map(\.row))
        if selection.isEmpty, let first = machines.first {
            selection = [first.id]
        }
        let paths = machines.map(\.path)
        diskHolders = await Task.detached { Self.diskHolders(paths) }.value
        // A stopped machine's guest boots afresh when it starts again.
        pendingGuestRestarts = pendingGuestRestarts.filter { state(of: $0.key) != .stopped }
        await loadBindings(paths)
        refreshDiskUsage()
    }

    /// Every process other than Launchpad holding each machine's disk image,
    /// by executable. The same test `vm stop` uses: a machine runs while a VM
    /// process holds its disk, which also finds guests started outside
    /// Launchpad.
    private nonisolated static func diskHolders(_ machines: [Path]) -> [Path: [VPhoneLaunchpadDiskHolder]] {
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
            return [:]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-F", "pn", "--"] + diskOwners.keys.sorted()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return [:]
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return VPhoneLaunchpadDiskHolder.holders(lsofOutput: output, diskOwners: diskOwners, excluding: getpid())
    }

    /// `name` when it is one path component, otherwise nil.
    private nonisolated static func plainFileName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        return name
    }

    // MARK: - Core Bundle

    /// Reads every machine's binding. A machine without one, created before
    /// bindings existed or outside Launchpad, is bound to the default
    /// version, so a bundle installed later does not change what it runs. A
    /// machine still being created is skipped: its pipeline binds it.
    private func loadBindings(_ paths: [Path]) async {
        let pending = Set(creations.keys).union(creations.values.compactMap(\.buildMachine))
        let fallback = bundles.defaultVersion
        let before = bindings
        var loaded = await Task.detached {
            var bindings: [Path: VPhoneLaunchpadMachineBinding] = [:]
            for path in paths {
                if let binding = VPhoneLaunchpadMachineBinding.load(path) {
                    bindings[path] = binding
                } else if !pending.contains(path), let fallback {
                    let binding = VPhoneLaunchpadMachineBinding(bundle: fallback)
                    // An unwritable folder still runs with the default.
                    if (try? binding.save(to: path)) != nil {
                        bindings[path] = binding
                    }
                }
            }
            return bindings
        }.value
        // A binding written while the files were read is newer than its file
        // was then.
        for (path, binding) in bindings where before[path] != binding {
            loaded[path] = binding
        }
        bindings = loaded
    }

    /// The version a machine runs with: its binding, else the default.
    func bundleVersion(for machine: Path) -> String? {
        bindings[machine]?.bundle ?? bundles.defaultVersion
    }

    /// `vphone-cli` of the machine's own bundle. Nil when that version is
    /// not installed, for example on a machine imported from another Mac.
    func commandLine(for machine: Path) -> VPhoneLaunchpadCommandLine? {
        bundleVersion(for: machine).flatMap(bundles.commandLine(version:))
    }

    /// Names of the listed machines bound to `version`.
    func machineNames(boundTo version: String) -> [String] {
        machines.filter { bundleVersion(for: $0.path) == version }.map(\.name)
    }

    /// Names of the machines bound to `version` that are not stopped.
    func activeMachineNames(boundTo version: String) -> [String] {
        machines.filter { bundleVersion(for: $0.path) == version && state(of: $0.path) != .stopped }.map(\.name)
    }

    /// True when the machine's Core Bundle is not installed, so it cannot
    /// run until it is given another one.
    func isDamaged(_ machine: Path) -> Bool {
        bundleVersion(for: machine).map { !bundles.selectableVersions.contains($0) } ?? false
    }

    /// The binding on disk, or the listed copy when the file cannot be read.
    private func currentBinding(of machine: Path) -> VPhoneLaunchpadMachineBinding? {
        VPhoneLaunchpadMachineBinding.load(machine) ?? bindings[machine]
    }

    /// Writes a machine's binding and keeps the listed copy in step.
    func bind(_ machine: Path, _ binding: VPhoneLaunchpadMachineBinding) throws {
        try binding.save(to: machine)
        bindings[machine] = binding
    }

    /// Binds machines to another installed version. The host programs change
    /// on the next start. With `updateEnvironment`, each stopped machine also
    /// gets that version's guest environment; a running one keeps its own
    /// until it is updated later. Boot chain and patches stay as created.
    /// A machine whose disk another process holds is left as it was rather
    /// than rebound without its update (`VPhoneLaunchpadBundleChange`).
    /// `willUpdate` hears of each update just before it starts.
    func setBundle(
        _ version: String,
        for machines: [Path],
        updateEnvironment: Bool,
        willUpdate: (Path) -> Void = { _ in },
    ) async {
        guard bundles.commandLine(version: version) != nil else {
            actionError = VPhoneLaunchpadError(String(localized: "VPhone.bundle \(version) is not installed."))
            return
        }
        for machine in machines {
            var binding = currentBinding(of: machine)
                ?? VPhoneLaunchpadMachineBinding(bundle: version)
            binding.bundle = version
            // A machine not restored yet, or whose custom firmware install
            // did not finish, has no guest environment to update.
            let listed = self.machines.first { $0.path == machine }
            let updates = updateEnvironment && state(of: machine) == .stopped
                && listed?.restoreInfo != nil && listed?.customFirmwareInstalled != false
            let change: VPhoneLaunchpadBundleChange
            do {
                change = try await VPhoneLaunchpadBundleChange.perform(
                    updatesEnvironment: updates,
                    otherDiskHolders: { await currentOtherDiskHolders(of: machine) },
                    bind: { try bind(machine, binding) },
                    // A failed update says first which layer moved.
                    updateEnvironment: {
                        willUpdate(machine)
                        return await updateGuestEnvironment(machine) { failure in
                            VPhoneLaunchpadError(
                                String(localized: "Unable to Update the Guest Environment of \(machine.name)"),
                                detail: [
                                    String(localized: "\(machine.name) now runs with Core Bundle \(version), but its guest environment was not updated. Update its guest environment to finish the change."),
                                    failure.message,
                                    failure.detail,
                                ].compactMap(\.self).joined(separator: "\n\n"),
                            )
                        }
                    },
                )
            } catch {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to Change the Core Bundle of \(machine.name)"),
                    detail: error.localizedDescription,
                )
                continue
            }
            if case let .refused(others) = change {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to Change the Core Bundle of \(machine.name)"),
                    detail: Self.diskHeldDetail(machine, others),
                )
            }
        }
    }

    /// Records the bundle whose guest environment a machine now has.
    func recordGuestEnvironment(_ machine: Path, _ version: String) {
        var binding = VPhoneLaunchpadMachineBinding.load(machine) ?? VPhoneLaunchpadMachineBinding(bundle: version)
        binding.guestEnvironment = version
        try? bind(machine, binding)
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

    /// One line of helper output, from the XPC queue. Creates the log if the
    /// machine has never been started from Launchpad.
    private nonisolated static func append(_ line: String, to log: URL) {
        if !FileManager.default.fileExists(atPath: log.path) {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: log) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    // MARK: - Start and stop

    /// Starts a machine with its own bundle, after checking that bundle in
    /// this session (policy exception, host preflight and AMFI admission).
    func start(_ machine: Path, headless: Bool = false) async {
        guard let version = bundleVersion(for: machine) else {
            actionError = VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle."))
            return
        }
        let isChecking = !bundles.isChecked(version)
        if isChecking {
            activities[machine] = String(localized: "Checking Core Bundle…")
        }
        do {
            try await bundles.prepare(version)
            if isChecking {
                activities[machine] = nil
            }
        } catch {
            if isChecking {
                activities[machine] = nil
            }
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Start \(machine.name)"),
                detail: VPhoneLaunchpadError.message(for: error),
            )
            return
        }
        guard let commandLine = bundles.commandLine(version: version) else {
            return
        }
        // `vm launch` refuses these too, but only into the console log.
        guard !VPhoneLaunchpadMachine.customFirmwareIncomplete(at: machine) else {
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Start \(machine.name)"),
                detail: String(localized: "Custom firmware installation on this machine did not complete, so it cannot boot. Choose Install Custom Firmware from the machine's menu, then start it again."),
            )
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

    /// False, with `actionError` set, while a process that does not run the
    /// machine has its disk open. `cfw install` and the updates refuse such a
    /// disk, but say so only in the console log; this names the holder here.
    private func requireDiskUnheld(
        _ machine: Path,
        explain: (VPhoneLaunchpadError) -> VPhoneLaunchpadError = { $0 },
    ) async -> Bool {
        let others = await currentOtherDiskHolders(of: machine)
        guard !others.isEmpty else {
            return true
        }
        actionError = explain(VPhoneLaunchpadError(String(localized: "Unable to Complete Action"), detail: Self.diskHeldDetail(machine, others)))
        return false
    }

    /// Names the processes that hold a machine's disk without running it.
    private static func diskHeldDetail(_ machine: Path, _ others: [VPhoneLaunchpadDiskHolder]) -> String {
        String(localized: "The disk of \(machine.name) is open in process \(VPhoneLaunchpadDiskHolder.describe(others)), which does not run it. Try again once that process closes it.")
    }

    /// Runs `cfw install` again through the helper, for a machine whose last
    /// install did not finish. Output goes to the machine's console log.
    func installCustomFirmware(_ machine: Path) async {
        guard let version = bundleVersion(for: machine) else {
            actionError = VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle."))
            return
        }
        guard await requireDiskUnheld(machine) else {
            return
        }
        activities[machine] = String(localized: "Installing custom firmware…")
        defer { activities[machine] = nil }
        appendConsoleLog(machine, "$ vphone-cli cfw install \(machine.name)")
        let log = Self.consoleLog(machine)
        do {
            let status = try await helper.installCustomFirmware(
                bundleVersion: version,
                machineName: machine.name,
                libraryRoot: machine.libraryRoot,
                keepArtifacts: true,
                onLine: { line in Self.append(line, to: log) },
            )
            if status != 0 {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to install custom firmware. Check the log for details."),
                    detail: String(localized: "Choose Show Console Log for the full output."),
                )
            } else {
                recordGuestEnvironment(machine, version)
            }
        } catch {
            if !(error is CancellationError) {
                actionError = error as? VPhoneLaunchpadError
                    ?? VPhoneLaunchpadError(String(localized: "Unable to install custom firmware. Check the log for details."), detail: error.localizedDescription)
            }
        }
        await refresh()
    }

    /// Redeploys the guest resources (vphoned and the hook dylibs) of the
    /// machine's own bundle into it while it is stopped, through the helper,
    /// and nothing else. This is how a machine created by an older bundle
    /// gets newer hooks, since its restore tree is gone after the first boot.
    /// True once the environment is recorded as updated. `explain` rewords a
    /// failure before it is shown.
    @discardableResult
    func updateGuestEnvironment(
        _ machine: Path,
        explain: (VPhoneLaunchpadError) -> VPhoneLaunchpadError = { $0 },
    ) async -> Bool {
        guard let version = bundleVersion(for: machine) else {
            actionError = explain(VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle.")))
            return false
        }
        guard await requireDiskUnheld(machine, explain: explain) else {
            return false
        }
        var updated = false
        activities[machine] = String(localized: "Updating guest environment…")
        defer { activities[machine] = nil }
        appendConsoleLog(machine, "$ vphone-cli cfw update-environment \(machine.name)")
        let log = Self.consoleLog(machine)
        do {
            let status = try await helper.updateGuestEnvironment(
                bundleVersion: version,
                machineName: machine.name,
                libraryRoot: machine.libraryRoot,
                onLine: { line in Self.append(line, to: log) },
            )
            if status != 0 {
                actionError = explain(VPhoneLaunchpadError(
                    String(localized: "Unable to update the guest environment."),
                    detail: String(localized: "Choose Show Console Log for the full output."),
                ))
            } else {
                recordGuestEnvironment(machine, version)
                updated = true
            }
        } catch {
            if !(error is CancellationError) {
                actionError = explain(error as? VPhoneLaunchpadError
                    ?? VPhoneLaunchpadError(String(localized: "Unable to update the guest environment."), detail: error.localizedDescription))
            }
        }
        await refresh()
        return updated
    }

    /// Replaces the machine's Preboot kernelcache with the one its current
    /// patch selection resolves to, keeping the guest's data (no restore). The
    /// data-preserving way to apply a kernel patch change to an installed VM.
    func updateKernel(_ machine: Path) async {
        guard let version = bundleVersion(for: machine) else {
            actionError = VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle."))
            return
        }
        guard await requireDiskUnheld(machine) else {
            return
        }
        activities[machine] = String(localized: "Updating kernel…")
        defer { activities[machine] = nil }
        appendConsoleLog(machine, "$ vphone-cli cfw update-kernel \(machine.name)")
        let log = Self.consoleLog(machine)
        do {
            let status = try await helper.updateKernel(
                bundleVersion: version,
                machineName: machine.name,
                libraryRoot: machine.libraryRoot,
                onLine: { line in Self.append(line, to: log) },
            )
            if status != 0 {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to update the kernel."),
                    detail: String(localized: "Choose Show Console Log for the full output."),
                )
            }
        } catch {
            if !(error is CancellationError) {
                actionError = error as? VPhoneLaunchpadError
                    ?? VPhoneLaunchpadError(String(localized: "Unable to update the kernel."), detail: error.localizedDescription)
            }
        }
        await refresh()
    }

    /// Stops a machine. The guest is asked to shut down first, so it quits its
    /// apps and unmounts its volumes. `vm stop`, which ends the virtual
    /// machine the way cutting the power would, follows only when the guest
    /// cannot be asked or has not stopped in time.
    func stop(_ machine: Path) async {
        if await shutDownGuest(machine) {
            await refresh()
            return
        }
        await perform(String(localized: "Stopping…"), on: machine, ["vm", "stop", machine.name] + machine.libraryArguments)
        launched[machine]?.interrupt()
    }

    /// Kills the machine's VM processes, `vphone-vm` and Virtualization's VM
    /// service, without asking the guest or `vphone-cli`: for a guest that
    /// hangs or ignores a stop. They run as this user, so no helper is
    /// needed. The `vphone-cli` that launched it exits once they are gone.
    func forceStop(_ machine: Path) async {
        activities[machine] = String(localized: "Force stopping…")
        defer { activities[machine] = nil }
        let holders = await Task.detached {
            Self.diskHolders([machine])[machine, default: []].filter(\.runsMachine)
        }.value
        let refused = holders.filter { kill($0.pid, SIGKILL) != 0 && errno != ESRCH }
        if !refused.isEmpty {
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Force Stop \(machine.name)"),
                detail: refused.map(\.description).joined(separator: "\n"),
            )
        }
        launched[machine]?.terminate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await isMachineRunning(machine) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await refresh()
    }

    /// How long a guest gets to shut down before `vm stop` takes over.
    private static let guestShutdownTimeout: TimeInterval = 30

    /// Sends vphoned's `system.shutdown` over the machine's vphone.sock and
    /// waits for the virtual machine to stop. False when the guest could not
    /// be asked (not started up yet, in DFU, or a vphoned older than the
    /// method) or is still running when the time is up.
    private func shutDownGuest(_ machine: Path) async -> Bool {
        // A panicked guest has no vphoned left to ask.
        guard !panicked.contains(machine) else {
            return false
        }
        activities[machine] = String(localized: "Shutting down…")
        defer { activities[machine] = nil }
        let request: [String: Any] = ["t": "rpc", "method": "system.shutdown", "params": ["force": true]]
        let socket = machine.url.appendingPathComponent("vphone.sock").path
        do {
            _ = try await VPhoneLaunchpadGuestSocket.send(request, socketPath: socket, timeout: 10)
        } catch {
            return await !isMachineRunning(machine)
        }
        let deadline = Date().addingTimeInterval(Self.guestShutdownTimeout)
        while Date() < deadline {
            if await !isMachineRunning(machine) {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Whether the machine's virtual machine is still up: the process
    /// Launchpad started, or for one started elsewhere, a VM process holding
    /// its disk.
    func isMachineRunning(_ machine: Path) async -> Bool {
        if let child = launched[machine] {
            return child.isRunning
        }
        return await Task.detached { Self.diskHolders([machine])[machine, default: []].contains(where: \.runsMachine) }.value
    }

    // MARK: - Edits

    /// `networkArguments` are further `vm config` options (address, MAC, forwards),
    /// passed as the Settings sheet built them.
    func configure(
        _ machine: Path,
        cpu: Int?,
        memoryMB: Int?,
        network: String?,
        bridgeInterface: String?,
        networkArguments: [String] = [],
        unlocksAtStartup: Bool? = nil,
        syncsHostLocation: Bool? = nil,
    ) async {
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
        arguments += networkArguments
        if let unlocksAtStartup {
            arguments += ["--unlock-at-startup", unlocksAtStartup ? "on" : "off"]
        }
        if let syncsHostLocation {
            arguments += ["--sync-host-location", syncsHostLocation ? "on" : "off"]
        }
        await perform(String(localized: "Saving settings…"), on: machine, arguments)
    }

    /// Records a new patch choice for the machine with its own bundle's
    /// `fw set-patches`. Nothing in the guest changes until the guest
    /// environment is updated, or, for the boot chain, the machine restored.
    @discardableResult
    func setPatches(_ selection: VPhoneLaunchpadPatchSelection, for machine: Path) async -> Bool {
        await perform(
            String(localized: "Saving patches…"),
            on: machine,
            ["fw", "set-patches", machine.name] + selection.setPatchesArguments + machine.libraryArguments,
        )
    }

    func rename(_ machine: Path, to newName: String) async {
        if await perform(String(localized: "Renaming…"), on: machine, ["vm", "rename", machine.name, newName] + machine.libraryArguments) {
            selection = [Path(libraryRoot: machine.libraryRoot, name: newName)]
        }
    }

    /// With `newIdentity` the clone gets its own ECID, UDID and MAC address,
    /// so both machines can run at once; a plain clone is the same device.
    func clone(_ machine: Path, as newName: String, newIdentity: Bool) async {
        if await perform(String(localized: "Cloning…"), on: machine, machine.cloneArguments(as: newName, newIdentity: newIdentity)) {
            selection = [Path(libraryRoot: machine.libraryRoot, name: newName)]
        }
    }

    /// Removing the folder needs nothing version-specific, so a machine whose
    /// own bundle is gone or from an unsupported series is deleted with the
    /// default one instead of having to be rebound first.
    ///
    /// When the machine was the last one cloned from a template, `vm delete`
    /// says so and leaves the template; `templateNotice` passes that on.
    func delete(_ machine: Path) async {
        do {
            let result = try await performChecked(
                String(localized: "Deleting…"),
                on: machine,
                ["vm", "delete", machine.name, "--force"] + machine.libraryArguments,
                anyBundle: true,
            )
            // A creation that stopped short goes with its machine; kept, it
            // would still claim its IPSWs in Downloaded Firmware.
            discardCreation(machine)
            if let notice = VPhoneLaunchpadTemplateNotice.parse(result.lines, libraryRoot: machine.libraryRoot) {
                templateNotice = notice
            }
        } catch {
            if !(error is CancellationError) {
                actionError = VPhoneLaunchpadError(actionFailure: error)
            }
        }
    }

    /// The template the last deleted machine was cloned from, now used by
    /// no machine. The machine list shows it once.
    var templateNotice: VPhoneLaunchpadTemplateNotice?

    // MARK: - Disk use

    /// What each listed machine takes on disk, measured off the main actor
    /// at most every `diskUsageInterval` seconds.
    private(set) var diskUsage: [Path: VPhoneLaunchpadDiskUsage] = [:]
    private var diskUsageMeasured: Date?
    private var isMeasuringDiskUsage = false
    /// A forced measurement asked for while one ran.
    private var isDiskUsageRequested = false
    private let diskMeter = VPhoneLaunchpadDiskMeter()
    private static let diskUsageInterval: TimeInterval = 30

    /// Measures again when the last measurement is old, or a machine was
    /// added. Every machine and template of every library is measured in one
    /// pass, because a folder's exclusive size depends on all the others.
    /// Only files that changed are mapped again, and never on every
    /// five-second refresh.
    private func refreshDiskUsage(force: Bool = false) {
        let paths = machines.map(\.path)
        let isNew = paths.contains { diskUsage[$0] == nil }
        let isOld = diskUsageMeasured.map { Date().timeIntervalSince($0) > Self.diskUsageInterval } ?? true
        guard !isMeasuringDiskUsage else {
            isDiskUsageRequested = isDiskUsageRequested || force
            return
        }
        guard force || isNew || isOld else {
            return
        }
        isMeasuringDiskUsage = true
        let machineFolders = machines.map { machine in
            VPhoneLaunchpadDiskMeter.Folder(path: machine.path.url.path, mayOpen: diskAccess(of: machine.path).mayOpen)
        }
        let libraryRoots = roots.filter { $0 == libraryRoot || VPhoneLaunchpadMachineLocations.isAvailable($0) }
        let meter = diskMeter
        let templatesMayOpen = templatesMayOpen
        let mayOpenNow: @Sendable (String) async -> Bool = { [weak self] folder in
            await self?.mayOpenDisk(inFolder: folder) ?? false
        }
        Task {
            let measured = await Self.measure(
                machineFolders,
                paths: paths,
                libraryRoots: libraryRoots,
                templatesMayOpen: templatesMayOpen,
                meter: meter,
                mayOpenNow: mayOpenNow,
            )
            diskUsage = measured.usage
            templateUsage = measured.templates
            hasTemplates = measured.hasTemplates
            diskUsageMeasured = Date()
            isMeasuringDiskUsage = false
            if isDiskUsageRequested {
                isDiskUsageRequested = false
                refreshDiskUsage(force: true)
            }
        }
    }

    /// Whether the disk meter may open this machine's files now: only when
    /// no `vm launch` of Launchpad's for it is still running (a start, a
    /// run, a stop), the last `lsof` named no other process for its disk,
    /// and Launchpad has no operation on it or on a whole library.
    private func diskAccess(of machine: Path) -> VPhoneLaunchpadDiskAccess {
        let isBusy = if case .busy = state(of: machine) {
            true
        } else {
            false
        }
        return VPhoneLaunchpadDiskAccess(
            isLaunched: launched[machine] != nil,
            isHeld: diskHolders[machine]?.isEmpty == false,
            isBusy: isBusy || creation(for: machine)?.isRunning == true || exports[machine] != nil,
            isLibraryBusy: isImporting,
        )
    }

    /// Whether the meter may open template files now: not while a
    /// library-wide operation (a template deletion) runs, nor while a
    /// creation saves a template or clones one, which `vm create --template`
    /// refuses while another process holds the template open.
    private var templatesMayOpen: Bool {
        VPhoneLaunchpadDiskAccess.templatesMayOpen(
            isLibraryBusy: isImporting,
            creationSteps: creations.values.filter(\.isRunning).compactMap(\.current),
        )
    }

    /// `diskAccess` for a measured folder, asked right before the meter
    /// opens one of its files. A template folder may be opened while
    /// `templatesMayOpen`; a folder that is neither a listed machine nor a
    /// template is not opened.
    private func mayOpenDisk(inFolder folder: String) -> Bool {
        if let machine = machines.first(where: { $0.path.url.path == folder }) {
            return diskAccess(of: machine.path).mayOpen
        }
        let isTemplate = URL(fileURLWithPath: folder).deletingLastPathComponent().lastPathComponent == ".templates"
        return isTemplate && templatesMayOpen
    }

    @concurrent
    private nonisolated static func measure(
        _ machineFolders: [VPhoneLaunchpadDiskMeter.Folder],
        paths: [Path],
        libraryRoots: [String],
        templatesMayOpen: Bool,
        meter: VPhoneLaunchpadDiskMeter,
        mayOpenNow: @escaping @Sendable (String) async -> Bool,
    ) async -> (usage: [Path: VPhoneLaunchpadDiskUsage], templates: [String: VPhoneLaunchpadDiskUsage], hasTemplates: Bool) {
        // Templates are keyed as `usage(of:)` looks them up.
        var templateKeys: [String: String] = [:]
        var hasBuilds = false
        for root in libraryRoots {
            for folder in VPhoneLaunchpadDiskMeter.templateFolders(in: root) {
                templateKeys[folder] = URL(fileURLWithPath: folder).lastPathComponent + "@" + root
            }
            hasBuilds = hasBuilds || VPhoneLaunchpadDiskMeter.hasTemplateBuilds(in: root)
        }
        let folders = machineFolders + templateKeys.keys.sorted().map { VPhoneLaunchpadDiskMeter.Folder(path: $0, mayOpen: templatesMayOpen) }
        let measured = await meter.measure(folders, mayOpenNow: mayOpenNow)
        var usage: [Path: VPhoneLaunchpadDiskUsage] = [:]
        for path in paths {
            usage[path] = measured[path.url.path]
        }
        var templates: [String: VPhoneLaunchpadDiskUsage] = [:]
        for (folder, key) in templateKeys {
            templates[key] = measured[folder]
        }
        return (usage, templates, !templateKeys.isEmpty || hasBuilds)
    }

    // MARK: - Templates

    /// Every library's templates, from `vm template list --json` with the
    /// default bundle. Nil until read.
    private(set) var templates: [VPhoneLaunchpadTemplate]?
    /// Template builds a create left behind (or is running), by library.
    private(set) var templateBuilds: [(libraryRoot: String, build: VPhoneLaunchpadTemplateList.Building)] = []
    private(set) var templatesError: String?
    /// Each template's disk use, by `<identifier>@<library root>`, measured
    /// with the machines.
    private(set) var templateUsage: [String: VPhoneLaunchpadDiskUsage] = [:]

    /// Whether any library holds a template or a left-over build, from the
    /// disk meter's scan of `.templates` and from `refreshTemplates`. The
    /// Templates menu item is shown only then.
    private(set) var hasTemplates = false

    func refreshTemplates() async {
        guard let commandLine = bundles.commandLine() else {
            templatesError = String(localized: "No Core Bundle version is installed. Install one in Core Bundle.")
            return
        }
        var found: [VPhoneLaunchpadTemplate] = []
        var builds: [(libraryRoot: String, build: VPhoneLaunchpadTemplateList.Building)] = []
        var errors: [String] = []
        for root in roots where root == libraryRoot || VPhoneLaunchpadMachineLocations.isAvailable(root) {
            do {
                let result = try await commandLine.run(VPhoneLaunchpadTemplateCommands.list + ["--library-root", root], recordInHistory: false)
                guard result.succeeded, let data = result.jsonData else {
                    errors.append(result.tail)
                    continue
                }
                let list = try VPhoneLaunchpadTemplateList.decode(data, libraryRoot: root)
                found += list.templates
                builds += list.building.map { (root, $0) }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        templates = found.sorted { $0.created > $1.created }
        templateBuilds = builds
        templatesError = errors.first
        if errors.isEmpty {
            hasTemplates = !found.isEmpty || !builds.isEmpty
        }
        refreshDiskUsage(force: true)
    }

    func usage(of template: VPhoneLaunchpadTemplate) -> VPhoneLaunchpadDiskUsage? {
        templateUsage[template.id + "@" + template.libraryRoot]
    }

    /// Deletes a template, or a left-over build by its `.building-…` name.
    /// Machines cloned from it keep working.
    func deleteTemplate(_ identifier: String, in root: String) async throws {
        try await performChecked(
            String(localized: "Deleting template…"),
            on: nil,
            VPhoneLaunchpadTemplateCommands.delete(identifier) + ["--library-root", root],
        )
        await refreshTemplates()
    }

    // MARK: - Guest

    /// One vphoned call over the running machine's `vphone.sock`, as
    /// `vphone-launchpad-cli guest rpc` makes it. The reply's `result`.
    func guestCall(_ machine: Path, _ method: String, _ params: [String: Any] = [:], timeout: Int = 120) async throws -> [String: Any] {
        let request: [String: Any] = ["t": "rpc", "method": method, "params": params, "screen": false]
        let reply = try await VPhoneLaunchpadGuestSocket.send(
            request,
            socketPath: machine.url.appendingPathComponent("vphone.sock").path,
            timeout: timeout,
        )
        return (reply as? [String: Any])?["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Guest restarts

    /// Service profile changes waiting for their guest to restart, by
    /// machine. Kept for this Launchpad session, so the Guest System sheet
    /// shows them when it opens again.
    private(set) var pendingGuestRestarts: [Path: VPhoneLaunchpadPendingRestart] = [:]

    /// The guest's current boot, launchd's start time; nil when the guest
    /// does not answer.
    func guestBoot(_ machine: Path) async -> Double? {
        guard let result = try? await guestCall(machine, "processes.list", ["filter": "launchd"], timeout: 20) else {
            return nil
        }
        return VPhoneLaunchpadPendingRestart.boot(fromProcesses: result)
    }

    /// Keeps what `services.profile.apply` left waiting for a restart.
    func recordServiceProfileApply(_ machine: Path, result: [String: Any], boot: Double?) {
        pendingGuestRestarts[machine] = VPhoneLaunchpadPendingRestart.afterApply(result, pending: pendingGuestRestarts[machine], boot: boot)
    }

    /// Whether a change still waits for the guest to restart. Forgets it once
    /// the guest answers from a later boot.
    func isGuestRestartPending(_ machine: Path) async -> Bool {
        guard let pending = pendingGuestRestarts[machine] else {
            return false
        }
        if await pending.hasRestarted(currentBoot: guestBoot(machine)) {
            pendingGuestRestarts[machine] = nil
            return false
        }
        return true
    }

    func forgetPendingRestart(_ machine: Path) {
        pendingGuestRestarts[machine] = nil
    }

    // MARK: - Export

    /// An export queued or under way. `fraction` is nil until the command
    /// reports progress; `task` is nil while the export waits its turn.
    struct Export {
        var fraction: Double?
        fileprivate var task: Task<Void, Never>?

        var isWaiting: Bool {
            task == nil
        }
    }

    private(set) var exports: [Path: Export] = [:]

    /// Exports each machine to its destination file, one at a time: each
    /// export reads a whole disk image.
    func export(_ items: [(machine: Path, destination: URL)]) async {
        for item in items {
            exports[item.machine] = Export()
        }
        for item in items {
            // Cancelled while it waited.
            guard exports[item.machine] != nil else {
                continue
            }
            let task = Task {
                await runExport(item.machine, to: item.destination)
            }
            exports[item.machine]?.task = task
            await task.value
            exports[item.machine] = nil
        }
    }

    /// Stops an export under way, or takes a waiting one out of the queue.
    func cancelExport(_ machine: Path) {
        guard let export = exports[machine] else {
            return
        }
        if let task = export.task {
            task.cancel()
        } else {
            exports[machine] = nil
        }
    }

    private func runExport(_ machine: Path, to destination: URL) async {
        // zstd, the default: Launchpad does not offer xz. Never
        // --include-ipsw: the restore IPSWs stay in the IPSW cache.
        let arguments = ["vm", "export", machine.name, "--out", destination.path] + machine.libraryArguments
        await perform(String(localized: "Exporting…"), on: machine, arguments) { [weak self] fraction in
            Task { @MainActor in self?.exports[machine]?.fraction = fraction }
        }
        // `vm export` writes the archive in place, so a cancelled one leaves
        // a partial file behind.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    /// What Import accepts: `.vpea`, and the `.tzst` and `.txz` names exports
    /// had before it. `vm import` detects the compressor, not the name.
    static var importableTypes: [UTType] {
        [.vphoneExportedArchive] + ["tzst", "txz"].compactMap { UTType(filenameExtension: $0) }
    }

    // MARK: - Import

    /// An import queued or under way, listed as a row of its own until the
    /// machine it brings appears. `fraction` is nil until the command reports
    /// progress; `task` is nil while the import waits its turn.
    struct Import: Identifiable {
        let id = UUID()
        let archive: URL
        /// The default library, which every import writes to.
        let libraryRoot: String
        var fraction: Double?
        fileprivate var task: Task<Void, Never>?

        var isWaiting: Bool {
            task == nil
        }

        /// The archive's name without its extension, which is the machine's
        /// name unless the export was renamed.
        var name: String {
            archive.deletingPathExtension().lastPathComponent
        }

        /// The row's identity in the machine table. No machine has it: a
        /// machine name cannot start with a dot.
        var row: Path {
            Path(libraryRoot: libraryRoot, name: ".import-\(id.uuidString)")
        }
    }

    private(set) var imports: [Import] = []
    /// The last import queued; each one waits for the one before.
    private var lastImport: Task<Void, Never>?

    /// True while an import unpacks into the library.
    var isImporting: Bool {
        imports.contains { !$0.isWaiting }
    }

    func importItem(_ row: Path) -> Import? {
        imports.first { $0.row == row }
    }

    /// Imports one archive after those already queued: each import writes a
    /// whole disk image.
    func importArchive(_ archive: URL) async {
        let item = Import(archive: archive, libraryRoot: libraryRoot)
        imports.append(item)
        // So the inspector shows the import as it runs.
        selection = [item.row]
        let previous = lastImport
        let queued = Task {
            await previous?.value
            await runImport(item.id)
        }
        lastImport = queued
        await queued.value
    }

    private func runImport(_ id: UUID) async {
        // Cancelled while it waited.
        guard let index = imports.firstIndex(where: { $0.id == id }) else {
            return
        }
        let item = imports[index]
        let arguments = ["vm", "import", item.archive.path, "--library-root", libraryRoot]
        let task = Task {
            do {
                let result = try await performChecked(String(localized: "Importing…"), on: nil, arguments) { fraction in
                    Task { @MainActor in
                        guard let index = self.imports.firstIndex(where: { $0.id == id }) else {
                            return
                        }
                        self.imports[index].fraction = fraction
                    }
                }
                // `imported → <name>`: the import's row gives way to the
                // machine, selected in its place.
                if let name = result.lines.last(where: { $0.hasPrefix("imported → ") })?.dropFirst("imported → ".count),
                   selection == [item.row]
                {
                    selection = [Path(libraryRoot: libraryRoot, name: String(name))]
                }
            } catch {
                if !(error is CancellationError) {
                    actionError = VPhoneLaunchpadError(actionFailure: error)
                }
            }
        }
        imports[index].task = task
        await task.value
        imports.removeAll { $0.id == id }
        selection.remove(item.row)
    }

    /// Stops an import under way, or takes a waiting one out of the queue.
    /// `vm import` removes what it had unpacked.
    func cancelImport(_ id: UUID) {
        guard let item = imports.first(where: { $0.id == id }) else {
            return
        }
        if let task = item.task {
            task.cancel()
        } else {
            imports.removeAll { $0.id == id }
        }
    }

    /// True while an import or an export is queued or under way.
    var hasActiveTransfer: Bool {
        !imports.isEmpty || !exports.isEmpty
    }

    /// Stops every import and export and waits for their commands to exit,
    /// so none is left running, or half written, when Launchpad quits.
    func stopTransfers() async {
        let running = imports.compactMap(\.task) + exports.values.compactMap(\.task)
        imports.removeAll { $0.isWaiting }
        exports = exports.filter { !$0.value.isWaiting }
        for task in running {
            task.cancel()
        }
        for task in running {
            await task.value
        }
    }

    /// Runs one command with `activity` shown as the machine's state. False
    /// when it failed, or was cancelled, which is not reported as an error.
    @discardableResult
    private func perform(
        _ activity: String,
        on machine: Path?,
        _ arguments: [String],
        anyBundle: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> Bool {
        do {
            try await performChecked(activity, on: machine, arguments, anyBundle: anyBundle, onProgress: onProgress)
            return true
        } catch {
            if !(error is CancellationError) {
                actionError = VPhoneLaunchpadError(actionFailure: error)
            }
            return false
        }
    }

    /// `perform` for a sheet that reports its own errors: throws what failed,
    /// or `CancellationError` when the command was cancelled.
    @discardableResult
    private func performChecked(
        _ activity: String,
        on machine: Path?,
        _ arguments: [String],
        anyBundle: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> VPhoneLaunchpadCommandResult {
        // A machine's commands run with its own bundle; `anyBundle` lets one
        // that needs no particular version fall back to the default.
        let commandLine: VPhoneLaunchpadCommandLine? = if let machine {
            self.commandLine(for: machine) ?? (anyBundle ? bundles.commandLine() : nil)
        } else {
            bundles.commandLine()
        }
        guard let commandLine else {
            if let machine {
                throw Self.missingBundle(machine)
            }
            throw CancellationError()
        }
        // Without a machine, the caller shows the activity itself: Import
        // shows a row of its own.
        if let machine {
            activities[machine] = activity
        }
        defer {
            if let machine {
                activities[machine] = nil
            }
        }
        do {
            let result = try await commandLine.runChecked(arguments, onProgress: onProgress)
            await refresh()
            return result
        } catch {
            await refresh()
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func missingBundle(_ machine: Path) -> VPhoneLaunchpadError {
        VPhoneLaunchpadError(
            String(localized: "Unable to Complete Action"),
            detail: String(localized: "The Core Bundle of \(machine.name) is not installed. Choose another Core Bundle for it."),
        )
    }

    // MARK: - Snapshots

    /// The machine's snapshots, oldest first, from its own bundle's
    /// `vm snapshot list --json`. Errors go to the caller, the Snapshots
    /// sheet, which shows them itself.
    func snapshots(of machine: Path) async throws -> [VPhoneLaunchpadMachineSnapshot] {
        guard let commandLine = commandLine(for: machine) else {
            throw Self.missingBundle(machine)
        }
        let result = try await commandLine.run(machine.snapshotListArguments, recordInHistory: false)
        guard result.succeeded, let data = result.jsonData else {
            throw VPhoneLaunchpadError(String(localized: "Unable to List Snapshots"), detail: result.tail)
        }
        return try VPhoneLaunchpadMachineSnapshot.list(from: data)
    }

    /// Takes a snapshot of a stopped machine, then saves its binding with it
    /// so a revert can tell which bundles built what the snapshot holds.
    func createSnapshot(of machine: Path, name: String, note: String?) async throws {
        try await performChecked(
            String(localized: "Taking snapshot…"),
            on: machine,
            machine.snapshotCreateArguments(name, note: note),
        )
        // The snapshot is taken either way; without the copy a revert can
        // only mark the guest environment and boot chain unknown.
        if let binding = currentBinding(of: machine) {
            try? binding.save(to: machine, snapshot: name)
        }
    }

    /// Puts a snapshot's disk, SEP storage and NVRAM back in place of the
    /// machine's own. What was there is gone unless it was snapshotted too.
    func revertSnapshot(of machine: Path, to name: String) async throws {
        try await performChecked(
            String(localized: "Reverting to snapshot…"),
            on: machine,
            machine.snapshotRevertArguments(name),
        )
        // The guest environment and the boot chain are on the disk and in
        // the NVRAM the revert just replaced, so the binding takes them from
        // the copy saved with the snapshot, or become unknown when there is
        // none to read (a snapshot taken with vphone-cli, or a copy that was
        // not written). The bundle is not on the disk: the machine keeps
        // running with the one chosen now.
        if let current = currentBinding(of: machine) {
            let saved = VPhoneLaunchpadMachineBinding.load(machine, snapshot: name)
            try? bind(machine, current.reverted(to: saved))
        }
    }

    func deleteSnapshot(of machine: Path, name: String) async throws {
        try await performChecked(
            String(localized: "Deleting snapshot…"),
            on: machine,
            machine.snapshotDeleteArguments(name),
        )
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
            hasListed = true
            diskHolders = [VPhoneLaunchpadPreview.path("research-01"): [
                VPhoneLaunchpadDiskHolder(pid: 4101, executablePath: "/Library/Application Support/vphone-launchpad/Bundles/2.9.0/VPhone.bundle/Contents/MacOS/vphone-vm"),
            ]]
            startedAt = [VPhoneLaunchpadPreview.path("research-01"): Date().addingTimeInterval(-6130)]
            creations = [creation.machine: creation]
            selection = [VPhoneLaunchpadPreview.path("research-01")]
            applyPreviewDiskUsage()
            // One machine on an older bundle whose guest environment was not
            // updated with it, so the inspector shows mixed versions.
            let current = VPhoneLaunchpadPreview.releases[1].version
            let older = VPhoneLaunchpadPreview.releases[2].version
            bindings = Dictionary(uniqueKeysWithValues: machines.map { machine in
                let binding = machine.name == "research-01"
                    ? VPhoneLaunchpadMachineBinding(bundle: current, bootChain: older, guestEnvironment: older)
                    : VPhoneLaunchpadMachineBinding(bundle: current, bootChain: current, guestEnvironment: current)
                return (machine.path, binding)
            })
        }

        /// Disk use for the mock machines.
        func applyPreviewDiskUsage() {
            let research = VPhoneLaunchpadPreview.path("research-01")
            diskUsage = [
                research: VPhoneLaunchpadDiskUsage(allocated: 17_812_000_000, exclusive: 612_000_000),
                VPhoneLaunchpadPreview.labMachine: VPhoneLaunchpadDiskUsage(allocated: 21_406_000_000, exclusive: 3_240_000_000),
            ]
            diskUsageMeasured = Date()
        }

        func applyPreviewTemplates() {
            templates = VPhoneLaunchpadPreview.templates
            templateBuilds = (VPhoneLaunchpadPreview.templateList?.building ?? []).map { (VPhoneLaunchpadMachineLocations.defaultRoot, $0) }
            templatesError = nil
            templateUsage = [
                "52b1fcc75e0c@\(libraryRoot)": VPhoneLaunchpadDiskUsage(allocated: 17_580_000_000, exclusive: 106_000_000),
                "9d04a7c3e1b2@\(libraryRoot)": VPhoneLaunchpadDiskUsage(allocated: 19_310_000_000, exclusive: 19_310_000_000),
                "2246f982776c@\(libraryRoot)": VPhoneLaunchpadDiskUsage(allocated: 18_920_000_000, exclusive: 15_700_000_000),
            ]
        }

        /// What deleting the last machine of a template leaves to say.
        func applyPreviewNotice() {
            templateNotice = VPhoneLaunchpadTemplateNotice(id: "9d04a7c3e1b2", size: "19.31 GB", libraryRoot: libraryRoot)
        }

        /// The mock list without one machine, as a refresh leaves it after
        /// the machine is deleted.
        func applyPreview(removing machine: Path) {
            machines.removeAll { $0.path == machine }
            selection.remove(machine)
        }
    }
#endif
