import ArgumentParser
import Darwin
import Foundation
import VPhoneCoreKit

/// A file the user names on the command line, such as a preset file.
enum VPhoneInvokingUserFile {
    /// Under root only a single-link regular file owned by the sudo user is
    /// opened, never a link, so root opens nothing the invoking user could not.
    static func read(_ url: URL, kind: String) throws -> Data {
        guard geteuid() == 0 else {
            return try Data(contentsOf: url)
        }
        guard let user = VPhoneInvokingUser.current else {
            throw ValidationError("Root reads a \(kind) only under sudo.")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ValidationError("Cannot open \(kind) \(url.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == user.uid
        else {
            throw ValidationError("\(kind.prefix(1).uppercased() + kind.dropFirst()) \(url.path) must be a regular file owned by the invoking user.")
        }
        return try handle.readToEnd() ?? Data()
    }
}
