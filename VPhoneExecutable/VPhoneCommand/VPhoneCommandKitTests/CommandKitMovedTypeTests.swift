import ArgumentParser
import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
import VPhoneRestore
@testable import VPhoneArchiveKit
@testable import VPhoneCommandKit
@testable import VPhoneCoreKit

// Pure, offline coverage for the types that moved into VPhoneCommandKit.
// Everything runs in a temp directory; nothing touches ~/.vphone, mounts a
// disk or contacts a service.
// VPhoneSealTool: SealToolTests.swift.
// VPhoneMachineTemplateKeys: MachineTemplateStaleTests.swift (and the
// recorded-key test below).

/// A temp directory removed by `cleanUp()`.
struct TempDir {
    let url: URL

    init(_ prefix: String) throws {
        // realpath: a pinned directory refuses a path through /var -> /private/var.
        let base = FileManager.default.temporaryDirectory.path
        let real = realpath(base, nil).map { String(cString: $0) } ?? base
        url = URL(fileURLWithPath: real, isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }

    /// A real, empty machine named `name` in `<temp>/machines`.
    func makeBundle(name: String = "m") throws -> VPhoneBundle {
        let rom = url.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        return try VPhoneBundleOperations.create(
            .init(name: name, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: VPhoneLibrary(root: url.appendingPathComponent("machines")),
        )
    }
}

private let ios = VPhoneRestoreInfo.OSVersion(version: "27.0", build: "24A435")
private let cloudOS = VPhoneRestoreInfo.OSVersion(version: "26.4", build: "23E5207q")

private func standardPlan() throws -> VPhonePatchPlan {
    let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
    return try VPhoneMachineTemplateKeys.plan(preset: preset, iOSVersion: ios.version, cloudOSVersion: cloudOS.version)
}

private func someKey(slimming: VPhoneMachineTemplateSlimming = .none) throws -> VPhoneMachineTemplateKey {
    let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
    return try VPhoneMachineTemplateKeys.key(
        device: "iPhone17,3", ios: ios, cloudOS: cloudOS, preset: preset, diskSizeGB: 64,
        series: VPhoneMachineTemplateKeys.currentSeries, slimming: slimming,
    )
}

// MARK: - Firmware

struct PatchPresetStoreMovedTests {
    @Test("a selection, a plan and a receipt written to a VM folder read back, under their file names")
    func roundTrip() throws {
        let dir = try TempDir("preset")
        defer { dir.cleanUp() }

        // Nothing written: standard selection, no plan, no receipt (unknown, not empty).
        #expect(VPhonePatchPresetStore.selection(forVM: dir.url) == VPhoneVirtualMachinePatchSelection())
        #expect(VPhonePatchPresetStore.plan(forVM: dir.url) == nil)
        #expect(VPhonePatchPresetStore.receipt(forVM: dir.url) == nil)

        let selection = VPhoneVirtualMachinePatchSelection(presetIdentifier: VPhonePatchPreset.minimalIdentifier)
        try VPhonePatchPresetStore.write(selection, forVM: dir.url)
        #expect(VPhonePatchPresetStore.selection(forVM: dir.url) == selection)
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("PatchSelection.plist").path))

        let plan = try VPhoneVirtualMachinePatchPlan(
            plan: standardPlan(),
            iOSBase: VPhoneVersion(ios.version),
            cloudOS: VPhoneVersion(cloudOS.version),
        )
        try VPhonePatchPresetStore.write(plan, forVM: dir.url)
        let readPlan = try #require(VPhonePatchPresetStore.plan(forVM: dir.url))
        #expect(readPlan == plan)
        #expect(readPlan.presetIdentifier == VPhonePatchPreset.standardIdentifier)
        #expect(readPlan.iOSBaseVersion == ios.version)
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("PatchPlan.plist").path))

        let identifier = try #require(plan.enabledPatches.first)
        try VPhonePatchPresetStore.updateReceipt(forVM: dir.url) { receipt in
            receipt.record("Guest", patches: [identifier, identifier], writer: "cfw install", bundleVersion: "1.2")
        }
        let receipt = try #require(VPhonePatchPresetStore.receipt(forVM: dir.url))
        let guest = try #require(receipt.parts[VPhoneVirtualMachinePatchReceipt.guestPart])
        #expect(guest.patches == [identifier]) // de-duplicated
        #expect(guest.writer == "cfw install")
        #expect(guest.bundleVersion == "1.2")
        #expect(receipt.appliedPatches == [identifier])
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("PatchReceipt.plist").path))
    }
}

