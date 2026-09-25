import Darwin
import Foundation

// MARK: - Errors

public enum VPhoneConfinedDirectoryError: Error, CustomStringConvertible, Equatable {
    /// Empty, absolute, or containing an empty, `.` or `..` component.
    case invalidPath(String)
    case missing(String)
    case symbolicLink(String)
    case notDirectory(String)
    case notRegularFile(String)
    case crossesDevice(String)
    case hardLinked(String)
    case foreignOwner(String, uid_t)
    case unsupportedFileType(String)
    case changedDuringOpen(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            "\(path) is not a plain relative path."
        case let .missing(path):
            "\(path) does not exist."
        case let .symbolicLink(path):
            "\(path) is a symbolic link or passes through one."
        case let .notDirectory(path):
            "\(path) is not a folder."
        case let .notRegularFile(path):
            "\(path) is not a regular file."
        case let .crossesDevice(path):
            "\(path) is on another volume."
        case let .hardLinked(path):
            "\(path) has more than one hard link."
        case let .foreignOwner(path, uid):
            "\(path) is owned by user ID \(uid), not the account that started the install."
        case let .unsupportedFileType(path):
            "\(path) is a device, socket or pipe."
        case let .changedDuringOpen(path):
            "\(path) changed while it was being opened."
        case let .system(path, code):
            "\(path): \(String(cString: strerror(code)))"
        }
    }

    static func from(_ code: Int32, _ path: String) -> VPhoneConfinedDirectoryError {
        switch code {
        case ENOENT: .missing(path)
        case ELOOP: .symbolicLink(path)
        case ENOTDIR: .notDirectory(path)
        default: .system(path, code)
        }
    }
}

// MARK: - VPhoneConfinedFile

/// A regular file opened without following a symbolic link, with the
/// metadata of the descriptor itself rather than of a path.
public final class VPhoneConfinedFile: Sendable {
    public let descriptor: Int32
    public let device: dev_t
    public let inode: ino_t
    public let owner: uid_t
    public let group: gid_t
    public let mode: mode_t
    public let size: off_t

    init(descriptor: Int32, metadata: stat) {
        self.descriptor = descriptor
        device = metadata.st_dev
        inode = metadata.st_ino
        owner = metadata.st_uid
        group = metadata.st_gid
        mode = metadata.st_mode
        size = metadata.st_size
    }

    deinit {
        close(descriptor)
    }
}

// MARK: - VPhoneConfinedDirectory

/// A directory held open by descriptor, for root code that works inside a
/// tree someone else controls: a caller's 0777 VM folder, or a guest volume
/// mounted from an untrusted Disk.img.
///
/// A path check followed by a path-based write is a race, and a path-based
/// write follows every symbolic link on the way. So nothing here goes by
/// path. Every relative path is walked one component at a time with
/// `openat(O_NOFOLLOW)` from the held descriptor, a symbolic link anywhere
/// on the way is refused, and the final operation is an `*at()` call on the
/// parent's descriptor. A symbolic link at the leaf is removed or replaced,
/// never followed. Walks never leave the volume the directory was opened on,
/// so a folder mounted inside the tree cannot redirect them either.
public final class VPhoneConfinedDirectory: Sendable {
    public let descriptor: Int32
    public let device: dev_t

