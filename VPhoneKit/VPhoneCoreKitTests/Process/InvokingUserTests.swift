import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct InvokingUserTests {
    private let user = VPhoneInvokingUser(
        uid: getuid(),
        gid: getgid(),
        home: FileManager.default.homeDirectoryForCurrentUser,
    )

    // MARK: - restoreOwnership

    /// An unreadable directory reached only through a symlink would fail the
    /// walk with EACCES if it were opened. It must never be.
    @Test func `Ownership walk skips hard links and symlinked directories`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = base.appendingPathComponent("VM")
        let nested = vm.appendingPathComponent("Firmware")
        let outside = base.appendingPathComponent("outside")
        let hostFile = base.appendingPathComponent("host-file")
        defer {
            chmod(outside.path, 0o700)
            try? FileManager.default.removeItem(at: base)
        }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: nested.appendingPathComponent("image"))
        try Data("host".utf8).write(to: hostFile)
        #expect(link(hostFile.path, vm.appendingPathComponent("linked").path) == 0)
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("escape"),
            withDestinationURL: outside,
        )
        #expect(chmod(outside.path, 0) == 0)

        try user.restoreOwnership(at: vm)
    }

    @Test func `Ownership walk ignores a missing path and a symlinked root`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = base.appendingPathComponent("outside")
        let vm = base.appendingPathComponent("VM")
        defer {
            chmod(outside.path, 0o700)
            try? FileManager.default.removeItem(at: base)
        }

        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: vm, withDestinationURL: outside)
        #expect(chmod(outside.path, 0) == 0)

        try user.restoreOwnership(at: base.appendingPathComponent("missing"))
        try user.restoreOwnership(at: vm)
        try user.restoreOwnerOfDirectory(at: vm)
        try user.restoreOwnerOfDirectory(at: base.appendingPathComponent("missing"))
    }
}
