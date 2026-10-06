import Darwin
import Foundation

// The helper's store source is compiled into this test binary with a temporary
// parent and the current UID. The production helper never sees those switches.
struct VPhoneLaunchpadHelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct UnattendedGrantTests {
    static func main() throws {
        let parent = ProcessInfo.processInfo.environment["VPHONE_GRANT_TEST_PARENT"]!
        let directory = parent + "/UnattendedVMManagement"
        let first: uid_t = 1001
        let second: uid_t = 1002
        let grant = directory + "/uid-1001.json"

        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "missing grant")
        try VPhoneLaunchpadHelperUnattendedGrant.enable(for: first)
        check(VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "grant active")
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: second), "UID isolation")
        var info = stat()
        check(lstat(grant, &info) == 0 && info.st_mode & 0o777 == 0o600, "grant mode")

        check(chmod(grant, 0o644) == 0, "make unsafe mode")
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "world-readable grant refused")
        expectThrows("unsafe mode cannot be renewed") { try VPhoneLaunchpadHelperUnattendedGrant.enable(for: first) }
        check(chmod(grant, 0o600) == 0, "restore mode")

        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: grant))
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: Data("corrupt".utf8))
        try file.close()
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "corrupt grant refused")
        let forged = try FileHandle(forWritingTo: URL(fileURLWithPath: grant))
        try forged.truncate(atOffset: 0)
        try forged.write(contentsOf: Data(#"{"schema":1,"uid":1002,"scope":"vm-management"}"#.utf8))
        try forged.close()
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "record UID must match peer")
        try VPhoneLaunchpadHelperUnattendedGrant.enable(for: first)
        check(VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "fresh enrollment repairs corrupt record")

        try VPhoneLaunchpadHelperUnattendedGrant.disable(for: first)
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "revoked grant")
        let target = parent + "/untouched"
        try Data("safe".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: grant, withDestinationPath: target)
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "symlink refused")
        expectThrows("symlink cannot be renewed") { try VPhoneLaunchpadHelperUnattendedGrant.enable(for: first) }
        expectThrows("symlink cannot be revoked through") { try VPhoneLaunchpadHelperUnattendedGrant.disable(for: first) }
        expectThrows("symlink blocks uninstall cleanup") { try VPhoneLaunchpadHelperUnattendedGrant.removeAllForHelperUninstall() }
        try check(String(contentsOfFile: target, encoding: .utf8) == "safe", "symlink target untouched")
        try FileManager.default.removeItem(atPath: grant)

        try VPhoneLaunchpadHelperUnattendedGrant.enable(for: first)
        try VPhoneLaunchpadHelperUnattendedGrant.enable(for: second)
        let unexpected = directory + "/other"
        try Data().write(to: URL(fileURLWithPath: unexpected))
        expectThrows("unexpected entry blocks uninstall cleanup") { try VPhoneLaunchpadHelperUnattendedGrant.removeAllForHelperUninstall() }
        try FileManager.default.removeItem(atPath: unexpected)
        try VPhoneLaunchpadHelperUnattendedGrant.removeAllForHelperUninstall()
        check(!FileManager.default.fileExists(atPath: directory), "uninstall removes directory")
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "uninstall revokes first UID")
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: second), "uninstall revokes second UID")

        let external = parent + "/external"
        try FileManager.default.createDirectory(atPath: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: directory, withDestinationPath: external)
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "symlinked store refused")
        expectThrows("symlinked store cannot be enrolled") { try VPhoneLaunchpadHelperUnattendedGrant.enable(for: first) }
        try FileManager.default.removeItem(atPath: directory)
        try FileManager.default.createSymbolicLink(atPath: directory, withDestinationPath: parent + "/missing")
        check(!VPhoneLaunchpadHelperUnattendedGrant.enabled(for: first), "dangling store symlink refused")
        expectThrows("dangling store symlink cannot be revoked through") { try VPhoneLaunchpadHelperUnattendedGrant.disable(for: first) }
        print("UnattendedGrantTests passed")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        guard try condition() else { fatalError(label) }
    }

    private static func expectThrows(_ label: String, _ operation: () throws -> Void) {
        do {
            try operation()
            fatalError(label)
        } catch {}
    }
}