struct PatchSetStoreMovedTests {
    @Test("a set's folder is <store>/<identifier>.<extension> inside patchsets, and errors name the set")
    func pathAndErrors() {
        let url = VPhonePatchSetStore.url(forIdentifier: "com.example.set")
        #expect(url.lastPathComponent == "com.example.set.\(VPhonePatchSetBundle.pathExtension)")
        #expect(url.deletingLastPathComponent().lastPathComponent == "patchsets")
        #expect(url.deletingLastPathComponent().path == VPhonePatchSetStore.directory().path)

        #expect(VPhonePatchSetStoreError.notImported(identifier: "a.b").description == "No imported patch set with identifier a.b")
        #expect(VPhonePatchSetStoreError.alreadyImported(identifier: "a.b", path: "/x/a.b").description
            == "a.b is already imported at /x/a.b. Pass --replace to overwrite it.")
        #expect(VPhonePatchSetStoreError.signingFailed(path: "/x", reason: "boom").description == "Could not ad hoc sign /x: boom")
    }
}

struct IOS17WallpaperAssetsMovedTests {
    private static let originalXML = #"<caml><img src="assets/Wall.HEIC"/></caml>"#

    /// `<root>/<wallpapers>/7565.test.wallpaper/anim.ca`, and the confined `root`.
    private func makeAnimation(in dir: TempDir) throws -> (root: VPhoneConfinedDirectory, animation: URL) {
        let wallpapers = String(FirmwareGuestSystemPatchSet.ios17WallpaperPath.dropFirst())
        let animation = dir.url.appendingPathComponent(wallpapers)
            .appendingPathComponent("7565.test.wallpaper/anim.ca", isDirectory: true)
        try FileManager.default.createDirectory(at: animation.appendingPathComponent("assets"), withIntermediateDirectories: true)
        return (try VPhoneConfinedDirectory.pin(absolutePath: dir.url.path), animation)
    }

    @Test("a system without the wallpaper collection changes nothing")
    func noCollection() throws {
        let dir = try TempDir("wall")
        defer { dir.cleanUp() }
        let root = try VPhoneConfinedDirectory.pin(absolutePath: dir.url.path)
        #expect(try VPhoneIOS17WallpaperAssets.update(system: root, enabled: true) == 0)
        #expect(try VPhoneIOS17WallpaperAssets.update(system: root, enabled: false) == 0)
    }

