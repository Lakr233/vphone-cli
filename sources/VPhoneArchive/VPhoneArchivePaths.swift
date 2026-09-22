import Foundation

/// Path handling that has to agree between the reader, the writer and the
/// extractor.
enum VPhoneArchivePaths {
    /// A directory with every symlink in it resolved, as realpath(3) sees it.
    ///
    /// Not `URL.resolvingSymlinksInPath()` or `.standardizedFileURL`. Both of
    /// those go the *other* way on macOS: given `/private/tmp/x` they hand
    /// back `/tmp/x`, stripping the `/private` prefix rather than resolving
    /// the symlink. That silently broke two things before this helper existed
    /// — extraction, where libarchive then refused to write "through symlink
    /// /var/...", and packing, where the archive-relative path never matched
    /// its root and every member was stored under an absolute path.
    ///
    /// Throws if the path does not exist, which is the right moment to find
    /// that out.
    static func resolved(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw VPhoneArchiveError.cannotOpen(
                path: url.path, reason: String(cString: strerror(errno))
            )
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// `absolute` expressed relative to `root`, for storing in an archive.
    ///
    /// Empty when it *is* the root, which the caller skips: an archive should
    /// not carry an entry for the directory it was made from.
    static func relative(_ absolute: String, under root: String) -> String {
        if absolute == root { return "" }
        if absolute.hasPrefix(root + "/") { return String(absolute.dropFirst(root.count + 1)) }
        return absolute
    }
}