    private init(adopting descriptor: Int32, name: String) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            close(descriptor)
            throw VPhoneConfinedDirectoryError.from(code, name)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw VPhoneConfinedDirectoryError.notDirectory(name)
        }
        self.descriptor = descriptor
        device = metadata.st_dev
    }

    /// Open `path` as the confinement root. Only the last component is
    /// checked for a symbolic link; use `pin` when the whole path matters.
    public convenience init(root path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        try self.init(adopting: descriptor, name: path)
    }

    deinit {
        close(descriptor)
    }

    /// Open an absolute, canonical path from `/` one component at a time,
    /// refusing a symbolic link anywhere in it. Pass a `realpath` result.
    /// Volume changes are allowed on the way down (the Data volume, external
    /// disks), but not below the returned directory.
    public static func pin(absolutePath: String, requireOwner owner: uid_t? = nil) throws -> VPhoneConfinedDirectory {
        guard absolutePath.hasPrefix("/"), !absolutePath.contains("\0") else {
            throw VPhoneConfinedDirectoryError.invalidPath(absolutePath)
        }
        var current = try VPhoneConfinedDirectory(root: "/")
        for component in absolutePath.split(separator: "/").map(String.init) {
            guard component != ".", component != ".." else {
                throw VPhoneConfinedDirectoryError.invalidPath(absolutePath)
            }
            current = try current.openChild(component, create: false, mode: 0, sameDevice: false, path: absolutePath)
        }
        if let owner {
            let metadata = try current.metadata()
            guard metadata.st_uid == owner else {
                throw VPhoneConfinedDirectoryError.foreignOwner(absolutePath, metadata.st_uid)
            }
        }
        return current
    }

    // MARK: - Identity

    /// The directory's current path from `F_GETPATH`, for handing a verified
    /// location to a subprocess. It is only as stable as the tree above it:
    /// use it for directories nobody else can rename.
    public var path: String {
        get throws {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
                throw VPhoneConfinedDirectoryError.system("F_GETPATH", errno)
            }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    public func metadata() throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw VPhoneConfinedDirectoryError.system(".", errno)
        }
        return metadata
    }

    public func fileSystemStatus() throws -> statfs {
        var status = statfs()
        guard fstatfs(descriptor, &status) == 0 else {
            throw VPhoneConfinedDirectoryError.system(".", errno)
        }
        return status
    }

    /// The device a mounted volume came from, such as `/dev/disk5s1`.
    public func mountedFrom() throws -> String {
        var status = try fileSystemStatus()
        return withUnsafePointer(to: &status.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
    }

    // MARK: - Walking

    /// Open a subdirectory, creating missing components when asked.
    public func directory(_ relative: String, create: Bool = false, mode: mode_t = 0o755) throws
        -> VPhoneConfinedDirectory
    {
        var current = self
        for component in try Self.components(of: relative) {
            current = try current.openChild(component, create: create, mode: mode, sameDevice: true, path: relative)
        }
        return current
    }

    /// Open the root of a volume mounted on the direct child `name`. This is
    /// the one walk that expects the device to change; check `mountedFrom()`.
    public func mountedVolume(_ name: String) throws -> VPhoneConfinedDirectory {
        let components = try Self.components(of: name)
        guard components.count == 1 else {
            throw VPhoneConfinedDirectoryError.invalidPath(name)
        }
        let volume = try openChild(name, create: false, mode: 0, sameDevice: false, path: name)
        guard volume.device != device else {
            throw VPhoneConfinedDirectoryError.missing("a volume mounted on \(name)")
        }
        return volume
    }

    /// The directory holding `relative`'s last component, and that component.
    public func parent(of relative: String, create: Bool = false, mode: mode_t = 0o755) throws
        -> (directory: VPhoneConfinedDirectory, leaf: String)
    {
        let components = try Self.components(of: relative)
        var current = self
        for component in components.dropLast() {
            current = try current.openChild(component, create: create, mode: mode, sameDevice: true, path: relative)
        }
        return (current, components[components.count - 1])
    }

    /// The names in this directory, without `.` and `..`, sorted.
    public func entries() throws -> [String] {
        try Self.entries(of: descriptor, path: ".")
    }

    // MARK: - Inspection

    /// `lstat` of `relative`, or nil when it or a folder above it is absent.
    /// A symbolic link above the leaf still throws.
    public func status(_ relative: String) throws -> stat? {
        let parent: (directory: VPhoneConfinedDirectory, leaf: String)
        do {
            parent = try self.parent(of: relative)
        } catch VPhoneConfinedDirectoryError.missing {
            return nil
        }
        var metadata = stat()
        guard fstatat(parent.directory.descriptor, parent.leaf, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
        return metadata
    }

    public func exists(_ relative: String) throws -> Bool {
        try status(relative) != nil
    }

    public func isSymlink(_ relative: String) throws -> Bool {
        try status(relative).map { $0.st_mode & S_IFMT == S_IFLNK } ?? false
    }

    public func isDirectory(_ relative: String) throws -> Bool {
        try status(relative).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false
    }

    public func isRegularFile(_ relative: String) throws -> Bool {
        try status(relative).map { $0.st_mode & S_IFMT == S_IFREG } ?? false
    }

    /// The link's target text, or nil when `relative` is absent or not a link.
    public func readLink(_ relative: String) throws -> String? {
        guard try isSymlink(relative) else { return nil }
        let (directory, leaf) = try parent(of: relative)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = readlinkat(directory.descriptor, leaf, &buffer, Int(MAXPATHLEN))
        guard count >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
        return String(decoding: buffer[0 ..< count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Reading

    /// Open a regular file for reading. A symbolic link, device or pipe is
    /// refused, and so is a file with another owner or a second hard link
    /// when asked: a hard link keeps its target's owner, so a link planted in
    /// a caller's folder could otherwise hand root another account's file.
    public func openRegularFile(
        _ relative: String,
        requireOwner owner: uid_t? = nil,
        requireSingleLink: Bool = false,
    ) throws -> VPhoneConfinedFile {
        let (directory, leaf) = try parent(of: relative)
        let file = openat(directory.descriptor, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else {
            let code = errno
            close(file)
            throw VPhoneConfinedDirectoryError.from(code, relative)
        }
        let opened = VPhoneConfinedFile(descriptor: file, metadata: metadata)
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw VPhoneConfinedDirectoryError.notRegularFile(relative)
        }
        if let owner, metadata.st_uid != owner {
            throw VPhoneConfinedDirectoryError.foreignOwner(relative, metadata.st_uid)
        }
        if requireSingleLink, metadata.st_nlink != 1 {
            throw VPhoneConfinedDirectoryError.hardLinked(relative)
        }
        // Clear O_NONBLOCK; it was only there so a FIFO could not hang open.
        _ = fcntl(file, F_SETFL, fcntl(file, F_GETFL) & ~O_NONBLOCK)
        return opened
    }

    public func readData(_ relative: String) throws -> Data {
        let file = try openRegularFile(relative)
        var data = Data(capacity: Int(max(file.size, 0)))
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(file.descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw VPhoneConfinedDirectoryError.system(relative, errno)
            }
            if count == 0 {
                return data
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
    }

    /// True when `relative` is still the file `file` was opened from. A
    /// caller that must hand a path to a subprocess checks this last.
    public func refersTo(_ relative: String, file: VPhoneConfinedFile) throws -> Bool {
        guard let metadata = try status(relative) else { return false }
        return metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_dev == file.device && metadata.st_ino == file.inode
    }

    // MARK: - Writing

    /// Atomically install `data` at `relative`: a new file beside it, then
    /// `renameat` over it. rename replaces a symbolic link at the leaf; it
    /// never writes through one.
    public func writeFile(
        _ relative: String,
        contents data: Data,
        mode: mode_t,
        owner: (uid: uid_t, gid: gid_t)? = nil,
    ) throws {
        try install(relative, mode: mode, owner: owner) { file in
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(file, bytes.baseAddress! + offset, bytes.count - offset)
                    if count < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw VPhoneConfinedDirectoryError.system(relative, errno)
                    }
                    offset += count
                }
            }
        }
    }

    /// Atomically install a copy of the regular file at `source`. The source
    /// is a trusted host file (the private work folder or the running
    /// bundle's resources); its last component still must not be a link.
    public func replaceFile(
        _ relative: String,
        fromFileAt source: URL,
        mode: mode_t,
        owner: (uid: uid_t, gid: gid_t)? = nil,
    ) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, source.path)
        }
        defer { close(input) }
        var metadata = stat()
        guard fstat(input, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw VPhoneConfinedDirectoryError.notRegularFile(source.path)
        }
        try install(relative, mode: mode, owner: owner) { file in
            try Self.copyContents(from: input, to: file, path: relative)
        }
    }

    /// Copy the regular file `source` to `destination`, in this directory or
    /// in `target`, keeping its mode and (when running as root) its owner.
    /// The destination must not exist yet.
    public func copyFile(from source: String, to destination: String, in target: VPhoneConfinedDirectory? = nil) throws {
        let input = try openRegularFile(source)
        let (directory, leaf) = try (target ?? self).parent(of: destination)
        let output = openat(directory.descriptor, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, destination)
        }
        defer { close(output) }
        do {
            try Self.copyContents(from: input.descriptor, to: output, path: destination)
            try Self.applyAttributes(
                to: output,
                owner: geteuid() == 0 ? (input.owner, input.group) : nil,
                mode: input.mode & 0o7777,
                path: destination,
            )
        } catch {
            unlinkat(directory.descriptor, leaf, 0)
            throw error
        }
    }

    /// Clone an already verified open file into this directory. Returns false
    /// when the two are on volumes that cannot share blocks.
    public func clone(_ file: VPhoneConfinedFile, to relative: String) throws -> Bool {
        let (directory, leaf) = try parent(of: relative)
        guard fclonefileat(file.descriptor, directory.descriptor, leaf, UInt32(CLONE_NOOWNERCOPY)) == 0 else {
            switch errno {
            case EXDEV, ENOTSUP, ENOTTY:
                return false
            default:
                throw VPhoneConfinedDirectoryError.from(errno, relative)
            }
        }
        return true
    }

    /// Stream an already verified open file into a new file in this directory.
    public func copy(_ file: VPhoneConfinedFile, to relative: String, mode: mode_t = 0o600) throws {
        let (directory, leaf) = try parent(of: relative)
        let output = openat(directory.descriptor, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
        defer { close(output) }
        guard lseek(file.descriptor, 0, SEEK_SET) == 0 else {
            throw VPhoneConfinedDirectoryError.system(relative, errno)
        }
        do {
            try Self.copyContents(from: file.descriptor, to: output, path: relative)
        } catch {
            unlinkat(directory.descriptor, leaf, 0)
            throw error
        }
    }

    /// Replace whatever is at `relative` with a symbolic link to `target`.
    public func createSymlink(target: String, at relative: String) throws {
        let (directory, leaf) = try parent(of: relative)
        try Self.removeEntry(in: directory.descriptor, named: leaf, device: directory.device, path: relative)
        guard symlinkat(target, directory.descriptor, leaf) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
    }

    /// `renameat` between two leaves, in this directory or into `target`.
    public func rename(_ source: String, to destination: String, in target: VPhoneConfinedDirectory? = nil) throws {
        let from = try parent(of: source)
        let to = try (target ?? self).parent(of: destination)
        guard renameat(from.directory.descriptor, from.leaf, to.directory.descriptor, to.leaf) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, source)
        }
    }

    public func setMode(_ relative: String, _ mode: mode_t) throws {
        let (directory, leaf) = try parent(of: relative)
        guard fchmodat(directory.descriptor, leaf, mode, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
    }

    public func setOwner(_ relative: String, uid: uid_t, gid: gid_t) throws {
        let (directory, leaf) = try parent(of: relative)
        guard fchownat(directory.descriptor, leaf, uid, gid, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
    }

    // MARK: - Removal

    /// Remove `relative` and everything below it without following a link:
    /// a symbolic link is removed as a link. Absent is not an error. A folder
    /// on another volume (something still mounted) is refused, not emptied.
    public func removeItem(_ relative: String) throws {
        let parent: (directory: VPhoneConfinedDirectory, leaf: String)
        do {
            parent = try self.parent(of: relative)
        } catch VPhoneConfinedDirectoryError.missing {
            return
        }
        try Self.removeEntry(in: parent.directory.descriptor, named: parent.leaf, device: device, path: relative)
    }

    // MARK: - Tree copy

    /// Copy the contents of `source` into a new folder `relative` (its parents
    /// are created as needed; the folder itself must not exist).
    ///
    /// The source is walked by descriptor too: symbolic links are recreated
    /// as links and never followed, devices, sockets and pipes are refused,
    /// and nothing on another volume is entered. With `requireSourceOwner`,
    /// every entry must belong to that user and no file may have a second
    /// hard link. Files get `owner` (or, as root, the source's owner), and
    /// `clearSetID` drops set-user-ID and set-group-ID bits.
    public func copyTree(
        from source: VPhoneConfinedDirectory,
        to relative: String,
        requireSourceOwner sourceOwner: uid_t? = nil,
        owner: (uid: uid_t, gid: gid_t)? = nil,
        clearSetID: Bool = true,
    ) throws {
        let rootMetadata = try source.metadata()
        if let sourceOwner, rootMetadata.st_uid != sourceOwner {
            throw VPhoneConfinedDirectoryError.foreignOwner(relative, rootMetadata.st_uid)
        }
        let (directory, leaf) = try parent(of: relative, create: true)
        guard mkdirat(directory.descriptor, leaf, 0o700) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
        let destination = try directory.openChild(leaf, create: false, mode: 0, sameDevice: true, path: relative)
        let options = TreeCopy(
            sourceDevice: source.device,
            sourceOwner: sourceOwner,
            owner: owner,
            clearSetID: clearSetID,
        )
        try options.copyContents(of: source.descriptor, into: destination.descriptor, path: relative)
        try options.finish(destination.descriptor, like: rootMetadata, path: relative)
    }

    // MARK: - Internals

    /// Split a relative path, refusing anything that could leave the root.
    static func components(of relative: String) throws -> [String] {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else {
            throw VPhoneConfinedDirectoryError.invalidPath(relative)
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VPhoneConfinedDirectoryError.invalidPath(relative)
        }
        return components
    }

    private func openChild(
        _ name: String,
        create: Bool,
        mode: mode_t,
        sameDevice: Bool,
        path: String,
    ) throws -> VPhoneConfinedDirectory {
        if create, mkdirat(descriptor, name, mode) != 0, errno != EEXIST {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            // O_NOFOLLOW|O_DIRECTORY on a link reports ENOTDIR on some
            // releases; say what it really is.
            let code = errno
            var metadata = stat()
            if fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
               metadata.st_mode & S_IFMT == S_IFLNK
            {
                throw VPhoneConfinedDirectoryError.symbolicLink(path)
            }
            throw VPhoneConfinedDirectoryError.from(code, path)
        }
        let directory = try VPhoneConfinedDirectory(adopting: child, name: path)
        if sameDevice, directory.device != device {
            throw VPhoneConfinedDirectoryError.crossesDevice(path)
        }
        return directory
    }

    static func entries(of descriptor: Int32, path: String) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            let code = errno
            if duplicate >= 0 {
                close(duplicate)
            }
            throw VPhoneConfinedDirectoryError.system(path, code)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            var name = entry.pointee.d_name
            let text = withUnsafePointer(to: &name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if text != ".", text != ".." {
                names.append(text)
            }
        }
        return names.sorted()
    }

    private func install(
        _ relative: String,
        mode: mode_t,
        owner: (uid: uid_t, gid: gid_t)?,
        write: (Int32) throws -> Void,
    ) throws {
        let (directory, leaf) = try parent(of: relative)
        let temporary = ".\(leaf).tmp-\(UUID().uuidString)"
        let file = openat(directory.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
        var installed = false
        defer {
            close(file)
            if !installed {
                unlinkat(directory.descriptor, temporary, 0)
            }
        }
        try write(file)
        try Self.applyAttributes(to: file, owner: owner, mode: mode, path: relative)
        guard fsync(file) == 0 else {
            throw VPhoneConfinedDirectoryError.system(relative, errno)
        }
        guard renameat(directory.descriptor, temporary, directory.descriptor, leaf) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, relative)
        }
        installed = true
    }

    /// Owner first: chown clears set-ID bits, so the mode has to come after.
    static func applyAttributes(to file: Int32, owner: (uid: uid_t, gid: gid_t)?, mode: mode_t, path: String) throws {
        if let owner, fchown(file, owner.uid, owner.gid) != 0 {
            throw VPhoneConfinedDirectoryError.system(path, errno)
        }
        guard fchmod(file, mode) == 0 else {
            throw VPhoneConfinedDirectoryError.system(path, errno)
        }
    }

    static func copyContents(from input: Int32, to output: Int32, path: String) throws {
        // fcopyfile works on the two descriptors already verified; it never
        // reopens anything by name.
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw VPhoneConfinedDirectoryError.system(path, errno)
        }
    }

    private static func removeEntry(in parent: Int32, named name: String, device: dev_t, path: String) throws {
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else {
                throw VPhoneConfinedDirectoryError.from(errno, path)
            }
            return
        }
        guard metadata.st_dev == device else {
            throw VPhoneConfinedDirectoryError.crossesDevice(path)
        }
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        defer { close(child) }
        var opened = stat()
        guard fstat(child, &opened) == 0, opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else {
            throw VPhoneConfinedDirectoryError.changedDuringOpen(path)
        }
        // A read-only folder (IPSW trees carry some) cannot be emptied, even
        // by its owner, until it is writable again. This is its own
        // descriptor, so it cannot be redirected.
        if opened.st_mode & 0o700 != 0o700 {
            _ = fchmod(child, (opened.st_mode & 0o7777) | 0o700)
        }
        for entry in try entries(of: child, path: path) {
            try removeEntry(in: child, named: entry, device: device, path: "\(path)/\(entry)")
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
    }
}

