import Darwin
import Foundation

/// Files panel metadata uses lstat for the entry and stat only to describe a
/// symlink target, matching the full daemon's wire contract.
enum VPhoneDarwinFileSystem {
    static func listDirectory(_ path: String) throws -> [String: Any] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: path).sorted().compactMap { name -> [String: Any]? in
            let full = (path as NSString).appendingPathComponent(name)
            var metadata = stat()
            guard lstat(full, &metadata) == 0 else { return nil }
            let type = metadata.st_mode & mode_t(S_IFMT)
            let isLink = type == mode_t(S_IFLNK)
            var target = stat()
            let targetDirectory = isLink && stat(full, &target) == 0 && target.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            var entry: [String: Any] = ["name": name, "path": full,
                                       "type": isLink ? "link" : type == mode_t(S_IFDIR) ? "dir" : "file",
                                       "link_target_dir": targetDirectory, "size": metadata.st_size,
                                       "perm": String(metadata.st_mode & 0o777, radix: 8), "mtime": Double(metadata.st_mtimespec.tv_sec)]
            if type == mode_t(S_IFDIR) || targetDirectory, let canonical = realpath(full, nil) {
                entry["resolved_path"] = String(cString: canonical)
                free(canonical)
            }
            return entry
        }
        return ["path": path, "entries": entries, "count": entries.count]
    }

}
