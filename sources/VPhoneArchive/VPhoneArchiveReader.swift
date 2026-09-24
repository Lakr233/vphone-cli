import Foundation
import LibArchive

/// Reading an archive without unpacking it.
///
/// Listing members and pulling a single one out — reading a BuildManifest from
/// an IPSW without writing 15 GB to disk first.
public enum VPhoneArchiveReader {
    private static let blockSize = 10240

    public struct Entry: Sendable, Equatable {
        public let path: String
        public let size: Int64
        public let isDirectory: Bool
        public let isSymlink: Bool
        public let mode: mode_t
        public let uid: Int
        public let gid: Int
        public let modified: Date?
        /// Where a symlink points, unresolved.
        public let linkTarget: String?
    }

    /// Every member, in the order the archive stores them.
    public static func entries(of archive: URL) throws -> [Entry] {
        try withReader(archive) { reader in
            var found: [Entry] = []
            while let entry = try nextHeader(reader, archive: archive) {
                found.append(makeEntry(entry))
                archive_read_data_skip(reader)
            }
            return found
        }
    }

    /// One member's contents.
    ///
    /// Reads sequentially, so it costs whatever it costs to reach the member.
    /// For a zip on a real file libarchive uses the central directory and the
    /// seek is cheap; for a compressed tar it is not, and the whole stream up
    /// to that point has to be decompressed.
    public static func readMember(_ member: String, from archive: URL) throws -> Data {
        try withReader(archive) { reader in
            while let entry = try nextHeader(reader, archive: archive) {
                let path = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
                guard path == member else {
                    archive_read_data_skip(reader)
                    continue
                }

                var data = Data()
                let hint = archive_entry_size(entry)
                if hint > 0 {
                    data.reserveCapacity(Int(hint))
                }

                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let read = buffer.withUnsafeMutableBytes {
                        archive_read_data(reader, $0.baseAddress, $0.count)
                    }
                    if read == 0 {
                        break
                    }
                    guard read > 0 else {
                        throw VPhoneArchiveError.readFailed(
                            path: archive.path, reason: archiveErrorString(reader),
                        )
                    }
                    data.append(contentsOf: buffer[0 ..< Int(read)])
                }
                return data
            }
            throw VPhoneArchiveError.memberNotFound(member: member, archive: archive.path)
        }
    }

    /// The compressor and format libarchive detects, for reporting.
    public static func describe(_ archive: URL) throws -> (format: String, filter: String) {
        try withReader(archive) { reader in
            _ = try nextHeader(reader, archive: archive)
            let format = archive_format_name(reader).map { String(cString: $0) } ?? "unknown"
            let filter = archive_filter_name(reader, 0).map { String(cString: $0) } ?? "none"
            return (format, filter)
        }
    }

    // MARK: - Plumbing

    private static func withReader<T>(
        _ archive: URL,
        _ body: (OpaquePointer?) throws -> T,
    ) throws -> T {
        let reader = archive_read_new()
        archive_read_support_format_all(reader)
        archive_read_support_format_raw(reader)
        archive_read_support_filter_all(reader)
        defer { archive_read_free(reader) }

        guard archive_read_open_filename(reader, archive.path, blockSize) == ARCHIVE_OK else {
            throw VPhoneArchiveError.cannotOpen(
                path: archive.path, reason: archiveErrorString(reader),
            )
        }
        return try body(reader)
    }

    private static func nextHeader(
        _ reader: OpaquePointer?,
        archive: URL,
    ) throws -> OpaquePointer? {
        var entry: OpaquePointer?
        let status = archive_read_next_header(reader, &entry)
        if status == ARCHIVE_EOF {
            return nil
        }
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            throw VPhoneArchiveError.readFailed(
                path: archive.path, reason: archiveErrorString(reader),
            )
        }
        return entry
    }

    private static func makeEntry(_ entry: OpaquePointer) -> Entry {
        let fileType = mode_t(archive_entry_filetype(entry))
        let mtime = archive_entry_mtime_is_set(entry) != 0
            ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry)))
            : nil
        return Entry(
            path: archive_entry_pathname(entry).map { String(cString: $0) } ?? "",
            size: archive_entry_size(entry),
            isDirectory: fileType == S_IFDIR,
            isSymlink: fileType == S_IFLNK,
            mode: mode_t(archive_entry_perm(entry)),
            uid: Int(archive_entry_uid(entry)),
            gid: Int(archive_entry_gid(entry)),
            modified: mtime,
            linkTarget: archive_entry_symlink(entry).map { String(cString: $0) },
        )
    }
}
