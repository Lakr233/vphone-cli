import Foundation
import Testing
@testable import VPhoneCoreKit

struct LaunchLayoutTests {
    @Test func `delegates to resources`() {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/proj"))
        let layout = VPhoneLaunchLayout(resources: resources)
        #expect(layout.vphoned.path == resources.vphoned.path)
    }

    @Test func `parses lsof PI ds`() {
        #expect(VPhoneLsof.parsePIDs("123\n456\n123\n\n  \nnotapid\n789\n") == [123, 456, 789])
        #expect(VPhoneLsof.parsePIDs("") == [])
    }

    // MARK: - Disk holders

    private static let service = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
        + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    /// `ProcessHolderKinds.json`, beside this file: the cases Launchpad's
    /// copy of the rule (`VPhoneLaunchpadDiskHolder.runsMachine`) is tested
    /// against too, so neither copy can change alone.
    struct HolderKindCase: Decodable {
        let path: String?
        let kind: String
    }

    static func holderKindCases() throws -> [HolderKindCase] {
        struct Table: Decodable {
            let cases: [HolderKindCase]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ProcessHolderKinds.json")
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: url)).cases
    }

    @Test func `only vphone-vm and Virtualization's VM service count as running a machine`() throws {
        let cases = try Self.holderKindCases()
        #expect(cases.count >= 10)
        for entry in cases {
            let expected: VPhoneProcessHolder.Kind? = switch entry.kind {
            case "virtualMachine": .virtualMachine
            case "virtualizationService": .virtualizationService
            case "other": .other
            default: nil
            }
            #expect(expected != nil, "unknown kind \(entry.kind)")
            #expect(VPhoneProcessHolder.kind(executablePath: entry.path) == expected, "\(entry.path ?? "nil")")
        }
    }

    @Test func `holders split into the machine's processes and the rest, in PID order`() {
        let holders = [
            VPhoneProcessHolder(pid: 900, executablePath: "/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad"),
            VPhoneProcessHolder(pid: 412, executablePath: Self.service),
            VPhoneProcessHolder(pid: 77, executablePath: nil),
            VPhoneProcessHolder(pid: 410, executablePath: "/opt/VPhone.bundle/Contents/MacOS/vphone-vm"),
        ]
        let (machine, others) = VPhoneProcessHolder.classify(holders)
        #expect(machine.map(\.pid) == [410, 412])
        #expect(others.map(\.pid) == [77, 900])
        #expect(VPhoneProcessHolder.describe(others) == "77 unknown, 900 vphone-launchpad")
        #expect(VPhoneProcessHolder.classify([]).machine.isEmpty)
    }

    @Test func `a disk refusal says whether the holder runs the machine`() throws {
        #expect(VPhoneProcessHolder.diskRefusal([], rerun: "run cfw install again") == nil)
        let meter = VPhoneProcessHolder(pid: 900, executablePath: "/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad")
        let reader = try #require(VPhoneProcessHolder.diskRefusal([meter], rerun: "run cfw install again"))
        #expect(reader.contains("900 vphone-launchpad"))
        #expect(reader.contains("does not run the VM"))
        #expect(!reader.contains("is running"))
        #expect(reader.hasSuffix("then run cfw install again."))
        let vm = VPhoneProcessHolder(pid: 412, executablePath: Self.service)
        let running = try #require(VPhoneProcessHolder.diskRefusal([meter, vm], rerun: "run cfw install again"))
        #expect(running.hasPrefix("The VM is running (process 412 com.apple.Virtualization.VirtualMachine, 900 vphone-launchpad)."))
    }

    @Test func `a running refusal names each holder's executable`() {
        let meter = VPhoneProcessHolder(pid: 900, executablePath: "/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad")
        let vm = VPhoneProcessHolder(pid: 410, executablePath: "/opt/VPhone.bundle/Contents/MacOS/vphone-vm")
        let reader = VPhoneBundleActivityError.running(name: "lab", holders: [meter]).description
        #expect(reader.hasPrefix("VM 'lab' is in use: its disk or state files are open in process 900 vphone-launchpad, which does not run it."))
        let running = VPhoneBundleActivityError.running(name: "lab", holders: [meter, vm]).description
        #expect(running == "VM 'lab' is running (process 410 vphone-vm, 900 vphone-launchpad). Stop it, then try again.")
        // A live control socket with no visible holder (a VM under sudo).
        #expect(VPhoneBundleActivityError.running(name: "lab", holders: []).description == "VM 'lab' is running. Stop it, then try again.")
        // The PID form looks the executable up: this test process is no VM.
        let me = VPhoneBundleActivityError.running(name: "lab", pids: [getpid()])
        #expect(me == .running(name: "lab", holders: [VPhoneProcessHolder(pid: getpid())]))
        #expect(VPhoneProcessHolder(pid: getpid()).executablePath != nil)
        #expect(VPhoneProcessHolder(pid: getpid()).kind == .other)
    }

    // MARK: - Guest processes

    /// A KERN_PROCARGS2 buffer as the kernel lays it out.
    private func processArguments(_ executable: String, _ arguments: [String], padding: Int = 3) -> [UInt8] {
        var buffer = withUnsafeBytes(of: Int32(arguments.count).littleEndian, Array.init)
        buffer += Array(executable.utf8) + [UInt8](repeating: 0, count: padding)
        for argument in arguments {
            buffer += Array(argument.utf8) + [0]
        }
        // The environment follows the arguments.
        buffer += Array("HOME=/Users/test".utf8) + [0]
        return buffer
    }

    @Test func `parses process arguments`() {
        let path = "/Library/Bundles/VPhone.bundle/Contents/MacOS/vphone-vm"
        let buffer = processArguments(path, [path, "--config", "/vms/a/config.plist"])
        #expect(VPhoneGuestProcesses.parseProcessArguments(buffer) == [path, "--config", "/vms/a/config.plist"])
        #expect(VPhoneGuestProcesses.parseProcessArguments([]) == nil)
        #expect(VPhoneGuestProcesses.parseProcessArguments(Array(buffer.prefix(12))) == nil)
    }

    @Test func `matches only the vphone-vm of one machine`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let machine = root.appendingPathComponent("machines/a")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = machine.appendingPathComponent("config.plist")
        try Data().write(to: config)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("machines"))
        let target = config.resolvingSymlinksInPath().standardizedFileURL.path
        let vm = "/B/VPhone.bundle/Contents/MacOS/vphone-vm"

        #expect(VPhoneGuestProcesses.runsMachine([vm, "--config", config.path], configPath: target))
        #expect(VPhoneGuestProcesses.runsMachine([vm, "--headless", "--config=\(config.path)"], configPath: target))
        // Another spelling of the same file.
        #expect(VPhoneGuestProcesses.runsMachine([vm, "--config", link.path + "/a/config.plist"], configPath: target))
        #expect(VPhoneGuestProcesses.runsMachine([vm, "--config", machine.path + "/../a/config.plist"], configPath: target))
        // Another machine, another program, or no --config.
        #expect(!VPhoneGuestProcesses.runsMachine([vm, "--config", root.path + "/machines/b/config.plist"], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine(["/usr/bin/vim", "--config", config.path], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine([vm, "--dfu"], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine([vm, "--config"], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine([], configPath: target))
    }

    @Test func `finds a running vphone-vm by its config`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A stand-in that lives long enough to be found under the right name.
        let program = root.appendingPathComponent("vphone-vm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: program)
        let config = root.appendingPathComponent("config.plist")
        let other = root.appendingPathComponent("other.plist")
        let process = Process()
        process.executableURL = program
        // cat reads "-" first and blocks on a pipe that is never written to.
        // Not yes: on macOS 26 it writes a newline over the NUL that ends its
        // first argument, which runs "--config" into the path.
        process.arguments = ["-", "--config", config.path]
        process.standardInput = Pipe()
        try process.run()
        defer { process.terminate() }

        // The stand-in takes a moment to become observable, and under parallel
        // test load that moment exceeds any fixed delay. Poll on a bounded
        // deadline until it appears instead of sleeping a fixed interval, so
        // the outcome depends on observation, not wall-clock timing.
        let deadline = Date().addingTimeInterval(5)
        var found = VPhoneGuestProcesses.virtualMachinePIDs(config: config)
        while found != [process.processIdentifier], Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            found = VPhoneGuestProcesses.virtualMachinePIDs(config: config)
        }

        #expect(found == [process.processIdentifier])
        #expect(VPhoneGuestProcesses.virtualMachinePIDs(config: other).isEmpty)
    }

    @Test func `stage vphoned copies when source exists`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(".build/vphoned.signed"))

        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        let layout = VPhoneLaunchLayout(projectRoot: root)
        #expect(try layout.stageVphoned(into: bundle) == true)
        #expect(FileManager.default.fileExists(atPath: bundleDir.appendingPathComponent(".vphoned.signed").path))
        // Second call is a no-op (already identical).
        #expect(try layout.stageVphoned(into: bundle) == false)
    }

    @Test func `stage vphoned picks the tvOS daemon for Apple TV and HomePod guests`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let guest = root.appendingPathComponent("guest-resources")
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: guest.appendingPathComponent("vphoned"))
        try Data([2]).write(to: guest.appendingPathComponent("vphoned-tvos"))
        let resources = VPhoneResources(base: root)
        #expect(resources.vphoned.lastPathComponent == "vphoned")
        #expect(resources.vphoned(for: .iPad).lastPathComponent == "vphoned")
        #expect(resources.vphoned(for: .appleTV).lastPathComponent == "vphoned-tvos")
        #expect(resources.vphoned(for: .homePod).lastPathComponent == "vphoned-tvos")

        let base = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        for (device, expected) in [(VPhoneGuestDevice.appleTV5_3, Data([2])), (.audioAccessory5_1, Data([2])), (.iPhone17_3, Data([1]))] {
            let bundleDir = root.appendingPathComponent(device.productType)
            try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
            let bundle = VPhoneBundle(url: bundleDir, manifest: base.updating(guestDevice: device))
            #expect(try VPhoneLaunchLayout(resources: resources).stageVphoned(into: bundle))
            #expect(try Data(contentsOf: bundleDir.appendingPathComponent(".vphoned.signed")) == expected)
        }
    }

    @Test func `stage vphoned fails when source absent`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No .build/vphoned.signed created → source absent.
        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        #expect(throws: VPhoneGuestBinaries.Error.self) {
            try VPhoneLaunchLayout(projectRoot: root).stageVphoned(into: bundle)
        }
        #expect(!FileManager.default.fileExists(
            atPath: bundleDir.appendingPathComponent(".vphoned.signed").path,
        ))
    }

    @Test func `stage vphoned overwrites stale destination`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([9, 9, 9, 9]).write(to: root.appendingPathComponent(".build/vphoned.signed"))

        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        // Pre-populate dst with DIFFERENT bytes.
        try Data([1, 1]).write(to: bundleDir.appendingPathComponent(".vphoned.signed"))
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        #expect(try VPhoneLaunchLayout(projectRoot: root).stageVphoned(into: bundle) == true)
        let staged = try Data(contentsOf: bundleDir.appendingPathComponent(".vphoned.signed"))
        #expect(staged == Data([9, 9, 9, 9]))
    }
}
