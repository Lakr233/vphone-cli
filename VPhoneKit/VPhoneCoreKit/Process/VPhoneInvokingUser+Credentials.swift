import Darwin
import Foundation

// MARK: - Credentials

public extension VPhoneInvokingUser {
    enum CredentialsError: Error, CustomStringConvertible {
        case notRoot
        case unknownAccount(uid_t)
        case switchFailed(String, Int32)

        public var description: String {
            switch self {
            case .notRoot:
                "Switching to the invoking user's credentials needs root."
            case let .unknownAccount(uid):
                "Unable to find the user account with ID \(uid)."
            case let .switchFailed(step, code):
                "\(step) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Run `body` with the invoking user's effective IDs and groups, so the
    /// kernel applies that user's permissions to host bookkeeping in their
    /// own folders rather than root's. Root is restored afterwards.
    ///
    /// Only the effective IDs change (the real and saved IDs stay 0), and the
    /// credentials are process wide: call this only from the single-threaded
    /// CLI, after the root work has finished.
    func withUserCredentials<T>(_ body: () throws -> T) throws -> T {
        guard geteuid() == 0 else { throw CredentialsError.notRoot }
        guard let account = getpwuid(uid), let name = account.pointee.pw_name else {
            throw CredentialsError.unknownAccount(uid)
        }
        let savedGroup = getegid()
        let count = getgroups(0, nil)
        guard count >= 0 else { throw CredentialsError.switchFailed("getgroups", errno) }
        var savedGroups = [gid_t](repeating: 0, count: Int(count))
        guard getgroups(count, &savedGroups) >= 0 else {
            throw CredentialsError.switchFailed("getgroups", errno)
        }

        // Groups and the group ID first, while still root; the user ID last.
        guard initgroups(name, Int32(bitPattern: gid)) == 0 else {
            throw CredentialsError.switchFailed("initgroups", errno)
        }
        guard setegid(gid) == 0 else {
            let code = errno
            _ = setgroups(Int32(savedGroups.count), savedGroups)
            throw CredentialsError.switchFailed("setegid", code)
        }
        guard seteuid(uid) == 0 else {
            let code = errno
            _ = setegid(savedGroup)
            _ = setgroups(Int32(savedGroups.count), savedGroups)
            throw CredentialsError.switchFailed("seteuid", code)
        }

        let result = Result { try body() }

        // Back to root in the reverse order: the user ID first, since only
        // root may change the group ID and the group list.
        guard seteuid(0) == 0 else { throw CredentialsError.switchFailed("seteuid(0)", errno) }
        guard setegid(savedGroup) == 0 else { throw CredentialsError.switchFailed("setegid", errno) }
        guard setgroups(Int32(savedGroups.count), savedGroups) == 0 else {
            throw CredentialsError.switchFailed("setgroups", errno)
        }
        return try result.get()
    }
}
