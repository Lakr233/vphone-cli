import Darwin
import Foundation

/// Writes files that arrive from the guest into a host directory the user chose.
/// Names come from the VM, so each one must be a single plain component, and
/// nothing under the destination may be a symbolic link we would follow.
public enum VPhoneHostSafeFile {
    /// A guest-supplied name is safe when it is exactly one path component.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Open the destination the user picked. The user's own choice may be a
    /// link; everything created below it is opened without following links.
    public static func openDestination(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    /// Create or reuse one directory level. An existing symlink, or anything
    /// that is not a directory, is refused.
    public static func makeDirectory(named name: String, in parent: Int32) throws -> Int32 {
        guard isSafeName(name) else { throw POSIXError(.EINVAL) }
        if mkdirat(parent, name, 0o755) != 0, errno != EEXIST {
            throw posixError()
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    /// Write a file through a fresh temporary entry, then rename it into place.
    /// The rename replaces a symlink at `name` rather than writing through it.
    public static func write(
        named name: String,
        in directory: Int32,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (FileHandle) async throws -> Void,
    ) async throws {
        guard isSafeName(name) else { throw POSIXError(.EINVAL) }
        let tempName = ".\(name.prefix(200)).vphone-\(UUID().uuidString)"
        let descriptor = openat(directory, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try await body(handle)
            try handle.synchronize()
            close(descriptor)
            guard renameat(directory, tempName, directory, name) == 0 else { throw posixError() }
        } catch {
            close(descriptor)
            unlinkat(directory, tempName, 0)
            throw error
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
