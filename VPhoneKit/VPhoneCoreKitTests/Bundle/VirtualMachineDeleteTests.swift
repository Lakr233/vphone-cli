import Foundation
import Testing
@testable import VPhoneCoreKit

struct VirtualMachineDeleteTests {
    private struct Fixture {
        let root: URL
        let library: VPhoneLibrary
        let rom: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func makeMachine(_ name: String) throws -> VPhoneBundle {
            try VPhoneBundleOperations.create(
                .init(name: name, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: rom),
                in: library,
            )
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        return Fixture(root: root, library: VPhoneLibrary(root: root.appendingPathComponent("machines")), rom: rom)
    }

    private func record() -> VPhoneMachineTemplateRecord {
        VPhoneMachineTemplateRecord(
            key: MachineTemplateKeyTests.key(),
            created: Date(timeIntervalSince1970: 1_800_000_000),
            builtWithBundleVersion: "2.8.0",
            sourceMachine: "src",
            steps: VPhoneMachineTemplateSteps(),
        )
    }

    @Test("delete removes the bundle directory")
    func removesDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bundle = try fixture.makeMachine("vm")
        let result = try VPhoneVirtualMachineDelete.delete(named: "vm", in: fixture.library)
        #expect(!fixture.exists(bundle.url))
        #expect(result.name == "vm")
        #expect(result.unusedTemplate == nil)
        #expect(result.templateNote == nil)
    }

    @Test("an unknown name throws the library's own error")
    func unknownName() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeMachine("vm")
        let expected = try #require(
            { () -> String? in
                do { _ = try fixture.library.bundle(named: "nosuch"); return nil } catch { return "\(error)" }
            }(),
        )
        #expect {
            try VPhoneVirtualMachineDelete.delete(named: "nosuch", in: fixture.library)
        } throws: { "\($0)" == expected }
        #expect(fixture.exists(fixture.library.root.appendingPathComponent("vm")))
    }

    @Test("the last machine of a template returns it with a note; another user keeps it quiet")
    func unusedTemplate() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeMachine("src")
        let template = try VPhoneMachineTemplates.adopt(machineNamed: "src", in: fixture.library, record: record())
        try VPhoneMachineTemplates.cloneMachine(from: template, to: "phone-a", in: fixture.library)
        try VPhoneBundleOperations.clone(bundleNamed: "phone-a", to: "phone-b", in: fixture.library, newIdentity: true)

        let first = try VPhoneVirtualMachineDelete.delete(named: "phone-a", in: fixture.library)
        #expect(first.unusedTemplate == nil)
        #expect(first.templateNote == nil)

        let last = try VPhoneVirtualMachineDelete.delete(named: "phone-b", in: fixture.library)
        #expect(last.unusedTemplate?.identifier == template.identifier)
        let note = try #require(last.templateNote)
        #expect(note.hasPrefix("note: template \(template.identifier) (~"))
        #expect(note.hasSuffix("remove it with `vphone-cli vm template delete \(template.identifier)`"))
        #expect(fixture.exists(template.url))
    }

    @Test("refuseWhenRunning throws for a held disk and removes nothing; the default deletes")
    func refuseWhenRunning() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bundle = try fixture.makeMachine("vm")
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", bundle.url.appendingPathComponent("Disk.img").path]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()
        defer { tail.terminate(); tail.waitUntilExit() }
        // Wait until tail has the disk open.
        var held = false
        for _ in 0 ..< 50 {
            held = !VPhoneBundleActivity.processesHolding([bundle.url.appendingPathComponent("Disk.img")]).isEmpty
            if held { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try #require(held)

        #expect {
            try VPhoneVirtualMachineDelete.delete(named: "vm", in: fixture.library, refuseWhenRunning: true)
        } throws: { error in
            if case VPhoneBundleActivityError.running = error { return true }
            return false
        }
        #expect(fixture.exists(bundle.url))

        try VPhoneVirtualMachineDelete.delete(named: "vm", in: fixture.library)
        #expect(!fixture.exists(bundle.url))
    }
}
