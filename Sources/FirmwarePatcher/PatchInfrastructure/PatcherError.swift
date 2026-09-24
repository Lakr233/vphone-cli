// PatcherError.swift — Error types for firmware patching.

import Foundation

public enum PatcherError: Error, CustomStringConvertible, Sendable {
    case fileNotFound(String)
    case invalidFormat(String)
    case patchSiteNotFound(String)
    case patchVerificationFailed(String)

    public var description: String {
        switch self {
        case let .fileNotFound(path):
            "File not found: \(path)"
        case let .invalidFormat(msg):
            "Invalid format: \(msg)"
        case let .patchSiteNotFound(msg):
            "Patch site not found: \(msg)"
        case let .patchVerificationFailed(msg):
            "Patch verification failed: \(msg)"
        }
    }
}