    @Test("disabling puts the backed-up animation back, removes the converted PNG and counts the asset")
    func disableRestoresBackup() throws {
        let dir = try TempDir("wall")
        defer { dir.cleanUp() }
        let (root, animation) = try makeAnimation(in: dir)
        try Data(Self.originalXML.utf8).write(to: animation.appendingPathComponent("main.caml.vphone-original"))
        try Data(#"<caml><img src="assets/Wall.vphone.png"/></caml>"#.utf8).write(to: animation.appendingPathComponent("main.caml"))
        try Data([1]).write(to: animation.appendingPathComponent("assets/Wall.vphone.png"))

        #expect(try VPhoneIOS17WallpaperAssets.update(system: root, enabled: false) == 1)
        #expect(try String(contentsOf: animation.appendingPathComponent("main.caml"), encoding: .utf8) == Self.originalXML)
        #expect(!FileManager.default.fileExists(atPath: animation.appendingPathComponent("assets/Wall.vphone.png").path))
        #expect(!FileManager.default.fileExists(atPath: animation.appendingPathComponent("main.caml.vphone-original").path))
        // Nothing left to undo.
        #expect(try VPhoneIOS17WallpaperAssets.update(system: root, enabled: false) == 0)
    }

    @Test("enabling refuses a reference that decodes to a path, and a PNG that already exists, before writing")
    func enableRefusals() throws {
        let dir = try TempDir("wall")
        defer { dir.cleanUp() }
        let (root, animation) = try makeAnimation(in: dir)
        let document = animation.appendingPathComponent("main.caml")

        try Data(#"<caml><img src="assets/..%2Fx.HEIC"/></caml>"#.utf8).write(to: document)
        #expect {
            try VPhoneIOS17WallpaperAssets.update(system: root, enabled: true)
        } throws: { error in
            "\(error)".contains("Invalid stock wallpaper asset reference: assets/..%2Fx.HEIC")
        }

        try Data(Self.originalXML.utf8).write(to: document)
        try Data([1]).write(to: animation.appendingPathComponent("assets/Wall.vphone.png"))
        #expect {
            try VPhoneIOS17WallpaperAssets.update(system: root, enabled: true)
        } throws: { error in
            "\(error)".contains("The stock wallpaper asset already exists: Wall.vphone.png")
        }
        #expect(try String(contentsOf: document, encoding: .utf8) == Self.originalXML)
    }
}

struct FirmwarePreparerMovedTests {
    @Test("the iOS 17 GPU transport is only 17.7 on the SE (3rd generation) and iPhone 15")
    func iOS17Transport() {
        #expect(VPhoneFirmwarePreparer.usesIOS17GPUTransport(version: "17.7", device: .iPhone14_6))
        #expect(VPhoneFirmwarePreparer.usesIOS17GPUTransport(version: "17.7", device: .iPhone15_4))
        #expect(!VPhoneFirmwarePreparer.usesIOS17GPUTransport(version: "17.6", device: .iPhone14_6))
        #expect(!VPhoneFirmwarePreparer.usesIOS17GPUTransport(version: "17.7", device: .iPhone17_3))
    }

    @Test("a cached GPU driver lives at <cache>/<version>_<build>/<bundle name>")
    func cachedDriverPath() {
        let cloud = VPhoneIPSWCache.Archive(
            file: URL(fileURLWithPath: "/tmp/c.ipsw"), version: "26.4", build: "23E5207q",
            productTypes: [], deviceClasses: [],
        )
        let cache = URL(fileURLWithPath: "/tmp/gpu-cache", isDirectory: true)
        #expect(VPhoneFirmwarePreparer.cachedGPUDriver(for: cloud, in: cache).path
            == "/tmp/gpu-cache/26.4_23E5207q/AppleParavirtGPUMetalIOGPUFamily.bundle")
    }

    @Test("storing a GPU driver copies it into the build folder and replaces damaged leftovers")
    func storeDriver() throws {
        let dir = try TempDir("gpu")
        defer { dir.cleanUp() }
        let source = dir.url.appendingPathComponent("src/\(VPhonePCCGPUDriver.name)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("Info.plist"))

        let destination = dir.url.appendingPathComponent("cache/26.4_23E5207q/\(VPhonePCCGPUDriver.name)")
        // A half-written earlier copy.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("stale"))

        try VPhoneFirmwarePreparer.storeGPUDriver(source, at: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("Info.plist"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale").path))
        // No private ".partial" folder is left beside the build folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent("cache").path)
        #expect(leftovers == ["26.4_23E5207q"])
    }

    @Test("recording a guest device rewrites config.plist for a different model and leaves the default alone")
    func recordDevice() throws {
        let dir = try TempDir("device")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        let config = bundle.url.appendingPathComponent("config.plist")
        let before = try VPhoneVirtualMachineManifest.load(from: config)
        #expect(before.guestProductType == nil)

        try VPhoneFirmwarePreparer.recordGuestDevice(.iPhone14_6, in: bundle)
        let after = try VPhoneVirtualMachineManifest.load(from: config)
        #expect(after.guestProductType == "iPhone14,6")
        #expect(after.screenConfig.width == 750)
        #expect(after.screenConfig.height == 1334)
    }

    @Test("errors tell the user what to do")
    func errorText() {
        let url = URL(fileURLWithPath: "/tmp/r")
        #expect(VPhoneFirmwarePreparer.Error.existingRestore(url).errorDescription
            == "A restore tree already exists at /tmp/r. Remove it, then prepare the firmware again.")
        #expect(VPhoneFirmwarePreparer.Error.deviceNotInSource("iPhone9,9", available: ["iPhone1,1", "iPhone2,2"]).errorDescription
            == "The IPSW does not contain iPhone9,9; it covers iPhone1,1, iPhone2,2. Choose one of those with --device, or use that model's IPSW.")
    }
}