// MARK: - Tree copy

private struct TreeCopy {
    let sourceDevice: dev_t
    let sourceOwner: uid_t?
    let owner: (uid: uid_t, gid: gid_t)?
    let clearSetID: Bool

    func copyContents(of source: Int32, into destination: Int32, path: String) throws {
        for name in try VPhoneConfinedDirectory.entries(of: source, path: path) {
            let entryPath = "\(path)/\(name)"
            var metadata = stat()
            guard fstatat(source, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw VPhoneConfinedDirectoryError.from(errno, entryPath)
            }
            if let sourceOwner, metadata.st_uid != sourceOwner {
                throw VPhoneConfinedDirectoryError.foreignOwner(entryPath, metadata.st_uid)
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                try copyDirectory(name, from: source, into: destination, metadata: metadata, path: entryPath)
            case S_IFREG:
                try copyFile(name, from: source, into: destination, metadata: metadata, path: entryPath)
            case S_IFLNK:
                try copyLink(name, from: source, into: destination, metadata: metadata, path: entryPath)
            default:
                throw VPhoneConfinedDirectoryError.unsupportedFileType(entryPath)
            }
        }
    }

    func finish(_ file: Int32, like metadata: stat, path: String) throws {
        var mode = metadata.st_mode & 0o7777
        if clearSetID {
            mode &= ~(S_ISUID | S_ISGID)
        }
        try VPhoneConfinedDirectory.applyAttributes(
            to: file,
            owner: owner ?? (geteuid() == 0 ? (metadata.st_uid, metadata.st_gid) : nil),
            mode: mode,
            path: path,
        )
    }

