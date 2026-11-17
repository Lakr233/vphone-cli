import Darwin
import Foundation

/// Checks on the library folders a request names, and the environment a
/// root `vphone-cli` child runs with. Shared by every verb that runs the
/// bundle's command line for the caller.
enum VPhoneLaunchpadHelperLibraryPath {
    /// Opens an absolute, canonical directory path one component at a time
    /// from "/", refusing a symbolic link anywhere in it.
    static func openDirectory(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw VPhoneLaunchpadHelperError("The library path \(path) must be an absolute path without . or .. components.")
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw VPhoneLaunchpadHelperError(openFailure(path, errno: errno))
        }
        for component in components {
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            close(directory)
            guard next >= 0 else {
                throw VPhoneLaunchpadHelperError(openFailure(path, errno: failure))
            }
            directory = next
        }
        return directory
    }

    /// The helper as Full Disk Access lists it.
    static let helperPath = "/Library/PrivilegedHelperTools/" + VPhoneLaunchpadHelperIdentity.label

    /// Why `path` did not open. EPERM or EACCES for root is macOS privacy
    /// protection, not a missing folder: Launchpad can ask the user for a
    /// removable or network volume, but a launchd daemon cannot show the
    /// prompt, so the helper stays refused until it has Full Disk Access.
    /// The root `vphone-cli` child is attributed to the helper and needs the
    /// same grant.
    static func openFailure(_ path: String, errno failure: Int32) -> String {
        switch failure {
        case ENOENT:
            "The library folder \(path) does not exist."
        case ELOOP, ENOTDIR:
            "The library path cannot include symbolic links."
        case EPERM, EACCES:
            "macOS refused vphone-launchpad's helper access to \(path). A library on an external or network volume needs Full Disk Access for the helper: in System Settings > Privacy & Security > Full Disk Access, click +, press Command-Shift-G, enter \(helperPath), then try again."
        default:
            "Unable to open the library folder \(path): \(String(cString: strerror(failure)))."
        }
    }

    static func requireOwner(_ descriptor: Int32, _ path: String, _ uid: uid_t) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw VPhoneLaunchpadHelperError("\(path) is not a folder.")
        }
        guard info.st_uid == uid else {
            var volume = statfs()
            let ignoresOwnership = fstatfs(descriptor, &volume) == 0
                && volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
            throw VPhoneLaunchpadHelperError(ownerRefusal(path, uid: uid, ignoresOwnership: ignoresOwnership))
        }
    }

    /// A volume that ignores ownership reports every file as owned by
    /// `_unknown` to root, so nothing on it can pass the owner check, and
    /// anyone could replace what root is about to use there.
    static func ownerRefusal(_ path: String, uid: uid_t, ignoresOwnership: Bool) -> String {
        guard ignoresOwnership else {
            return "\(path) is not owned by your user account."
        }
        let user = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        return "\(path) is on a volume that ignores ownership. Select the volume in Finder, choose File > Get Info, turn off \"Ignore ownership on this volume\", run sudo chown -R \(user) \"\(path)\", then try again."
    }

    /// The environment `sudo vphone-cli …` sees for the caller. SUDO_UID and
    /// SUDO_GID are how the command line finds the caller's home and hands
    /// root-created files back afterwards.
    static func environment(callerUID: uid_t, callerGID: gid_t) throws -> [String: String] {
        guard let account = getpwuid(callerUID) else {
            throw VPhoneLaunchpadHelperError("Unable to find the user account with ID \(callerUID).")
        }
        let userName = String(cString: account.pointee.pw_name)
        let home = String(cString: account.pointee.pw_dir)
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "USER": userName,
            "LOGNAME": userName,
            "SUDO_USER": userName,
            "SUDO_UID": String(callerUID),
            "SUDO_GID": String(callerGID),
            "LANG": "en_US.UTF-8",
        ]
    }
}
