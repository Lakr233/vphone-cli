import Foundation
import LibArchive

/// Unpacks an archive onto disk.
///
/// The format and the compressor are detected, so there is no `--zstd` to
/// pass and no way to get it wrong. What the caller does choose is where the
/// files end up belonging, which is the part that differs between unpacking
/// onto a mounted guest volume and unpacking into a scratch directory.
public enum VPhoneArchiveExtractor {
    /// Bytes handed to libarchive per read. 10 KiB is libarchive's own
    /// suggestion and there is no reason here to argue with it.
    private static let blockSize = 10240

    public struct Progress: Sendable {
        public let entriesWritten: Int
        public let bytesWritten: Int64
        public let currentPath: String
    }

    /// Unpack `archive` into `destination`.
    ///
    /// `bytesRead` reports how far into the archive *file* the read has got —
    /// compressed bytes, so it can be shown against the file's size on disk.
    /// It fires per data block, not per entry, because a VM bundle's `Disk.img`
    /// is one entry of many gigabytes.
    ///
    /// - Returns: the number of entries written, not counting any skipped by
    ///   `noOverwriteDir`.
    @discardableResult
    public static func extract(
        _ archive: URL,
        into destination: URL,
        options: VPhoneArchiveExtractOptions,
        progress: ((Progress) -> Void)? = nil,
        bytesRead: ((Int64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
    ) throws -> Int {
        let reader = archive_read_new()
        archive_read_support_format_all(reader)
        archive_read_support_filter_all(reader)
        defer { archive_read_free(reader) }

        let writer = archive_write_disk_new()
        archive_write_disk_set_options(writer, options.extractFlags)
        // Deliberately NOT archive_write_disk_set_standard_lookup(): see
        // VPhoneArchiveOwnership.preserveNumeric. Without it libarchive uses
        // the numeric ids straight from the archive, which is what we want.
        defer { archive_write_free(writer) }

        guard archive_read_open_filename(reader, archive.path, blockSize) == ARCHIVE_OK else {
            throw VPhoneArchiveError.cannotOpen(
                path: archive.path,
                reason: archiveErrorString(reader),
            )
        }

        // Resolved once, and every target is built from the resolved form.
        //
        // Not a tidy-up: ARCHIVE_EXTRACT_SECURE_SYMLINKS checks every
        // component of the path it is given, and on macOS /tmp and /var are
        // themselves symlinks into /private. Handing it an unresolved
        // /var/folders/... target makes it refuse the extraction outright,
        // with "Cannot extract through symlink /var/...". Resolving the
        // destination leaves only components *below* it for the flag to judge,
        // which is the part we actually want judged.
        let resolvedDestination = try VPhoneArchivePaths.resolved(destination)
        let destinationPath = resolvedDestination.path
        var written = 0
        var bytes: Int64 = 0

        while true {
            if isCancelled?() == true {
                throw VPhoneArchiveError.cancelled
            }

            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF {
                break
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else {
                throw VPhoneArchiveError.readFailed(
                    path: archive.path,
                    reason: archiveErrorString(reader),
                )
            }

            let memberPath = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            let target = resolvedDestination.appendingPathComponent(memberPath)

            // libarchive's SECURE_* flags already refuse absolute paths and
            // `..`, but they refuse them inside libarchive. Checking the
            // normalised result here as well means the answer does not rest on
            // one flag being set, and the error can name the member.
            // .standardized, not .standardizedFileURL: the latter resolves
            // symlinks as well, and on macOS that turns the /private/var we
            // just resolved back into /var, so the prefix comparison fails
            // against a destination that is perfectly fine. Collapsing "." and
            // ".." is all that is wanted here — the destination was already
            // resolved once, above.
            let targetPath = target.standardized.path
            guard targetPath == destinationPath || targetPath.hasPrefix(destinationPath + "/") else {
                throw VPhoneArchiveError.pathEscapesDestination(
                    member: memberPath,
                    destination: destinationPath,
                )
            }
            archive_entry_set_pathname(entry, targetPath)

            // A hardlink entry names its target as an archive-relative path,
            // and libarchive resolves that against the process's working
            // directory. Since the entry's own path has just been made
            // absolute, the target has to be too, or extraction fails with
            // "Hard-link target 'x' does not exist" — which is what happened.
            //
            // Symlinks are deliberately left alone: their target is data,
            // stored and restored verbatim, and rewriting one would change
            // what the link says.
            if let rawLink = archive_entry_hardlink(entry) {
                let linkPath = String(cString: rawLink)
                let linkTarget = resolvedDestination.appendingPathComponent(linkPath)
                let resolvedLink = linkTarget.standardized.path
                guard resolvedLink.hasPrefix(destinationPath + "/") else {
                    throw VPhoneArchiveError.pathEscapesDestination(
                        member: linkPath,
                        destination: destinationPath,
                    )
                }
                archive_entry_set_hardlink(entry, resolvedLink)
            }

            if options.noOverwriteDir, shouldSkipExistingDirectory(entry, at: target) {
                // Skip the header only. Everything under this directory that
                // does not yet exist is still written on its own entry, which
                // is what GNU tar does too.
                continue
            }

            guard archive_write_header(writer, entry) == ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(
                    path: target.path,
                    reason: archiveErrorString(writer),
                )
            }

            if archive_entry_size(entry) > 0 {
                bytes += try copyData(
                    from: reader,
                    to: writer,
                    isCancelled: isCancelled,
                    onBlock: bytesRead.map { report in
                        { report(archive_filter_bytes(reader, -1)) }
                    },
                )
            }

            guard archive_write_finish_entry(writer) == ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(
                    path: target.path,
                    reason: archiveErrorString(writer),
                )
            }

            written += 1
            progress?(Progress(entriesWritten: written, bytesWritten: bytes, currentPath: memberPath))
            // filter -1 is the bottom filter, the archive file itself, so this
            // is the compressed position. Entries with no data never reach the
            // per-block report above, and small ones are most of a bundle.
            bytesRead?(archive_filter_bytes(reader, -1))
        }

        return written
    }

    // MARK: - --no-overwrite-dir

    /// Whether this entry is a directory that already exists and should be
    /// left exactly as it is.
    ///
    /// GNU tar's `--no-overwrite-dir` has no libarchive equivalent, and
    /// neither of the two things libarchive does offer is the same:
    ///
    /// - The default, per `man 3 archive_write_disk`, is that "existing
    ///   directories will have their permissions updated". That is precisely
    ///   what must not happen. `iosbinpack64.tar` carries entries for `usr/`,
    ///   `usr/local/` and `System/`, and unpacking it onto an installed iOS
    ///   volume would stamp the archive's modes and owners over the real
    ///   ones.
    ///
    /// - `ARCHIVE_EXTRACT_NO_OVERWRITE` is too broad in the other direction:
    ///   it skips any existing object of any type, so an ordinary file that
    ///   should be replaced silently is not. libarchive decides per entry, so
    ///   skipping a directory does not affect new files beneath it — the
    ///   problem is only what it does to regular files.
    ///
    /// So: look for a directory entry whose target already exists as a
    /// directory, and skip writing its header. The path is left in place; only
    /// its metadata is left alone.
    private static func shouldSkipExistingDirectory(
        _ entry: OpaquePointer,
        at target: URL,
    ) -> Bool {
        // S_IFDIR rather than AE_IFDIR: the AE_* names are C macros that Swift
        // does not import, and they are defined to the same values as the
        // S_IF* ones precisely so they can be compared like this.
        guard mode_t(archive_entry_filetype(entry)) == S_IFDIR else { return false }

        var info = stat()
        // lstat, not stat: a symlink that points at a directory is a symlink,
        // and replacing it is a different decision from updating a directory.
        guard lstat(target.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Data

    private static func copyData(
        from reader: OpaquePointer?,
        to writer: OpaquePointer?,
        isCancelled: (() -> Bool)?,
        onBlock: (() -> Void)? = nil,
    ) throws -> Int64 {
        var total: Int64 = 0
        while true {
            // Cancellation is checked per block, not per entry: a single
            // multi-gigabyte disk image is one entry, and a check that only
            // happens between entries would not interrupt it.
            if isCancelled?() == true {
                throw VPhoneArchiveError.cancelled
            }

            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: la_int64_t = 0

            let status = archive_read_data_block(reader, &buffer, &size, &offset)
            if status == ARCHIVE_EOF {
                return total
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw VPhoneArchiveError.readFailed(
                    path: "<member data>",
                    reason: archiveErrorString(reader),
                )
            }

            guard archive_write_data_block(writer, buffer, size, offset) >= ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(
                    path: "<member data>",
                    reason: archiveErrorString(writer),
                )
            }
            total += Int64(size)
            onBlock?()
        }
    }
}
