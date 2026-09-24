import Foundation
import ArchiveKit

public enum VPhoneArchiveError: Error, CustomStringConvertible {
    case cannotOpen(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case memberNotFound(member: String, archive: String)
    /// A member resolved outside the destination after normalisation.
    case pathEscapesDestination(member: String, destination: String)
    case destinationNotWritable(String)
    case cancelled

    public var description: String {
        switch self {
        case let .cannotOpen(path, reason):
            "Could not open \(path): \(reason)"
        case let .readFailed(path, reason):
            "Could not read \(path): \(reason)"
        case let .writeFailed(path, reason):
            "Could not write \(path): \(reason)"
        case let .memberNotFound(member, archive):
            "\(archive) has no member named \(member)"
        case let .pathEscapesDestination(member, destination):
            """
            Refusing to unpack '\(member)': it resolves outside \(destination).
            The archive is malformed or hostile; nothing was written.
            """
        case let .destinationNotWritable(path):
            "Cannot write into \(path)"
        case .cancelled:
            "Cancelled"
        }
    }
}

/// libarchive's own message for a handle, or a stand-in when it has none.
func archiveErrorString(_ handle: OpaquePointer?) -> String {
    guard let handle, let message = archive_error_string(handle) else {
        return "unknown libarchive error"
    }
    return String(cString: message)
}
