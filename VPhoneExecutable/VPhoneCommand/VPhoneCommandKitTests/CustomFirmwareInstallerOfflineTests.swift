import ArgumentParser
import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
@testable import VPhoneArchiveKit
@testable import VPhoneCommandKit
@testable import VPhoneCoreKit

/// `VPhoneCustomFirmwareInstaller` as far as it goes without root: the
/// refusal when not root, and the host-side checks it makes of the bundle
/// before it mounts anything. The install proper needs root and a disk image.
private func refusal(_ body: () throws -> some Any) -> String? {
    do { _ = try body() } catch let error as ValidationError { return error.message } catch { return "\(error)" }
    return nil
}

struct CustomFirmwareInstallerRootRefusalTests {
    private let resources = VPhoneResources.resolve()

    @Test("modes name themselves in the refusal when not root", .enabled(if: geteuid() != 0))
    func refusesWithoutRoot() throws {
        let expected: [(VPhoneCustomFirmwareInstaller.Mode, String, String)] = [
            (.full, "full", "CFW system install"),
            (.environmentOnly, "environmentOnly", "guest environment update"),
            (.kernelUpdate, "kernelUpdate", "guest kernel update"),
        ]
        for (mode, raw, summary) in expected {
            #expect(mode.rawValue == raw)
            #expect(mode.summary == summary)
            let text = "\(summary.capitalized) needs root. Run this command with sudo."
            let bundle = URL(fileURLWithPath: "/nonexistent")
            #expect(refusal { try VPhoneCustomFirmwareInstaller.elevate(bundle: bundle, resources: resources, mode: mode) } == text)
            #expect(refusal {
                try VPhoneCustomFirmwareInstaller(bundle: bundle, resources: resources, mode: mode, workParent: "/x").run()
            } == text)
        }
        #expect(refusal { try VPhoneCustomFirmwareInstaller.elevate(bundle: URL(fileURLWithPath: "/nonexistent"), resources: resources) }
            == "Cfw System Install needs root. Run this command with sudo.")
    }

    @Test("the install-root initialiser is a full install in the work folder it is given")
    func publicInit() {
        let bundle = URL(fileURLWithPath: "/tmp/vm")
        let installer = VPhoneCustomFirmwareInstaller(bundle: bundle, resources: resources, workParent: "/x")
        #expect(installer.mode == .full)
        #expect(installer.workParent == "/x")
        #expect(installer.bundle == bundle)
        #expect(VPhoneCustomFirmwareInstaller.defaultWorkParent == "/private/var/tmp")
    }

    @Test("a full install needs 50 GiB free and an environment or kernel update 10")
    func requiredSpace() {
        #expect(VPhoneCustomFirmwareInstaller.requiredFreeSpaceGiB(for: .full) == 50)
        #expect(VPhoneCustomFirmwareInstaller.requiredFreeSpaceGiB(for: .environmentOnly) == 10)
        #expect(VPhoneCustomFirmwareInstaller.requiredFreeSpaceGiB(for: .kernelUpdate) == 10)
    }
}

struct CustomFirmwareInstallerHostChecksTests {
    private let resources = VPhoneResources.resolve()
    private let stranger = geteuid() + 1

    private func installer(_ bundle: URL, _ mode: VPhoneCustomFirmwareInstaller.Mode = .full) -> VPhoneCustomFirmwareInstaller {
        VPhoneCustomFirmwareInstaller(bundle: bundle, resources: resources, mode: mode, workParent: "/private/var/tmp")
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("pinning refuses a missing folder, a file, and a folder of another account, and accepts the caller's own")
    func pin() throws {
        let dir = try TempDir("pin")
        defer { dir.cleanUp() }
        let missing = dir.url.appendingPathComponent("gone")
        #expect(refusal { try installer(missing).pinBundle(owner: nil) }
            == "The VM folder \(missing.path) does not exist. Create the VM again, then install CFW.")

        let file = dir.url.appendingPathComponent("file")
        try Data().write(to: file)
        let notFolder = try #require(refusal { try installer(file).pinBundle(owner: nil) })
        #expect(notFolder.hasPrefix("The VM folder \(file.path) cannot be used for a root install: "))
        #expect(notFolder.hasSuffix("is not a folder."))

        let vm = try folder("vm", in: dir.url)
        let foreign = try #require(refusal { try installer(vm).pinBundle(owner: stranger) })
        #expect(foreign.hasPrefix("The VM folder \(vm.path) cannot be used for a root install: "))
        #expect(foreign.hasSuffix("is owned by user ID \(geteuid()), not the account that started the install."))

        let pinned = try installer(vm).pinBundle(owner: geteuid())
        #expect(try pinned.entries().isEmpty)
    }

