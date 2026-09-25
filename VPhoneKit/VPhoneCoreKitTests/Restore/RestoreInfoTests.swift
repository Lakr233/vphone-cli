import Foundation
import Testing
@testable import VPhoneCoreKit

struct RestoreInfoTests {
    private func makeBundle() throws -> VPhoneBundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        return VPhoneBundle(url: root, manifest: manifest)
    }

    /// Write a restore dir with the two BuildManifest plists. Omit a key by
    /// passing nil for its value to exercise the missing-key path.
    private func makeRestoreDir(
        in bundle: VPhoneBundle,
        iosVersion: String?,
        iosBuild: String?,
        cloudVersion: String?,
        cloudBuild: String?,
    ) throws {
        let dir = bundle.url.appendingPathComponent("iPhone17,3_27.0_24A5390f_Restore")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ version: String?, _ build: String?) throws {
            var dict: [String: Any] = [:]
            if let version {
                dict["ProductVersion"] = version
            }
            if let build {
                dict["ProductBuildVersion"] = build
            }
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent(name))
        }
        try write("iPhone-BuildManifest.plist", iosVersion, iosBuild)
        try write("BuildManifest.plist", cloudVersion, cloudBuild)
    }

    @Test func `derives both versions from plists`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(
            in: b,
            iosVersion: "27.0",
            iosBuild: "24A5390f",
            cloudVersion: "26.4",
            cloudBuild: "23E5207q",
        )
        let info = VPhoneRestoreInfo.derive(fromBundle: b)
        #expect(info?.ios == .init(version: "27.0", build: "24A5390f"))
        #expect(info?.cloudOS == .init(version: "26.4", build: "23E5207q"))
    }

    @Test func `derive nil when no restore dir`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        #expect(VPhoneRestoreInfo.derive(fromBundle: b) == nil)
    }

    @Test func `derive nil when version key missing`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(
            in: b,
            iosVersion: "27.0",
            iosBuild: "24A5390f",
            cloudVersion: nil,
            cloudBuild: "23E5207q",
        )
        #expect(VPhoneRestoreInfo.derive(fromBundle: b) == nil)
    }

    @Test func `write then load round trips`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        let info = VPhoneRestoreInfo(
            ios: .init(version: "18.6.2", build: "22G100"),
            cloudOS: .init(version: "26.1", build: "23B85"),
        )
        try info.write(toBundle: b)
        #expect(VPhoneRestoreInfo.load(fromBundle: b) == info)
    }

    @Test func `load falls back to derive when no JSON`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(
            in: b,
            iosVersion: "27.0",
            iosBuild: "24A5390f",
            cloudVersion: "26.4",
            cloudBuild: "23E5207q",
        )
        // No restore-info.json written — load() must derive from the plists.
        let info = VPhoneRestoreInfo.load(fromBundle: b)
        #expect(info?.ios.version == "27.0")
        #expect(info?.cloudOS.version == "26.4")
    }

    @Test func `bundle report carries restore info`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(
            in: b,
            iosVersion: "27.0",
            iosBuild: "24A5390f",
            cloudVersion: "26.4",
            cloudBuild: "23E5207q",
        )
        let report = VPhoneBundleReport(bundle: b)
        #expect(report.restoreInfo?.ios.build == "24A5390f")
        #expect(report.restoreInfo?.cloudOS.build == "23E5207q")
    }

    @Test func `device for variant`() {
        #expect(VPhoneRestoreInfo.device(forVariant: "exp") == "iPhone17,3")
        for v in ["regular", "dev", "jb"] {
            #expect(VPhoneRestoreInfo.device(forVariant: v) == "iPhone99,11")
        }
    }

    @Test func `record variant merges into versions`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try VPhoneRestoreInfo(
            ios: .init(version: "18.6.2", build: "22G100"),
            cloudOS: .init(version: "26.1", build: "23B85"),
        ).write(toBundle: b)

        let merged = try VPhoneRestoreInfo.recordVariant("exp", toBundle: b)
        #expect(merged?.variant == "exp")
        #expect(merged?.device == "iPhone17,3")

        let loaded = VPhoneRestoreInfo.load(fromBundle: b)
        #expect(loaded?.ios.build == "22G100")
        #expect(loaded?.variant == "exp")
        #expect(loaded?.device == "iPhone17,3")
    }

    @Test func `record variant nil without versions`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        #expect(try VPhoneRestoreInfo.recordVariant("jb", toBundle: b) == nil)
    }

    @Test func `normal boot rejects an explicit old variant but DFU still parses`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try b.manifest.write(to: b.configURL)
        try VPhoneRestoreInfo(
            ios: .init(version: "26.6.2", build: "23G90"),
            cloudOS: .init(version: "26.4", build: "23E5207q"),
            variant: "exp",
        ).write(toBundle: b)

        do {
            _ = try VPhoneBootCommand.parseAsRoot(["--config", b.configURL.path])
            Issue.record("Boot accepted an explicitly unsupported VM variant")
        } catch {
            #expect(String(describing: error).contains("Only JB VMs are supported"))
        }
        _ = try VPhoneBootCommand.parseAsRoot(["--config", b.configURL.path, "--dfu"])
    }

    @Test func `bundle report carries UDID`() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try "UDID=AAAABBBB-1122334455667788\n"
            .write(to: b.url.appendingPathComponent("udid-prediction.txt"), atomically: true, encoding: .utf8)
        #expect(VPhoneBundleReport(bundle: b).udid == "AAAABBBB-1122334455667788")
    }

    // MARK: - Links planted in the bundle

    @Test func `write replaces a planted restore-info link without writing through it`() throws {
        let b = try makeBundle()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: b.url)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("host file".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: VPhoneRestoreInfo.url(forBundle: b),
            withDestinationURL: outside,
        )
        // load() must not read through the link either.
        #expect(VPhoneRestoreInfo.load(fromBundle: b) == nil)

        let info = VPhoneRestoreInfo(
            ios: .init(version: "18.6.2", build: "22G100"),
            cloudOS: .init(version: "26.1", build: "23B85"),
        )
        try info.write(toBundle: b)

        #expect(try Data(contentsOf: outside) == Data("host file".utf8))
        var metadata = stat()
        #expect(lstat(VPhoneRestoreInfo.url(forBundle: b).path, &metadata) == 0)
        #expect(metadata.st_mode & S_IFMT == S_IFREG)
        #expect(VPhoneRestoreInfo.load(fromBundle: b) == info)
    }

    @Test func `a restore-tree link is neither followed nor removed`() throws {
        let b = try makeBundle()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: b.url)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appendingPathComponent("iPhone-BuildManifest.plist")
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["ProductVersion": "27.0", "ProductBuildVersion": "24A5390f"],
            format: .xml,
            options: 0,
        )
        try plist.write(to: kept)
        try plist.write(to: outside.appendingPathComponent("BuildManifest.plist"))
        let link = b.url.appendingPathComponent("iPhoneX_Restore")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(VPhoneRestoreInfo.derive(fromBundle: b) == nil)
        #expect(try VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: b) == nil)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func `remove built firmware removes a real tree without following links inside it`() throws {
        let b = try makeBundle()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: b.url)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: kept)
        try makeRestoreDir(
            in: b,
            iosVersion: "27.0",
            iosBuild: "24A5390f",
            cloudVersion: "26.4",
            cloudBuild: "23E5207q",
        )
        let restore = b.url.appendingPathComponent("iPhone17,3_27.0_24A5390f_Restore")
        try FileManager.default.createSymbolicLink(
            at: restore.appendingPathComponent("escape"),
            withDestinationURL: outside,
        )

        #expect(try VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: b) == "iPhone17,3_27.0_24A5390f_Restore")
        #expect(!FileManager.default.fileExists(atPath: restore.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func `version strings outside the allowed set are rejected`() throws {
        for bad in ["27.0; rm -rf /", "../27", "27.0\n", "", String(repeating: "9", count: 33), "２７.0"] {
            let b = try makeBundle()
            defer { try? FileManager.default.removeItem(at: b.url) }
            try makeRestoreDir(
                in: b,
                iosVersion: bad,
                iosBuild: "24A5390f",
                cloudVersion: "26.4",
                cloudBuild: "23E5207q",
            )
            #expect(VPhoneRestoreInfo.derive(fromBundle: b) == nil, "accepted \(bad.debugDescription)")
        }
        #expect(VPhoneRestoreInfo.isVersionToken("26.4"))
        #expect(VPhoneRestoreInfo.isVersionToken("23E5207q"))
    }

    /// The snapshot lives at the bundle root, so `vm export` must not strip it:
    /// it is matched by neither the `*_Restore*` exclude nor any regenerable-
    /// artifact pattern. Guards against a future exclude edit dropping it.
    @Test func `not excluded from export`() {
        let name = VPhoneRestoreInfo.fileName
        #expect(fnmatch("*_Restore*", name, 0) != 0)
        for pattern in VPhoneBundleOperations.exportExcludePatterns {
            #expect(fnmatch(pattern, name, 0) != 0)
        }
    }
}
