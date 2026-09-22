import Foundation
import LibArchive

/// Creating archives, and plain decompression.
public enum VPhoneArchiveWriter {
    public struct Progress: Sendable {
        public let entriesWritten: Int
        public let bytesWritten: Int64
        public let currentPath: String
    }

    /// Pack `root` into `archive`.
    ///
    /// Paths inside the archive are relative to `root`, so unpacking anywhere
    /// reproduces the tree rather than an absolute path.
    ///
    /// `excluding` takes `fnmatch` patterns matched against the archive-relative
    /// path, which is what `vm export` already uses.
    @discardableResult
    public static func create(
        archive: URL,
        from root: URL,
        format: VPhoneArchiveFormat = .gnutar,
        compression: VPhoneArchiveCompression = .none,
        excluding patterns: [String] = [],
        progress: ((Progress) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Int {
        let writer = archive_write_new()
        defer { archive_write_free(writer) }

        switch format {
        case .gnutar: archive_write_set_format_gnutar(writer)
        case .pax: archive_write_set_format_pax_restricted(writer)
        case .ustar: archive_write_set_format_ustar(writer)
        }

        switch compression {
        case .none:
            break
        case let .zstd(level):
            archive_write_add_filter_zstd(writer)
            try setFilterOption(writer, "zstd", "compression-level", String(level))
            // threads=0 means "as many as there are cores".
            try setFilterOption(writer, "zstd", "threads", "0")
        case let .xz(level):
            archive_write_add_filter_xz(writer)
            try setFilterOption(writer, "xz", "compression-level", String(level))
            // The bundled liblzma does carry the multithreaded encoder, which
            // is worth about 4.8x -- but only above one xz block, roughly
            // 192 MiB at level 9. A smaller archive gets no benefit, and that
            // is arithmetic rather than a fault. See
            // research/libarchive_xcframework_validation.md.
            try setFilterOption(writer, "xz", "threads", "0")
        case let .gzip(level):
            archive_write_add_filter_gzip(writer)
            try setFilterOption(writer, "gzip", "compression-level", String(level))
        }

        guard archive_write_open_filename(writer, archive.path) == ARCHIVE_OK else {
            throw VPhoneArchiveError.cannotOpen(
                path: archive.path, reason: archiveErrorString(writer)
            )
        }
        defer { archive_write_close(writer) }

        let disk = archive_read_disk_new()
        archive_read_disk_set_standard_lookup(disk)
        defer { archive_read_free(disk) }

        // Resolved, and the same resolved path is what libarchive walks — so
        // the prefix strip below always matches. Passing one form here and
        // comparing against another is how every member ended up stored under
        // an absolute path.
        let resolvedRoot = try VPhoneArchivePaths.resolved(root)
        guard archive_read_disk_open(disk, resolvedRoot.path) == ARCHIVE_OK else {
            throw VPhoneArchiveError.cannotOpen(
                path: resolvedRoot.path, reason: archiveErrorString(disk)
            )
        }

        // Without a link resolver, every name of a hardlinked file is packed
        // as its own full copy, and unpacking gives back separate files. That
        // matters here: iosbinpack64 and the procursus bootstrap are full of
        // hardlinks, so flattening them silently doubles what lands on the
        // guest volume and breaks anything that expected the identity. GNU tar
        // does this by default, which is how the difference was found — see
        // `vphone-archive fingerprint`.
        //
        // With the tar strategy the resolver never defers: the first name is
        // returned as-is, and later ones come back as hardlink references with
        // size 0, which the data copy below already skips.
        let resolver = archive_entry_linkresolver_new()
        archive_entry_linkresolver_set_strategy(resolver, archive_format(writer))
        defer { archive_entry_linkresolver_free(resolver) }

        let rootPath = resolvedRoot.path
        var written = 0
        var bytes: Int64 = 0

        while true {
            if isCancelled?() == true { throw VPhoneArchiveError.cancelled }

            let entry = archive_entry_new()
            defer { archive_entry_free(entry) }

            let status = archive_read_next_header2(disk, entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw VPhoneArchiveError.readFailed(
                    path: root.path, reason: archiveErrorString(disk)
                )
            }
            archive_read_disk_descend(disk)

            let absolute = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            let relative = VPhoneArchivePaths.relative(absolute, under: rootPath)
            if relative.isEmpty { continue }   // the root itself
            if patterns.contains(where: { matches(relative, pattern: $0) }) { continue }
            archive_entry_set_pathname(entry, relative)

            // Turns the second and later names of a hardlinked file into
            // references to the first. The archive-relative pathname has to be
            // set before this, or the resolver records absolute paths as the
            // link targets.
            var resolved: OpaquePointer? = entry
            var deferred: OpaquePointer?
            archive_entry_linkify(resolver, &resolved, &deferred)
            guard let resolved else { continue }

            guard archive_write_header(writer, resolved) == ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(
                    path: relative, reason: archiveErrorString(writer)
                )
            }

            // A hardlink reference comes back with size 0, so this also skips
            // re-storing contents we have already written once.
            if archive_entry_size(resolved) > 0 {
                bytes += try copyFile(at: absolute, into: writer, isCancelled: isCancelled)
            }

            written += 1
            progress?(Progress(entriesWritten: written, bytesWritten: bytes, currentPath: relative))
        }

        return written
    }

    /// Decompress a single-stream file — `zstd -d`, and its xz and gzip
    /// equivalents.
    ///
    /// This is not unpacking: `bootstrap-iphoneos-arm64.tar.zst` is one
    /// compressed file, and what comes out is the tar. libarchive expresses
    /// that as the "raw" format, which presents the stream as one nameless
    /// entry.
    public static func decompress(_ input: URL, to output: URL) throws {
        let reader = archive_read_new()
        archive_read_support_filter_all(reader)
        archive_read_support_format_raw(reader)
        defer { archive_read_free(reader) }

        guard archive_read_open_filename(reader, input.path, 10240) == ARCHIVE_OK else {
            throw VPhoneArchiveError.cannotOpen(
                path: input.path, reason: archiveErrorString(reader)
            )
        }

        var entry: OpaquePointer?
        guard archive_read_next_header(reader, &entry) == ARCHIVE_OK else {
            throw VPhoneArchiveError.readFailed(
                path: input.path, reason: archiveErrorString(reader)
            )
        }

        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: output.path) else {
            throw VPhoneArchiveError.cannotOpen(path: output.path, reason: "cannot create")
        }
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let read = buffer.withUnsafeMutableBytes {
                archive_read_data(reader, $0.baseAddress, $0.count)
            }
            if read == 0 { break }
            guard read > 0 else {
                throw VPhoneArchiveError.readFailed(
                    path: input.path, reason: archiveErrorString(reader)
                )
            }
            try handle.write(contentsOf: buffer[0..<Int(read)])
        }
    }

    // MARK: - Plumbing

    private static func setFilterOption(
        _ writer: OpaquePointer?,
        _ filter: String,
        _ key: String,
        _ value: String
    ) throws {
        guard archive_write_set_filter_option(writer, filter, key, value) == ARCHIVE_OK else {
            throw VPhoneArchiveError.writeFailed(
                path: "<filter \(filter)>", reason: archiveErrorString(writer)
            )
        }
    }

    private static func matches(_ path: String, pattern: String) -> Bool {
        fnmatch(pattern, path, 0) == 0
            || fnmatch(pattern, (path as NSString).lastPathComponent, 0) == 0
    }

    private static func copyFile(
        at path: String,
        into writer: OpaquePointer?,
        isCancelled: (() -> Bool)?
    ) throws -> Int64 {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw VPhoneArchiveError.cannotOpen(path: path, reason: "cannot read")
        }
        defer { try? handle.close() }

        var total: Int64 = 0
        while true {
            if isCancelled?() == true { throw VPhoneArchiveError.cancelled }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            let sent = chunk.withUnsafeBytes {
                archive_write_data(writer, $0.baseAddress, $0.count)
            }
            guard sent > 0 else {
                throw VPhoneArchiveError.writeFailed(
                    path: path, reason: archiveErrorString(writer)
                )
            }
            total += Int64(sent)
        }
        return total
    }
}