    @Test("pinning follows no link: a symlinked VM folder resolves to its target")
    func pinThroughLink() throws {
        let dir = try TempDir("pin")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        try Data("x".utf8).write(to: vm.appendingPathComponent("marker"))
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: vm)
        let pinned = try installer(link).pinBundle(owner: nil)
        #expect(try pinned.entries() == ["marker"])
    }

    @Test("the disk image must exist, be a regular file with one link, and be the caller's")
    func diskImage() throws {
        let dir = try TempDir("disk")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        #expect(refusal { try sut.openDiskImage(in: pinned, path: vm.path, owner: nil) }
            == "The VM disk image is missing: \(vm.path)/Disk.img. Create the VM again, then install CFW.")

        let disk = vm.appendingPathComponent("Disk.img")
        try Data("img".utf8).write(to: disk)
        _ = try sut.openDiskImage(in: pinned, path: vm.path, owner: geteuid())

        let foreign = try #require(refusal { try sut.openDiskImage(in: pinned, path: vm.path, owner: stranger) })
        #expect(foreign.hasPrefix("The VM disk image cannot be used for a root install: "))
        #expect(foreign.hasSuffix("is owned by user ID \(geteuid()), not the account that started the install."))

        try FileManager.default.linkItem(at: disk, to: dir.url.appendingPathComponent("second-name"))
        let linked = try #require(refusal { try sut.openDiskImage(in: pinned, path: vm.path, owner: nil) })
        #expect(linked.hasPrefix("The VM disk image cannot be used for a root install: "))
        #expect(linked.hasSuffix("Disk.img has more than one hard link."))
    }

    @Test("a disk image that is a folder or a link is refused")
    func diskImageWrongKind() throws {
        let dir = try TempDir("disk")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        try FileManager.default.createDirectory(at: vm.appendingPathComponent("Disk.img"), withIntermediateDirectories: true)
        let asFolder = try #require(refusal { try sut.openDiskImage(in: pinned, path: vm.path, owner: nil) })
        #expect(asFolder.hasPrefix("The VM disk image cannot be used for a root install: "))
        #expect(asFolder.hasSuffix("is not a regular file."))

        try FileManager.default.removeItem(at: vm.appendingPathComponent("Disk.img"))
        let target = dir.url.appendingPathComponent("target.img")
        try Data("t".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: vm.appendingPathComponent("Disk.img"), withDestinationURL: target)
        let asLink = try #require(refusal { try sut.openDiskImage(in: pinned, path: vm.path, owner: nil) })
        #expect(asLink.hasPrefix("The VM disk image cannot be used for a root install: "))
    }

    private func restoreFolder(_ name: String, in vm: URL, manifest: Bool = true) throws {
        let url = try folder(name, in: vm)
        if manifest { try Data("{}".utf8).write(to: url.appendingPathComponent("iPhone-BuildManifest.plist")) }
    }

    @Test("the restore tree is the highest iPhone*_Restore with a manifest, else any *Restore* folder, else refused")
    func restoreTreeChoice() throws {
        let dir = try TempDir("restore")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        let none = "No prepared iPhone restore tree was found in \(vm.path). Run fw prepare, then install CFW again."
        #expect(refusal { try sut.restoreTree(in: pinned, path: vm.path, owner: nil) } == none)

        // No manifest: not a tree. A file of that name: not a tree.
        try restoreFolder("iPhone17,3_27.0_24A435_Restore", in: vm, manifest: false)
        try Data().write(to: vm.appendingPathComponent("iPhone17,3_28.0_25A1_Restore"))
        #expect(refusal { try sut.restoreTree(in: pinned, path: vm.path, owner: nil) } == none)

        try restoreFolder("OldRestoreCopy", in: vm)
        let fallback = try sut.restoreTree(in: pinned, path: vm.path, owner: nil)
        #expect(try fallback.isRegularFile("iPhone-BuildManifest.plist"))
        #expect(try fallback.entries() == ["iPhone-BuildManifest.plist"])
        try Data("fallback".utf8).write(to: vm.appendingPathComponent("OldRestoreCopy/mark"))

        try restoreFolder("iPhone17,3_26.0_23A1_Restore", in: vm)
        try restoreFolder("iPhone17,3_27.0_24A435_Restore", in: vm) // now with a manifest
        try Data("high".utf8).write(to: vm.appendingPathComponent("iPhone17,3_27.0_24A435_Restore/mark"))
        let chosen = try sut.restoreTree(in: pinned, path: vm.path, owner: nil)
        #expect(try chosen.entries().sorted() == ["iPhone-BuildManifest.plist", "mark"])
        #expect(try String(decoding: chosen.readData("mark"), as: UTF8.self) == "high")
    }

    @Test("a tree owned by another account is named in the refusal")
    func restoreTreeForeign() throws {
        let dir = try TempDir("restore")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        try restoreFolder("iPhone17,3_27.0_24A435_Restore", in: vm)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        #expect(refusal { try sut.restoreTree(in: pinned, path: vm.path, owner: stranger) }
            == "The restore tree \(vm.path)/iPhone17,3_27.0_24A435_Restore is not owned by your account. Run fw prepare as yourself, then install CFW again.")
        _ = try sut.restoreTree(in: pinned, path: vm.path, owner: geteuid())
    }

    @Test("free space is checked once per volume, skips paths that do not exist, and names the volume and the mode")
    func freeSpace() throws {
        let dir = try TempDir("space")
        defer { dir.cleanUp() }
        // Independently computed: free bytes on the volume holding the temp folder.
        var fs = statfs()
        #expect(statfs(dir.url.path, &fs) == 0)
        let available = Int64(fs.f_bavail) * Int64(fs.f_bsize)
        let gib: Int64 = 1024 * 1024 * 1024
        let missing = dir.url.appendingPathComponent("gone").path
        for (mode, required, summary) in [
            (VPhoneCustomFirmwareInstaller.Mode.full, Int64(50), "CFW system install"),
            (.environmentOnly, 10, "guest environment update"),
            (.kernelUpdate, 10, "guest kernel update"),
        ] {
            let sut = installer(dir.url, mode)
            #expect(refusal { try sut.requireFreeSpace(at: [missing]) } == nil)
            #expect(refusal { try sut.requireFreeSpace(at: []) } == nil)
            // Far from the threshold either way, so a few MB of churn cannot flip it.
            guard abs(available - required * gib) > 2 * gib else { continue }
            let text = refusal { try sut.requireFreeSpace(at: [dir.url.path, dir.url.path]) }
            if available > required * gib {
                #expect(text == nil)
            } else {
                #expect(text == "Less than \(required) GiB of disk space is available on the volume holding \(dir.url.path). Free up space, then run the \(summary) again.")
            }
        }
    }

    @Test("without a patch-plan.plist the plan is nil, and a damaged one is nil too; a good one reads back")
    func readPlan() throws {
        let dir = try TempDir("plan")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        #expect(sut.readPatchPlan(in: pinned) == nil)
        try Data("not a plist".utf8).write(to: vm.appendingPathComponent(VPhonePatchPresetStore.planFileName))
        #expect(sut.readPatchPlan(in: pinned) == nil)

        let plan = try Self.standardPlan()
        try VPhonePatchPresetStore.write(plan, forVM: vm)
        #expect(sut.readPatchPlan(in: pinned) == plan)
    }

    static func standardPlan(blocked: Set<String> = []) throws -> VPhoneVirtualMachinePatchPlan {
        let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
        let resolved = try VPhonePatchPlan.resolve(
            preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"), blocked: blocked, allowed: [],
        )
        return VPhoneVirtualMachinePatchPlan(plan: resolved, iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"))
    }

    @Test("guest patches follow the VM's current selection and boot-chain patches stay as recorded")
    func guestSelection() throws {
        let dir = try TempDir("select")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        #expect(sut.resolveGuestSelection(nil, in: pinned) == nil)

        let plan = try Self.standardPlan()
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers
        let guestOn = Set(plan.enabledPatches).intersection(guest)
        let bootOn = Set(plan.enabledPatches).subtracting(guest)
        let dropped = try #require(guestOn.sorted().first)
        #expect(!bootOn.isEmpty)

        // No selection file: the preset's own choices, which made the plan.
        #expect(sut.resolveGuestSelection(plan, in: pinned)?.enabledPatches == plan.enabledPatches)

        try VPhonePatchPresetStore.write(VPhoneVirtualMachinePatchSelection(blockedPatches: [dropped]), forVM: vm)
        let blocked = try #require(sut.resolveGuestSelection(plan, in: pinned))
        #expect(Set(blocked.enabledPatches) == Set(plan.enabledPatches).subtracting([dropped]))
        #expect(blocked.enabledPatches == blocked.enabledPatches.sorted())
        #expect(Set(blocked.enabledPatches).intersection(bootOn) == bootOn)
        #expect(blocked.presetIdentifier == plan.presetIdentifier)
    }

    @Test("a plan whose preset the bundled sets cannot resolve is kept as recorded")
    func guestSelectionUnresolvable() throws {
        let dir = try TempDir("select")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        var plan = try Self.standardPlan()
        plan.presetIdentifier = "external.example"
        try VPhonePatchPresetStore.write(VPhoneVirtualMachinePatchSelection(blockedPatches: Array(plan.enabledPatches.prefix(1))), forVM: vm)
        #expect(sut.resolveGuestSelection(plan, in: pinned) == plan)
    }

    @Test("the guest device comes from the restore tree's manifest, else the default")
    func deviceOfRestore() throws {
        let dir = try TempDir("device")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let tree = try folder("iPhone17,3_27.0_24A435_Restore", in: vm)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        let treeDirectory = try pinned.directory("iPhone17,3_27.0_24A435_Restore")
        #expect(sut.guestDevice(of: nil) == .default)
        #expect(sut.guestDevice(of: treeDirectory) == .default) // no manifest

        let manifest = try PropertyListSerialization.data(
            fromPropertyList: ["SupportedProductTypes": ["iPhone15,4", "iPhone14,6"]], format: .xml, options: 0,
        )
        try manifest.write(to: tree.appendingPathComponent("iPhone-BuildManifest.plist"))
        #expect(sut.guestDevice(of: treeDirectory) == .iPhone15_4)
    }

    @Test("the configured device is read from config.plist; unknown, absent or unreadable gives nil")
    func configuredDevice() throws {
        let dir = try TempDir("config")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        #expect(sut.configuredGuestDevice(in: pinned) == nil)
        let config = vm.appendingPathComponent("config.plist")
        func write(_ value: Any) throws {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: config)
        }
        try write(["guestProductType": "iPad16,1"])
        #expect(sut.configuredGuestDevice(in: pinned) == .iPad16_1)
        try write(["guestProductType": "iPad16,2"]) // a cellular twin
        #expect(sut.configuredGuestDevice(in: pinned) == .iPad16_1)
        try write(["guestProductType": "Toaster1,1"])
        #expect(sut.configuredGuestDevice(in: pinned) == nil)
        try write(["other": "x"])
        #expect(sut.configuredGuestDevice(in: pinned) == nil)
        try Data("junk".utf8).write(to: config)
        #expect(sut.configuredGuestDevice(in: pinned) == nil)
    }

    @Test("the recorded OS version is read from restore-info.json; absent or damaged gives nil")
    func recordedVersion() throws {
        let dir = try TempDir("info")
        defer { dir.cleanUp() }
        let vm = try folder("vm", in: dir.url)
        let sut = installer(vm)
        let pinned = try sut.pinBundle(owner: nil)
        #expect(sut.recordedOSVersion(in: pinned) == nil)
        let info = VPhoneRestoreInfo(
            ios: .init(version: "27.0", build: "24A435"), cloudOS: .init(version: "26.4", build: "23E5207q"),
        )
        try JSONEncoder().encode(info).write(to: vm.appendingPathComponent("restore-info.json"))
        #expect(sut.recordedOSVersion(in: pinned) == .init(version: "27.0", build: "24A435"))
        try Data("{".utf8).write(to: vm.appendingPathComponent("restore-info.json"))
        #expect(sut.recordedOSVersion(in: pinned) == nil)
    }
}
