import ArgumentParser
import Foundation
import VPhoneCoreKit

struct VPhoneVirtualMachineLaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Boot a VM bundle (runs host preflight first)",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Boot into DFU mode (headless)") var dfu = false
    @Flag(name: .customLong("headless"), help: "Boot without a VM window or menu bar") var headless = false
    @Option(help: "Expose the guest HTTP/WebSocket API on host:port (for example 127.0.0.1:8765)")
    var apiListen: String?
    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned; valid: 6000...65535)")
    var kernelDebugPort: Int?
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int
    @Flag(help: "Start the VM in its own session, log to Launchpad's console log and return once vphoned answers")
    var detach = false
    @Option(parsing: .unconditional, help: "With --detach: seconds to wait for vphoned (default 300)")
    var timeout: Int?

    func validate() throws {
        if dfu, apiListen != nil {
            throw ValidationError("`--api-listen` is unavailable with `--dfu`.")
        }
        if timeout != nil, !detach {
            throw ValidationError("`--timeout` needs `--detach`.")
        }
        if detach, dfu {
            throw ValidationError("`--detach` is unavailable with `--dfu` (DFU has no vphoned).")
        }
        if let timeout, timeout < 1 {
            throw ValidationError("`--timeout` must be a whole number of seconds, 1 or more.")
        }
    }

    /// `--timeout` in seconds; `validate()` has already rejected anything else.
    private var timeoutSeconds: Int { timeout ?? 300 }

    func run() throws {
        if detach { return try runDetached() }
        let v = VPhoneVerbosity(count: verboseCount)
        if name == nil {
            let scan = try lib.library.scan()
            if scan.bundles.isEmpty, let incompatible = scan.skipped.first {
                throw ValidationError("VM '\(incompatible.name)' cannot launch: \(incompatible.reason)")
            }
        }
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        try VPhoneMachineTemplates.requireBootable(bundleURL: bundle.url)
        defer {
            do { try VPhoneHostFilePermissions.makeAccessible(at: bundle.url) }
            catch { fputs("warning: could not set VM file permissions: \(error)\n", stderr) }
        }
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let layout = VPhoneLaunchLayout(resources: resources)

        // The guest runs in vphone-vm, not in this process — that is the binary
        // carrying the virtualization entitlements, so it is also the one
        // preflight has to check. Checking ourselves would prove nothing: this
        // binary is unentitled and always launches.
        let launcher: VPhoneGuestLaunchPlanner
        do {
            launcher = try VPhoneHostPreflight.check()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode(1)
        }
        if !dfu {
            // A system the restore installed customised (`minimal`) is sealed and
            // boots on a stock AMFI: a vphoned the host pushed would never run,
            // and the host would push it again on every probe. Without the
            // staged copy, vphone-vm pushes none.
            if VPhoneCustomFirmwareInstaller.restoredCustomisedSystem(VPhonePatchPresetStore.plan(forVM: bundle.url)) {
                try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(".vphoned.signed"))
            } else {
                _ = try layout.stageVphoned(into: bundle)
            }
        }

        let boot = VPhoneBootCommand(
            config: bundle.configURL,
            dfu: dfu,
            headless: headless,
            apiListen: apiListen,
            kernelDebugPort: kernelDebugPort,
        )
        let args = boot.bootArguments

        if v.tracesInternals {
            let (exe, spawned) = launcher.plan(args)
            print("[trace] spawning: \(exe.path) \(spawned.joined(separator: " "))")
        }

        // `vm launch` always streams the guest serial console (inherits our
        // stdio); it is intentionally not gated on verbosity. run() also hands
        // the terminal to the child, which is what lets Ctrl-C reach the guest.
        defer {
            do { try VPhoneShaderCache.checkpoint(machineDirectory: bundle.url) }
            catch { fputs("warning: could not save shader cache: \(error)\n", stderr) }
        }
        throw try ExitCode(launcher.run(args, cwd: bundle.url))
    }

    private func fail(_ message: String) -> ExitCode {
        fputs("\(message)\n", stderr)
        return ExitCode(1)
    }

    /// Re-runs this command as a detached child that logs to Launchpad's
    /// console log, then waits for vphoned to answer.
    private func runDetached() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let log = VPhoneMachineConsoleLog.url(
            libraryRoot: VPhoneMachineConsoleLog.canonical(lib.library.root),
            name: name,
            defaultRoot: VPhoneMachineConsoleLog.defaultRoot(),
        )
        // Refused before the log is opened, created or truncated. A short-lived
        // reader (Launchpad's disk meter, Spotlight) is waited out, as a clone's
        // source is; a VM process or live control socket refuses at once.
        do { try VPhoneBundleActivity.requireStopped(bundle, waitingForReaders: VPhoneBundleActivity.readerWait) } catch let error as VPhoneBundleActivityError {
            throw fail("\(error)")
        }

        var arguments = ["vm", "launch", name]
        if let root = lib.libraryRoot { arguments += ["-l", root] }
        if headless { arguments.append("--headless") }
        if let apiListen { arguments += ["--api-listen", apiListen] }
        if let kernelDebugPort { arguments += ["--kernel-debug-port", String(kernelDebugPort)] }
        if let projectRoot { arguments += ["-p", projectRoot] }
        arguments += Array(repeating: "-v", count: verboseCount)

        let pid: pid_t
        do {
            try FileManager.default.createDirectory(
                at: log.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try Data().write(to: log)
            pid = try VPhoneDetachedProcess.spawn(
                executable: VPhoneResources.runningExecutable(),
                arguments: arguments,
                logFile: log,
                disclaim: false,
            )
        } catch {
            let reason = (error as? VPhoneDetachedProcess.SpawnError)?.description ?? "\(error.localizedDescription) (\(log.path))"
            throw fail("could not start `\(name)`: \(reason)")
        }
        print("pid \(pid)")
        print("log \(log.path)")
        fflush(stdout)

        var scanner = VPhoneConsolePanicScanner(url: log)
        var status: Int32?
        let socket = bundle.url.appendingPathComponent("vphone.sock").path
        let outcome = VPhoneGuestWait.run(
            budget: .seconds(timeoutSeconds),
            pollInterval: 1,
            ping: { VPhoneControlSocket.ping(socketPath: socket) },
            exited: {
                if status == nil { status = VPhoneDetachedProcess.exitStatus(pid: pid) }
                return status != nil
            },
            panicked: { scanner.hasPanic() },
            cancelled: { false },
            progress: { _ in },
        )
        let stop = "stop it with `vphone-cli vm stop \(name)`"
        switch outcome {
        case let .answered(seconds):
            print("vphoned answered after \(seconds)s")
        case .exited:
            let how = status.map(VPhoneDetachedProcess.describe(status:)) ?? "unknown"
            throw fail("`\(name)` stopped before vphoned answered (\(how))\nlog: \(log.path)\n\(Self.tail(of: log))")
        case .panicked:
            throw fail("`\(name)` had a kernel panic; it is still running (pid \(pid))\nlog: \(log.path)\n\(stop)")
        case .timedOut, .cancelled:
            throw fail("vphoned did not answer within \(timeoutSeconds)s; `\(name)` is still running (pid \(pid))\nlog: \(log.path)\n\(stop)")
        }
    }

    /// The last 20 lines, from the final 64 KiB of the log.
    private static func tail(of log: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
    }
}

