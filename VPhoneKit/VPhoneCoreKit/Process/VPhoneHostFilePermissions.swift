import Darwin
import Foundation

/// Host-side VM artifacts must remain usable when another local process owns
/// the workstation UI and the command was originally run as root.
public enum VPhoneHostFilePermissions {
    /// Make regular files and directories under an output world accessible.
    /// Symbolic links are never followed, and special files are left alone.
    public static func makeAccessible(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        try makeAccessible(descriptor: descriptor, path: url.path)
    }

    public static func makeDirectoryAccessible(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.ENOTDIR)
        }
        guard fchmod(descriptor, 0o777) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func makeAccessible(descriptor: Int32, path: String) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind = metadata.st_mode & S_IFMT
        if kind == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                if child < 0 {
                    if errno == ELOOP || errno == ENOENT {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                do {
                    defer { close(child) }
                    try makeAccessible(
                        descriptor: child,
                        path: (path as NSString).appendingPathComponent(name),
                    )
                }
            }
        }
        guard kind == S_IFDIR || kind == S_IFREG else { return }
        guard fchmod(descriptor, 0o777) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
