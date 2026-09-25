import Darwin
import Foundation

/// Host-side VM artifacts must remain usable when another local process owns
/// the workstation UI and the command was originally run as root.
public enum VPhoneHostFilePermissions {
    // MARK: - Accessible modes

    /// Make regular files and directories under an output world accessible.
    /// Symbolic links are never followed, and special files are left alone.
    /// The walk is descriptor relative (see `walkTree`), so a hard link to a
    /// host file or a directory swapped for a symlink mid-walk is never
    /// widened. When running as root, entries owned by a third account are
    /// skipped: root must never widen a file its invoking user could not.
    public static func makeAccessible(at url: URL) throws {
        let owners = permittedOwners()
        try walkTree(
            at: url,
            admits: { metadata in owners.map { $0.contains(metadata.st_uid) } ?? true },
            visit: { descriptor, _ in
                guard fchmod(descriptor, 0o777) == 0 else { throw currentError() }
            },
        )
    }

    public static func makeDirectoryAccessible(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw currentError()
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.ENOTDIR)
        }
        // Root leaves a directory it does not share with the invoking user as is.
        if let owners = permittedOwners(), !owners.contains(metadata.st_uid) {
            return
        }
        guard fchmod(descriptor, 0o777) == 0 else {
            throw currentError()
        }
    }

    /// Owners whose entries a root process may change: root itself and the
    /// sudo invoker. `nil` when not root, where the kernel's own checks apply.
    private static func permittedOwners() -> Set<uid_t>? {
        guard geteuid() == 0 else { return nil }
        var owners: Set<uid_t> = [0]
        if let invoker = VPhoneInvokingUser.current {
            owners.insert(invoker.uid)
        }
        return owners
    }

    // MARK: - Descriptor walk

    /// Walk a host tree through directory descriptors and call `visit` on
    /// each admitted entry, children before their directory.
    ///
    /// The tree may be writable by other local accounts, so every entry is
    /// reached through `openat(parent, name, O_NOFOLLOW)` and listed through
    /// `fdopendir` on that descriptor, never by path. An entry is visited only
    /// when it is a directory or a regular file with a single link, sits on
    /// the root's device, is admitted by `admits`, and the descriptor opened
    /// for it is the inode `fstatat` described. Anything else is skipped and
    /// not descended into. A root that is a symlink or missing is ignored.
    static func walkTree(
        at url: URL,
        admits: (stat) -> Bool,
        visit: (Int32, stat) throws -> Void,
    ) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP {
                return
            }
            throw currentError()
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw currentError() }
        guard isWalkable(metadata, device: metadata.st_dev), admits(metadata) else { return }
        if metadata.st_mode & S_IFMT == S_IFDIR {
            try walkChildren(of: descriptor, device: metadata.st_dev, admits: admits, visit: visit)
        }
        try visit(descriptor, metadata)
    }

    private static func walkChildren(
        of directory: Int32,
        device: dev_t,
        admits: (stat) -> Bool,
        visit: (Int32, stat) throws -> Void,
    ) throws {
        let listing = dup(directory)
        guard listing >= 0 else { throw currentError() }
        guard let stream = fdopendir(listing) else {
            let error = currentError()
            close(listing)
            throw error
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    throw currentError()
                }
                return
            }
            // Keep the raw bytes: a name need not be valid UTF-8.
            let length = Int(entry.pointee.d_namlen)
            let name: [CChar] = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                Array(raw.bindMemory(to: CChar.self).prefix(length)) + [0]
            }
            if name == [0x2E, 0] || name == [0x2E, 0x2E, 0] {
                continue
            }
            try walkChild(named: name, in: directory, device: device, admits: admits, visit: visit)
        }
    }

    private static func walkChild(
        named name: [CChar],
        in directory: Int32,
        device: dev_t,
        admits: (stat) -> Bool,
        visit: (Int32, stat) throws -> Void,
    ) throws {
        var expected = stat()
        guard fstatat(directory, name, &expected, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw currentError()
        }
        guard isWalkable(expected, device: device), admits(expected) else { return }
        let isDirectory = expected.st_mode & S_IFMT == S_IFDIR
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (isDirectory ? O_DIRECTORY : 0)
        let child = openat(directory, name, flags)
        guard child >= 0 else {
            // Replaced by a symlink, removed, or retyped since fstatat.
            if errno == ELOOP || errno == ENOENT || errno == ENOTDIR {
                return
            }
            throw currentError()
        }
        defer { close(child) }
        var opened = stat()
        guard fstat(child, &opened) == 0 else { throw currentError() }
        guard opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              opened.st_mode & S_IFMT == expected.st_mode & S_IFMT,
              isWalkable(opened, device: device), admits(opened)
        else { return }
        if isDirectory {
            try walkChildren(of: child, device: device, admits: admits, visit: visit)
        }
        try visit(child, opened)
    }

    /// A directory, or a regular file with no other name, on the root's device.
    private static func isWalkable(_ metadata: stat, device: dev_t) -> Bool {
        guard metadata.st_dev == device else { return false }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            return true
        case S_IFREG:
            return metadata.st_nlink == 1
        default:
            return false
        }
    }

    static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
