// CryptexFilesystemPatcherFileOps.swift — the file operations that used to be subprocesses.
//
// chmod, chown, ln and find were spawned a dozen times between them to do work this
// process can do directly. What is here is not a set of convenience wrappers: each one
// names the tool and the flag it replaces, because the defaults are not obvious and
// getting one wrong writes a guest volume that only fails at boot.
//
//   /bin/chmod 0755 <path>              -> setMode(0o755, at:)
//   /usr/sbin/chown -R 0:0 <path>       -> chownRecursively(uid:gid:at:)
//   /bin/ln -sf <dest> <link>           -> createSymlink(at:to:)
//   /usr/bin/find <dir> -name ._* -del  -> deleteAppleDoubleFiles(under:)

import Foundation

enum CryptexFileOperationError: Error, CustomStringConvertible {
    case chown(path: String, code: Int32)
    case unlink(path: String, code: Int32)
    case symlinkOntoDirectory(path: String)
    case unsafeGuestPath(path: String)
    case guestIO(path: String, operation: String, code: Int32)

    var description: String {
        switch self {
        case let .chown(path, code):
            "Unable to change the owner of \(path): \(String(cString: strerror(code)))"
        case let .unlink(path, code):
            "Unable to remove \(path): \(String(cString: strerror(code)))"
        case let .symlinkOntoDirectory(path):
            "Unable to create a symlink at \(path) because a directory already exists there."
        case let .unsafeGuestPath(path):
            "Unable to change \(path) because it is not a plain path under a mounted guest volume."
        case let .guestIO(path, operation, code):
            "Unable to \(operation) \(path): \(String(cString: strerror(code)))"
        }
    }
}

extension CryptexFilesystemPatcher {
    /// `chmod -h <mode> <path>`.
    ///
    /// This runs as root against a guest volume, so neither the leaf nor any
    /// directory on the way to it is followed if it is a symlink.
    func setMode(_ mode: Int, at url: URL) throws {
        try withGuestParent(of: url) { parent, leaf in
            guard fchmodat(parent, leaf, mode_t(mode), AT_SYMLINK_NOFOLLOW) == 0 else {
                throw CryptexFileOperationError.guestIO(path: url.path, operation: "chmod", code: errno)
            }
        }
    }

    /// `chown -R <uid>:<gid> <path>`, numerically.
    ///
    /// `lchown`, not `chown`: BSD `chown -R` defaults to `-P`, where a
    /// symlink's own ownership changes and its target's does not. FileManager's
    /// `.ownerAccountID` attribute would follow the link instead, so it is not
    /// used here.
    func chownRecursively(uid: uid_t, gid: gid_t, at url: URL) throws {
        for entry in [url] + entriesBelow(url).map(\.url) {
            guard lchown(entry.path, uid, gid) == 0 else {
                throw CryptexFileOperationError.chown(path: entry.path, code: errno)
            }
        }
    }

    /// `ln -sf <destination> <link>`.
    ///
    /// `-f` means whatever is at `link` goes first, and `destination` is stored
    /// verbatim — these links are relative and must stay relative, because they
    /// are resolved inside the guest, not here.
    ///
    /// The one case this deliberately does not reproduce is a real directory at
    /// `link`: ln(1) would quietly create the symlink *inside* it. That has
    /// never happened on a volume this installer produced — the dyld paths
    /// arrive as symlinks already — and if it ever does, an error at patch time
    /// beats a guest that cannot find its dyld cache.
    func createSymlink(at link: URL, to destination: String) throws {
        try withGuestParent(of: link) { parent, leaf in
            var info = stat()
            if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) else {
                    throw CryptexFileOperationError.symlinkOntoDirectory(path: link.path)
                }
                guard unlinkat(parent, leaf, 0) == 0 else {
                    throw CryptexFileOperationError.unlink(path: link.path, code: errno)
                }
            }
            guard symlinkat(destination, parent, leaf) == 0 else {
                throw CryptexFileOperationError.guestIO(path: link.path, operation: "create symlink", code: errno)
            }
        }
    }

    /// `find <directory> -name '._*' -delete`.
    ///
    /// AppleDouble members land as ordinary files when an archive carrying them
    /// is unpacked onto the guest volume, and a `._CodeResources` beside a real
    /// one is how a bundle comes out unloadable. Returns how many were removed;
    /// zero is the normal answer for an archive that has none.
    ///
    /// Unlike the `try? runProcess(…)` this replaces, a failure to remove one
    /// is reported rather than swallowed.
    @discardableResult
    func deleteAppleDoubleFiles(under directory: URL) throws -> Int {
        var removed = 0
        for entry in entriesBelow(directory)
            where entry.url.lastPathComponent.hasPrefix("._")
        {
            // unlink(2), not FileManager.removeItem: Foundation reads a `._name`
            // as the partner file's metadata rather than as a file of its own,
            // which is the same confusion that hides these from its directory
            // listings. unlink removes the directory entry, which is the job.
            let gone = entry.isDirectory ? rmdir(entry.url.path) : unlink(entry.url.path)
            guard gone == 0 else {
                throw CryptexFileOperationError.unlink(path: entry.url.path, code: errno)
            }
            removed += 1
        }
        return removed
    }

    /// Every entry below `directory`, children before their parent, as `find`
    /// sees them.
    ///
    /// `opendir`/`readdir`, and it has to be. On a volume with native extended
    /// attributes Foundation treats a `._name` as the partner file's metadata,
    /// not as a file: `contentsOfDirectory` and `enumerator(at:)` both leave
    /// those entries out of the listing entirely, so an enumerator-based sweep
    /// for them finds nothing and reports success. `readdir` returns the
    /// directory as it is.
    ///
    /// Symlinks are returned but never descended into, which is what both
    /// `find` and `chown -R` do by default.
    private func entriesBelow(_ directory: URL) -> [(url: URL, isDirectory: Bool)] {
        guard let handle = opendir(directory.path) else { return [] }
        defer { closedir(handle) }

        var entries: [(url: URL, isDirectory: Bool)] = []
        while let entry = readdir(handle) {
            var storage = entry.pointee.d_name
            let name = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }

            let child = directory.appendingPathComponent(name)
            var isDirectory = entry.pointee.d_type == UInt8(DT_DIR)
            if entry.pointee.d_type == UInt8(DT_UNKNOWN) {
                var info = stat()
                isDirectory = lstat(child.path, &info) == 0
                    && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            }
            if isDirectory {
                entries.append(contentsOf: entriesBelow(child))
            }
            entries.append((child, isDirectory))
        }
        return entries
    }
}

