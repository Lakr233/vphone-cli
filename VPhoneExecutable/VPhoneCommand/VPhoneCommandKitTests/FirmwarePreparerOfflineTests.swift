import ArgumentParser
import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
@testable import VPhoneArchiveKit
@testable import VPhoneCommandKit
@testable import VPhoneCoreKit

/// `VPhoneFirmwarePreparer` up to the first download, extraction of a real
/// GPU driver or restore: source resolution against local IPSWs and the
/// cache, every refusal, the merge helpers and the driver cache. Fixtures are
/// archives that hold only a BuildManifest.
private func message(of error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? (error as? ValidationError)?.message ?? "\(error)"
}

private func thrownMessage(_ body: () throws -> some Any) -> String? {
    do { _ = try body() } catch { return message(of: error) }
    return nil
}

struct PreparerSourceResolutionTests {
    @Test("local IPSWs resolve in place to their versions and the default device")
    func localPair() throws {
        let dir = try TempDir("sources")
        defer { dir.cleanUp() }
        let pair = try OfflineFixtures.writePair(in: dir.url)
        let resolved = try VPhoneFirmwarePreparer.resolveSources(
            iPhoneSource: pair.phone.path, cloudOSSource: pair.cloud.path,
            ipswCacheDirectory: dir.url.appendingPathComponent("cache"),
        )
        #expect(resolved.phone.file == pair.phone)
        #expect(resolved.phone.version == "27.0")
        #expect(resolved.phone.build == "24A435")
        #expect(resolved.cloud.version == "26.4")
        #expect(resolved.cloud.build == "23E5207q")
        #expect(resolved.device == .iPhone17_3)
        // A local source is never copied into the cache.
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("cache").path))
    }

    @Test("an IPSW covering several models gives the requested one, and an uncovered one is refused with the list")
    func deviceSelection() throws {
        let dir = try TempDir("sources")
        defer { dir.cleanUp() }
        let pair = try OfflineFixtures.writePair(in: dir.url, phoneProducts: ["iPhone17,3", "iPhone14,6"])
        let cache = dir.url.appendingPathComponent("cache")
        let chosen = try VPhoneFirmwarePreparer.resolveSources(
            iPhoneSource: pair.phone.path, cloudOSSource: pair.cloud.path, ipswCacheDirectory: cache, device: "iPhone14,6",
        )
        #expect(chosen.device == .iPhone14_6)

        #expect(thrownMessage {
            try VPhoneFirmwarePreparer.resolveSources(
                iPhoneSource: pair.phone.path, cloudOSSource: pair.cloud.path, ipswCacheDirectory: cache, device: "iPhone15,4",
            )
        } == "The IPSW does not contain iPhone15,4; it covers iPhone17,3, iPhone14,6. Choose one of those with --device, or use that model's IPSW.")
    }

    @Test("a catalog OTA source for another device is refused before anything is fetched")
    func otaSourceForOtherDevice() throws {
        let dir = try TempDir("sources")
        defer { dir.cleanUp() }
        let pair = try OfflineFixtures.writePair(in: dir.url)
        let ota = try #require(VPhoneFirmwareCatalog.otaReleases.first { $0.productType == "AppleTV14,1" })
        #expect(thrownMessage {
            try VPhoneFirmwarePreparer.resolveSources(
                iPhoneSource: ota.url, cloudOSSource: pair.cloud.path,
                ipswCacheDirectory: dir.url.appendingPathComponent("cache"), device: "iPhone17,3",
            )
        } == "The IPSW does not contain iPhone17,3; it covers AppleTV14,1. Choose one of those with --device, or use that model's IPSW.")
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("cache").path))
    }

    @Test("swapped, wrong-kind, missing and unsupported sources fail with the fix")
    func badSources() throws {
        let dir = try TempDir("sources")
        defer { dir.cleanUp() }
        let pair = try OfflineFixtures.writePair(in: dir.url)
        let cache = dir.url.appendingPathComponent("cache")
        func resolve(_ phone: String, _ cloud: String) -> String? {
            thrownMessage {
                try VPhoneFirmwarePreparer.resolveSources(iPhoneSource: phone, cloudOSSource: cloud, ipswCacheDirectory: cache)
            }
        }
        #expect(resolve(pair.cloud.path, pair.phone.path)
            == "The iPhone and cloudOS IPSWs are swapped: cloud.ipsw is a cloudOS IPSW and phone.ipsw is an iPhone IPSW. Swap the two sources, then try again.")
        // Two iPhone IPSWs: the second is no cloudOS.
        #expect(resolve(pair.phone.path, pair.phone.path)
            == "phone.ipsw is not a cloudOS IPSW: it has no vresearch101ap build identity. Choose a cloudOS IPSW as the cloudOS source.")
        // Two cloudOS IPSWs: the first is no iPhone IPSW (it is for iPhone17,3 only as a listed product here, so use one with none).
        let none = try OfflineFixtures.writeIPSW(
            in: dir.url, name: "none.ipsw", version: "27.0", build: "24A435", productTypes: [], deviceClasses: ["x"],
        )
        #expect(resolve(none.path, pair.cloud.path)
            == "none.ipsw is not an IPSW vphone can run; it is for no listed product. Choose an IPSW for \(VPhoneIPSWCache.guestProductTypes.joined(separator: " or ")) as the iPhone source.")
        let missing = dir.url.appendingPathComponent("gone.ipsw").path
        #expect(resolve(missing, pair.cloud.path) == "IPSW not found at \(missing). Check the path and try again.")
        #expect(resolve("ftp://example.invalid/a.ipsw", pair.cloud.path)
            == "Unsupported IPSW source: ftp://example.invalid/a.ipsw. Use a local file path or an HTTP(S) URL.")
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("a cached remote IPSW resolves from the cache with no download")
    func cacheHit() throws {
        let dir = try TempDir("sources")
        defer { dir.cleanUp() }
        let pair = try OfflineFixtures.writePair(in: dir.url)
        let cache = dir.url.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let source = "https://example.invalid/ipsws/iPhone17,3_27.0_24A435_Restore.ipsw"
        let sourceURL = try #require(URL(string: source))
        let cached = cache.appendingPathComponent(VPhoneIPSWCache.cacheName(for: sourceURL))
        try FileManager.default.copyItem(at: pair.phone, to: cached)
        let resolved = try VPhoneFirmwarePreparer.resolveSources(
            iPhoneSource: source, cloudOSSource: pair.cloud.path, ipswCacheDirectory: cache,
        )
        #expect(resolved.phone.file == cached)
        #expect(resolved.phone.build == "24A435")
        #expect(resolved.device == .iPhone17_3)
    }

    @Test("an IPSW whose file name disagrees with its contents is refused; other names are not checked")
    func nameMismatch() throws {
        let archive = VPhoneIPSWCache.Archive(
            file: URL(fileURLWithPath: "/tmp/real.ipsw"), version: "27.0", build: "24A435",
            productTypes: ["iPhone17,3"], deviceClasses: [],
        )
        try VPhoneFirmwarePreparer.checkIPhoneName("/x/iPhone17,3_27.0_24A435_Restore.ipsw", archive: archive, device: .iPhone17_3)
        // Not the original name: nothing to compare.
        try VPhoneFirmwarePreparer.checkIPhoneName("/x/my copy.ipsw", archive: archive, device: .iPhone17_3)
        // Another device's name is not this device's pattern.
        try VPhoneFirmwarePreparer.checkIPhoneName("/x/iPhone16,1_26.0_99Z999_Restore.ipsw", archive: archive, device: .iPhone17_3)
        // An iPad IPSW names every model it covers.
        try VPhoneFirmwarePreparer.checkIPhoneName("/x/iPad16,1,iPad16,2_27.0_24A435_Restore.ipsw", archive: archive, device: .iPad16_1)

        #expect(thrownMessage {
            try VPhoneFirmwarePreparer.checkIPhoneName("/x/iPhone17,3_27.0_24A999_Restore.ipsw", archive: archive, device: .iPhone17_3)
        } == "The IPSW file name does not match its contents (27.0/24A435): /tmp/real.ipsw. Use the original file name or download the IPSW again.")
        #expect(thrownMessage {
            try VPhoneFirmwarePreparer.checkIPhoneName("/x/iPad16,1,iPad16,2_26.0_24A435_Restore.ipsw", archive: archive, device: .iPad16_1)
        } != nil)
    }

    @Test("every error says what to do")
    func errorText() {
        #expect(message(of: VPhoneFirmwarePreparer.Error.missingComponent(URL(fileURLWithPath: "/tmp/agx")))
            == "A firmware component is missing: /tmp/agx. Check that the IPSW is complete, then prepare the firmware again.")
        #expect(message(of: VPhoneFirmwarePreparer.Error.sourceNameMismatch(URL(fileURLWithPath: "/tmp/a.ipsw"), version: "1", build: "2"))
            == "The IPSW file name does not match its contents (1/2): /tmp/a.ipsw. Use the original file name or download the IPSW again.")
    }
}

