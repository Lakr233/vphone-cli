import Foundation
import Testing
@testable import VPhoneCoreKit

@Suite(.serialized)
struct VirtualMachineLaunchTests {
    // MARK: - Foreground run

    @Test("run returns the guest's exit status")
    func returnsStatus() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try guest.write(status: 7)
        #expect(try guest.launch().run() == 7)
        try guest.write(status: 0)
        #expect(try guest.launch().run() == 0)
    }

    @Test("run passes the boot arguments")
    func bootArguments() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        let options = VPhoneVirtualMachineLaunch.Options(headless: true, apiListen: "127.0.0.1:8765", kernelDebugPort: 6001)
        _ = try guest.launch(options: options).run()
        let expected = VPhoneBootCommand(
            config: guest.bundle.configURL,
            dfu: false,
            headless: true,
            apiListen: "127.0.0.1:8765",
            kernelDebugPort: 6001,
        ).bootArguments
        #expect(guest.recordedArguments == expected)
        #expect(!expected.isEmpty)
    }

    @Test("restoredCustomisedSystem removes a staged vphoned and stages nothing")
    func restoredRemoves() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try Data("old".utf8).write(to: guest.stagedVphoned)
        _ = try guest.launch(restoredCustomisedSystem: true).run()
        #expect(!FileManager.default.fileExists(atPath: guest.stagedVphoned.path))
    }

    @Test("without restoredCustomisedSystem vphoned is staged")
    func stagesVphoned() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        #expect(!FileManager.default.fileExists(atPath: guest.stagedVphoned.path))
        _ = try guest.launch().run()
        #expect(try Data(contentsOf: guest.stagedVphoned) == guest.vphonedContents)
    }

    @Test("dfu neither stages nor removes")
    func dfuLeavesVphoned() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        _ = try guest.launch(options: .init(dfu: true)).run()
        #expect(!FileManager.default.fileExists(atPath: guest.stagedVphoned.path))
        try Data("old".utf8).write(to: guest.stagedVphoned)
        _ = try guest.launch(options: .init(dfu: true), restoredCustomisedSystem: true).run()
        #expect(try Data(contentsOf: guest.stagedVphoned) == Data("old".utf8))
    }

    @Test("trace receives the spawning line only when given")
    func trace() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        var lines: [String] = []
        _ = try guest.launch().run(trace: { lines.append($0) })
        let args = VPhoneBootCommand(config: guest.bundle.configURL).bootArguments
        #expect(lines == ["[trace] spawning: \(guest.executable.path) \(args.joined(separator: " "))"])
        lines = []
        _ = try guest.launch().run()
        #expect(lines.isEmpty)
    }

    // MARK: - Shader cache warning

    /// Runs `body` with fd 2 redirected to a temp file and returns what was written.
    private func captureStderr(_ body: () throws -> Void) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vpck-stderr-\(UUID().uuidString)")
        let fd = open(file.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = dup(2)
        fflush(stderr)
        dup2(fd, 2)
        close(fd)
        var failure: Error?
        do { try body() } catch { failure = error }
        fflush(stderr)
        dup2(saved, 2)
        close(saved)
        if let failure { throw failure }
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("a failing shader-cache checkpoint warns on stderr and keeps the status")
    func shaderCacheFailureWarns() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try guest.write(status: 5)
        // A ShaderCache that is a file makes the checkpoint throw.
        try Data("x".utf8).write(to: guest.bundle.url.appendingPathComponent("ShaderCache"))
        var status: Int32 = -1
        let err = try captureStderr { status = try guest.launch().run() }
        #expect(status == 5)
        #expect(err.split(separator: "\n").contains { $0.hasPrefix("warning: could not save shader cache: ") })
    }

    @Test("a succeeding shader-cache checkpoint prints no warning")
    func shaderCacheSuccessIsSilent() throws {
        let guest = try FakeGuestVM()
        defer { guest.cleanUp() }
        try guest.write(status: 3)
        var status: Int32 = -1
        let err = try captureStderr { status = try guest.launch().run() }
        #expect(status == 3)
        #expect(!err.contains("warning:"))
    }
}
