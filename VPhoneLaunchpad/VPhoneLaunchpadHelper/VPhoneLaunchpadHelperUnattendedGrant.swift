import Darwin
import Foundation

/// A durable, per-macOS-user opt-in for the helper's five fixed VM verbs.
/// The helper's XPC listener authenticates the signed Launchpad app; the UID
/// comes from that connection, never from a caller-supplied argument. No
/// AuthorizationExternalForm, password, or bearer token is stored here.
enum VPhoneLaunchpadHelperUnattendedGrant {
    #if VPHONE_UNATTENDED_GRANT_TEST
    // Compiled only into the non-root store test executable, never the helper.
    private static let parent = ProcessInfo.processInfo.environment["VPHONE_GRANT_TEST_PARENT"]!
    private static let expectedOwner = getuid()
    #else
    private static let parent = "/Library/Application Support/vphone-launchpad"
    private static let expectedOwner: uid_t = 0
    #endif
    private static var directory: String { parent + "/UnattendedVMManagement" }
    private static let schema = 1

    private struct Record: Codable {
        let schema: Int
        let uid: UInt32
        let scope: String
    }

    static func enabled(for uid: uid_t) -> Bool {
        guard uid != 0, let descriptor = try? openDirectory(create: false) else {
            return false
        }
        defer { close(descriptor) }
        do {
            let name = fileName(for: uid)
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { return false }
            defer { close(file) }
            try requireSecureFile(file)
            var bytes = [UInt8](repeating: 0, count: 257)
            let count = read(file, &bytes, bytes.count)
            guard count > 0, count <= 256 else { return false }
            let record = try JSONDecoder().decode(Record.self, from: Data(bytes[..<count]))
            return record.schema == schema && record.uid == uid && record.scope == "vm-management"
        } catch {
            return false
        }
    }

    /// Only call after a fresh administrator AuthorizationExternalForm has
    /// passed the existing right. Atomic replacement avoids partial grants.
    static func enable(for uid: uid_t) throws {
        guard uid != 0 else { throw failure }
        let descriptor = try openDirectory(create: true)
        defer { close(descriptor) }
        let name = fileName(for: uid)
        try requireExistingFileSecure(directory: descriptor, name: name)

        let temporary = ".grant-\(UUID().uuidString)"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw failure }
        defer { unlinkat(descriptor, temporary, 0) }
        do {
            defer { close(file) }
            try requireSecureFile(file)
            let data = try JSONEncoder().encode(Record(schema: schema, uid: uid, scope: "vm-management"))
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { throw failure }
                var written = 0
                while written < buffer.count {
                    let count = write(file, base.advanced(by: written), buffer.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure }
                    written += count
                }
            }
            guard fsync(file) == 0 else { throw failure }
        }
        guard renameat(descriptor, temporary, descriptor, name) == 0,
              fsync(descriptor) == 0
        else { throw failure }
    }

    /// A signed Launchpad connection may revoke only its own UID's grant.
    /// A malformed record may be removed, but a symlink or foreign-owned file
    /// is refused without following it.
    static func disable(for uid: uid_t) throws {
        guard uid != 0 else { throw failure }
        let descriptor: Int32
        do {
            descriptor = try openDirectory(create: false)
        } catch let error as StoreError where error == .missing {
            return
        }
        defer { close(descriptor) }
        let name = fileName(for: uid)
        guard try existingFileIsSecure(directory: descriptor, name: name) else { return }
        guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else { throw failure }
    }

    /// Helper uninstall must not leave a dormant grant that a later reinstall
    /// silently reactivates. Refuse unexpected or unsafe entries rather than
    /// deleting anything outside the store's known root-owned files.
    static func removeAllForHelperUninstall() throws {
        let descriptor: Int32
        do {
            descriptor = try openDirectory(create: false)
        } catch let error as StoreError where error == .missing {
            return
        }
        defer { close(descriptor) }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        for name in names {
            let digits = String(name.dropFirst(4).dropLast(5))
            let grantName = name.hasPrefix("uid-") && name.hasSuffix(".json")
                && UInt32(digits).map(String.init) == digits
            let temporaryName = name.hasPrefix(".grant-") && UUID(uuidString: String(name.dropFirst(7))) != nil
            guard grantName || temporaryName,
                  try existingFileIsSecure(directory: descriptor, name: name),
                  unlinkat(descriptor, name, 0) == 0
            else { throw failure }
        }

        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(directory, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              current.st_uid == expectedOwner,
              current.st_mode & 0o022 == 0,
              opened.st_dev == current.st_dev,
              opened.st_ino == current.st_ino,
              rmdir(directory) == 0
        else { throw failure }
    }

    // MARK: - Root-owned storage

    private enum StoreError: Error { case missing, unsafe }

    private static var failure: VPhoneLaunchpadHelperError {
        VPhoneLaunchpadHelperError("Unable to update unattended VM management. Check the root-owned Launchpad authorization store.")
    }

    private static func fileName(for uid: uid_t) -> String { "uid-\(uid).json" }

    private static func openDirectory(create: Bool) throws -> Int32 {
        #if !VPHONE_UNATTENDED_GRANT_TEST
        try requireSecureDirectory("/Library")
        try requireSecureDirectory("/Library/Application Support")
        #endif
        if create {
            if mkdir(parent, 0o755) != 0 && errno != EEXIST { throw failure }
            try requireSecureDirectory(parent)
            if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw failure }
        } else {
            var info = stat()
            if lstat(parent, &info) != 0 {
                throw errno == ENOENT ? StoreError.missing : StoreError.unsafe
            }
            try requireSecureDirectory(parent)
            if lstat(directory, &info) != 0 {
                throw errno == ENOENT ? StoreError.missing : StoreError.unsafe
            }
        }
        try requireSecureDirectory(directory)
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure }
        return descriptor
    }

    private static func requireSecureDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == expectedOwner,
              info.st_mode & 0o022 == 0
        else { throw StoreError.unsafe }
    }

    private static func requireExistingFileSecure(directory: Int32, name: String) throws {
        _ = try existingFileIsSecure(directory: directory, name: name)
    }

    private static func existingFileIsSecure(directory: Int32, name: String) throws -> Bool {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return false }
            throw failure
        }
        defer { close(file) }
        try requireSecureFile(file)
        return true
    }

    private static func requireSecureFile(_ file: Int32) throws {
        var info = stat()
        guard fstat(file, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == expectedOwner,
              info.st_nlink == 1,
              info.st_mode & 0o077 == 0
        else { throw failure }
    }
}
