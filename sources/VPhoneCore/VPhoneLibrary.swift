import Foundation

public enum VPhoneLibraryError: Error, Equatable {
    case notFound(name: String)
    case alreadyExists(name: String)
    case invalidName(String)
}

extension VPhoneLibraryError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .notFound(name): "VM '\(name)' not found"
        case let .alreadyExists(name): "VM '\(name)' already exists"
        case let .invalidName(name): "Invalid VM name '\(name)' (must be non-empty, contain no '/', and not start with '.')"
        }
    }
    public var errorDescription: String? { description }
}

public struct VPhoneLibrarySkip: Sendable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

// MARK: - Library

public struct VPhoneLibrary: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VPHONE_LIBRARY_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // `~/.vphone/VMs` — deliberately space-free: bundle paths flow into the
        // shell/make firmware pipeline, and "Application Support" (a space) breaks
        // any unquoted expansion there. Keep the default path shell-safe.
        return VPhoneResources.userDataRoot()
            .appendingPathComponent("VMs", isDirectory: true)
    }

    public func url(forName name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    public func scan() throws -> (bundles: [VPhoneBundle], skipped: [VPhoneLibrarySkip]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return ([], []) }
        let entries = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var bundles: [VPhoneBundle] = []
        var skipped: [VPhoneLibrarySkip] = []
        for url in entries
            where fm.fileExists(atPath: url.appendingPathComponent("config.plist").path) {
            do {
                bundles.append(try VPhoneBundle.load(at: url))
            } catch {
                skipped.append(VPhoneLibrarySkip(name: url.lastPathComponent, reason: "\(error)"))
            }
        }
        return (bundles.sorted { $0.name < $1.name }, skipped.sorted { $0.name < $1.name })
    }

    public func bundles() throws -> [VPhoneBundle] {
        try scan().bundles
    }

    public func bundle(named name: String) throws -> VPhoneBundle {
        let url = url(forName: name)
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("config.plist").path) else {
            throw VPhoneLibraryError.notFound(name: name)
        }
        return try VPhoneBundle.load(at: url)
    }
}
