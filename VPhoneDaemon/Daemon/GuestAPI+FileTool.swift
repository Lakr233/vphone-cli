import Foundation
import IcliKit
import IcliSystem

// MARK: - Files, Keychain, Packages

extension GuestAPI {
    /// `readFile` from `offset` on: icli's has no offset. Same keys; `size` is the whole file, as is
    /// `total`; `next_offset` (offset plus raw bytes returned) only when more remains.
    private static func readFileFrom(_ path: String, offset: Int, binary: Bool, limit: Int?) throws -> [String: Any] {
        let cap = limit ?? 512 * 1024
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw GuestAPIError.fromErrno(errno, "\(path): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw GuestAPIError.fromErrno(errno, "\(path): \(String(cString: strerror(errno)))") }
        var buffer = [UInt8](repeating: 0, count: cap + 1)
        var filled = 0
        while filled < cap + 1 {
            let count = pread(descriptor, &buffer[filled], cap + 1 - filled, off_t(offset + filled))
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw GuestAPIError.fromErrno(errno, "\(path): \(String(cString: strerror(errno)))") }
            if count == 0 { break }
            filled += count
        }
        let truncated = filled > cap
        let slice = Data(buffer[..<min(filled, cap)])
        let text = !binary && !slice.contains(0) ? String(data: slice, encoding: .utf8) : nil
        var reply: [String: Any] = [
            "path": path, "encoding": text == nil ? "base64" : "utf8", "truncated": truncated,
            "size": Int(info.st_size), "total": Int(info.st_size), "content": text ?? slice.base64EncodedString(),
        ]
        if truncated { reply["next_offset"] = offset + slice.count }
        return reply
    }

    static func executeFileTool(_ m: FileToolMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .filesRead:
            // With offset or limit the reply pages (total, next_offset), so vphoned reads it; else icli reads it.
            if params["offset"] != nil || params["limit"] != nil {
                let offset = try GuestPaging.strictInt(params["offset"], name: "offset", range: 0 ... 1_099_511_627_776) ?? 0
                let limit = try GuestPaging.strictInt(params["limit"], name: "limit", range: 0 ... 67_108_864)
                return try readFileFrom(string(params, "path"), offset: offset, binary: bool(params, "binary"), limit: limit)
            }
            return try readFile(string(params, "path"), binary: bool(params, "binary"), limit: nil)
        case .filesWrite:
            guard let content = params["content"] as? String else {
                throw GuestAPIError.invalidRequest("content is required", hint: "Pass content as a string; an empty string is allowed")
            }
            return try writeFile(
                string(params, "path"),
                content: content,
                encoding: optionalString(params, "encoding") ?? "utf8",
            )
        case .filesFind:
            return try findFiles(root: string(params, "root"), pattern: string(params, "pattern"))
        case .filesCopy:
            return try copyPath(string(params, "from"), to: string(params, "to"))
        case .filesSymlink:
            return try createSymlink(
                target: string(params, "target"),
                link: string(params, "link"),
                replace: bool(params, "replace"),
            )
        case .filesChmod:
            return try changeMode(string(params, "path"), mode: string(params, "mode"))
        case .filesChown:
            return try changeOwner(string(params, "path"), owner: string(params, "owner"))
        case .filesSaveToFilesApp:
            return try saveToFilesApp(string(params, "path"), name: string(params, "name"))
        case .filesPlist:
            return try readPlist(string(params, "path"))
        case .filesPlistSet:
            let json: String? =
                if bool(params, "remove") {
                    nil
                } else if let value = params["value"] {
                    try String(
                        decoding: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                        as: UTF8.self,
                    )
                } else {
                    throw GuestAPIError.invalidRequest("value is required unless remove is true", hint: "Pass value (any JSON value), or remove: true to delete the key")
                }
            return try setPlistValue(string(params, "path"), key: string(params, "key"), json: json)
        case .keychainDatabase:
            return try listKeychainDatabaseMetadata(className: optionalString(params, "class"))
        case .packagesList:
            return try listPackages(filter: optionalString(params, "filter"))
        case .packagesStatus:
            return try packageStatus(string(params, "name"))
        case .packagesInfo:
            return try readDeb(string(params, "path"))
        case .packagesCompare:
            return try compareDebianVersions(string(params, "left"), string(params, "right"))
        case .packagesTweaks:
            return try listTweaks()
        case .packagesRepos:
            return try listRepos()
        }
    }
}
