import Darwin
import Foundation

/// A validated `vphone-cli cfw install` invocation. Built only from a store
/// bundle whose cdhash still matches its receipt, and only for a VM directory
/// the calling user owns.
struct VPhoneLaunchpadHelperFirmwareRequest {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL

    init(
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        forceDyldSharedCacheMaxSlide: Bool,
        keepArtifacts: Bool,
        callerUID: uid_t,
        callerGID: gid_t,
    ) throws {
        guard VPhoneLaunchpadNames.isValidVersion(bundleVersion) else {
            throw VPhoneLaunchpadHelperError("\"\(bundleVersion)\" is not a valid bundle version.")
        }
        guard let receipt = VPhoneLaunchpadBundleReceipt.load(version: bundleVersion) else {
            throw VPhoneLaunchpadHelperError("VPhone.bundle \(bundleVersion) is not installed. Install it in Core Bundle, then try again.")
        }
        let executable = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-cli")
        try VPhoneLaunchpadHelperCodeCheck.requireCDHash(executable, receipt.cdhashes["vphone-cli"])

        guard VPhoneLaunchpadNames.isValidMachineName(machineName) else {
            throw VPhoneLaunchpadHelperError("\"\(machineName)\" is not a valid machine name.")
        }
        // Checked by walking the path from "/" without following any link:
        // the library folder, the machine folder and its Disk.img must belong
        // to the caller. The caller can still rename these afterwards, so this
        // only refuses a bad request up front; the root vphone-cli child pins
        // the machine directory again itself before it touches anything.
        try Self.requireMachine(libraryRoot: libraryRoot, machineName: machineName, ownedBy: callerUID)
        let machine = URL(fileURLWithPath: libraryRoot, isDirectory: true)
            .appendingPathComponent(machineName, isDirectory: true)

        guard let account = getpwuid(callerUID) else {
            throw VPhoneLaunchpadHelperError("Unable to find the user account with ID \(callerUID).")
        }
        let userName = String(cString: account.pointee.pw_name)
        let home = String(cString: account.pointee.pw_dir)

        var arguments = ["cfw", "install", machineName, "--library-root", libraryRoot]
        if forceDyldSharedCacheMaxSlide {
            arguments.append("--force-dsc-maxslide")
        }
        if keepArtifacts {
            arguments.append("--keep-artifacts")
        }

        self.executable = executable
        self.arguments = arguments
        workingDirectory = machine
        // The same environment `sudo vphone-cli cfw install` sees: SUDO_UID
        // and SUDO_GID are how the installer hands root-created files back
        // to the user afterwards.
        environment = [
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

    // MARK: - Machine directory

    private static func requireMachine(libraryRoot: String, machineName: String, ownedBy uid: uid_t) throws {
        let root = try openDirectory(libraryRoot)
        defer { close(root) }
        try requireOwner(root, libraryRoot, uid)

        let machinePath = libraryRoot + "/" + machineName
        let machine = openat(root, machineName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard machine >= 0 else {
            throw VPhoneLaunchpadHelperError("\(machinePath) is not a folder, or is a symbolic link.")
        }
        defer { close(machine) }
        try requireOwner(machine, machinePath, uid)

        var disk = stat()
        guard fstatat(machine, "Disk.img", &disk, AT_SYMLINK_NOFOLLOW) == 0,
              (disk.st_mode & S_IFMT) == S_IFREG,
              disk.st_nlink == 1
        else {
            throw VPhoneLaunchpadHelperError("\(machinePath)/Disk.img must be a regular file, not a link.")
        }
        guard disk.st_uid == uid else {
            throw VPhoneLaunchpadHelperError("\(machinePath)/Disk.img is not owned by your user account.")
        }
    }

    /// Opens an absolute, canonical directory path one component at a time
    /// from "/", refusing a symbolic link anywhere in it.
    private static func openDirectory(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw VPhoneLaunchpadHelperError("The library path \(path) must be an absolute path without . or .. components.")
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw VPhoneLaunchpadHelperError("The library folder \(path) does not exist.")
        }
        for component in components {
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            close(directory)
            guard next >= 0 else {
                throw VPhoneLaunchpadHelperError(
                    failure == ELOOP || failure == ENOTDIR
                        ? "The library path cannot include symbolic links."
                        : "The library folder \(path) does not exist.",
                )
            }
            directory = next
        }
        return directory
    }

    private static func requireOwner(_ descriptor: Int32, _ path: String, _ uid: uid_t) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw VPhoneLaunchpadHelperError("\(path) is not a folder.")
        }
        guard info.st_uid == uid else {
            throw VPhoneLaunchpadHelperError("\(path) is not owned by your user account.")
        }
    }
}