struct PreparerPrepareRefusalTests {
    private let resources = VPhoneResources.resolve()

    private func prepare(
        _ bundle: VPhoneBundle, phone: String, cloud: String, cache: URL, ota: String? = nil, key: String? = nil,
    ) throws {
        try VPhoneFirmwarePreparer.prepare(
            iPhoneSource: phone, cloudOSSource: cloud, ipswCacheDirectory: cache,
            otaSource: ota, otaKey: key, bundle: bundle, resources: resources,
        )
    }

    private func setUp(_ prefix: String = "prepare") throws -> (dir: TempDir, bundle: VPhoneBundle, pair: (phone: URL, cloud: URL)) {
        let dir = try TempDir(prefix)
        let bundle = try dir.makeBundle()
        return (dir, bundle, try OfflineFixtures.writePair(in: dir.url))
    }

    @Test("a restore tree already in the machine is refused; a file of that name is not a tree")
    func existingRestore() throws {
        let (dir, bundle, pair) = try setUp()
        defer { dir.cleanUp() }
        let cache = dir.url.appendingPathComponent("cache")
        let tree = bundle.url.appendingPathComponent("iPhone17,3_27.0_24A435_Restore")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        #expect(thrownMessage { try prepare(bundle, phone: pair.phone.path, cloud: pair.cloud.path, cache: cache) }
            == "A restore tree already exists at \(tree.path). Remove it, then prepare the firmware again.")
        // The refusal comes before any source is read.
        #expect(thrownMessage { try prepare(bundle, phone: "/nonexistent.ipsw", cloud: pair.cloud.path, cache: cache) }
            == "A restore tree already exists at \(tree.path). Remove it, then prepare the firmware again.")

        try FileManager.default.removeItem(at: tree)
        try Data().write(to: tree)
        #expect(thrownMessage { try prepare(bundle, phone: "/nonexistent.ipsw", cloud: pair.cloud.path, cache: cache) }
            == "IPSW not found at /nonexistent.ipsw. Check the path and try again.")
    }

    @Test("kept boot-chain originals and a staged OTA userland of the previous firmware are removed before the sources are read")
    func staleLeftovers() throws {
        let (dir, bundle, pair) = try setUp()
        defer { dir.cleanUp() }
        let originals = bundle.url.appendingPathComponent(VPhoneBundleOperations.firmwareOriginalsDirectoryName)
        let userland = bundle.url.appendingPathComponent(VPhoneOTAArchive.userlandDirectoryName)
        for folder in [originals, userland] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("kept"))
        }
        #expect(throws: (any Error).self) {
            try prepare(bundle, phone: "/nonexistent.ipsw", cloud: pair.cloud.path, cache: dir.url.appendingPathComponent("cache"))
        }
        #expect(!FileManager.default.fileExists(atPath: originals.path))
        #expect(!FileManager.default.fileExists(atPath: userland.path))
    }

    @Test("the iOS 17 and iOS 16 experiments refuse everything but their one supported pairing")
    func experimentalVersions() throws {
        let dir = try TempDir("prepare")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        let cache = dir.url.appendingPathComponent("cache")

        let ios17 = try OfflineFixtures.writePair(in: dir.url.appendingPathComponent("a", isDirectory: true).createdDirectory(), ios: .init(version: "17.6", build: "21G80"))
        #expect(thrownMessage { try prepare(bundle, phone: ios17.phone.path, cloud: ios17.cloud.path, cache: cache) }
            == "Experimental iOS 17 bring-up supports iPhone15,4 17.7 with cloudOS 26.1 and iPhone14,6 17.7 (21H16) with cloudOS 26.1 (23B85).")

        let ios16 = try OfflineFixtures.writePair(in: dir.url.appendingPathComponent("b", isDirectory: true).createdDirectory(), ios: .init(version: "16.5", build: "20F66"))
        #expect(thrownMessage { try prepare(bundle, phone: ios16.phone.path, cloud: ios16.cloud.path, cache: cache) }
            == "The local iOS 16 experiment is limited to iPhone15,2 16.6.1 with cloudOS 26.1.")
    }

    @Test("OTA options without an OTA userland device are refused")
    func otaOptionsOnIPhone() throws {
        let (dir, bundle, pair) = try setUp()
        defer { dir.cleanUp() }
        let cache = dir.url.appendingPathComponent("cache")
        let expected = "--ota-source and --ota-key require an OTA userland device, such as AppleTV14,1 or HomePod mini."
        #expect(thrownMessage { try prepare(bundle, phone: pair.phone.path, cloud: pair.cloud.path, cache: cache, ota: "/x/ota.zip") } == expected)
        #expect(thrownMessage { try prepare(bundle, phone: pair.phone.path, cloud: pair.cloud.path, cache: cache, key: "AAAA") } == expected)
    }

    @Test("a machine whose selection names an unknown preset is refused with the available ones")
    func unknownPreset() throws {
        let (dir, bundle, pair) = try setUp()
        defer { dir.cleanUp() }
        try VPhonePatchPresetStore.write(VPhoneVirtualMachinePatchSelection(presetIdentifier: "nope"), forVM: bundle.url)
        let available = VPhonePatchPresetStore.availablePresets().map(\.identifier).joined(separator: ", ")
        #expect(thrownMessage {
            try prepare(bundle, phone: pair.phone.path, cloud: pair.cloud.path, cache: dir.url.appendingPathComponent("cache"))
        } == "Unknown patch preset 'nope'. Available: \(available)")
    }

    @Test("a cloudOS without the merge folders fails the merge, naming the folder, and leaves no staging or tree behind")
    func mergeFailureCleansUp() throws {
        let (dir, bundle, pair) = try setUp()
        defer { dir.cleanUp() }
        let before = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).sorted()
        let text = try #require(thrownMessage {
            try prepare(bundle, phone: pair.phone.path, cloud: pair.cloud.path, cache: dir.url.appendingPathComponent("cache"))
        })
        #expect(text.hasPrefix("A firmware component is missing: "))
        #expect(text.contains("/cloudOS/Firmware/agx. Check that the IPSW is complete"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).sorted() == before)
    }
}

