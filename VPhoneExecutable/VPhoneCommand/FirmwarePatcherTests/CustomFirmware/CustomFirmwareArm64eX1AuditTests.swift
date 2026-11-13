@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Read-only standalone X1 audit")
struct CustomFirmwareArm64eX1AuditTests {
    typealias Installation = CustomFirmwareArm64eX1InstallationTests

    @Test func `discovery finds an unlisted plug-in without modifying bytes metadata or backups`() throws {
        let fixture = try Installation.Fixture()
        defer { fixture.remove() }
        let path = "System/Library/NewFeature.bundle/UnlistedPlugin"
        let source = Installation.library(fileType: 8)
        try fixture.write(source, at: path)
        try fixture.write(source, at: path + ".bak")
        try fixture.write(source, at: "Saved.bundle.bak/UnlistedPlugin")
        // APFS System volumes include an unreadable zero-byte .file marker.
        // It cannot contain a Mach-O header and should not require read access.
        try fixture.write(Data(), at: "Images/Empty")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url.appendingPathComponent("Images/Empty").path)
        try FileManager.default.createSymbolicLink(at: fixture.url.appendingPathComponent("alias"),
                                                  withDestinationURL: fixture.url.appendingPathComponent(path))
        let before = try #require(try fixture.system.status(path))
        let report = try CustomFirmwareArm64eX1Audit.scan(root: fixture.url)
        let image = try #require(report.images.only)
        #expect(image.path == path)
        #expect(image.state == .needsLowering)
        #expect(image.instructions == 2)
        #expect(image.unvisitedCandidates == 0)
        #expect(image.declarations.isEmpty)
        #expect(report.skippedBackups == 2)
        #expect(report.failures.isEmpty)
        #expect(report.needsAttention)
        #expect(try fixture.system.readData(path) == source)
        #expect(try fixture.system.readData(path + ".bak") == source)
        let after = try #require(try fixture.system.status(path))
        #expect(after.st_ino == before.st_ino)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
    }

    @Test func `a declaration does not hide remaining instructions and a lowered image keeps its X1 header`() throws {
        let fixture = try Installation.Fixture()
        defer { fixture.remove() }
        let image = try #require(FirmwareGuestSystemPatchSet.arm64eX1AccessibilityImages.first {
            $0.identifier == "system-uikitpopaccessibility-cfw-arm64e_x1"
        })
        var source = Installation.library(fileType: 8)
        try fixture.write(source, at: image.path)
        let before = try CustomFirmwareArm64eX1Audit.scan(root: fixture.url)
        #expect(before.images.only?.declarations == [image.identifier])
        #expect(before.images.only?.state == .needsLowering)
        _ = try CustomFirmwareArm64eX1.lowerCompletelyAndReattest(&source, identifier: image.identifier)
        try fixture.write(source, at: image.path)
        let after = try CustomFirmwareArm64eX1Audit.scan(root: fixture.url)
        #expect(after.images.only?.state == .noLoweringNeeded)
        #expect(!after.needsAttention)
    }

    @Test func `incomplete and failed analysis cannot produce a clean audit`() throws {
        let fixture = try Installation.Fixture()
        defer { fixture.remove() }
        let incomplete = Installation.library(fileType: 8, unvisited: true)
        try fixture.write(incomplete, at: "Images/Incomplete")
        var failed = Installation.library(fileType: 8)
        // Remove SHA-256 coverage while retaining executable X1 code.
        failed.replaceSubrange((failed.count - 1)..<failed.count, with: Data())
        try fixture.write(failed, at: "Images/Truncated")
        // The permissive research parser would otherwise return no sections
        // for a truncated command table and incorrectly appear clean.
        let headerOnly = Data(Installation.library(fileType: 8).prefix(32))
        try fixture.write(headerOnly, at: "Images/HeaderOnly")
        let fat = CustomFirmwareArm64eX1Tests.universal(headerOnly, Installation.library(subtype: 0x8000_0002))
        try fixture.write(fat, at: "Images/TruncatedFat")
        let report = try CustomFirmwareArm64eX1Audit.scan(root: fixture.url)
        #expect(report.images.first { $0.path == "Images/Incomplete" }?.state == .incomplete)
        #expect(report.images.first { $0.path == "Images/Truncated" }?.state == .failed)
        #expect(report.images.first { $0.path == "Images/HeaderOnly" }?.state == .failed)
        #expect(report.images.first { $0.path == "Images/TruncatedFat" }?.state == .failed)
        #expect(report.needsAttention)
        #expect(try fixture.system.readData("Images/Incomplete") == incomplete)
        #expect(try fixture.system.readData("Images/Truncated") == failed)
    }

    @Test func `universal images are inspected and executable scanning is explicit`() throws {
        let fixture = try Installation.Fixture()
        defer { fixture.remove() }
        let fat = CustomFirmwareArm64eX1Tests.universal(Installation.library(fileType: 8), Installation.library(subtype: 0x8000_0002))
        try fixture.write(fat, at: "Images/FatPlugin")
        try fixture.write(Installation.library(fileType: 2), at: "Images/Program")
        try fixture.write(Installation.library(fileType: 11), at: "Images/KernelExtension")
        try fixture.write(Installation.library(subtype: 0x8000_0002), at: "Images/Ordinary")
        let libraries = try CustomFirmwareArm64eX1Audit.scan(root: fixture.url)
        #expect(libraries.images.only?.path == "Images/FatPlugin")
        #expect(libraries.images.only?.state == .needsLowering)
        let all = try CustomFirmwareArm64eX1Audit.scan(root: fixture.url, includeExecutables: true)
        #expect(Set(all.images.map(\.path)) == ["Images/FatPlugin", "Images/Program"])
        #expect(all.failures.isEmpty)
        #expect(try fixture.system.readData("Images/FatPlugin") == fat)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
