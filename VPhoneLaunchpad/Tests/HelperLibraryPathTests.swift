import Darwin
import Foundation

@main
struct HelperLibraryPathTests {
    typealias LibraryPath = VPhoneLaunchpadHelperLibraryPath

    /// The message `openDirectory` throws for `path`, or nil when it opens.
    static func openMessage(_ path: String) -> String? {
        do {
            close(try LibraryPath.openDirectory(path))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func main() throws {
        // The script passes its temporary directory; resolve /var to
        // /private/var so the path holds no symbolic link of its own.
        // Foundation's resolvingSymlinksInPath drops /private again.
        guard let resolved = realpath(CommandLine.arguments[1], nil) else {
            preconditionFailure("cannot resolve \(CommandLine.arguments[1])")
        }
        let scratch = String(cString: resolved)
        free(resolved)

        // MARK: - Messages by errno

        precondition(LibraryPath.openFailure("/Volumes/X/lib", errno: ENOENT) == "The library folder /Volumes/X/lib does not exist.")
        precondition(LibraryPath.openFailure("/Volumes/X/lib", errno: ELOOP) == "The library path cannot include symbolic links.")
        // A privacy refusal names the folder, Full Disk Access and the
        // helper's own path, never "does not exist".
        for failure in [EPERM, EACCES] {
            let message = LibraryPath.openFailure("/Volumes/ExAPFS/vphone", errno: failure)
            precondition(message.contains("/Volumes/ExAPFS/vphone"), message)
            precondition(message.contains("Full Disk Access"), message)
            precondition(message.contains("/Library/PrivilegedHelperTools/com.vphone.launchpad.helper"), message)
            precondition(!message.contains("does not exist"), message)
        }
        let other = LibraryPath.openFailure("/Volumes/X/lib", errno: EIO)
        precondition(other.contains(String(cString: strerror(EIO))), other)

        // MARK: - openDirectory on real folders

        let library = scratch + "/library"
        try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        precondition(openMessage(library) == nil)
        precondition(openMessage(scratch + "/missing") == "The library folder \(scratch)/missing does not exist.")

        let link = scratch + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: library)
        precondition(openMessage(link) == "The library path cannot include symbolic links.")

        // Root passes a mode 000 folder, so only an ordinary user sees EACCES.
        if getuid() != 0 {
            let closed = scratch + "/closed"
            try FileManager.default.createDirectory(atPath: closed + "/lib", withIntermediateDirectories: true)
            precondition(chmod(closed, 0) == 0)
            let message = openMessage(closed + "/lib") ?? ""
            precondition(message.contains("Full Disk Access"), message)
            precondition(chmod(closed, 0o700) == 0)
        }

        // MARK: - Owner check

        precondition(LibraryPath.ownerRefusal("/lib", uid: getuid(), ignoresOwnership: false) == "/lib is not owned by your user account.")
        let ignored = LibraryPath.ownerRefusal("/Volumes/My Disk/lib", uid: getuid(), ignoresOwnership: true)
        precondition(ignored.contains("Ignore ownership on this volume"), ignored)
        precondition(ignored.contains("\"/Volumes/My Disk/lib\""), ignored)

        let descriptor = try LibraryPath.openDirectory(library)
        defer { close(descriptor) }
        try LibraryPath.requireOwner(descriptor, library, getuid())
        do {
            try LibraryPath.requireOwner(descriptor, library, getuid() + 1)
            preconditionFailure("another user's folder passed the owner check")
        } catch {
            precondition(error.localizedDescription == "\(library) is not owned by your user account.", error.localizedDescription)
        }

        print("HelperLibraryPathTests passed")
    }
}