// MARK: - vm stop

struct VPhoneVirtualMachineStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a running VM bundle",
        discussion: """
        Sends SIGINT to the machine's vphone-vm, waits, then sends SIGKILL to whatever of the \
        machine is left. Only processes that run a machine are ever signalled: vphone-vm and \
        Virtualization's VM service holding this machine's disk. Any other process that has the \
        disk open (Launchpad measuring it, Spotlight, a backup tool) is named, never signalled.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "Seconds to wait for graceful shutdown before SIGKILL") var timeout: Int = 20

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        // The holders lsof reports for this path decide what is signalled, so
        // it must be the bundle's own disk: a plain name inside the bundle and
        // a regular file, never a symbolic link to something shared like
        // /dev/null.
        let disk = try bundle.manifest.resolve(path: bundle.manifest.diskImage, in: bundle.url)
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: disk) else {
            print("\(name): not running")
            return
        }

        // Every process holding the disk now, by executable. Looked up again
        // before each signal, so a PID reused by another program meanwhile is
        // not taken for the VM.
        func holders() -> (machine: [VPhoneProcessHolder], others: [VPhoneProcessHolder]) {
            guard let r = try? VPhoneProcessRunner.runCapturing(
                URL(fileURLWithPath: "/usr/sbin/lsof"),
                ["-t", "--", disk.path],
            ) else { return ([], []) }
            return VPhoneProcessHolder.classify(VPhoneLsof.parsePIDs(r.stdout).map { VPhoneProcessHolder(pid: $0) })
        }

        // The disk is held by Virtualization's service, not by vphone-vm. A
        // SIGINT to the service ends the VM under vphone-vm, which then exits
        // with "the virtual machine stopped unexpectedly". vphone-vm quits on
        // SIGINT and the service follows it, so vphone-vm is the one asked.
        let virtualMachines = VPhoneGuestProcesses.virtualMachinePIDs(config: bundle.configURL)
        let initial = holders()
        guard !virtualMachines.isEmpty || !initial.machine.isEmpty else {
            if !initial.others.isEmpty {
                print("\(name): not running; its disk is open in \(VPhoneProcessHolder.describe(initial.others)), "
                    + "which does not run it and was not signalled")
            } else {
                print("\(name): not running")
            }
            return
        }

        // Without a vphone-vm of this config (one started some other way),
        // only the VM processes holding the disk are left to ask.
        let asked = virtualMachines.isEmpty ? initial.machine.map(\.pid) : virtualMachines
        print("\(name): sending SIGINT to \(asked.map(String.init).joined(separator: ", "))")
        for pid in asked {
            kill(pid, SIGINT)
        }

        func remaining() -> (machine: [Int32], others: [VPhoneProcessHolder]) {
            let held = holders()
            // Found again by its --config rather than by the PIDs found first,
            // which another process may have taken once vphone-vm exited.
            let alive = VPhoneGuestProcesses.virtualMachinePIDs(config: bundle.configURL)
            return (Array(Set(alive + held.machine.map(\.pid))).sorted(), held.others)
        }
        var waited = 0
        while waited < timeout, !remaining().machine.isEmpty {
            Thread.sleep(forTimeInterval: 1)
            waited += 1
        }
        let (survivors, others) = remaining()
        if !survivors.isEmpty {
            print("\(name): force-killing \(survivors.map(String.init).joined(separator: ", "))")
            for pid in survivors {
                kill(pid, SIGKILL)
            }
        }
        if !others.isEmpty {
            print("\(name): its disk is also open in \(VPhoneProcessHolder.describe(others)), "
                + "which does not run it and was not signalled")
        }
        print("\(name): stopped")
    }
}
