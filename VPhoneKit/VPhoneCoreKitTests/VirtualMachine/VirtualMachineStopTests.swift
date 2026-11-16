import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct VirtualMachineStopTests {
    /// A process table the test scripts: `machine` are vphone-vm PIDs,
    /// `held` the disk holders, `exitAfterSleeps` when the machine goes away.
    final class Fake: @unchecked Sendable {
        var machine: [Int32] = []
        var held: [VPhoneProcessHolder] = []
        var exitAfterSleeps: Int?
        var sleeps = 0
        var signals: [(Int32, Int32)] = []
        var lines: [String] = []
        /// Run after each sleep, before the exit check.
        var onSleep: (() -> Void)?

        var processes: VPhoneVirtualMachineStop.Processes {
            .init(
                holders: { _ in VPhoneProcessHolder.classify(self.held) },
                virtualMachinePIDs: { _ in self.machine },
                signal: { self.signals.append(($0, $1)) },
                sleep: { _ in
                    self.sleeps += 1
                    self.onSleep?()
                    if let n = self.exitAfterSleeps, self.sleeps >= n {
                        self.machine = []
                        self.held.removeAll { $0.runsMachine }
                    }
                },
            )
        }

        func stop(_ bundle: VPhoneBundle, timeout: Int = 3) throws -> VPhoneVirtualMachineStop.Outcome {
            try VPhoneVirtualMachineStop.stop(bundle: bundle, timeout: timeout, processes: processes) { lines.append($0) }
        }
    }

    private func vm(_ pid: Int32) -> VPhoneProcessHolder {
        .init(pid: pid, executablePath: "/x/vphone-vm")
    }

    private func other(_ pid: Int32) -> VPhoneProcessHolder {
        .init(pid: pid, executablePath: "/usr/libexec/mds_stores")
    }

    private func withBundle(_ body: (VPhoneBundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = root.appendingPathComponent("rom.bin")
        try Data([1, 2, 3]).write(to: rom)
        let lib = VPhoneLibrary(root: root.appendingPathComponent("lib"))
        try FileManager.default.createDirectory(at: lib.root, withIntermediateDirectories: true)
        let bundle = try VPhoneBundleOperations.create(
            .init(name: "stopvm", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: lib,
        )
        try body(bundle)
    }

    @Test("A missing disk is not running")
    func missingDisk() throws {
        try withBundle { bundle in
            try FileManager.default.removeItem(at: bundle.url.appendingPathComponent(bundle.manifest.diskImage))
            let fake = Fake()
            fake.machine = [10]
            try #expect(fake.stop(bundle) == .notRunning)
            #expect(fake.lines == ["stopvm: not running"])
            #expect(fake.signals.isEmpty)
        }
    }

    @Test("A symbolic-link disk throws")
    func symlinkDisk() throws {
        try withBundle { bundle in
            let disk = bundle.url.appendingPathComponent(bundle.manifest.diskImage)
            try FileManager.default.removeItem(at: disk)
            try FileManager.default.createSymbolicLink(atPath: disk.path, withDestinationPath: "/dev/null")
            let fake = Fake()
            #expect(throws: (any Error).self) { try fake.stop(bundle) }
            #expect(fake.signals.isEmpty)
        }
    }

    @Test("No VM and no holders is not running")
    func nothingRunning() throws {
        try withBundle { bundle in
            let fake = Fake()
            try #expect(fake.stop(bundle) == .notRunning)
            #expect(fake.lines == ["stopvm: not running"])
            #expect(fake.signals.isEmpty)
        }
    }

    @Test("A disk held only by a non-machine process is named and not signalled")
    func onlyOthers() throws {
        try withBundle { bundle in
            let fake = Fake()
            fake.held = [other(77)]
            try #expect(fake.stop(bundle) == .notRunning)
            #expect(fake.lines == [
                "stopvm: not running; its disk is open in 77 mds_stores, which does not run it and was not signalled",
            ])
            #expect(fake.signals.isEmpty)
        }
    }

    @Test("A VM that exits after the first sleep gets only SIGINT")
    func gracefulStop() throws {
        try withBundle { bundle in
            let fake = Fake()
            fake.machine = [10]
            fake.held = [vm(10)]
            fake.exitAfterSleeps = 1
            try #expect(fake.stop(bundle) == .stopped)
            #expect(fake.signals.map(\.0) == [10])
            #expect(fake.signals.map(\.1) == [SIGINT])
            #expect(fake.sleeps == 1)
            #expect(fake.lines == ["stopvm: sending SIGINT to 10", "stopvm: stopped"])
        }
    }

    @Test("A VM that survives gets SIGINT, timeout sleeps, then SIGKILL to the survivors")
    func forcedStop() throws {
        try withBundle { bundle in
            let fake = Fake()
            fake.machine = [10, 11]
            fake.held = [vm(10), other(77)]
            try #expect(fake.stop(bundle, timeout: 3) == .stopped)
            #expect(fake.sleeps == 3)
            #expect(fake.signals.map(\.1) == [SIGINT, SIGINT, SIGKILL, SIGKILL])
            #expect(fake.signals.map(\.0) == [10, 11, 10, 11])
            #expect(fake.lines == [
                "stopvm: sending SIGINT to 10, 11",
                "stopvm: force-killing 10, 11",
                "stopvm: its disk is also open in 77 mds_stores, which does not run it and was not signalled",
                "stopvm: stopped",
            ])
        }
    }

    @Test("With no vphone-vm of this config the machine holders are asked")
    func holderOnly() throws {
        try withBundle { bundle in
            let service = VPhoneProcessHolder(
                pid: 55,
                executablePath: "/System/Library/Frameworks/Virtualization.framework/x/com.apple.Virtualization.VirtualMachine",
            )
            let fake = Fake()
            fake.held = [service]
            fake.exitAfterSleeps = 1
            try #expect(fake.stop(bundle) == .stopped)
            #expect(fake.signals.map(\.0) == [55])
            #expect(fake.lines.first == "stopvm: sending SIGINT to 55")
        }
    }

    @Test("A PID that disappears before the SIGKILL is not signalled")
    func vanishesBeforeKill() throws {
        try withBundle { bundle in
            let fake = Fake()
            fake.machine = [10, 11]
            fake.held = [vm(10), vm(11)]
            // 11 is gone by the last wait; 10 is still there.
            fake.onSleep = { if fake.sleeps == 3 { fake.machine = [10]; fake.held = [fake.held[0]] } }
            try #expect(fake.stop(bundle, timeout: 3) == .stopped)
            let kills = fake.signals.filter { $0.1 == SIGKILL }.map(\.0)
            #expect(kills == [10])
            #expect(fake.lines.contains("stopvm: force-killing 10"))
        }
    }

    @Test("Without a timeout the stop waits 20 seconds before SIGKILL")
    func defaultTimeoutIsTwentySeconds() throws {
        try withBundle { bundle in
            let fake = Fake()
            fake.machine = [10]
            fake.held = [vm(10)]
            // The machine never exits; every sleep is instant.
            try #expect(VPhoneVirtualMachineStop.stop(bundle: bundle, processes: fake.processes) { fake.lines.append($0) } == .stopped)
            #expect(fake.sleeps == 20)
            #expect(fake.signals.map(\.1) == [SIGINT, SIGKILL])
        }
    }

    @Test("A machine that exits at the 19th wait is never killed under the default timeout")
    func defaultTimeoutNotExceeded() throws {
        try withBundle { bundle in
            let fake = Fake()
            fake.machine = [10]
            fake.held = [vm(10)]
            fake.exitAfterSleeps = 19
            try #expect(VPhoneVirtualMachineStop.stop(bundle: bundle, processes: fake.processes) { fake.lines.append($0) } == .stopped)
            #expect(fake.sleeps == 19)
            #expect(fake.signals.map(\.1) == [SIGINT])
        }
    }
}