struct CustomFirmwareInstallerMovedTests {
    @Test("only a plan that enables the cryptex merge means the restore customised the system")
    func restoredCustomised() throws {
        func decode(preset: String, enabled: [String]) throws -> VPhoneVirtualMachinePatchPlan {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Preset": preset, "EnabledPatches": enabled], format: .xml, options: 0,
            )
            return try PropertyListDecoder().decode(VPhoneVirtualMachinePatchPlan.self, from: data)
        }
        let plain = try decode(preset: VPhonePatchPreset.standardIdentifier, enabled: [])
        #expect(VPhoneCustomFirmwareInstaller.restoredCustomisedSystem(plain) == false)
        #expect(VPhoneCustomFirmwareInstaller.restoredCustomisedSystem(nil) == false)

        let customised = try decode(
            preset: VPhonePatchPreset.minimalIdentifier, enabled: [FirmwareRestoreImagePatchSet.cryptexMerge],
        )
        #expect(customised.enabledPatches == [FirmwareRestoreImagePatchSet.cryptexMerge])
        #expect(VPhoneCustomFirmwareInstaller.restoredCustomisedSystem(customised) == true)
    }

    @Test("a full install needs 50 GiB free, an update 10")
    func freeSpace() {
        #expect(VPhoneCustomFirmwareInstaller.requiredFreeSpaceGiB(for: .full) == 50)
        #expect(VPhoneCustomFirmwareInstaller.requiredFreeSpaceGiB(for: .environmentOnly) == 10)
        #expect(VPhoneCustomFirmwareInstaller.requiredFreeSpaceGiB(for: .kernelUpdate) == 10)
    }

    @Test("the restore-image refusal names the minimal preset and the refused mode")
    func refusal() {
        let message = VPhoneCustomFirmwareInstaller.restoreImageRefusal(.kernelUpdate).message
        #expect(message.contains("(the \(VPhonePatchPreset.minimalIdentifier) preset)"))
        #expect(message.contains(VPhoneCustomFirmwareInstaller.Mode.kernelUpdate.summary))
        #expect(message.hasSuffix("Patch and restore the VM again instead."))
    }

    @Test("a disk held by another process refuses with the rerun advice; this process and no holder do not")
    func diskUnused() throws {
        try VPhoneCustomFirmwareInstaller.requireDiskUnused(lsofOutput: "", rerun: "run cfw install again")
        try VPhoneCustomFirmwareInstaller.requireDiskUnused(lsofOutput: "\(getpid())\n", rerun: "run cfw install again")
        #expect {
            try VPhoneCustomFirmwareInstaller.requireDiskUnused(lsofOutput: "2147483646\n", rerun: "run cfw install again")
        } throws: { error in
            let message = (error as? ValidationError)?.message ?? ""
            return message.hasPrefix("The VM disk is open in process 2147483646")
                && message.hasSuffix("Wait for it to close the disk, then run cfw install again.")
        }
    }

    @Test("only the foldable board counts as foldable")
    func foldable() {
        #expect(VPhoneCustomFirmwareInstaller.isFoldable(.iPhone19_4))
        #expect(!VPhoneCustomFirmwareInstaller.isFoldable(.iPhone17_3))
    }
}

