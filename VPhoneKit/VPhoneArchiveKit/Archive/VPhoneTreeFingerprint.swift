import CryptoKit
import Foundation

/// A complete description of a directory tree, for comparing two of them.
///
/// `diff -r` plus `stat` is not enough to decide that GNU tar and libarchive
/// produced the same result, and the four things it misses are exactly the
/// four most likely to differ: ACLs, extended attributes, which files are
/// hardlinked to which, and sparse-file occupancy. All four change how a guest
/// behaves and none of them shows up in a diff.
///
/// The output is deterministic and JSON, so two trees compare with a plain
/// equality check and any difference names itself.
public struct VPhoneTreeFingerprint: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Path relative to the tree root, so two trees in different places
        /// still compare.
        public let path: String
        /// file, dir, symlink, fifo, socket, blockdev, chardev
        public let type: String
        /// Permission bits including setuid, setgid and sticky, as octal.
        public let mode: String
        /// Numeric, never resolved to a name: the whole point of restoring
        /// ownership by number is that the name means something different on
        /// the host than it does in the guest.
        public let uid: Int
        public let gid: Int
        public let size: Int64
        /// Whole nanoseconds, because ARCHIVE_EXTRACT_TIME claims to restore
        /// them.
        public let mtimeNanoseconds: Int64
        /// Unresolved target of a symlink.
        public let linkTarget: String?
        /// Which files share an inode, normalised to a sequence number.
        ///
        /// Comparing inode numbers directly is meaningless across two
        /// extractions; what has to match is the *grouping*. Files with no
        /// other link have no id.
        public let hardlinkGroup: Int?
        /// Extended attribute names with a SHA-256 of each value. Covers the
        /// `com.apple.*` ones, which is where AppleDouble handling shows up.
        public let xattrs: [String: String]
        /// `acl_to_text` output, or nil when there is no ACL. libarchive and
        /// GNU tar disagree here more readily than anywhere else.
        public let acl: String?
        /// Blocks actually allocated. Two files can have the same logical size
        /// and different occupancy, which is what a lost sparse hole looks
        /// like.
        public let blocks: Int64
        /// Content digest, regular files only.
        public let contentSHA256: String?
    }

    public let root: String
    public let entries: [Entry]

    // MARK: - Capture

    public static func capture(_ root: URL, includeContentHashes: Bool = true) throws -> Self {
        let resolvedRoot = try VPhoneArchivePaths.resolved(root)
        let rootPath = resolvedRoot.path

        var paths: [String] = []

        /// An explicit walk rather than FileManager's enumerator, which follows
        /// its own rules about symlinks and packages. This has to see exactly
        /// what is on disk, in a stable order.
        func walk(_ directory: String) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            for name in names.sorted() {
                let full = directory + "/" + name
                paths.append(full)
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    try walk(full)
                }
            }
        }
        try walk(rootPath)

        // Hardlink groups, assigned in path order so the numbering is stable.
        var groupOf: [String: Int] = [:] // "dev:ino" -> group
        var linkCounts: [String: Int] = [:]
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_nlink > 1 else { continue }
            let key = "\(info.st_dev):\(info.st_ino)"
            linkCounts[key, default: 0] += 1
        }
        var nextGroup = 0
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_nlink > 1 else { continue }
            let key = "\(info.st_dev):\(info.st_ino)"
            guard linkCounts[key] ?? 0 > 1, groupOf[key] == nil else { continue }
            groupOf[key] = nextGroup
            nextGroup += 1
        }

        var entries: [Entry] = []
        entries.reserveCapacity(paths.count)
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let relative = VPhoneArchivePaths.relative(path, under: rootPath)
            let fileType = info.st_mode & S_IFMT
            let key = "\(info.st_dev):\(info.st_ino)"

            entries.append(Entry(
                path: relative,
                type: describe(fileType),
                mode: String(info.st_mode & 0o7777, radix: 8),
                uid: Int(info.st_uid),
                gid: Int(info.st_gid),
                size: fileType == S_IFREG ? info.st_size : 0,
                mtimeNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(info.st_mtimespec.tv_nsec),
                linkTarget: fileType == S_IFLNK
                    ? try? FileManager.default.destinationOfSymbolicLink(atPath: path)
                    : nil,
                hardlinkGroup: info.st_nlink > 1 ? groupOf[key] : nil,
                xattrs: extendedAttributes(of: path),
                acl: accessControlList(of: path),
                blocks: Int64(info.st_blocks),
                contentSHA256: includeContentHashes && fileType == S_IFREG
                    ? digest(of: path)
                    : nil,
            ))
        }

        return VPhoneTreeFingerprint(root: rootPath, entries: entries)
    }

    /// Every way the two trees differ, described by path.
    ///
    /// The root itself is not compared: two extractions of the same archive
    /// into different directories are supposed to differ there.
    public func differences(from other: VPhoneTreeFingerprint) -> [String] {
        var found: [String] = []
        let mine = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let theirs = Dictionary(uniqueKeysWithValues: other.entries.map { ($0.path, $0) })

        for path in Set(mine.keys).subtracting(theirs.keys).sorted() {
            found.append("\(path): only in \(root)")
        }
        for path in Set(theirs.keys).subtracting(mine.keys).sorted() {
            found.append("\(path): only in \(other.root)")
        }
        for path in Set(mine.keys).intersection(theirs.keys).sorted() {
            let a = mine[path]!, b = theirs[path]!
            if a == b {
                continue
            }
            if a.type != b.type {
                found.append("\(path): type \(a.type) vs \(b.type)")
            }
            if a.mode != b.mode {
                found.append("\(path): mode \(a.mode) vs \(b.mode)")
            }
            if a.uid != b.uid || a.gid != b.gid {
                found.append("\(path): owner \(a.uid):\(a.gid) vs \(b.uid):\(b.gid)")
            }
            if a.size != b.size {
                found.append("\(path): size \(a.size) vs \(b.size)")
            }
            if a.mtimeNanoseconds != b.mtimeNanoseconds {
                found.append("\(path): mtime \(a.mtimeNanoseconds) vs \(b.mtimeNanoseconds)")
            }
            if a.linkTarget != b.linkTarget {
                found.append("\(path): symlink \(a.linkTarget ?? "-") vs \(b.linkTarget ?? "-")")
            }
            if a.hardlinkGroup != b.hardlinkGroup {
                found.append("\(path): hardlink group \(a.hardlinkGroup.map(String.init) ?? "-") vs \(b.hardlinkGroup.map(String.init) ?? "-")")
            }
            if a.xattrs != b.xattrs {
                found.append("\(path): xattrs \(a.xattrs.keys.sorted()) vs \(b.xattrs.keys.sorted())")
            }
            if a.acl != b.acl {
                found.append("\(path): ACL differs")
            }
            if a.blocks != b.blocks {
                found.append("\(path): occupancy \(a.blocks) vs \(b.blocks) blocks (sparseness)")
            }
            if a.contentSHA256 != b.contentSHA256 {
                found.append("\(path): contents differ")
            }
        }
        return found
    }

    // MARK: - Details

    private static func describe(_ fileType: mode_t) -> String {
        switch fileType {
        case S_IFREG: "file"
        case S_IFDIR: "dir"
        case S_IFLNK: "symlink"
        case S_IFIFO: "fifo"
        case S_IFSOCK: "socket"
        case S_IFBLK: "blockdev"
        case S_IFCHR: "chardev"
        default: "other"
        }
    }

    private static func extendedAttributes(of path: String) -> [String: String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }

        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [:] }

        var result: [String: String] = [:]
        for chunk in names.split(separator: 0) {
            let name = String(decoding: chunk.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !name.isEmpty else { continue }
            let valueSize = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: max(valueSize, 1))
            guard getxattr(path, name, &value, valueSize, 0, XATTR_NOFOLLOW) == valueSize else { continue }
            result[name] = SHA256.hash(data: Data(value.prefix(valueSize)))
                .map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private static func accessControlList(of path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        let value = String(cString: text)
        return value.isEmpty ? nil : value
    }

    private static func digest(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
