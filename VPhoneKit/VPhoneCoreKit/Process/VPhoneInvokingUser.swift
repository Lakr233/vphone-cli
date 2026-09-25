import Darwin
import Foundation

/// The account that invoked a Command process through sudo. Root-owned guest files
/// inside Disk.img are unaffected; this only touches host filesystem paths.
public struct VPhoneInvokingUser: Sendable {
    public let uid: uid_t
    public let gid: gid_t
    public let home: URL

    public static var current: VPhoneInvokingUser? {
        guard geteuid() == 0,
              let uidText = ProcessInfo.processInfo.environment["SUDO_UID"],
              let gidText = ProcessInfo.processInfo.environment["SUDO_GID"],
              let uid = uid_t(uidText), let gid = gid_t(gidText),
              uid != 0, let account = getpwuid(uid), let directory = account.pointee.pw_dir
        else { return nil }
        return VPhoneInvokingUser(uid: uid, gid: gid, home: URL(fileURLWithPath: String(cString: directory)))
    }

    // MARK: - Ownership

    /// Restore the owner of root-created files while preserving their modes.
    /// Never use 0777: it would expose firmware, VM disks and credentials to
    /// every local account.
    ///
    /// The tree may be writable by other accounts, so the walk is descriptor
    /// relative (`VPhoneHostFilePermissions.walkTree`): symlinks, special
    /// files, other devices and regular files with more than one link are
    /// skipped, and ownership changes only through `fchown` on a descriptor
    /// verified to be the listed inode. A hard link to a root-owned host file,
    /// or a directory swapped for a symlink mid-walk, is never handed over.
    public func restoreOwnership(at url: URL) throws {
        try VPhoneHostFilePermissions.walkTree(
            at: url,
            admits: { _ in true },
            visit: { descriptor, metadata in
                if metadata.st_uid == 0, fchown(descriptor, uid, gid) != 0 {
                    throw VPhoneHostFilePermissions.currentError()
                }
            },
        )
    }

    public func restoreOwnerOfDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            // Missing, a symlink, or not a directory: leave it alone.
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR {
                return
            }
            throw VPhoneHostFilePermissions.currentError()
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw VPhoneHostFilePermissions.currentError()
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return }
        if metadata.st_uid == 0, fchown(descriptor, uid, gid) != 0 {
            throw VPhoneHostFilePermissions.currentError()
        }
    }
}
