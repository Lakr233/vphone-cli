import CryptoKit
import Darwin
import Foundation

/// The folders machines live in. The default library (`VPHONE_LIBRARY_ROOT`,
/// else the folder chosen in Host Setup, else ~/.vphone/machines) is always
/// one; New Machine can add others. Each is passed to vphone-cli as
/// `--library-root`.
///
/// Roots are canonical: the helper refuses a library path with a symbolic
/// link in it, and comparing canonical paths keeps one folder from being
/// listed twice under two spellings.
nonisolated enum VPhoneLaunchpadMachineLocations {
    static let defaultRoot: String = {
        let environment = environmentRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return canonical(
            environment ?? chosenLibrary()
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vphone/machines", isDirectory: true),
        )
    }()

    /// `VPHONE_LIBRARY_ROOT`, which Host Setup cannot change.
    static let environmentRoot = ProcessInfo.processInfo.environment["VPHONE_LIBRARY_ROOT"].flatMap { $0.isEmpty ? nil : $0 }

    // MARK: Chosen library

    private static let libraryBookmarkKey = "VPhoneLaunchpadLibraryBookmark"

    /// The folder chosen in Host Setup, kept as a bookmark: it is found
    /// again after it is moved or renamed, and access to it survives a
    /// relaunch. A stale bookmark is written again.
    private static func chosenLibrary() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: libraryBookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &isStale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &isStale))
        else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        if isStale {
            try? rememberLibrary(url)
        }
        return url
    }

    /// Makes `url` the default library from the next launch. Nothing is
    /// moved: the machines stay in the folder they are in.
    static func rememberLibrary(_ url: URL) throws {
        let data = try (try? url.bookmarkData(options: [.withSecurityScope]))
            ?? url.bookmarkData()
        UserDefaults.standard.set(data, forKey: libraryBookmarkKey)
    }

    /// Whether the volume holding `root` makes copy-on-write clones, which
    /// templates, clones and snapshots rely on to share a disk image.
    static func supportsCloning(_ root: String) -> Bool {
        let url = VPhoneLaunchpadHostSetup.existingAncestor(of: URL(fileURLWithPath: root, isDirectory: true))
        return (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
    }

    /// The resolved path of an existing folder, else the standardized path.
    static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// False while a chosen folder is missing, for example on a volume that
    /// is not mounted.
    static func isAvailable(_ root: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The name of the volume holding `root`, for a narrow column. The full
    /// path goes in the column's help and the inspector.
    static func volumeName(_ root: String) -> String {
        let url = VPhoneLaunchpadHostSetup.existingAncestor(of: URL(fileURLWithPath: root, isDirectory: true))
        return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? VPhoneLaunchpadHostSetup.abbreviated(url)
    }

    /// Eight hex digits that tell libraries apart in log file names.
    static func digest(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// vphone-vm binds the machine's control socket at `<machine>/vphone.sock`
    /// and skips it when the path does not fit `sun_path`; first boot then
    /// waits for vphoned in vain.
    static func socketPathFits(root: String, name: String) -> Bool {
        let path = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("vphone.sock").path
        return path.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /// Why machines cannot be created in `root`, or nil. These are the
    /// conditions the helper enforces before `cfw install` (a root owned by
    /// the user), plus the APFS volume Host Setup requires of the default
    /// library.
    static func problem(with root: String) -> String? {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let shown = VPhoneLaunchpadHostSetup.abbreviated(url)
        // A root that does not exist yet is created by `vm new`.
        let existing = VPhoneLaunchpadHostSetup.existingAncestor(of: url)
        var volume = statfs()
        guard statfs(existing.path, &volume) == 0 else {
            return String(localized: "Cannot read the volume of \(shown)")
        }
        let type = withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard type == "apfs" else {
            return String(localized: "\(shown) is not on an APFS volume.")
        }
        // Files there report an unknown owner to root, which the helper refuses.
        guard volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else {
            return String(localized: "\(shown) is on a volume that ignores ownership. Select the volume in the Finder, choose File > Get Info, and turn off “Ignore ownership on this volume”.")
        }
        if existing.path == url.path {
            var status = stat()
            guard stat(root, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
                return String(localized: "Cannot read the volume of \(shown)")
            }
            guard status.st_uid == getuid() else {
                return String(localized: "\(shown) is not owned by your user account.")
            }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("config.plist").path) {
                return String(localized: "\(shown) is a machine. Choose the folder that contains it.")
            }
        }
        guard access(existing.path, W_OK) == 0 else {
            return String(localized: "You cannot write to \(VPhoneLaunchpadHostSetup.abbreviated(existing)).")
        }
        return nil
    }
}