    private func copyDirectory(
        _ name: String,
        from source: Int32,
        into destination: Int32,
        metadata: stat,
        path: String,
    ) throws {
        guard metadata.st_dev == sourceDevice else {
            throw VPhoneConfinedDirectoryError.crossesDevice(path)
        }
        let input = try open(name, in: source, flags: O_DIRECTORY, like: metadata, path: path)
        defer { close(input) }
        guard mkdirat(destination, name, 0o700) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        let output = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        defer { close(output) }
        try copyContents(of: input, into: output, path: path)
        _ = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_XATTR))
        try finish(output, like: metadata, path: path)
    }

    private func copyFile(
        _ name: String,
        from source: Int32,
        into destination: Int32,
        metadata: stat,
        path: String,
    ) throws {
        if sourceOwner != nil, metadata.st_nlink != 1 {
            throw VPhoneConfinedDirectoryError.hardLinked(path)
        }
        let input = try open(name, in: source, flags: O_NONBLOCK, like: metadata, path: path)
        defer { close(input) }
        let output = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        defer { close(output) }
        try VPhoneConfinedDirectory.copyContents(from: input, to: output, path: path)
        // Extended attributes are kept where the host allows it; some names
        // are reserved even for root, and the data is what matters.
        _ = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_XATTR))
        try finish(output, like: metadata, path: path)
    }

    private func copyLink(
        _ name: String,
        from source: Int32,
        into destination: Int32,
        metadata: stat,
        path: String,
    ) throws {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = readlinkat(source, name, &buffer, Int(MAXPATHLEN))
        guard count >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        buffer[count] = 0
        guard symlinkat(buffer, destination, name) == 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        let linkOwner = owner ?? (geteuid() == 0 ? (metadata.st_uid, metadata.st_gid) : nil)
        if let linkOwner, fchownat(destination, name, linkOwner.uid, linkOwner.gid, AT_SYMLINK_NOFOLLOW) != 0 {
            throw VPhoneConfinedDirectoryError.system(path, errno)
        }
    }

    /// Open a source entry without following a link and confirm it is still
    /// the inode `fstatat` described.
    private func open(_ name: String, in source: Int32, flags: Int32, like metadata: stat, path: String) throws -> Int32 {
        let file = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | flags)
        guard file >= 0 else {
            throw VPhoneConfinedDirectoryError.from(errno, path)
        }
        var opened = stat()
        guard fstat(file, &opened) == 0,
              opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino,
              opened.st_mode & S_IFMT == metadata.st_mode & S_IFMT
        else {
            close(file)
            throw VPhoneConfinedDirectoryError.changedDuringOpen(path)
        }
        return file
    }
}
