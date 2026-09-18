import Darwin
import Foundation

public enum VPhoneDownloadPathError: Error {
    case invalidComponent, openFailed, notDirectory
}

/// Keeps guest-selected descendants relative to an already-open host directory.
public enum VPhoneDownloadPath {
    public static func validateComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0")
        else { throw VPhoneDownloadPathError.invalidComponent }
    }

    public static func openDirectory(_ url: URL, create: Bool = true) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw VPhoneDownloadPathError.openFailed }
        return fd
    }

    public static func openChildDirectory(_ parent: Int32, _ name: String, create: Bool = true) throws -> Int32 {
        try validateComponent(name)
        var fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 && create && errno == ENOENT {
            guard mkdirat(parent, name, 0o755) == 0 || errno == EEXIST else {
                throw VPhoneDownloadPathError.openFailed
            }
            fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw errno == ENOTDIR || errno == ELOOP
                ? VPhoneDownloadPathError.notDirectory : .openFailed
        }
        return fd
    }

    /// Never truncate an existing guest-named leaf, which could be a symlink or hard link.
    public static func openAtomicOutput(_ parent: Int32, name: String) throws -> (fd: Int32, temporary: String) {
        try validateComponent(name)
        let temporary = ".vphone-\(UUID().uuidString)"
        let fd = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw VPhoneDownloadPathError.openFailed }
        return (fd, temporary)
    }

    public static func commit(_ parent: Int32, temporary: String, name: String) throws {
        try validateComponent(temporary)
        try validateComponent(name)
        guard Darwin.renameat(parent, temporary, parent, name) == 0 else {
            _ = Darwin.unlinkat(parent, temporary, 0)
            throw VPhoneDownloadPathError.openFailed
        }
    }
}
