import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit
import VPhonePatchKit
import VPhoneSign

@Suite("Standalone debug and accessibility X1 installation")
struct CustomFirmwareArm64eX1InstallationTests {
    typealias Installation = CustomFirmwareArm64eX1Installation
    static let identifier = "system-libdispatch-cfw-arm64e_x1_introspection"
    static let bundle = "Library.framework"
    static let path = bundle + "/Library"
    static let seal = bundle + "/_CodeSignature/CodeResources"

    enum InjectedFailure: Error { case seal }

    /// Extend the lowering fixture with a real __LINKEDIT so the production
    /// signer, including identifier and entitlement preservation, is exercised.
    static func library(subtype: UInt32 = 0x8000_000C, fileType: UInt32 = 6, unvisited: Bool = false) -> Data {
        var (data, hashOffset) = CustomFirmwareArm64eX1Tests.signedFixture()
        data.replaceSubrange(8 ..< 24, with: ARM64.encodeU32(subtype) + ARM64.encodeU32(fileType)
            + ARM64.encodeU32(4) + ARM64.encodeU32(256))
        var segment = ARM64.encodeU32(0x19) + ARM64.encodeU32(72)
        segment += Data("__LINKEDIT".utf8) + Data(count: 6)
        for value in [0x1000, 0x1000, 0x400, UInt64(data.count - 0x400)] as [UInt64] {
            withUnsafeBytes(of: value.littleEndian) { segment.append(contentsOf: $0) }
        }
        for value in [1, 1, 0, 0] as [UInt32] { segment += ARM64.encodeU32(value) }
        data.replaceSubrange(216 ..< 288, with: segment)
        if subtype != 0x8000_000C {
            data.replaceSubrange(0x200 ..< 0x208, with: ARM64.pacibsp + ARM64.retab)
        }
        if unvisited {
            // A second, unreferenced PAC/return pair after the first return.
            // The strict path must refuse it instead of declaring success.
            data.replaceSubrange(144 ..< 152, with: Data([16, 0, 0, 0, 0, 0, 0, 0]))
            data.replaceSubrange(0x208 ..< 0x210, with: ARM64.encodeU32(CustomFirmwareArm64eX1Tests.pac)
                + ARM64.encodeU32(CustomFirmwareArm64eX1Tests.ret))
        }
        data.replaceSubrange(hashOffset ..< hashOffset + 32, with: Data(SHA256.hash(data: data.prefix(0x400))))
        return data
    }

    struct Fixture {
        let url: URL
        let system: VPhoneConfinedDirectory

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            system = try VPhoneConfinedDirectory(root: url.path)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }

        func write(_ data: Data, at path: String = SelfPath.path) throws {
            _ = try system.directory((path as NSString).deletingLastPathComponent, create: true)
            try system.writeFile(path, contents: data, mode: 0o555)
        }

        func update(
            enabled: Bool = true, priorApplied: Bool = false, bundle: String? = nil,
            seal: (String) throws -> Void = { _ in Issue.record("unexpected bundle signing") },
        ) throws -> Installation.Outcome {
            try Installation.update(
                system: system, identifier: SelfPath.identifier, path: SelfPath.path, bundle: bundle,
                enabled: enabled, priorApplied: priorApplied, sealBundle: seal, log: { _ in },
            )
        }

