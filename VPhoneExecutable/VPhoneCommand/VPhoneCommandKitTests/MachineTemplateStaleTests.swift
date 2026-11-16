import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
@testable import VPhoneCommandKit
@testable import VPhoneCoreKit

/// `VPhoneMachineTemplateKeys.staleReasons`: the three ways a template stops
/// serving a create, and the receipt-drift reason.
struct MachineTemplateStaleTests {
    private struct Fixture {
        let root: URL
        let template: VPhoneMachineTemplate

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let ios = VPhoneRestoreInfo.OSVersion(version: "27.0", build: "24A435")
    private static let cloudOS = VPhoneRestoreInfo.OSVersion(version: "26.4", build: "23E5207q")

    private func freshKey(preset: String = VPhonePatchPreset.standardIdentifier) throws -> VPhoneMachineTemplateKey {
        let resolved = try #require(VPhonePatchPresetStore.preset(named: preset))
        return try VPhoneMachineTemplateKeys.key(
            device: "iPhone17,3",
            ios: Self.ios,
            cloudOS: Self.cloudOS,
            preset: resolved,
            diskSizeGB: 64,
            series: VPhoneMachineTemplateKeys.currentSeries,
        )
    }

    /// A template on disk whose bundle is a real, empty machine.
    private func makeTemplate(key: VPhoneMachineTemplateKey) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stale-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let bundle = try VPhoneBundleOperations.create(
            .init(name: "tpl", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: VPhoneLibrary(root: root.appendingPathComponent("machines")),
        )
        let template = VPhoneMachineTemplate(url: bundle.url, record: VPhoneMachineTemplateRecord(key: key))
        return Fixture(root: root, template: template)
    }

    /// The boot-chain patches the standard plan wants, with their receipt part.
    private func wantedBootChain() throws -> [(identifier: String, part: String)] {
        let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
        let plan = try VPhoneMachineTemplateKeys.plan(
            preset: preset,
            iOSVersion: Self.ios.version,
            cloudOSVersion: Self.cloudOS.version,
        )
        return FirmwarePatchSetCatalog.allDeclarations.compactMap { declaration in
            guard case .firmware = declaration.target, plan.enabled.contains(declaration.identifier) else { return nil }
            return (declaration.identifier, VPhoneVirtualMachinePatchReceipt.part(for: declaration.target))
        }
    }

    /// A receipt recording every wanted boot-chain patch live except `missing`.
    private func writeReceipt(missing: String, wanted: [(identifier: String, part: String)], in directory: URL) throws {
        try VPhonePatchPresetStore.updateReceipt(forVM: directory) { receipt in
            for part in Set(wanted.map(\.part)) {
                let live = wanted.filter { $0.part == part && $0.identifier != missing }.map(\.identifier)
                receipt.record(part, patches: live, writer: "restore", bundleVersion: nil)
            }
        }
    }

    @Test("a template whose key matches a fresh resolve and whose patches match is fresh")
    func fresh() throws {
        let fixture = try makeTemplate(key: freshKey())
        defer { fixture.cleanUp() }
        #expect(VPhoneMachineTemplateKeys.staleReasons(fixture.template) == [])
    }

    @Test("a template built by another bundle series is stale for the series")
    func otherSeries() throws {
        var key = try freshKey()
        key.bundleSeries = "0.1"
        let fixture = try makeTemplate(key: key)
        defer { fixture.cleanUp() }
        #expect(VPhoneMachineTemplateKeys.staleReasons(fixture.template) == [
            "built by bundle series 0.1; this vphone-cli is \(VPhoneMachineTemplateKeys.currentSeries)",
        ])
    }

    @Test("a plan that resolves differently now is stale with the changed fields")
    func planResolvesDifferently() throws {
        var key = try freshKey()
        key.bootChainPlanDigest = "0123456789abcdef"
        let fixture = try makeTemplate(key: key)
        defer { fixture.cleanUp() }
        let reasons = VPhoneMachineTemplateKeys.staleReasons(fixture.template)
        #expect(reasons.count == 1)
        #expect(reasons.first?.hasPrefix("a create with the same options now resolves differently (boot-chain plan: 0123456789ab → ") == true)
    }

    @Test("a recorded iOS build that differs from the fresh key is stale for the key")
    func iOSBuildDiffers() throws {
        let fresh = try freshKey()
        var recorded = fresh
        recorded.iOSBuild = "24A000"
        let template = VPhoneMachineTemplate(
            url: FileManager.default.temporaryDirectory,
            record: VPhoneMachineTemplateRecord(key: recorded),
        )
        #expect(template.staleReasons(currentSeries: fresh.bundleSeries, freshKey: fresh) == [
            "a create with the same options now resolves differently (iOS: 27.0 (24A000) → 27.0 (24A435))",
        ])
    }

    @Test("an unknown preset is stale with the unresolvable-preset reason")
    func unknownPreset() throws {
        var key = try freshKey()
        key.patchPreset = "no-such-preset"
        key.bundleSeries = VPhoneMachineTemplateKeys.currentSeries
        let fixture = try makeTemplate(key: key)
        defer { fixture.cleanUp() }
        #expect(VPhoneMachineTemplateKeys.staleReasons(fixture.template) == [
            "its preset no-such-preset cannot be resolved by this vphone-cli",
        ])
    }

    @Test("a receipt missing a wanted boot-chain patch is drift, listed sorted; notApplicable clears it")
    func drift() throws {
        let wanted = try wantedBootChain()
        let missing = try #require(wanted.map(\.identifier).sorted().first)
        let fixture = try makeTemplate(key: freshKey())
        defer { fixture.cleanUp() }
        try writeReceipt(missing: missing, wanted: wanted, in: fixture.template.url)
        #expect(VPhoneMachineTemplateKeys.staleReasons(fixture.template) == [
            "boot-chain patches differ from its receipt: \(missing)",
        ])

        // The plan then records the patch as not applicable on this guest.
        let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
        let resolved = try VPhoneMachineTemplateKeys.plan(
            preset: preset,
            iOSVersion: Self.ios.version,
            cloudOSVersion: Self.cloudOS.version,
        )
        let plan = VPhoneVirtualMachinePatchPlan(
            plan: resolved,
            iOSBase: VPhoneVersion(Self.ios.version),
            cloudOS: VPhoneVersion(Self.cloudOS.version),
            notApplicablePatches: [missing],
        )
        try VPhonePatchPresetStore.write(plan, forVM: fixture.template.url)
        #expect(VPhoneMachineTemplateKeys.staleReasons(fixture.template) == [])
    }
}
