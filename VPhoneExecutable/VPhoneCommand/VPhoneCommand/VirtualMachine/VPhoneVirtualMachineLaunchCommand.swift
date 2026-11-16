import ArgumentParser
import Foundation
import VPhoneCommandKit
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
        let launch = VPhoneVirtualMachineLaunch(
            bundle: bundle,
            planner: launcher,
            layout: layout,
            options: .init(dfu: dfu, headless: headless, apiListen: apiListen, kernelDebugPort: kernelDebugPort),
            restoredCustomisedSystem: !dfu
                && VPhoneCustomFirmwareInstaller.restoredCustomisedSystem(VPhonePatchPresetStore.plan(forVM: bundle.url)),
        )
        // `vm launch` always streams the guest serial console (inherits our
        // stdio); it is intentionally not gated on verbosity.
        throw try ExitCode(launch.run(trace: v.tracesInternals ? { print($0) } : nil))
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
        _ = try VPhoneVirtualMachineStop.stop(bundle: bundle, timeout: timeout, report: { print($0) })
    }
}
