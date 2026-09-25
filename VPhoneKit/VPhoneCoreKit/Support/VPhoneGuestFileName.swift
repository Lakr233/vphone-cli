import CoreServices
import Darwin
import Foundation

// MARK: - Guest File Names

/// File names the guest reports (file listings, crash reports) are untrusted.
/// The host only uses a name that is one path component.
public enum VPhoneGuestFileName {
    /// Longest name one path component may have (`NAME_MAX`).
    static let maxLength = 255

    /// True when `name` is a single path component: not empty, not `.` or
    /// `..`, no `/` or NUL, and at most 255 bytes.
    public static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0"),
              name.utf8.count <= maxLength
        else { return false }
        return name == (name as NSString).lastPathComponent
    }
}

// MARK: - Host Download Directory

/// A host directory that receives guest data. It holds the directory open
/// and creates every entry relative to that descriptor: files are created
/// exclusively and never through a symbolic link, so a guest name cannot
/// replace an existing file or write outside the directory.
public final class VPhoneHostDownloadDirectory: Sendable {
    public let url: URL
    private let fd: Int32

    private init(fd: Int32, url: URL) {
        self.fd = fd
        self.url = url
    }

    /// Opens a directory the user chose.
    public convenience init(url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else { throw Self.posixError() }
        self.init(fd: fd, url: url)
    }

    /// Creates and opens a fresh, private directory under the user's
    /// temporary directory.
    public static func makeTemporary() throws -> VPhoneHostDownloadDirectory {
        let parent = try VPhoneHostDownloadDirectory(url: FileManager.default.temporaryDirectory)
        return try parent.makeSubdirectory(named: UUID().uuidString, mode: 0o700, reuseExisting: false)
    }

    deinit {
        close(fd)
    }

    // MARK: - Files

    /// Creates `name` in this directory and writes `data` to it. Fails with
    /// `EEXIST` when any entry, including a symbolic link, already has that name.
    public func writeNewFile(named name: String, data: Data) throws -> URL {
        guard VPhoneGuestFileName.isSafe(name) else { throw POSIXError(.EINVAL) }
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw Self.posixError() }
        defer { close(file) }
        do {
            try Self.write(file, data: data)
        } catch {
            unlinkat(fd, name, 0)
            throw error
        }
        return url.appendingPathComponent(name, isDirectory: false)
    }

    /// Writes a new file as `name`, or as `name 2`, `name 3`… (before the
    /// extension) when that name is taken. Never replaces an existing entry.
    public func writeUniqueFile(named name: String, data: Data) throws -> URL {
        do {
            return try writeNewFile(named: name, data: data)
        } catch let error as POSIXError where error.code == .EEXIST {}
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 2 ... 9999 {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            do {
                return try writeNewFile(named: candidate, data: data)
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        throw POSIXError(.EEXIST)
    }

    // MARK: - Directories

    /// Creates the directory `name`, or opens it when a real directory of that
    /// name already exists. A symbolic link of that name is refused.
    public func makeSubdirectory(named name: String) throws -> VPhoneHostDownloadDirectory {
        try makeSubdirectory(named: name, mode: 0o755, reuseExisting: true)
    }

    private func makeSubdirectory(named name: String, mode: mode_t, reuseExisting: Bool) throws -> VPhoneHostDownloadDirectory {
        guard VPhoneGuestFileName.isSafe(name) else { throw POSIXError(.EINVAL) }
        if mkdirat(fd, name, mode) != 0 {
            let code = errno
            guard code == EEXIST, reuseExisting else { throw Self.posixError(code) }
        }
        // O_NOFOLLOW with O_DIRECTORY refuses a symbolic link in place of the directory.
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw Self.posixError() }
        return VPhoneHostDownloadDirectory(fd: child, url: url.appendingPathComponent(name, isDirectory: true))
    }

    // MARK: - Quarantine

    /// Tags guest data written to the host as a download, so Gatekeeper
    /// checks it before it is opened or run. Best effort.
    public static func markQuarantined(_ url: URL, agent: String = "vphone-vm") {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: agent,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try? url.setResourceValues(values)
    }

    // MARK: - Private

    private static func write(_ file: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, base + offset, bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
