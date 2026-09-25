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
        // The path must already be canonical: no symlink anywhere in it, so a
        // component cannot be swapped to point root somewhere else.
        guard libraryRoot.hasPrefix("/"), let resolved = realpath(libraryRoot, nil) else {
            throw VPhoneLaunchpadHelperError("The library folder \(libraryRoot) does not exist.")
        }
        let canonical = String(cString: resolved)
        free(resolved)
        guard canonical == libraryRoot else {
            throw VPhoneLaunchpadHelperError("The library path cannot include symbolic links.")
        }
        let machine = URL(fileURLWithPath: libraryRoot, isDirectory: true)
            .appendingPathComponent(machineName, isDirectory: true)
        try Self.requireDirectory(libraryRoot, ownedBy: callerUID)
        try Self.requireDirectory(machine.path, ownedBy: callerUID)

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

    private static func requireDirectory(_ path: String, ownedBy uid: uid_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw VPhoneLaunchpadHelperError("\(path) is not a folder.")
        }
        guard info.st_uid == uid else {
            throw VPhoneLaunchpadHelperError("\(path) is not owned by your user account.")
        }
    }
}