        private typealias SelfPath = CustomFirmwareArm64eX1InstallationTests
    }

    @Test func `missing optional libraries create no files`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.update() == .notApplicable)
        #expect(try fixture.update(enabled: false) == .inactive)
        #expect(try fixture.system.entries().isEmpty)
    }

    @Test(arguments: [UInt32(0), 0x8000_0002])
    func `ordinary libraries retain bytes signatures inodes and shared seals`(subtype: UInt32) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = Self.library(subtype: subtype)
        let seal = Data("shared original seal".utf8)
        try fixture.write(source)
        try fixture.write(seal, at: Self.seal)
        try FileManager.default.linkItem(at: fixture.url.appendingPathComponent(Self.path),
                                        to: fixture.url.appendingPathComponent("sibling-library"))
        try FileManager.default.linkItem(at: fixture.url.appendingPathComponent(Self.seal),
                                        to: fixture.url.appendingPathComponent("shared-seal"))
        let before = try #require(try fixture.system.status(Self.path))
        #expect(try fixture.update(bundle: Self.bundle) == .notApplicable)
        let after = try #require(try fixture.system.status(Self.path))
        #expect(after.st_ino == before.st_ino)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        #expect(after.st_nlink == 2)
        #expect(try fixture.system.readData(Self.path) == source)
        #expect(try fixture.system.readData(Self.seal) == seal)
        #expect(try fixture.system.status(Self.seal)?.st_nlink == 2)
        #expect(try !fixture.system.exists(Self.path + ".bak"))
    }

    @Test(arguments: [UInt32(6), 8])
    func `applying reapplying and disabling preserve the original and its entitlements`(fileType: UInt32) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = Self.library(fileType: fileType)
        try fixture.write(source)
        #expect(try fixture.update() == .applied)
        let patched = try fixture.system.readData(Self.path)
        #expect(patched != source)
        #expect(try fixture.system.readData(Self.path + ".bak") == source)
        #expect(try VPhoneSigner.identifier(in: patched) == VPhoneSigner.identifier(in: source))
        let entitlements = try #require(try VPhoneSigner.entitlements(in: patched).first)
        let plist = try PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Bool]
        #expect(plist?["platform-application"] == true)
        #expect((try fixture.system.status(Self.path)?.st_mode ?? 0) & 0o777 == 0o555)
        var again = patched
        #expect(try CustomFirmwareArm64eX1.lowerCompletelyAndReattest(&again, identifier: Self.identifier).result.records.isEmpty)
        #expect(again == patched)
        #expect(try fixture.update(priorApplied: true) == .applied)
        #expect(try fixture.system.readData(Self.path) == patched)
        #expect(try fixture.system.readData(Self.path + ".bak") == source)
        #expect(try fixture.update(enabled: false, priorApplied: true) == .inactive)
        #expect(try fixture.system.readData(Self.path) == source)
        #expect(try !fixture.system.exists(Self.path + ".bak"))
    }

    @Test func `partial universal conversion is rejected without publishing any slice`() throws {
        let incomplete = Self.library(unvisited: true)
        for source in [incomplete, CustomFirmwareArm64eX1Tests.universal(Self.library(), incomplete)] {
            var data = source
            #expect(throws: (any Error).self) {
                try CustomFirmwareArm64eX1.lowerCompletelyAndReattest(&data, identifier: Self.identifier)
            }
            #expect(data == source)
        }
    }

    @Test func `incomplete and malformed images fail before guest writes`() throws {
        for source in [Self.library(unvisited: true), Self.library(fileType: 8, unvisited: true), Data("truncated".utf8),
                       CustomFirmwareArm64eX1Tests.signedFixture().0] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(source)
            #expect(throws: (any Error).self) { try fixture.update(bundle: Self.bundle) }
            #expect(try fixture.system.readData(Self.path) == source)
            #expect(try !fixture.system.exists(Self.path + ".bak"))
            #expect(try !fixture.system.exists(Self.bundle + "/_CodeSignature"))
        }
    }

    @Test(arguments: [UInt32(6), 8])
    func `failed bundle signing restores the executable backup and shared resource bytes`(fileType: UInt32) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = Self.library(fileType: fileType), originalSeal = Data("original seal".utf8)
        try fixture.write(source)
        try fixture.write(originalSeal, at: Self.seal)
        try FileManager.default.linkItem(at: fixture.url.appendingPathComponent(Self.seal),
                                        to: fixture.url.appendingPathComponent("shared-seal"))
        #expect(throws: InjectedFailure.self) {
            try fixture.update(bundle: Self.bundle) { bundle in
                #expect(bundle == Self.bundle)
                #expect(try fixture.system.readData(Self.path + ".bak") == source)
                // Model codesign rewriting both files after the shared seal
                // has been detached by the installer's sealing helper.
                try fixture.system.writeFile(Self.seal, contents: Data("new seal".utf8), mode: 0o644)
                try fixture.system.writeFile(Self.path, contents: Data("partial signature".utf8), mode: 0o755)
                throw InjectedFailure.seal
            }
        }
        #expect(try fixture.system.readData(Self.path) == source)
        #expect(try fixture.system.readData(Self.seal) == originalSeal)
        #expect(try fixture.system.readData("shared-seal") == originalSeal)
        #expect(try !fixture.system.exists(Self.path + ".bak"))
    }

    @Test func `failed reapplication and rollback retain the prior live state and original backup`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = Self.library(), liveSeal = Data("live seal".utf8)
        try fixture.write(source)
        try fixture.write(liveSeal, at: Self.seal)
        #expect(try fixture.update() == .applied)
        let patched = try fixture.system.readData(Self.path)
        for enabled in [true, false] {
            #expect(throws: InjectedFailure.self) {
                try fixture.update(enabled: enabled, priorApplied: true, bundle: Self.bundle) { _ in
                    #expect(try fixture.system.exists(Self.path + ".bak") == enabled)
                    try fixture.system.writeFile(Self.seal, contents: Data("incomplete seal".utf8), mode: 0o644)
                    throw InjectedFailure.seal
                }
            }
            #expect(try fixture.system.readData(Self.path) == patched)
            #expect(try fixture.system.readData(Self.path + ".bak") == source)
            #expect(try fixture.system.readData(Self.seal) == liveSeal)
        }
        let reverted = try fixture.update(enabled: false, priorApplied: true, bundle: Self.bundle) { _ in
            let backupExists = try fixture.system.exists(Self.path + ".bak")
            #expect(!backupExists)
        }
        #expect(reverted == .inactive)
        #expect(try fixture.system.readData(Self.path) == source)
    }

    @Test func `a prior patch without its backup is never backed up as pristine`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.library())
        #expect(try fixture.update() == .applied)
        let patched = try fixture.system.readData(Self.path)
        try fixture.system.removeItem(Self.path + ".bak")
        for enabled in [false, true] {
            #expect(try fixture.update(enabled: enabled, priorApplied: true) == .notRevertible)
            #expect(try fixture.system.readData(Self.path) == patched)
            #expect(try !fixture.system.exists(Self.path + ".bak"))
        }
    }

    @Test func `failure to restore the previous state must abort the enclosing installation`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.library())
        #expect(throws: Installation.RollbackFailure.self) {
            try fixture.update(bundle: Self.bundle) { _ in
                // Make the prior file impossible to restore by rename. Reporting
                // an ordinary isolated failure here would leave a false receipt.
                try fixture.system.removeItem(Self.path)
                _ = try fixture.system.directory(Self.path, create: true)
                throw InjectedFailure.seal
            }
        }
    }
}