// MARK: - No-follow guest paths

/// Every write into a mounted guest volume runs as root, so a symlink planted
/// anywhere on the way would redirect it onto the host. These walk from the
/// mount root one component at a time with `O_NOFOLLOW | O_DIRECTORY` and do
/// the final operation relative to the parent descriptor, never by path.
extension CryptexFilesystemPatcher {
    /// The mount root (or, for tests, the restore directory) `url` lives under.
    private func guestRoot(for url: URL) throws -> String {
        let path = url.path
        let roots = Array(mountPoints.values) + [restoreDir.path]
        let matches = roots.filter { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        guard let root = matches.max(by: { $0.count < $1.count }) else {
            throw CryptexFileOperationError.unsafeGuestPath(path: path)
        }
        return root
    }

    /// Open the directory holding `url` and hand it with the leaf name to `body`.
    func withGuestParent<T>(of url: URL, _ body: (Int32, String) throws -> T) throws -> T {
        let root = try guestRoot(for: url)
        let parts = url.path.dropFirst(root.count).split(separator: "/").map(String.init)
        guard let leaf = parts.last, !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            throw CryptexFileOperationError.unsafeGuestPath(path: url.path)
        }
        var directory = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw CryptexFileOperationError.guestIO(path: root, operation: "open", code: errno)
        }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(directory)
            guard next >= 0 else {
                throw CryptexFileOperationError.guestIO(path: url.path, operation: "open a directory of", code: code)
            }
            directory = next
        }
        defer { close(directory) }
        return try body(directory, leaf)
    }

    /// Read a guest file without following a link at the leaf.
    func readGuestFile(at url: URL) throws -> Data {
        try withGuestParent(of: url) { parent, leaf in
            let descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw CryptexFileOperationError.guestIO(path: url.path, operation: "read", code: errno)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            return try handle.readToEnd() ?? Data()
        }
    }

    /// Replace a guest file: write a fresh O_EXCL|O_NOFOLLOW temp beside it,
    /// then renameat over the old entry (which replaces a link, never follows it).
    func writeGuestFile(_ data: Data, to url: URL, mode: mode_t = 0o644) throws {
        try withGuestParent(of: url) { parent, leaf in
            let temp = ".\(leaf).vphone-\(UUID().uuidString)"
            let descriptor = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            guard descriptor >= 0 else {
                throw CryptexFileOperationError.guestIO(path: url.path, operation: "create", code: errno)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
                guard renameat(parent, temp, parent, leaf) == 0 else {
                    throw CryptexFileOperationError.guestIO(path: url.path, operation: "rename into", code: errno)
                }
            } catch {
                unlinkat(parent, temp, 0)
                throw error
            }
        }
    }

    /// Copy a host file or directory tree into the guest. Host symlinks are
    /// recreated as links; nothing in the guest is followed.
    func copyIntoGuest(from source: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            throw CryptexFileOperationError.guestIO(path: source.path, operation: "read", code: errno)
        }
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            try withGuestParent(of: destination) { parent, leaf in
                guard mkdirat(parent, leaf, info.st_mode & 0o7777) == 0 else {
                    throw CryptexFileOperationError.guestIO(path: destination.path, operation: "create", code: errno)
                }
            }
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                try copyIntoGuest(
                    from: source.appendingPathComponent(name),
                    to: destination.appendingPathComponent(name),
                )
            }
        case mode_t(S_IFLNK):
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try createSymlink(at: destination, to: target)
        case mode_t(S_IFREG):
            try writeGuestFile(
                Data(contentsOf: source, options: .mappedIfSafe),
                to: destination,
                mode: info.st_mode & 0o7777,
            )
        default:
            throw CryptexFileOperationError.unsafeGuestPath(path: source.path)
        }
    }

    /// `rm -rf` inside the guest, by descriptor. Missing is not an error.
    func removeGuestItem(at url: URL) throws {
        try withGuestParent(of: url) { parent, leaf in
            try removeTree(parent: parent, name: leaf, path: url.path)
        }
    }

    private func removeTree(parent: Int32, name: String, path: String) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw CryptexFileOperationError.unlink(path: path, code: errno)
        }
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0, let stream = fdopendir(directory) else {
                throw CryptexFileOperationError.unlink(path: path, code: errno)
            }
            var children: [String] = []
            while let entry = readdir(stream) {
                var storage = entry.pointee.d_name
                let child = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if child != ".", child != ".." { children.append(child) }
            }
            defer { closedir(stream) }
            for child in children {
                try removeTree(parent: dirfd(stream), name: child, path: path + "/" + child)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                throw CryptexFileOperationError.unlink(path: path, code: errno)
            }
        } else {
            guard unlinkat(parent, name, 0) == 0 else {
                throw CryptexFileOperationError.unlink(path: path, code: errno)
            }
        }
    }
}
