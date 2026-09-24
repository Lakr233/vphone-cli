import Foundation
import Testing
@testable import VPhoneCoreKit

/// `VPhoneVirtualMachineManifest.newVM` replaces `scripts/vm_manifest.py`.
///
/// These assert the legacy values and the v2 schema marker, because the file
/// they write is what every later boot reads: a wrong type or a missing key
/// here surfaces as a VM that will not start, some distance from the cause.
///
/// The equivalence itself was checked by running both versions and comparing
/// the parsed plists key by key — identical for the default arguments and for
/// `--cpu 4 --memory 4096 --platform-fusing dev`. The v2 marker is deliberately
/// additional; the other values remain pinned to that comparison.
@Suite("Fresh VM manifest")
struct NewVirtualMachineManifestTests {
    @Test
    func `defaults match the Python's`() {
        let m = VPhoneVirtualMachineManifest.newVM()

        #expect(m.platformType == .vresearch101)
        #expect(m.cpuCount == 8)
        #expect(m.memorySize == 8192 * 1024 * 1024)
        #expect(m.diskImage == "Disk.img")
        #expect(m.nvramStorage == "nvram.bin")
        #expect(m.sepStorage == "SEPStorage")
        #expect(m.romImages?.avpBooter == "AVPBooter.vresearch1.bin")
        #expect(m.romImages?.avpSEPBooter == "AVPSEPBooter.vresearch1.bin")
        #expect(m.screenConfig.width == 1290)
        #expect(m.screenConfig.height == 2796)
        #expect(m.screenConfig.pixelsPerInch == 460)
        #expect(m.screenConfig.scale == 3.0)
        #expect(m.networkConfig.mode == .nat)
    }

    @Test
    func `machineIdentifier starts empty, for first boot to fill in`() {
        #expect(VPhoneVirtualMachineManifest.newVM().machineIdentifier.isEmpty)
    }

    @Test
    func `macAddress starts empty so the framework assigns one`() {
        // Not cosmetic: forcing a MAC here breaks guest networking.
        #expect(VPhoneVirtualMachineManifest.newVM().networkConfig.macAddress.isEmpty)
    }

    @Test
    func `memory is MB in, bytes out`() {
        #expect(VPhoneVirtualMachineManifest.newVM(memoryMB: 4096).memorySize == 4_294_967_296)
    }

    @Test
    func `platformFusing is absent unless asked for`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-manifest-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        try VPhoneVirtualMachineManifest.newVM().write(to: url)
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil,
        ) as? [String: Any]

        // Absent, not null: the host OS decides when the key is missing.
        #expect(parsed?["platformFusing"] == nil)
        #expect(parsed?["bridgeInterface"] == nil)
    }

    @Test
    func `platformFusing is written when asked for`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-manifest-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        try VPhoneVirtualMachineManifest.newVM(platformFusing: .dev).write(to: url)
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil,
        ) as? [String: Any]

        #expect(parsed?["platformFusing"] as? String == "dev")
    }

    @Test
    func `the exact v2 key set is written`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-manifest-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        try VPhoneVirtualMachineManifest.newVM().write(to: url)
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil,
        ) as? [String: Any])

        #expect(parsed.keys.sorted() == [
            "cpuCount", "diskImage", "machineIdentifier", "memorySize",
            "networkConfig", "nvramStorage", "platformType", "romImages",
            "schemaVersion", "screenConfig", "sepStorage",
        ])
        #expect(parsed["schemaVersion"] as? Int == 2)
    }

    @Test
    func `manifest without v2 marker requires VM recreation`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-manifest-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        try VPhoneVirtualMachineManifest.newVM().write(to: url)
        var parsed = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil,
        ) as? [String: Any])
        parsed.removeValue(forKey: "schemaVersion")
        let legacy = try PropertyListSerialization.data(fromPropertyList: parsed, format: .xml, options: 0)
        try legacy.write(to: url)

        do {
            _ = try VPhoneVirtualMachineManifest.load(from: url)
            Issue.record("A manifest without schemaVersion was accepted")
        } catch let error as VPhoneManifestError {
            if case let .unsupportedSchema(_, found) = error {
                #expect(found == nil)
                #expect(error.description.contains("Recreate this VM"))
            } else {
                Issue.record("Expected an unsupported schema error, got \(error)")
            }
        } catch {
            Issue.record("Expected a manifest error, got \(error)")
        }
    }

    @Test
    func `what is written can be read back`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-manifest-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = VPhoneVirtualMachineManifest.newVM(cpuCount: 4, memoryMB: 4096)
        try written.write(to: url)
        let read = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(read.cpuCount == 4)
        #expect(read.memorySize == 4_294_967_296)
        #expect(read.romImages?.avpBooter == written.romImages?.avpBooter)
        #expect(read.networkConfig.mode == .nat)
    }

    @Test
    func `cpuCount stays an integer, not a string`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-manifest-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        try VPhoneVirtualMachineManifest.newVM().write(to: url)
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil,
        ) as? [String: Any])

        // A number that becomes "8" parses fine and fails much later.
        #expect(parsed["cpuCount"] is NSNumber)
        #expect(parsed["cpuCount"] as? Int == 8)
        #expect(parsed["memorySize"] is NSNumber)
        #expect(parsed["machineIdentifier"] is Data)
    }
}