struct PreparerMergeHelperTests {
    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("the cloudOS merge copies kernelcaches, the five folders, .im4p files (over the phone's), and disk images only where missing")
    func mergeCloudOS() throws {
        let dir = try TempDir("merge")
        defer { dir.cleanUp() }
        let cloud = dir.url.appendingPathComponent("cloud")
        let phone = dir.url.appendingPathComponent("phone")
        try write("c-kernel", cloud.appendingPathComponent("kernelcache.release.vphone600"))
        try write("c-other", cloud.appendingPathComponent("readme.txt"))
        for sub in ["agx", "all_flash", "ane", "dfu", "pmp"] {
            try write("c-\(sub)", cloud.appendingPathComponent("Firmware/\(sub)/file.bin"))
        }
        try write("c-im4p", cloud.appendingPathComponent("Firmware/boot.im4p"))
        try write("c-skip", cloud.appendingPathComponent("Firmware/skip.bin"))
        try write("c-dmg", cloud.appendingPathComponent("system.dmg"))
        try write("c-dmg2", cloud.appendingPathComponent("extra.dmg"))
        try write("c-tc", cloud.appendingPathComponent("Firmware/system.dmg.trustcache"))
        try write("p-im4p", phone.appendingPathComponent("Firmware/boot.im4p"))
        try write("p-dmg", phone.appendingPathComponent("system.dmg"))
        try write("p-tc", phone.appendingPathComponent("Firmware/system.dmg.trustcache"))

        try VPhoneFirmwarePreparer.mergeCloudOS(from: cloud, into: phone)

        #expect(read(phone.appendingPathComponent("kernelcache.release.vphone600")) == "c-kernel")
        #expect(read(phone.appendingPathComponent("readme.txt")) == nil)
        for sub in ["agx", "all_flash", "ane", "dfu", "pmp"] {
            #expect(read(phone.appendingPathComponent("Firmware/\(sub)/file.bin")) == "c-\(sub)")
        }
        #expect(read(phone.appendingPathComponent("Firmware/boot.im4p")) == "c-im4p")
        #expect(read(phone.appendingPathComponent("Firmware/skip.bin")) == nil)
        #expect(read(phone.appendingPathComponent("system.dmg")) == "p-dmg")
        #expect(read(phone.appendingPathComponent("extra.dmg")) == "c-dmg2")
        #expect(read(phone.appendingPathComponent("Firmware/system.dmg.trustcache")) == "p-tc")
    }

