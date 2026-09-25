import ArchiveKit
import Foundation

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
            "Unable to open \(path) (\(reason)). Check that the file exists and try again."
        case let .readFailed(path, reason):
            "Unable to read \(path) (\(reason)). The file may be damaged. Download it again."
        case let .writeFailed(path, reason):
            "Unable to write to \(path) (\(reason)). Check that the folder is writable and has free space, then try again."
        case let .memberNotFound(member, archive):
            "\(archive) does not contain '\(member)'."
        case let .pathEscapesDestination(member, destination):
            "Unable to unpack '\(member)' because it points outside \(destination). The archive may be damaged or unsafe. Nothing was written."
        case let .destinationNotWritable(path):
            "Unable to write to \(path). Check that the folder is writable and try again."
        case .cancelled:
            "Cancelled"
        }
    }
}

/// libarchive's own message for a handle, or a stand-in when it has none.
func archiveErrorString(_ handle: OpaquePointer?) -> String {
    guard let handle, let message = archive_error_string(handle) else {
        return "unknown error"
    }
    return String(cString: message)
}