// MARK: - Host

struct HostPreflightMovedTests {
    @Test("on a physical host without a sibling vphone-vm, preflight throws the planner's missing-companion error")
    func noCompanion() throws {
        let sibling = VPhoneResources.siblingExecutable("vphone-vm")
        try #require(!FileManager.default.isExecutableFile(atPath: sibling.path), "test host unexpectedly has a vphone-vm")
        #expect {
            try VPhoneHostPreflight.check(isNestedHost: false)
        } throws: { error in
            guard case let VPhoneGuestLaunchError.missingCompanion(name, expectedAt) = error else { return false }
            return name == "vphone-vm" && expectedAt.path == sibling.path
        }
    }

    @Test("on a nested VM host, preflight refuses before looking for vphone-vm")
    func nestedHostRefused() {
        #expect {
            try VPhoneHostPreflight.check(isNestedHost: true)
        } throws: { error in
            (error as? ValidationError)?.message.contains("running inside a VM") == true
        }
    }
}

struct PCCGPURecoveryMovedTests {
    @Test("cloudOS before 26 restores with one vCPU, 26 and later with eight")
    func cpuCount() {
        #expect(VPhonePCCGPURecovery.restoreCPUCount(platformVersion: "18.6") == 1)
        #expect(VPhonePCCGPURecovery.restoreCPUCount(platformVersion: "25.9.1") == 1)
        #expect(VPhonePCCGPURecovery.restoreCPUCount(platformVersion: "26.0") == 8)
        #expect(VPhonePCCGPURecovery.restoreCPUCount(platformVersion: "27.2") == 8)
        #expect(VPhonePCCGPURecovery.restoreCPUCount(platformVersion: "garbage") == 8)
    }

    @Test("the virtual device is added to SupportedProductTypes once, keeping the rest of the manifest")
    func acceptDevice() throws {
        let dir = try TempDir("manifest")
        defer { dir.cleanUp() }
        let file = dir.url.appendingPathComponent("BuildManifest.plist")
        func write(_ types: [String]?) throws {
            var manifest: [String: Any] = ["ProductVersion": "26.4"]
            if let types { manifest["SupportedProductTypes"] = types }
            try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: file)
        }
        func read() throws -> [String: Any] {
            try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        }

        try write(["VirtualMac2,1"])
        try VPhonePCCGPURecovery.acceptVirtualDevice(manifest: file)
        #expect(try read()["SupportedProductTypes"] as? [String] == ["VirtualMac2,1", "iPhone99,11"])
        #expect(try read()["ProductVersion"] as? String == "26.4")

        try VPhonePCCGPURecovery.acceptVirtualDevice(manifest: file)
        #expect(try read()["SupportedProductTypes"] as? [String] == ["VirtualMac2,1", "iPhone99,11"])

        try write(nil)
        try VPhonePCCGPURecovery.acceptVirtualDevice(manifest: file)
        #expect(try read()["SupportedProductTypes"] as? [String] == ["iPhone99,11"])
    }

    @Test("tool failures name the tool and the detail")
    func errorText() {
        #expect(VPhonePCCGPURecovery.Error.toolFailed("diskutil", "busy").errorDescription
            == "diskutil failed while reading the restored PCC System volume: busy")
    }
}

// MARK: - Support

struct InvokingUserFileMovedTests {
    @Test("a non-root read returns the file's bytes and a missing file throws")
    func readFile() throws {
        try #require(geteuid() != 0, "the root path needs sudo and is not exercised here")
        let dir = try TempDir("preset-file")
        defer { dir.cleanUp() }
        let file = dir.url.appendingPathComponent("p.json")
        try Data("{\"a\":1}".utf8).write(to: file)
        #expect(try VPhoneInvokingUserFile.read(file, kind: "preset") == Data("{\"a\":1}".utf8))
        #expect(throws: (any Error).self) {
            try VPhoneInvokingUserFile.read(dir.url.appendingPathComponent("missing.json"), kind: "preset")
        }
    }
}