    @Test("a cloudOS missing one of the folders is refused naming it")
    func mergeMissingFolder() throws {
        let dir = try TempDir("merge")
        defer { dir.cleanUp() }
        let cloud = dir.url.appendingPathComponent("cloud")
        for sub in ["agx", "all_flash", "ane", "dfu"] {
            try write("x", cloud.appendingPathComponent("Firmware/\(sub)/file.bin"))
        }
        #expect(thrownMessage { try VPhoneFirmwarePreparer.mergeCloudOS(from: cloud, into: dir.url.appendingPathComponent("phone")) }
            == "A firmware component is missing: \(cloud.path)/Firmware/pmp. Check that the IPSW is complete, then prepare the firmware again.")
    }

    @Test("clone replaces an existing destination and refuses a missing source")
    func cloneFile() throws {
        let dir = try TempDir("clone")
        defer { dir.cleanUp() }
        let source = dir.url.appendingPathComponent("a")
        let destination = dir.url.appendingPathComponent("b")
        try write("new", source)
        try write("old", destination)
        try VPhoneFirmwarePreparer.clone(source, to: destination)
        #expect(read(destination) == "new")
        let missing = dir.url.appendingPathComponent("none")
        #expect(thrownMessage { try VPhoneFirmwarePreparer.clone(missing, to: destination) }
            == "A firmware component is missing: \(missing.path). Check that the IPSW is complete, then prepare the firmware again.")
    }

    @Test("making a tree user-writable adds the owner write bit to files and folders and leaves symlinks alone")
    func userWritable() throws {
        let dir = try TempDir("writable")
        defer { dir.cleanUp() }
        let tree = dir.url.appendingPathComponent("tree")
        let file = tree.appendingPathComponent("sub/readonly.bin")
        try write("x", file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let outside = dir.url.appendingPathComponent("outside.bin")
        try write("y", outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("link"), withDestinationURL: outside)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path) }

        try VPhoneFirmwarePreparer.makeUserWritable(tree)

        func mode(_ url: URL) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        #expect(try mode(file) == 0o644)
        #expect(try mode(outside) == 0o444)
    }

    @Test("recording a guest device writes its type and display to config.plist once, and a machine without config.plist is skipped")
    func recordDevice() throws {
        let dir = try TempDir("device")
        defer { dir.cleanUp() }
        let bundle = try dir.makeBundle()
        let config = bundle.url.appendingPathComponent("config.plist")
        try VPhoneFirmwarePreparer.recordGuestDevice(.iPhone14_6, in: bundle)
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        #expect(manifest.guestProductType == "iPhone14,6")
        #expect(manifest.screenConfig == manifest.updating(guestDevice: .iPhone14_6).screenConfig)
        // Already recorded: the file is not rewritten.
        let written = try Data(contentsOf: config)
        try VPhoneFirmwarePreparer.recordGuestDevice(.iPhone14_6, in: bundle)
        #expect(try Data(contentsOf: config) == written)

        try FileManager.default.removeItem(at: config)
        try VPhoneFirmwarePreparer.recordGuestDevice(.iPhone14_6, in: bundle)
        #expect(!FileManager.default.fileExists(atPath: config.path))
    }
}

