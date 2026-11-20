import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct HostFilePermissionsTests {
    @Test func `VM outputs become 0777 without following symlinks`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = base.appendingPathComponent("VM")
        let nested = vm.appendingPathComponent("Firmware")
        let disk = vm.appendingPathComponent("Disk.img")
        let image = nested.appendingPathComponent("image")
        let outside = base.appendingPathComponent("outside")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: disk)
        try Data("image".utf8).write(to: image)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: vm.appendingPathComponent("link"),
            withDestinationURL: outside,
        )
        for path in [vm, nested, disk, image, outside] {
            #expect(chmod(path.path, 0o700) == 0)
        }

        try VPhoneHostFilePermissions.makeAccessible(at: vm)
        for path in [vm, nested, disk, image] {
            var info = stat()
            #expect(stat(path.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o777)
        }
        var outsideInfo = stat()
        #expect(stat(outside.path, &outsideInfo) == 0)
        #expect(outsideInfo.st_mode & 0o777 == 0o700)
    }

    // MARK: - Hard links and symlinked directories

    @Test func `Only an entry not exactly 0777 that this process may change is changed`() {
        func entry(_ mode: mode_t, owner: uid_t) -> stat {
            var metadata = stat()
            metadata.st_mode = S_IFREG | mode
            metadata.st_uid = owner
            return metadata
        }
        let me = geteuid()
        #expect(VPhoneHostFilePermissions.needsModeChange(entry(0o644, owner: me)))
        #expect(!VPhoneHostFilePermissions.needsModeChange(entry(0o777, owner: me)))
        // A setuid, setgid or sticky bit is cleared, so the entry still changes.
        #expect(VPhoneHostFilePermissions.needsModeChange(entry(0o4777, owner: me)))
        #expect(VPhoneHostFilePermissions.needsModeChange(entry(0o1777, owner: me)))
        // Without root, another account's entry is left to the kernel's checks.
        let other = me == 0 ? 501 : me &+ 1
        #expect(VPhoneHostFilePermissions.needsModeChange(entry(0o644, owner: other)) == (me == 0))
        #expect(!VPhoneHostFilePermissions.needsModeChange(entry(0o777, owner: other)))
    }

    @Test func `A hard link into the tree keeps the linked file's mode`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = base.appendingPathComponent("VM")
        let disk = vm.appendingPathComponent("Disk.img")
        let outside = base.appendingPathComponent("host-file")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: disk)
        try Data("host".utf8).write(to: outside)
        #expect(link(outside.path, vm.appendingPathComponent("linked").path) == 0)
        #expect(chmod(disk.path, 0o600) == 0)
        #expect(chmod(outside.path, 0o600) == 0)

        try VPhoneHostFilePermissions.makeAccessible(at: vm)
        #expect(mode(of: disk) == 0o777)
        #expect(mode(of: outside) == 0o600)
    }

    @Test func `A symlinked directory is not descended into`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = base.appendingPathComponent("VM")
        let outside = base.appendingPathComponent("outside")
        let outsideFile = outside.appendingPathComponent("secret")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: vm.appendingPathComponent("Firmware"),
            withDestinationURL: outside,
        )
        #expect(chmod(outsideFile.path, 0o600) == 0)
        #expect(chmod(outside.path, 0o700) == 0)

        try VPhoneHostFilePermissions.makeAccessible(at: vm)
        #expect(mode(of: vm) == 0o777)
        #expect(mode(of: outside) == 0o700)
        #expect(mode(of: outsideFile) == 0o600)
    }

    @Test func `A directory named through a symlink is left as it is`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let relocated = base.appendingPathComponent("relocated")
        let link = base.appendingPathComponent("ipsws")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: relocated)
        #expect(chmod(relocated.path, 0o700) == 0)

        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: link)
        #expect(mode(of: relocated) == 0o700)
    }

    @Test func `Root accepts only a symlink it or the sudo invoker owns`() {
        // Without root the kernel's own checks apply, so any link is accepted.
        #expect(VPhoneHostFilePermissions.acceptsLink(owner: 502, permittedOwners: nil))
        #expect(VPhoneHostFilePermissions.acceptsLink(owner: 0, permittedOwners: [0, 501]))
        #expect(VPhoneHostFilePermissions.acceptsLink(owner: 501, permittedOwners: [0, 501]))
        #expect(!VPhoneHostFilePermissions.acceptsLink(owner: 502, permittedOwners: [0, 501]))
    }

    @Test func `The walk visits only single-link files and real directories`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = base.appendingPathComponent("VM")
        let nested = vm.appendingPathComponent("Firmware")
        let image = nested.appendingPathComponent("image")
        let outside = base.appendingPathComponent("outside")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: image)
        try Data("host".utf8).write(to: outside.appendingPathComponent("file"))
        #expect(link(
            outside.appendingPathComponent("file").path,
            nested.appendingPathComponent("linked").path,
        ) == 0)
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("escape"),
            withDestinationURL: outside,
        )
        #expect(mkfifo(vm.appendingPathComponent("fifo").path, 0o600) == 0)

        var visited: Set<ino_t> = []
        try VPhoneHostFilePermissions.walkTree(
            at: vm,
            admits: { _ in true },
            visit: { _, metadata in visited.insert(metadata.st_ino) },
        )
        #expect(visited == Set([vm, nested, image].map(inode(of:))))
    }

    private func mode(of url: URL) -> mode_t {
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        return info.st_mode & 0o777
    }

    private func inode(of url: URL) -> ino_t {
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        return info.st_ino
    }
}