struct ProgressBarMovedTests {
    @Test("byte counts scale by 1024 with one decimal above bytes")
    func bytes() {
        #expect(VPhoneProgressBar.bytes(0) == "0 B")
        #expect(VPhoneProgressBar.bytes(1023) == "1023 B")
        #expect(VPhoneProgressBar.bytes(1024) == "1.0 KB")
        #expect(VPhoneProgressBar.bytes(1536) == "1.5 KB")
        #expect(VPhoneProgressBar.bytes(5 * 1024 * 1024) == "5.0 MB")
        #expect(VPhoneProgressBar.bytes(3 * 1024 * 1024 * 1024) == "3.0 GB")
        #expect(VPhoneProgressBar.bytes(Int64(2) * 1024 * 1024 * 1024 * 1024) == "2.0 TB")
        #expect(VPhoneProgressBar.bytes(5 * 1024 * 1024 * 1024 * 1024 * 1024) == "5120.0 TB")
    }

    @Test("the eta clock is mm:ss under an hour and h:mm:ss from an hour")
    func clock() {
        #expect(VPhoneProgressBar.clock(0) == "00:00")
        #expect(VPhoneProgressBar.clock(59.6) == "01:00")
        #expect(VPhoneProgressBar.clock(125) == "02:05")
        #expect(VPhoneProgressBar.clock(3599) == "59:59")
        #expect(VPhoneProgressBar.clock(3600) == "1:00:00")
        #expect(VPhoneProgressBar.clock(3725) == "1:02:05")
    }
    // The bar writes to the process's stderr (a terminal or VPHONE_PROGRESS pipe
    // in use), which a parallel test run cannot capture; the helpers above are
    // everything it renders with.
}

// VPhoneVerbosityRestore.swift
struct VerbosityRestoreMovedTests {
    @Test("restore logging is info below debug and debug from debug up; the debug ceiling follows")
    func mapping() {
        #expect(VPhoneVerbosity.quiet.restoreLogLevel == .info)
        #expect(VPhoneVerbosity.info.restoreLogLevel == .info)
        #expect(VPhoneVerbosity.debug.restoreLogLevel == .debug)
        #expect(VPhoneVerbosity.trace.restoreLogLevel == .debug)
        #expect(VPhoneVerbosity.quiet.restoreDebugLevel == 0)
        #expect(VPhoneVerbosity.info.restoreDebugLevel == 0)
        #expect(VPhoneVerbosity.debug.restoreDebugLevel == 1)
        #expect(VPhoneVerbosity.trace.restoreDebugLevel == 1)
    }
}

// MARK: - Virtual machine

struct MachineTemplateTrimmerMovedTests {
    private func spec(_ text: String) throws -> VPhoneSystemTrimSpec {
        try VPhoneSystemTrimSpec.parse(tier: text)
    }

    @Test("trim none on a stopped machine frees nothing and records the tier in a new unfrozen record")
    func trimNone() throws {
        let dir = try TempDir("trim")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        var log: [String] = []
        let result = try VPhoneMachineTemplateTrimmer.trim(
            bundle, label: "m", spec: .none, newRecord: VPhoneMachineTemplateRecord(key: someKey()), log: { log.append($0) },
        )
        #expect(result.trim == "none")
        #expect(result.entries.isEmpty)
        #expect(result.bytes == 0)
        #expect(log == ["[*] Trim none: nothing to delete"])
        let record = try #require(try VPhoneMachineTemplates.readRecord(inBundle: bundle.url))
        #expect(record.steps.trimTier == "none")
        #expect(record.frozen == false)
    }

