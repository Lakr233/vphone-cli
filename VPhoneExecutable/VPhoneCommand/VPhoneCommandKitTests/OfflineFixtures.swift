import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
import VPhoneRestore
@testable import VPhoneArchiveKit
@testable import VPhoneCommandKit
@testable import VPhoneCoreKit

/// Fixtures shared by the offline CommandKit tests: IPSW archives that hold
/// only a BuildManifest, and a template library built without a restore.
enum OfflineFixtures {
    static let fixtureIOS = VPhoneRestoreInfo.OSVersion(version: "27.0", build: "24A435")
    static let fixtureCloudOS = VPhoneRestoreInfo.OSVersion(version: "26.4", build: "23E5207q")

    /// An IPSW at `directory/name` whose BuildManifest says `version`/`build`,
    /// covers `productTypes` and has one build identity per device class.
    @discardableResult
    static func writeIPSW(
        in directory: URL,
        name: String,
        version: String,
        build: String,
        productTypes: [String] = [],
        deviceClasses: [String] = [],
        files: [String: Data] = [:],
    ) throws -> URL {
        let fm = FileManager.default
        let staging = directory.appendingPathComponent(".ipsw-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let manifest: [String: Any] = [
            "ProductVersion": version,
            "ProductBuildVersion": build,
            "SupportedProductTypes": productTypes,
            "BuildIdentities": deviceClasses.map { ["Info": ["DeviceClass": $0]] },
        ]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: staging.appendingPathComponent("BuildManifest.plist"))
        for (path, data) in files {
            let file = staging.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let archive = directory.appendingPathComponent(name)
        try VPhoneArchiveWriter.create(archive: archive, from: staging)
        return archive
    }

    /// An iPhone IPSW for iPhone17,3 and a cloudOS IPSW, in `directory`.
    static func writePair(
        in directory: URL,
        ios: VPhoneRestoreInfo.OSVersion = fixtureIOS,
        cloudOS: VPhoneRestoreInfo.OSVersion = fixtureCloudOS,
        phoneProducts: [String] = ["iPhone17,3"],
    ) throws -> (phone: URL, cloud: URL) {
        let phone = try writeIPSW(
            in: directory, name: "phone.ipsw", version: ios.version, build: ios.build,
            productTypes: phoneProducts, deviceClasses: ["d47ap"],
        )
        let cloud = try writeIPSW(
            in: directory, name: "cloud.ipsw", version: cloudOS.version, build: cloudOS.build,
            productTypes: ["ComputeModule14,2"], deviceClasses: [VPhoneIPSWCache.cloudOSDeviceClass],
        )
        return (phone, cloud)
    }

    /// A boot-ROM image `VPhoneBootROM.kind` takes for OpenAVB, and a SEP ROM.
    static func writeROMs(in directory: URL) throws -> (rom: URL, seprom: URL) {
        let rom = directory.appendingPathComponent("OpenAVB.bin")
        try Data("OpenBootROM: fixture".utf8).write(to: rom)
        let seprom = directory.appendingPathComponent("sep.bin")
        try Data([0x5E, 0x9]).write(to: seprom)
        return (rom, seprom)
    }

    /// The boot-chain patches the standard plan wants for the fixture
    /// versions, with their receipt part.
    static func wantedBootChain() throws -> [(identifier: String, part: String)] {
        let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
        let plan = try VPhoneMachineTemplateKeys.plan(
            preset: preset, iOSVersion: fixtureIOS.version, cloudOSVersion: fixtureCloudOS.version,
        )
        return FirmwarePatchSetCatalog.allDeclarations.compactMap { declaration in
            guard case .firmware = declaration.target, plan.enabled.contains(declaration.identifier) else { return nil }
            return (declaration.identifier, VPhoneVirtualMachinePatchReceipt.part(for: declaration.target))
        }
    }
}