struct PreparerGPUDriverAndOTATests {
    /// A GPU driver bundle that passes `validateBundle` for `platform`.
    private func makeDriver(at url: URL, platform: String, marker: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("AppleParavirtGPUMetalIOGPUFamily"))
        try Data().write(to: url.appendingPathComponent("_CodeSignature/CodeResources"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily",
            "DTPlatformVersion": platform,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
    }

    @Test("an iOS 18 release takes its driver from the newest cached build that stages, skipping a wrong-platform one")
    func driverCacheHit() throws {
        let dir = try TempDir("gpu")
        defer { dir.cleanUp() }
        let cache = dir.url.appendingPathComponent("cache")
        let name = VPhonePCCGPUDriver.name
        try makeDriver(at: cache.appendingPathComponent("18.6_22G86/\(name)"), platform: "18.6", marker: "good")
        try makeDriver(at: cache.appendingPathComponent("18.6_22G90/\(name)"), platform: "17.0", marker: "wrong platform")
        try makeDriver(at: cache.appendingPathComponent("18.7_22H20/\(name)"), platform: "18.7", marker: "other release")
        let tree = dir.url.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)

        try VPhoneFirmwarePreparer.stageIOS18GPUDriver(
            forVersion: "18.6.1", into: tree, staging: dir.url.appendingPathComponent("staging"),
            ipswCacheDirectory: dir.url.appendingPathComponent("ipsws"), downloadConnections: 1, cacheDirectory: cache,
        )
        let staged = VPhonePCCGPUDriver.stagedBundle(in: tree)
        #expect(try String(contentsOf: staged.appendingPathComponent("AppleParavirtGPUMetalIOGPUFamily"), encoding: .utf8) == "good")
        // Nothing was resolved or downloaded.
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("ipsws").path))
    }

    @Test("a release no cloudOS supplies a driver for is refused with the two ways out, before any download")
    func driverUnknownRelease() throws {
        let dir = try TempDir("gpu")
        defer { dir.cleanUp() }
        let text = thrownMessage {
            try VPhoneFirmwarePreparer.stageIOS18GPUDriver(
                forVersion: "17.5", into: dir.url, staging: dir.url,
                ipswCacheDirectory: dir.url.appendingPathComponent("ipsws"), downloadConnections: 1,
                cacheDirectory: dir.url.appendingPathComponent("empty"),
            )
        }
        #expect(text == "No known cloudOS 17.5 supplies a GPU driver iOS 17.5 can load. Pass one with --gpu-driver-bundle, or block \(FirmwareGuestSystemPatchSet.ios18GPUTransport).")
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("ipsws").path))
    }

    @Test("a device with no catalog OTA for the build and no source is refused with the flags to pass")
    func otaWithoutSource() throws {
        let dir = try TempDir("ota")
        defer { dir.cleanUp() }
        let text = thrownMessage {
            try VPhoneFirmwarePreparer.resolveOTA(
                nil, key: nil, device: .iPhone17_3, build: "24A435",
                ipswCacheDirectory: dir.url, downloadConnections: 1,
            )
        }
        #expect(text == "The firmware catalog has no iPhone17,3 OTA for build 24A435. Pass the device's full OTA of that build with --ota-source, and its key with --ota-key.")
    }
}

private extension URL {
    /// Creates this folder and returns it.
    func createdDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
