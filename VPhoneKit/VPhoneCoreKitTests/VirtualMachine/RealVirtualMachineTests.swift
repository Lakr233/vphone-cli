import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

/// Runs foreground and detached launch, stop and delete against a real
/// `vphone-vm` in DFU mode (no restore, so no Apple service is contacted).
///
/// Opt-in: set `VPHONE_REAL_VM_TEST=<library root>:vpck-<name>` to a disposable
/// bundle made with `vm new`. The test deletes that bundle at its end.
/// `VPHONE_REAL_VM_APP` names the `VPhone.bundle` that holds `vphone-vm`
/// (default: the workspace build in `.build/XcodeBundle`).
struct RealVirtualMachineTests {
    static let variable = "VPHONE_REAL_VM_TEST"

    struct Target: Equatable {
        let libraryRoot: String
        let name: String
    }

    struct FormatError: Error, CustomStringConvertible {
        var description: String { "\(RealVirtualMachineTests.variable) must be <library root>:vpck-<name>" }
    }

    /// `nil` when unset; throws `FormatError` for any value that is not
    /// `<library root>:vpck-<name>`.
    static func parse(_ value: String?) throws -> Target? {
        guard let value else { return nil }
        guard let colon = value.lastIndex(of: ":") else { throw FormatError() }
        let root = String(value[..<colon])
        let name = String(value[value.index(after: colon)...])
        guard !root.isEmpty, name.hasPrefix("vpck-"), name.count > "vpck-".count else { throw FormatError() }
        return Target(libraryRoot: root, name: name)
    }

    @Test("the target variable is parsed as <root>:vpck-<name>")
    func parsing() throws {
        #expect(try Self.parse(nil) == nil)
        #expect(try Self.parse("/tmp/l:vpck-a") == Target(libraryRoot: "/tmp/l", name: "vpck-a"))
        for bad in ["/tmp/x:prod", "/tmp/x:production", "nocolon", ":vpck-a", "/tmp/x:vpck-", ""] {
            #expect(throws: FormatError.self) { try Self.parse(bad) }
        }
        #expect(FormatError().description == "VPHONE_REAL_VM_TEST must be <library root>:vpck-<name>")
    }

    private static func pgrep(_ name: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "vphone-vm.*\(name)"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func waitUntil(_ seconds: Double, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return try condition()
    }

    @Test(
        "foreground run, detached start, stop and delete against a real DFU guest",
        .enabled(if: ProcessInfo.processInfo.environment[RealVirtualMachineTests.variable] != nil),
    )
    func realLifecycle() throws {
        let target = try #require(try Self.parse(ProcessInfo.processInfo.environment[Self.variable]))
        let library = VPhoneLibrary(root: URL(fileURLWithPath: target.libraryRoot))
        let bundle = try library.bundle(named: target.name)

        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = ProcessInfo.processInfo.environment["VPHONE_REAL_VM_APP"].map { URL(fileURLWithPath: $0) }
            ?? repo.appendingPathComponent(".build/XcodeBundle/Build/Products/Debug/VPhone.bundle")
        let planner = try VPhoneGuestLaunchPlanner(vphoneVM: app.appendingPathComponent("Contents/MacOS/vphone-vm"))
        let layout = VPhoneLaunchLayout(resources: VPhoneResources(base: app.appendingPathComponent("Contents/Resources")))
        let launch = VPhoneVirtualMachineLaunch(
            bundle: bundle,
            planner: planner,
            layout: layout,
            options: .init(dfu: true, headless: true),
            restoredCustomisedSystem: false,
        )
        try #require(try !Self.pgrep(target.name), "\(target.name) is already running")

        // Foreground run: blocks until the guest exits, so it runs on a thread
        // while this one waits for it, refuses a delete, and stops it.
        final class Box: @unchecked Sendable { var status: Result<Int32, any Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.status = Result { try launch.run() }
            done.signal()
        }
        // Up once the control socket exists: before that the guest has not
        // opened its disk, and the bundle does not yet count as running.
        let socket = bundle.url.appendingPathComponent("vphone.sock").path
        let started = Self.waitUntil(60) {
            !VPhoneGuestProcesses.virtualMachinePIDs(config: bundle.configURL).isEmpty
                && FileManager.default.fileExists(atPath: socket)
        }
        try #require(started)
        defer { _ = try? VPhoneVirtualMachineStop.stop(bundle: bundle, timeout: 5, report: { _ in }) }

        #expect(throws: VPhoneBundleActivityError.self) {
            try VPhoneVirtualMachineDelete.delete(named: target.name, in: library, refuseWhenRunning: true)
        }
        #expect(FileManager.default.fileExists(atPath: bundle.url.path))

        var lines: [String] = []
        let outcome = try VPhoneVirtualMachineStop.stop(bundle: bundle, timeout: 20) { lines.append($0) }
        #expect(outcome == .stopped)
        #expect(lines.last == "\(target.name): stopped")
        #expect(done.wait(timeout: .now() + 30) == .success)
        if case let .failure(error)? = box.status { throw error }
        #expect(try !Self.pgrep(target.name))

        // Detached start: a DFU guest has no vphoned, so ready is optional.
        // Either way the process is gone afterwards.
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vpck-real-\(UUID().uuidString.prefix(8)).log")
        defer { try? FileManager.default.removeItem(at: log) }
        do {
            let detached = try launch.startDetached(logURL: log, readyTimeout: 20)
            #expect(detached.logURL == log)
            #expect(throws: VPhoneBundleActivityError.self) {
                try VPhoneVirtualMachineDelete.delete(named: target.name, in: library, refuseWhenRunning: true)
            }
            _ = try VPhoneVirtualMachineStop.stop(bundle: bundle, timeout: 20, report: { _ in })
            var status: Int32 = 0
            waitpid(detached.pid, &status, 0)
        } catch let error as VPhoneVirtualMachineLaunchError {
            switch error {
            case .notReady, .exitedBeforeReady:
                #expect(error.description.isEmpty == false)
            default:
                throw error
            }
        }
        #expect(try Self.waitUntil(30) { try !Self.pgrep(target.name) })

        // Virtualization's VM service outlives a SIGKILLed vphone-vm briefly.
        #expect(Self.waitUntil(30) { (try? VPhoneBundleActivity.requireStopped(bundle)) != nil })

        // Delete after it stopped.
        try VPhoneVirtualMachineDelete.delete(named: target.name, in: library, refuseWhenRunning: true)
        #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
    }
}
