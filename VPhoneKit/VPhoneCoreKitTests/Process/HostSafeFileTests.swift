import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct HostSafeFileTests {
    @Test(arguments: ["", ".", "..", "a/b", "/", "x\u{0}y"])
    func `unsafe guest names are rejected`(name: String) {
        #expect(!VPhoneHostSafeFile.isSafeName(name))
    }

    @Test(arguments: ["file.txt", ".hidden", "...", "a b"])
    func `plain names are accepted`(name: String) {
        #expect(VPhoneHostSafeFile.isSafeName(name))
    }

    @Test func `writes replace a planted symlink instead of following it`() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("out").path, withDestinationPath: victim.path)

        let fd = try VPhoneHostSafeFile.openDestination(dir)
        defer { close(fd) }
        try await VPhoneHostSafeFile.write(named: "out", in: fd) { try $0.write(contentsOf: Data("new".utf8)) }

        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
        #expect(try String(contentsOf: dir.appendingPathComponent("out"), encoding: .utf8) == "new")
        #expect(throws: POSIXError.self) { try VPhoneHostSafeFile.makeDirectory(named: "..", in: fd) }
    }

    @Test func `directory creation refuses a symlink in the way`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("sub").path, withDestinationPath: "/tmp")

        let fd = try VPhoneHostSafeFile.openDestination(dir)
        defer { close(fd) }
        #expect(throws: POSIXError.self) { try VPhoneHostSafeFile.makeDirectory(named: "sub", in: fd) }
        let made = try VPhoneHostSafeFile.makeDirectory(named: "real", in: fd)
        close(made)
    }
}
