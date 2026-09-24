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

    var description: String {
        switch self {
        case let .chown(path, code):
            "cannot change owner of \(path): \(String(cString: strerror(code)))"
        case let .unlink(path, code):
            "cannot remove \(path): \(String(cString: strerror(code)))"
        case let .symlinkOntoDirectory(path):
            """
            refusing to replace the directory at \(path) with a symlink.
            `ln -sf` would have created the link *inside* it, which leaves the \
            guest with a path that resolves to nothing and only fails at boot.
            """
        }
    }
}

extension CryptexFilesystemPatcher {
    /// `chmod <mode> <path>`.
    ///
    /// Follows symlinks, which is what chmod(1) does without `-h`.
    func setMode(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: url.path,
        )
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
        var info = stat()
        if lstat(link.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) else {
                throw CryptexFileOperationError.symlinkOntoDirectory(path: link.path)
            }
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: destination,
        )
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
