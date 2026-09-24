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
}