    @Test("a machine without a record and no new record to write is refused as not being built")
    func trimWithoutRecord() throws {
        let dir = try TempDir("trim")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        #expect(throws: VPhoneMachineTemplateError.notBeingBuilt(path: bundle.url.path)) {
            try VPhoneMachineTemplateTrimmer.trim(bundle, label: "m", spec: .none, newRecord: nil, log: { _ in })
        }
    }

    @Test("a frozen template is refused")
    func frozen() throws {
        let dir = try TempDir("trim")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        var record = try VPhoneMachineTemplateRecord(key: someKey())
        record.frozen = true
        try VPhoneMachineTemplates.writeRecord(record, inBundle: bundle.url)
        #expect(throws: VPhoneMachineTemplateError.frozen(identifier: record.identifier)) {
            try VPhoneMachineTemplateTrimmer.requireTrimmable(bundle, label: "m", spec: .none)
        }
    }

    @Test("a clone of a template is refused with the template named")
    func clone() throws {
        let dir = try TempDir("trim")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        try VPhoneMachineTemplates.writeSource(VPhoneMachineTemplateSource(identifier: "0123456789ab"), inBundle: bundle.url)
        #expect(throws: VPhoneSystemTrimError.clonedFromTemplate(machine: "m", template: "0123456789ab")) {
            try VPhoneMachineTemplateTrimmer.requireTrimmable(bundle, label: "m", spec: .none)
        }
    }

    @Test("a lighter trim than the recorded one is a downgrade; conservative then standard is allowed")
    func downgrade() throws {
        let dir = try TempDir("trim")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        var record = try VPhoneMachineTemplateRecord(key: someKey())
        record.steps.trimTier = "conservative/1"
        try VPhoneMachineTemplates.writeRecord(record, inBundle: bundle.url)

        #expect(throws: VPhoneSystemTrimError.downgrade(machine: "m", recorded: "conservative/1", requested: "none")) {
            try VPhoneMachineTemplateTrimmer.requireTrimmable(bundle, label: "m", spec: .none)
        }
        try VPhoneMachineTemplateTrimmer.requireTrimmable(bundle, label: "m", spec: .standard)
        try VPhoneMachineTemplateTrimmer.requireTrimmable(bundle, label: "m", spec: spec("conservative"))
    }
}

// VPhoneTemplateSetup.swift (VPhoneTemplateBuildFinisher)
struct TemplateSetupMovedTests {
    /// A machine whose records say it was restored, patched and CFW-installed.
    private func makeBuild(in dir: TempDir) throws -> (build: VPhoneMachineTemplateBuild, key: VPhoneMachineTemplateKey) {
        let bundle = try dir.makeBundle(name: "tpl")
        try VPhoneRestoreInfo(ios: ios, cloudOS: cloudOS).write(toBundle: bundle)
        try VPhoneRestoreInfo.recordVariant("jb", toBundle: bundle)
        try VPhonePatchPresetStore.write(
            VPhoneVirtualMachinePatchPlan(plan: standardPlan(), iOSBase: nil, cloudOS: nil), forVM: bundle.url,
        )
        let build = VPhoneMachineTemplateBuild(identifier: "tpl", stagingURL: bundle.url.deletingLastPathComponent())
        let recorded = try VPhoneMachineTemplateKeys.recorded(VPhoneBundle.load(at: build.bundleURL))
        #expect(recorded.key.iOSBuild == "24A435")
        #expect(recorded.key.cloudOSBuild == "23E5207q")
        #expect(recorded.key.patchPreset == VPhonePatchPreset.standardIdentifier)
        return (build, recorded.key)
    }

