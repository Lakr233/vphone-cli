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

    func validate() throws {
        if dfu, apiListen != nil {
            throw ValidationError("`--api-listen` is unavailable with `--dfu`.")
        }
    }

    func run() throws {
        let v = VPhoneVerbosity(count: verboseCount)
        if name == nil {
            let scan = try lib.library.scan()
            if scan.bundles.isEmpty, let incompatible = scan.skipped.first {
                throw ValidationError("VM '\(incompatible.name)' cannot launch: \(incompatible.reason)")
            }
        }
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
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
            _ = try layout.stageVphoned(into: bundle)
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
        throw try ExitCode(launcher.run(args, cwd: bundle.url))
    }
}

// MARK: - vm stop

struct VPhoneVirtualMachineStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a running VM bundle",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "Seconds to wait for graceful shutdown before SIGKILL") var timeout: Int = 20

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let disk = try bundle.manifest.resolve(path: bundle.manifest.diskImage, in: bundle.url)

        func runningPIDs() -> [Int32] {
            guard let r = try? VPhoneProcessRunner.runCapturing(
                URL(fileURLWithPath: "/usr/sbin/lsof"),
                ["-t", "--", disk.path],
            ) else { return [] }
            return VPhoneLsof.parsePIDs(r.stdout)
        }

        let pids = runningPIDs()
        guard !pids.isEmpty else { print("\(name): not running"); return }

        print("\(name): sending SIGINT to \(pids.map(String.init).joined(separator: ", "))")
        for pid in pids {
            kill(pid, SIGINT)
        }

        var waited = 0
        while waited < timeout, !runningPIDs().isEmpty {
            Thread.sleep(forTimeInterval: 1)
            waited += 1
        }
        let survivors = runningPIDs()
        if !survivors.isEmpty {
            print("\(name): force-killing \(survivors.map(String.init).joined(separator: ", "))")
            for pid in survivors {
                kill(pid, SIGKILL)
            }
        }
        print("\(name): stopped")
    }
}
