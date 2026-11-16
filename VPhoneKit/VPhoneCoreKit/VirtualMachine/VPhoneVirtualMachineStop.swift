import Darwin
import Foundation

// MARK: - VPhoneVirtualMachineStop

/// Stops a VM bundle: SIGINT to the processes that run the machine, a wait,
/// then SIGKILL to what is left. Only processes that run a machine
/// (`vphone-vm`, Virtualization's VM service for this disk) are signalled; any
/// other process holding the disk is named and left alone.
public enum VPhoneVirtualMachineStop {
    public enum Outcome: Equatable, Sendable {
        case notRunning
        case stopped
    }

    /// The process table, signals and clock, so a test needs no real VM and no
    /// real waiting.
    public struct Processes: Sendable {
        public var holders: @Sendable (_ disk: URL) -> (machine: [VPhoneProcessHolder], others: [VPhoneProcessHolder])
        public var virtualMachinePIDs: @Sendable (_ config: URL) -> [Int32]
        public var signal: @Sendable (_ pid: Int32, _ signal: Int32) -> Void
        public var sleep: @Sendable (_ seconds: TimeInterval) -> Void

        public init(
            holders: @escaping @Sendable (URL) -> (machine: [VPhoneProcessHolder], others: [VPhoneProcessHolder]),
            virtualMachinePIDs: @escaping @Sendable (URL) -> [Int32],
            signal: @escaping @Sendable (Int32, Int32) -> Void,
            sleep: @escaping @Sendable (TimeInterval) -> Void,
        ) {
            self.holders = holders
            self.virtualMachinePIDs = virtualMachinePIDs
            self.signal = signal
            self.sleep = sleep
        }

        public static let live = Processes(
            holders: { disk in
                guard let r = try? VPhoneProcessRunner.runCapturing(
                    URL(fileURLWithPath: "/usr/sbin/lsof"),
                    ["-t", "--", disk.path],
                ) else { return ([], []) }
                return VPhoneProcessHolder.classify(VPhoneLsof.parsePIDs(r.stdout).map { VPhoneProcessHolder(pid: $0) })
            },
            virtualMachinePIDs: { VPhoneGuestProcesses.virtualMachinePIDs(config: $0) },
            signal: { kill($0, $1) },
            sleep: { Thread.sleep(forTimeInterval: $0) },
        )
    }

    /// Every line the `vm stop` command prints goes to `report`.
    @discardableResult
    public static func stop(
        bundle: VPhoneBundle,
        timeout: Int = 20,
        processes: Processes = .live,
        report: (String) -> Void,
    ) throws -> Outcome {
        let name = bundle.name
        // The holders lsof reports for this path decide what is signalled, so
        // it must be the bundle's own disk: a plain name inside the bundle and
        // a regular file, never a symbolic link to something shared like
        // /dev/null.
        let disk = try bundle.manifest.resolve(path: bundle.manifest.diskImage, in: bundle.url)
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: disk) else {
            report("\(name): not running")
            return .notRunning
        }

        // Every process holding the disk now, by executable. Looked up again
        // before each signal, so a PID reused by another program meanwhile is
        // not taken for the VM.
        // The disk is held by Virtualization's service, not by vphone-vm. A
        // SIGINT to the service ends the VM under vphone-vm, which then exits
        // with "the virtual machine stopped unexpectedly". vphone-vm quits on
        // SIGINT and the service follows it, so vphone-vm is the one asked.
        let virtualMachines = processes.virtualMachinePIDs(bundle.configURL)
        let initial = processes.holders(disk)
        guard !virtualMachines.isEmpty || !initial.machine.isEmpty else {
            if !initial.others.isEmpty {
                report("\(name): not running; its disk is open in \(VPhoneProcessHolder.describe(initial.others)), "
                    + "which does not run it and was not signalled")
            } else {
                report("\(name): not running")
            }
            return .notRunning
        }

        // Without a vphone-vm of this config (one started some other way),
        // only the VM processes holding the disk are left to ask.
        let asked = virtualMachines.isEmpty ? initial.machine.map(\.pid) : virtualMachines
        report("\(name): sending SIGINT to \(asked.map(String.init).joined(separator: ", "))")
        for pid in asked {
            processes.signal(pid, SIGINT)
        }

        func remaining() -> (machine: [Int32], others: [VPhoneProcessHolder]) {
            let held = processes.holders(disk)
            // Found again by its --config rather than by the PIDs found first,
            // which another process may have taken once vphone-vm exited.
            let alive = processes.virtualMachinePIDs(bundle.configURL)
            return (Array(Set(alive + held.machine.map(\.pid))).sorted(), held.others)
        }
        var waited = 0
        while waited < timeout, !remaining().machine.isEmpty {
            processes.sleep(1)
            waited += 1
        }
        let (survivors, others) = remaining()
        if !survivors.isEmpty {
            report("\(name): force-killing \(survivors.map(String.init).joined(separator: ", "))")
            for pid in survivors {
                processes.signal(pid, SIGKILL)
            }
        }
        if !others.isEmpty {
            report("\(name): its disk is also open in \(VPhoneProcessHolder.describe(others)), "
                + "which does not run it and was not signalled")
        }
        report("\(name): stopped")
        return .stopped
    }
}
