import Darwin
import Foundation

enum GuestCacheFileProtectionFailure: Error, CustomStringConvertible {
    case setFailed(path: String, reason: String)
    case readbackMismatch(path: String, value: String?)

    var description: String {
        switch self {
        case let .setFailed(path, reason):
            "Could not set boot-time file protection for \(path): \(reason)"
        case let .readbackMismatch(path, value):
            "File protection for \(path) read back as \(value ?? "unknown"), "
                + "expected \(FileProtectionType.none.rawValue)"
        }
    }
}

enum GuestCacheFileProtection {
    static func setNoneAndVerify(atPath path: String) throws {
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: path)
        } catch {
            throw GuestCacheFileProtectionFailure.setFailed(path: path, reason: error.localizedDescription)
        }
        try verifyNone(atPath: path)
    }

    static func writeMarker(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let staging = url.appendingPathExtension("\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        try data.write(to: staging, options: [.atomic, .noFileProtection])
        try verifyNone(atPath: staging.path, fileManager: fileManager)
        // Rename the verified inode so publication cannot inherit the old marker's protection.
        guard Darwin.rename(staging.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func verifyNone(atPath path: String, fileManager: FileManager = .default) throws {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let actual = protectionName(attributes[.protectionKey])
        guard actual == FileProtectionType.none.rawValue else {
            throw GuestCacheFileProtectionFailure.readbackMismatch(path: path, value: actual)
        }
    }

    private static func protectionName(_ value: Any?) -> String? {
        if let protection = value as? FileProtectionType { return protection.rawValue }
        if let string = value as? String { return string }
        return nil
    }
}
