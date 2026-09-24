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

    /// Restore the owner of root-created files while preserving their modes.
    /// Never use 0777: it would expose firmware, VM disks and credentials to
    /// every local account. lstat/lchown avoid following symlinks out of the
    /// caller's VM directory or cache.
    public func restoreOwnership(at url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if (metadata.st_mode & S_IFMT) == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try restoreOwnership(at: child)
            }
        }
        if metadata.st_uid == 0, lchown(url.path, uid, gid) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func restoreOwnerOfDirectory(at url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { return }
        if metadata.st_uid == 0, lchown(url.path, uid, gid) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
