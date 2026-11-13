import Foundation
import IcliKit
import IcliSystem

// MARK: - Files, Keychain, Packages

extension GuestAPI {
    static func executeFileTool(_ m: FileToolMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .filesRead:
            return try readFile(
                string(params, "path"),
                binary: bool(params, "binary"),
                limit: (params["limit"] as? NSNumber)?.intValue,
            )
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
