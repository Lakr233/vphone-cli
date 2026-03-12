import Foundation
import SWCompression
import libzstd

enum VPhoneArchiveError: Error, CustomStringConvertible {
    case unsupportedEntry(String)
    case missingEntryData(String)
    case invalidRelativePath(String)
    case zstd(String)

    var description: String {
        switch self {
        case let .unsupportedEntry(path):
            return "Unsupported archive entry: \(path)"
        case let .missingEntryData(path):
            return "Archive entry missing data: \(path)"
        case let .invalidRelativePath(path):
            return "Invalid archive path: \(path)"
        case let .zstd(message):
            return "zstd error: \(message)"
        }
    }
}

enum VPhoneArchive {
    static func extractTarArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let tarData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let entries = try TarContainer.open(container: tarData)
        try writeTarEntries(entries, to: destinationURL)
    }

    static func extractTarGzipArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let compressedData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let tarData = try GzipArchive.unarchive(archive: compressedData)
        let entries = try TarContainer.open(container: tarData)
        try writeTarEntries(entries, to: destinationURL)
    }

    static func extractTarZstdArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let compressedData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let tarData = try decompressZstd(compressedData)
        let entries = try TarContainer.open(container: tarData)
        try writeTarEntries(entries, to: destinationURL)
    }

    static func decompressZstdFile(at sourceURL: URL, to destinationURL: URL) throws {
        let compressedData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        try decompressZstd(compressedData).write(to: destinationURL)
    }

    static func decompressGzipFile(at sourceURL: URL) throws -> Data {
        let compressedData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        return try GzipArchive.unarchive(archive: compressedData)
    }

    static func createTarArchive(from sourceURL: URL) throws -> Data {
        let rootURL = sourceURL.standardizedFileURL
        var entries = [TarEntry]()
        try appendEntries(at: rootURL, rootURL: rootURL, entries: &entries)
        return TarContainer.create(from: entries, force: .pax)
    }

    static func replaceTarArchive(at archiveURL: URL, from sourceDirectory: URL) throws {
        let tarData = try createTarArchive(from: sourceDirectory)
        try tarData.write(to: archiveURL)
    }

    static func writeTarEntries(_ entries: [TarEntry], to destinationURL: URL) throws {
        var directoryAttributes = [([FileAttributeKey: Any], String)]()
        for entry in entries where entry.info.type == .directory {
            directoryAttributes.append(try writeTarDirectory(entry, to: destinationURL))
        }
        for entry in entries where entry.info.type != .directory {
            try writeTarEntry(entry, to: destinationURL)
        }
        for (attributes, path) in directoryAttributes {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        }
    }

    static func writeTarDirectory(_ entry: TarEntry, to destinationURL: URL) throws -> ([FileAttributeKey: Any], String) {
        let entryURL = destinationURL.appendingPathComponent(entry.info.name, isDirectory: true)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)

        var attributes = [FileAttributeKey: Any]()
        if let mtime = entry.info.modificationTime {
            attributes[.modificationDate] = mtime
        }
        if let ctime = entry.info.creationTime {
            attributes[.creationDate] = ctime
        }
        if let permissions = entry.info.permissions?.rawValue, permissions > 0 {
            attributes[.posixPermissions] = NSNumber(value: permissions)
        }
        return (attributes, entryURL.path)
    }

    static func writeTarEntry(_ entry: TarEntry, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let entryURL = destinationURL.appendingPathComponent(entry.info.name, isDirectory: false)
        try fileManager.createDirectory(at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch entry.info.type {
        case .symbolicLink:
            let linkName = entry.info.linkName
            if fileManager.fileExists(atPath: entryURL.path) {
                try fileManager.removeItem(at: entryURL)
            }
            try fileManager.createSymbolicLink(atPath: entryURL.path, withDestinationPath: linkName)
            return
        case .hardLink:
            let linkName = entry.info.linkName
            if fileManager.fileExists(atPath: entryURL.path) {
                try fileManager.removeItem(at: entryURL)
            }
            let linkTarget = destinationURL.appendingPathComponent(linkName).path
            try fileManager.linkItem(atPath: linkTarget, toPath: entryURL.path)
            return
        case .regular:
            guard let entryData = entry.data else {
                throw VPhoneArchiveError.missingEntryData(entry.info.name)
            }
            try entryData.write(to: entryURL)
        default:
            throw VPhoneArchiveError.unsupportedEntry(entry.info.name)
        }

        var attributes = [FileAttributeKey: Any]()
        if let mtime = entry.info.modificationTime {
            attributes[.modificationDate] = mtime
        }
        if let ctime = entry.info.creationTime {
            attributes[.creationDate] = ctime
        }
        if let permissions = entry.info.permissions?.rawValue, permissions > 0 {
            attributes[.posixPermissions] = NSNumber(value: permissions)
        }
        try fileManager.setAttributes(attributes, ofItemAtPath: entryURL.path)
    }

    static func decompressZstd(_ compressedData: Data) throws -> Data {
        let expectedSize = compressedData.withUnsafeBytes { rawBuffer -> UInt64 in
            guard let source = rawBuffer.baseAddress else {
                return ZSTD_CONTENTSIZE_ERROR
            }
            return ZSTD_getFrameContentSize(source, rawBuffer.count)
        }

        guard expectedSize != ZSTD_CONTENTSIZE_UNKNOWN else {
            throw VPhoneArchiveError.zstd("unknown decompressed size")
        }
        guard expectedSize != ZSTD_CONTENTSIZE_ERROR else {
            throw VPhoneArchiveError.zstd("invalid zstd frame")
        }
        guard expectedSize <= UInt64(Int.max) else {
            throw VPhoneArchiveError.zstd("decompressed size too large")
        }

        var output = Data(count: Int(expectedSize))
        let result = output.withUnsafeMutableBytes { outputBuffer in
            compressedData.withUnsafeBytes { inputBuffer -> size_t in
                guard let outputBase = outputBuffer.baseAddress, let inputBase = inputBuffer.baseAddress else {
                    return size_t.max
                }
                return ZSTD_decompress(outputBase, outputBuffer.count, inputBase, inputBuffer.count)
            }
        }
        if ZSTD_isError(result) != 0 {
            throw VPhoneArchiveError.zstd(String(cString: ZSTD_getErrorName(result)))
        }
        let writtenCount = Int(result)
        if writtenCount != output.count {
            output.removeSubrange(writtenCount...)
        }
        return output
    }

    private static func appendEntries(at url: URL, rootURL: URL, entries: inout [TarEntry]) throws {
        let fileManager = FileManager.default
        let resourceValues = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        let relativePath = try relativeArchivePath(for: url, rootURL: rootURL)
        if resourceValues.isDirectory == true {
            if !relativePath.isEmpty {
                var info = TarEntryInfo(name: relativePath + "/", type: .directory)
                applyMetadata(to: &info, from: attributes)
                entries.append(TarEntry(info: info, data: nil))
            }

            let children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try appendEntries(at: child, rootURL: rootURL, entries: &entries)
            }
            return
        }

        if resourceValues.isSymbolicLink == true {
            var info = TarEntryInfo(name: relativePath, type: .symbolicLink)
            info.linkName = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            applyMetadata(to: &info, from: attributes)
            entries.append(TarEntry(info: info, data: Data()))
            return
        }

        if resourceValues.isRegularFile == true {
            var info = TarEntryInfo(name: relativePath, type: .regular)
            applyMetadata(to: &info, from: attributes)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            entries.append(TarEntry(info: info, data: data))
            return
        }

        throw VPhoneArchiveError.unsupportedEntry(url.path)
    }

    private static func applyMetadata(to info: inout TarEntryInfo, from attributes: [FileAttributeKey: Any]) {
        info.modificationTime = attributes[.modificationDate] as? Date
        info.creationTime = attributes[.creationDate] as? Date
        if let permissions = attributes[.posixPermissions] as? NSNumber {
            info.permissions = .init(rawValue: permissions.uint32Value)
        }
        if let ownerID = attributes[.ownerAccountID] as? NSNumber {
            info.ownerID = ownerID.intValue
        }
        if let groupID = attributes[.groupOwnerAccountID] as? NSNumber {
            info.groupID = groupID.intValue
        }
    }

    private static func relativeArchivePath(for url: URL, rootURL: URL) throws -> String {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw VPhoneArchiveError.invalidRelativePath(path)
        }
        if path == rootPath {
            return ""
        }
        let offset = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
        return String(path.dropFirst(offset))
    }
}