    @Test("a build whose records give the requested key passes; a different key is refused with the differences")
    func requireKey() throws {
        let dir = try TempDir("setup")
        defer { dir.cleanUp() }
        let (build, key) = try makeBuild(in: dir)
        try VPhoneTemplateBuildFinisher.requireRecordedKey(build, key: key)

        var other = key
        other.iOSBuild = "24A000"
        #expect {
            try VPhoneTemplateBuildFinisher.requireRecordedKey(build, key: other)
        } throws: { error in
            (error as? ValidationError)?.message
                == "The built template's records give another key than requested (iOS: 27.0 (24A000) → 27.0 (24A435))."
        }
    }

    @Test("a machine with no completed CFW install cannot be keyed")
    func noInstall() throws {
        let dir = try TempDir("setup")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle(name: "tpl")
        let build = VPhoneMachineTemplateBuild(identifier: "tpl", stagingURL: bundle.url.deletingLastPathComponent())
        #expect {
            try VPhoneTemplateBuildFinisher.requireRecordedKey(build, key: someKey())
        } throws: { error in
            (error as? ValidationError)?.message == "VM 'tpl' has no completed CFW install, so it cannot be a template."
        }
    }

}

// VPhoneVirtualMachineCreateOptions.swift
struct CreateOptionsMovedTests {
    @Test("defaults build an 8 CPU, 8 GiB, 64 GB machine from the standard preset with no template")
    func defaults() {
        let options = VPhoneVirtualMachineCreator.Options(name: "vm1")
        #expect(options.name == "vm1")
        #expect(options.cpuCount == 8)
        #expect(options.memoryMB == 8192)
        #expect(options.diskSizeGB == 64)
        #expect(options.patchPreset == VPhonePatchPreset.standardIdentifier)
        #expect(options.template == .none)
        #expect(options.verbosity == .quiet)
        #expect(options.keepArtifacts == false)
        #expect(options.skipsFirstBoot == false)
        #expect(options.iphoneSource == nil)
        #expect(options.cloudosSource == nil)
        #expect(options.bootstrapLayout == nil)
        #expect(options.networkMode == nil)
        #expect(options.unlocksAtStartup == nil)
        #expect(options.slimming == VPhoneTemplateSlimmingRequest.defaultSlimming)
    }

    @Test("template uses compare by case and identifier")
    func templateUse() {
        typealias Use = VPhoneVirtualMachineCreator.TemplateUse
        #expect(Use.identifier("abcd") == .identifier("abcd"))
        #expect(Use.identifier("abcd") != .identifier("abce"))
        #expect(Use.automatic != .none)
    }

    private let resources = VPhoneResources.resolve()

    @Test("run refuses an invalid name, an existing machine and an unknown template before any work")
    func runValidation() throws {
        let dir = try TempDir("create")
        defer { dir.cleanUp() }
        let library = VPhoneLibrary(root: dir.url.appendingPathComponent("machines"))
        let creator = VPhoneVirtualMachineCreator(library: library, resources: resources, launcher: nil)
        func options(_ name: String) -> VPhoneVirtualMachineCreator.Options {
            .init(name: name, template: .identifier("0123456789ab"), skipsFirstBoot: true)
        }

        #expect {
            try creator.run(options(".hidden"))
        } throws: { error in
            guard case VPhoneLibraryError.invalidName(".hidden") = error else { return false }
            return true
        }

        _ = try dir.makeBundle(name: "taken")
        #expect {
            try creator.run(options("taken"))
        } throws: { error in
            guard case VPhoneLibraryError.alreadyExists(name: "taken") = error else { return false }
            return true
        }

        #expect(throws: VPhoneMachineTemplateError.notFound("0123456789ab")) {
            try creator.run(options("fresh"))
        }
        #expect(!FileManager.default.fileExists(atPath: library.url(forName: "fresh").path))
    }
}

struct VirtualMachineCreatorMovedTests {
    @Test("templateSlimming is the options' own slimming")
    func slimming() {
        #expect(VPhoneVirtualMachineCreator.templateSlimming(.init(name: "a")) == VPhoneTemplateSlimmingRequest.defaultSlimming)
        let custom = VPhoneMachineTemplateSlimming(trimTier: "conservative/1", setupBoot: true, serviceProfile: "trimmed")
        #expect(VPhoneVirtualMachineCreator.templateSlimming(.init(name: "a", slimming: custom)) == custom)
        #expect(VPhoneVirtualMachineCreator.templateSlimming(.init(name: "a", slimming: .none)) == .none)
    }
}
