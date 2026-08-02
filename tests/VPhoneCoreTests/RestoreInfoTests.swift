@testable import VPhoneCore
import Foundation
import Testing

struct RestoreInfoTests {
    private func makeBundle() throws -> VPhoneBundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 1024 * 1024, romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        return VPhoneBundle(url: root, manifest: manifest)
    }

    /// Write a restore dir with the two BuildManifest plists. Omit a key by
    /// passing nil for its value to exercise the missing-key path.
    private func makeRestoreDir(
        in bundle: VPhoneBundle, iosVersion: String?, iosBuild: String?,
        cloudVersion: String?, cloudBuild: String?
    ) throws {
        let dir = bundle.url.appendingPathComponent("iPhone17,3_27.0_24A5390f_Restore")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ version: String?, _ build: String?) throws {
            var dict: [String: Any] = [:]
            if let version { dict["ProductVersion"] = version }
            if let build { dict["ProductBuildVersion"] = build }
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent(name))
        }
        try write("iPhone-BuildManifest.plist", iosVersion, iosBuild)
        try write("BuildManifest.plist", cloudVersion, cloudBuild)
    }

    @Test func derivesBothVersionsFromPlists() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(in: b, iosVersion: "27.0", iosBuild: "24A5390f",
                           cloudVersion: "26.4", cloudBuild: "23E5207q")
        let info = VPhoneRestoreInfo.derive(fromBundle: b)
        #expect(info?.ios == .init(version: "27.0", build: "24A5390f"))
        #expect(info?.cloudOS == .init(version: "26.4", build: "23E5207q"))
    }

    @Test func deriveNilWhenNoRestoreDir() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        #expect(VPhoneRestoreInfo.derive(fromBundle: b) == nil)
    }

    @Test func deriveNilWhenVersionKeyMissing() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(in: b, iosVersion: "27.0", iosBuild: "24A5390f",
                           cloudVersion: nil, cloudBuild: "23E5207q")
        #expect(VPhoneRestoreInfo.derive(fromBundle: b) == nil)
    }

    @Test func writeThenLoadRoundTrips() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        let info = VPhoneRestoreInfo(
            ios: .init(version: "18.6.2", build: "22G100"),
            cloudOS: .init(version: "26.1", build: "23B85"))
        try info.write(toBundle: b)
        #expect(VPhoneRestoreInfo.load(fromBundle: b) == info)
    }

    @Test func loadFallsBackToDeriveWhenNoJSON() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(in: b, iosVersion: "27.0", iosBuild: "24A5390f",
                           cloudVersion: "26.4", cloudBuild: "23E5207q")
        // No restore-info.json written — load() must derive from the plists.
        let info = VPhoneRestoreInfo.load(fromBundle: b)
        #expect(info?.ios.version == "27.0")
        #expect(info?.cloudOS.version == "26.4")
    }

    @Test func bundleReportCarriesRestoreInfo() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try makeRestoreDir(in: b, iosVersion: "27.0", iosBuild: "24A5390f",
                           cloudVersion: "26.4", cloudBuild: "23E5207q")
        let report = VPhoneBundleReport(bundle: b)
        #expect(report.restoreInfo?.ios.build == "24A5390f")
        #expect(report.restoreInfo?.cloudOS.build == "23E5207q")
    }

    @Test func deviceForVariant() {
        #expect(VPhoneRestoreInfo.device(forVariant: "exp") == "iPhone17,3")
        for v in ["regular", "dev", "jb"] {
            #expect(VPhoneRestoreInfo.device(forVariant: v) == "iPhone99,11")
        }
    }

    @Test func recordVariantMergesIntoVersions() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try VPhoneRestoreInfo(
            ios: .init(version: "18.6.2", build: "22G100"),
            cloudOS: .init(version: "26.1", build: "23B85")).write(toBundle: b)

        let merged = try VPhoneRestoreInfo.recordVariant("exp", toBundle: b)
        #expect(merged?.variant == "exp")
        #expect(merged?.device == "iPhone17,3")

        let loaded = VPhoneRestoreInfo.load(fromBundle: b)
        #expect(loaded?.ios.build == "22G100")
        #expect(loaded?.variant == "exp")
        #expect(loaded?.device == "iPhone17,3")
    }

    @Test func recordVariantNilWithoutVersions() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        #expect(try VPhoneRestoreInfo.recordVariant("jb", toBundle: b) == nil)
    }

    @Test func bundleReportCarriesUDID() throws {
        let b = try makeBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        try "UDID=AAAABBBB-1122334455667788\n"
            .write(to: b.url.appendingPathComponent("udid-prediction.txt"), atomically: true, encoding: .utf8)
        #expect(VPhoneBundleReport(bundle: b).udid == "AAAABBBB-1122334455667788")
    }

    /// The snapshot lives at the bundle root, so `vm export` must not strip it:
    /// it is matched by neither the `*_Restore*` exclude nor any regenerable-
    /// artifact pattern. Guards against a future exclude edit dropping it.
    @Test func notExcludedFromExport() throws {
        let name = VPhoneRestoreInfo.fileName
        #expect(fnmatch("*_Restore*", name, 0) != 0)
        for pattern in VPhoneBundleOps.exportExcludePatterns {
            #expect(fnmatch(pattern, name, 0) != 0)
        }
    }
}
