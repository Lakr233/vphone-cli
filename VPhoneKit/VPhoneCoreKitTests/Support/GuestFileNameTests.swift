import Foundation
import Testing
@testable import VPhoneCoreKit

struct GuestFileNameTests {
    // MARK: - Names

    @Test func `path-like names are rejected`() {
        for name in ["..", ".", "a/b", "../x", "", "a\u{0}b", "/", "x/", String(repeating: "a", count: 256)] {
            #expect(!VPhoneGuestFileName.isSafe(name), "\(name.debugDescription)")
        }
    }

    @Test func `plain names are accepted`() {
        #expect(VPhoneGuestFileName.isSafe("ok.txt"))
        #expect(VPhoneGuestFileName.isSafe(".hidden"))
        #expect(VPhoneGuestFileName.isSafe("..."))
        #expect(VPhoneGuestFileName.isSafe(String(repeating: "a", count: 255)))
    }

    // MARK: - Files

    @Test func `writeNewFile writes inside the directory`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try VPhoneHostDownloadDirectory(url: root)
        let url = try directory.writeNewFile(named: "ok.txt", data: Data("new".utf8))
        #expect(url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
    }

    @Test func `writeNewFile refuses unsafe names`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try VPhoneHostDownloadDirectory(url: root)
        #expect(throws: POSIXError.self) {
            try directory.writeNewFile(named: "../escape", data: Data("x".utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    @Test func `writeNewFile refuses an existing file`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("x")
        try Data("old".utf8).write(to: existing)
        let directory = try VPhoneHostDownloadDirectory(url: root)
        #expect(throws: POSIXError.self) {
            try directory.writeNewFile(named: "x", data: Data("new".utf8))
        }
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
    }

    @Test func `writeNewFile refuses an existing symlink`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: inner.appendingPathComponent("link"), withDestinationURL: target)
        let directory = try VPhoneHostDownloadDirectory(url: inner)
        #expect(throws: POSIXError.self) {
            try directory.writeNewFile(named: "link", data: Data("new".utf8))
        }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }

    @Test func `writeUniqueFile numbers a taken name`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appendingPathComponent("report.ips"))
        let directory = try VPhoneHostDownloadDirectory(url: root)
        let url = try directory.writeUniqueFile(named: "report.ips", data: Data("new".utf8))
        #expect(url.lastPathComponent == "report 2.ips")
        #expect(try Data(contentsOf: root.appendingPathComponent("report.ips")) == Data("old".utf8))
    }

    // MARK: - Directories

    @Test func `makeSubdirectory creates and reuses a real directory`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try VPhoneHostDownloadDirectory(url: root)
        let first = try directory.makeSubdirectory(named: "sub")
        _ = try first.writeNewFile(named: "a", data: Data("a".utf8))
        let again = try directory.makeSubdirectory(named: "sub")
        _ = try again.writeNewFile(named: "b", data: Data("b".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sub").path).sorted()
        #expect(names == ["a", "b"])
    }

    @Test func `makeSubdirectory refuses a symlink entry`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: inner.appendingPathComponent("sub"), withDestinationURL: outside)
        let directory = try VPhoneHostDownloadDirectory(url: inner)
        #expect(throws: POSIXError.self) {
            try directory.makeSubdirectory(named: "sub")
        }
        #expect(throws: POSIXError.self) {
            try directory.makeSubdirectory(named: "..")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func `makeTemporary creates a fresh private directory`() throws {
        let directory = try VPhoneHostDownloadDirectory.makeTemporary()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    // MARK: - Helpers

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuestFileNameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
